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
