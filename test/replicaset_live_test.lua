--- Репликасет без шардирования: ведущий пишет, реплика читает, а запись
--- отвергает либо — с `writes: forward` — пересылает ведущему. Три
--- процесса под одной конфигурацией кластера.
---
--- Проверки идут по порядку объявления (luatest по умолчанию сортирует
--- их по строке). Последняя гасит ведущего и поднимает его снова —
--- поэтому она и стоит последней: соседям незачем видеть стенд без ведущего.

local t = require('luatest')

local helper = dofile('test/helper.lua')

--- Конфигурация кластера: репликасет из трёх узлов, ведущий назначен.
---
--- Реплика core-b пересылает запись (`model_writes: forward` — метка,
--- из которой сценарий стенда собирает раздел `models`), core-c — нет.
--- Пересылка ходит под учёткой `iproto.advertise.sharding`, как
--- прослойка: ей нужны права на функции и спейс модели.
---@param ports table<string, integer>
---@return string
local function config_of(ports)
    return helper.core_config(ports, 'core-a', {
        { 'core-a' },
        { 'core-b', 'labels: { model_writes: forward }' },
        { 'core-c' },
    })
end

local g = t.group('tnt.model.replicaset_live')

--- Ключи записей ведущего по порядку.
---@return integer[]
local function leader_ids()
    return g.leader:exec(function()
        local ids = {}

        for _, stored in box.space.users:pairs() do
            table.insert(ids, stored[1])
        end

        return ids
    end)
end

g.before_all(function()
    local ports = {
        ['core-a'] = helper.free_port(),
        ['core-b'] = helper.free_port(),
        ['core-c'] = helper.free_port(),
    }

    g.stand = helper.start_stand(config_of(ports), ports, { 'core-a', 'core-b', 'core-c' })
    g.leader = g.stand['core-a']
    g.forwarding = g.stand['core-b']
    g.replica = g.stand['core-c']
end)

g.after_all(function()
    helper.stop_stand(g.stand)
end)

g.test_leader_writes_replica_reads_and_refuses_writes = function()
    local written = g.leader:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local created = User.create({ id = 1, name = 'Мария', age = 46 })

        User.create({ id = 2, name = 'Иван', age = 30 })

        return {
            bound = User.bound(),
            status = rawget(_G, 'binding').status(),
            created = created:to_table(),
            format = #box.space.users:format(),
            served = rawget(_G, 'tnt_model_find') ~= nil,
            ro = box.info.ro,
        }
    end)

    t.assert_equals(written.bound, 'local')
    t.assert_equals(written.status, { source = 'local', sharded = false, serves = true, spaces = { 'users' } })
    t.assert_equals(written.created, { id = 1, name = 'Мария', age = 46 })
    t.assert_equals(written.format, 3, 'без шардирования поля bucket_id нет')
    t.assert_equals(written.served, true)
    t.assert_equals(written.ro, false)

    -- Реплика догоняет ведущего журналом: и схему, и записи.
    t.helpers.retrying({ timeout = 8 }, function()
        t.assert_equals(
            g.replica:exec(function()
                return box.space.users ~= nil and box.space.users:count() or 0
            end),
            2
        )
    end)

    local read = g.replica:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local _, created = User.create({ id = 3, name = 'Анна', age = 19 })
        local _, deleted = User.delete(1)
        local _, saved = User.find(1):save()

        return {
            bound = User.bound(),
            status = rawget(_G, 'binding').status(),
            found = User.find(1):to_table(),
            adults = User.where('age', '>=', 18):count(),
            created = { created.kind, tostring(created) },
            deleted = deleted.kind,
            saved = saved.kind,
            served = rawget(_G, 'tnt_model_put')('users', { id = 9, name = 'x', age = 1 }, 'insert'),
        }
    end)

    t.assert_equals(read.bound, 'local')
    t.assert_equals(read.status, { source = 'local', sharded = false, serves = true, spaces = { 'users' } })
    t.assert_equals(read.found, { id = 1, name = 'Мария', age = 46 })
    t.assert_equals(read.adults, 2)
    t.assert_equals(read.created, { 'readonly', 'узел только для чтения: config' })
    t.assert_equals(read.deleted, 'readonly')
    t.assert_equals(read.saved, 'readonly')
    t.assert_equals(
        read.served.kind,
        'readonly',
        'функция узла с данными отвечает тем же отказом'
    )
    t.assert_equals(
        leader_ids(),
        { 1, 2 },
        'реплика без пересылки ведущему ничего не отдала'
    )
end

g.test_replica_forwards_writes_to_the_leader = function()
    t.helpers.retrying({ timeout = 8 }, function()
        t.assert_equals(
            g.forwarding:exec(function()
                return box.space.users ~= nil and box.space.users:count() or 0
            end),
            2
        )
    end)

    local seen = g.forwarding:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local created, err = User.create({ id = 10, name = ' Пётр ', age = 52 })

        assert(created, tostring(err))

        local _, twice = User.create({ id = 10, name = 'Снова', age = 1 })
        local _, invalid = User.create({ id = 11, name = '', age = 1 })
        local record = assert(User.find(2))

        record.age = 31

        local saved, refused = record:save()

        assert(saved, tostring(refused))

        local atomic, in_txn = rawget(_G, 'model').atomic(function()
            return User.create({ id = 13, name = 'Олег', age = 20 })
        end)

        return {
            bound = User.bound(),
            status = rawget(_G, 'binding').status(),
            ro = box.info.ro,
            created = created:to_table(),
            twice = twice.kind,
            invalid = { invalid.kind, invalid.fields.name },
            saved = saved.age,
            deleted = { User.delete(1), User.delete(1) },
            served = rawget(_G, 'tnt_model_put')('users', { id = 12, name = 'x', age = 1 }, 'insert'),
            atomic = { atomic, in_txn.kind, tostring(in_txn) },
        }
    end)

    t.assert_equals(seen.bound, 'local', 'читает реплика у себя')
    t.assert_equals(
        seen.status,
        { source = 'local', sharded = false, serves = true, writes = 'forward', spaces = { 'users' } }
    )
    t.assert_equals(seen.ro, true)
    t.assert_equals(seen.created, { id = 10, name = 'Пётр', age = 52 })
    t.assert_equals(seen.twice, 'conflict', 'отказ ведущего доходит до вызывающего')
    t.assert_equals(seen.invalid, {
        'invalid',
        'должно быть строкой длиной от 1 до 255 знаков, а сейчас 0 знаков',
    })
    t.assert_equals(seen.saved, 31)
    t.assert_equals(seen.deleted, { true, false })
    t.assert_equals(
        seen.served.kind,
        'readonly',
        'функция узла с данными не пересылает: иначе реплики гоняли бы запись по кругу'
    )
    t.assert_equals(seen.atomic, {
        nil,
        'readonly',
        'узел только для чтения: config; в транзакции запись ведущему не пересылается',
    })

    -- Запись легла на ведущем, и он видит её моделью.
    local leader = g.leader:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        return {
            created = User.find(10):to_table(),
            saved = User.find(2).age,
            deleted = User.find(1),
        }
    end)

    t.assert_equals(leader.created, { id = 10, name = 'Пётр', age = 52 })
    t.assert_equals(leader.saved, 31)
    t.assert_equals(leader.deleted, nil)
    t.assert_equals(leader_ids(), { 2, 10 })

    -- Журналом запись доезжает и до самой реплики.
    t.helpers.retrying({ timeout = 8 }, function()
        t.assert_equals(
            g.forwarding:exec(function()
                return rawget(_G, 'User').find(10) ~= nil
            end),
            true
        )
    end)
end

g.test_forwarding_without_the_leader_names_every_node_and_resumes = function()
    g.leader:stop()

    local refused = g.forwarding:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local _, err = User.create({ id = 20, name = 'Вера', age = 33 })

        return { kind = err.kind, message = tostring(err) }
    end)

    t.assert_equals(refused.kind, 'unavailable', 'молчащий ведущий — не readonly')
    t.assert_str_matches(
        refused.message,
        '^репликасет core не ответил: core%-a .+; core%-c: узел только для чтения: config$'
    )

    -- Ведущий вернулся — пересылка идёт снова, без перечитывания
    -- конфигурации: оборванное соединение заменено новым.
    g.leader:start({ wait_until_ready = true })

    t.helpers.retrying({ timeout = 8 }, function()
        t.assert_equals(
            g.forwarding:exec(function()
                local created, err = rawget(_G, 'User').create({ id = 20, name = 'Вера', age = 33 })

                return created ~= nil and created.id or tostring(err)
            end),
            20
        )
    end)

    t.assert_equals(leader_ids(), { 2, 10, 20 })
end
