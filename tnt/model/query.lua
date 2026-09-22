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
---
--- Страница по номеру — смещением: `offset(n)` пропускает n записей.
--- На узле с данными это дёшево — индекс TREE пропускает записи, не читая
--- их, — а через роутер vshard каждое хранилище отдаёт `n + limit` своих
--- записей: сколько из пропущенных лежит у соседей, оно не знает.
---
--- Области (`scope`) и мягкое удаление сужают выборку условиями на поля
--- записи: условия едут вместе с выборкой к узлу с данными, и тот берёт
--- записи индекса кусками и отбирает подходящие. Страница, смещение
--- и `after` считают только подошедшие записи.
---
--- Значение выборки проверяется по тому, чем оно служит. Искомое
--- значение — `=` у `where` и `EQ` с провода — всем правилом поля:
--- записи с негодным значением быть не может, и такой запрос — ошибка
--- клиента. Граница диапазона и курсор `after` — только родом поля
--- (`check.bound_rule_of`): это место в порядке индекса, а не значение
--- записи. Правило одно у модели и у функций узла с данными: выборка,
--- которую модель собрала, узел примет, а чужую негодную не пропустит.

local validate = require('tnt.validate')

local check = require('tnt.model.check')
local failure = require('tnt.model.failure')
local order = require('tnt.model.order')
local scopes = require('tnt.model.scope')
local shapes = require('tnt.model.shape')
local stamps = require('tnt.model.stamp')

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

--- Самое большое смещение и самая длинная страница: `box` держит оба
--- в 32 битах и большее молча обрезает — смещение 2^32 отдало бы первую
--- страницу, а `limit(2^32 + 5)` — пять записей (сверено на 3.8).
Module.OFFSET = 2 ^ 32 - 1

--- Мягко удалённые записи в выборке: только живые, все, только удалённые.
local ALIVE, EVERY, DELETED = 'alive', 'every', 'deleted'

--- Целое ли это от `low` до `Module.OFFSET`: годится ли значение
--- смещением (от нуля) либо размером страницы (от единицы).
---@param value any
---@param low integer
---@return boolean
local function is_count(value, low)
    return type(value) == 'number' and value >= low and value <= Module.OFFSET and value % 1 == 0
end

--- Размер страницы и смещение с провода — те же пределы, что у `limit`
--- и `offset`, но правилом: негодное значение с провода — отказ
--- `invalid` с текстом `tnt-validate`, а не исключение.
local PAGE = validate.integer({ min = 1, max = Module.OFFSET })
local SKIP = validate.integer({ min = 0, max = Module.OFFSET, optional = true })

--- Значение выборки, проверенное на месте; отказ — вместо правки.
---
--- Проверенное ложится туда же, откуда взято: при приведении типов
--- `tnt-validate` оно другое, и `box` должен получить его, а не вход.
---@param target table Где лежит значение: выборка, ключ, курсор
---@param slot any Где в ней
---@param space string Имя спейса — для текста
---@param name string Место отказа: имя поля либо настройки выборки
---@param rule TntValidateRule
---@return TntModelFailure|nil
local function settled(target, slot, space, name, rule)
    local ready, err = check.query_value(space, name, rule, target[slot])

    if err == nil then
        target[slot] = ready
    end

    return err
end

--- Курсор `after`, проверенный родом полей на месте; отказ — по первому
--- негодному полю: части индекса, затем первичного ключа.
---
--- Курсор приходит от клиента, как и граница `where`, — у модели
--- и с провода. Без проверки строка в числовом поле доходила бы до `box`,
--- тот бросал «Iterator position is invalid», и вызывающий получал
--- на узле с данными исключение, а через роутер — `unavailable`, ложную
--- беду хранилища вместо ошибки клиента.
---
--- Пустое значение необязательного поля — не отказ, а место в индексе:
--- запись без почты стоит в индексе `email` на месте NULL, и страница,
--- кончившаяся ею, продолжается от этого места. Пустота и `box.NULL`
--- здесь одно и то же — поля нет у записи, `null` пришёл из JSON либо
--- по проводу, — и кортеж курсора получает NULL (`tuple.cursor_of`).
--- У обязательного поля пустота по-прежнему отказ «обязательное поле»:
--- такой записи в индексе нет.
---@param model TntModel
---@param index TntModelIndex
---@param cursor table
---@return TntModelFailure|nil
local function positioned(model, index, cursor)
    local shape = model._shape

    for _, name in ipairs(order.names_of(shape, index)) do
        if cursor[name] ~= nil or not shape.by_name[name].optional then
            local err = settled(cursor, name, model.space, name, model._rule(name, false))

            if err ~= nil then
                return err
            end
        end
    end

    return nil
end

---@class TntModelQuery
---@field model TntModel
---@field spec TntModelQuerySpec
---@field refusal TntModelFailure|nil Отказ по значению условия, области либо курсора — отдаётся вместо результата
---@field conditions TntModelCondition[] Условия областей
---@field deleted string Какие записи по мягкому удалению: alive, every, deleted
local Query = {}
Query.__index = Query

--- Выборка по готовому описанию: без областей, только живые записи.
---@param model TntModel
---@param spec TntModelQuerySpec
---@return TntModelQuery
local function new(model, spec)
    return setmetatable({ model = model, spec = spec, conditions = {}, deleted = ALIVE }, Query)
end

--- Описание выборки для шлюза: условия областей и мягкого удаления.
---
--- Собирается при каждом исполнении, а не копится вызовами: `all()`
--- на той же выборке дважды не удвоит условие удаления. Без условий
--- поля `filter` нет вовсе — шлюз идёт прежним путём, одним `select`.
---@param query TntModelQuery
---@return TntModelQuerySpec
local function spec_of(query)
    local filter = {}

    for _, condition in ipairs(query.conditions) do
        table.insert(filter, condition)
    end

    local deleted = query.model._shape.stamps[stamps.DELETED]

    if deleted ~= nil and query.deleted ~= EVERY then
        table.insert(filter, { field = deleted, op = query.deleted == DELETED and '~=' or '=' })
    end

    query.spec.filter = filter[1] ~= nil and filter or nil

    return query.spec
end

--- Добавить область: её условия сужают выборку.
---
--- Негодный аргумент области — отказ `invalid` из `all()`, `first()`
--- и `count()`, как негодное значение `where`: он пришёл снаружи.
--- Незнакомая область — ошибка программиста.
---@param name string
---@param ... any Аргументы области-функции
---@return TntModelQuery
function Query:scope(name, ...)
    local conditions, err = self.model._scope(name, ...)

    if conditions == nil then
        self.refusal = err

        return self
    end

    for _, condition in ipairs(conditions) do
        table.insert(self.conditions, condition)
    end

    return self
end

--- Выборка по мягкому удалению; у модели без него — ошибка программиста.
---@param query TntModelQuery
---@param mode string
---@param name string Имя метода — для текста
---@return TntModelQuery
local function trashed(query, mode, name)
    if query.model._shape.stamps[stamps.DELETED] == nil then
        fail(
            ('модель %s: %s — только у модели с мягким удалением, model.deleted_at()'):format(
                query.model.space,
                name
            )
        )
    end

    query.deleted = mode

    return query
end

--- Вместе с мягко удалёнными записями.
---@return TntModelQuery
function Query:with_deleted()
    return trashed(self, EVERY, 'with_deleted')
end

--- Только мягко удалённые записи.
---@return TntModelQuery
function Query:only_deleted()
    return trashed(self, DELETED, 'only_deleted')
end

--- Записей на странице.
---@param count integer
---@return TntModelQuery
function Query:limit(count)
    if not is_count(count, 1) then
        fail(
            ('модель %s: limit — целое число от 1 до %d, а не %s'):format(
                self.model.space,
                Module.OFFSET,
                tostring(count)
            )
        )
    end

    self.spec.limit = count

    return self
end

--- Пропустить записи от начала выборки: страница по номеру.
---
--- Смещение складывается с `after`: `after(last):offset(n)` пропускает
--- n записей после курсора.
---@param count integer
---@return TntModelQuery
function Query:offset(count)
    if not is_count(count, 0) then
        fail(
            ('модель %s: offset — целое число от 0 до %d, а не %s'):format(
                self.model.space,
                Module.OFFSET,
                tostring(count)
            )
        )
    end

    self.spec.offset = count

    return self
end

--- Продолжить после записи: части индекса и первичный ключ берутся из неё.
---
--- Курсор — граница, и проверяется он родом полей (`positioned`):
--- негодное значение — отказ `invalid` из `all()`, `first()` и `count()`.
---
--- Обязательного поля нет вовсе — ошибка программиста: у записи
--- страницы оно есть всегда. Необязательного может не быть — у записи
--- без значения его и нет, — и это место NULL в индексе, а не ошибка:
--- иначе страница, кончившаяся такой записью, не продолжалась бы.
--- Отсутствие проверяется у всех полей до значений: ошибка кода
--- не прячется за отказом по данным.
---@param last table Запись либо таблица с нужными полями
---@return TntModelQuery
function Query:after(last)
    if type(last) ~= 'table' then
        fail(('модель %s: after — запись, а не %s'):format(self.model.space, type(last)))
    end

    local shape = self.model._shape
    local index = assert(shapes.index_of(shape, self.spec.index))

    -- Копия: запись пришла от вызывающего, и приведённые значения
    -- не должны менять её под ним.
    local cursor = {}

    for _, name in ipairs(order.names_of(shape, index)) do
        -- Типом, а не сравнением с nil: `box.NULL == nil` истинно,
        -- а пустота из JSON — значение клиента: у обязательного поля
        -- отказ по ней — `invalid` «обязательное поле», как у `where`,
        -- у необязательного — место NULL (`positioned`).
        if type(last[name]) == 'nil' and not shape.by_name[name].optional then
            fail(('модель %s: в after нет поля %s'):format(shape.space, name))
        end

        cursor[name] = last[name]
    end

    local refusal = positioned(self.model, index, cursor)

    if refusal ~= nil then
        self.refusal = refusal
    else
        self.spec.after = cursor
    end

    return self
end

--- Страница записей.
---@return TntModelRecord[]|nil records
---@return TntModelFailure|nil err
function Query:all()
    if self.refusal ~= nil then
        return nil, self.refusal
    end

    local rows, err = self.model._gateway().select(self.model._shape, spec_of(self))

    if rows == nil then
        return nil, err
    end

    for position, row in ipairs(rows) do
        rows[position] = self.model._loaded(row)
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

--- Сколько записей подходит под условие — без страницы, `after` и `offset`.
---@return integer|nil count
---@return TntModelFailure|nil err
function Query:count()
    if self.refusal ~= nil then
        return nil, self.refusal
    end

    return self.model._gateway().count(self.model._shape, spec_of(self))
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

    local query = new(model, { index = index.name, iterator = iterator, key = {}, limit = Module.LIMIT })

    local bounds = { value }

    -- Границы считаются числом, а не обходом `ipairs`: пустое значение
    -- обход бы пропустил, и `where('age', '>=', nil)` без отказа ушёл бы
    -- полным обходом с пустым ключом.
    local count = 1

    -- Искомое значение — только у равенства; у остальных знаков граница.
    local exact = op == '='

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
        local err = settled(bounds, position, model.space, field, model._rule(field, exact))

        if err ~= nil then
            query.refusal = err

            return query
        end
    end

    query.spec.key = { bounds[1] }
    query.spec.to = bounds[2]

    return query
end

--- Полный обход по первичному ключу — страницами.
---@param model TntModel
---@return TntModelQuery
function Module.scan(model)
    return new(model, { index = shapes.PRIMARY_INDEX, iterator = 'ALL', key = {}, limit = Module.LIMIT })
end

--- Ключ выборки с провода, проверенный на месте; отказ — по первой
--- негодной части.
---
--- Частей не больше, чем у индекса: лишнюю `box` не примет. У `EQ`
--- части — искомые значения; у остальных итераторов — границы, и у `ALL`
--- с ключом тоже: `box` ведёт его от ключа, как `GE` (сверено на 3.8).
---@param model TntModel
---@param index TntModelIndex
---@param spec TntModelQuerySpec
---@return TntModelFailure|nil
local function keyed(model, index, spec)
    local key = spec.key
    local size = 0

    -- Считаются все ключи таблицы, а не `#`: дыра либо имя среди частей
    -- сдвигают счёт, и часть на пропущенном месте выходит пустой — отказ
    -- «обязательное поле», а не молчаливый обход с другим ключом.
    for _ in pairs(key) do
        size = size + 1
    end

    if size > #index.parts then
        return failure.invalid_query(model.space, {
            [check.WHOLE] = ('ключ по индексу %s — не больше частей, чем у индекса: %s'):format(
                index.name,
                table.concat(index.parts, ', ')
            ),
        })
    end

    local exact = spec.iterator == 'EQ'

    for position = 1, size do
        local name = index.parts[position] --[[@as string]]
        local err = settled(key, position, model.space, name, model._rule(name, exact))

        if err ~= nil then
            return err
        end
    end

    return nil
end

--- Значения условий областей с провода, проверенные на месте.
---@param model TntModel
---@param filter TntModelCondition[]
---@return TntModelFailure|nil
local function filtered(model, filter)
    for _, condition in ipairs(filter) do
        local value, err = scopes.value_of(model._shape, model._rule, condition.field, condition.op, condition.value)

        if err ~= nil then
            return err
        end

        condition.value = value
    end

    return nil
end

--- Первое негодное значение выборки с провода; пусто — годны все.
---@param model TntModel
---@param index TntModelIndex
---@param spec TntModelQuerySpec
---@return TntModelFailure|nil
local function refusal_of(model, index, spec)
    local space = model.space
    local part = index.parts[1] --[[@as string]]

    return settled(spec, 'limit', space, 'limit', PAGE)
        or settled(spec, 'offset', space, 'offset', SKIP)
        or keyed(model, index, spec)
        or (spec.to ~= nil and settled(spec, 'to', space, part, model._rule(part, false)))
        or (spec.after ~= nil and positioned(model, index, spec.after))
        or (spec.filter ~= nil and filtered(model, spec.filter))
        or nil
end

--- Выборка, пришедшая с провода: форма и значения.
---
--- Форма — индекс и итератор из известных, ключ, курсор и условия
--- таблицами, поле и знак условия из формы. Негодная форма — ошибка
--- вызывающего кода, и это исключение: свои шлюзы собирают выборку сами,
--- чужой вызов по `lua_call` — чужая ошибка.
---
--- Значения — части ключа, граница `to`, курсор `after`, значения
--- условий, страница и смещение — проверяются теми же правилами, что
--- у `where`, `after`, областей, `limit` и `offset`. Негодное — отказ
--- `invalid`, а не исключение: узел с данными не верит вызывающему,
--- а значение могло прийти от клиента. Без проверки строка в числовом
--- ключе бросала бы «Supplied key type … does not match», граница `to` —
--- «attempt to compare number with string», а `limit = -1` отдавал бы
--- весь спейс. Проверенные значения ложатся в ту же выборку.
---@param model TntModel
---@param spec any
---@return TntModelQuerySpec|nil spec
---@return TntModelFailure|nil err
function Module.checked(model, spec)
    local shape = model._shape
    local index = type(spec) == 'table' and shapes.index_of(shape, spec.index) or nil

    if
        index == nil
        or not ITERATORS[spec.iterator]
        or type(spec.key) ~= 'table'
        or (spec.after ~= nil and type(spec.after) ~= 'table')
        or (spec.filter ~= nil and not scopes.valid(shape, spec.filter))
    then
        fail(
            ('модель %s: выборка не по форме: index, iterator, key, after, filter'):format(
                shape.space
            )
        )
    end

    local refusal = refusal_of(model, index, spec)

    if refusal ~= nil then
        return nil, refusal
    end

    return spec
end

return Module
