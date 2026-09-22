--- Шлюз `sharded` над двойником роутера vshard: бакет от ключа,
--- вызовы общих функций, веер по репликасетам и слияние страниц.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.sharded')

---@type any
local model

---@type any
local calls

---@type any
local answers

--- Двойник роутера: бакет — хеш, как у настоящего; ответы заготовлены.
---@return table
local function fake_router()
    local hash = require('vshard.hash')

    local router = {
        bucket_id_mpcrc32 = function(key)
            return hash.mpcrc32(key) % 100 + 1
        end,
        map_callrw = function(name, args, opts)
            table.insert(calls, { mode = 'map', name = name, args = args, opts = opts })

            return answers.map, answers.map_err
        end,
    }

    for _, mode in ipairs({ 'callro', 'callrw' }) do
        router[mode] = function(bucket_id, name, args, opts)
            table.insert(calls, { mode = mode, bucket_id = bucket_id, name = name, args = args, opts = opts })

            return answers.reply, answers.err
        end
    end

    return router
end

--- Модель пользователей на шлюзе `sharded` с двойником роутера.
---@return any
local function bound()
    local User = helper.users(model)
    local gateway = helper.module('tnt.model.gateway.sharded').new({ timeout = 3 })

    User._bind(gateway)

    return User
end

g.before_each(function()
    model = helper.load()
    calls = {}
    answers = {}

    model._set_source({
        router = fake_router,
        config = function()
            return helper.fake_config({ sharding_roles = { 'router' } })
        end,
    })
end)

g.after_each(function()
    model._set_source(nil)
    helper.unload()
end)

g.test_find_goes_to_the_bucket_of_the_key_by_callro = function()
    answers.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    local User = bound()
    local record, err = User.find(7)

    t.assert_equals(err, nil)
    t.assert_equals(record:is_adult(), true)
    t.assert_equals(User.bound(), 'sharded')
    t.assert_equals(calls, {
        { mode = 'callro', bucket_id = 98, name = 'tnt_model_find', args = { 'users', { 7 } }, opts = { timeout = 3 } },
    })

    answers.reply = { ok = true }

    t.assert_equals(User.find(7), nil)
end

g.test_writes_go_by_callrw_with_values_and_mode = function()
    answers.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    local User = bound()

    t.assert_equals(User.create({ id = 7, name = ' Мария ', age = 46 }).name, 'Мария')
    t.assert_equals(calls[1], {
        mode = 'callrw',
        bucket_id = 98,
        name = 'tnt_model_put',
        args = { 'users', { id = 7, name = 'Мария', age = 46 }, 'insert' },
        opts = { timeout = 3 },
    })

    User.validate({ id = 7, name = 'Мария', age = 47 }):save()

    t.assert_equals(calls[2].args, { 'users', { id = 7, name = 'Мария', age = 47 }, 'replace' })

    answers.reply = { ok = true, value = true }

    t.assert_equals(User.delete(7), true)
    t.assert_equals(calls[3], {
        mode = 'callrw',
        bucket_id = 98,
        name = 'tnt_model_delete',
        args = { 'users', { 7 } },
        opts = { timeout = 3 },
    })
end

g.test_storage_refusal_and_vshard_error_become_failures = function()
    local User = bound()

    answers.reply = { ok = false, kind = 'conflict', message = 'занято' }

    local _, conflict = User.create({ id = 7, name = 'a', age = 1 })

    t.assert_equals(conflict.kind, 'conflict')
    t.assert_equals(tostring(conflict), 'занято')

    answers.reply = { ok = false, kind = 'invalid', message = 'плохо', fields = { age = 'нет' } }

    local _, invalid = User.find(7)

    t.assert_equals(invalid.fields, { age = 'нет' })

    answers.reply = nil
    answers.err = { message = 'Timeout exceeded', code = 5 }

    local _, timeout = User.find(7)

    t.assert_equals(timeout.kind, 'unavailable')
    t.assert_equals(tostring(timeout), 'хранилище не ответило: Timeout exceeded')

    answers.err = 'обрыв'

    local _, broken = User.delete(7)

    t.assert_equals(tostring(broken), 'хранилище не ответило: обрыв')
end

g.test_primary_equality_goes_to_one_bucket_and_the_rest_fans_out = function()
    answers.reply = { ok = true, value = { { id = 7, name = 'a', age = 1 } } }

    local User = bound()

    t.assert_equals(User.where('id', '=', 7):all()[1].id, 7)
    t.assert_equals(calls[1].mode, 'callro')
    t.assert_equals(calls[1].bucket_id, 98)
    t.assert_equals(calls[1].name, 'tnt_model_select')
    t.assert_equals(calls[1].args[2].index, 'primary')

    answers.reply = { ok = true, value = 1 }

    t.assert_equals(User.where('id', '=', 7):count(), 1)
    t.assert_equals(calls[2].name, 'tnt_model_count')

    answers.map = {
        ['storage-001'] = { { ok = true, value = { { id = 1, age = 20 }, { id = 4, age = 30 } } } },
        ['storage-002'] = { { ok = true, value = { { id = 2, age = 20 }, { id = 3, age = 25 } } } },
    }

    local page = User.where('age', '>=', 20):limit(3):all()

    t.assert_equals(calls[3].mode, 'map')
    t.assert_equals(calls[3].name, 'tnt_model_select')
    t.assert_equals(calls[3].args, { 'users', { index = 'age', iterator = 'GE', key = { 20 }, limit = 3 } })
    t.assert_equals(calls[3].opts, { timeout = 3 })
    t.assert_equals({ page[1].id, page[2].id, page[3].id }, { 1, 2, 3 })
    t.assert_equals(page[3]:is_adult(), true)

    answers.map = { ['storage-001'] = { { ok = true, value = 2 } }, ['storage-002'] = { { ok = true, value = 3 } } }

    t.assert_equals(User.where('age', '>=', 20):count(), 5)
    t.assert_equals(User.scan():count(), 5)
    t.assert_equals(calls[5].args[2].index, 'primary')
    t.assert_equals(
        calls[5].mode,
        'map',
        'обход по первичному ключу без равенства идёт веером'
    )
end

-- Ключ за точностью double: бакет считается от значения, а не от рода —
-- `int64_t` из JSON и `uint64_t` из `box` ложатся в один бакет, — а ключ
-- уходит хранилищу cdata, без приведения к числу.
g.test_wide_keys_go_to_the_bucket_of_their_value = function()
    local ffi = require('ffi')
    local hash = require('vshard.hash')
    local max = 18446744073709551615ULL

    answers.reply = { ok = true, value = { id = max, name = 'Мария', age = 46 } }

    local User = bound()
    local found = User.find(max)

    found.age = 47
    found:save()
    User.find(9007199254740993LL)
    User.find(9007199254740993ULL)

    t.assert_equals(calls[1].bucket_id, hash.mpcrc32(max) % 100 + 1)
    t.assert_equals(calls[1].args, { 'users', { max } })
    t.assert_equals(ffi.istype('uint64_t', calls[1].args[2][1]), true)
    t.assert_equals(calls[2].mode, 'callrw')
    t.assert_equals(calls[2].bucket_id, calls[1].bucket_id)
    t.assert_equals(calls[2].args, { 'users', { id = max, name = 'Мария', age = 47 }, 'replace' })
    t.assert_equals(calls[3].bucket_id, hash.mpcrc32(9007199254740993ULL) % 100 + 1)
    t.assert_equals(calls[4].bucket_id, calls[3].bucket_id)
    t.assert_not_equals(
        calls[3].bucket_id,
        hash.mpcrc32(2 ^ 53) % 100 + 1,
        'число Lua 2^53 + 1 — это уже 2^53, и бакет у него свой'
    )

    -- Страница с двух хранилищ сливается по ключу точно: число Lua
    -- и cdata вперемешку, как их отдаёт net.box.
    answers.map = {
        ['storage-001'] = { { ok = true, value = { { id = 7, age = 20 }, { id = max, age = 20 } } } },
        ['storage-002'] = { { ok = true, value = { { id = 9007199254740993ULL, age = 20 } } } },
    }

    local page = User.where('age', '=', 20):limit(2):all()

    t.assert_equals({ tostring(page[1].id), tostring(page[2].id) }, { '7', '9007199254740993ULL' })

    User.where('age', '=', 20):limit(2):after(page[2]):all()

    t.assert_equals(calls[#calls].args[2].after, { age = 20, id = 9007199254740993ULL })
    t.assert_equals(ffi.istype('uint64_t', calls[#calls].args[2].after.id), true)
end

g.test_composite_key_with_shard_key_not_first_fans_out_on_equality = function()
    local Link = model.define({
        space = 'links',
        fields = {
            { 'left', 'unsigned', primary = true },
            { 'right', 'unsigned', primary = true },
            model.bucket_of('right'),
        },
    })

    Link._bind(helper.module('tnt.model.gateway.sharded').new({ timeout = 1 }))
    answers.map = { one = { { ok = true, value = { { left = 1, right = 2 } } } } }

    t.assert_equals(Link.where('left', '=', 1):all()[1].right, 2)
    t.assert_equals(calls[1].mode, 'map')

    answers.reply = { ok = true, value = { left = 1, right = 2 } }

    t.assert_equals(Link.find({ 1, 2 }).right, 2)
    t.assert_equals(calls[2].bucket_id, require('vshard.hash').mpcrc32(2) % 100 + 1)
end

g.test_fan_out_refusals_and_errors_stop_the_page = function()
    local User = bound()

    answers.map = nil
    answers.map_err = { message = 'нет ссылки' }

    local _, err = User.where('age', '>=', 1):all()

    t.assert_equals(tostring(err), 'хранилище не ответило: нет ссылки')

    local _, count_err = User.where('age', '>=', 1):count()

    t.assert_equals(count_err.kind, 'unavailable')

    answers.map_err = nil
    answers.map = {
        a = { { ok = true, value = {} } },
        b = {
            {
                ok = false,
                kind = 'unknown',
                message = 'спейс users этим узлом не обслуживается',
            },
        },
    }

    local _, unknown = User.where('age', '>=', 1):all()

    t.assert_equals(unknown.kind, 'unknown')
    t.assert_equals(User.where('age', '>=', 1):count(), nil)
end

g.test_atomic_is_impossible_through_the_router = function()
    local User = bound()
    local binding = model.bind({ User }, model.settings({ source = 'sharded' }))

    t.assert_error_msg_equals(
        'транзакция через роутер невозможна: box.atomic живёт в функции хранилища, которую роутер зовёт callrw',
        binding.gateway.atomic,
        function() end
    )
    binding.gateway.close()
end
