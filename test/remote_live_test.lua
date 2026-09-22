--- Узел-прослойка без своих данных: шлюз `remote` ходит по net.box
--- в репликасет с данными под учёткой `iproto.advertise.sharding`,
--- запись находит ведущего по отказу `readonly`, чтение идёт на любой узел.
---
--- Ведущим назначен второй по имени узел: первый отвечает `readonly`,
--- и шлюз обязан его пропустить, а не сдаться.

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
    helper.stop_stand(g.stand)
end)

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
    t.assert_equals(seen.status, { source = 'remote', sharded = false, serves = false, spaces = { 'users' } })
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
