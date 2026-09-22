--- Шлюз реплики с пересылкой записи над двойниками шлюзов: чтение
--- и транзакция на месте, запись на месте первой, отказ `readonly` —
--- пересылкой, внутри транзакции — без неё.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.forward')

---@type any
local model

---@type boolean Идёт ли транзакция на двойнике box
local in_txn

--- Отказ «только для чтения», каким его отдаёт шлюз local на реплике.
---@return table
local function readonly()
    return model.failure.new('readonly', 'узел только для чтения: config')
end

--- Модель пользователей на шлюзе пересылки над двумя двойниками.
---@param here_answers table|nil Ответы шлюза на месте
---@param there_answers table|nil Ответы шлюза к соседям
---@return any User
---@return table gateway
---@return table[] here_calls
---@return table[] there_calls
local function bound(here_answers, there_answers)
    local here, here_calls = helper.fake_gateway(here_answers)
    local there, there_calls = helper.fake_gateway(there_answers)
    local gateway = helper.module('tnt.model.gateway.forward').new(here, there)
    local User = helper.users(model)

    User._bind(gateway)

    return User, gateway, here_calls, there_calls
end

--- Имена вызванных действий двойника по порядку.
---@param calls table[]
---@return string[]
local function names(calls)
    local listed = {}

    for _, call in ipairs(calls) do
        table.insert(listed, call.name)
    end

    return listed
end

g.before_each(function()
    model = helper.load()
    in_txn = false

    model._set_source({
        box = function()
            return {
                is_in_txn = function()
                    return in_txn
                end,
            }
        end,
    })
end)

g.after_each(function()
    model._set_source(nil)
    helper.unload()
end)

g.test_reads_and_transactions_stay_on_the_node = function()
    local User, gateway, here_calls, there_calls = bound({
        find = { id = 7, name = 'Мария', age = 46 },
        select = { { id = 7, name = 'Мария', age = 46 } },
        count = 4,
    })

    t.assert_equals(gateway.kind, 'fake', 'шлюз называется шлюзом на месте')
    t.assert_equals(User.bound(), 'fake')
    t.assert_equals(User.find(7):to_table(), { id = 7, name = 'Мария', age = 46 })
    t.assert_equals(#User.where('age', '>=', 18):all(), 1)
    t.assert_equals(User.scan():count(), 4)
    t.assert_equals(
        gateway.atomic(function(a, b)
            return a + b
        end, 1, 2),
        3
    )
    t.assert_equals(names(here_calls), { 'find', 'select', 'count', 'atomic' })
    t.assert_equals(there_calls, {}, 'к соседям чтение не ходит')
end

g.test_a_write_the_node_takes_is_not_forwarded = function()
    local User, _, here_calls, there_calls = bound({ put = { id = 7, name = 'Мария', age = 46 }, delete = true })

    t.assert_equals(
        User.create({ id = 7, name = 'Мария', age = 46 }):to_table(),
        { id = 7, name = 'Мария', age = 46 }
    )
    t.assert_equals(User.delete(7), true)
    t.assert_equals(here_calls, {
        { name = 'put', space = 'users', args = { { id = 7, name = 'Мария', age = 46 }, 'insert' } },
        { name = 'delete', space = 'users', args = { { 7 } } },
    })
    t.assert_equals(there_calls, {})

    -- Ложь — «записи не было», а не отказ: пересылать нечего.
    local Absent, _, _, absent_calls = bound({ delete = false })

    t.assert_equals(Absent.delete(8), false)
    t.assert_equals(absent_calls, {})
end

g.test_a_refusal_other_than_readonly_is_returned_as_is = function()
    local conflict = model.failure.new('conflict', 'запись users с таким ключом уже есть')
    local missing =
        model.failure.new('unavailable', 'спейса users нет: схема на узле не поднята')
    local User, _, here_calls, there_calls = bound({ put = { refusal = conflict }, delete = { refusal = missing } })

    local created, refused = User.create({ id = 7, name = 'Мария', age = 46 })
    local deleted, failed = User.delete(7)

    t.assert_equals({ created, deleted }, { nil, nil })
    t.assert_is(refused, conflict)
    t.assert_is(failed, missing)
    t.assert_equals(names(here_calls), { 'put', 'delete' })
    t.assert_equals(there_calls, {}, 'отказ, кроме readonly, не пересылается')
end

g.test_readonly_forwards_the_write_to_the_neighbours = function()
    local User, _, here_calls, there_calls = bound(
        { put = { refusal = readonly() }, delete = { refusal = readonly() } },
        { put = { id = 7, name = 'Мария', age = 46 }, delete = true }
    )

    local record = User.create({ id = 7, name = ' Мария ', age = 46 })

    t.assert_equals(record:to_table(), { id = 7, name = 'Мария', age = 46 })
    t.assert_equals(record:is_adult(), true)
    t.assert_equals(User.delete(7), true)

    -- Сохранение записи — та же запись: пересылается заменой.
    record.age = 47

    t.assert_equals(record:save(), record)

    local calls = {
        { name = 'put', space = 'users', args = { { id = 7, name = 'Мария', age = 46 }, 'insert' } },
        { name = 'delete', space = 'users', args = { { 7 } } },
        { name = 'put', space = 'users', args = { { id = 7, name = 'Мария', age = 47 }, 'replace' } },
    }

    t.assert_equals(here_calls, calls, 'сначала запись идёт на месте')
    t.assert_equals(there_calls, calls, 'соседям уходят те же аргументы, что узлу')
end

g.test_the_neighbours_refusal_is_returned_to_the_caller = function()
    local unavailable = model.failure.new(
        'unavailable',
        'репликасет core не ответил: core-a не отвечает: Peer closed; core-c: узел только для чтения: config'
    )
    local User = bound(
        { put = { refusal = readonly() }, delete = { refusal = readonly() } },
        { put = { refusal = unavailable }, delete = { refusal = unavailable } }
    )

    local created, err = User.create({ id = 7, name = 'Мария', age = 46 })
    local deleted, refused = User.delete(7)

    t.assert_equals({ created, deleted }, { nil, nil })
    t.assert_is(err, unavailable)
    t.assert_is(refused, unavailable)
end

g.test_a_write_inside_a_transaction_is_not_forwarded = function()
    local User, _, here_calls, there_calls = bound(
        { put = { refusal = readonly() }, delete = { refusal = readonly() } },
        { put = { id = 7, name = 'Мария', age = 46 }, delete = true }
    )

    in_txn = true

    local created, err = User.create({ id = 7, name = 'Мария', age = 46 })
    local deleted, refused = User.delete(7)

    t.assert_equals({ created, deleted }, { nil, nil })

    for _, failure in ipairs({ err, refused }) do
        t.assert_equals(failure.kind, 'readonly')
        t.assert_equals(
            tostring(failure),
            'узел только для чтения: config; в транзакции запись ведущему не пересылается'
        )
        t.assert_equals(model.failure.is(failure), true)
    end

    t.assert_equals(names(here_calls), { 'put', 'delete' })
    t.assert_equals(there_calls, {}, 'в транзакции соседям ничего не уходит')
end

g.test_close_releases_both_gateways = function()
    local _, gateway, here_calls, there_calls = bound()

    gateway.close()

    t.assert_equals(names(here_calls), { 'close' })
    t.assert_equals(names(there_calls), { 'close' })
end
