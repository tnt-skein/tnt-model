--- Шлюз `sharded` над двойником роутера vshard: бакет от ключа,
--- вызовы общих функций, веер по репликасетам и слияние страниц, повтор
--- веера, застигнутого перечитыванием роутера, и имя репликасета в отказе.
--- Транзакция — над двойниками `box` и хранилища vshard: выделенный
--- роутер отказывает записи в ней, узел «и роутер, и хранилище» идёт
--- к своему бакету шлюзом `local` под ссылкой до конца транзакции.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.sharded')

---@type any
local model

---@type any
local calls

---@type any
local answers

---@type boolean Идёт ли транзакция на двойнике box
local in_txn

---@type function[] Триггеры фиксации, поставленные на двойнике box
local commits

---@type function[] Триггеры отката, поставленные на двойнике box
local rollbacks

---@type table[] Ссылки на бакеты у двойника хранилища: взятые и снятые, по порядку
local refs

---@type any Двойник часов: время стоит, пока его не сдвинет ответ веера
local clock

--- Ошибка vshard, какой хранилище отказывает в ссылке на бакет.
---@param name string Имя ошибки vshard
---@param message string
---@return table
local function vshard_error(name, message)
    return { type = 'ShardingError', name = name, message = message }
end

--- Текст vshard, которым веер отказывает, когда роутер перечитал
--- конфигурацию посреди него.
local OUTDATED_TEXT = 'Object is outdated after module reload/reconfigure. Use new instance.'

--- Ошибка vshard о прежних объектах репликасетов.
---@return table
local function outdated()
    return vshard_error('OBJECT_IS_OUTDATED', OUTDATED_TEXT)
end

--- Двойник хранилища vshard: ссылка берётся либо отказывает заготовленной
--- ошибкой `answers.ref_err`.
---@return table
local function fake_storage()
    return {
        bucket_ref = function(bucket_id, mode)
            table.insert(refs, { 'ref', bucket_id, mode })

            if answers.ref_err ~= nil then
                return nil, answers.ref_err
            end

            return true
        end,
        bucket_unref = function(bucket_id, mode)
            table.insert(refs, { 'unref', bucket_id, mode })

            return true
        end,
    }
end

--- Двойник роутера: бакет — хеш, как у настоящего; ответы заготовлены.
---
--- Веер отвечает по очереди из `answers.turns` — карта, ошибка,
--- репликасет и сколько секунд попытка шла по двойнику часов, — а когда
--- очередь пуста, одним ответом `answers.map`, `answers.map_err`,
--- `answers.map_replicaset`.
---@return table
local function fake_router()
    local hash = require('vshard.hash')

    local router = {
        bucket_id_mpcrc32 = function(key)
            return hash.mpcrc32(key) % 100 + 1
        end,
        map_callrw = function(name, args, opts)
            table.insert(calls, { mode = 'map', name = name, args = args, opts = opts })

            local turn = table.remove(answers.turns or {}, 1)

            if turn ~= nil then
                clock.pass(turn.took or 0)

                return turn.map, turn.err, turn.replicaset
            end

            return answers.map, answers.map_err, answers.map_replicaset
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
---@param here table|nil Шлюз к бакетам узла — у узла «и роутер, и хранилище»
---@return any User
---@return table gateway
local function bound(here)
    local User = helper.users(model)
    local gateway = helper.module('tnt.model.gateway.sharded').new({ timeout = 3, here = here })

    User._bind(gateway)

    return User, gateway
end

--- Модель на узле «и роутер, и хранилище»: шлюз к своим бакетам — двойник.
---@param here_answers table|nil Ответы двойника шлюза `local`
---@return any User
---@return table gateway
---@return table[] here_calls
local function on_node(here_answers)
    local here, here_calls = helper.fake_gateway(here_answers)
    local User, gateway = bound(here)

    return User, gateway, here_calls
end

--- Снимает ссылки: зовёт поставленные триггеры конца транзакции.
---@param triggers function[]
local function ended(triggers)
    for _, trigger in ipairs(triggers) do
        trigger()
    end
end

g.before_each(function()
    model = helper.load()
    calls = {}
    answers = {}
    in_txn = false
    commits = {}
    rollbacks = {}
    refs = {}
    clock = helper.fake_clock(0.25)

    model._set_source({
        router = fake_router,
        storage = fake_storage,
        clock = function()
            return clock
        end,
        config = function()
            return helper.fake_config({ sharding_roles = { 'router' } })
        end,
        box = function()
            return {
                is_in_txn = function()
                    return in_txn
                end,
                on_commit = function(trigger)
                    table.insert(commits, trigger)
                end,
                on_rollback = function(trigger)
                    table.insert(rollbacks, trigger)
                end,
            }
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

    -- Способ удаления едет к хранилищу: мягко удаляет и восстанавливает
    -- узел с данными.
    User.force_delete(7)

    t.assert_equals(calls[4].args, { 'users', { 7 }, 'force' })
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

g.test_an_offset_fans_out_as_a_longer_page_and_is_skipped_on_the_router = function()
    answers.map = {
        ['storage-001'] = {
            { ok = true, value = { { id = 1, age = 20 }, { id = 4, age = 30 }, { id = 5, age = 40 } } },
        },
        ['storage-002'] = {
            { ok = true, value = { { id = 2, age = 20 }, { id = 3, age = 25 }, { id = 6, age = 50 } } },
        },
    }

    local User = bound()
    local page = User.where('age', '>=', 20):limit(2):offset(3):all()

    t.assert_equals(
        calls[1].args,
        { 'users', { index = 'age', iterator = 'GE', key = { 20 }, limit = 5 } },
        'хранилище не знает, сколько пропущенных у соседей: отдаёт offset + limit своих'
    )
    t.assert_equals({ page[1].id, page[2].id, #page }, { 4, 5, 2 })

    local tail = User.where('age', '>=', 20):limit(3):offset(4):all()

    t.assert_equals(calls[2].args[2].limit, 7)
    t.assert_equals({ tail[1].id, tail[2].id, #tail }, { 5, 6, 2 })
    t.assert_equals(User.where('age', '>=', 20):limit(2):offset(6):all(), {})
    t.assert_equals(User.where('age', '>=', 20):limit(2):offset(0):all()[1].id, 1)
    t.assert_equals(calls[4].args[2], { index = 'age', iterator = 'GE', key = { 20 }, limit = 2 })

    answers.reply = { ok = true, value = { { id = 7, name = 'a', age = 1 } } }

    User.where('id', '=', 7):limit(2):offset(3):all()

    t.assert_equals(
        calls[5].args[2],
        { index = 'primary', iterator = 'EQ', key = { 7 }, limit = 2, offset = 3 },
        'в один бакет смещение уходит как есть: все записи ключа — на одном хранилище'
    )
end

-- `offset` и `limit` годны каждый до 2^32 − 1, а их сумма — нет: `box`
-- держит предел в 32 битах и больший молча обрезает, и веер с пределом
-- 2^32 + 4 получил бы с каждого хранилища по четыре записи.
g.test_the_fanned_out_page_never_exceeds_32_bits = function()
    answers.map = { ['storage-001'] = { { ok = true, value = {} } } }

    local User = bound()

    User.scan():limit(5):offset(model.OFFSET):all()
    User.scan():limit(5):offset(model.OFFSET - 2):all()
    User.scan():limit(5):offset(model.OFFSET - 5):all()
    User.scan():limit(5):offset(model.OFFSET - 6):all()
    User.scan():limit(model.OFFSET):offset(1):all()

    local limits = {}

    for position, call in ipairs(calls) do
        limits[position] = call.args[2].limit
    end

    t.assert_equals(limits, { 4294967295, 4294967295, 4294967295, 4294967294, 4294967295 })
end

-- Число Lua за пределом рода через роутер — отказ `invalid` у вызывающего,
-- а не `unavailable` «хранилище не ответило»: иначе ошибку клиента читали
-- бы бедой хранилища, и он получал бы 503 вместо 422.
g.test_numbers_beyond_the_kind_are_refused_without_a_call = function()
    local User = bound()
    local beyond =
        'должно быть целым числом от 0 до 18446744073709551615, а не 1.844674407371e+19'
    local refusals = {
        select(2, User.find(2 ^ 64)),
        select(2, User.create({ id = 2 ^ 64, name = 'Мария', age = 46 })),
        select(2, User.delete(2 ^ 64)),
        select(2, User.where('id', '>=', 2 ^ 64):all()),
        select(2, User.where('age', '>=', 18):after({ age = 20, id = 2 ^ 64 }):all()),
    }

    for position, err in ipairs(refusals) do
        t.assert_equals({ err.kind, err.fields }, { 'invalid', { id = beyond } }, position)
    end

    t.assert_equals(calls, {}, 'к роутеру не ходили')
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

    -- Репликасет, на котором веер споткнулся, vshard называет третьим
    -- значением, и отказ называет его же: погашенный шард виден сразу.
    answers.map_err = { type = 'ClientError', name = 'TIMEOUT', message = 'Timeout exceeded' }
    answers.map_replicaset = 'storage-003'

    local _, named = User.where('age', '>=', 1):all()

    t.assert_equals(named.kind, 'unavailable')
    t.assert_equals(tostring(named), 'хранилище storage-003 не ответило: Timeout exceeded')

    answers.map_err = { type = 'TimedOut', message = 'timed out' }

    t.assert_equals(
        tostring(select(2, User.where('age', '>=', 1):count())),
        'хранилище storage-003 не ответило: timed out'
    )
    t.assert_equals(#calls, 4, 'срок и молчание хранилища не повторяются')

    answers.map_replicaset = nil

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

-- Выделенный роутер пишет по сети: запись легла бы на хранилище своей
-- транзакцией, и откат здешней её не отменил бы. Чтение данных не меняет
-- и идёт через роутер и в транзакции.
g.test_a_dedicated_router_refuses_writes_inside_a_transaction = function()
    local User = bound()
    local refused = 'модель users: запись через роутер в транзакции невозможна — она ушла бы по сети '
        .. 'и легла мимо транзакции; box.atomic живёт в функции хранилища, которую роутер зовёт callrw'

    in_txn = true

    t.assert_error_msg_equals(refused, User.create, { id = 7, name = 'Мария', age = 46 })
    t.assert_error_msg_equals(refused, User.delete, 7)
    t.assert_error_msg_equals(refused, User.force_delete, 7)

    local record = User.validate({ id = 7, name = 'Мария', age = 46 })

    t.assert_error_msg_equals(refused, record.save, record)
    t.assert_equals(calls, {}, 'к хранилищу ничего не ушло')
    t.assert_equals(
        refs,
        {},
        'бакет выделенного роутера не берётся под ссылку'
    )

    answers.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }
    answers.map = { a = { { ok = true, value = 2 } }, b = { { ok = true, value = 3 } } }

    t.assert_equals(User.find(7).id, 7)
    t.assert_equals(User.where('age', '>=', 1):count(), 5)
    t.assert_equals({ calls[1].mode, calls[2].mode }, { 'callro', 'map' })

    in_txn = false

    t.assert_equals(User.create({ id = 7, name = 'Мария', age = 46 }).id, 7)
    t.assert_equals(
        calls[3].mode,
        'callrw',
        'вне транзакции запись идёт через роутер'
    )
end

g.test_outside_a_transaction_the_node_with_data_goes_through_its_router = function()
    local User, gateway, here_calls = on_node()

    answers.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    t.assert_equals(User.create({ id = 7, name = 'Мария', age = 46 }).id, 7)
    t.assert_equals(User.find(7).id, 7)

    answers.reply = { ok = true, value = 1 }

    t.assert_equals(User.where('id', '=', 7):count(), 1)
    t.assert_equals({ calls[1].mode, calls[2].mode, calls[3].mode }, { 'callrw', 'callro', 'callro' })
    t.assert_equals(calls[3].name, 'tnt_model_count')
    t.assert_equals(here_calls, {})
    t.assert_equals(refs, {})

    -- Транзакция у такого узла есть: `box.atomic` шлюза к своим бакетам.
    t.assert_equals(
        gateway.atomic(function(a, b)
            return a + b
        end, 1, 2),
        3
    )
    t.assert_equals(here_calls, { { name = 'atomic' } })
end

g.test_in_a_transaction_the_node_with_data_goes_to_its_own_bucket_under_a_ref = function()
    local stored = { id = 7, name = 'Мария', age = 46 }
    local User, _, here_calls = on_node({ put = stored, find = stored, delete = true, select = { stored }, count = 1 })

    in_txn = true

    t.assert_equals(User.create({ id = 7, name = ' Мария ', age = 46 }):to_table(), stored)
    t.assert_equals(User.find(7):to_table(), stored)
    t.assert_equals(User.where('id', '=', 7):all()[1].id, 7)
    t.assert_equals(User.where('id', '=', 7):count(), 1)
    t.assert_equals(User.force_delete(7), true)
    t.assert_equals(calls, {}, 'мимо роутера: ничего не ушло по сети')
    t.assert_equals(here_calls[1], { name = 'put', space = 'users', args = { stored, 'insert' } })
    t.assert_equals(here_calls[2], { name = 'find', space = 'users', args = { { 7 } } })
    local selected = assert(here_calls[3])

    t.assert_equals(selected.name, 'select')
    t.assert_equals(selected.args[1].key, { 7 }, 'выборка — в бакет ключа')
    t.assert_equals(assert(here_calls[4]).name, 'count')
    t.assert_equals(here_calls[5], { name = 'delete', space = 'users', args = { { 7 }, 'force' } })
    t.assert_equals(refs, {
        { 'ref', 98, 'write' },
        { 'ref', 98, 'read' },
        { 'ref', 98, 'read' },
        { 'ref', 98, 'read' },
        { 'ref', 98, 'write' },
    })

    -- Ссылки держатся до конца транзакции и снимаются её триггерами:
    -- при фиксации и при откате — каждая своего рода.
    t.assert_equals({ #commits, #rollbacks }, { 5, 5 })

    ended(commits)

    t.assert_equals(refs[6], { 'unref', 98, 'write' })
    t.assert_equals(refs[7], { 'unref', 98, 'read' })
    t.assert_equals(refs[10], { 'unref', 98, 'write' })
    t.assert_equals(#refs, 10)

    ended({ rollbacks[2] })

    t.assert_equals(refs[11], { 'unref', 98, 'read' })
end

g.test_a_foreign_bucket_and_a_fan_out_in_a_transaction_are_programmer_errors = function()
    local User, _, here_calls = on_node()
    local foreign = 'модель users: бакет 98 не на этом узле — в транзакции узел «и роутер, и хранилище» '
        .. 'читает и пишет только свои бакеты; транзакция над чужим живёт в функции его хранилища, '
        .. 'которую роутер зовёт callrw'
    local fanned = 'модель users: выборка веером в транзакции невозможна — она шла бы через роутер по сети '
        .. 'мимо транзакции; в транзакции — только выборка в один бакет, по первичному ключу на равенство'

    in_txn = true
    answers.ref_err = vshard_error('WRONG_BUCKET', 'Cannot perform action with bucket 98, reason: Not found')

    t.assert_error_msg_equals(foreign, User.create, { id = 7, name = 'Мария', age = 46 })
    t.assert_error_msg_equals(foreign, User.find, 7)
    t.assert_error_msg_equals(foreign, User.delete, 7)
    t.assert_equals(here_calls, {})
    t.assert_equals(
        { #commits, #rollbacks },
        { 0, 0 },
        'ссылка не взялась — снимать нечего'
    )

    answers.ref_err = nil

    local query = User.where('age', '>=', 18)

    t.assert_error_msg_equals(fanned, query.all, query)
    t.assert_error_msg_equals(fanned, query.count, query)

    local scan = User.scan()

    t.assert_error_msg_equals(fanned, scan.count, scan)
    t.assert_equals(calls, {}, 'ни роутеру, ни хранилищам ничего не ушло')
    t.assert_equals(here_calls, {})
end

-- Бакет на узле есть, а ссылка не взялась: узел не ведущий либо бакет
-- в переносе. Это не ошибка программиста, а состояние кластера — отказ
-- парой, и тело транзакции решает, что с ним делать.
g.test_a_bucket_that_cannot_be_referenced_is_a_refusal = function()
    local User, _, here_calls = on_node()

    in_txn = true
    answers.ref_err = vshard_error('NON_MASTER', 'Replica single-b is not a master for replicaset single-001 anymore')

    local _, readonly = User.create({ id = 7, name = 'Мария', age = 46 })

    t.assert_equals(readonly.kind, 'readonly')
    t.assert_equals(
        tostring(readonly),
        'бакет 98: Replica single-b is not a master for replicaset single-001 anymore'
    )

    answers.ref_err = vshard_error('TRANSFER_IS_IN_PROGRESS', 'Bucket 98 is transferring to replicaset single-002')

    local _, moving = User.find(7)

    t.assert_equals(moving.kind, 'unavailable')
    t.assert_equals(tostring(moving), 'бакет 98: Bucket 98 is transferring to replicaset single-002')
    t.assert_equals(here_calls, {})
    t.assert_equals({ #commits, #rollbacks }, { 0, 0 })
end

-- Перечитывание конфигурации роутера обрывает веер `OBJECT_IS_OUTDATED`,
-- хотя хранилища живы. Функции веера только читают, и веер повторяется
-- один раз тем же вызовом — в остаток своего срока. Срок отмечен
-- монотонными часами, остаток считается от отметки цикла, которая
-- отстаёт от них на четверть секунды.
g.test_a_fan_out_caught_by_a_router_reload_is_repeated_once_within_its_term = function()
    local User = bound()

    answers.turns = {
        { err = outdated(), replicaset = 'storage-001', took = 1 },
        { map = { a = { { ok = true, value = 2 } }, b = { { ok = true, value = 3 } } } },
    }

    t.assert_equals(User.where('age', '>=', 18):count(), 5)
    t.assert_equals(#calls, 2)
    t.assert_equals(calls[1].opts, { timeout = 3 })
    t.assert_equals(calls[2].opts, { timeout = 2.25 }, 'остаток: 100 + 3 − (101 − 0,25)')
    t.assert_equals(calls[2].name, 'tnt_model_count')
    t.assert_equals(calls[2].args, calls[1].args)

    answers.turns = {
        { err = outdated(), replicaset = 'storage-002', took = 0.5 },
        { map = { a = { { ok = true, value = { { id = 1, age = 20 } } } } } },
    }

    t.assert_equals(helper.ids(User.where('age', '>=', 18):all()), { 1 })
    t.assert_equals({ calls[3].name, calls[4].name }, { 'tnt_model_select', 'tnt_model_select' })
    t.assert_equals(calls[4].args, calls[3].args)
    t.assert_equals(calls[4].opts, { timeout = 2.75 }, 'остаток: 101 + 3 − (101,5 − 0,25)')
end

-- Второй такой отказ значит новое перечитывание за время повтора: веер
-- отказывает, а не ходит по кругу, и отказ называет репликасет повтора.
g.test_a_fan_out_outdated_twice_is_a_refusal = function()
    local User = bound()

    answers.turns = {
        { err = outdated(), replicaset = 'storage-001' },
        { err = outdated(), replicaset = 'storage-002' },
        { map = { a = { { ok = true, value = 2 } } } },
    }

    local _, err = User.where('age', '>=', 18):count()

    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(tostring(err), 'хранилище storage-002 не ответило: ' .. OUTDATED_TEXT)
    t.assert_equals(#calls, 2)
end

-- Срок вышел за первой попыткой — повтор не уходит: vshard со сроком
-- ноль и меньше всё равно разослал бы запросы ссылок. Граница — остаток
-- ровно ноль.
g.test_an_outdated_fan_out_past_its_term_is_not_repeated = function()
    local User = bound()

    answers.turns = {
        { err = outdated(), replicaset = 'storage-001', took = 3.25 },
        { map = {} },
    }

    local _, err = User.where('age', '>=', 18):count()

    t.assert_equals(tostring(err), 'хранилище storage-001 не ответило: ' .. OUTDATED_TEXT)
    t.assert_equals(#calls, 1)

    answers.turns = {
        { err = outdated(), replicaset = 'storage-001', took = 3 },
        { map = { a = { { ok = true, value = 7 } } } },
    }

    t.assert_equals(User.where('age', '>=', 18):count(), 7)
    t.assert_equals(calls[3].opts, { timeout = 0.25 }, 'остаток: 103,25 + 3 − (106,25 − 0,25)')
end
