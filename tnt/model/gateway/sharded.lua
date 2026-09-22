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
--- страницы сливаются в порядке индекса. Выборка по первичному ключу
--- на равенство — в один бакет, как `find`.
---
--- Транзакции через роутер нет: `box.atomic` живёт там, где данные, —
--- в функции хранилища, которую роутер зовёт `callrw` в пределах одного
--- бакета.

local check = require('tnt.model.check')
local failure = require('tnt.model.failure')
local order = require('tnt.model.order')
local shapes = require('tnt.model.shape')
local tuple = require('tnt.model.tuple')
local world = require('tnt.model.world')

local Module = {}

--- Имя шлюза.
Module.KIND = 'sharded'

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

---@class TntModelShardedOptions
---@field timeout number Срок одного обращения к хранилищу, секунды

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
        local text = type(err) == 'table' and err.message or tostring(err)

        return nil,
            failure.new(failure.UNAVAILABLE, ('хранилище не ответило: %s'):format(tostring(text)))
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

--- Ответы всех репликасетов на веерный вызов.
---@param options TntModelShardedOptions
---@param name string
---@param args any[]
---@return any[]|nil values Значения из ответов, по репликасетам
---@return TntModelFailure|nil err
local function fanned(options, name, args)
    local map, err = world.current().router().map_callrw(name, args, { timeout = options.timeout })

    if map == nil then
        return unwrapped(nil, err)
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

    function gateway.find(shape, key)
        return called('callro', shape, key, 'tnt_model_find', { shape.space, key })
    end

    function gateway.put(shape, values, mode)
        local key = check.key_from(shape, values)

        return called('callrw', shape, key, 'tnt_model_put', { shape.space, values, mode })
    end

    function gateway.delete(shape, key)
        return called('callrw', shape, key, 'tnt_model_delete', { shape.space, key })
    end

    function gateway.select(shape, query)
        if single_bucket(shape, query) then
            return called('callro', shape, query.key, 'tnt_model_select', { shape.space, query })
        end

        local pages, err = fanned(options, 'tnt_model_select', { shape.space, query })

        if pages == nil then
            return nil, err
        end

        local index = assert(shapes.index_of(shape, query.index))

        return order.merged(shape, index, query.iterator, pages, query.limit)
    end

    function gateway.count(shape, query)
        if single_bucket(shape, query) then
            return called('callro', shape, query.key, 'tnt_model_count', { shape.space, query })
        end

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

    function gateway.atomic()
        local message =
            'транзакция через роутер невозможна: box.atomic живёт в функции хранилища, которую роутер зовёт callrw'

        fail(message)
    end

    function gateway.close() end

    return gateway
end

return Module
