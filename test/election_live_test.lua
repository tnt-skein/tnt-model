--- Репликасет с выборами и зависший ведущий: запись, ушедшая к нему без
--- ответа, другому узлу не отдаётся ни прослойкой, ни репликой
--- с пересылкой — вызывающий получает `unavailable`, а не `ok`. Срок
--- платится один раз: промолчавший ведущий уходит в конец опроса,
--- и следующие чтение и запись идут мимо него — запись к новому ведущему.
---
--- Ведущего выбирают сами узлы (`failover: election`). Проверка
--- останавливает его сигналом SIGSTOP: соединения к нему живы, запрос
--- уходит в сокет и ждёт срок, а соседи тем временем выбирают нового.
--- Повтор у нового ведущего положил бы запись второй раз: прежний,
--- проснувшись, исполнит свою копию из сокета. Поэтому проверяется,
--- что новый ведущий вызова не получал, а прежний получил его,
--- когда проснулся, — ровно один узел.
---
--- Функции `tnt_model_put` и `tnt_model_find` на каждом узле проверка
--- оборачивает счётчиком: net.box ищет функцию по имени при каждом вызове,
--- и обёртка видит каждую запись и каждое чтение, пришедшие по сети.
--- Проснувшись, зависший узел исполняет всё, что ждало в его сокете, —
--- по обёртке видно, что туда ушло.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.election_live')

--- Узлы репликасета с данными.
local CORE = { 'core-a', 'core-b', 'core-c' }

--- Срок обращения шлюза к узлу, секунды: метка `model_timeout` у всех.
local TIMEOUT = 1

--- Конфигурация: три узла с выборами — каждый пересылает запись, пока
--- не ведущий, — и прослойка без данных.
---@param ports table<string, integer>
---@return string
local function config_of(ports)
    local members = {}

    for _, name in ipairs(CORE) do
        table.insert(members, { name, ("labels: { model_writes: forward, model_timeout: '%d' }"):format(TIMEOUT) })
    end

    local gateways = [[
  gateways:
    labels: { model_source: 'remote', model_replicaset: 'core', model_timeout: '%d' }
    replicasets:
      gw:
        instances:
          gw-a: { iproto: { listen: [{ uri: '127.0.0.1:%d' }] } }
]]

    return helper.core_config(ports, nil, members, gateways:format(TIMEOUT, ports['gw-a']))
end

--- Ведущий среди названных узлов: ждёт, пока выборы его дадут.
---@param names string[]
---@return string
local function elected(names)
    ---@type string|nil
    local found

    t.helpers.retrying({ timeout = 30, delay = 0.2 }, function()
        found = nil

        for _, name in ipairs(names) do
            if g.stand[name]:exec(function()
                return not box.info.ro
            end) then
                found = name
            end
        end

        t.assert_not_equals(found, nil, 'ведущий ещё не выбран')
    end)

    return assert(found)
end

--- Ключи записей, которые пришли на узел вызовом `tnt_model_put`
--- либо `tnt_model_find`.
---@param name string
---@param what string|nil put либо find; по умолчанию put
---@return integer[]
local function seen_ids(name, what)
    return g.stand[name]:exec(function(list)
        local ids = {}

        for _, seen in ipairs(rawget(_G, list)) do
            table.insert(ids, seen)
        end

        return ids
    end, { (what or 'put') .. '_seen' })
end

--- Запись моделью на узле: ключ либо род и текст отказа.
---@param name string Узел стенда
---@param id integer
---@return table
local function create_on(name, id)
    return g.stand[name]:exec(function(key)
        local created, err = rawget(_G, 'User').create({ id = key, name = 'Вера', age = 33 })

        if created ~= nil then
            return { id = created.id }
        end

        return { kind = err.kind, message = tostring(err) }
    end, { id })
end

g.before_all(function()
    local ports = { ['gw-a'] = helper.free_port() }

    for _, name in ipairs(CORE) do
        ports[name] = helper.free_port()
    end

    g.stand = helper.start_stand(config_of(ports), ports, { 'core-a', 'core-b', 'core-c', 'gw-a' })
    g.gateway = g.stand['gw-a']
    g.leader = elected(CORE)

    -- Сценарий узла поднимает схему только там, где узел уже принимает
    -- запись, а выборы могли кончиться позже: схему ставит проверка.
    g.stand[g.leader]:exec(function()
        if box.space.users == nil then
            box.atomic(function()
                rawget(_G, 'User').migration()(box)
                rawget(_G, 'Post').migration()(box)
            end)
        end
    end)

    for _, name in ipairs(CORE) do
        t.helpers.retrying({ timeout = 10 }, function()
            t.assert(g.stand[name]:exec(function()
                return box.space.users ~= nil
            end))
        end)

        g.stand[name]:exec(function()
            local served = rawget(_G, 'tnt_model_put')
            local found = rawget(_G, 'tnt_model_find')
            local seen = {}
            local asked = {}

            rawset(_G, 'put_seen', seen)
            rawset(_G, 'find_seen', asked)
            rawset(_G, 'tnt_model_put', function(space, values, mode)
                table.insert(seen, values.id)

                return served(space, values, mode)
            end)
            rawset(_G, 'tnt_model_find', function(space, key)
                table.insert(asked, key[1])

                return found(space, key)
            end)
        end)
    end
end)

g.after_all(function()
    -- Остановленный узел не гасится, пока его не разбудят.
    for _, server in pairs(g.stand) do
        if server.process ~= nil then
            server.process:kill('CONT', { quiet = true })
        end
    end

    helper.stop_stand(g.stand)
end)

g.test_a_write_to_a_hung_leader_is_not_repeated_on_the_new_one = function()
    local leader = g.leader
    ---@type string[]
    local followers = {}

    for _, name in ipairs(CORE) do
        if name ~= leader then
            table.insert(followers, name)
        end
    end

    local first, second = assert(followers[1]), assert(followers[2])

    -- Прослойка и обе реплики пишут и запоминают ведущего.
    t.assert_equals(create_on('gw-a', 1), { id = 1 })
    t.assert_equals(create_on(first, 2), { id = 2 })
    t.assert_equals(create_on(second, 3), { id = 3 })
    t.assert_items_equals(seen_ids(leader), { 1, 2, 3 }, 'все три записи принял ведущий')

    -- Репликация асинхронная: запись, не доехавшая до реплик к остановке
    -- ведущего, у них так и не появится, и чтение через соседа ниже
    -- проверяло бы отставание, а не обход.
    for _, name in ipairs(followers) do
        t.helpers.retrying({ timeout = 10 }, function()
            t.assert_equals(
                g.stand[name]:exec(function()
                    return box.space.users:count()
                end),
                3,
                ('%s ещё не получил записи журналом'):format(name)
            )
        end)
    end

    g.stand[leader].process:kill('STOP')

    local successor = elected(followers)
    local follower = successor == first and second or first
    local unknown = ('репликасет core не ответил: исход записи на %s неизвестен: нет ответа за %d с'):format(
        leader,
        TIMEOUT
    )

    -- Запись ушла прежнему ведущему и ждала срок; новому она не уходит.
    t.assert_equals(create_on('gw-a', 10), { kind = 'unavailable', message = unknown })
    t.assert_equals(create_on(follower, 11), { kind = 'unavailable', message = unknown })

    for _, name in ipairs(followers) do
        t.assert_items_exclude(
            seen_ids(name),
            { 10, 11 },
            ('%s получил запись, ушедшую прежнему'):format(name)
        )
    end

    -- Промолчавший ведущий ушёл в конец опроса: чтение идёт к соседу
    -- сразу, а следующие записи находят нового ведущего — и у прослойки,
    -- и у реплики с пересылкой.
    local found = g.gateway:exec(function()
        return rawget(_G, 'User').find(2):to_table()
    end)

    t.assert_equals(found, { id = 2, name = 'Вера', age = 33 })
    t.assert_equals(create_on('gw-a', 12), { id = 12 })
    t.assert_equals(create_on(follower, 13), { id = 13 })
    t.assert_items_include(seen_ids(successor), { 12, 13 })

    -- Проснувшись, прежний ведущий получает обе записи из сокета: вызов
    -- дошёл до одного узла — до того, кому ушёл. Ни чтения, ни записей,
    -- которые шли после его молчания, в сокете не было.
    g.stand[leader].process:kill('CONT')

    t.helpers.retrying({ timeout = 10 }, function()
        t.assert_items_include(seen_ids(leader), { 10, 11 })
    end)

    t.assert_items_exclude(seen_ids(leader), { 12, 13 })
    t.assert_equals(seen_ids(leader, 'find'), {}, 'чтение ждало у молчащего ведущего')
end
