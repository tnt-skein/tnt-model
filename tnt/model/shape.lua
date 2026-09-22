--- Форма записи: объявление модели, проверенное при загрузке.
---
--- Из одного объявления следуют формат спейса, индексы, схема проверки
--- входа, разбор кортежа и фабрика. Ошибка в объявлении — ошибка
--- программиста, и падает она при загрузке модуля модели, а не на первом
--- запросе.
---
--- Поля объявляются списком, а не словарём, потому что порядок полей —
--- это формат спейса: у словаря Lua порядка нет, а поле, добавленное
--- в словарь, сдвинуло бы соседей в кортежах, которые уже лежат в базе.
--- Запись поля — `{ 'name', 'string', max = 255 }` либо
--- `{ name = 'name', type = 'string', max = 255 }`.

--- Отказ без места вызова: текст уходит в alerts при загрузке роли.
local fail = require('tnt.must.fail').raise

--- Проверки по имени без броска: отсюда текст отказа о незнакомой
--- настройке, общий со всеми пакетами, а бросок — свой, без места.
local explain = require('tnt.must').explain

local Module = {}

--- Имя поля шардирования: vshard требует ровно это имя.
Module.BUCKET_FIELD = 'bucket_id'

--- Имя первичного индекса.
Module.PRIMARY_INDEX = 'primary'

--- Роды полей: имя рода в объявлении → тип поля в формате спейса.
---@type table<string, string>
Module.TYPES = {
    unsigned = 'unsigned',
    integer = 'integer',
    number = 'number',
    string = 'string',
    boolean = 'boolean',
    uuid = 'uuid',
}

--- Настройки, которые понимает всякое поле.
---@type table<string, boolean>
local COMMON = { primary = true, optional = true, default = true }

--- Настройки по родам сверх общих.
---@type table<string, table<string, boolean>>
local BY_TYPE = {
    unsigned = { min = true, max = true },
    integer = { min = true, max = true },
    number = { min = true, max = true },
    string = { min = true, max = true, pattern = true, one_of = true, trim = true },
    boolean = {},
    uuid = {},
}

--- Настройки объявления модели.
---
--- Значения описаны как любые (`'?'`): описание держит набор ключей,
--- а каждое значение проверяется ниже своим текстом с именем модели.
local SETTINGS = { space = '?', fields = '?', indexes = '?', rules = '?', methods = '?', factory = '?' }

--- Методы записи, которые заняты пакетом.
---@type table<string, boolean>
Module.RECORD_METHODS = { save = true, delete = true, to_table = true }

---@class TntModelField
---@field name string
---@field type string Род: unsigned, integer, number, string, boolean, uuid
---@field primary boolean
---@field optional boolean
---@field default any
---@field min number|nil
---@field max number|nil
---@field pattern string|nil
---@field one_of any[]|nil
---@field trim boolean

---@class TntModelIndex
---@field name string
---@field parts string[] Имена полей
---@field unique boolean

---@class TntModelShape
---@field space string
---@field fields TntModelField[] Поля по порядку объявления, без поля шардирования
---@field by_name table<string, TntModelField>
---@field layout string[] Имена полей кортежа по порядку, вместе с полем шардирования
---@field primary string[] Имена полей первичного ключа
---@field bucket_of string|nil Поле, от которого считается бакет; пусто — модель без ключа шардирования
---@field indexes TntModelIndex[] Первичный первым, остальные по имени
---@field rules (fun(record: table): string|nil, string|nil)[]
---@field methods table<string, function>
---@field factory (fun(sequence: integer): table)|nil

--- Имя — идентификатор: спейс и поля зовутся им и в формате, и в записи.
---@param name any
---@return boolean
local function is_name(name)
    return type(name) == 'string' and name:match('^[%a_][%w_]*$') ~= nil
end

--- Запись поля списком либо словарём — одним видом.
---@param space string
---@param index integer
---@param entry any
---@return TntModelField
local function field_of(space, index, entry)
    if type(entry) ~= 'table' then
        fail(('модель %s: поле №%d объявляется таблицей'):format(space, index))
    end

    local name = entry.name or entry[1]
    local kind = entry.type or entry[2]

    if not is_name(name) then
        fail(('модель %s: у поля №%d нет имени'):format(space, index))
    end

    if Module.TYPES[kind] == nil then
        fail(
            ('модель %s: у поля %s род %s, а бывает unsigned, integer, number, string, boolean, uuid'):format(
                space,
                tostring(name),
                tostring(kind)
            )
        )
    end

    local allowed = BY_TYPE[kind]

    for key in pairs(entry) do
        local known = key == 1 or key == 2 or key == 'name' or key == 'type' or COMMON[key] or allowed[key]

        if not known then
            fail(
                ('модель %s: поле %s не знает настройки %s'):format(
                    space,
                    tostring(name),
                    tostring(key)
                )
            )
        end
    end

    return {
        name = name,
        type = kind,
        primary = entry.primary == true,
        optional = entry.optional == true,
        default = entry.default,
        min = entry.min,
        max = entry.max,
        pattern = entry.pattern,
        one_of = entry.one_of,
        trim = entry.trim == true,
    }
end

--- Индексы по объявлению: первичный — из полей, остальные по имени.
---@param space string
---@param by_name table<string, TntModelField>
---@param primary string[]
---@param declared any
---@return TntModelIndex[]
local function indexes_of(space, by_name, primary, declared)
    local indexes = { { name = Module.PRIMARY_INDEX, parts = primary, unique = true } }
    local names = {}

    for name in pairs(declared or {}) do
        table.insert(names, name)
    end

    table.sort(names)

    for _, name in ipairs(names) do
        local index = declared[name]

        if not is_name(name) or name == Module.PRIMARY_INDEX or name == Module.BUCKET_FIELD then
            fail(('модель %s: имя индекса %s занято'):format(space, tostring(name)))
        end

        if type(index) ~= 'table' or type(index.parts) ~= 'table' or index.parts[1] == nil then
            fail(
                ('модель %s: у индекса %s нужны parts — список полей'):format(
                    space,
                    name
                )
            )
        end

        if type(index.unique) ~= 'boolean' then
            fail(('модель %s: у индекса %s нужно unique = true либо false'):format(space, name))
        end

        for _, part in ipairs(index.parts) do
            if by_name[part] == nil then
                fail(
                    ('модель %s: индекс %s по неизвестному полю %s'):format(
                        space,
                        name,
                        tostring(part)
                    )
                )
            end
        end

        table.insert(indexes, { name = name, parts = index.parts, unique = index.unique })
    end

    return indexes
end

--- Функции по именам: правила списком, методы словарём.
---@param space string
---@param what string
---@param declared any
---@return table
local function functions_of(space, what, declared)
    for key, fn in pairs(declared or {}) do
        if type(fn) ~= 'function' then
            fail(('модель %s: %s %s должно быть функцией'):format(space, what, tostring(key)))
        end
    end

    return declared or {}
end

--- Проверенная форма записи.
---@param spec any Объявление модели
---@return TntModelShape
function Module.of(spec)
    if type(spec) ~= 'table' or not is_name(spec.space) then
        fail('модель объявляется таблицей с именем спейса в space')
    end

    local space = spec.space
    local stray = explain.options(spec, ('модель %s'):format(space), SETTINGS)

    if stray ~= nil then
        fail(stray)
    end

    if type(spec.fields) ~= 'table' or spec.fields[1] == nil then
        fail(('модель %s: fields — непустой список полей'):format(space))
    end

    local fields, by_name, layout, primary = {}, {}, {}, {}
    local bucket_of = nil

    for index, entry in ipairs(spec.fields) do
        if type(entry) == 'table' and entry.bucket_of ~= nil then
            if bucket_of ~= nil then
                fail(('модель %s: ключ шардирования объявлен дважды'):format(space))
            end

            bucket_of = entry.bucket_of
            table.insert(layout, Module.BUCKET_FIELD)
        else
            local field = field_of(space, index, entry)

            if by_name[field.name] ~= nil or field.name == Module.BUCKET_FIELD then
                fail(('модель %s: поле %s объявлено дважды'):format(space, field.name))
            end

            if field.primary and (field.optional or field.default ~= nil) then
                fail(
                    ('модель %s: поле первичного ключа %s обязательно'):format(
                        space,
                        field.name
                    )
                )
            end

            table.insert(fields, field)
            table.insert(layout, field.name)
            by_name[field.name] = field

            if field.primary then
                table.insert(primary, field.name)
            end
        end
    end

    if primary[1] == nil then
        fail(('модель %s: нет поля с primary = true'):format(space))
    end

    if bucket_of ~= nil and (by_name[bucket_of] == nil or not by_name[bucket_of].primary) then
        fail(
            ('модель %s: ключ шардирования %s должен быть полем первичного ключа'):format(
                space,
                tostring(bucket_of)
            )
        )
    end

    local methods = functions_of(space, 'метод', spec.methods)

    for name in pairs(methods) do
        if Module.RECORD_METHODS[name] then
            fail(('модель %s: метод %s занят пакетом'):format(space, name))
        end
    end

    if spec.factory ~= nil and type(spec.factory) ~= 'function' then
        fail(('модель %s: factory должно быть функцией'):format(space))
    end

    return {
        space = space,
        fields = fields,
        by_name = by_name,
        layout = layout,
        primary = primary,
        bucket_of = bucket_of,
        indexes = indexes_of(space, by_name, primary, spec.indexes),
        rules = functions_of(space, 'правило', spec.rules),
        methods = methods,
        factory = spec.factory,
    }
end

--- Индекс по имени; пусто — нет такого.
---@param shape TntModelShape
---@param name string
---@return TntModelIndex|nil
function Module.index_of(shape, name)
    for _, index in ipairs(shape.indexes) do
        if index.name == name then
            return index
        end
    end

    return nil
end

--- Индекс, по которому ищут значение поля: первым звеном.
---
--- Точный индекс по одному полю берётся первым: страница по нему
--- не зависит от хвоста составного. Отказ называет индексы, по которым
--- искать можно, — иначе тот, кто написал `where` по неиндексированному
--- полю, полез бы в формат спейса.
---@param shape TntModelShape
---@param field string
---@return TntModelIndex
function Module.index_for(shape, field)
    ---@type TntModelIndex|nil
    local found = nil

    for _, index in ipairs(shape.indexes) do
        if index.parts[1] == field and (found == nil or #index.parts == 1) then
            found = index
        end
    end

    if found == nil then
        local names = {}

        for _, index in ipairs(shape.indexes) do
            table.insert(names, index.name .. ' (' .. table.concat(index.parts, ', ') .. ')')
        end

        fail(
            ('модель %s: по полю %s индекса нет; есть индексы %s'):format(
                shape.space,
                tostring(field),
                table.concat(names, ', ')
            )
        )
    end

    return found
end

return Module
