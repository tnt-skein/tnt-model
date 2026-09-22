--- Узел «и роутер, и хранилище» — обе роли vshard на одном процессе:
--- шлюз `sharded` через свой же роутер vshard, функции узла с данными
--- опубликованы здесь же, в кортеже есть поле шардирования.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.single_sharded_live')

--- Конфигурация одного узла с обеими ролями vshard.
---@param port integer
---@return string
local function config_of(port)
    return ([[
credentials:
  users:
    client: { password: 'client-secret', roles: [super] }
    storage: { password: 'storage-secret', roles: [sharding] }
iproto:
  advertise:
    sharding: { login: storage }
sharding:
  bucket_count: 20
groups:
  single:
    sharding: { roles: [router, storage] }
    replicasets:
      single-001:
        instances:
          single-a: { iproto: { listen: [{ uri: '127.0.0.1:%d' }] } }
]]):format(port)
end

g.before_all(function()
    local port = helper.free_port()

    g.stand = helper.start_stand(config_of(port), { ['single-a'] = port }, { 'single-a' })
    g.node = g.stand['single-a']

    t.helpers.retrying({ timeout = 8 }, function()
        t.assert(g.node:exec(function()
            return (require('vshard').router.bootstrap({ if_not_bootstrapped = true }))
        end))
    end)
end)

g.after_all(function()
    helper.stop_stand(g.stand)
end)

g.test_one_node_routes_to_itself = function()
    local seen = g.node:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        for id = 1, 5 do
            assert(User.create({ id = id, name = 'Клиент ' .. id, age = 20 + id }))
        end

        local _, twice = User.create({ id = 1, name = 'Снова', age = 1 })
        local page = User.where('age', '>', 21):limit(2):all()
        local rest = User.where('age', '>', 21):limit(2):after(page[#page]):all()

        return {
            bound = User.bound(),
            status = rawget(_G, 'binding').status(),
            served = rawget(_G, 'tnt_model_put') ~= nil,
            found = User.find(3):to_table(),
            twice = twice.kind,
            page = { page[1].id, page[2].id },
            rest = { rest[1].id, rest[2].id },
            counted = User.scan():count(),
            tuple = assert(box.space.users:get(3)):totable(),
            bucket = require('vshard').router.bucket_id_mpcrc32(3),
            bucket_index = box.space.users.index.bucket_id ~= nil,
            deleted = User.delete(5),
            atomic = { pcall(rawget(_G, 'model').atomic, function() end) },
        }
    end)

    t.assert_equals(seen.bound, 'sharded')
    t.assert_equals(seen.status, { source = 'sharded', sharded = true, serves = true, spaces = { 'users' } })
    t.assert_equals(seen.served, true)
    t.assert_equals(seen.found, { id = 3, name = 'Клиент 3', age = 23 })
    t.assert_equals(seen.twice, 'conflict')
    t.assert_equals(seen.page, { 2, 3 })
    t.assert_equals(seen.rest, { 4, 5 })
    t.assert_equals(seen.counted, 5)
    t.assert_equals(seen.tuple, { 3, seen.bucket, 'Клиент 3', 23 })
    t.assert_equals(seen.bucket_index, true)
    t.assert_equals(seen.deleted, true)
    t.assert_equals(seen.atomic[1], false)
    t.assert_str_contains(seen.atomic[2], 'транзакция через роутер невозможна')
end
