--- Выборка по индексу: `where`, `scan`, страница, счёт.
---
--- Выборка только по индексу — и это ошибка программиста, если индекса
--- по полю нет: полный перебор в спейсе с миллионом записей не должен
--- случаться из-за опечатки. Полный обход — только явным `scan()`,
--- и он тоже идёт страницами: без `limit` страница равна `LIMIT`,
--- а не «всё».
---
--- Страница продолжается по записи: `after(last)` — последняя запись
--- предыдущей страницы, из неё берутся части индекса и первичный ключ.
--- Так страница не зависит от вставок между запросами и одинаково
--- считается на одном узле и слиянием с нескольких хранилищ.

local validate = require('tnt.validate')

local check = require('tnt.model.check')
local failure = require('tnt.model.failure')
local shapes = require('tnt.model.shape')

--- Отказ без места вызова.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Страница по умолчанию: столько записей отдаёт `all()` без `limit`.
Module.LIMIT = 100

--- Итераторы box по знаку сравнения.
---@type table<string, string>
Module.OPERATORS = { ['='] = 'EQ', ['>'] = 'GT', ['>='] = 'GE', ['<'] = 'LT', ['<='] = 'LE', between = 'GE' }

--- Итераторы, которые принимает выборка с провода.
---@type table<string, boolean>
local ITERATORS = { EQ = true, GT = true, GE = true, LT = true, LE = true, ALL = true }

---@class TntModelQuery
---@field model TntModel
---@field spec TntModelQuerySpec
---@field refusal TntModelFailure|nil Отказ по значению условия — отдаётся вместо результата
local Query = {}
Query.__index = Query

--- Записей на странице.
---@param count integer
---@return TntModelQuery
function Query:limit(count)
    if type(count) ~= 'number' or count < 1 or count % 1 ~= 0 then
        fail(
            ('модель %s: limit — натуральное число, а не %s'):format(
                self.model.space,
                tostring(count)
            )
        )
    end

    self.spec.limit = count

    return self
end

--- Продолжить после записи: части индекса и первичный ключ берутся из неё.
---@param last table Запись либо таблица с нужными полями
---@return TntModelQuery
function Query:after(last)
    if type(last) ~= 'table' then
        fail(('модель %s: after — запись, а не %s'):format(self.model.space, type(last)))
    end

    local shape = self.model._shape
    local index = assert(shapes.index_of(shape, self.spec.index))
    local cursor = {}

    for _, names in ipairs({ index.parts, shape.primary }) do
        for _, name in ipairs(names) do
            if last[name] == nil then
                fail(('модель %s: в after нет поля %s'):format(shape.space, name))
            end

            cursor[name] = last[name]
        end
    end

    self.spec.after = cursor

    return self
end

--- Страница записей.
---@return TntModelRecord[]|nil records
---@return TntModelFailure|nil err
function Query:all()
    if self.refusal ~= nil then
        return nil, self.refusal
    end

    local rows, err = self.model._gateway().select(self.model._shape, self.spec)

    if rows == nil then
        return nil, err
    end

    for position, row in ipairs(rows) do
        rows[position] = self.model._wrap(row)
    end

    return rows
end

--- Первая запись страницы; пусто — нет ни одной.
---@return TntModelRecord|nil record
---@return TntModelFailure|nil err
function Query:first()
    self.spec.limit = 1

    local rows, err = self:all()

    if rows == nil then
        return nil, err
    end

    return rows[1]
end

--- Сколько записей подходит под условие — без страницы и `after`.
---@return integer|nil count
---@return TntModelFailure|nil err
function Query:count()
    if self.refusal ~= nil then
        return nil, self.refusal
    end

    return self.model._gateway().count(self.model._shape, self.spec)
end

--- Значение условия, проверенное правилом поля; отказ — вместо результата.
---@param model TntModel
---@param field TntModelField
---@param value any
---@return any checked
---@return TntModelFailure|nil err
local function checked(model, field, value)
    local ready, errors = validate.check(value, model._rule(field.name))

    if errors ~= nil then
        return nil, failure.invalid(model.space, { [field.name] = errors[check.WHOLE] })
    end

    return ready
end

--- Выборка по условию на поле индекса.
---@param model TntModel
---@param field string
---@param op string =, >, >=, <, <=, between
---@param value any Значение либо пара { от, до } для between
---@return TntModelQuery
function Module.where(model, field, op, value)
    local shape = model._shape
    local index = shapes.index_for(shape, field)
    local iterator = Module.OPERATORS[op]

    if iterator == nil then
        fail(
            ('модель %s: условие %s неизвестно; есть =, >, >=, <, <=, between'):format(
                shape.space,
                tostring(op)
            )
        )
    end

    local query = setmetatable({
        model = model,
        spec = { index = index.name, iterator = iterator, key = {}, limit = Module.LIMIT },
    }, Query)

    local bounds = { value }

    -- Границы считаются числом, а не обходом `ipairs`: пустое значение
    -- обход бы пропустил, и `where('age', '>=', nil)` без отказа ушёл бы
    -- полным обходом с пустым ключом.
    local count = 1

    if op == 'between' then
        if type(value) ~= 'table' or #value ~= 2 then
            fail(('модель %s: between ждёт пару { от, до }'):format(shape.space))
        end

        -- Копия: пара пришла от вызывающего, и приведённые значения
        -- не должны менять её под ним.
        bounds = { value[1], value[2] }
        count = 2
    end

    for position = 1, count do
        local ready, err = checked(model, shape.by_name[field], bounds[position])

        if ready == nil then
            query.refusal = err

            return query
        end

        bounds[position] = ready
    end

    query.spec.key = { bounds[1] }
    query.spec.to = bounds[2]

    return query
end

--- Полный обход по первичному ключу — страницами.
---@param model TntModel
---@return TntModelQuery
function Module.scan(model)
    return setmetatable({
        model = model,
        spec = { index = shapes.PRIMARY_INDEX, iterator = 'ALL', key = {}, limit = Module.LIMIT },
    }, Query)
end

--- Выборка, пришедшая с провода, проверенная по форме.
---
--- Ошибка здесь — ошибка вызывающего кода, а не данных: свои шлюзы
--- собирают выборку сами, чужой вызов по `lua_call` — чужая ошибка.
---@param shape TntModelShape
---@param spec any
---@return TntModelQuerySpec
function Module.checked(shape, spec)
    if
        type(spec) ~= 'table'
        or shapes.index_of(shape, spec.index) == nil
        or not ITERATORS[spec.iterator]
        or type(spec.key) ~= 'table'
        or type(spec.limit) ~= 'number'
        or (spec.after ~= nil and type(spec.after) ~= 'table')
    then
        fail(
            ('модель %s: выборка не по форме: index, iterator, key, limit, after'):format(
                shape.space
            )
        )
    end

    return spec
end

return Module
