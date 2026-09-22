--- Узел «и роутер, и хранилище» — обе роли vshard на одном процессе:
--- шлюз `sharded` через свой же роутер vshard, функции узла с данными
--- опубликованы здесь же, в кортеже есть поле шардирования.
---
--- Транзакция у такого узла есть — по его бакетам: внутри неё модель идёт
--- мимо роутера, к своему бакету под ссылкой vshard. Второй стенд — два
--- таких узла в двух репликасетах: чужой бакет в транзакции — исключение,
--- а тело транзакции над ним живёт в функции узла, которую роутер зовёт
--- `callrw`.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.single_sharded_live')

local pair = t.group('tnt.model.single_sharded_live.pair')

--- Конфигурация узлов с обеими ролями vshard, по узлу на репликасет.
---@param ports table<string, integer> Порт iproto по имени узла
---@param names string[] Узлы по порядку: single-a — в single-001, single-b — в single-002
---@return string
local function config_of(ports, names)
    local lines = {
        [[
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
    replicasets:]],
    }

    for position, name in ipairs(names) do
        table.insert(lines, ('      single-00%d:'):format(position))
        table.insert(lines, '        instances:')
        table.insert(
            lines,
            ("          %s: { iproto: { listen: [{ uri: '127.0.0.1:%d' }] } }"):format(name, ports[name])
        )
    end

    return table.concat(lines, '\n') .. '\n'
end

--- Поднимает узлы и размечает бакеты с первого.
---@param names string[]
---@return table<string, table> stand
local function started(names)
    local ports = {}

    for _, name in ipairs(names) do
        ports[name] = helper.free_port()
    end

    local stand = helper.start_stand(config_of(ports, names), ports, names)

    t.helpers.retrying({ timeout = 8 }, function()
        t.assert(stand[names[1]]:exec(function()
            return (require('vshard').router.bootstrap({ if_not_bootstrapped = true }))
        end))
    end)

    return stand
end

g.before_all(function()
    g.stand = started({ 'single-a' })
    g.node = g.stand['single-a']
end)

g.after_all(function()
    helper.stop_stand(g.stand)
end)

pair.before_all(function()
    pair.stand = started({ 'single-a', 'single-b' })
end)

pair.after_all(function()
    helper.stop_stand(pair.stand)
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
        }
    end)

    t.assert_equals(seen.bound, 'sharded')
    t.assert_equals(seen.status, { source = 'sharded', sharded = true, serves = true, spaces = { 'users', 'posts' } })
    t.assert_equals(seen.served, true)
    t.assert_equals(seen.found, { id = 3, name = 'Клиент 3', age = 23 })
    t.assert_equals(seen.twice, 'conflict')
    t.assert_equals(seen.page, { 2, 3 })
    t.assert_equals(seen.rest, { 4, 5 })
    t.assert_equals(seen.counted, 5)
    t.assert_equals(seen.tuple, { 3, seen.bucket, 'Клиент 3', 23 })
    t.assert_equals(seen.bucket_index, true)
    t.assert_equals(seen.deleted, true)
end

-- Запись в транзакции идёт мимо роутера, к своему бакету: откат `box.atomic`
-- отменяет и её. Через роутер она ушла бы по сети, легла бы своей
-- транзакцией и пережила бы откат.
g.test_a_transaction_covers_the_models_of_the_node = function()
    local seen = g.node:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        ---@type any
        local Post = rawget(_G, 'Post')
        local model = rawget(_G, 'model')
        -- Хранилище vshard в аннотациях описано не полностью: сведения
        -- о бакете там без аргумента.
        ---@type any
        local vshard = require('vshard')

        --- Ссылки на бакет ключа: чтения и записи; пустые — нулём.
        ---@param id integer
        ---@return integer[]
        local function refs_of(id)
            local bucket = vshard.router.bucket_id_mpcrc32(id)
            local info = vshard.storage.buckets_info(bucket)[bucket]

            return { info.ref_ro or 0, info.ref_rw or 0 }
        end

        local rolled = {
            pcall(box.atomic, function()
                assert(User.create({ id = 8101, name = 'Откат', age = 30 }))
                error('нарочный откат', 0)
            end),
        }

        -- Чтение, запись и счёт — одной транзакцией: чтение видит запись,
        -- легшую перед ним, ссылки держатся до конца транзакции.
        local inside = {}
        local aged = model.atomic(function()
            assert(User.create({ id = 8102, name = 'Вера', age = 30 }))

            local found = assert(User.find(8102))

            found.age = 31
            assert(found:save())
            assert(Post.create({ id = 8103, title = 'Черновик' }))
            inside.removed = Post.delete(8103)
            inside.counted = User.where('id', '=', 8102):count()
            inside.refs = refs_of(8102)

            return found.age
        end)

        local fanned = {
            pcall(model.atomic, function()
                return User.scan():count()
            end),
        }

        return {
            rolled = rolled,
            lost = User.find(8101) == nil and box.space.users:get(8101) == nil,
            released = { refs_of(8101), refs_of(8102), refs_of(8103) },
            aged = aged,
            inside = inside,
            stored = User.find(8102):to_table(),
            deleted = Post.where('id', '=', 8103):with_deleted():first().deleted_at ~= nil,
            fanned = fanned,
        }
    end)

    t.assert_equals(seen.rolled, { false, 'нарочный откат' })
    t.assert_equals(seen.lost, true, 'откат отменил запись модели')
    t.assert_equals(seen.aged, 31)
    t.assert_equals(seen.inside, { removed = true, counted = 1, refs = { 2, 2 } })
    t.assert_equals(seen.stored, { id = 8102, name = 'Вера', age = 31 })
    t.assert_equals(seen.deleted, true, 'мягкое удаление в транзакции легло')
    t.assert_equals(
        seen.released,
        { { 0, 0 }, { 0, 0 }, { 0, 0 } },
        'ссылки сняты и после отката, и после фиксации'
    )
    t.assert_equals(seen.fanned, {
        false,
        'модель users: выборка веером в транзакции невозможна — она шла бы через роутер по сети '
            .. 'мимо транзакции; в транзакции — только выборка в один бакет, по первичному ключу на равенство',
    })
end

-- Чужой бакет в транзакции — исключение, и откат уносит всё тело, в том
-- числе запись в свой бакет. Тело над чужим бакетом живёт в функции узла,
-- которому бакет принадлежит: роутер зовёт её `callrw`, и там модель идёт
-- к своему бакету на месте.
pair.test_a_foreign_bucket_stops_the_transaction_and_its_node_carries_it = function()
    helper.publish_aged(pair.stand, { 'single-a', 'single-b' })

    local seen = pair.stand['single-a']:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local model = rawget(_G, 'model')
        local vshard = require('vshard')
        local ours, theirs

        -- Первый ключ, чей бакет лежит здесь, и первый — у соседа.
        for id = 9001, 9100 do
            if box.space._bucket:get(vshard.router.bucket_id_mpcrc32(id)) ~= nil then
                ours = ours or id
            else
                theirs = theirs or id
            end
        end

        local own = assert(ours, 'среди ключей нет своего бакета')
        local foreign = assert(theirs, 'среди ключей нет бакета соседа')

        local refused = {
            pcall(model.atomic, function()
                assert(User.create({ id = own, name = 'Своя', age = 30 }))
                assert(User.create({ id = foreign, name = 'Чужая', age = 30 }))
            end),
        }
        local lost = User.find(own) == nil and User.find(foreign) == nil

        assert(User.create({ id = foreign, name = 'Чужая', age = 30 }))

        local bucket = vshard.router.bucket_id_mpcrc32(foreign)
        local answer = vshard.router.callrw(bucket, 'aged', { foreign, 44 })

        return {
            refused = refused,
            lost = lost,
            answer = answer,
            stored = User.find(foreign).age,
            bucket = bucket,
            foreign = foreign,
        }
    end)

    t.assert_equals(seen.refused, {
        false,
        ('модель users: бакет %d не на этом узле — в транзакции узел «и роутер, и хранилище» '):format(
            seen.bucket
        )
            .. 'читает и пишет только свои бакеты; транзакция над чужим живёт в функции его хранилища, '
            .. 'которую роутер зовёт callrw',
    })
    t.assert_equals(seen.lost, true, 'откат унёс и запись в свой бакет')
    t.assert_equals(seen.answer, { age = 44 })
    t.assert_equals(seen.stored, 44)
    t.assert_equals(
        pair.stand['single-b']:exec(function(id)
            return assert(box.space.users:get(id)).age
        end, { seen.foreign }),
        44,
        'тело транзакции прошло на узле бакета'
    )
end
