--- Узел-прослойка без своих данных: шлюз `remote` ходит по net.box
--- в репликасет с данными под учёткой `iproto.advertise.sharding`,
--- запись находит ведущего по отказу `readonly`, чтение идёт на любой узел.
---
--- Ведущим назначен второй по имени узел: первый отвечает `readonly`,
--- и шлюз обязан его пропустить, а не сдаться.
---
--- Перечитывание конфигурации (`rebind` сценария узла) не обрывает вызовы
--- в пути: запись, ушедшая ведущему до перечитывания, получает его ответ,
--- а соединения прежней привязки закрываются, когда вызовы кончились.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.remote_live')

--- Конфигурация: репликасет из двух узлов и прослойка без данных.
---@param ports table<string, integer>
---@return string
local function config_of(ports)
    local gateways = [[
  gateways:
    labels: { model_source: 'remote', model_replicaset: 'core' }
    replicasets:
      gw:
        instances:
          gw-a: { iproto: { listen: [{ uri: '127.0.0.1:%d' }] } }
]]

    return helper.core_config(ports, 'core-b', { { 'core-a' }, { 'core-b' } }, gateways:format(ports['gw-a']))
end

g.before_all(function()
    local ports = { ['core-a'] = helper.free_port(), ['core-b'] = helper.free_port(), ['gw-a'] = helper.free_port() }

    g.stand = helper.start_stand(config_of(ports), ports, { 'core-a', 'core-b', 'gw-a' })
    g.gateway = g.stand['gw-a']
end)

g.after_all(function()
    -- Остановленный узел не гасится, пока его не разбудят.
    g.stand['core-b'].process:kill('CONT', { quiet = true })
    helper.stop_stand(g.stand)
end)

--- Узлы с данными: на них считаются соединения прослойки.
local CORE = { 'core-a', 'core-b' }

--- Запись моделью на прослойке, которая обязана лечь.
---
--- Первая запись свежей привязки проходит core-a с отказом `readonly`
--- и ложится на core-b: после неё привязка держит соединения с обоими.
---@param id integer
local function landed(id)
    helper.created(g.gateway, id)
end

g.test_gateway_node_reads_and_writes_through_the_replicaset = function()
    local seen = g.gateway:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local created = User.create({ id = 1, name = 'Мария', age = 46 })

        assert(User.create({ id = 2, name = 'Иван', age = 30 }))

        local _, twice = User.create({ id = 1, name = 'Мария', age = 46 })
        local _, invalid = User.create({ id = 3, name = 'Анна', age = 500 })
        local record = assert(User.find(2))

        record.age = 31
        record:save()

        return {
            bound = User.bound(),
            status = rawget(_G, 'binding').status(),
            served = rawget(_G, 'tnt_model_find'),
            space = box.space.users,
            created = created:to_table(),
            twice = twice.kind,
            invalid = { invalid.kind, invalid.fields.age },
            found = User.find(1):to_table(),
            adult = User.find(1):is_adult(),
            missing = User.find(404),
            saved = User.find(2).age,
            adults = #User.where('age', '>=', 18):all(),
            counted = User.scan():count(),
            first = User.where('age', '>', 40):first().name,
            deleted = { User.delete(2), User.delete(2) },
        }
    end)

    t.assert_equals(seen.bound, 'remote')
    t.assert_equals(seen.status, { source = 'remote', sharded = false, serves = false, spaces = { 'users', 'posts' } })
    t.assert_equals(
        seen.served,
        nil,
        'прослойка функций узла с данными не публикует'
    )
    t.assert_equals(seen.space, nil, 'спейса на прослойке нет')
    t.assert_equals(seen.created, { id = 1, name = 'Мария', age = 46 })
    t.assert_equals(seen.twice, 'conflict')
    t.assert_equals(
        seen.invalid,
        { 'invalid', 'должно быть целым числом от 0 до 150, а не 500' }
    )
    t.assert_equals(seen.found, { id = 1, name = 'Мария', age = 46 })
    t.assert_equals(seen.adult, true)
    t.assert_equals(seen.missing, nil)
    t.assert_equals(seen.saved, 31)
    t.assert_equals(seen.adults, 2)
    t.assert_equals(seen.counted, 2)
    t.assert_equals(seen.first, 'Мария')
    t.assert_equals(seen.deleted, { true, false })

    -- Данные легли на ведущем — втором по имени узле репликасета.
    local leader = g.stand['core-b']:exec(function()
        return { ro = box.info.ro, ids = box.space.users.index.primary:select() }
    end)

    t.assert_equals(leader.ro, false)
    t.assert_equals(#leader.ids, 1)
    t.assert_equals(leader.ids[1][1], 1)
    t.assert_equals(
        g.stand['core-a']:exec(function()
            return box.info.ro
        end),
        true
    )
end

g.test_a_reload_lets_calls_in_flight_finish_and_then_closes_connections = function()
    -- Прослойка знает ведущего и держит соединения с обоими узлами.
    landed(20)
    helper.await_replication(g.stand, CORE)

    local before = helper.connections(g.stand, CORE)

    -- Ведущий завис: запись и чтение ушли к нему и ждут ответа, а тем
    -- временем прослойка перечитывает конфигурацию.
    g.stand['core-b'].process:kill('STOP')
    g.gateway:exec(function()
        local fiber = require('fiber')
        ---@type any
        local User = rawget(_G, 'User')
        local answers = {}

        --- Ответ модели: ключ записи либо род и текст отказа.
        ---@param record any
        ---@param err any
        ---@return table
        local function answer(record, err)
            if record ~= nil then
                return { id = record.id }
            end

            return { kind = err.kind, message = tostring(err) }
        end

        rawset(_G, 'answers', answers)
        fiber.create(function()
            answers.write = answer(User.create({ id = 21, name = 'Вера', age = 33 }))
        end)
        fiber.create(function()
            answers.read = answer(User.find(20))
        end)
        fiber.sleep(0.2)
        rawget(_G, 'rebind')()
    end)
    g.stand['core-b'].process:kill('CONT')

    local answers = {}

    t.helpers.retrying({ timeout = 10 }, function()
        answers = g.gateway:exec(function()
            local given = rawget(_G, 'answers')

            return { write = given.write, read = given.read }
        end)

        t.assert_not_equals(answers.write, nil, 'запись ещё ждёт ответа')
        t.assert_not_equals(answers.read, nil, 'чтение ещё ждёт ответа')
    end)

    t.assert_equals(
        answers,
        { write = { id = 21 }, read = { id = 20 } },
        'вызовы в пути получили ответ ведущего'
    )
    t.assert_equals(
        g.stand['core-b']:exec(function()
            return box.space.users:get(21) ~= nil
        end),
        true
    )

    -- Прежняя привязка закрыла свои соединения, когда вызовы кончились:
    -- у каждого узла их на одно меньше.
    t.helpers.retrying({ timeout = 10 }, function()
        t.assert_equals(
            helper.connections(g.stand, CORE),
            { ['core-a'] = before['core-a'] - 1, ['core-b'] = before['core-b'] - 1 }
        )
    end)

    -- Новая открывает свои первым обращением — число прежнее.
    landed(22)

    t.helpers.retrying({ timeout = 10 }, function()
        t.assert_equals(helper.connections(g.stand, CORE), before)
    end)
end

g.test_writes_under_reloads_are_all_answered = function()
    local base = 1000000

    landed(30)
    helper.await_replication(g.stand, CORE)

    local before = helper.connections(g.stand, CORE)
    local seen = helper.write_under_reloads(g.gateway, base)

    t.assert_equals(seen.refusals, {})
    t.assert_gt(seen.written, 0)
    t.assert_equals(
        helper.stored_from(g.stand['core-b'], base),
        seen.written,
        'каждая принятая запись легла'
    )

    -- Прежние привязки закрыли свои соединения, а последняя после пятого
    -- перечитывания могла не успеть обратиться к узлам: одна запись
    -- открывает её соединения, и число снова прежнее — лишних нет.
    landed(31)

    t.helpers.retrying({ timeout = 10 }, function()
        t.assert_equals(helper.connections(g.stand, CORE), before)
    end)
end

-- Запись прослойки ушла бы по сети и легла на ведущем своей транзакцией:
-- откат транзакции прослойки её не отменил бы. Теперь это исключение,
-- и записи на узлах с данными нет.
g.test_gateway_node_refuses_writes_inside_a_transaction = function()
    local seen = g.gateway:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local rolled = {
            pcall(box.atomic, function()
                assert(User.create({ id = 8101, name = 'Откат', age = 30 }))
                error('нарочный откат', 0)
            end),
        }

        return { rolled = rolled, lost = User.find(8101) == nil }
    end)

    t.assert_equals(seen.rolled, {
        false,
        'модель users: запись на узле без данных в транзакции невозможна — она ушла бы по сети '
            .. 'и легла мимо транзакции; box.atomic живёт в функции узла с данными',
    })
    t.assert_equals(seen.lost, true)
    t.assert_equals(
        g.stand['core-b']:exec(function()
            return box.space.users:get(8101) == nil
        end),
        true
    )
end
