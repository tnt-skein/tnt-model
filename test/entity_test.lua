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

    local empty, none = bound({}).where('age', '>=', 1):first()

    t.assert_equals({ empty, none }, { nil, nil })
end

g.test_query_refuses_bad_values_and_reports_gateway_refusals = function()
    local User, calls = bound({ select = { refusal = failure().new('unavailable', 'нет') } })
    local page, err = User.where('age', '>=', 'много'):all()

    t.assert_equals(page, nil)
    t.assert_equals(
        err.fields,
        { age = "должно быть целым числом от 0 до 150, а не 'много'" }
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
    t.assert_equals(
        tostring(err),
        'запись tags не прошла проверку: status — обязательное поле'
    )
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
    t.assert_error_msg_equals('модель users: limit — натуральное число, а не 0', function()
        User.scan():limit(0)
    end)
    t.assert_error_msg_equals('модель users: limit — натуральное число, а не 1.5', function()
        User.scan():limit(1.5)
    end)
    t.assert_error_msg_equals('модель users: after — запись, а не number', function()
        User.scan():after(5)
    end)
    t.assert_error_msg_equals('модель users: в after нет поля age', function()
        User.where('age', '>', 1):after({ id = 1 })
    end)
    t.assert_error_msg_equals('модель users: в after нет поля id', function()
        User.where('age', '>', 1):after({ age = 1 })
    end)
end

g.test_wire_query_is_checked_by_shape = function()
    local User = bound()
    local good = { index = 'age', iterator = 'GE', key = { 1 }, limit = 10, after = { id = 1, age = 1 } }

    t.assert_is(User._query(good), good)

    for _, iterator in ipairs({ 'EQ', 'GT', 'GE', 'LT', 'LE', 'ALL' }) do
        local spec = { index = 'primary', iterator = iterator, key = {}, limit = 1 }

        t.assert_is(User._query(spec), spec, iterator)
    end

    local message = 'модель users: выборка не по форме: index, iterator, key, limit, after'

    for _, bad in ipairs({
        'x',
        { index = 'none', iterator = 'GE', key = {}, limit = 1 },
        { index = 'age', iterator = 'REQ', key = {}, limit = 1 },
        { index = 'age', iterator = 'GE', key = 1, limit = 1 },
        { index = 'age', iterator = 'GE', key = {}, limit = '1' },
        { index = 'age', iterator = 'GE', key = {}, limit = 1, after = 5 },
    }) do
        t.assert_error_msg_equals(message, User._query, bad)
    end
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
