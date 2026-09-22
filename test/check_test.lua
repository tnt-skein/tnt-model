--- Проверки входа по форме: поля, обрезка, свои правила, ключ, отказ.

local t = require('luatest')

local helper = dofile('test/helper.lua')

---@type any
local model

local g = helper.group('tnt.model.check', function(loaded)
    model = loaded
end)

--- Отказы модели — модуль того же набора исходников.
---@return any
local function failure()
    return helper.module('tnt.model.failure')
end

g.test_validate_returns_a_record_with_class_methods = function()
    local User = helper.users(model)
    local record, err = User.validate({ id = 7, name = '  Мария  ', age = 46 })

    t.assert_equals(err, nil)
    t.assert_equals(record.name, 'Мария', 'пробелы обрезаны до проверки')
    t.assert_equals(record:to_table(), { id = 7, name = 'Мария', age = 46 })
    t.assert_equals(record:is_adult(), true)
    t.assert_equals(getmetatable(record:to_table()), nil)
    t.assert_equals(User.validate({ id = 7, name = 'Иван', age = 17 }):is_adult(), false)
end

g.test_validate_refuses_with_fields_and_readable_text = function()
    local User = helper.users(model)
    local record, err = User.validate({ id = 0.5, name = '   ', age = 151, emial = 'x' })

    t.assert_equals(record, nil)
    t.assert_equals(failure().is(err), true)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.fields, {
        id = 'должно быть целым числом не меньше 0, а не 0.5',
        name = 'должно быть строкой длиной от 1 до 255 знаков, а сейчас 0 знаков',
        age = 'должно быть целым числом от 0 до 150, а не 151',
        emial = 'неизвестное поле',
    })
    t.assert_equals(
        tostring(err),
        'запись users не прошла проверку: '
            .. 'age — должно быть целым числом от 0 до 150, а не 151; '
            .. 'emial — неизвестное поле; '
            .. 'id — должно быть целым числом не меньше 0, а не 0.5; '
            .. 'name — должно быть строкой длиной от 1 до 255 знаков, а сейчас 0 знаков'
    )
    t.assert_equals(('%s'):format(err), tostring(err))
    t.assert_equals('отказ: ' .. err, 'отказ: ' .. tostring(err))
    t.assert_equals(require('json').encode({ err = err }), require('json').encode({ err = tostring(err) }))
end

g.test_validate_refuses_non_table_input = function()
    local User = helper.users(model)
    local record, err = User.validate('Мария')

    t.assert_equals(record, nil)
    t.assert_equals(err.fields, { ['$'] = 'должно быть таблицей полей' })
end

g.test_types_defaults_and_optional_fields = function()
    local Note = model.define({
        space = 'notes',
        fields = {
            { 'key', 'string', primary = true, min = 1, pattern = '^%l+$' },
            { 'body', 'string', default = 'пусто' },
            { 'flag', 'boolean', default = false },
            { 'owner', 'uuid', optional = true },
            { 'weight', 'number', min = 0.5, max = 2 },
            { 'rank', 'integer', min = -5, max = 5 },
            { 'mood', 'string', one_of = { 'up', 'down' } },
        },
    })

    local record = Note.validate({ key = 'abc', weight = 1.5, rank = -5, mood = 'up' })

    t.assert_equals(
        record:to_table(),
        { key = 'abc', body = 'пусто', flag = false, weight = 1.5, rank = -5, mood = 'up' }
    )

    local owner = require('uuid').str()

    t.assert_equals(Note.validate({ key = 'abc', weight = 1, rank = 0, mood = 'down', owner = owner }).owner, owner)

    local _, err =
        Note.validate({ key = 'A1', flag = 'да', owner = 'нет', weight = 2.5, rank = 1.5, mood = 'left' })

    t.assert_equals(err.fields, {
        key = "должно быть строкой длиной не меньше 1 знака по образцу ^%l+$, а не 'A1'",
        flag = "должно быть логическим значением, а не 'да'",
        owner = "должно быть UUID, а не 'нет'",
        weight = 'должно быть числом от 0.5 до 2, а не 2.5',
        rank = 'должно быть целым числом от -5 до 5, а не 1.5',
        mood = "должно быть одним из: 'up', 'down', а не 'left'",
    })
end

-- Опознаватель приходит строкой в любом регистре и cdata `uuid` — от
-- `uuid.new()` и из кортежа, — а у записи он один видом: строка в нижнем
-- регистре. Так же — в ключе, в искомом значении и в границе выборки.
-- Умолчание `tnt-validate` проверку минует, и приведение ему своё:
-- значение и функция отдают строку, негодное остаётся как есть.
g.test_uuid_fields_take_strings_and_cdata_and_keep_strings = function()
    local uuid = require('uuid')
    local check = helper.module('tnt.model.check')
    local validate = helper.module('tnt.validate')
    local id = '6ba7b810-9dad-41d1-80b4-00c04fd430c8'
    local origin = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
    local Device = model.define({
        space = 'devices',
        fields = {
            { 'id', 'uuid', primary = true },
            { 'owner', 'uuid', optional = true },
            { 'serial', 'uuid', default = uuid.new },
            { 'origin', 'uuid', default = uuid.fromstr(origin) },
            { 'mark', 'uuid', default = origin:upper() },
            { 'broken', 'uuid', default = 'не опознаватель' },
        },
    })

    local by_string = Device.validate({ id = id:upper() })
    local by_cdata = Device.validate({ id = uuid.fromstr(id), owner = uuid.fromstr(origin) })

    t.assert_equals(by_string.id, id, 'строка приведена к нижнему регистру')
    t.assert_equals(
        by_string.owner,
        nil,
        'пустое необязательное поле не заполняется'
    )
    t.assert_equals({ type(by_cdata.id), by_cdata.id, by_cdata.owner }, { 'string', id, origin })
    t.assert_equals(type(by_string.serial), 'string', 'умолчание-функция отдаёт строку')
    t.assert_str_matches(by_string.serial, '%x+%-%x+%-%x+%-%x+%-%x+')
    t.assert_not_equals(
        by_string.serial,
        by_cdata.serial,
        'функция зовётся на каждую запись'
    )
    t.assert_equals({ by_string.origin, by_string.mark }, { origin, origin })
    t.assert_equals(
        by_string.broken,
        'не опознаватель',
        'негодное умолчание — как есть, его отвергнет box'
    )
    t.assert_equals(Device.validate({ id = id, serial = uuid.fromstr(origin) }).serial, origin)

    local _, err = Device.validate({ id = 5, owner = 7ULL, serial = 'нет' })

    t.assert_equals(err.fields, {
        id = 'должно быть UUID, а не 5',
        owner = 'должно быть UUID, а не значением не из Lua',
        serial = "должно быть UUID, а не 'нет'",
    })
    t.assert_equals(Device._key(uuid.fromstr(id)), { id })
    t.assert_equals(Device._key({ id:upper() }), { id })
    t.assert_equals(select(2, Device._key('нет')).fields, { id = "должно быть UUID, а не 'нет'" })

    local field = Device._shape.by_name.serial

    t.assert_equals(validate.check(uuid.fromstr(id), check.search_rule_of(field)), id)
    t.assert_equals(validate.check(uuid.fromstr(id), check.bound_rule_of(field)), id)
    t.assert_equals(
        select(2, validate.check(nil, check.search_rule_of(field))),
        { ['$'] = 'обязательное поле' },
        'у ключа умолчания нет'
    )
end

g.test_unsigned_lower_bound_never_drops_below_zero = function()
    local Counter = model.define({
        space = 'counters',
        fields = { { 'id', 'unsigned', primary = true, min = -10 }, { 'hits', 'unsigned' } },
    })

    local _, err = Counter.validate({ id = -1, hits = -1 })

    t.assert_equals(err.fields, {
        id = 'должно быть целым числом не меньше 0, а не -1',
        hits = 'должно быть целым числом не меньше 0, а не -1',
    })
end

-- Целые от 10^14 по модулю `box` отдаёт cdata, `json.decode` — от 2^53,
-- причём положительные до 2^63 — `int64_t`. Запись с таким ключом обязана
-- проходить свою проверку как есть: приведение к числу Lua потеряло бы
-- младшие цифры.
g.test_wide_integers_pass_as_they_are_within_the_bounds = function()
    local ffi = require('ffi')
    local User = helper.users(model)
    local max = 18446744073709551615ULL
    local record, err = User.validate({ id = max, name = 'Мария', age = 150ULL })

    t.assert_equals(err, nil)
    t.assert_equals(ffi.istype('uint64_t', record.id), true, 'ключ не приведён к числу')
    t.assert_equals(tostring(record.id), '18446744073709551615ULL')
    t.assert_equals(tostring(record.age), '150ULL', 'верхняя граница включительно')

    local decoded = User.validate(require('json').decode('{"id": 9007199254740993, "name": "М", "age": 0}'))

    t.assert_equals(
        tostring(decoded.id),
        '9007199254740993LL',
        'int64_t из JSON годится беззнаковому'
    )
    t.assert_equals(tostring(User.validate({ id = 5, name = 'М', age = 0LL }).age), '0LL')
    t.assert_equals(User._key(max)[1], max)
    t.assert_equals(tostring(User._key({ 9007199254740993ULL })[1]), '9007199254740993ULL')
    t.assert_equals(User.where('id', '>=', max).spec.key, { max })

    local Wide = model.define({
        space = 'wide',
        fields = {
            { 'id', 'integer', primary = true },
            { 'delta', 'integer', max = 5 },
            { 'rank', 'integer', min = -5, max = 5 },
            { 'weight', 'number', min = 0.5, max = 2 },
            { 'total', 'number' },
        },
    })
    local wide = Wide.validate({
        id = -9223372036854775808LL,
        delta = 5LL,
        rank = -5LL,
        weight = 1ULL,
        total = max,
    })

    t.assert_equals(wide:to_table(), {
        id = -9223372036854775808LL,
        delta = 5LL,
        rank = -5LL,
        weight = 1ULL,
        total = max,
    })
    t.assert_equals(Wide.validate({ id = max, delta = 0, rank = 5ULL, weight = 2ULL, total = 0 }).rank, 5ULL)
end

g.test_wide_integers_beyond_the_bounds_are_refused_in_digits = function()
    local User = helper.users(model)
    local _, err = User.validate({ id = -1LL, name = 'Мария', age = 151ULL })

    t.assert_equals(err.fields, {
        id = 'должно быть целым числом не меньше 0, а не -1',
        age = 'должно быть целым числом от 0 до 150, а не 151',
    })

    -- Тот же текст, что у числа Lua за той же границей.
    local _, plain = User.validate({ id = -1, name = 'Мария', age = 151 })

    t.assert_equals(plain.fields, err.fields)
    t.assert_equals(
        select(2, User._key(-9223372036854775808LL)).fields,
        { id = 'должно быть целым числом не меньше 0, а не -9223372036854775808' }
    )
    t.assert_equals(
        select(2, User.where('id', '>=', -1LL):all()).fields,
        { id = 'должно быть целым числом не меньше 0, а не -1' }
    )

    local Wide = model.define({
        space = 'wide',
        fields = {
            { 'id', 'integer', primary = true },
            { 'delta', 'integer', max = 5 },
            { 'rank', 'integer', min = -5, max = 5 },
            { 'weight', 'number', min = 0.5, max = 2 },
            { 'token', 'unsigned', max = 10 },
        },
    })
    local _, wide = Wide.validate({
        id = require('decimal').new(1),
        delta = 6ULL,
        rank = 18446744073709551615ULL,
        weight = 0ULL,
        token = 11ULL,
    })

    t.assert_equals(wide.fields, {
        id = 'должно быть целым числом, а не значением не из Lua',
        delta = 'должно быть целым числом не больше 5, а не 6',
        rank = 'должно быть целым числом от -5 до 5, а не 18446744073709551615',
        weight = 'должно быть числом от 0.5 до 2, а не 0',
        token = 'должно быть целым числом от 0 до 10, а не присланным значением',
    })
    t.assert_equals(select(2, Wide.validate({ id = 1, delta = 1, rank = -6LL, weight = 3ULL, token = 1 })).fields, {
        rank = 'должно быть целым числом от -5 до 5, а не -6',
        weight = 'должно быть числом от 0.5 до 2, а не 3',
    })
end

-- Число Lua за пределом целого рода `box` кладёт как `double` и бросает
-- «expected unsigned, got double»: на узле с данными — исключением, через
-- роутер — `unavailable`, бедой хранилища. Приходит оно снаружи —
-- `json.decode` отдаёт `1e20` числом, — и отказ по нему — `invalid`
-- до шлюза: в записи, в ключе, в условии и в курсоре.
g.test_lua_numbers_beyond_the_kind_are_refused_before_the_gateway = function()
    local User = helper.users(model)
    local gateway, calls = helper.fake_gateway({})

    User._bind(gateway)

    local beyond = 'должно быть целым числом от 0 до 18446744073709551615, а не %s'
    local _, created = User.create(require('json').decode('{"id": 1e20, "name": "Мария", "age": 46}'))

    t.assert_equals(created.kind, 'invalid')
    t.assert_equals(created.fields, { id = beyond:format('1e+20') })
    t.assert_equals(select(2, User.validate({ id = 2 ^ 64, name = 'Мария', age = 2 ^ 64 })).fields, {
        id = beyond:format('1.844674407371e+19'),
        age = 'должно быть целым числом от 0 до 150, а не 1.844674407371e+19',
    }, 'объявленный предел поля важнее предела рода')
    t.assert_equals(select(2, User.find(2 ^ 64)).fields, { id = beyond:format('1.844674407371e+19') })
    t.assert_equals(select(2, User.delete(1e20)).fields, { id = beyond:format('1e+20') })
    t.assert_equals(select(2, User.where('id', '>=', 1e20):all()).fields, { id = beyond:format('1e+20') })
    t.assert_equals(select(2, User.scan():after({ id = 2 ^ 64 }):first()).fields, {
        id = beyond:format('1.844674407371e+19'),
    })
    t.assert_equals(calls, {}, 'к шлюзу не ходили')

    -- 2^64 − 2048 — наибольший double меньше 2^64, и `box` кладёт его
    -- целым (сверено на 3.8): предел рода не отсекает годного.
    t.assert_equals(User.validate({ id = 2 ^ 64 - 2048, name = 'Мария', age = 46 }).id, 2 ^ 64 - 2048)
    t.assert_equals(User._key(2 ^ 64 - 2048), { 2 ^ 64 - 2048 })

    local Ledger = model.define({
        space = 'ledger',
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'delta', 'integer' },
            { 'floor', 'integer', min = -5 },
            { 'ceiling', 'integer', max = 5 },
            { 'hits', 'unsigned', min = 10 },
            { 'token', 'unsigned' },
            { 'total', 'number' },
        },
    })
    local _, below = Ledger.validate({
        id = 1,
        delta = -2 ^ 63 - 2048,
        floor = 1e20,
        ceiling = -1e20,
        hits = 2 ^ 64,
        token = 2 ^ 64,
        total = 1e300,
    })

    local whole =
        'должно быть целым числом от -9223372036854775808 до 18446744073709551615, а не %s'

    t.assert_equals(below.fields, {
        delta = whole:format('-9.2233720368548e+18'),
        floor = 'должно быть целым числом от -5 до 18446744073709551615, а не 1e+20',
        ceiling = 'должно быть целым числом от -9223372036854775808 до 5, а не -1e+20',
        hits = 'должно быть целым числом от 10 до 18446744073709551615, а не 1.844674407371e+19',
        token = 'должно быть целым числом от 0 до 18446744073709551615, а не присланным значением',
    })

    local _, above =
        Ledger.validate({ id = 1, delta = 2 ^ 64, floor = 0, ceiling = 0, hits = 10, token = 0, total = 0 })

    t.assert_equals(above.fields, { delta = whole:format('1.844674407371e+19') })

    -- `number` держит double любой величины: у него предела рода нет.
    local edge = Ledger.validate({
        id = 1,
        delta = -2 ^ 63,
        floor = 2 ^ 64 - 2048,
        ceiling = -2 ^ 63,
        hits = 2 ^ 64 - 2048,
        token = 0,
        total = -1e300,
    })

    t.assert_equals(edge:to_table(), {
        id = 1,
        delta = -2 ^ 63,
        floor = 2 ^ 64 - 2048,
        ceiling = -2 ^ 63,
        hits = 2 ^ 64 - 2048,
        token = 0,
        total = -1e300,
    })
end

-- Предел объявления шире рода ничего не сужает и снимается: иначе отказ
-- за пределом рода назвал бы значение, которого в поле быть не может.
-- Предел ровно на границе рода тоже ничего не сужает; предел внутри рода
-- остаётся.
g.test_declared_bounds_wider_than_the_kind_are_dropped = function()
    local Loose = model.define({
        space = 'loose',
        fields = {
            { 'id', 'integer', primary = true, min = -1e30, max = 1e30 },
            { 'low', 'integer', min = -2 ^ 63 },
            { 'high', 'unsigned', max = 2 ^ 64 },
            { 'kept', 'integer', min = -2 ^ 63 + 2048, max = 2 ^ 64 - 2048 },
        },
    })

    t.assert_equals(select(2, Loose.validate({ id = 1.5, low = 1.5, high = 1.5, kept = 1.5 })).fields, {
        id = 'должно быть целым числом, а не 1.5',
        low = 'должно быть целым числом, а не 1.5',
        high = 'должно быть целым числом не меньше 0, а не 1.5',
        kept = 'должно быть целым числом от -9.2233720368548e+18 до 1.844674407371e+19, а не 1.5',
    })
    local whole =
        'должно быть целым числом от -9223372036854775808 до 18446744073709551615, а не %s'

    t.assert_equals(select(2, Loose.validate({ id = 1e30, low = -2 ^ 64, high = 2 ^ 64, kept = 0 })).fields, {
        id = whole:format('1e+30'),
        low = whole:format('-1.844674407371e+19'),
        high = 'должно быть целым числом от 0 до 18446744073709551615, а не 1.844674407371e+19',
    })
    t.assert_equals(Loose.validate({ id = -2 ^ 63, low = -2 ^ 63, high = 0, kept = 0 }).id, -2 ^ 63)
end

g.test_own_rules_run_after_fields_and_all_at_once = function()
    local seen = {}
    local User = helper.users(model, {
        rules = {
            function(record)
                table.insert(seen, record.age)

                if record.age < 18 then
                    return 'младше 18 нельзя', 'age'
                end

                return nil
            end,
            function(record)
                if record.name == 'Иван' then
                    return 'Иванов не берём'
                end

                return nil
            end,
        },
    })

    local record, err = User.validate({ id = 1, name = 'Иван', age = 17 })

    t.assert_equals(record, nil)
    t.assert_equals(err.fields, { age = 'младше 18 нельзя', ['$'] = 'Иванов не берём' })
    t.assert_equals(seen, { 17 })

    t.assert_equals(User.validate({ id = 1, name = 'Мария', age = 18 }).age, 18)

    -- Правило не зовётся, пока поля не прошли: строка в возрасте не доходит.
    local _, refused = User.validate({ id = 1, name = 'Мария', age = 'сорок' })

    t.assert_equals(
        refused.fields.age,
        "должно быть целым числом от 0 до 150, а не 'сорок'"
    )
    t.assert_equals(seen, { 17, 18 })
end

g.test_trim_does_not_touch_the_input_table = function()
    local User = helper.users(model)
    local input = { id = 1, name = '  Мария ', age = 30 }

    User.validate(input)

    t.assert_equals(input.name, '  Мария ')
end

g.test_trim_cuts_ascii_whitespace_only = function()
    local User = helper.users(model)

    -- Режутся знаки `%s` Lua: пробел, табуляции, переводы строки
    -- и страницы, возврат каретки. Пробелы Юникода остаются — имя
    -- из одного неразрывного пробела проходит `min = 1`.
    t.assert_equals(User.validate({ id = 1, name = ' \t\n\v\f\rИра\r\f\v\n\t ', age = 30 }).name, 'Ира')
    t.assert_equals(User.validate({ id = 1, name = '\u{00A0}', age = 30 }).name, '\u{00A0}')
    t.assert_equals(User.validate({ id = 1, name = '\u{2003}Ира\u{2003}', age = 30 }).name, '\u{2003}Ира\u{2003}')

    local _, err = User.validate({ id = 1, name = ' \t\n ', age = 30 })

    t.assert_equals(
        err.fields.name,
        'должно быть строкой длиной от 1 до 255 знаков, а сейчас 0 знаков'
    )
end

g.test_trim_touches_only_fields_declared_with_it = function()
    local User = helper.users(model)
    local record = User.validate({ id = 1, name = ' Мария ', age = 30, email = ' m@x.ru ' })

    t.assert_equals(record.name, 'Мария')
    t.assert_equals(record.email, ' m@x.ru ', 'у поля без trim пробелы остаются')

    local _, err = User.validate({ id = 1, name = 'Мария', age = 30, nick = ' ник ' })

    t.assert_equals(err.fields, { nick = 'неизвестное поле' })
end

g.test_search_rule_drops_default_and_optional = function()
    local check = helper.module('tnt.model.check')
    local validate = helper.module('tnt.validate')
    local field = { name = 'status', type = 'string', default = 'new', optional = true }

    t.assert_equals(validate.check(nil, check.rule_of(field, false)), 'new')
    t.assert_equals(
        select(2, validate.check(nil, check.search_rule_of(field))),
        { ['$'] = 'обязательное поле' }
    )
    t.assert_equals(validate.check('done', check.search_rule_of(field)), 'done')
end

g.test_key_of_checks_parts_by_primary_rules = function()
    local User = helper.users(model)
    local check = helper.module('tnt.model.check')

    t.assert_equals(User._key(7), { 7 })
    t.assert_equals(User._key({ 7 }), { 7 })

    local _, err = User._key('abc')

    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(
        err.fields,
        { id = "должно быть целым числом не меньше 0, а не 'abc'" }
    )

    local _, two = User._key({ 1, 2 })

    t.assert_equals(two.fields, { ['$'] = 'ключ — 1 значение: id' })

    local Link = model.define({
        space = 'links',
        fields = { { 'left', 'unsigned', primary = true }, { 'right', 'string', primary = true, optional = false } },
    })

    t.assert_equals(Link._key({ 1, 'a' }), { 1, 'a' })
    t.assert_equals(
        select(2, Link._key(1)).fields,
        { ['$'] = 'ключ — 2 значения по порядку: left, right' }
    )
    t.assert_equals(
        select(2, Link._key({ 1, 2 })).fields,
        { right = 'должно быть строкой, а не 2' }
    )
    t.assert_equals(check.key_from(Link._shape, { left = 5, right = 'b', extra = 1 }), { 5, 'b' })
end

g.test_failure_kinds_wire_and_concat = function()
    local err = failure().new('readonly', 'узел только для чтения')

    t.assert_equals(failure().is(err), true)
    t.assert_equals(failure().is({ kind = 'readonly' }), false)
    t.assert_equals(
        failure().to_wire(err),
        { ok = false, kind = 'readonly', message = 'узел только для чтения' }
    )

    local back = failure().from_wire({ ok = false, kind = 'invalid', message = 'плохо', fields = { a = 'b' } })

    t.assert_equals(failure().is(back), true)
    t.assert_equals(back.kind, 'invalid')
    t.assert_equals(back.message, 'плохо')
    t.assert_equals(back.fields, { a = 'b' })
    t.assert_equals(err .. '!', 'узел только для чтения!')
    t.assert_equals({
        failure().INVALID,
        failure().CONFLICT,
        failure().READONLY,
        failure().UNAVAILABLE,
        failure().MISROUTED,
        failure().UNKNOWN,
    }, { 'invalid', 'conflict', 'readonly', 'unavailable', 'misrouted', 'unknown' })
end
