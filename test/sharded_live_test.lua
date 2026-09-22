--- Шардированный кластер: роутер и два хранилища. Через роутер — шлюз
--- `sharded`: запись ложится в бакет своего ключа, чтение и страницы
--- по индексу собираются с обоих хранилищ; на хранилище — шлюз `local`
--- с полем шардирования, чужой бакет не принимается, чужой спейс
--- по имени недоступен.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.sharded_live')

--- Число бакетов: маленькое, чтобы оба хранилища получили записи.
local BUCKETS = 30

--- Конфигурация кластера: два хранилища по одному узлу и роутер.
---@param ports table<string, integer>
---@return string
local function config_of(ports)
    return ([[
credentials:
  users:
    client: { password: 'client-secret', roles: [super] }
    replicator: { password: 'replicator-secret', roles: [replication] }
    storage: { password: 'storage-secret', roles: [sharding] }
iproto:
  advertise:
    peer: { login: replicator }
    sharding: { login: storage }
sharding:
  bucket_count: %d
groups:
  storages:
    sharding: { roles: [storage] }
    replication: { failover: manual }
    replicasets:
      storage-001:
        leader: storage-a
        instances:
          storage-a: { iproto: { listen: [{ uri: '127.0.0.1:%d' }] } }
      storage-002:
        leader: storage-b
        instances:
          storage-b: { iproto: { listen: [{ uri: '127.0.0.1:%d' }] } }
  routers:
    sharding: { roles: [router] }
    replicasets:
      router-001:
        instances:
          router-a: { iproto: { listen: [{ uri: '127.0.0.1:%d' }] } }
]]):format(BUCKETS, ports['storage-a'], ports['storage-b'], ports['router-a'])
end

g.before_all(function()
    local ports = {
        ['storage-a'] = helper.free_port(),
        ['storage-b'] = helper.free_port(),
        ['router-a'] = helper.free_port(),
    }

    g.stand = helper.start_stand(config_of(ports), ports, { 'storage-a', 'storage-b', 'router-a' })
    g.router = g.stand['router-a']

    -- Разметка бакетов — с роутера, как это делает провайдер шардирования
    -- приложения; хранилища могут ещё подниматься.
    t.helpers.retrying({ timeout = 8 }, function()
        t.assert(g.router:exec(function()
            return (require('vshard').router.bootstrap({ if_not_bootstrapped = true }))
        end))
    end)
end)

g.after_all(function()
    helper.stop_stand(g.stand)
end)

g.test_router_writes_reads_and_pages_across_storages = function()
    local seen = g.router:exec(function(buckets)
        ---@type any
        local User = rawget(_G, 'User')
        local hash = require('vshard.hash')
        local placed = {}

        for id = 1, 12 do
            assert(User.create({ id = id, name = 'Клиент ' .. id, age = 10 + id * 5 }))

            placed[tostring(id)] = hash.mpcrc32(id) % buckets + 1
        end

        local _, twice = User.create({ id = 1, name = 'Снова', age = 20 })
        local _, invalid = User.create({ id = 13, name = '', age = 20 })
        local ids = function(rows)
            local listed = {}

            for _, row in ipairs(rows) do
                table.insert(listed, row.id)
            end

            return listed
        end

        local page = User.where('age', '>=', 40):limit(5):all()
        local rest = User.where('age', '>=', 40):limit(5):after(page[#page]):all()

        local saved = User.find(3)

        saved.age = 99
        saved:save()

        return {
            bound = User.bound(),
            status = rawget(_G, 'binding').status(),
            served = rawget(_G, 'tnt_model_find'),
            found = User.find(7):to_table(),
            adult = User.find(7):is_adult(),
            missing = User.find(404),
            twice = twice.kind,
            invalid = invalid.kind,
            page = ids(page),
            rest = ids(rest),
            counted = User.where('age', '>=', 40):count(),
            all = User.scan():count(),
            older = User.where('age', '>', 60):count(),
            between = #User.where('age', 'between', { 20, 30 }):all(),
            by_id = User.where('id', '=', 5):first():to_table(),
            saved = User.find(3).age,
            deleted = { User.delete(12), User.delete(12) },
            placed = placed,
            unknown = tostring(
                select(2, User._gateway().find({ space = 'secrets', primary = { 'id' }, bucket_of = 'id' }, { 1 }))
            ),
        }
    end, { BUCKETS })

    t.assert_equals(seen.bound, 'sharded')
    t.assert_equals(seen.status, { source = 'sharded', sharded = false, serves = false, spaces = { 'users' } })
    t.assert_equals(
        seen.served,
        nil,
        'роутер данных не держит и функций узла не публикует'
    )
    t.assert_equals(seen.found, { id = 7, name = 'Клиент 7', age = 45 })
    t.assert_equals(seen.adult, true)
    t.assert_equals(seen.missing, nil)
    t.assert_equals(seen.twice, 'conflict')
    t.assert_equals(seen.invalid, 'invalid')
    t.assert_equals(
        seen.page,
        { 6, 7, 8, 9, 10 },
        'страница слита с двух хранилищ в порядке возраста'
    )
    t.assert_equals(seen.rest, { 11, 12 })
    t.assert_equals(seen.counted, 8, 'семь по возрасту и запись 3 после save')
    t.assert_equals(seen.all, 12)
    t.assert_equals(seen.older, 3)
    t.assert_equals(seen.between, 2)
    t.assert_equals(seen.by_id, { id = 5, name = 'Клиент 5', age = 35 })
    t.assert_equals(seen.saved, 99)
    t.assert_equals(seen.deleted, { true, false })
    t.assert_equals(seen.unknown, 'спейс secrets этим узлом не обслуживается')

    -- На хранилищах: кортеж несёт бакет своего ключа, записи разошлись
    -- по обоим, а запись мимо роутера в чужой бакет не принимается.
    local storages = {}

    for _, name in ipairs({ 'storage-a', 'storage-b' }) do
        storages[name] = g.stand[name]:exec(function()
            ---@type any
            local User = rawget(_G, 'User')
            local rows = {}

            for _, tuple in box.space.users:pairs() do
                rows[tostring(tuple.id)] = tuple.bucket_id
            end

            local foreign = nil
            local own = nil

            for id = 1, 11 do
                local created, err = User.create({ id = id, name = 'мимо роутера', age = 1 })

                if created ~= nil then
                    created:delete()
                elseif err.kind == 'misrouted' then
                    foreign = (foreign or 0) + 1
                else
                    own = err.kind
                end
            end

            return {
                bound = User.bound(),
                status = rawget(_G, 'binding').status(),
                rows = rows,
                format = assert(box.space.users:format()[2]).name,
                bucket_index = box.space.users.index.bucket_id ~= nil,
                foreign = foreign,
                own = own,
                served = rawget(_G, 'tnt_model_select') ~= nil,
            }
        end)
    end

    local total = 0

    for name, storage in pairs(storages) do
        t.assert_equals(storage.bound, 'local', name)
        t.assert_equals(storage.status, { source = 'local', sharded = true, serves = true, spaces = { 'users' } })
        t.assert_equals(storage.format, 'bucket_id')
        t.assert_equals(storage.bucket_index, true)
        t.assert_equals(storage.served, true)
        t.assert_equals(storage.own, 'conflict', 'своя запись занята — бакет свой')
        t.assert_type(storage.foreign, 'number')

        for id, bucket in pairs(storage.rows) do
            t.assert_equals(bucket, seen.placed[id], ('бакет записи %d на %s'):format(id, name))
            total = total + 1
        end

        t.assert_not_equals(next(storage.rows), nil, name .. ' получил записи')
    end

    t.assert_equals(total, 11)
    t.assert_equals(storages['storage-a'].foreign + storages['storage-b'].foreign, 11)
end

--- Ключи записей цифрами вместе с родом: 7 и 7ULL для `==` равны.
---
--- Записи приходят с роутера таблицами, и ключ от 10^14 net.box
--- отдаёт cdata — так же, как роутеру его отдало хранилище.
---@param rows table[]
---@return string[]
local function keys_of(rows)
    local keys = {}

    for position, row in ipairs(rows) do
        keys[position] = tostring(row.id)
    end

    return keys
end

-- Ключи за точностью double через настоящий роутер: ключ идёт хранилищу
-- по net.box и возвращается ответом `tnt_model_*` — msgpack кодирует cdata
-- целым, и хранилище проверяет его заново той же моделью. Бакет считается
-- от значения ключа на роутере и на хранилище одинаково. Записи
-- стираются в конце: соседняя проверка считает свои записи во всём
-- кластере.
g.test_router_keeps_keys_beyond_double_precision = function()
    local seen = g.router:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        assert(User.create({ id = 9007199254740992ULL, name = 'Точный', age = 140 }))
        assert(User.create(require('json').decode('{"id": 9007199254740993, "name": "Из JSON", "age": 140}')))
        assert(User.create({ id = 18446744073709551615ULL, name = 'Последний', age = 140 }))

        local _, twice = User.create({ id = 18446744073709551615ULL, name = 'Снова', age = 140 })
        local found = User.find(18446744073709551615ULL)

        found.name = 'Последний снова'
        assert(found:save())

        local first = User.where('age', '=', 140):limit(2):all()

        return {
            found = User.find(18446744073709551615ULL):to_table(),
            neighbours = { User.find(9007199254740992ULL).name, User.find(9007199254740993ULL).name },
            twice = twice.kind,
            first = first,
            rest = User.where('age', '=', 140):limit(2):after(first[#first]):all(),
            from_exact = User.where('id', '>=', 9007199254740992ULL):all(),
            exact_max = User.where('id', '=', 18446744073709551615ULL):all(),
            counted = User.where('age', '=', 140):count(),
        }
    end)

    t.assert_equals(tostring(seen.found.id), '18446744073709551615ULL')
    t.assert_equals(seen.found.name, 'Последний снова')
    t.assert_equals(seen.neighbours, { 'Точный', 'Из JSON' })
    t.assert_equals(seen.twice, 'conflict')
    t.assert_equals(
        { keys_of(seen.first), keys_of(seen.rest) },
        { { '9007199254740992ULL', '9007199254740993ULL' }, { '18446744073709551615ULL' } },
        'страницы слиты с двух хранилищ по ключу точно'
    )
    t.assert_equals(
        keys_of(seen.from_exact),
        { '9007199254740992ULL', '9007199254740993ULL', '18446744073709551615ULL' }
    )
    t.assert_equals(keys_of(seen.exact_max), { '18446744073709551615ULL' })
    t.assert_equals(seen.counted, 3)

    -- На хранилищах кортеж несёт ключ целиком и бакет, посчитанный
    -- от того же значения, что и на роутере.
    local hash = require('vshard.hash')
    local stored = {}
    local placed = {}

    for _, name in ipairs({ 'storage-a', 'storage-b' }) do
        local held = g.stand[name]:exec(function()
            return box.space.users.index.primary:select({ 9007199254740992ULL }, { iterator = 'GE' })
        end)

        for _, tuple in ipairs(held) do
            stored[tostring(tuple[1])] = tuple[2]
            placed[tostring(tuple[1])] = hash.mpcrc32(tuple[1]) % BUCKETS + 1
        end
    end

    local held_keys = {}

    for key in pairs(stored) do
        table.insert(held_keys, key)
    end

    table.sort(held_keys)

    t.assert_equals(held_keys, { '18446744073709551615ULL', '9007199254740992ULL', '9007199254740993ULL' })
    t.assert_equals(stored, placed)
    t.assert_equals(stored['18446744073709551615ULL'], hash.mpcrc32(18446744073709551615ULL) % BUCKETS + 1)

    local left = g.router:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        for _, key in ipairs({ 9007199254740992ULL, 9007199254740993ULL, 18446744073709551615ULL }) do
            assert(User.delete(key))
        end

        return User.where('age', '=', 140):count()
    end)

    t.assert_equals(left, 0)
end
