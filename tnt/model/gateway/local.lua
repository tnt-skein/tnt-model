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
--- Отметки времени и признак мягкого удаления ставит этот шлюз: замена
--- берёт отметку создания и признак удаления у прежней записи тем же
--- обращением к спейсу, без уступки между чтением и записью. Сюда же
--- приходят записи роутера и прослойки через функции узла с данными,
--- поэтому отметка ставится одинаково в любой топологии.
---
--- Счёт диапазона с верхней границей — два счёта по индексу (`ranged`
--- ниже): без уступок и одним снимком. Не одним обращением к `box` идут
--- только выборка и счёт с условиями областей и мягкого удаления: `box`
--- их не знает, и индекс обходится кусками с уступкой между ними (`walk`
--- ниже). Внутри транзакции уступать нельзя, и там обход идёт без
--- уступок — предел назван в документе пакета.

local check = require('tnt.model.check')
local failure = require('tnt.model.failure')
local order = require('tnt.model.order')
local scopes = require('tnt.model.scope')
local shapes = require('tnt.model.shape')
local stamps = require('tnt.model.stamp')
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
---@field offset integer|nil Сколько записей пропустить
---@field after table|nil Запись, после которой продолжать
---@field to any Верхняя граница диапазона по первому звену, только у итератора GE; пусто — без неё
---@field filter TntModelCondition[]|nil Условия на поля записи; пусто — без них

---@class TntModelGateway Шлюз к данным: одинаков для всех топологий
---
--- Способ удаления `delete`: пусто — по модели (мягко у модели с признаком
--- удаления), `force` — окончательно, `restore` — восстановить. Мягкое
--- удаление и восстановление отдают запись, какой она легла; ложь —
--- удалять либо восстанавливать нечего.
---@field kind string local, sharded либо remote
---@field find fun(shape: TntModelShape, key: any[]): table|nil, TntModelFailure|nil
---@field put fun(shape: TntModelShape, values: table, mode: string): table|nil, TntModelFailure|nil
---@field delete fun(shape: TntModelShape, key: any[], mode: string?): boolean|table|nil, TntModelFailure|nil
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

--- Сколько записей берётся за один кусок обхода выборки с условиями.
---
--- Тысяча — та же мера, что у чистки кэша, expirationd и moonwalker:
--- кусок вместе с разбором записей и сверкой с условиями проходится
--- за единицы миллисекунд (замер на 3.8: до 6 мс), а уступка между
--- кусками обновляет срез файбера.
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

--- Отказ из исключения `box`: занятое значение уникального индекса —
--- отказ, остальное — ошибка программиста или узла, и она бросается
--- дальше.
---
--- Отказ называет индекс, который занят: ключ свободен, а занят `login` —
--- и текст «с таким ключом» послал бы искать не то. Имя индекса `box`
--- кладёт в ошибку сам; первичный индекс зовётся ключом. Так же зовётся
--- и занятое без имени индекса: такую ошибку собирают кодом
--- (`box.error.new` в триггере спейса), и сказать, что занято, нечем.
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
        local taken = 'ключом'

        if err.index ~= nil and err.index ~= shapes.PRIMARY_INDEX then
            taken = err.index
        end

        return failure.new(
            failure.CONFLICT,
            ('запись %s с таким %s уже есть'):format(shape.space, taken)
        )
    end

    error(err)
end

--- Верхняя граница `to` приходит только с итератором `GE`.
---
--- Границу ставит `between`, и выборка идёт от нижней границы вверх:
--- записи за верхней — хвост выборки, и их отрезает и страница
--- (`bounded`), и разность счётов (`ranged`). С другим итератором граница
--- значила бы иное: у `EQ` и по убыванию разность счётов вычла бы чужие
--- записи, а страница по убыванию отдавала бы всё либо ничего — по первой
--- записи. Модель такой выборки не собирает, и прийти она может только
--- чужим вызовом с провода: это ошибка вызывающего кода, как выборка
--- не по форме, а не число, посчитанное неведомо как.
---@param shape TntModelShape
---@param query TntModelQuerySpec
local function upward(shape, query)
    if query.to ~= nil and query.iterator ~= 'GE' then
        fail(
            ('модель %s: граница to — только у итератора GE, а не %s'):format(
                shape.space,
                query.iterator
            )
        )
    end
end

--- Выборка с ключом в виде `box` (`tuple.stored_key`).
---
--- Копия, а не правка: выборку вызывающий держит у себя. Верхняя граница
--- `to` остаётся в виде записи — ею сверяется запись, прочитанная
--- из спейса (`within`), а в `box` её переводит счёт диапазона (`ranged`).
---@param shape TntModelShape
---@param query TntModelQuerySpec
---@return TntModelQuerySpec
local function searched(shape, query)
    local copy = table.copy(query) --[[@as TntModelQuerySpec]]

    copy.key = tuple.stored_key(shape, assert(shapes.index_of(shape, query.index)).parts, query.key)

    return copy
end

--- Первое звено индекса выборки: по нему режет верхняя граница диапазона.
---@param shape TntModelShape
---@param query TntModelQuerySpec
---@return string
local function part_of(shape, query)
    return assert(shapes.index_of(shape, query.index)).parts[1] --[[@as string]]
end

--- Не ушла ли запись за верхнюю границу диапазона; без границы — не ушла.
---@param part string Первое звено индекса
---@param query TntModelQuerySpec
---@param row table Значения записи
---@return boolean
local function within(part, query, row)
    return query.to == nil or order.compare(row[part], query.to) <= 0
end

--- Записи страницы, отрезанной по верхней границе диапазона.
---@param shape TntModelShape
---@param options TntModelLocalOptions
---@param query TntModelQuerySpec
---@param tuples any[]
---@return table[]
local function bounded(shape, options, query, tuples)
    local rows = {}
    local part = part_of(shape, query)

    for _, item in ipairs(tuples) do
        local row = tuple.from_tuple(shape, options.sharded, item)

        if not within(part, query, row) then
            break
        end

        table.insert(rows, row)
    end

    return rows
end

--- Кусок обхода: за уступкой — под `pcall`, без неё — как есть.
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
---@param after any|nil Кортеж, после которого брать кусок
---@param yielded boolean Уступил ли обход перед этим куском
---@return any[]|nil page
---@return TntModelFailure|nil err
local function chunk_of(shape, index, query, after, yielded)
    local opts = { iterator = query.iterator, limit = COUNT_CHUNK, after = after }

    if not yielded then
        return index:select(query.key, opts)
    end

    local ok, page = pcall(index.select, index, query.key, opts)

    if not ok then
        return nil,
            failure.new(
                failure.UNAVAILABLE,
                ('выборка %s с условием оборвана: %s'):format(shape.space, tostring(page))
            )
    end

    return page
end

--- Индекс выборки вместе с настройками `select`.
---
--- Курсор сверяется с ключом выборки до `box` (`order.placed`): курсор
--- раньше начала выборки не передаётся вовсе — после него идёт вся
--- выборка, — а за концом выборки на равенство страница пуста без
--- обращения к индексу. Иначе курсор от другой выборки отвечал бы
--- исключением `box` на узле с данными и отказом `unavailable` через
--- роутер, хотя ошибся клиент. Сверка идёт по ключу в виде записи,
--- до `searched`: так же, в виде записи, приходит и курсор.
---@param shape TntModelShape
---@param options TntModelLocalOptions
---@param space table
---@param query TntModelQuerySpec Выборка в виде записи
---@return table index
---@return table opts
---@return boolean|nil late Курсор за концом выборки: страница пуста
local function prepared(shape, options, space, query)
    local opts = { iterator = query.iterator, limit = query.limit, offset = query.offset }
    local early, late

    if query.after ~= nil then
        local index = assert(shapes.index_of(shape, query.index))
        local cursor, missing = tuple.cursor_of(shape, options.sharded, index, query.after)

        if cursor == nil then
            fail(('модель %s: в after нет поля %s'):format(shape.space, missing))
        end

        early, late = order.placed(index.parts, query.iterator, query.key, query.after)
        opts.after = not early and cursor or nil
    end

    return space.index[query.index], opts, late
end

--- Обход индекса кусками, с уступкой между ними.
---
--- Обход без уступок узел не переживает: на 3.8 он идёт около 2,7 млн
--- записей в секунду, и срез файбера рвёт его «fiber slice is exceeded» —
--- при умолчании ядра на третьем миллионе записей, при срезе в 20 мс
--- хватает и 70 000. Спасает уступка, а не само разбиение: куски без
--- уступки срываются точно так же.
---
--- Уступка — после полного куска, перед следующим, а не перед первым:
--- короткий обход кончается одним куском, не уступая зря, и отдаёт
--- снимок. И первый кусок тогда вправду идёт в мире, которого никто
--- не менял, — его отказ остаётся исключением (`chunk_of` выше). Срез
--- от этого не страдает: между уступками по-прежнему один кусок.
---
--- Продолжение — `after` с кортежем конца куска, а не `GT` от его ключа:
--- индекс выборки бывает неуникальным, и `GT` потерял бы все записи
--- с тем же ключом, что у последней записи куска (сверено на 3.8:
--- из четырёх записей с одним ключом `GT` отдал две, `after` — четыре).
---
--- Внутри транзакции уступки нет: уступка обрывает транзакцию memtx
--- («Transaction has been aborted by a fiber yield»), и обход унёс бы
--- с собой чужую работу. Там он идёт без уступок, и длинный обход
--- в транзакции по-прежнему упирается в срез файбера — это названо
--- в документе пакета.
---
--- Обход вне транзакции длиннее куска — не снимок: за уступкой соседи
--- дописывают и стирают, и прочитанное складывается из кусков, снятых
--- каждый в свой миг. Снесённый под обходом спейс — отказ `unavailable`
--- парой, а не исключение из глубины `box` (`chunk_of` выше); неполный
--- итог при этом не отдаётся.
---@param shape TntModelShape
---@param index table Индекс выборки
---@param query TntModelQuerySpec
---@param after any|nil Кортеж, после которого начинать; пусто — с начала выборки
---@param visit fun(page: any[]): boolean|nil Разбор куска; истина — обход кончен, пусто — дальше
---@return TntModelFailure|nil err
local function walk(shape, index, query, after, visit)
    local yielding = not world.current().box().is_in_txn()
    local yielded = false

    while true do
        local page, err = chunk_of(shape, index, query, after, yielded)

        if page == nil then
            return err
        end

        -- Неполный кусок — индекс кончился, и уступать перед пустым
        -- продолжением незачем.
        if visit(page) or #page < COUNT_CHUNK then
            return nil
        end

        after = page[#page]

        if yielding then
            world.current().fiber().yield()
        end

        yielded = yielding
    end
end

--- Записей в диапазоне `between`: записи от нижней границы без записей
--- строго за верхней — два счёта по индексу.
---
--- `index:count` верхней границы не знает, но на 3.8 считает по дереву
--- индекса, не читая записей: миллион записей — около 100 мкс на оба
--- счёта против полсекунды обхода. Счёт не уступает, поэтому одинаков
--- в транзакции и вне её, не срывается срезом файбера и видит один
--- снимок — между двумя счётами никто не пишет.
---
--- Верхняя граница — только первым звеном (`{ to }`), и `GT` с неполным
--- ключом пропускает все записи с этим значением звена: составной индекс
--- считается по первому звену, как `between` его и задаёт. Пустое
--- значение необязательного поля в индексе меньше любого, и под нижнюю
--- границу оно не попадает.
---
--- Верхняя граница ниже нижней — пустой диапазон: записей за верхней
--- тогда больше, чем от нижней, и разность меньше нуля.
---@param shape TntModelShape
---@param index table Индекс выборки
---@param query TntModelQuerySpec Выборка с ключом в виде `box`
---@return integer
local function ranged(shape, index, query)
    local from = index:count(query.key, { iterator = query.iterator })
    local to = tuple.stored_key(shape, { part_of(shape, query) }, { query.to })
    local beyond = index:count(to, { iterator = 'GT' })

    return math.max(from - beyond, 0) --[[@as integer]]
end

--- Обход выборки с условиями: записи индекса по одной, пока `take`
--- не скажет «хватит» либо не кончится диапазон.
---
--- `box` условий на поля записи не знает, поэтому индекс обходится
--- кусками (`walk`), и каждая запись куска сверяется с условиями.
--- Сколько записей прочитано, зависит от того, как часто они подходят:
--- страница из двадцати записей, под которую подошла каждая тысячная,
--- читает двадцать тысяч.
---@param shape TntModelShape
---@param options TntModelLocalOptions
---@param index table Индекс выборки
---@param query TntModelQuerySpec
---@param after any|nil Кортеж-курсор, после которого начинать
---@param take fun(row: table): boolean|nil Подошедшая запись; истина — хватит, пусто — дальше
---@return TntModelFailure|nil err
local function sifted(shape, options, index, query, after, take)
    local part = part_of(shape, query)
    local filter = query.filter --[[@as TntModelCondition[] ]]

    return walk(shape, index, query, after, function(page)
        for _, item in ipairs(page) do
            local row = tuple.from_tuple(shape, options.sharded, item)

            if not within(part, query, row) then
                return true
            end

            if scopes.matches(filter, row) and take(row) then
                return true
            end
        end
    end)
end

--- Заводит шлюз.
---@param options TntModelLocalOptions
---@return TntModelGateway
function Module.new(options)
    local gateway = { kind = Module.KIND }

    --- Запись по ключу из спейса; пусто — нет такой.
    ---@param shape TntModelShape
    ---@param space table
    ---@param key any[]
    ---@return table|nil
    local function existing(shape, space, key)
        local found = space:get(tuple.stored_key(shape, shape.primary, key))

        if found == nil then
            return nil
        end

        return tuple.from_tuple(shape, options.sharded, found)
    end

    --- Час записи — стенные часы: отметка уезжает на другие узлы.
    ---@return number
    local function now()
        return world.current().clock().realtime()
    end

    function gateway.find(shape, key)
        local space, err = space_of(shape)

        if space == nil then
            return nil, err
        end

        return existing(shape, space, key)
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
        local key = check.key_from(shape, values)
        local space, bucket_id = writable(shape, key)

        if space == nil then
            return nil, bucket_id
        end

        -- Прежняя запись читается и перед вставкой: занятый ключ вставка
        -- всё равно отвергнет, а ветка по способу записи была бы лишней.
        if shape.stamped then
            stamps.written(shape, values, existing(shape, space, key), now())
        end

        ---@cast bucket_id integer|nil
        local ok, stored = pcall(space[mode], space, tuple.to_tuple(shape, options.sharded, values, bucket_id))

        if not ok then
            return nil, refused(shape, stored)
        end

        return tuple.from_tuple(shape, options.sharded, stored)
    end

    --- Удаление: окончательное — из спейса; мягкое и восстановление —
    --- заменой записи с отметкой.
    ---
    --- Мягко удаляется запись модели с признаком удаления, если способ
    --- не `force`; восстановление — всегда заменой: у модели без
    --- признака `stamps.marked` отвечает «нечего», и запись не трогается.
    function gateway.delete(shape, key, mode)
        local space, bucket_id = writable(shape, key)

        if space == nil then
            return nil, bucket_id
        end

        if mode ~= stamps.RESTORE and (mode == stamps.FORCE or shape.stamps[stamps.DELETED] == nil) then
            return space:delete(tuple.stored_key(shape, shape.primary, key)) ~= nil
        end

        local found = existing(shape, space, key)
        local marked = found and stamps.marked(shape, found, mode, now())

        if not marked then
            return false
        end

        ---@cast bucket_id integer|nil
        return tuple.from_tuple(
            shape,
            options.sharded,
            space:replace(tuple.to_tuple(shape, options.sharded, marked, bucket_id))
        )
    end

    function gateway.select(shape, query)
        upward(shape, query)

        local space, err = space_of(shape)

        if space == nil then
            return nil, err
        end

        local index, opts, late = prepared(shape, options, space, query)

        if late then
            return {}
        end

        query = searched(shape, query)

        if query.filter == nil then
            return bounded(shape, options, query, index:select(query.key, opts))
        end

        -- Смещение считает подошедшие записи: `box` пропустил бы
        -- и не подошедшие.
        local rows = {}
        local skipped = 0
        local broken = sifted(shape, options, index, query, opts.after, function(row)
            -- Без смещения сравнивать не с чем: умолчание нулём было бы
            -- неотличимо от любого отрицательного.
            if query.offset ~= nil and skipped < query.offset then
                skipped = skipped + 1
            else
                table.insert(rows, row)

                -- Равенство, а не «не меньше»: записи прибавляются
                -- по одной, и страница полна ровно на пределе.
                return #rows == query.limit
            end
        end)

        if broken ~= nil then
            return nil, broken
        end

        return rows
    end

    function gateway.count(shape, query)
        upward(shape, query)

        local space, err = space_of(shape)

        if space == nil then
            return nil, err
        end

        local index = space.index[query.index]

        query = searched(shape, query)

        if query.filter ~= nil then
            local counted = 0
            local broken = sifted(shape, options, index, query, nil, function()
                counted = counted + 1
            end)

            if broken ~= nil then
                return nil, broken
            end

            return counted
        end

        if query.to == nil then
            return index:count(query.key, { iterator = query.iterator })
        end

        return ranged(shape, index, query)
    end

    function gateway.atomic(fn, ...)
        return world.current().box().atomic(fn, ...)
    end

    function gateway.close() end

    return gateway
end

return Module
