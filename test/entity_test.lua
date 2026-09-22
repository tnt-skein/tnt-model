--- Проверки модели над двойником шлюза: доступ, выборка, запись, фабрика.

local t = require('luatest')

local helper = dofile('test/helper.lua')

---@type any
local model

local g = helper.group('tnt.model.entity', function(loaded)
    model = loaded
end)

--- Отказы модели — модуль того же набора исходников.
---@return any
local function failure()
    return helper.module('tnt.model.failure')
end

--- Модель пользователей на двойнике шлюза.
---@param answers table|nil
---@return any User
---@return any calls
local function bound(answers)
    local User = helper.users(model)
    local gateway, calls = helper.fake_gateway(answers)

    User._bind(gateway)

    return User, calls
end

g.test_unbound_model_refuses_data_access_as_programmer_error = function()
    local User = helper.users(model)

    t.assert_equals(User.bound(), nil)
    t.assert_equals(model.is(User), true)
    t.assert_equals(model.is({}), false)
    t.assert_error_msg_equals(
        'модель users не привязана: узел ещё не применил конфигурацию',
        User.find,
        7
    )
    t.assert_error_msg_equals(
        'модель users не привязана: узел ещё не применил конфигурацию',
        User.create,
        { id = 1, name = 'a', age = 1 }
    )

    -- Проверка и фабрика данных не трогают и работают до привязки.
    t.assert_equals(User.validate({ id = 1, name = 'Мария', age = 1 }).id, 1)
    t.assert_equals(User.factory().id, 1)
end

g.test_unbound_model_names_the_reason_it_was_unbound_with = function()
    local User = helper.users(model)

    User._bind(helper.fake_gateway({}))
    User._bind(nil, 'привязка закрыта, новой нет')

    t.assert_equals(User.bound(), nil)
    t.assert_error_msg_equals(
        'модель users не привязана: привязка закрыта, новой нет',
        User.find,
        7
    )

    -- Привязка заново и отвязка без причины — снова прежний текст:
    -- причина принадлежит отвязке, а не модели навсегда.
    User._bind(helper.fake_gateway({}))
    User._bind(nil)

    t.assert_error_msg_equals(
        'модель users не привязана: узел ещё не применил конфигурацию',
        User.find,
        7
    )
end

g.test_find_checks_the_key_and_wraps_the_record = function()
    local User, calls = bound({ find = { id = 7, name = 'Мария', age = 46 } })
    local record, err = User.find(7)

    t.assert_equals(err, nil)
    t.assert_equals(record:is_adult(), true)
    t.assert_equals(calls, { { name = 'find', space = 'users', args = { { 7 } } } })
    t.assert_equals(User.bound(), 'fake')

    local missing, bad = User.find('abc')

    t.assert_equals(missing, nil)
    t.assert_equals(bad.kind, 'invalid')
    t.assert_equals(#calls, 1, 'негодный ключ до шлюза не доходит')

    local none, none_err = bound({}).find(8)

    t.assert_equals({ none, none_err }, { nil, nil })
end

g.test_find_passes_gateway_refusal = function()
    local refusal = failure().new('unavailable', 'нет связи')
    local User = bound({ find = { refusal = refusal } })
    local record, err = User.find(1)

    t.assert_equals(record, nil)
    t.assert_is(err, refusal)
end

g.test_create_validates_then_inserts = function()
    local User, calls = bound({ put = { id = 1, name = 'Мария', age = 46 } })
    local record, err = User.create({ id = 1, name = ' Мария ', age = 46 })

    t.assert_equals(err, nil)
    t.assert_equals(record:to_table(), { id = 1, name = 'Мария', age = 46 })
    t.assert_equals(
        calls[1],
        { name = 'put', space = 'users', args = { { id = 1, name = 'Мария', age = 46 }, 'insert' } }
    )

    local refused, bad = User.create({ id = 1, name = '', age = 46 })

    t.assert_equals(refused, nil)
    t.assert_equals(bad.kind, 'invalid')
    t.assert_equals(#calls, 1)

    local conflict = failure().new('conflict', 'занято')
    local _, taken = bound({ put = { refusal = conflict } }).create({ id = 1, name = 'a', age = 1 })

    t.assert_is(taken, conflict)
end

g.test_delete_by_key_and_by_record = function()
    local User, calls = bound({ delete = true, put = { id = 3, name = 'Анна', age = 19 } })

    t.assert_equals(User.delete(3), true)
    t.assert_equals(calls[1], { name = 'delete', space = 'users', args = { { 3 } } })

    local _, bad = User.delete({ 1, 2 })

    t.assert_equals(bad.kind, 'invalid')

    local record = User.validate({ id = 3, name = 'Анна', age = 19 })

    t.assert_equals(record:delete(), true)
    t.assert_equals(calls[2], { name = 'delete', space = 'users', args = { { 3 } } })
end

g.test_save_replaces_and_takes_stored_values_back = function()
    local User, calls = bound({ put = { id = 3, name = 'Анна', age = 19, email = 'a@x.ru' } })
    local record = User.validate({ id = 3, name = ' Анна ', age = 19 })
    local saved, err = record:save()

    t.assert_equals(err, nil)
    t.assert_is(saved, record)
    t.assert_equals(record:to_table(), { id = 3, name = 'Анна', age = 19, email = 'a@x.ru' })
    t.assert_equals(record:is_adult(), true)
    t.assert_equals(calls[1].args[2], 'replace')

    record.age = 'много'
    record.extra = 'лишнее'

    local refused, bad = record:save()

    t.assert_equals(refused, nil)
    t.assert_equals(bad.fields, {
        age = "должно быть целым числом от 0 до 150, а не 'много'",
        extra = 'неизвестное поле',
    })
    t.assert_equals(#calls, 1)

    local denied = failure().new('readonly', 'только чтение')
    local Readonly = bound({ put = { refusal = denied } })
    local _, why = Readonly.validate({ id = 1, name = 'a', age = 1 }):save()

    t.assert_is(why, denied)
end

g.test_where_builds_an_index_query_and_wraps_the_page = function()
    local User, calls = bound({ select = { { id = 1, name = 'a', age = 20 }, { id = 2, name = 'b', age = 30 } } })
    local page, err = User.where('age', '>=', 18):limit(2):all()

    t.assert_equals(err, nil)
    t.assert_equals(#page, 2)
    t.assert_equals(page[2]:is_adult(), true)
    t.assert_equals(calls[1], {
        name = 'select',
        space = 'users',
        args = { { index = 'age', iterator = 'GE', key = { 18 }, limit = 2 } },
    })

    t.assert_equals(User.where('id', '=', 7):all()[1].id, 1)
    t.assert_equals(calls[2].args[1], { index = 'primary', iterator = 'EQ', key = { 7 }, limit = 100 })
    t.assert_equals(model.LIMIT, 100, 'фасад называет страницу выборки')

    User.where('age', '<', 30):all()
    User.where('age', '<=', 30):all()
    User.where('age', '>', 30):all()

    t.assert_equals(calls[3].args[1].iterator, 'LT')
    t.assert_equals(calls[4].args[1].iterator, 'LE')
    t.assert_equals(calls[5].args[1].iterator, 'GT')

    local pair = { 18, 30 }

    User.where('age', 'between', pair):all()

    t.assert_equals(calls[6].args[1], { index = 'age', iterator = 'GE', key = { 18 }, to = 30, limit = 100 })
    t.assert_equals(pair, { 18, 30 }, 'пара вызывающего не тронута')
end

g.test_first_count_after_and_scan = function()
    local User, calls = bound({ select = { { id = 5, name = 'e', age = 50 } }, count = 3 })

    t.assert_equals(User.where('age', '>=', 40):first().id, 5)
    t.assert_equals(calls[1].args[1].limit, 1)
    t.assert_equals(User.where('age', '>=', 40):count(), 3)
    t.assert_equals(calls[2].name, 'count')

    local query = User.where('age', '>=', 40):after({ id = 5, age = 50, name = 'e' })

    query:all()

    t.assert_equals(calls[3].args[1].after, { id = 5, age = 50 })
    t.assert_equals(User.scan():limit(7):count(), 3)
    t.assert_equals(calls[4].args[1], { index = 'primary', iterator = 'ALL', key = {}, limit = 7 })

    -- Страница в одну запись — наименьшая годная.
    User.scan():limit(1):all()

    t.assert_equals(calls[5].args[1].limit, 1)

    User.where('age', '>=', 40):limit(10):offset(20):all()

    t.assert_equals(calls[6].args[1], { index = 'age', iterator = 'GE', key = { 40 }, limit = 10, offset = 20 })

    User.scan():offset(0):after({ id = 5 }):first()

    t.assert_equals(calls[7].args[1], {
        index = 'primary',
        iterator = 'ALL',
        key = {},
        limit = 1,
        offset = 0,
        after = { id = 5 },
    })
    t.assert_equals(User.scan():offset(model.OFFSET):count(), 3, 'счёт смещения не знает')
    t.assert_equals(calls[8].args[1].offset, 4294967295)
    t.assert_equals(model.OFFSET, 4294967295, 'фасад называет самое большое смещение')

    User.scan():limit(model.OFFSET):all()

    t.assert_equals(
        calls[9].args[1].limit,
        4294967295,
        'самая длинная страница — тот же предел'
    )

    local empty, none = bound({}).where('age', '>=', 1):first()

    t.assert_equals({ empty, none }, { nil, nil })
end

g.test_query_refuses_bad_values_and_reports_gateway_refusals = function()
    local User, calls = bound({ select = { refusal = failure().new('unavailable', 'нет') } })
    local page, err = User.where('age', '>=', 'много'):all()

    t.assert_equals(page, nil)
    t.assert_equals(
        err.fields,
        { age = "должно быть целым числом не меньше 0, а не 'много'" }
    )
    t.assert_equals(
        tostring(err),
        "условие выборки users: age — должно быть целым числом не меньше 0, а не 'много'",
        'отказ называет условие выборки, а не запись'
    )

    local counted, count_err = User.where('age', 'between', { 1, 'x' }):count()

    t.assert_equals(counted, nil)
    t.assert_equals(count_err.kind, 'invalid')
    t.assert_equals(#calls, 0)

    local _, unavailable = User.where('age', '>=', 1):all()

    t.assert_equals(unavailable.kind, 'unavailable')

    local _, first_err = User.where('age', '>=', 1):first()

    t.assert_equals(first_err.kind, 'unavailable')
end

g.test_query_refuses_empty_condition_values_instead_of_a_full_scan = function()
    local Tag = model.define({
        space = 'tags',
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'status', 'string', default = 'new' },
            { 'label', 'string', optional = true },
        },
        indexes = {
            status = { parts = { 'status' }, unique = false },
            label = { parts = { 'label' }, unique = false },
        },
    })
    local gateway, calls = helper.fake_gateway({ select = {}, count = 0 })

    Tag._bind(gateway)

    -- Условие ищут, а не заполняют: ни умолчание, ни необязательность
    -- поля пустое значение условия не пропускают.
    local page, err = Tag.where('status', '=', nil):all()

    t.assert_equals(page, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.fields, { status = 'обязательное поле' })
    t.assert_equals(tostring(err), 'условие выборки tags: status — обязательное поле')
    t.assert_equals(
        select(2, Tag.where('label', '<', nil):count()).fields,
        { label = 'обязательное поле' }
    )
    t.assert_equals(select(2, Tag.where('id', '>=', nil):first()).fields, { id = 'обязательное поле' })
    t.assert_equals(
        select(2, Tag.where('id', 'between', { nil, 5 }):all()).fields,
        { id = 'обязательное поле' }
    )
    t.assert_equals(#calls, 0, 'до шлюза пустое условие не доходит')

    t.assert_equals(Tag.where('status', '=', 'done'):all(), {})
    t.assert_equals(calls[1].args[1].key, { 'done' })
end

-- Курсор страницы приходит от клиента, как и значение условия: строка,
-- число за границей поля и пустота из JSON — отказ `invalid` до шлюза.
-- Без проверки `box` ответил бы «Iterator position is invalid», и через
-- роутер это читалось бы бедой хранилища — `unavailable`.
g.test_after_refuses_bad_cursor_values_before_the_gateway = function()
    local User, calls = bound({ select = {}, count = 0 })
    local page, err = User.where('age', '>=', 18):after({ age = 'x', id = 1 }):all()

    t.assert_equals(page, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(
        err.fields,
        { age = "должно быть целым числом не меньше 0, а не 'x'" }
    )
    t.assert_equals(
        tostring(err),
        "условие выборки users: age — должно быть целым числом не меньше 0, а не 'x'"
    )

    -- Курсор — место в индексе, и от правила поля у него только род:
    -- `-1` в индекс `unsigned` `box` не примет.
    local first, first_err = User.where('age', '>=', 18):after({ age = -1, id = 1 }):first()

    t.assert_equals(first, nil)
    t.assert_equals(
        first_err.fields,
        { age = 'должно быть целым числом не меньше 0, а не -1' }
    )

    -- Счёт курсора не знает, но выборку с негодным значением не считает:
    -- значение пришло снаружи, как и у `where`.
    local counted, count_err = User.where('age', '>=', 18):after({ age = 18, id = box.NULL }):count()

    t.assert_equals(counted, nil)
    t.assert_equals(count_err.kind, 'invalid')
    t.assert_equals(count_err.fields, { id = 'обязательное поле' })

    -- Отказ называет первое негодное поле: части индекса раньше ключа.
    t.assert_equals(
        select(2, User.where('age', '>=', 18):after({ age = -1, id = -2 }):all()).fields,
        { age = 'должно быть целым числом не меньше 0, а не -1' }
    )
    t.assert_equals(
        select(2, User.scan():after({ id = 'x' }):all()).fields,
        { id = "должно быть целым числом не меньше 0, а не 'x'" }
    )
    t.assert_equals(#calls, 0, 'до шлюза негодный курсор не доходит')

    -- Годный курсор не снимает отказа по условию.
    t.assert_equals(
        select(2, User.where('age', '>=', 'много'):after({ age = 18, id = 1 }):all()).fields,
        { age = "должно быть целым числом не меньше 0, а не 'много'" }
    )
    t.assert_equals(#calls, 0)

    t.assert_equals(User.where('age', '>=', 18):after({ age = 18, id = 1 }):all(), {})
    t.assert_equals(calls[1].args[1].after, { age = 18, id = 1 })

    -- Запись, лёгшая до того, как объявление сузили, продолжает страницу:
    -- возраст 151 за `max`, но место в индексе у него есть.
    local last = { age = 151, id = 3, name = 'Долгожитель' }

    t.assert_equals(User.where('age', '>=', 100):after(last):all(), {})
    t.assert_equals(calls[2].args[1].after, { age = 151, id = 3 })
    t.assert_equals(
        last,
        { age = 151, id = 3, name = 'Долгожитель' },
        'запись вызывающего не тронута'
    )
end

--- Модель учётных записей: строковые индексы с длиной, образцом
--- и перечнем, составной индекс.
---@return any Account
---@return any calls
local function accounts()
    local Account = model.define({
        space = 'accounts',
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'login', 'string', min = 1, max = 64, pattern = '^%l+$' },
            { 'role', 'string', one_of = { 'admin', 'user' } },
            { 'rank', 'integer', min = -5, max = 5 },
            { 'weight', 'number', min = 0.5, max = 2 },
        },
        indexes = {
            login = { parts = { 'login' }, unique = true },
            pair = { parts = { 'role', 'login' }, unique = true },
            rank = { parts = { 'rank' }, unique = false },
            weight = { parts = { 'weight' }, unique = false },
        },
    })
    local gateway, calls = helper.fake_gateway({ select = {}, count = 0 })

    Account._bind(gateway)

    return Account, calls
end

-- Граница диапазона — место в порядке индекса, а не значение записи:
-- `login >= ''` обходит весь индекс, `age < 200` — его же по убыванию.
-- Поэтому у границы от правила поля только род, а искомое значение
-- равенства проверяется всем правилом: записи с ним быть не может.
g.test_ranges_check_only_the_kind_and_equality_the_whole_rule = function()
    local User, calls = bound({ select = {}, count = 0 })

    t.assert_equals(User.where('age', '<', 200):all(), {})
    t.assert_equals(calls[1].args[1], { index = 'age', iterator = 'LT', key = { 200 }, limit = 100 })
    t.assert_equals(User.where('age', 'between', { 0, 200 }):count(), 0)
    t.assert_equals(calls[2].args[1], { index = 'age', iterator = 'GE', key = { 0 }, to = 200, limit = 100 })
    t.assert_equals(User.where('age', '>', 151):first(), nil)
    t.assert_equals(calls[3].args[1].key, { 151 })

    local Account, seen = accounts()

    t.assert_equals(Account.where('login', '>=', ''):all(), {})
    t.assert_equals(seen[1].args[1].key, { '' })
    t.assert_equals(Account.where('login', '<', string.rep('z', 65)):all(), {})
    t.assert_equals(seen[2].args[1].key, { string.rep('z', 65) })
    t.assert_equals(
        Account.where('login', '>', 'A1'):count(),
        0,
        'образец к границе не применяется'
    )
    t.assert_equals(Account.where('role', '<=', 'root'):count(), 0, 'перечень тоже')
    t.assert_equals(Account.where('rank', '>=', -100):count(), 0)
    t.assert_equals(Account.where('weight', '<', 7.5):count(), 0, 'граница числа — любое число')
    t.assert_equals(#seen, 6)

    -- Равенство — всем правилом поля.
    local _, err = User.where('age', '=', 200):all()

    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.fields, { age = 'должно быть целым числом от 0 до 150, а не 200' })
    t.assert_equals(
        tostring(err),
        'условие выборки users: age — должно быть целым числом от 0 до 150, а не 200'
    )
    t.assert_equals(select(2, Account.where('login', '=', ''):first()).fields, {
        login = 'должно быть строкой длиной от 1 до 64 знаков по образцу ^%l+$, а сейчас 0 знаков',
    })
    t.assert_equals(
        select(2, Account.where('role', '=', 'root'):count()).fields,
        { role = "должно быть одним из: 'admin', 'user', а не 'root'" }
    )
    t.assert_equals(select(2, Account.where('rank', '=', 6):all()).fields, {
        rank = 'должно быть целым числом от -5 до 5, а не 6',
    })

    -- Род — и у границы: `box` не примет в индекс `unsigned` ни строку,
    -- ни `-1`, ни дробь, а в `integer` — число за пределом рода.
    t.assert_equals(
        select(2, User.where('age', '>=', 'x'):all()).fields,
        { age = "должно быть целым числом не меньше 0, а не 'x'" }
    )
    t.assert_equals(
        select(2, User.where('age', '>=', -1):all()).fields,
        { age = 'должно быть целым числом не меньше 0, а не -1' }
    )
    t.assert_equals(
        select(2, User.where('age', 'between', { 1, 17.5 }):count()).fields,
        { age = 'должно быть целым числом не меньше 0, а не 17.5' }
    )
    t.assert_equals(select(2, Account.where('rank', '<', 1e20):count()).fields, {
        rank = 'должно быть целым числом от -9223372036854775808 до 18446744073709551615, а не 1e+20',
    })
    t.assert_equals(
        select(2, Account.where('login', '<', 5):count()).fields,
        { login = 'должно быть строкой, а не 5' }
    )
    t.assert_equals(#calls, 3, 'до шлюза негодное условие не доходит')
    t.assert_equals(#seen, 6)
end

g.test_query_programmer_errors_name_the_model = function()
    local User = bound()

    t.assert_error_msg_equals(
        'модель users: по полю name индекса нет; есть индексы primary (id), age (age)',
        User.where,
        'name',
        '=',
        'a'
    )
    t.assert_error_msg_equals(
        'модель users: условие ~ неизвестно; есть =, >, >=, <, <=, between',
        User.where,
        'age',
        '~',
        1
    )
    t.assert_error_msg_equals(
        'модель users: between ждёт пару { от, до }',
        User.where,
        'age',
        'between',
        1
    )
    t.assert_error_msg_equals(
        'модель users: between ждёт пару { от, до }',
        User.where,
        'age',
        'between',
        { 1 }
    )
    -- `box` держит предел страницы в 32 битах и больший молча обрезает:
    -- `limit(2^32 + 5)` отдал бы пять записей.
    for _, wrong in ipairs({ 0, 1.5, 4294967296, '5' }) do
        t.assert_error_msg_equals(
            ('модель users: limit — целое число от 1 до 4294967295, а не %s'):format(wrong),
            function()
                User.scan():limit(wrong)
            end
        )
    end

    for _, wrong in ipairs({ -1, 1.5, 4294967296, '5' }) do
        t.assert_error_msg_equals(
            ('модель users: offset — целое число от 0 до 4294967295, а не %s'):format(wrong),
            function()
                User.scan():offset(wrong)
            end
        )
    end

    t.assert_error_msg_equals('модель users: after — запись, а не number', function()
        User.scan():after(5)
    end)
    t.assert_error_msg_equals('модель users: в after нет поля age', function()
        User.where('age', '>', 1):after({ id = 1 })
    end)
    t.assert_error_msg_equals('модель users: в after нет поля id', function()
        User.where('age', '>', 1):after({ age = 1 })
    end)
    -- Ошибка кода не прячется за отказом по данным: поле, которого нет,
    -- видно и тогда, когда поле перед ним негодно.
    t.assert_error_msg_equals('модель users: в after нет поля id', function()
        User.where('age', '>', 1):after({ age = 'x' })
    end)
end

g.test_wire_query_is_checked_by_shape = function()
    local User = bound()
    local good = { index = 'age', iterator = 'GE', key = { 1 }, limit = 10, after = { id = 1, age = 1 } }

    t.assert_is(User._query(good), good)
    t.assert_equals(good, { index = 'age', iterator = 'GE', key = { 1 }, limit = 10, after = { id = 1, age = 1 } })

    for _, iterator in ipairs({ 'EQ', 'GT', 'GE', 'LT', 'LE', 'ALL' }) do
        local spec = { index = 'primary', iterator = iterator, key = {}, limit = 1 }

        t.assert_is(User._query(spec), spec, iterator)
    end

    for _, offset in ipairs({ 0, 1, 4294967295 }) do
        local spec = { index = 'age', iterator = 'GE', key = {}, limit = 1, offset = offset }

        t.assert_is(User._query(spec), spec, offset)
    end

    local longest = { index = 'age', iterator = 'GE', key = {}, limit = 4294967295 }

    t.assert_is(User._query(longest), longest)

    local message = 'модель users: выборка не по форме: index, iterator, key, after, filter'

    for _, bad in ipairs({
        'x',
        { index = 'none', iterator = 'GE', key = {}, limit = 1 },
        { index = 'age', iterator = 'REQ', key = {}, limit = 1 },
        { index = 'age', iterator = 'GE', key = 1, limit = 1 },
        { index = 'age', iterator = 'GE', key = {}, limit = 1, after = 5 },
        { index = 'age', iterator = 'GE', key = {}, limit = 1, filter = { { field = 'years', op = '=' } } },
    }) do
        t.assert_error_msg_equals(message, User._query, bad)
    end
end

--- Отказ выборки с провода: поля отказа; годная выборка — ошибка проверки.
---@param Model any
---@param spec table
---@return table<string, string>
local function wire_refusal(Model, spec)
    local checked, err = Model._query(spec)

    t.assert_equals(checked, nil)
    t.assert_equals(err.kind, 'invalid')

    return err.fields
end

-- Значения выборки с провода — те же, что у модели: роутер проверил их
-- у себя, а узел с данными проверяет заново и отвечает отказом `invalid`,
-- а не исключением из глубины `box`. Без этого строка в ключе бросала бы
-- «Supplied key type … does not match», граница `to` — «attempt to compare
-- number with string», а `limit = -1` отдавал бы весь спейс.
g.test_wire_query_values_are_refusals_not_throws = function()
    local User, calls = bound()
    local page = 'должно быть целым числом от 1 до 4294967295, а не %s'
    local skip = 'должно быть целым числом от 0 до 4294967295, а не %s'
    local age = 'должно быть целым числом не меньше 0, а не %s'
    local base = { index = 'age', iterator = 'GE', key = { 1 }, limit = 10 }

    --- Выборка поверх годной: только названные поля другие.
    ---@param changes table
    ---@return table
    local function spec(changes)
        local copy = table.deepcopy(base)

        for name, value in pairs(changes) do
            copy[name] = value
        end

        return copy
    end

    local err = select(2, User._query(spec({ key = { 'много' } })))

    t.assert_equals(err.fields, { age = age:format("'много'") })
    t.assert_equals(
        tostring(err),
        "условие выборки users: age — должно быть целым числом не меньше 0, а не 'много'"
    )

    for index, case in ipairs({
        { { key = { 1 }, to = 'пять' }, { age = age:format("'пять'") } },
        { { index = 'primary', iterator = 'ALL', key = {}, limit = -1 }, { limit = page:format('-1') } },
        { { limit = 2.5 }, { limit = page:format('2.5') } },
        { { limit = 0 }, { limit = page:format('0') } },
        { { limit = 4294967296 }, { limit = page:format('4294967296') } },
        { { limit = '1' }, { limit = page:format("'1'") } },
        { { limit = box.NULL }, { limit = 'обязательное поле' } },
        { { offset = -1 }, { offset = skip:format('-1') } },
        { { offset = 0.5 }, { offset = skip:format('0.5') } },
        { { offset = 4294967296 }, { offset = skip:format('4294967296') } },
        { { offset = '1' }, { offset = skip:format("'1'") } },
        {
            { iterator = 'EQ', key = { 999 } },
            { age = 'должно быть целым числом от 0 до 150, а не 999' },
        },
        { { iterator = 'LT', key = { -1 } }, { age = age:format('-1') } },
        { { iterator = 'ALL', key = { 'x' } }, { age = age:format("'x'") } },
        {
            { key = { 1, 2 } },
            {
                ['$'] = 'ключ по индексу age — не больше частей, чем у индекса: age',
            },
        },
        { { index = 'primary', key = { [2] = 1 } }, { id = 'обязательное поле' } },
        {
            { key = { 1, x = 2 } },
            {
                ['$'] = 'ключ по индексу age — не больше частей, чем у индекса: age',
            },
        },
        { { after = { age = 'x', id = -1 } }, { age = age:format("'x'") } },
        { { after = { age = 1, id = -1 } }, { id = age:format('-1') } },
        { { after = { age = 1 } }, { id = 'обязательное поле' } },
        { { filter = { { field = 'age', op = '<', value = 'x' } } }, { age = age:format("'x'") } },
        {
            { filter = { { field = 'age', op = '=', value = 200 } } },
            {
                age = 'должно быть целым числом от 0 до 150, а не 200',
            },
        },
        {
            { filter = { { field = 'email', op = '=' }, { field = 'age', op = '<' } } },
            {
                age = 'обязательное поле',
            },
        },
    }) do
        t.assert_equals(wire_refusal(User, spec(case[1])), case[2], ('случай №%d'):format(index))
    end

    -- Годное проходит как есть: границы за объявлением, `ALL` с ключом,
    -- пустота у условий `=` и `~=`, курсор за `max`.
    local fits = spec({
        iterator = 'LT',
        key = { 200 },
        to = 300,
        offset = 0,
        after = { age = 151, id = 1 },
        filter = { { field = 'email', op = '=' }, { field = 'age', op = '<', value = 200 } },
    })

    t.assert_is(User._query(fits), fits)
    t.assert_equals(fits.filter, { { field = 'email', op = '=' }, { field = 'age', op = '<', value = 200 } })
    t.assert_equals(fits.after, { age = 151, id = 1 })
    t.assert_is_not(User._query(spec({ iterator = 'ALL', key = { 5 } })), nil)
    t.assert_is_not(
        User._query(spec({ iterator = 'EQ', key = { 150 }, filter = { { field = 'age', op = '~=' } } })),
        nil
    )
    t.assert_equals(#calls, 0)

    -- Составной индекс: частей ключа сколько у индекса, у `EQ` каждая —
    -- искомое значение, у границы — только род.
    local Account = accounts()
    local pair = { index = 'pair', iterator = 'GE', key = { 'admin', '' }, limit = 1 }

    t.assert_is(Account._query(pair), pair)
    t.assert_equals(wire_refusal(Account, { index = 'pair', iterator = 'EQ', key = { 'admin', '' }, limit = 1 }), {
        login = 'должно быть строкой длиной от 1 до 64 знаков по образцу ^%l+$, а сейчас 0 знаков',
    })
    t.assert_equals(
        wire_refusal(Account, { index = 'pair', iterator = 'GE', key = { 'admin', 'a', 'b' }, limit = 1 }),
        {
            ['$'] = 'ключ по индексу pair — не больше частей, чем у индекса: role, login',
        }
    )
    t.assert_equals(
        wire_refusal(Account, { index = 'pair', iterator = 'GE', key = { 'admin', 5 }, limit = 1 }),
        { login = 'должно быть строкой, а не 5' }
    )
end

--- Модель пользователей с индексом по необязательной почте на двойнике
--- шлюза.
---@return any User
---@return any calls
local function mailed()
    local User = helper.users(model, {
        indexes = {
            age = { parts = { 'age' }, unique = false },
            email = { parts = { 'email' }, unique = false },
        },
    })
    local gateway, calls = helper.fake_gateway({ select = {}, count = 0 })

    User._bind(gateway)

    return User, calls
end

-- Запись без почты стоит в индексе `email` на месте NULL — последней
-- по убыванию, — и страница, кончившаяся ею, продолжается от этого
-- места: пустота необязательного поля в курсоре — не нехватка поля
-- и не отказ, и у модели, и с провода. Непустое значение проверяется
-- родом, как у всякой части курсора. У обязательного поля всё
-- по-прежнему: поля нет — ошибка кода, `null` — отказ.
g.test_after_takes_an_empty_optional_part_as_the_null_place = function()
    local json = require('json')
    local User, calls = mailed()
    local last = { id = 4, name = 'Без почты', age = 30 }

    t.assert_equals(User.where('email', '<', 'n'):after(last):all(), {})
    t.assert_equals(calls[1].args[1].after, { id = 4 })
    t.assert_equals(
        last,
        { id = 4, name = 'Без почты', age = 30 },
        'запись вызывающего не тронута'
    )

    t.assert_equals(User.where('email', '<=', 'n'):after(json.decode('{"email": null, "id": 4}')):first(), nil)
    t.assert_equals(
        type(calls[2].args[1].after.email),
        'cdata',
        'null из JSON доходит до шлюза как есть'
    )
    t.assert_equals(User.where('email', '<', 'n'):after({ id = 4 }):count(), 0)
    t.assert_equals(#calls, 3)

    t.assert_equals(
        select(2, User.where('email', '<', 'n'):after({ email = 5, id = 4 }):all()).fields,
        { email = 'должно быть строкой, а не 5' }
    )
    t.assert_equals(
        select(2, User.where('email', '<', 'n'):after({ email = box.NULL, id = box.NULL }):all()).fields,
        { id = 'обязательное поле' }
    )
    t.assert_error_msg_equals('модель users: в after нет поля id', function()
        User.where('email', '<', 'n'):after({ email = 'm@x.ru' })
    end)
    t.assert_equals(#calls, 3, 'до шлюза негодный курсор не доходит')

    -- С провода — тем же правилом: пустота и `null` почты — место NULL.
    for _, after in ipairs({ { id = 4 }, { email = box.NULL, id = 4 } }) do
        local wire = { index = 'email', iterator = 'LT', key = { 'n' }, limit = 10, after = after }

        t.assert_is(User._query(wire), wire)
    end

    for index, case in ipairs({
        { { email = 5, id = 4 }, { email = 'должно быть строкой, а не 5' } },
        { { email = box.NULL }, { id = 'обязательное поле' } },
    }) do
        t.assert_equals(
            wire_refusal(User, { index = 'email', iterator = 'LT', key = { 'n' }, limit = 10, after = case[1] }),
            case[2],
            ('случай №%d'):format(index)
        )
    end
end

-- При приведении типов `tnt-validate` проверенное значение другое, чем
-- пришло, и в выборку ложится оно: `box` строку в числовом индексе
-- не примет.
g.test_checked_values_replace_the_input_when_types_are_coerced = function()
    helper.module('tnt.validate').configure({ coerce = true })

    local User, calls = bound({ select = {}, count = 0 })
    local wire = {
        index = 'age',
        iterator = 'GE',
        key = { '30' },
        to = '40',
        limit = '10',
        offset = '2',
        after = { age = '31', id = '7' },
        filter = { { field = 'age', op = '<', value = '50' } },
    }

    t.assert_is(User._query(wire), wire)
    t.assert_equals(wire, {
        index = 'age',
        iterator = 'GE',
        key = { 30 },
        to = 40,
        limit = 10,
        offset = 2,
        after = { age = 31, id = 7 },
        filter = { { field = 'age', op = '<', value = 50 } },
    })

    User.where('age', 'between', { '18', '30' }):after({ age = '20', id = '3' }):all()

    t.assert_equals(calls[1].args[1], {
        index = 'age',
        iterator = 'GE',
        key = { 18 },
        to = 30,
        limit = 100,
        after = { age = 20, id = 3 },
    })
end

g.test_factory_builds_valid_records_by_type_and_declaration = function()
    local User = helper.users(model)
    local first = User.factory()
    local second = User.factory({ name = 'Мария', email = 'm@x.ru' })

    t.assert_equals(first:to_table(), { id = 1, name = 'name 1', age = 1 })
    t.assert_equals(second:to_table(), { id = 2, name = 'Мария', age = 2, email = 'm@x.ru' })
    t.assert_equals(second:is_adult(), false)

    local Declared = helper.users(model, {
        factory = function(sequence)
            return { name = 'Клиент ' .. sequence, age = 30 }
        end,
    })

    t.assert_equals(Declared.factory():to_table(), { id = 1, name = 'Клиент 1', age = 30 })
    t.assert_equals(Declared.factory({ age = 40 }).age, 40)

    local Note = model.define({
        space = 'notes',
        fields = {
            { 'key', 'string', primary = true, min = 12 },
            { 'code', 'string', max = 3 },
            { 'mark', 'string', max = 1 },
            { 'blank', 'string', max = 0 },
            { 'sliver', 'string', max = 0.5 },
            { 'mood', 'string', one_of = { 'up', 'down' } },
            { 'flag', 'boolean' },
            { 'owner', 'uuid' },
            { 'weight', 'number', min = 2.5 },
            { 'rank', 'integer', max = -1 },
        },
    })
    local note = Note.factory()

    t.assert_equals(note.key, 'key 1xxxxxxx')
    -- Короткий `max` оставляет конец строки, то есть номер записи:
    -- у следующей записи значение другое, и ключи не сталкиваются.
    t.assert_equals(note.code, 'e 1')
    t.assert_equals(note.mark, '1')
    t.assert_equals(note.blank, '')
    t.assert_equals(note.sliver, '')
    t.assert_equals(note.mood, 'up')
    t.assert_equals(note.flag, false)
    t.assert_equals(#note.owner, 36)
    t.assert_equals(note.weight, 2.5)
    t.assert_equals(note.rank, -1)

    local next_note = Note.factory()

    t.assert_equals(next_note.key, 'key 2xxxxxxx')
    t.assert_equals(next_note.code, 'e 2')

    local Strict = helper.users(model, {
        rules = {
            function()
                return 'никого не берём'
            end,
        },
    })

    t.assert_error_msg_equals(
        'фабрика модели users собрала негодную запись: запись users не прошла проверку: $ — никого не берём',
        Strict.factory
    )
end

g.test_migration_step_is_a_function_of_box = function()
    local User = helper.users(model)

    t.assert_type(User.migration(), 'function')
end

g.test_migration_step_gives_the_shape_to_a_gateway_with_its_own_schema = function()
    local User = helper.users(model)
    local step = User.migration()
    local gateway = helper.fake_gateway()
    local answer = { true } --[[@as any[] ]]
    local asked = {}

    -- Шлюз смотрится в миг шага: шаг взяли до привязки.
    function gateway.migrate(shape)
        table.insert(asked, shape.space)

        return unpack(answer)
    end

    User._bind(gateway)

    step(nil)
    t.assert_equals(asked, { 'users' })

    local refusal = model.failure.new('unavailable', 'база не ответила')

    answer = { nil, refusal }

    local ok, err = pcall(step, nil)

    t.assert_equals(ok, false)
    t.assert_is(err, refusal)
    t.assert_equals(asked, { 'users', 'users' })
end
