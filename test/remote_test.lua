--- Шлюз `remote` над двойником net.box: порядок узлов, поиск ведущего
--- по отказу `readonly`, молчащий узел в конце опроса, срок на узел,
--- тексты отказов, запись с неизвестным исходом, замена оборванного
--- соединения, закрытие шлюза с вызовами в пути и без них, запись
--- в транзакции.

local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.remote')

---@type any
local model

---@type table<string, table> Двойники узлов по адресу: ответы и что с ними делали
local nodes

---@type any
local calls

---@type table Двойник часов: срок узла считается по нему
local clock

---@type boolean Идёт ли транзакция на двойнике box
local in_txn

--- Сборка ошибок Tarantool: коды и конструктор в аннотациях описаны
--- не полностью, поэтому берутся через промежуточную ссылку.
---@type any
local box_error = box.error

--- Обрыв связи после отправки: так net.box отвечает на вызов, когда узел
--- погас, не ответив.
---@return table
local function peer_closed()
    return box_error.new({ code = box_error.NO_CONNECTION, reason = 'Peer closed' })
end

--- Отказ сервера: функции `tnt_model_*` на узле ещё нет.
---@param name string
---@return table
local function no_such_proc(name)
    return box_error.new(box_error.NO_SUCH_PROC, name)
end

--- Модель пользователей на шлюзе `remote` к узлам репликасета core.
---@param names string[]|nil Адреса узлов по порядку; узел `x` зовётся core-x. По умолчанию a и b
---@return any User
---@return any gateway
local function bound(names)
    local peers = {}

    for _, uri in ipairs(names or { 'a', 'b' }) do
        table.insert(peers, { name = 'core-' .. uri, uri = uri, login = 'storage', password = 's' })
    end

    local User = helper.users(model)
    local gateway = helper.module('tnt.model.gateway.remote').new({
        replicaset = 'core',
        peers = peers,
        timeout = 2,
    })

    User._bind(gateway)

    return User, gateway
end

--- Ждёт, пока файбер проверки положит ответ модели.
---
--- Отпущенный вызов доходит до ответа, когда главный файбер уступит
--- управление, — ожидание и уступает.
---@param answers table Ответы по имени
---@param name string
---@return table answer Что вернула модель: значение и отказ
local function awaited(answers, name)
    t.helpers.retrying({ timeout = 1, delay = 0.001 }, function()
        t.assert_not_equals(answers[name], nil, ('%s ещё в пути'):format(name))
    end)

    return answers[name]
end

--- Запускает действие модели в своём файбере и кладёт его итог в ответы.
---
--- `fiber.create` отдаёт управление новому файберу сразу, и тот идёт
--- до первой уступки: когда функция вернулась, вызов уже ждёт у узла.
---@param answers table
---@param name string
---@param action function
---@param ... any Аргументы действия
local function launched(answers, name, action, ...)
    local args = { ... }

    fiber.create(function()
        local value, err = action(unpack(args))

        answers[name] = { value = value, err = err }
    end)
end

--- Модель, знающая ведущего: первую запись узел a отверг `readonly`,
--- b принял, — у шлюза открыты соединения с обоими, и b спрашивается первым.
---@param names string[]|nil
---@return any User
---@return any gateway
local function led_by_b(names)
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.b.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    local User, gateway = bound(names)

    t.assert_equals(User.create({ id = 7, name = 'Мария', age = 46 }).id, 7)

    return User, gateway
end

--- Адреса узлов, к которым уходили вызовы, по порядку.
---
--- Журнал нельзя завести заново посреди проверки: открытые соединения
--- пишут в тот, что был при их открытии. Поэтому шаг отсчитывается
--- от числа вызовов до него.
---@param since integer|nil Сколько первых вызовов пропустить
---@return string[]
local function uris(since)
    local listed = {}

    for position = (since or 0) + 1, #calls do
        table.insert(listed, calls[position].uri)
    end

    return listed
end

g.before_each(function()
    model = helper.load()
    calls = {}
    nodes = { a = {}, b = {} }
    clock = helper.fake_clock()
    in_txn = false

    model._set_source({
        net_box = function()
            return helper.fake_net_box(nodes, calls, clock)
        end,
        box = function()
            return {
                is_in_txn = function()
                    return in_txn
                end,
                error = box_error,
            }
        end,
        clock = function()
            return clock
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

    User.force_delete(7)

    t.assert_equals(
        calls[3].args,
        { 'users', { 7 }, 'force' },
        'способ удаления едет к узлу с данными'
    )
end

g.test_a_write_that_went_unanswered_is_not_carried_to_the_next_node = function()
    -- Срок, обрыв связи после отправки, исключение внутри функции и ошибка
    -- не из box: узел мог запись исполнить, и второй узел её не получает.
    -- Исключение функции — ответ узла: репликасет отказал, а не промолчал.
    local cases = {
        {
            throws = helper.timed_out(),
            text = 'репликасет core не ответил: исход записи на core-a неизвестен: нет ответа за 2 с',
        },
        {
            throws = peer_closed(),
            drops = true,
            text = 'репликасет core не ответил: исход записи на core-a неизвестен: Peer closed',
        },
        {
            throws = box_error.new({ code = box_error.PROC_LUA, reason = 'serve.lua:1: сбой' }),
            text = 'репликасет core отказал: исход записи на core-a неизвестен: ответил ошибкой: serve.lua:1: сбой',
        },
        {
            throws = 'сбой',
            text = 'репликасет core не ответил: исход записи на core-a неизвестен: сбой',
        },
    }

    for _, case in ipairs(cases) do
        calls = {}
        nodes = {
            a = { throws = case.throws, drops = case.drops },
            b = { reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } } },
        }

        local User = bound()
        local created, err = User.create({ id = 7, name = 'Мария', age = 46 })

        t.assert_equals(created, nil)
        t.assert_equals(err.kind, 'unavailable')
        t.assert_equals(tostring(err), case.text)
        t.assert_equals(#calls, 1, 'второму узлу запись не ушла')
        t.assert_equals(nodes.b.opened, nil)
    end
end

g.test_a_delete_is_not_carried_on_and_reads_pass_the_silent_node = function()
    nodes.a.throws = helper.timed_out()
    nodes.b.reply = { ok = true, value = true }

    local User = bound()
    local deleted, err = User.delete(7)

    t.assert_equals(deleted, nil)
    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: исход записи на core-a неизвестен: нет ответа за 2 с'
    )
    t.assert_equals(#calls, 1)
    t.assert_equals(calls[1].name, 'tnt_model_delete')

    -- Узел промолчал и ушёл в конец опроса: чтение идёт сразу к соседу,
    -- не ожидая срока у молчащего.
    nodes.b.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    t.assert_equals(User.find(7):to_table(), { id = 7, name = 'Мария', age = 46 })

    nodes.b.reply = { ok = true, value = { { id = 7, name = 'Мария', age = 46 } } }

    t.assert_equals(#User.where('age', '>=', 1):all(), 1)

    nodes.b.reply = { ok = true, value = 1 }

    t.assert_equals(User.scan():count(), 1)
    t.assert_equals(uris(), { 'a', 'b', 'b', 'b' })
    t.assert_equals(
        { calls[2].name, calls[3].name, calls[4].name },
        { 'tnt_model_find', 'tnt_model_select', 'tnt_model_count' }
    )
end

g.test_reads_go_on_after_a_node_answered_with_an_error = function()
    -- Узел ответил ошибкой — он жив: чтение идёт к соседу, а сам узел
    -- остаётся на месте и спрашивается первым и в следующий раз.
    nodes.a.throws = box_error.new({ code = box_error.PROC_LUA, reason = 'serve.lua:1: сбой' })
    nodes.b.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    local User = bound()

    t.assert_equals(User.find(7).name, 'Мария')
    t.assert_equals(User.find(7).name, 'Мария')
    t.assert_equals(uris(), { 'a', 'b', 'a', 'b' })
end

g.test_an_unknown_outcome_ends_the_round_and_names_the_nodes_passed = function()
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.b.drops = true
    nodes.b.throws = peer_closed()

    local _, err = bound().create({ id = 1, name = 'a', age = 1 })

    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: core-a: только чтение; исход записи на core-b неизвестен: Peer closed'
    )
    t.assert_equals(#calls, 2)
end

g.test_a_write_the_node_refused_to_perform_goes_to_the_next_node = function()
    -- Функции нет, на неё нет права, узел только для чтения: запись здесь
    -- не легла, и нести её дальше можно.
    local refusals = {
        { no_such_proc('tnt_model_put'), "Procedure 'tnt_model_put' is not defined" },
        {
            box_error.new({
                code = box_error.ACCESS_DENIED,
                reason = "Execute access to function 'tnt_model_put' is denied for user 'storage'",
            }),
            "Execute access to function 'tnt_model_put' is denied for user 'storage'",
        },
        { box_error.new(box_error.READONLY), "Can't modify data on a read-only instance" },
    }

    for _, refusal in ipairs(refusals) do
        calls = {}
        nodes = {
            a = { throws = refusal[1] },
            b = { reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } } },
        }

        local User = bound()

        t.assert_equals(User.create({ id = 7, name = 'Мария', age = 46 }).id, 7)
        t.assert_equals({ calls[1].uri, calls[2].uri }, { 'a', 'b' })

        -- Узел, принявший запись, запоминается как обычно.
        nodes.b.reply = { ok = true, value = true }

        t.assert_equals(User.delete(7), true)
        t.assert_equals(calls[3].uri, 'b')

        -- Узел ответил ошибкой — репликасет отказал, а не промолчал;
        -- род — unavailable: ведущим мог быть и он.
        nodes.b.reply = { ok = false, kind = 'readonly', message = 'только чтение' }

        local _, err = bound().create({ id = 8, name = 'Олег', age = 20 })

        t.assert_equals(err.kind, 'unavailable')
        t.assert_equals(
            tostring(err),
            ('репликасет core отказал: core-a ответил ошибкой: %s; core-b: только чтение'):format(
                refusal[2]
            )
        )
    end
end

g.test_a_write_goes_on_when_the_connection_did_not_come_up = function()
    -- Соединение отвергнуто либо не поднялось за срок: запрос не уходил.
    for _, pending in ipairs({ false, true }) do
        calls = {}
        nodes = {
            a = { reachable = false, pending = pending, error = 'Connection refused' },
            b = { reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } } },
        }

        t.assert_equals(bound().create({ id = 7, name = 'Мария', age = 46 }).id, 7)
        t.assert_equals(#calls, 1)
        t.assert_equals(calls[1].uri, 'b')
    end
end

g.test_unreachable_and_throwing_nodes_are_named_in_the_refusal = function()
    nodes.a.reachable = false
    nodes.a.error = 'connection refused'
    nodes.b.throws = no_such_proc('tnt_model_find')

    local _, err = bound().find(1)

    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: core-a не отвечает: connection refused; '
            .. "core-b ответил ошибкой: Procedure 'tnt_model_find' is not defined"
    )
    t.assert_equals(#calls, 1, 'к недоступному узлу вызова не было')

    -- Ответили ошибкой оба — репликасет отказал: молчавших нет.
    calls = {}
    nodes = {
        a = { throws = no_such_proc('tnt_model_find') },
        b = { throws = box_error.new({ code = box_error.PROC_LUA, reason = 'serve.lua:1: сбой' }) },
    }

    local _, refused = bound().find(1)

    t.assert_equals(refused.kind, 'unavailable')
    t.assert_equals(
        tostring(refused),
        "репликасет core отказал: core-a ответил ошибкой: Procedure 'tnt_model_find' is not defined; "
            .. 'core-b ответил ошибкой: serve.lua:1: сбой'
    )
    t.assert_equals(uris(), { 'a', 'b' })
end

g.test_a_silent_leader_is_dropped_and_asked_last = function()
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.b.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    local User = bound()

    t.assert_equals(User.create({ id = 7, name = 'Мария', age = 46 }).id, 7)

    -- Ведущий завис: соединение живо, вызов ждёт срок. Первое чтение
    -- платит срок и идёт к соседу, следующие идут к соседу сразу.
    nodes.b.throws = helper.timed_out()
    nodes.a.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    t.assert_equals(User.find(7).name, 'Мария')
    t.assert_equals(User.find(7).name, 'Мария')
    t.assert_equals(uris(), { 'a', 'b', 'b', 'a', 'a' })

    -- Из опроса молчащий не выпадает: запись, которой сосед ответил
    -- readonly, идёт и к нему — последним.
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'только чтение' }

    local _, err = User.create({ id = 8, name = 'Олег', age = 20 })

    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: core-a: только чтение; исход записи на core-b неизвестен: нет ответа за 2 с'
    )

    -- Проснувшись, узел принимает запись, снова становится ведущим
    -- и спрашивается первым.
    nodes.b.throws = nil
    nodes.b.reply = { ok = true, value = { id = 9, name = 'Анна', age = 30 } }

    t.assert_equals(User.create({ id = 9, name = 'Анна', age = 30 }).id, 9)

    nodes.b.reply = { ok = true }

    t.assert_equals(User.find(9), nil)
    t.assert_equals(uris(), { 'a', 'b', 'b', 'a', 'a', 'a', 'b', 'a', 'b', 'b' })
end

g.test_a_silent_first_node_is_passed_over_until_it_answers = function()
    -- Свежая привязка, записи ещё не было: первым идёт первый по имени.
    -- Он принимает соединение и молчит — чтение ждёт срок один раз.
    nodes.a = { reachable = false, pending = true }
    nodes.b.reply = { ok = true, value = { id = 1, name = 'b', age = 1 } }

    local User = bound()

    t.assert_equals(User.find(1).name, 'b')
    t.assert_equals(User.find(1).name, 'b')
    t.assert_equals(nodes.a.waits, 1, 'молчащего спросили один раз')

    -- Ожил — а чтение всё так же идёт к соседу, пока тот отвечает.
    nodes.a.reachable = nil
    nodes.a.reply = { ok = true, value = { id = 1, name = 'a', age = 1 } }

    t.assert_equals(User.find(1).name, 'b')
    t.assert_equals(nodes.a.waits, 1)

    -- Сосед замолчал: ответ ожившего возвращает его на место.
    nodes.b.throws = helper.timed_out()

    t.assert_equals(User.find(1).name, 'a')
    t.assert_equals(User.find(1).name, 'a')
    t.assert_equals(uris(), { 'b', 'b', 'b', 'b', 'a', 'a' })
end

g.test_silent_nodes_are_asked_in_the_order_they_fell_silent = function()
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.b.reply = { ok = true, value = { id = 1, name = 'b', age = 1 } }
    nodes.c = { reply = { ok = true, value = { id = 1, name = 'c', age = 1 } } }

    local User = bound({ 'a', 'b', 'c' })

    User.create({ id = 1, name = 'b', age = 1 })

    -- Замолкают по очереди ведущий b, затем a, затем c.
    nodes.b.throws = helper.timed_out()
    nodes.a.reply = { ok = true, value = { id = 1, name = 'a', age = 1 } }

    t.assert_equals(User.find(1).name, 'a')

    nodes.a.throws = helper.timed_out()

    t.assert_equals(User.find(1).name, 'c')

    nodes.c.throws = helper.timed_out()

    local before = #calls
    local _, err = User.find(1)

    -- Молчат все — каждый узел стоит своего срока, и отказ называет всех.
    -- Порядок молчавших — по времени, а не по имени: b замолчал раньше a.
    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: core-c: нет ответа за 2 с; core-b: нет ответа за 2 с; core-a: нет ответа за 2 с'
    )
    t.assert_equals(uris(before), { 'c', 'b', 'a' })

    before = #calls
    User.find(1)

    t.assert_equals(
        uris(before),
        { 'c', 'b', 'a' },
        'каждый замолчавший снова встаёт в конец, порядок держится'
    )
end

g.test_a_silent_follower_does_not_unseat_the_leader = function()
    nodes.a.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.b.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.c = { reply = { ok = true, value = { id = 1, name = 'c', age = 1 } } }

    local User = bound({ 'a', 'b', 'c' })

    User.create({ id = 1, name = 'c', age = 1 })

    -- Ведущий c ответил readonly, a не поднял соединения, b — readonly.
    nodes.c.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.a.reachable = false
    nodes.a.error = 'нет связи'

    local _, err = User.create({ id = 2, name = 'c', age = 1 })

    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: core-c: только чтение; core-a не отвечает: нет связи; core-b: только чтение'
    )

    -- Ведущим остаётся c: молчал не он.
    local before = #calls

    nodes.c.reply = { ok = true, value = { id = 1, name = 'c', age = 1 } }

    t.assert_equals(User.find(1).name, 'c')
    t.assert_equals(uris(before), { 'c' })
end

g.test_the_term_covers_the_connection_and_the_call_together = function()
    -- Соединение поднималось полторы секунды из двух — вызову остаётся
    -- полсекунды, а не новый срок.
    nodes.a.connecting = 1.5
    nodes.a.reply = { ok = true, value = 4 }

    local User = bound()

    t.assert_equals(User.scan():count(), 4)
    t.assert_equals(calls[1].opts, { timeout = 0.5 })

    -- Остаток считается от отметки цикла: она отстаёт от часов на работу
    -- без уступки, и ожидание net.box кончится ровно в срок.
    clock.lag = 0.25
    nodes.a.connecting = 0

    t.assert_equals(User.scan():count(), 4)
    t.assert_equals(calls[2].opts, { timeout = 2.25 })
end

g.test_no_time_left_after_connecting_sends_nothing = function()
    -- Соединение поднялось к самому концу срока либо позже: вызов
    -- со сроком 0 net.box всё равно отправил бы, а запись получила бы
    -- неизвестный исход. Запрос не уходит, и запись идёт дальше.
    for _, connecting in ipairs({ 2, 2.5 }) do
        calls = {}
        nodes = {
            a = { connecting = connecting, reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } } },
            b = { reply = { ok = false, kind = 'readonly', message = 'только чтение' } },
        }

        local _, err = bound().create({ id = 7, name = 'Мария', age = 46 })

        t.assert_equals(
            tostring(err),
            'репликасет core не ответил: core-a: нет ответа за 2 с; core-b: только чтение'
        )
        t.assert_equals(uris(), { 'b' })
    end
end

g.test_a_broken_connection_is_replaced_on_the_next_call = function()
    nodes.a.reachable = false
    nodes.a.error = 'Peer closed'

    local User = bound({ 'a' })
    local _, err = User.find(1)

    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: core-a не отвечает: Peer closed'
    )
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
    nodes.a.throws = peer_closed()

    local _, dropped = User.find(1)

    t.assert_equals(
        tostring(dropped),
        'репликасет core не ответил: core-a не отвечает: Peer closed'
    )

    nodes.a.drops = nil
    nodes.a.throws = nil

    t.assert_equals(User.find(1).name, 'a')
    t.assert_equals(nodes.a.opened, 3)
end

g.test_a_slow_connection_is_waited_for_and_not_replaced = function()
    nodes.a.reachable = false
    nodes.a.pending = true

    local User = bound({ 'a' })
    local _, err = User.find(1)

    -- Ошибки у соединения, которое ещё поднимается, нет: отказ называет
    -- срок, а не «nil».
    t.assert_equals(
        tostring(err),
        'репликасет core не ответил: core-a: нет ответа за 2 с'
    )

    User.find(1)

    t.assert_equals(
        nodes.a.opened,
        1,
        'соединение, которое ещё поднимается, ждут снова'
    )
    t.assert_equals(nodes.a.waits, 2)

    -- Отказ самой функции соединение не рвёт: оно остаётся.
    nodes.a.reachable = nil
    nodes.a.throws = no_such_proc('tnt_model_find')

    t.assert_equals(User.find(1), nil)
    t.assert_equals(User.find(1), nil)
    t.assert_equals(nodes.a.opened, 1)
end

g.test_close_drops_idle_connections_and_the_closed_gateway_refuses = function()
    nodes.a.reply = { ok = true }

    local User, gateway = bound()

    User.find(1)
    gateway.close()

    t.assert_equals(
        nodes.a.closed,
        1,
        'вызовов в пути нет — соединение закрыто сразу'
    )
    t.assert_equals(nodes.b.closed, nil)

    -- Закрытый шлюз новых обращений не принимает и соединений не открывает:
    -- модели к этому мигу смотрят на новую привязку.
    local found, err = User.find(1)
    local created, refused = User.create({ id = 7, name = 'Мария', age = 46 })

    t.assert_equals({ found, created }, { nil, nil })

    for _, failure in ipairs({ err, refused }) do
        t.assert_equals(failure.kind, 'unavailable')
        t.assert_equals(tostring(failure), 'репликасет core: привязка закрыта')
    end

    t.assert_equals(#calls, 1)
    t.assert_equals(nodes.a.opened, 1)
    t.assert_equals(nodes.b.opened, nil)

    gateway.close()

    t.assert_equals(
        nodes.a.closed,
        1,
        'закрытое соединение второй раз не закрывается'
    )
end

g.test_calls_in_flight_get_their_answers_and_connections_close_after_the_last = function()
    local User, gateway = led_by_b()
    local answers = {}

    -- Запись и чтение ушли ведущему и ждут ответа, а тем временем
    -- конфигурацию перечитали.
    nodes.b.gate = fiber.channel(2)
    launched(answers, 'write', User.create, { id = 8, name = 'Олег', age = 20 })
    launched(answers, 'read', User.find, 7)
    gateway.close()

    t.assert_equals(
        { nodes.a.closed, nodes.b.closed },
        { nil, nil },
        'соединения держатся, пока вызовы в пути'
    )

    nodes.b.reply = { ok = true, value = { id = 8, name = 'Олег', age = 20 } }
    nodes.b.gate:put(true)

    t.assert_equals(awaited(answers, 'write').value:to_table(), { id = 8, name = 'Олег', age = 20 })
    t.assert_equals(
        { nodes.a.closed, nodes.b.closed },
        { nil, nil },
        'чтение ещё в пути — соединения держатся'
    )

    nodes.b.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }
    nodes.b.gate:put(true)

    t.assert_equals(awaited(answers, 'read').value:to_table(), { id = 7, name = 'Мария', age = 46 })
    t.assert_equals(
        { nodes.a.closed, nodes.b.closed },
        { 1, 1 },
        'последний вызов вернулся — закрыты все'
    )
    t.assert_equals(uris(), { 'a', 'b', 'b', 'b' })
    t.assert_equals(nodes.a.opened, 1)
    t.assert_equals(nodes.b.opened, 1)
end

g.test_a_write_in_flight_goes_on_by_an_open_connection_after_close = function()
    local User, gateway = led_by_b()
    local answers = {}

    -- Ведущий сменился, пока запись ждала: b отвечает readonly, и запись
    -- идёт к a по соединению, которое закрытый шлюз ещё держит.
    nodes.b.gate = fiber.channel(1)
    launched(answers, 'write', User.create, { id = 8, name = 'Олег', age = 20 })
    gateway.close()

    nodes.a.reply = { ok = true, value = { id = 8, name = 'Олег', age = 20 } }
    nodes.b.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.b.gate:put(true)

    t.assert_equals(awaited(answers, 'write').value.id, 8)
    t.assert_equals(uris(), { 'a', 'b', 'b', 'a' })
    t.assert_equals(nodes.a.opened, 1, 'новое соединение не открывалось')
    t.assert_equals({ nodes.a.closed, nodes.b.closed }, { 1, 1 })
end

g.test_a_call_in_flight_opens_the_connection_it_needs_and_it_closes_too = function()
    nodes.c = {}

    local User, gateway = led_by_b({ 'a', 'b', 'c' })
    local answers = {}

    -- С c шлюз ещё не соединялся. Запись, которой a и b ответили readonly,
    -- идёт к нему и после закрытия: вызов в пути доходит до конца прежними
    -- правилами, иначе ведущий c её бы не получил.
    nodes.b.gate = fiber.channel(1)
    launched(answers, 'write', User.create, { id = 8, name = 'Олег', age = 20 })
    gateway.close()

    nodes.b.reply = { ok = false, kind = 'readonly', message = 'только чтение' }
    nodes.c.reply = { ok = true, value = { id = 8, name = 'Олег', age = 20 } }
    nodes.b.gate:put(true)

    t.assert_equals(awaited(answers, 'write').value.id, 8)
    t.assert_equals(uris(), { 'a', 'b', 'b', 'a', 'c' })

    -- Открытое после закрытия закрывается вместе с прочими — ничего
    -- не висит до сборки мусора.
    t.assert_equals(nodes.c.opened, 1)
    t.assert_equals({ nodes.a.closed, nodes.b.closed, nodes.c.closed }, { 1, 1, 1 })
end

g.test_an_exception_inside_a_call_still_lets_the_gateway_close = function()
    -- Узел ответил не таблицей: разбор ответа бросает. Бросок уходит
    -- вызывающему как есть, а вызов в пути больше не числится — закрытие
    -- не ждёт его вечно.
    nodes.a.reply = 42

    local User, gateway = bound()

    t.assert_error_msg_contains('attempt to index', User.find, 1)

    gateway.close()

    t.assert_equals(nodes.a.closed, 1)
end

g.test_atomic_is_impossible_without_data = function()
    local _, gateway = bound()

    t.assert_error_msg_equals(
        'транзакция на узле без данных невозможна: box.atomic живёт в функции узла с данными',
        gateway.atomic,
        function() end
    )
end

-- Запись по сети легла бы на узле с данными своей транзакцией: откат
-- здешней её не отменил бы, и транзакция молча вышла бы частичной.
-- Чтение данных не меняет и идёт к узлу и в транзакции.
g.test_writes_inside_a_transaction_are_programmer_errors = function()
    local User = bound()
    local refused = 'модель users: запись на узле без данных в транзакции невозможна — она ушла бы по сети '
        .. 'и легла мимо транзакции; box.atomic живёт в функции узла с данными'

    in_txn = true

    t.assert_error_msg_equals(refused, User.create, { id = 7, name = 'Мария', age = 46 })
    t.assert_error_msg_equals(refused, User.delete, 7)
    t.assert_equals(calls, {}, 'к узлам ничего не ушло')
    t.assert_equals(nodes.a.opened, nil, 'соединение не открывалось')

    nodes.a.reply = { ok = true, value = { id = 7, name = 'Мария', age = 46 } }

    t.assert_equals(User.find(7).id, 7)

    in_txn = false

    t.assert_equals(User.create({ id = 7, name = 'Мария', age = 46 }).id, 7)
    t.assert_equals(calls[2].name, 'tnt_model_put')
end
