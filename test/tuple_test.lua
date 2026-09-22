--- Проверки раскладки: запись ↔ кортеж, бакет, курсор страницы, порядок.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.tuple')

---@type any
local model

---@type any
local tuple

---@type any
local order

---@type TntModelShape
local shape

g.before_each(function()
    model = helper.load()
    tuple = helper.module('tnt.model.tuple')
    order = helper.module('tnt.model.order')
    shape = helper.users(model)._shape
end)

g.after_each(helper.unload)

--- Хеш, как у vshard: настоящий модуль ставится в Tarantool вместе с ним.
local hash = require('vshard.hash')

g.test_names_and_tuple_with_and_without_bucket = function()
    t.assert_equals(tuple.names_of(shape, true), { 'id', 'bucket_id', 'name', 'age', 'email' })
    t.assert_equals(tuple.names_of(shape, false), { 'id', 'name', 'age', 'email' })

    local values = { id = 7, name = 'Мария', age = 46 }

    t.assert_equals(tuple.to_tuple(shape, true, values, 98), { 7, 98, 'Мария', 46, box.NULL })
    t.assert_equals(tuple.to_tuple(shape, false, values), { 7, 'Мария', 46, box.NULL })
    t.assert_equals(tuple.from_tuple(shape, true, { 7, 98, 'Мария', 46, box.NULL }), values)
    t.assert_equals(tuple.from_tuple(shape, false, { 7, 'Мария', 46, 'm@x.ru' }), {
        id = 7,
        name = 'Мария',
        age = 46,
        email = 'm@x.ru',
    })
    t.assert_equals(tuple.from_tuple(shape, true, box.tuple.new({ 7, 98, 'Мария', 46 })), values)
end

-- Поле `uuid` спейса держит cdata и строки не примет ни в кортеже, ни в
-- ключе, ни в курсоре, а у записи опознаватель — строка. Переводится
-- только поле `uuid`: строка того же вида в строковом поле — строка.
-- Строка, которая не UUID, идёт в `box` как есть — пустота на её месте
-- легла бы в необязательное поле молча.
g.test_uuid_fields_are_cdata_in_the_tuple_and_strings_in_the_record = function()
    local uuid = require('uuid')
    local id = '6ba7b810-9dad-41d1-80b4-00c04fd430c8'
    local owner = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
    local Device = model.define({
        space = 'devices',
        fields = {
            { 'id', 'uuid', primary = true },
            model.bucket_of('id'),
            { 'owner', 'uuid', optional = true },
            { 'label', 'string' },
        },
        indexes = { owner = { parts = { 'owner' }, unique = false } },
    })
    local devices = Device._shape

    local stored = tuple.to_tuple(devices, true, { id = id, owner = owner, label = id }, 5)

    t.assert_equals({ uuid.is_uuid(stored[1]), stored[2], uuid.is_uuid(stored[3]), stored[4] }, { true, 5, true, id })
    t.assert_equals({ tostring(stored[1]), tostring(stored[3]) }, { id, owner })

    local empty = tuple.to_tuple(devices, false, { id = uuid.fromstr(id), label = 'x' })

    t.assert_equals({ tostring(empty[1]), empty[2], empty[3] }, { id, box.NULL, 'x' })
    t.assert_equals(
        tuple.to_tuple(devices, false, { id = 'не опознаватель', label = 'x' })[1],
        'не опознаватель'
    )

    local values = tuple.from_tuple(devices, true, box.tuple.new(stored))

    t.assert_equals(values, { id = id, owner = owner, label = id })
    t.assert_equals({ type(values.id), type(values.owner) }, { 'string', 'string' })

    local key = tuple.stored_key(devices, { 'owner', 'id' }, { owner, id })

    t.assert_equals({ uuid.is_uuid(key[1]), tostring(key[1]), uuid.is_uuid(key[2]), tostring(key[2]) }, {
        true,
        owner,
        true,
        id,
    })
    t.assert_equals(tuple.stored_key(shape, { 'id' }, { 7 }), { 7 })
    t.assert_equals(tuple.stored_key(devices, { 'owner' }, {}), {})

    local cursor = tuple.cursor_of(devices, false, devices.indexes[2], { id = id, owner = owner, label = 'x' })

    t.assert_equals({ tostring(cursor[1]), tostring(cursor[2]), cursor[3] }, { id, owner, box.NULL })
    t.assert_equals({ uuid.is_uuid(cursor[1]), uuid.is_uuid(cursor[2]) }, { true, true })
end

g.test_bucket_is_computed_from_the_shard_key_like_the_router = function()
    t.assert_equals(tuple.shard_key_of(shape, { 7 }), 7)
    t.assert_equals(tuple.bucket_of(hash, 7, 100), hash.mpcrc32(7) % 100 + 1)
    t.assert_equals(tuple.bucket_of(hash, 7, 100), 98)
    t.assert_equals(tuple.bucket_of(hash, 'a', 100), hash.mpcrc32('a') % 100 + 1)

    local Link = model.define({
        space = 'links',
        fields = {
            { 'left', 'unsigned', primary = true },
            { 'right', 'string', primary = true },
            model.bucket_of('right'),
        },
    })

    t.assert_equals(tuple.shard_key_of(Link._shape, { 1, 'b' }), 'b')

    local Plain = model.define({ space = 'plain', fields = { { 'id', 'unsigned', primary = true } } })

    t.assert_equals(tuple.shard_key_of(Plain._shape, { 1 }), nil)
end

g.test_cursor_carries_index_parts_and_primary_key_only = function()
    local index = { name = 'age', parts = { 'age' }, unique = false }

    t.assert_equals(tuple.cursor_of(shape, true, index, { id = 7, age = 46, name = 'Мария' }), {
        7,
        box.NULL,
        box.NULL,
        46,
        box.NULL,
    })
    t.assert_equals(tuple.cursor_of(shape, false, index, { id = 7, age = 46 }), { 7, box.NULL, 46, box.NULL })

    local missing, name = tuple.cursor_of(shape, false, index, { id = 7 })

    t.assert_equals(missing, nil)
    t.assert_equals(name, 'age')
end

-- Запись без значения необязательного поля стоит в индексе на месте
-- NULL: пустая часть курсора — `box.NULL` на своём месте, а не нехватка
-- и не дыра. `box.NULL == nil` истинно, поэтому место сверяется родом:
-- дыра дала бы `nil`, и сравнение таблиц её не заметило бы.
g.test_cursor_puts_null_for_an_empty_optional_part = function()
    local index = { name = 'email', parts = { 'email' }, unique = false }

    for _, after in ipairs({ { id = 7 }, { id = 7, email = box.NULL } }) do
        local cursor = tuple.cursor_of(shape, false, index, after)

        t.assert_equals(cursor, { 7, box.NULL, box.NULL, box.NULL })
        t.assert_equals(type(cursor[4]), 'cdata', 'пустая почта — NULL, а не дыра')
    end

    t.assert_equals(tuple.cursor_of(shape, true, index, { id = 7, email = 'm@x.ru', age = 46 }), {
        7,
        box.NULL,
        box.NULL,
        box.NULL,
        'm@x.ru',
    })

    local missing, name = tuple.cursor_of(shape, false, index, { email = 'm@x.ru' })

    t.assert_equals(missing, nil)
    t.assert_equals(name, 'id', 'обязательной части ключа пустота не прощается')
end

g.test_compare_handles_numbers_strings_booleans_and_cdata = function()
    t.assert_equals(order.compare(1, 2), -1)
    t.assert_equals(order.compare(2, 1), 1)
    t.assert_equals(order.compare(2, 2), 0)
    t.assert_equals(order.compare('a', 'b'), -1)
    t.assert_equals(order.compare(false, true), -1)
    t.assert_equals(order.compare(true, false), 1)
    t.assert_equals(order.compare(true, true), 0)
    t.assert_equals(order.compare(1ULL, 2ULL), -1)
    t.assert_equals(order.compare(2ULL, 1ULL), 1)
    t.assert_equals(order.compare(2ULL, 2ULL), 0)

    -- Пустое значение необязательного поля — раньше любого, как NULL в индексе.
    t.assert_equals(order.compare(nil, 1), -1)
    t.assert_equals(order.compare(1, nil), 1)
    t.assert_equals(order.compare(nil, false), -1)
    t.assert_equals(order.compare(nil, nil), 0)
    t.assert_equals(order.compare_by({ 'age', 'id' }, { age = 1, id = 5 }, { age = 1, id = 3 }), 1)
    t.assert_equals(order.compare_by({ 'age', 'id' }, { age = 1, id = 5 }, { age = 2, id = 3 }), -1)
    t.assert_equals(order.compare_by({ 'age', 'id' }, { age = 1, id = 5 }, { age = 1, id = 5 }), 0)
    t.assert_equals(order.names_of(shape, { name = 'age', parts = { 'age' } }), { 'age', 'id' })
    t.assert_equals(order.names_of(shape, { name = 'primary', parts = { 'id' } }), { 'id' })
    t.assert_equals(order.descending('LT'), true)
    t.assert_equals(order.descending('LE'), true)
    t.assert_equals(order.descending('GE'), false)
    t.assert_equals(order.descending('ALL'), false)
end

-- Целые 64-битные cdata приходят из `box` и net.box вперемешку с числами
-- Lua: от 10^14 по модулю — cdata. Сравнение `<` LuaJIT приводит обе
-- стороны к `uint64_t`, стоит одной быть им, и путает знак; здесь порядок
-- сверен с точной арифметикой по каждой развилке сравнения.
g.test_compare_orders_wide_integers_exactly = function()
    local max = 18446744073709551615ULL
    local min = -9223372036854775808LL

    t.assert_equals(order.is_wide(5ULL), true)
    t.assert_equals(order.is_wide(5LL), true)
    t.assert_equals(order.is_wide(5), false)
    t.assert_equals(order.is_wide(box.NULL), false)
    t.assert_equals(order.is_wide(require('decimal').new(5)), false)

    -- Отрицательное против `uint64_t`: LuaJIT счёл бы -1 равным 2^64 − 1.
    t.assert_equals(order.compare(-1, 5ULL), -1)
    t.assert_equals(order.compare(5ULL, -1), 1)
    t.assert_equals(order.compare(-1LL, max), -1)
    t.assert_equals(order.compare(max, -1LL), 1)
    t.assert_equals(order.compare(max, max), 0)

    -- Половины: `int64_t` не держит 2^63, и значения по разные стороны
    -- от него различает половина, а в одной половине — её тип.
    t.assert_equals(order.compare(9223372036854775808ULL, 9223372036854775807LL), 1)
    t.assert_equals(order.compare(9223372036854775807LL, 9223372036854775808ULL), -1)
    t.assert_equals(order.compare(9223372036854775807LL, 9223372036854775807ULL), 0)
    t.assert_equals(order.compare(9223372036854775809ULL, 9223372036854775808ULL), 1)
    t.assert_equals(order.compare(2 ^ 63, 9223372036854775808ULL), 0)
    t.assert_equals(order.compare(2 ^ 63, 9223372036854775809ULL), -1)
    t.assert_equals(order.compare(6917529027641081858LL, 6917529027641081857ULL), 1)

    -- Число Lua за пределами целых cdata дальше от нуля любого из них.
    t.assert_equals(order.compare(2 ^ 64, max), 1)
    t.assert_equals(order.compare(max, 2 ^ 64), -1)
    t.assert_equals(order.compare(math.huge, max), 1)
    t.assert_equals(order.compare(-2 ^ 63 - 2048, min), -1)
    t.assert_equals(order.compare(min, -2 ^ 63 - 2048), 1)
    t.assert_equals(order.compare(-2 ^ 63, min), 0)
    t.assert_equals(order.compare(-2 ^ 62 * 1.5, min), 1)
    t.assert_equals(order.compare(-math.huge, 0LL), -1)

    -- В пределах типа: целые части, затем дробь числа Lua.
    t.assert_equals(order.compare(-1, -5LL), 1)
    t.assert_equals(order.compare(-2, -5LL), 1)
    t.assert_equals(order.compare(9, 7LL), 1)
    t.assert_equals(order.compare(7ULL, 5), 1)
    t.assert_equals(order.compare(5, 7ULL), -1)
    t.assert_equals(order.compare(2 ^ 60, 1152921504606846976ULL), 0)
    t.assert_equals(order.compare(1152921504606846976LL, 1152921504606846976ULL), 0)
    t.assert_equals(order.compare(100000000000000ULL, 1e14 + 0.5), -1)
    t.assert_equals(order.compare(1e14 + 0.5, 100000000000000ULL), 1)
    t.assert_equals(order.compare(5ULL, 5.5), -1)
    t.assert_equals(order.compare(-2LL, -1.5), -1)
    t.assert_equals(order.compare(-1.5, -2LL), 1)
end

-- Не-число лежит в поле `number`, записанном мимо модели, и индекс TREE
-- ставит его раньше любого числа, даже `-inf` (сверено на 3.8). Против
-- целого cdata ответ обязан быть тем же, что против числа Lua, и не
-- зависеть от машины: `ffi.cast` не-числа к целому типу на x86 даёт
-- `-2^63`, на arm64 — ноль.
g.test_compare_puts_nan_before_every_number_like_the_index = function()
    local nan = 0 / 0

    t.assert_equals(order.compare(nan, 1LL), -1)
    t.assert_equals(order.compare(1LL, nan), 1)
    t.assert_equals(order.compare(nan, 1ULL), -1)
    t.assert_equals(order.compare(1ULL, nan), 1)
    t.assert_equals(
        order.compare(nan, -9223372036854775808LL),
        -1,
        'на x86 приведение дало бы равенство'
    )
    t.assert_equals(order.compare(0LL, nan), 1, 'на arm64 приведение дало бы равенство')
    t.assert_equals(order.compare(nan, 1), -1)
    t.assert_equals(order.compare(1, nan), 1)
    t.assert_equals(order.compare(nan, -math.huge), -1)
    t.assert_equals(order.compare(-math.huge, nan), 1)
    t.assert_equals(order.compare(nan, nan), 0)

    -- Пустое значение — ещё раньше: NULL в индексе идёт перед числами.
    t.assert_equals(order.compare(nil, nan), -1)
    t.assert_equals(order.compare(nan, nil), 1)

    local index = { name = 'score', parts = { 'score' }, unique = false }
    local merged = order.merged(shape, index, 'GE', {
        { { id = 1, score = 5ULL }, { id = 4, score = nan } },
        { { id = 3, score = -1LL }, { id = 2, score = nan }, { id = 5 } },
    }, 10)

    t.assert_equals(
        helper.ids(merged),
        { 5, 2, 4, 3, 1 },
        'пустое, затем NaN по ключу, затем числа'
    )
end

g.test_cursor_and_merged_pages_keep_wide_keys = function()
    local index = { name = 'age', parts = { 'age' }, unique = false }
    local max = 18446744073709551615ULL

    t.assert_equals(tuple.cursor_of(shape, false, index, { id = max, age = 0ULL }), { max, box.NULL, 0ULL, box.NULL })

    local merged = order.merged(shape, index, 'GE', {
        { { id = max, age = 20 }, { id = 5, age = 30 } },
        { { id = 9007199254740993ULL, age = 20 }, { id = 7, age = 20 } },
    }, 10)
    local ids = {}

    for position, row in ipairs(merged) do
        ids[position] = tostring(row.id)
    end

    t.assert_equals(ids, { '7', '9007199254740993ULL', '18446744073709551615ULL', '5' })
end

g.test_merged_pages_follow_index_order_and_limit = function()
    local index = { name = 'age', parts = { 'age' }, unique = false }
    local left = { { id = 1, age = 20 }, { id = 4, age = 30 } }
    local right = { { id = 2, age = 20 }, { id = 3, age = 25 } }

    t.assert_equals(order.merged(shape, index, 'GE', { left, right }, 10), {
        { id = 1, age = 20 },
        { id = 2, age = 20 },
        { id = 3, age = 25 },
        { id = 4, age = 30 },
    })
    t.assert_equals(order.merged(shape, index, 'GE', { left, right }, 3), {
        { id = 1, age = 20 },
        { id = 2, age = 20 },
        { id = 3, age = 25 },
    })
    t.assert_equals(
        order.merged(
            shape,
            index,
            'LE',
            { { { id = 4, age = 30 }, { id = 1, age = 20 } }, { { id = 3, age = 25 } } },
            2
        ),
        { { id = 4, age = 30 }, { id = 3, age = 25 } }
    )
    t.assert_equals(order.merged(shape, index, 'GE', {}, 5), {})
end

g.test_merged_pages_put_empty_values_first_like_the_index = function()
    local index = { name = 'email', parts = { 'email' }, unique = false }
    local left = { { id = 3, email = 'b@x.ru' }, { id = 2 } }
    local right = { { id = 4, email = 'a@x.ru' }, { id = 1 } }

    t.assert_equals(order.merged(shape, index, 'LT', { left, right }, 10), {
        { id = 3, email = 'b@x.ru' },
        { id = 4, email = 'a@x.ru' },
        { id = 2 },
        { id = 1 },
    })
    t.assert_equals(order.merged(shape, index, 'GE', { left, right }, 3), {
        { id = 1 },
        { id = 2 },
        { id = 4, email = 'a@x.ru' },
    })
end

-- Место курсора относительно выборки: раньше начала выборка идёт целиком,
-- за концом равенства страница пуста, остальное — в выборке, и дальше
-- решает `box`. `>` и `<` не берут записей со значением ключа, и курсор
-- с ним стоит ещё до начала. По убыванию «раньше» — больше ключа.
g.test_cursor_is_placed_before_inside_or_past_the_selection = function()
    --- Место курсора по возрасту: { раньше начала, за концом }.
    local function placed(iterator, key, age)
        return { order.placed({ 'age' }, iterator, key, { age = age, id = 1 }) }
    end

    t.assert_equals(placed('GE', { 100 }, 5), { true, false })
    t.assert_equals(placed('GE', { 100 }, 100), { false, false })
    t.assert_equals(placed('GE', { 100 }, 149), { false, false }, 'конец диапазона видит box')
    t.assert_equals(placed('ALL', { 100 }, 5), { true, false }, 'ALL с ключом идёт от него, как GE')
    t.assert_equals(
        placed('ALL', {}, 5),
        { false, false },
        'без ключа начало выборки — начало индекса'
    )
    t.assert_equals(placed('GT', { 100 }, 99), { true, false })
    t.assert_equals(placed('GT', { 100 }, 100), { true, false })
    t.assert_equals(placed('GT', { 100 }, 101), { false, false })
    t.assert_equals(placed('LE', { 100 }, 101), { true, false })
    t.assert_equals(placed('LE', { 100 }, 100), { false, false })
    t.assert_equals(placed('LE', { 100 }, 99), { false, false })
    t.assert_equals(placed('LT', { 100 }, 101), { true, false })
    t.assert_equals(placed('LT', { 100 }, 100), { true, false })
    t.assert_equals(placed('LT', { 100 }, 99), { false, false })
    t.assert_equals(placed('EQ', { 100 }, 99), { true, false })
    t.assert_equals(placed('EQ', { 100 }, 100), { false, false })
    t.assert_equals(placed('EQ', { 100 }, 101), { false, true })
end

-- Части курсора сверяются с частями ключа по порядку индекса и только
-- с ними: неполный ключ оставляет остальные части `box`. Пустая часть
-- курсора — раньше любого значения, как NULL в индексе: по возрастанию
-- она до начала выборки, по убыванию — в её конце.
g.test_cursor_is_placed_by_the_key_parts_only = function()
    local parts = { 'kind', 'label' }

    t.assert_equals({ order.placed(parts, 'GE', { 'x', 'a' }, { kind = 'x', id = 4 }) }, { true, false })
    t.assert_equals({ order.placed(parts, 'GE', { 'x', 'a' }, { kind = 'x', label = box.NULL }) }, { true, false })
    t.assert_equals({ order.placed(parts, 'GE', { 'x', 'a' }, { kind = 'x', label = 'b' }) }, { false, false })
    t.assert_equals({ order.placed(parts, 'LE', { 'x', 'a' }, { kind = 'x' }) }, { false, false })
    t.assert_equals({ order.placed(parts, 'EQ', { 'x', 'a' }, { kind = 'x', label = 'b' }) }, { false, true })
    t.assert_equals({ order.placed(parts, 'EQ', { 'x', 'a' }, { kind = 'w', label = 'z' }) }, { true, false })
    t.assert_equals(
        { order.placed(parts, 'EQ', { 'x' }, { kind = 'x', label = 'b' }) },
        { false, false },
        'вторая часть не в ключе — место в выборке'
    )
end
