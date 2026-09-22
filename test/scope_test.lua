--- Условия областей: разбор объявления, сверка записи, проверка
--- условий с провода.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.scope')

---@type any
local model

---@type any
local scopes

g.before_each(function()
    model = helper.load()
    scopes = helper.module('tnt.model.scope')
end)

g.after_each(helper.unload)

--- Модель пользователей: её форма и правила значений условий.
---@return any User
local function users()
    return helper.users(model)
end

--- Условия области пользователей по объявлению.
---@param entries any
---@return any conditions
---@return any err
local function conditions(entries)
    local User = users()

    return scopes.conditions_of(User._shape, User._rule, 'adults', entries)
end

g.test_conditions_are_checked_and_brought_to_the_field = function()
    t.assert_equals(conditions({ { 'age', '>=', 18 }, { 'name', '=', ' Мария ' } }), {
        { field = 'age', op = '>=', value = 18 },
        { field = 'name', op = '=', value = ' Мария ' },
    })
    t.assert_equals(conditions({ { 'email', '=', nil }, { 'email', '~=' } }), {
        { field = 'email', op = '=' },
        { field = 'email', op = '~=' },
    })
    t.assert_equals(conditions({}), {})
end

-- Значение `=` и `~=` — значение поля, и проверяется оно всем правилом:
-- записи с негодным значением быть не может. Значение остальных знаков —
-- граница, и от правила у неё только род, как у `where`.
g.test_equality_checks_the_whole_rule_and_bounds_only_the_kind = function()
    t.assert_equals(conditions({ { 'age', '<', 200 }, { 'age', '>=', 151 }, { 'name', '>', '' } }), {
        { field = 'age', op = '<', value = 200 },
        { field = 'age', op = '>=', value = 151 },
        { field = 'name', op = '>', value = '' },
    })
    t.assert_equals(conditions({ { 'age', '<=', 200 }, { 'age', '>', 200 } })[2].value, 200)

    for index, case in ipairs({
        { { 'age', '=', 200 }, 'должно быть целым числом от 0 до 150, а не 200' },
        { { 'age', '~=', 151 }, 'должно быть целым числом от 0 до 150, а не 151' },
        { { 'age', '<', -1 }, 'должно быть целым числом не меньше 0, а не -1' },
        { { 'age', '>', 1.5 }, 'должно быть целым числом не меньше 0, а не 1.5' },
    }) do
        local none, err = conditions({ case[1] })

        t.assert_equals(none, nil, ('случай №%d'):format(index))
        t.assert_equals(err.fields, { age = case[2] }, ('случай №%d'):format(index))
    end

    t.assert_equals(select(2, conditions({ { 'name', '=', '' } })).fields, {
        name = 'должно быть строкой длиной от 1 до 255 знаков, а сейчас 0 знаков',
    })
end

g.test_bad_value_is_a_refusal_not_a_throw = function()
    local none, err = conditions({ { 'age', '>=', 18 }, { 'age', '<', 'много' } })

    t.assert_equals(none, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(
        err.fields,
        { age = "должно быть целым числом не меньше 0, а не 'много'" }
    )
    t.assert_equals(
        tostring(err),
        "условие выборки users: age — должно быть целым числом не меньше 0, а не 'много'"
    )

    -- Пустое значение осмысленно только для = и ~=: «меньше пустого»
    -- не бывает, и это отказ, как у where.
    local _, empty = conditions({ { 'age', '<' } })

    t.assert_equals(empty.fields, { age = 'обязательное поле' })
end

g.test_bad_condition_is_a_programmer_error = function()
    local expected = 'модель users: область adults — список условий { поле, знак, значение }: '
        .. 'поле из объявления, знак =, ~=, <, <=, >, >='

    for index, entries in ipairs({
        { 'age' },
        { { 'years', '=', 1 } },
        { { 'age', 'like', 1 } },
        { { 'age', '=', 1 }, { 'age' } },
    }) do
        t.assert_error_msg_equals(expected, conditions, entries, ('случай №%d'):format(index))
    end

    t.assert_error_msg_equals(
        'модель users: область adults — список условий, а не string',
        conditions,
        'age'
    )
end

--- Подходит ли запись под одно условие.
---@param op string
---@param value any Значение условия
---@param age any Возраст записи
---@return boolean
local function matched(op, value, age)
    return scopes.matches({ { field = 'age', op = op, value = value } }, { id = 1, age = age })
end

g.test_each_operator_compares_like_the_index = function()
    -- Каждый знак — на записи меньше, равной и больше значения условия.
    local cases = {
        ['='] = { false, true, false },
        ['~='] = { true, false, true },
        ['<'] = { true, false, false },
        ['<='] = { true, true, false },
        ['>'] = { false, false, true },
        ['>='] = { false, true, true },
    }

    for op, expected in pairs(cases) do
        t.assert_equals({ matched(op, 30, 29), matched(op, 30, 30), matched(op, 30, 31) }, expected, op)
    end
end

g.test_empty_value_is_smallest_like_null_in_a_tree_index = function()
    t.assert_equals(matched('=', nil, nil), true)
    t.assert_equals(matched('=', nil, 5), false)
    t.assert_equals(matched('~=', nil, 5), true)
    t.assert_equals(matched('~=', nil, nil), false)
    t.assert_equals(
        matched('<', 18, nil),
        true,
        'записи без значения — первыми, как в индексе'
    )
    t.assert_equals(matched('>', 18, nil), false)
end

-- Не-число, записанное мимо модели, условие видит так же, как индекс:
-- раньше любого числа. Без своей ветки `<` на нём всегда ложно, и NaN
-- подходило бы под «равно 30».
g.test_nan_is_below_every_number_like_in_a_tree_index = function()
    local nan = 0 / 0

    t.assert_equals(matched('=', 30, nan), false)
    t.assert_equals(matched('~=', 30, nan), true)
    t.assert_equals(matched('<', 30, nan), true)
    t.assert_equals(matched('>=', 30, nan), false)
    t.assert_equals(matched('<', 30ULL, nan), true, 'и против целого cdata')
end

g.test_every_condition_must_match = function()
    local both = {
        { field = 'age', op = '>=', value = 18 },
        { field = 'name', op = '=', value = 'Мария' },
    }

    t.assert_equals(scopes.matches(both, { age = 20, name = 'Мария' }), true)
    t.assert_equals(scopes.matches(both, { age = 20, name = 'Иван' }), false)
    t.assert_equals(scopes.matches(both, { age = 10, name = 'Мария' }), false)
    t.assert_equals(scopes.matches({}, { age = 10 }), true)
end

g.test_wire_filter_names_known_fields_and_operators = function()
    local shape = users()._shape

    t.assert_equals(scopes.valid(shape, {}), true)
    t.assert_equals(
        scopes.valid(shape, { { field = 'age', op = '<=', value = 3 }, { field = 'email', op = '=' } }),
        true
    )

    for index, filter in ipairs({
        'age',
        { 'age' },
        { { field = 'years', op = '=' } },
        { { field = 'age', op = 'like' } },
        { { field = 'age', op = '=' }, { op = '=' } },
    }) do
        t.assert_equals(scopes.valid(shape, filter), false, ('случай №%d'):format(index))
    end
end
