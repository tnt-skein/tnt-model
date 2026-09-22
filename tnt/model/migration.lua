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

local shapes = require('tnt.model.shape')
local topology = require('tnt.model.topology')
local tuple = require('tnt.model.tuple')

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

--- Шаг миграции: спейс, первичный индекс, индексы модели, индекс бакета.
---@param shape TntModelShape
---@return fun(box: table)
function Module.step(shape)
    return function(box)
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
