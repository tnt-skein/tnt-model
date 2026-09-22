--- Фабрика записей для проверок.
---
--- Годная запись по умолчанию, поля перебиваются аргументом. Значения
--- считаются от порядкового номера: два вызова одной проверки дают
--- разные ключи и не сталкиваются. Умолчания по роду поля годятся
--- большинству моделей; кому нужны свои — объявляет `factory`
--- в модели, и она перебивает умолчания по роду, а аргумент — её.

local uuid = require('uuid')

--- Длина строки меряется знаками: средство то же, что у правила строки.
---@type any
local letters = rawget(_G, 'utf8')

local Module = {}

--- Число в границах поля: номер по порядку, прижатый к `min`/`max`.
---
--- Номер прижимается `math.max`/`math.min`, а не сравнением: у номера,
--- равного границе, строгое и нестрогое сравнение дают один ответ,
--- и поломку знака не заметила бы ни одна проверка.
---@param field TntModelField
---@param sequence integer
---@return number
local function bounded_number(field, sequence)
    ---@type number
    local value = sequence

    if field.min ~= nil then
        value = math.max(value, field.min)
    end

    if field.max ~= nil then
        value = math.min(value, field.max)
    end

    return value
end

--- Строка по имени поля и номеру, по длине в границах поля.
---
--- Слишком короткая дописывается знаком `x`, слишком длинная теряет
--- начало: номер записи стоит в конце, и срез с конца оставляет его,
--- а срез с начала дал бы всем записям с коротким `max` одну голову,
--- и ключи столкнулись бы. Длина считается знаками, как у правила строки.
---@param field TntModelField
---@param sequence integer
---@return string
local function bounded_string(field, sequence)
    if field.one_of ~= nil then
        return field.one_of[1]
    end

    local value = ('%s %d'):format(field.name, sequence)

    -- Недостача у строки не короче `min` не больше нуля, и `string.rep`
    -- отдаёт тогда пустую строку: сравнивать длину заранее незачем.
    if field.min ~= nil then
        local missing = math.ceil(field.min) - letters.len(value) --[[@as integer]]

        value = value .. string.rep('x', missing)
    end

    -- Срез последних `max` знаков строку не длиннее `max` не меняет.
    -- Начало отрицательное, а не счёт от единицы: у `sub(value, 1, max)`
    -- сдвиг единицы в ноль неотличим. Поле короче одного знака годно
    -- только пустым, а срез с `-0` отдал бы строку целиком.
    if field.max ~= nil then
        value = field.max < 1 and '' or letters.sub(value, -field.max)
    end

    return value
end

--- Значение поля по его роду.
---@param field TntModelField
---@param sequence integer
---@return any
local function value_of(field, sequence)
    if field.type == 'string' then
        return bounded_string(field, sequence)
    end

    if field.type == 'boolean' then
        return false
    end

    if field.type == 'uuid' then
        return uuid.str()
    end

    return bounded_number(field, sequence)
end

--- Значения записи: умолчания по роду, поверх — фабрика модели, поверх — аргумент.
---
--- Необязательные поля без умолчания остаются пустыми: запись «по
--- умолчанию» — это наименьшая годная запись, а не заполненная до отказа.
---@param shape TntModelShape
---@param sequence integer
---@param overrides table|nil
---@return table
function Module.values_of(shape, sequence, overrides)
    local values = {}

    for _, field in ipairs(shape.fields) do
        if not field.optional then
            values[field.name] = value_of(field, sequence)
        end
    end

    local layers = { overrides or {} }

    if shape.factory ~= nil then
        table.insert(layers, 1, shape.factory(sequence))
    end

    for _, layer in ipairs(layers) do
        for key, value in pairs(layer) do
            values[key] = value
        end
    end

    return values
end

return Module
