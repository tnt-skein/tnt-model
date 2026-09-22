--- Области выборки: именованные условия на поля записи, которые
--- добавляются к выборке по индексу, — «только опубликованные»,
--- «без удалённых».
---
--- Условие — данные, а не функция: выборку исполняет узел с данными,
--- и через роутер и прослойку условие едет по проводу вместе с ней.
--- Функцией бывает только сама область с аргументами: она зовётся там,
--- где собирают выборку, и отдаёт условия.
---
--- Условие сравнивает значение поля записи в том же порядке, что индекс
--- TREE (`order.compare`): пустое значение необязательного поля меньше
--- любого. Поэтому `{ 'email', '=', nil }` — «почты нет», `{ 'email',
--- '~=', nil }` — «почта есть», а `{ 'age', '<', 18 }` берёт и записи
--- без возраста — так же, как `where('age', '<', 18)` по индексу.
---
--- Значение условия проверяется тем же правилом, что у `where`: при `=`
--- и `~=` — всем правилом поля, при остальных знаках — только родом,
--- это граница (`check.bound_rule_of`).

local check = require('tnt.model.check')
local order = require('tnt.model.order')

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Знаки условия: знак → проверка ответа `order.compare`.
---@type table<string, fun(verdict: integer): boolean>
local OPERATORS = {
    ['='] = function(verdict)
        return verdict == 0
    end,
    ['~='] = function(verdict)
        return verdict ~= 0
    end,
    ['<'] = function(verdict)
        return verdict < 0
    end,
    ['<='] = function(verdict)
        return verdict <= 0
    end,
    ['>'] = function(verdict)
        return verdict > 0
    end,
    ['>='] = function(verdict)
        return verdict >= 0
    end,
}

--- Знаки, при которых значение условия — значение поля, а не граница.
---
--- Пустое значение при них осмысленно — «нет значения» и «есть
--- значение», — а непустое проверяется всем правилом поля: записи
--- с негодным значением быть не может, и такое условие — ошибка.
--- Остальным знакам пустота — отказ «обязательное поле», как у `where`,
--- а от правила поля у их границы только род.
---@type table<string, boolean>
local EXACT = { ['='] = true, ['~='] = true }

---@class TntModelCondition Условие области: поле, знак, значение
---@field field string
---@field op string =, ~=, <, <=, >, >=
---@field value any Пусто — сравнение с отсутствием значения

--- Значение условия, проверенное правилом поля по знаку; отказ — вместо
--- него. Пусто без отказа — пустое значение при `=` либо `~=`.
---
--- Одно на условие области и на условие, пришедшее по проводу: узел
--- с данными проверяет его заново тем же правилом, что и модель у себя.
---@param shape TntModelShape
---@param rule_of fun(name: string, exact: boolean): TntValidateRule Правило значения выборки по имени поля
---@param field string
---@param op string
---@param value any
---@return any ready
---@return TntModelFailure|nil err
function Module.value_of(shape, rule_of, field, op, value)
    local exact = EXACT[op] == true

    if value == nil and exact then
        return nil
    end

    return check.query_value(shape.space, field, rule_of(field, exact), value)
end

--- Условие по объявлению `{ поле, знак, значение }`.
---
--- Негодное поле или знак — ошибка программиста: условие написано
--- в объявлении либо собрано функцией области. Негодное значение —
--- отказ `invalid`: у области с аргументами оно пришло снаружи.
---@param shape TntModelShape
---@param rule_of fun(name: string, exact: boolean): TntValidateRule Правило значения выборки по имени поля
---@param name string Имя области — для текста
---@param entry any
---@return TntModelCondition|nil condition
---@return TntModelFailure|nil err
local function condition_of(shape, rule_of, name, entry)
    if type(entry) ~= 'table' or shape.by_name[entry[1]] == nil or OPERATORS[entry[2]] == nil then
        local expected =
            'список условий { поле, знак, значение }: поле из объявления, знак =, ~=, <, <=, >, >='

        fail(('модель %s: область %s — %s'):format(shape.space, name, expected))
    end

    local field, op = entry[1], entry[2]
    local value, err = Module.value_of(shape, rule_of, field, op, entry[3])

    if err ~= nil then
        return nil, err
    end

    return { field = field, op = op, value = value }
end

--- Условия области по её объявлению: список `{ поле, знак, значение }`.
---@param shape TntModelShape
---@param rule_of fun(name: string, exact: boolean): TntValidateRule
---@param name string Имя области — для текста
---@param entries any
---@return TntModelCondition[]|nil conditions
---@return TntModelFailure|nil err
function Module.conditions_of(shape, rule_of, name, entries)
    if type(entries) ~= 'table' then
        fail(
            ('модель %s: область %s — список условий, а не %s'):format(
                shape.space,
                name,
                type(entries)
            )
        )
    end

    local conditions = {}

    for position, entry in ipairs(entries) do
        local condition, err = condition_of(shape, rule_of, name, entry)

        if condition == nil then
            return nil, err
        end

        conditions[position] = condition
    end

    return conditions
end

--- Подходит ли запись под все условия.
---@param conditions TntModelCondition[]
---@param row table Значения записи
---@return boolean
function Module.matches(conditions, row)
    for _, condition in ipairs(conditions) do
        local verdict = order.compare(row[condition.field], condition.value)

        if not OPERATORS[condition.op](verdict) then
            return false
        end
    end

    return true
end

--- Годятся ли условия, пришедшие по проводу: список, поле из формы,
--- знак известен.
---@param shape TntModelShape
---@param filter any
---@return boolean
function Module.valid(shape, filter)
    if type(filter) ~= 'table' then
        return false
    end

    for _, condition in ipairs(filter) do
        if type(condition) ~= 'table' or shape.by_name[condition.field] == nil or OPERATORS[condition.op] == nil then
            return false
        end
    end

    return true
end

return Module
