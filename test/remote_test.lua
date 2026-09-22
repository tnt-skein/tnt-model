--- Шлюз `remote` над двойником net.box: порядок узлов, поиск ведущего
--- по отказу `readonly`, отказы связи, замена оборванного соединения,
--- закрытие соединений.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.remote')

---@type any
local model

---@type table<string, table> Двойники узлов по адресу: ответы и что с ними делали
local nodes

---@type any
local calls

--- Двойник соединения net.box с одним узлом.
---
--- Состояние — как у net.box без `reconnect_after`: не поднявшееся
--- соединение остаётся в `error`, медленное — ещё в `initial`,
--- оборванное посреди вызова (`drops`) — в `error`.
---@param uri string
---@param opts table
---@return table
local function fake_connection(uri, opts)
    local node = nodes[uri]

    node.opened = (node.opened or 0) + 1
    node.opts = opts

    return {
        error = node.error,
        state = 'initial',
        wait_connected = function(self, timeout)
            node.waited = timeout

            if node.reachable == false then
                self.state = node.pending and 'initial' or 'error'

                return false
            end

            self.state = 'active'

            return true
        end,
        call = function(self, name, args, call_opts)
            table.insert(calls, { uri = uri, name = name, args = args, opts = call_opts })

            if node.drops then
                self.state = 'error'
            end

            if node.throws ~= nil then
                error(node.throws, 0)
            end

            return node.reply
        end,
        close = function()
            node.closed = (node.closed or 0) + 1
        end,
    }
end

--- Модель пользователей на шлюзе `remote` к двум узлам.
---@return any User
---@return any gateway
local function bound()
    local User = helper.users(model)
    local gateway = helper.module('tnt.model.gateway.remote').new({
        replicaset = 'core',
        peers = {
            { name = 'core-a', uri = 'a', login = 'storage', password = 's' },
            { name = 'core-b', uri = 'b', login = 'storage', password = 's' },
        },
        timeout = 2,
    })

    User._bind(gateway)

    return User, gateway
end

g.before_each(function()
    model = helper.load()
    calls = {}
    nodes = { a = {}, b = {} }

    model._set_source({
        net_box = function()
            return { connect = fake_connection }
        end,
    })
end)

g.after_each(function()
    model._set_source(nil)
    helper.unload()
end)

g.test_reads_go_to_the_first_reachable_node_lazily = function()
    nodes.a.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    local User = bound()

    t.assert_equals(User.find(7):is_adult(), true)
    t.assert_equals(User.bound(), 'remote')
    t.assert_equals(
        calls,
        { { uri = 'a', name = 'tnt_model_find', args = { 'users', { 7 } }, opts = { timeout = 2 } } }
    )
    t.assert_equals(nodes.a.opened, 1)
    t.assert_equals(nodes.a.waited, 2)
    t.assert_equals(nodes.a.opts, { user = 'storage', password = 's', wait_connected = false })
    t.assert_equals(nodes.b.opened, nil, 'второй узел не открывался')

    User.find(8)

    t.assert_equals(nodes.a.opened, 1, 'соединение открыто один раз')

    nodes.a.reply = { ok = true, value = { { id = 1, name = 'a', age = 1 } } }

    t.assert_equals(#User.where('age', '>=', 1):all(), 1)

    nodes.a.reply = { ok = true, value = 4 }

    t.assert_equals(User.scan():count(), 4)
end

g.test_writes_skip_readonly_nodes_and_remember_the_leader = function()
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'узел только для чтения' }
    nodes.b.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    local User = bound()

    t.assert_equals(User.create({ id = 7, name = 'Мария', age = 46 }).id, 7)
    t.assert_equals({ calls[1].uri, calls[2].uri }, { 'a', 'b' })
    t.assert_equals(calls[2].args, { 'users', { id = 7, name = 'Мария', age = 46 }, 'insert' })

    nodes.b.reply = { ok = true, value = true }

    t.assert_equals(User.delete(7), true)
    t.assert_equals(calls[3].uri, 'b', 'ведущий спрашивается первым')
    t.assert_equals(#calls, 3)

    -- Чтение тоже идёт к запомненному узлу первым.
    nodes.b.reply = { ok = true }

    t.assert_equals(User.find(7), nil)
    t.assert_equals(calls[4].uri, 'b')
end

g.test_all_nodes_readonly_is_a_readonly_refusal = function()
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.b.reply = { ok = false, kind = 'readonly', message = 'только чтение' }

    local _, err = bound().create({ id = 1, name = 'a', age = 1 })

    t.assert_equals(err.kind, 'readonly')
    t.assert_equals(
        tostring(err),
        'репликасет core не принимает запись: core-a: только чтение; core-b: только чтение'
    )

    nodes.b.reachable = false
    nodes.b.error = 'нет связи'

    local _, mixed = bound().create({ id = 1, name = 'a', age = 1 })

    t.assert_equals(
        mixed.kind,
        'unavailable',
        'молчащий узел — не readonly: ведущий мог быть им'
    )
    t.assert_equals(
        tostring(mixed),
        'репликасет core не ответил: core-a: только чтение; core-b не отвечает: нет связи'
    )
end

g.test_storage_refusal_is_returned_as_is_without_trying_others = function()
    nodes.a.reply = { ok = false, kind = 'invalid', message = 'плохо', fields = { age = 'нет' } }

    local User = bound()
    local _, err = User.create({ id = 1, name = 'a', age = 1 })

    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.fields, { age = 'нет' })
    t.assert_equals(#calls, 1)

    -- Отказ readonly на чтении — не повод идти дальше: чтение так не отказывают.
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'странно' }

    local _, odd = User.find(1)

    t.assert_equals(odd.kind, 'readonly')
    t.assert_equals(#calls, 2)

    -- Выборка и счёт — тоже чтение.
    local _, page = User.where('age', '>=', 1):all()
    local _, counted = User.scan():count()

    t.assert_equals({ page.kind, counted.kind }, { 'readonly', 'readonly' })
    t.assert_equals(#calls, 4)
    t.assert_equals({ calls[3].name, calls[4].name }, { 'tnt_model_select', 'tnt_model_count' })
    t.assert_equals(nodes.b.opened, nil, 'к второму узлу чтение не ходило')
end

g.test_delete_is_a_write_and_skips_readonly_nodes = function()
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.b.reply = { ok = true, value = true }

    local User = bound()

    t.assert_equals(User.delete(7), true)
    t.assert_equals(calls[1].uri, 'a')
    t.assert_equals(
        calls[2],
        { uri = 'b', name = 'tnt_model_delete', args = { 'users', { 7 } }, opts = { timeout = 2 } }
    )
end

g.test_unreachable_and_throwing_nodes_are_named_in_the_refusal = function()
    nodes.a.reachable = false
    nodes.a.error = 'connection refused'
    nodes.b.throws = 'Procedure tnt_model_find is not defined'

    local _, err = bound().find(1)

    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: core-a не отвечает: connection refused; '
            .. 'core-b отказал: Procedure tnt_model_find is not defined'
    )
    t.assert_equals(#calls, 1, 'к недоступному узлу вызова не было')
end

g.test_a_broken_connection_is_replaced_on_the_next_call = function()
    nodes.a.reachable = false
    nodes.a.error = 'Peer closed'
    nodes.b.reply = { ok = true, value = { id = 1, name = 'b', age = 1 } }

    local User = bound()

    t.assert_equals(User.find(1).name, 'b')
    t.assert_equals(nodes.a.opened, 1)

    -- Узел вернулся: прежнее соединение в error, и шлюз открывает новое,
    -- а не отвечает «Peer closed» до перечитывания конфигурации.
    nodes.a.reachable = nil
    nodes.a.reply = { ok = true, value = { id = 1, name = 'a', age = 1 } }

    t.assert_equals(User.find(1).name, 'a')
    t.assert_equals(nodes.a.opened, 2)
    t.assert_equals(nodes.a.closed, nil, 'соединение без сокета не закрывается')

    User.find(1)

    t.assert_equals(nodes.a.opened, 2, 'живое соединение не заменяется')

    -- Оборванное посреди вызова — тоже.
    nodes.a.drops = true
    nodes.a.throws = 'Peer closed'

    t.assert_equals(User.find(1).name, 'b')

    nodes.a.drops = nil
    nodes.a.throws = nil

    t.assert_equals(User.find(1).name, 'a')
    t.assert_equals(nodes.a.opened, 3)
end

g.test_a_slow_connection_is_waited_for_and_not_replaced = function()
    nodes.a.reachable = false
    nodes.a.pending = true
    nodes.a.error = nil
    nodes.b.reply = { ok = true }

    local User = bound()

    User.find(1)
    User.find(1)

    t.assert_equals(
        nodes.a.opened,
        1,
        'соединение, которое ещё поднимается, ждут снова'
    )
    t.assert_equals(nodes.a.waited, 2)

    -- Отказ самой функции соединение не рвёт: оно остаётся.
    nodes.a.reachable = nil
    nodes.a.throws = 'Procedure tnt_model_find is not defined'

    t.assert_equals(User.find(1), nil)
    t.assert_equals(User.find(1), nil)
    t.assert_equals(nodes.a.opened, 1)
end

g.test_close_drops_connections_and_reopens_on_demand = function()
    nodes.a.reply = { ok = true }

    local User, gateway = bound()

    User.find(1)
    gateway.close()

    t.assert_equals(nodes.a.closed, 1)
    t.assert_equals(nodes.b.closed, nil)

    User.find(1)

    t.assert_equals(nodes.a.opened, 2)

    gateway.close()
    gateway.close()

    t.assert_equals(nodes.a.closed, 2)
end

g.test_atomic_is_impossible_without_data = function()
    local _, gateway = bound()

    t.assert_error_msg_equals(
        'транзакция на узле без данных невозможна: box.atomic живёт в функции узла с данными',
        gateway.atomic,
        function() end
    )
end
