--- Шлюз `local`: данные лежат на этом узле, обращение к `box.space` прямо.
---
--- Стоит на одиночном узле, на ведущем и репликах репликасета без
--- шардирования и на хранилище vshard. Разница одна: на хранилище
--- в кортеже есть поле шардирования, бакет считается от ключа, а запись
--- принимается только в бакет, который живёт здесь, — запись мимо роутера
--- в чужой бакет иначе легла бы в спейс и пропала при переносе бакета.
---
--- На реплике только чтение: запись отвечает отказом `readonly`,
--- а не исключением из глубины `box`. Сам шлюз ведущему не пересылает:
--- по разделу `writes = 'forward'` это делает шлюз `forward` поверх него,
--- по этому отказу, — а функции узла с данными отвечают этим шлюзом
--- напрямую и потому не пересылают никогда.
---
--- Единственное место шлюза, где счёт идёт не одним обращением к `box`, —
--- диапазон с верхней границей: `index:count` её не знает, и диапазон
--- обходится кусками с уступкой между ними (`ranged` ниже). Внутри
--- транзакции уступать нельзя, и там обход идёт без уступок — предел
--- назван в документе пакета.

local check = require('tnt.model.check')
local failure = require('tnt.model.failure')
local order = require('tnt.model.order')
local shapes = require('tnt.model.shape')
local tuple = require('tnt.model.tuple')
local world = require('tnt.model.world')

local Module = {}

--- Имя шлюза.
Module.KIND = 'local'

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

---@class TntModelQuerySpec Выборка по индексу
---@field index string Имя индекса
---@field iterator string Итератор box: EQ, GT, GE, LT, LE, ALL
---@field key any[] Ключ выборки: значение первого звена либо пусто
---@field limit integer Не больше стольких записей
---@field after table|nil Запись, после которой продолжать
---@field to any Верхняя граница диапазона по первому звену; пусто — без неё

---@class TntModelGateway Шлюз к данным: одинаков для всех топологий
---@field kind string local, sharded либо remote
---@field find fun(shape: TntModelShape, key: any[]): table|nil, TntModelFailure|nil
---@field put fun(shape: TntModelShape, values: table, mode: string): table|nil, TntModelFailure|nil
---@field delete fun(shape: TntModelShape, key: any[]): boolean|nil, TntModelFailure|nil
---@field select fun(shape: TntModelShape, query: TntModelQuerySpec): table[]|nil, TntModelFailure|nil
---@field count fun(shape: TntModelShape, query: TntModelQuerySpec): integer|nil, TntModelFailure|nil
---@field atomic fun(fn: function, ...: any): any
---@field close fun()

---@class TntModelLocalOptions
---@field sharded boolean Узел — хранилище vshard: в кортеже есть поле шардирования
---@field bucket_count integer|nil Число бакетов — на шардированном узле

--- Состояния бакета, в котором запись на месте.
---@type table<string, boolean>
local OWNED = { active = true, pinned = true }

--- Сколько записей берётся за один кусок счёта по диапазону.
---
--- Тысяча — та же мера, что у чистки кэша, expirationd и moonwalker:
--- кусок проходится за доли миллисекунды, а уступка между кусками
--- обновляет срез файбера. Замер на 3.8: 300 000 записей — 301 уступка
--- и 0,1 с при срезе файбера в 20 мс.
local COUNT_CHUNK = 1000

--- Спейс модели либо отказ: схема ещё не поднята.
---@param shape TntModelShape
---@return table|nil space
---@return TntModelFailure|nil err
local function space_of(shape)
    local space = world.current().box().space[shape.space]

    if space == nil then
        return nil,
            failure.new(
                failure.UNAVAILABLE,
                ('спейса %s нет: схема на узле не поднята'):format(shape.space)
            )
    end

    return space
end

--- Отказ записи, если узел только для чтения.
---@return TntModelFailure|nil
local function readonly()
    local info = world.current().box().info

    if not info.ro then
        return nil
    end

    local reason = info.ro_reason

    return failure.new(
        failure.READONLY,
        'узел только для чтения' .. (reason ~= nil and (': ' .. tostring(reason)) or '')
    )
end

--- Номер бакета записи на шардированном узле; на остальных — пусто.
---
--- Бакет обязан быть здесь: `_bucket` знает, какие бакеты узел держит.
--- Без разметки записывать некуда — это тоже отказ, а не тихая запись
--- в бакет, которого никто не назначал.
---@param options TntModelLocalOptions
---@param shape TntModelShape
---@param key any[]
---@return integer|nil bucket_id
---@return TntModelFailure|nil err
local function owned_bucket(options, shape, key)
    if not options.sharded or shape.bucket_of == nil then
        return nil
    end

    local count = options.bucket_count --[[@as integer]]
    local bucket_id = tuple.bucket_of(world.current().hash(), tuple.shard_key_of(shape, key), count)
    local buckets = world.current().box().space._bucket

    if buckets == nil then
        return nil, failure.new(failure.UNAVAILABLE, 'бакеты на узле не размечены')
    end

    local bucket = buckets:get(bucket_id)

    if bucket == nil or not OWNED[bucket.status] then
        return nil,
            failure.new(
                failure.MISROUTED,
                ('бакет %d не на этом узле: запись идёт через роутер'):format(
                    bucket_id
                )
            )
    end

    return bucket_id
end

--- Отказ из исключения `box`: занятый ключ — отказ, остальное — ошибка
--- программиста или узла, и она бросается дальше.
---
--- Только чтение здесь не ловится: оно проверено до записи, а между
--- проверкой и записью файбер не уступает — режим смениться не успеет.
---
--- Исключение бросается дальше как есть, без уровня: запись в спейс
--- бросает объект ошибки `box`, а место вызова `error` дописывает только
--- к строке — уровень здесь ничего бы не менял.
---@param shape TntModelShape
---@param err any
---@return TntModelFailure
local function refused(shape, err)
    local errors = world.current().box().error

    if errors.is(err) and err.code == errors.TUPLE_FOUND then
        return failure.new(
            failure.CONFLICT,
            ('запись %s с таким ключом уже есть'):format(shape.space)
        )
    end

    error(err)
end

--- Записи страницы, отрезанной по верхней границе диапазона.
---@param shape TntModelShape
---@param options TntModelLocalOptions
---@param query TntModelQuerySpec
---@param tuples any[]
---@return table[]
local function bounded(shape, options, query, tuples)
    local rows = {}
    local part = assert(shapes.index_of(shape, query.index)).parts[1]

    for _, item in ipairs(tuples) do
        local row = tuple.from_tuple(shape, options.sharded, item)

        if query.to ~= nil and order.compare(row[part], query.to) > 0 then
            break
        end

        table.insert(rows, row)
    end

    return rows
end

--- Не ушла ли запись за верхнюю границу диапазона.
---@param shape TntModelShape
---@param options TntModelLocalOptions
---@param query TntModelQuerySpec
---@param item any Кортеж из спейса
---@return boolean
local function within(shape, options, query, item)
    local part = assert(shapes.index_of(shape, query.index)).parts[1]
    local row = tuple.from_tuple(shape, options.sharded, item)

    return order.compare(row[part], query.to) <= 0
end

--- Кусок диапазона: за уступкой — под `pcall`, до неё — как есть.
---
--- Пока обход не уступал, мир под ним не менялся, и отказ `box` здесь —
--- честная поломка: негодный индекс или итератор (ошибка программиста)
--- либо съеденный срез файбера внутри транзакции. Такой отказ обязан
--- лететь исключением — проглоченный, он превратил бы обречённую
--- транзакцию в невнятный отказ чтения.
---
--- За уступкой отказ значит другое: спейс снесли под обходом
--- («Space '516' does not exist» из глубины `box`), и это отказ узла,
--- а не ошибка вызывающего. Срез файбера тут не при чём — выборка сразу
--- за уступкой его не срывает.
---@param shape TntModelShape
---@param index table
---@param query TntModelQuerySpec
---@param after any|nil Кортеж конца прошлого куска
---@param yielding boolean Уступает ли обход перед куском
---@return any[]|nil page
---@return TntModelFailure|nil err
local function chunk_of(shape, index, query, after, yielding)
    local opts = { iterator = query.iterator, limit = COUNT_CHUNK, after = after }

    if not yielding or after == nil then
        return index:select(query.key, opts)
    end

    local ok, page = pcall(index.select, index, query.key, opts)

    if not ok then
        return nil,
            failure.new(
                failure.UNAVAILABLE,
                ('счёт по диапазону %s оборван: %s'):format(shape.space, tostring(page))
            )
    end

    return page
end

--- Индекс выборки вместе с настройками `select`.
---@param shape TntModelShape
---@param options TntModelLocalOptions
---@param space table
---@param query TntModelQuerySpec
---@return table index
---@return table opts
local function prepared(shape, options, space, query)
    local opts = { iterator = query.iterator, limit = query.limit }

    if query.after ~= nil then
        local index = assert(shapes.index_of(shape, query.index))
        local cursor, missing = tuple.cursor_of(shape, options.sharded, index, query.after)

        if cursor == nil then
            fail(('модель %s: в after нет поля %s'):format(shape.space, missing))
        end

        opts.after = cursor
    end

    return space.index[query.index], opts
end

--- Записей в диапазоне с верхней границей: кусками, с уступкой.
---
--- `index:count` верхней границы не знает, и диапазон приходится
--- обходить. Обход без уступок узел не переживает: на 3.8 он идёт около
--- 2,7 млн записей в секунду, и срез файбера рвёт его «fiber slice is
--- exceeded» — при умолчании ядра на третьем миллионе записей, при срезе
--- в 20 мс хватает и 70 000. Спасает уступка, а не само разбиение:
--- куски без уступки срываются точно так же.
---
--- Продолжение — `after` с кортежем конца куска, а не `GT` от его ключа:
--- индекс выборки бывает неуникальным, и `GT` потерял бы все записи
--- с тем же ключом, что у последней записи куска (сверено на 3.8:
--- из четырёх записей с одним ключом `GT` отдал две, `after` — четыре).
---
--- Внутри транзакции уступки нет: уступка обрывает транзакцию memtx
--- («Transaction has been aborted by a fiber yield»), и счёт унёс бы
--- с собой чужую работу. Там обход идёт без уступок, и длинный диапазон
--- в транзакции по-прежнему упирается в срез файбера — это названо
--- в документе пакета.
---
--- Счёт вне транзакции — не снимок: за уступкой соседи дописывают
--- и стирают, и посчитанное складывается из кусков, снятых каждый
--- в свой миг. Снесённый под обходом спейс — отказ `unavailable` парой,
--- а не исключение из глубины `box` (`chunk_of` выше); неполный счёт
--- при этом не отдаётся.
---@param shape TntModelShape
---@param options TntModelLocalOptions
---@param index table Индекс выборки
---@param query TntModelQuerySpec
---@return integer|nil counted
---@return TntModelFailure|nil err
local function ranged(shape, options, index, query)
    local yielding = not world.current().box().is_in_txn()
    local counted = 0
    local after = nil
    local page

    repeat
        if yielding then
            world.current().fiber().yield()
        end

        local err

        page, err = chunk_of(shape, index, query, after, yielding)

        if page == nil then
            return nil, err
        end

        local last = page[#page]

        -- Пусто — индекс кончился; последняя запись куска за границей —
        -- граница внутри куска, и за ней записей уже не будет. В обоих
        -- случаях кусок разбирается по записям и обход кончается.
        if last == nil or not within(shape, options, query, last) then
            return counted + #bounded(shape, options, query, page)
        end

        -- Кусок целиком в диапазоне, раз в нём последняя запись: границу
        -- ставит только `between`, а он идёт по возрастанию. Такой кусок
        -- считается числом записей, без разбора каждой: на 300 000
        -- записей счёт стоит 0,1 с против 1,1 с с разбором.
        counted = counted + #page
        after = last
    until #page < COUNT_CHUNK

    return counted
end

--- Заводит шлюз.
---@param options TntModelLocalOptions
---@return TntModelGateway
function Module.new(options)
    local gateway = { kind = Module.KIND }

    function gateway.find(shape, key)
        local space, err = space_of(shape)

        if space == nil then
            return nil, err
        end

        local found = space:get(key)

        if found == nil then
            return nil
        end

        return tuple.from_tuple(shape, options.sharded, found)
    end

    --- Спейс, готовый принять запись по ключу: схема поднята, узел
    --- пишет, бакет ключа здесь.
    ---@param shape TntModelShape
    ---@param key any[]
    ---@return table|nil space
    ---@return integer|TntModelFailure|nil bucket_or_err Номер бакета при успехе, отказ — при пустом спейсе
    local function writable(shape, key)
        local space, err = space_of(shape)

        if space == nil then
            return nil, err
        end

        local denied = readonly()

        if denied ~= nil then
            return nil, denied
        end

        local bucket_id, misrouted = owned_bucket(options, shape, key)

        if misrouted ~= nil then
            return nil, misrouted
        end

        return space, bucket_id
    end

    function gateway.put(shape, values, mode)
        local space, bucket_id = writable(shape, check.key_from(shape, values))

        if space == nil then
            return nil, bucket_id
        end

        ---@cast bucket_id integer|nil
        local ok, stored = pcall(space[mode], space, tuple.to_tuple(shape, options.sharded, values, bucket_id))

        if not ok then
            return nil, refused(shape, stored)
        end

        return tuple.from_tuple(shape, options.sharded, stored)
    end

    function gateway.delete(shape, key)
        local space, err = writable(shape, key)

        if space == nil then
            return nil, err
        end

        return space:delete(key) ~= nil
    end

    function gateway.select(shape, query)
        local space, err = space_of(shape)

        if space == nil then
            return nil, err
        end

        local index, opts = prepared(shape, options, space, query)

        return bounded(shape, options, query, index:select(query.key, opts))
    end

    function gateway.count(shape, query)
        local space, err = space_of(shape)

        if space == nil then
            return nil, err
        end

        local index = space.index[query.index]

        if query.to == nil then
            return index:count(query.key, { iterator = query.iterator })
        end

        return ranged(shape, options, index, query)
    end

    function gateway.atomic(fn, ...)
        return world.current().box().atomic(fn, ...)
    end

    function gateway.close() end

    return gateway
end

return Module
