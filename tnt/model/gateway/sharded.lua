--- Шлюз `sharded`: данные в шардированном кластере, путь через роутер vshard.
---
--- Стоит там, где у узла есть роль router vshard: на выделенном роутере
--- и на узле «и роутер, и хранилище». Бакет считается от ключа
--- шардирования `bucket_id_mpcrc32` роутера, а на хранилище вызываются
--- общие функции `tnt_model_*`, которые узел с данными публикует
--- по белому списку моделей приложения.
---
--- Выборка по вторичному индексу идёт на все репликасеты сразу
--- (`map_callrw`, другого веера у vshard 0.1.42 нет — только на ведущих),
--- страницы сливаются в порядке индекса. Веер берёт на каждом хранилище
--- ссылку, которая держит бакеты на месте до ответа: пока бакеты
--- переезжают, он ждёт её и может отказать по сроку, а перенос ждёт,
--- пока ссылки отпустят. Выборка по первичному ключу на равенство —
--- в один бакет, как `find`.
---
--- Смещение веер хранилищам не передаёт: сколько из пропущенных записей
--- лежит у соседей, хранилище не знает. Каждое отдаёт первые
--- `offset + limit` своих записей, роутер сливает их и пропускает
--- `offset` — страница номер N стоит N страниц записей с каждого
--- репликасета.
---
--- Транзакции через роутер нет: роутер пишет по сети, запись ложится
--- на хранилище своей транзакцией, и откат вызывающего её не отменяет.
--- Поэтому у выделенного роутера запись внутри транзакции `box` —
--- исключение, как и `atomic`: тело транзакции живёт в функции хранилища,
--- которую роутер зовёт `callrw` в пределах одного бакета.
---
--- Узел «и роутер, и хранилище» держит часть бакетов сам, и транзакция
--- у него есть — по своим бакетам: `atomic` — это `box.atomic`. Внутри
--- транзакции модель идёт мимо роутера: чтение и запись по ключу — шлюзом
--- `local` к данным узла, под ссылкой vshard на бакет до конца транзакции.
--- Чужой бакет и выборка веером в транзакции — исключение: транзакция
--- не выходит за свой репликасет, а вызов через роутер ушёл бы по сети
--- мимо неё. Вне транзакции такой узел ходит через свой роутер, как
--- выделенный.

local check = require('tnt.model.check')
local failure = require('tnt.model.failure')
local order = require('tnt.model.order')
local queries = require('tnt.model.query')
local shapes = require('tnt.model.shape')
local tuple = require('tnt.model.tuple')
local world = require('tnt.model.world')

local Module = {}

--- Имя шлюза.
Module.KIND = 'sharded'

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

---@class TntModelShardedOptions
---@field timeout number Срок одного обращения к хранилищу, у веера — всего веера с повтором, секунды
---@field here TntModelGateway|nil Шлюз `local` к бакетам узла — у узла «и роутер, и хранилище»

--- Имя ошибки vshard, когда бакета на узле нет: он у другого репликасета
--- либо уже уехал.
local WRONG_BUCKET = 'WRONG_BUCKET'

--- Род отказа, когда бакет на узле есть, а ссылка на него не взялась:
--- узел не ведущий — только чтение; прочее — бакет в переносе либо заперт,
--- и это пройдёт.
---@type table<string, string>
local REF_KINDS = { NON_MASTER = failure.READONLY }

--- Имя ошибки vshard, когда веер застал объекты репликасетов прежней
--- конфигурации: роутер перечитал её, пока веер ждал ответов.
local OUTDATED = 'OBJECT_IS_OUTDATED'

--- Отказ: хранилище не ответило.
---
--- Веер ходит на все репликасеты сразу, и vshard называет третьим
--- значением тот, на котором вызов споткнулся. Без имени погашенный шард
--- и шард, чьи бакеты переезжают, звучали бы одинаково, и искать пришлось
--- бы по журналам всех узлов. Вызов в один бакет имени не получает:
--- хранилище там одно, и оно видно по ключу.
---@param err any Ошибка vshard
---@param replicaset string|nil Репликасет, который не ответил
---@return nil
---@return TntModelFailure
local function unanswered(err, replicaset)
    local text = type(err) == 'table' and err.message or tostring(err)
    local storage = replicaset == nil and 'хранилище' or 'хранилище ' .. replicaset

    return nil, failure.new(failure.UNAVAILABLE, ('%s не ответило: %s'):format(storage, tostring(text)))
end

--- Значение из ответа хранилища либо отказ.
---
--- Пустой ответ — отказ самого vshard: бакет не найден, срок, обрыв.
--- Ответ с `ok = false` — отказ модели на хранилище, он восстанавливается
--- в тот же вид, что и на месте.
---@param reply any
---@param err any
---@return any value
---@return TntModelFailure|nil err
local function unwrapped(reply, err)
    if reply == nil then
        return unanswered(err)
    end

    if reply.ok == false then
        return nil, failure.from_wire(reply)
    end

    return reply.value
end

--- Номер бакета по ключу — считает роутер, знающий число бакетов.
---@param shape TntModelShape
---@param key any[]
---@return integer
local function bucket_of(shape, key)
    return world.current().router().bucket_id_mpcrc32(tuple.shard_key_of(shape, key))
end

--- Веерный вызов одной попыткой.
---@param name string
---@param args any[]
---@param timeout number Срок попытки, секунды
---@return table|nil map Ответы по репликасетам
---@return any err Ошибка vshard
---@return string|nil replicaset Репликасет, на котором вызов споткнулся
local function mapped(name, args, timeout)
    return world.current().router().map_callrw(name, args, { timeout = timeout })
end

--- Ответы всех репликасетов на веерный вызов.
---
--- Перечитывание конфигурации роутера заводит новые объекты репликасетов,
--- а прежние помечает устаревшими. Веер держит их от ссылок до ответов,
--- через уступки, и перечитывание, пришедшее посреди, обрывает его
--- `OBJECT_IS_OUTDATED`, хотя хранилища живы. Вызов в один бакет берёт
--- репликасет в миг отправки и этого не видит. Такой веер повторяется:
--- `tnt_model_select` и `tnt_model_count` только читают, а роутер к мигу
--- отказа уже держит свежие объекты.
---
--- Повтор один. Второй такой отказ значит новое перечитывание за время
--- повтора, а роутер, чья настройка сорвалась между пометкой и заменой
--- объектов, отказывает так сразу, без уступки: повтор без предела занял
--- бы поток целиком. Повтор идёт в остаток того же срока — веер целиком
--- не дольше `timeout`, как и без перечитывания. Срок отмечается
--- монотонными часами, остаток считается от отметки цикла: от неё vshard
--- отсчитывает свой срок (`tnt-clock`, правило выбора часов). Остатка
--- нет — повтор не уходит, отказом остаётся первая попытка.
---@param options TntModelShardedOptions
---@param name string
---@param args any[]
---@return any[]|nil values Значения из ответов, по репликасетам
---@return TntModelFailure|nil err
local function fanned(options, name, args)
    local clock = world.current().clock()
    local deadline = clock.monotonic() + options.timeout
    local map, err, replicaset = mapped(name, args, options.timeout)

    if map == nil and err.name == OUTDATED then
        local left = deadline - clock.scheduler_now()

        if left > 0 then
            map, err, replicaset = mapped(name, args, left)
        end
    end

    if map == nil then
        return unanswered(err, replicaset)
    end

    local values = {}

    for _, replies in pairs(map) do
        local value, refused = unwrapped(replies[1])

        if refused ~= nil then
            return nil, refused
        end

        table.insert(values, value)
    end

    return values
end

--- Выборка одного бакета: по первичному ключу на равенство, когда ключ
--- шардирования — его первое звено, то есть уже в ключе выборки.
---@param shape TntModelShape
---@param query TntModelQuerySpec
---@return boolean
local function single_bucket(shape, query)
    return query.index == shapes.PRIMARY_INDEX and query.iterator == 'EQ' and shape.primary[1] == shape.bucket_of
end

--- Заводит шлюз.
---@param options TntModelShardedOptions
---@return TntModelGateway
function Module.new(options)
    local gateway = { kind = Module.KIND }
    local here = options.here

    --- Вызов на хранилище бакета ключа.
    ---@param mode string callro либо callrw
    ---@param shape TntModelShape
    ---@param key any[]
    ---@param name string
    ---@param args any[]
    ---@return any value
    ---@return TntModelFailure|nil err
    local function called(mode, shape, key, name, args)
        local router = world.current().router()

        return unwrapped(router[mode](bucket_of(shape, key), name, args, { timeout = options.timeout }))
    end

    --- Шлюз к своим бакетам, если модель идёт к данным на месте: у узла
    --- с данными, в транзакции; пусто — модель идёт через роутер.
    ---
    --- Признак транзакции спрашивается только у такого узла: выделенному
    --- роутеру он нужен лишь для записи (`writer`), чтение идёт через роутер
    --- в любом случае.
    ---@return TntModelGateway|nil
    local function spot()
        if here ~= nil and world.current().box().is_in_txn() then
            return here
        end

        return nil
    end

    --- Действие шлюза `local` над бакетом ключа, взятым под ссылку vshard.
    ---
    --- Ссылка держится до конца транзакции и снимается триггером фиксации
    --- либо отката, а не сразу после действия: фиксация уступает управление
    --- на запись журнала, и перенос бакета, начатый в эту уступку, увёз бы
    --- его без записи. Бакета на узле нет — исключение: транзакция
    --- не выходит за свой репликасет, и чужой бакет — это тело транзакции,
    --- написанное не для этого узла. Бакет есть, а ссылка не взялась —
    --- отказ парой: узел не ведущий либо бакет в переносе.
    ---@param shape TntModelShape
    ---@param key any[]
    ---@param mode string read либо write — род ссылки vshard
    ---@param action function Действие шлюза `local`
    ---@param ... any Аргументы действия
    ---@return any value
    ---@return TntModelFailure|nil err
    local function nearby(shape, key, mode, action, ...)
        local bucket_id = bucket_of(shape, key)
        local storage = world.current().storage()
        local held, err = storage.bucket_ref(bucket_id, mode)

        if not held then
            if err.name == WRONG_BUCKET then
                fail(
                    (
                        'модель %s: бакет %d не на этом узле — в транзакции узел «и роутер, и хранилище» '
                        .. 'читает и пишет только свои бакеты; транзакция над чужим живёт в функции '
                        .. 'его хранилища, которую роутер зовёт callrw'
                    ):format(shape.space, bucket_id)
                )
            end

            return nil,
                failure.new(
                    REF_KINDS[err.name] or failure.UNAVAILABLE,
                    ('бакет %d: %s'):format(bucket_id, tostring(err.message))
                )
        end

        local box = world.current().box()

        local function released()
            storage.bucket_unref(bucket_id, mode)
        end

        box.on_commit(released)
        box.on_rollback(released)

        return action(...)
    end

    --- Шлюз записи в транзакции: у узла с данными — `local`, к своему бакету.
    ---
    --- У выделенного роутера своих данных нет — исключение: запись ушла бы
    --- по сети и легла на хранилище своей транзакцией, мимо этой, и откат
    --- её бы не отменил.
    ---@param shape TntModelShape
    ---@return TntModelGateway
    local function writer(shape)
        if here == nil then
            fail(
                (
                    'модель %s: запись через роутер в транзакции невозможна — она ушла бы по сети и легла '
                    .. 'мимо транзакции; box.atomic живёт в функции хранилища, которую роутер зовёт callrw'
                ):format(shape.space)
            )
        end

        return here
    end

    --- Выборка в один бакет: в транзакции узла с данными — на месте,
    --- иначе через роутер.
    ---@param shape TntModelShape
    ---@param query TntModelQuerySpec
    ---@param action string select либо count — действие шлюза и имя функции узла
    ---@return any value
    ---@return TntModelFailure|nil err
    local function single(shape, query, action)
        local near = spot()

        if near ~= nil then
            return nearby(shape, query.key, 'read', near[action] --[[@as function]], shape, query)
        end

        return called('callro', shape, query.key, 'tnt_model_' .. action, { shape.space, query })
    end

    --- Веер в транзакции узла с данными — исключение: он идёт через роутер
    --- по сети, и вызов уступил бы управление посреди транзакции.
    ---@param shape TntModelShape
    local function fanning(shape)
        if spot() ~= nil then
            fail(
                (
                    'модель %s: выборка веером в транзакции невозможна — она шла бы через роутер по сети '
                    .. 'мимо транзакции; в транзакции — только выборка в один бакет, по первичному ключу '
                    .. 'на равенство'
                ):format(shape.space)
            )
        end
    end

    function gateway.find(shape, key)
        local near = spot()

        if near ~= nil then
            return nearby(shape, key, 'read', near.find, shape, key)
        end

        return called('callro', shape, key, 'tnt_model_find', { shape.space, key })
    end

    function gateway.put(shape, values, mode)
        local key = check.key_from(shape, values)

        if world.current().box().is_in_txn() then
            return nearby(shape, key, 'write', writer(shape).put, shape, values, mode)
        end

        return called('callrw', shape, key, 'tnt_model_put', { shape.space, values, mode })
    end

    function gateway.delete(shape, key, mode)
        if world.current().box().is_in_txn() then
            return nearby(shape, key, 'write', writer(shape).delete, shape, key, mode)
        end

        return called('callrw', shape, key, 'tnt_model_delete', { shape.space, key, mode })
    end

    function gateway.select(shape, query)
        if single_bucket(shape, query) then
            return single(shape, query, 'select')
        end

        fanning(shape)

        -- Сумма по отдельности годных `offset` и `limit` бывает больше
        -- 32 бит, а их `box` молча обрезает: предел 2^32 + 4 отдал бы
        -- четыре записи. Хранилищу уходит не больше `OFFSET` — записей
        -- дальше него смещением через роутер не достать, их листают `after`.
        local offset = query.offset or 0
        local limit = math.min(offset + query.limit, queries.OFFSET) --[[@as integer]]
        local wide = table.copy(query)

        wide.offset = nil
        wide.limit = limit

        local pages, err = fanned(options, 'tnt_model_select', { shape.space, wide })

        if pages == nil then
            return nil, err
        end

        local index = assert(shapes.index_of(shape, query.index))
        local rows = order.merged(shape, index, query.iterator, pages, limit)
        local page = {}

        for position = offset + 1, #rows do
            table.insert(page, rows[position])
        end

        return page
    end

    function gateway.count(shape, query)
        if single_bucket(shape, query) then
            return single(shape, query, 'count')
        end

        fanning(shape)

        local counts, err = fanned(options, 'tnt_model_count', { shape.space, query })

        if counts == nil then
            return nil, err
        end

        local total = 0

        for _, counted in ipairs(counts) do
            total = total + counted
        end

        return total
    end

    --- Транзакция: у узла с данными — `box.atomic` шлюза `local`,
    --- у выделенного роутера её нет.
    function gateway.atomic(fn, ...)
        if here == nil then
            fail(
                'транзакция через роутер невозможна: box.atomic живёт в функции хранилища, которую роутер зовёт callrw'
            )
        end

        return here.atomic(fn, ...)
    end

    function gateway.close() end

    return gateway
end

return Module
