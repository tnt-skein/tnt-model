--- Шаг миграции из формы записи: формат спейса и индексы.
---
--- Шаг `tnt-schema` — функция от `box`, и решает он на узле, где
--- выполняется: на хранилище vshard в формате есть поле шардирования
--- и индекс по нему, на узле без шардирования их нет. Одна модель —
--- одна схема на каждой топологии, а переезд между топологиями —
--- отдельный шаг, написанный руками.
---
--- Шаг создаёт спейс по нынешнему объявлению. После первого выпуска
--- правки формы — отдельными шагами: на новом узле первый шаг создаст
--- спейс уже по новому объявлению, и следующие шаги обязаны это
--- пережить.
---
--- Модель, привязанная к шлюзу со своей схемой (`migrate` — у шлюза `sql`,
--- который приносит приложение), спейса не заводит: шаг отдаёт форму
--- шлюзу, и тот создаёт таблицу в базе. Так источник данных меняется
--- настройкой, а шаги миграций приложения остаются теми же. Отказ шлюза бросается:
--- шаг, не поднявший схему, обязан сорваться, чтобы версия не ушла вперёд.

local shapes = require('tnt.model.shape')
local topology = require('tnt.model.topology')
local tuple = require('tnt.model.tuple')

--- Бросок без места: отказ шлюза уходит шагу `tnt-schema` как есть,
--- таблицей с родом, и раннер пишет его текст.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Часть индекса для `create_index`: поле по имени с его родом.
---
--- Допустимость пустого значения часть не называет: без `is_nullable`
--- Tarantool берёт её из формата спейса, а формат её уже знает. Названная
--- здесь второй раз, она могла бы только разойтись с форматом.
---@param field TntModelField
---@return table
local function part_of(field)
    return { field = field.name, type = shapes.TYPES[field.type] }
end

--- Формат спейса для узла.
---@param shape TntModelShape
---@param sharded boolean
---@return table[]
function Module.format_of(shape, sharded)
    local format = {}

    for _, name in ipairs(tuple.names_of(shape, sharded)) do
        if name == shapes.BUCKET_FIELD then
            table.insert(format, { name = name, type = 'unsigned' })
        else
            local field = shape.by_name[name]

            table.insert(format, { name = name, type = shapes.TYPES[field.type], is_nullable = field.optional or nil })
        end
    end

    return format
end

--- Шлюз со своим хранилищем и своей схемой: `migrate` — схема из формы;
--- пусто — схема спейсом.
---@class TntModelSchemaGateway: TntModelGateway
---@field migrate (fun(shape: TntModelShape): boolean|nil, TntModelFailure|nil)|nil

--- Шаг миграции: спейс, первичный индекс, индексы модели, индекс бакета.
---@param shape TntModelShape
---@param bound fun(): TntModelGateway|nil Шлюз модели в миг шага; пусто — не привязана
---@return fun(box: table)
function Module.step(shape, bound)
    return function(box)
        local gateway = bound() --[[@as TntModelSchemaGateway|nil]]

        if gateway ~= nil and gateway.migrate ~= nil then
            local done, err = gateway.migrate(shape)

            if not done then
                fail(err)
            end

            return
        end

        local sharded = topology.vshard_storage()
        local space = box.schema.space.create(shape.space, { format = Module.format_of(shape, sharded) })

        for _, index in ipairs(shape.indexes) do
            local parts = {}

            for _, name in ipairs(index.parts) do
                table.insert(parts, part_of(shape.by_name[name]))
            end

            space:create_index(index.name, { parts = parts, unique = index.unique })
        end

        -- Индекс по бакету обязателен: без него vshard не переносит бакеты.
        if sharded and shape.bucket_of ~= nil then
            space:create_index(shapes.BUCKET_FIELD, {
                parts = { { field = shapes.BUCKET_FIELD, type = 'unsigned' } },
                unique = false,
            })
        end
    end
end

return Module
