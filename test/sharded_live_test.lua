--- Шардированный кластер: роутер и два хранилища. Через роутер — шлюз
--- `sharded`: запись ложится в бакет своего ключа, чтение и страницы
--- по индексу собираются с обоих хранилищ; на хранилище — шлюз `local`
--- с полем шардирования, чужой бакет не принимается, чужой спейс
--- по имени недоступен. Веер переживает перечитывание конфигурации
--- роутера, во время переноса бакетов отвечает целиком либо отказывает,
--- и отказ называет молчащее хранилище.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.sharded_live')

--- Число бакетов: маленькое, чтобы оба хранилища получили записи.
local BUCKETS = 30

--- Конфигурация кластера: два хранилища по одному узлу и роутер.
---
--- Балансировщик выключен: проверка переноса сама отправляет бакеты
--- и возвращает их на место, а балансировщик, заметив перекос, повёл бы
--- их своим путём посреди соседних проверок.
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
  rebalancer_mode: 'off'
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
    t.assert_equals(seen.status, { source = 'sharded', sharded = false, serves = false, spaces = { 'users', 'posts' } })
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
        t.assert_equals(
            storage.status,
            { source = 'local', sharded = true, serves = true, spaces = { 'users', 'posts' } }
        )
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

-- Страница по номеру через роутер: каждое хранилище отдаёт первые
-- offset + limit своих записей, роутер сливает их и пропускает offset.
-- Страницы подряд — тот же порядок, что у одной выборки на всё. Самая
-- длинная страница со смещением идёт хранилищам пределом 2^32 − 1, а не
-- суммой: сумму 2^32 + 1 `box` обрезал бы до одной записи с хранилища,
-- и страница вышла бы пустой. Записи стираются в конце: соседние
-- проверки считают свои во всём кластере.
g.test_router_pages_by_number_across_storages = function()
    local seen = g.router:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')

        for id = 1001, 1012 do
            assert(User.create({ id = id, name = 'Страница ' .. id, age = 120 + id % 5 }))
        end

        local pages = {}

        for number = 1, 4 do
            pages[number] = User.where('age', '>=', 120):limit(5):offset((number - 1) * 5):all()
        end

        local whole = User.where('age', '>=', 120):limit(12):all()
        local longest = User.where('age', '>=', 120):limit(model.OFFSET):offset(2):all()

        for id = 1001, 1012 do
            User.delete(id)
        end

        return { pages = pages, whole = whole, longest = longest }
    end)

    local whole = helper.ids(seen.whole)
    local joined = {}

    for number = 1, 3 do
        for _, id in ipairs(helper.ids(seen.pages[number])) do
            table.insert(joined, id)
        end
    end

    t.assert_equals(seen.pages[4], {}, 'страница за концом пуста')
    t.assert_equals(joined, whole, 'страницы подряд — одна выборка')
    t.assert_equals(
        whole,
        { 1005, 1010, 1001, 1006, 1011, 1002, 1007, 1012, 1003, 1008, 1004, 1009 },
        'по возрасту, равные — по id: записи с обоих хранилищ'
    )
    t.assert_equals(
        helper.ids(seen.longest),
        { 1001, 1006, 1011, 1002, 1007, 1012, 1003, 1008, 1004, 1009 },
        'самая длинная страница без двух первых'
    )
end

-- Число Lua за пределом рода через роутер — отказ `invalid` до похода
-- на хранилище, а не `unavailable` «хранилище не ответило»: иначе ошибку
-- клиента читали бы бедой хранилища, и он получал бы 503 вместо 422.
g.test_router_refuses_numbers_beyond_the_kind_without_a_storage = function()
    local seen = g.router:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        --- Отказ вызова: род и поля.
        local function refused(_, err)
            return { err.kind, err.fields }
        end

        return {
            found = refused(User.find(2 ^ 64)),
            created = refused(User.create(require('json').decode('{"id": 1e20, "name": "Мария", "age": 46}'))),
            ranged = refused(User.where('id', '>=', 1e20):all()),
            counted = refused(User.where('age', '>=', 18):after({ age = 20, id = 2 ^ 64 }):count()),
        }
    end)

    local beyond = 'должно быть целым числом от 0 до 18446744073709551615, а не %s'

    t.assert_equals(seen, {
        found = { 'invalid', { id = beyond:format('1.844674407371e+19') } },
        created = { 'invalid', { id = beyond:format('1e+20') } },
        ranged = { 'invalid', { id = beyond:format('1e+20') } },
        counted = { 'invalid', { id = beyond:format('1.844674407371e+19') } },
    })
end

-- Граница выборки за объявлением через роутер: роутер проверяет её
-- родом поля, хранилище — тем же правилом заново, и страница сливается
-- с обоих хранилищ. Искомое значение за объявлением — отказ `invalid`
-- без похода на хранилище. Записи стираются в конце: соседние проверки
-- считают свои во всём кластере.
g.test_router_and_storages_check_query_values_by_one_rule = function()
    local seen = g.router:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        for id = 201, 206 do
            assert(User.create({ id = id, name = 'Граница ' .. id, age = 145 + id % 3 }))
        end

        local _, equal = User.where('age', '=', 200):all()
        local answer = {
            below = User.where('age', '<', 200):limit(4):all(),
            between = User.where('age', 'between', { 145, 200 }):count(),
            after = User.where('age', '>=', 145):after({ age = 146, id = 204 }):all(),
            equal = { equal.kind, equal.fields },
        }

        for id = 201, 206 do
            assert(User.delete(id))
        end

        return answer
    end)

    -- Возраст по id: 201 — 145, 202 — 146, 203 — 147, 204 — 145, 205 — 146,
    -- 206 — 147; по убыванию равные идут по убыванию ключа.
    t.assert_equals(helper.ids(seen.below), { 206, 203, 205, 202 })
    t.assert_equals(seen.between, 6)
    t.assert_equals(helper.ids(seen.after), { 205, 203, 206 })
    t.assert_equals(
        seen.equal,
        { 'invalid', { age = 'должно быть целым числом от 0 до 150, а не 200' } }
    )
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

-- Отметки, мягкое удаление и область через роутер: отметку ставит
-- хранилище, способ удаления и условие выборки едут к нему по проводу,
-- а страница с условием сливается с обоих хранилищ. Записи стираются
-- в конце: соседние проверки считают свои во всём кластере.
g.test_router_carries_stamps_soft_deletion_and_scopes = function()
    local seen = g.router:exec(function()
        ---@type any
        local Post = rawget(_G, 'Post')
        local clock = require('clock')
        local ids = function(rows)
            local listed = {}

            for _, row in ipairs(rows) do
                table.insert(listed, row.id)
            end

            return listed
        end

        local before = clock.realtime()

        for id = 1, 12 do
            assert(Post.create({ id = id, title = 'Запись ' .. id, published = id % 3 == 0 }))
        end

        local created = Post.find(3)
        local deleted = { Post.delete(6), Post.delete(6), Post.find(6) }
        local trashed = Post.where('id', '=', 6):only_deleted():first()
        local observed = {
            before = before,
            created = created:to_table(),
            deleted = deleted,
            trashed = trashed:to_table(),
            published = ids(Post.scan():scope('published'):all()),
            published_count = Post.scan():scope('published'):count(),
            second_page = ids(Post.scan():scope('published'):limit(2):offset(1):all()),
            with_deleted = ids(Post.scan():scope('published'):with_deleted():all()),
            only_deleted = ids(Post.scan():only_deleted():all()),
        }

        observed.restored = trashed:restore()
        observed.revived = Post.find(6) ~= nil
        observed.forced = { Post.force_delete(6), Post.find(6), Post.scan():with_deleted():count() }

        for id = 1, 12 do
            Post.force_delete(id)
        end

        observed.left = Post.scan():with_deleted():count()

        return observed
    end)

    t.assert_ge(seen.created.created_at, seen.before, 'отметку поставило хранилище')
    t.assert_equals(seen.created.updated_at, seen.created.created_at)
    t.assert_equals(seen.deleted, { true, false })
    t.assert_ge(seen.trashed.deleted_at, seen.created.created_at)
    t.assert_equals(
        seen.published,
        { 3, 9, 12 },
        'шестая удалена, страница слита с двух хранилищ'
    )
    t.assert_equals(seen.published_count, 3)
    t.assert_equals(seen.second_page, { 9, 12 })
    t.assert_equals(seen.with_deleted, { 3, 6, 9, 12 })
    t.assert_equals(seen.only_deleted, { 6 })
    t.assert_equals(seen.restored, true)
    t.assert_equals(seen.revived, true)
    t.assert_equals(seen.forced, { true, nil, 11 })
    t.assert_equals(seen.left, 0)
end

-- Запись роутера ушла бы по сети и легла на хранилище своей транзакцией:
-- откат транзакции роутера её не отменил бы. Теперь это исключение,
-- и откат чистый — записи нет нигде.
g.test_router_refuses_writes_inside_a_transaction = function()
    local seen = g.router:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local rolled = {
            pcall(box.atomic, function()
                assert(User.create({ id = 8101, name = 'Откат', age = 30 }))
                error('нарочный откат', 0)
            end),
        }

        return {
            rolled = rolled,
            lost = User.find(8101) == nil,
            atomic = { pcall(rawget(_G, 'model').atomic, function() end) },
        }
    end)

    t.assert_equals(seen.rolled, {
        false,
        'модель users: запись через роутер в транзакции невозможна — она ушла бы по сети и легла '
            .. 'мимо транзакции; box.atomic живёт в функции хранилища, которую роутер зовёт callrw',
    })
    t.assert_equals(seen.lost, true)
    t.assert_equals(seen.atomic[1], false)
    t.assert_str_contains(seen.atomic[2], 'транзакция через роутер невозможна')

    for _, name in ipairs({ 'storage-a', 'storage-b' }) do
        t.assert_equals(
            g.stand[name]:exec(function()
                return box.space.users:get(8101) == nil
            end),
            true,
            name
        )
    end
end

-- Тело транзакции живёт в функции хранилища: роутер зовёт её `callrw`
-- в бакет ключа, и там `model.atomic` — это `box.atomic`.
g.test_router_carries_a_transaction_to_the_storage_function = function()
    helper.publish_aged(g.stand, { 'storage-a', 'storage-b' })

    local seen = g.router:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local vshard = require('vshard')

        assert(User.create({ id = 8201, name = 'Вера', age = 30 }))

        return {
            answer = vshard.router.callrw(vshard.router.bucket_id_mpcrc32(8201), 'aged', { 8201, 44 }),
            stored = User.find(8201).age,
        }
    end)

    t.assert_equals(seen, { answer = { age = 44 }, stored = 44 })
end

-- Страница по необязательной почте через роутер: записи без почты стоят
-- в индексе на месте NULL, последними по убыванию, и страница,
-- кончившаяся такой записью, продолжается от неё. Курсор с пустой почтой
-- едет хранилищам по проводу, каждое продолжает свою страницу от этого
-- места, и роутер сливает их в порядке индекса. Страницы по 1, 3 и 7
-- проходят каждую запись ровно по разу.
g.test_router_pages_by_an_optional_field_past_empty_values = function()
    local base = 9000

    helper.assert_pages_by_email(helper.pages_by_email(g.router, base), base)
end

-- Курсор от другой выборки через роутер: каждое хранилище сверяет его
-- с ключом выборки само, роутер сливает страницы. Курсор раньше начала
-- выборки отдаёт её целиком, как шлюз `sql`, — и выборке с условием
-- мягкого удаления, и выборке в один бакет; курсор за концом выборки
-- на равенство — пустую страницу. Прежде хранилище бросало «Iterator
-- position is invalid», и роутер отвечал `unavailable`, хотя ошибся
-- клиент. Выборки целиком сверяются с собой без курсора: в кластере
-- лежат и записи соседних проверок. Свои записи стираются в конце.
g.test_router_pages_after_a_cursor_from_another_selection = function()
    local seen = g.router:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        ---@type any
        local Post = rawget(_G, 'Post')

        for id = 9601, 9606 do
            local email = id % 2 == 0 and 'k@x' or nil

            assert(User.create({ id = id, name = 'Курсор ' .. id, age = 137, email = email }))
            assert(Post.create({ id = id, title = 'Курсор ' .. id }))
        end

        --- Ключи страницы по порядку либо род отказа.
        local function ids(query)
            local rows, err = query:all()

            if rows == nil then
                return err.kind
            end

            local keys = {}

            for position, row in ipairs(rows) do
                keys[position] = row.id
            end

            return keys
        end

        local answer = {
            from = ids(User.where('age', '>=', 137)),
            from_before = ids(User.where('age', '>=', 137):after({ age = 5, id = 1 })),
            above = ids(User.where('age', '>', 137)),
            above_key = ids(User.where('age', '>', 137):after({ age = 137, id = 9601 })),
            equal_before = ids(User.where('age', '=', 137):after({ age = 136, id = 9999 })),
            equal_after = ids(User.where('age', '=', 137):after({ age = 138, id = 1 })),
            mails = ids(User.where('email', '>=', 'a')),
            mails_before = ids(User.where('email', '>=', 'a'):after({ id = 4 })),
            posts_before = ids(Post.where('id', '>=', 9601):after({ id = 5 })),
            single_before = ids(User.where('id', '=', 9603):after({ id = 9601 })),
            single_after = ids(User.where('id', '=', 9603):after({ id = 9605 })),
        }

        for id = 9601, 9606 do
            assert(User.delete(id))
            assert(Post.force_delete(id))
        end

        return answer
    end)

    --- Свои ключи среди всех, по порядку.
    local function own(keys)
        local found = {}

        for _, key in ipairs(keys) do
            if key > 9600 and key < 9607 then
                table.insert(found, key)
            end
        end

        return found
    end

    local mine = { 9601, 9602, 9603, 9604, 9605, 9606 }

    t.assert_equals(own(seen.from), mine)
    t.assert_equals(seen.from_before, seen.from, 'курсор раньше начала — вся выборка')
    t.assert_equals(own(seen.above), {})
    t.assert_equals(seen.above_key, seen.above, 'записей возраста 137 в выборке > 137 нет')
    t.assert_equals(seen.equal_before, mine)
    t.assert_equals(
        seen.equal_after,
        {},
        'курсор за концом равенства — пустая страница'
    )
    t.assert_equals(own(seen.mails), { 9602, 9604, 9606 })
    t.assert_equals(
        seen.mails_before,
        seen.mails,
        'курсор без почты раньше начала — вся выборка'
    )
    t.assert_equals(seen.posts_before, mine, 'и с условием мягкого удаления')
    t.assert_equals(seen.single_before, { 9603 }, 'и в один бакет')
    t.assert_equals(seen.single_after, {})
end

--- Логин уникален без ключа шардирования: `box` держит его только внутри
--- репликасета, и тот же логин у ключей из разных репликасетов лёг бы
--- дважды.
local ACCOUNTS = {
    space = 'accounts',
    fields = {
        { 'id', 'unsigned', primary = true },
        { name = 'bucket_id', type = 'unsigned', bucket_of = 'id' },
        { 'login', 'string' },
    },
    indexes = { login = { parts = { 'login' }, unique = true } },
}

--- Место уникально в пределах зала: ключ шардирования `hall` среди полей
--- индекса, пусть и не первым, — все места зала в одном бакете.
local SEATS = {
    space = 'seats',
    fields = {
        { 'hall', 'unsigned', primary = true },
        { name = 'bucket_id', type = 'unsigned', bucket_of = 'hall' },
        { 'id', 'unsigned', primary = true },
        { 'place', 'string' },
    },
    indexes = { place = { parts = { 'place', 'hall' }, unique = true } },
}

-- Уникальный индекс без ключа шардирования — исключение `model.bind`
-- и на роутере, и на каждом хранилище: иначе тот же логин у ключей
-- из разных репликасетов лёг бы дважды молча. Узел остаётся при прежней
-- привязке.
g.test_bind_refuses_a_unique_index_without_the_shard_key = function()
    for _, name in ipairs({ 'router-a', 'storage-a', 'storage-b' }) do
        local seen = g.stand[name]:exec(function(spec)
            ---@type any
            local model = rawget(_G, 'model')
            local Account = model.define(spec)

            return {
                refused = { pcall(model.bind, { Account }, model.settings(nil)) },
                spaces = rawget(_G, 'binding').status().spaces,
                bound = Account.bound(),
            }
        end, { ACCOUNTS })

        t.assert_equals(seen, {
            refused = {
                false,
                'модель accounts: уникальность индекса login в шардированном кластере не гарантирована — '
                    .. 'среди его полей нет ключа шардирования id',
            },
            spaces = { 'users', 'posts' },
        }, name)
    end
end

--- Хранилища стенда.
local STORAGES = { 'storage-a', 'storage-b' }

--- Своя модель проверки на всех узлах стенда: привязка перечитыванием
--- со списком, проверка на роутере, отпускание перечитыванием без списка.
---
--- Спейс на хранилищах стирается, и соседние проверки видят стенд
--- прежним, даже если проверка упала. До того на каждом хранилище
--- исполняется `survey` со спейсом — чем он лёг; без него — сколько
--- в спейсе записей.
---@param spec table Объявление модели: без функций, оно едет узлам по проводу
---@param global string Имя глобала, под которым модель видна проверке
---@param run function Проверка на роутере; её ответ — первое значение
---@param survey function|nil Осмотр спейса на хранилище; пусто — счёт записей
---@return any seen Ответ проверки
---@return table<string, any> held Ответ осмотра по хранилищам
local function with_model(spec, global, run, survey)
    --- Привязка модели на узле; на хранилище — ещё и её спейс.
    local function bind(name)
        g.stand[name]:exec(function(declared, as)
            ---@type any
            local model = rawget(_G, 'model')
            local defined = model.define(declared)

            if rawget(_G, 'binding').topology.serves then
                box.atomic(defined.migration(), box)
            end

            rawset(_G, as, defined)
            rawget(_G, 'rebind')({ defined })
        end, { spec, global })
    end

    local ok, seen = pcall(function()
        for _, name in ipairs(STORAGES) do
            bind(name)
        end

        bind('router-a')

        return g.router:exec(run)
    end)

    local held = {}

    for _, name in ipairs(STORAGES) do
        held[name] = g.stand[name]:exec(survey or function(space)
            return box.space[space] ~= nil and box.space[space]:count() or 0
        end, { spec.space })

        g.stand[name]:exec(function(space, as)
            rawget(_G, 'rebind')()
            rawset(_G, as, nil)

            if box.space[space] ~= nil then
                box.space[space]:drop()
            end
        end, { spec.space, global })
    end

    g.router:exec(function(as)
        rawget(_G, 'rebind')()
        rawset(_G, as, nil)
    end, { global })

    t.assert(ok, seen)

    return seen, held
end

-- Уникальный индекс с ключом шардирования держит уникальность по кластеру:
-- место занято в своём зале, где бы ни лежал зал, а то же место в других
-- залах — разные записи на обоих хранилищах. Отказ `conflict` называет
-- занятый индекс и у `create`, и у `save`, а занятый ключ — ключом: текст
-- приходит с хранилища через роутер.
g.test_unique_index_with_the_shard_key_names_itself_in_a_conflict = function()
    local seen, held = with_model(SEATS, 'Seat', function()
        ---@type any
        local Seat = rawget(_G, 'Seat')

        --- Отказ пары: пусто ли первое значение, род и текст.
        local function refused(...)
            local created, err = ...

            return { created == nil, err.kind, tostring(err) }
        end

        for hall = 1, 6 do
            assert(Seat.create({ hall = hall, id = 1, place = 'A1' }))
        end

        local moved = assert(Seat.create({ hall = 4, id = 2, place = 'B2' }))

        moved.place = 'A1'

        return {
            taken = refused(Seat.create({ hall = 3, id = 2, place = 'A1' })),
            twice = refused(Seat.create({ hall = 3, id = 1, place = 'B7' })),
            saved = refused(moved:save()),
            same_place = Seat.where('place', '=', 'A1'):count(),
            kept = Seat.find({ 4, 2 }).place,
        }
    end)

    t.assert_equals(seen, {
        taken = { true, 'conflict', 'запись seats с таким place уже есть' },
        twice = { true, 'conflict', 'запись seats с таким ключом уже есть' },
        saved = { true, 'conflict', 'запись seats с таким place уже есть' },
        same_place = 6,
        kept = 'B2',
    })
    t.assert_equals(held['storage-a'] + held['storage-b'], 7)
    t.assert_gt(held['storage-a'], 0, 'залы легли на оба хранилища')
    t.assert_gt(held['storage-b'], 0, 'залы легли на оба хранилища')
end

--- Устройства: ключ и ключ шардирования — опознаватель, владелец —
--- опознаватель во вторичном индексе.
local DEVICES = {
    space = 'devices',
    fields = {
        { 'id', 'uuid', primary = true },
        { name = 'bucket_id', type = 'unsigned', bucket_of = 'id' },
        { 'owner', 'uuid' },
        { 'name', 'string' },
    },
    indexes = { owner = { parts = { 'owner' }, unique = false } },
}

-- Опознаватель через роутер — строкой в любом регистре либо cdata:
-- `create`, `find`, `where` в один бакет и веером, `after`, `between`
-- и `delete`. По проводу, в слиянии страниц и у записи он строка,
-- на хранилище в `box` — cdata. Бакет роутер и хранилище считают от строки
-- одинаково: иначе запись получала бы отказ «бакет не на этом узле».
-- Страницы веером проходят каждую запись ровно по разу — слияние строк
-- идёт в том же порядке, что индекс опознавателей на хранилищах.
g.test_router_carries_uuid_fields_as_strings_or_cdata = function()
    local seen, held = with_model(DEVICES, 'Device', function()
        local uuid = require('uuid')
        ---@type any
        local Device = rawget(_G, 'Device')
        local owner = uuid.new()
        local base = uuid.new():str()
        local ids, kinds, owned = {}, {}, {}

        -- Шестнадцать записей: чётные — cdata, нечётные — строкой в верхнем
        -- регистре; двенадцать первых — одного владельца. Голова, общая
        -- с `base`, от записи к записи длиннее на два знака: слияние строк
        -- сверяется с индексом хранилищ по каждому полю опознавателя,
        -- а не только по первому.
        for position = 1, 16 do
            local cut = (position - 1) * 2
            local text = base:sub(1, cut) .. uuid.new():str():sub(cut + 1)
            local key = position % 2 == 0 and uuid.fromstr(text) or text:upper()
            local created = assert(Device.create({
                id = key,
                owner = position <= 12 and owner or uuid.new(),
                name = 'Устройство ' .. position,
            }))

            table.insert(ids, created.id)
            kinds[type(created.id) .. ' ' .. type(created.owner)] = true

            if position <= 12 then
                table.insert(owned, created.id)
            end
        end

        --- Все страницы выборки по пять записей, ключами подряд.
        local function paged(start)
            local listed = {}
            local page = start():limit(5):all()

            while #page > 0 do
                for _, row in ipairs(page) do
                    table.insert(listed, row.id)
                end

                page = start():limit(5):after(page[#page]):all()
            end

            return listed
        end

        local sorted = table.copy(ids)

        table.sort(sorted)
        table.sort(owned)

        local found = 0

        for _, id in ipairs(ids) do
            local by_string = Device.find(id:upper())
            local by_cdata = Device.find(uuid.fromstr(id))

            if by_string.id == id and by_cdata.id == id then
                found = found + 1
            end
        end

        local range = { uuid.fromstr(sorted[3]), sorted[10]:upper() }
        local between = {}

        for _, row in ipairs(Device.where('id', 'between', range):limit(20):all()) do
            table.insert(between, row.id)
        end

        return {
            kinds = kinds,
            found = found,
            single = #Device.where('id', '=', uuid.fromstr(ids[1])):all(),
            owned = {
                paged(function()
                    return Device.where('owner', '=', owner)
                end),
                owned,
            },
            scanned = { paged(Device.scan), sorted },
            between = { between, { unpack(sorted, 3, 10) } },
            between_count = Device.where('id', 'between', range):count(),
            removed = {
                Device.delete(uuid.fromstr(sorted[1])),
                Device.delete(sorted[2]:upper()),
                Device.delete(sorted[2]),
                Device.find(sorted[1]) == nil,
            },
            left = Device.scan():count(),
        }
    end, function(space)
        local placed = {}

        for _, stored in box.space[space]:pairs() do
            placed[tostring(stored.id)] = stored.bucket_id
        end

        return placed
    end)

    t.assert_equals(seen.kinds, { ['string string'] = true })
    t.assert_equals(seen.found, 16)
    t.assert_equals(seen.single, 1)
    t.assert_equals(seen.owned[1], seen.owned[2])
    t.assert_equals(#seen.owned[1], 12)
    t.assert_equals(seen.scanned[1], seen.scanned[2])
    t.assert_equals(seen.between[1], seen.between[2])
    t.assert_equals(seen.between_count, 8)
    t.assert_equals(seen.removed, { true, true, false, true })
    t.assert_equals(seen.left, 14)

    local hash = require('vshard.hash')
    local counts = {}

    for name, placed in pairs(held) do
        counts[name] = 0

        for id, bucket_id in pairs(placed) do
            t.assert_equals(
                bucket_id,
                hash.mpcrc32(id) % BUCKETS + 1,
                'бакет от строки опознавателя'
            )
            counts[name] = counts[name] + 1
        end
    end

    t.assert_equals(counts['storage-a'] + counts['storage-b'], 14)
    t.assert_gt(counts['storage-a'], 0, 'устройства легли на оба хранилища')
    t.assert_gt(counts['storage-b'], 0, 'устройства легли на оба хранилища')
end

--- Перепривязывает модели роутера со сроком обращения `timeout`: новая
--- привязка рядом, модели переключены на неё, прежняя отпущена — порядок
--- приложения при перечитывании с другим разделом. Пусто — срок
--- по умолчанию, как у стенда.
---
--- Проверки молчания и переноса ждут срок веера целиком, и полсекунды
--- вместо пяти держат их короткими.
---@param timeout number|nil
local function router_timeout(timeout)
    g.router:exec(function(seconds)
        ---@type any
        local model = rawget(_G, 'model')
        local previous = rawget(_G, 'binding')
        local fresh = model.bind({ rawget(_G, 'User'), rawget(_G, 'Post') }, model.settings({ timeout = seconds }))

        fresh.attach()
        rawset(_G, 'binding', fresh)
        previous.close()
    end, { timeout })
end

--- Кладёт через роутер записи с ключами `first .. first + count - 1`
--- и возрастом `age`: веер проверки считает только их.
---@param first integer
---@param count integer
---@param age integer
local function placed(first, count, age)
    g.router:exec(function(from, total, years)
        ---@type any
        local User = rawget(_G, 'User')

        for id = from, from + total - 1 do
            assert(User.create({ id = id, name = 'Веер ' .. id, age = years }))
        end
    end, { first, count, age })
end

--- Стирает через роутер записи с ключами `first .. first + count - 1`:
--- соседние проверки считают свои записи во всём кластере.
---@param first integer
---@param count integer
local function forgotten(first, count)
    g.router:exec(function(from, total)
        ---@type any
        local User = rawget(_G, 'User')

        for id = from, from + total - 1 do
            assert(User.delete(id))
        end
    end, { first, count })
end

--- Запускает на роутере файберы веера: нечётные считают записи возраста
--- `age`, чётные читают их страницей. Ответы копятся в глобале `fanning`
--- до `rawget(_G, 'fanning').stop()`: полный ответ — `whole`, отказ —
--- в `refusals` родом и текстом, неполный — `partial`.
---@param age integer
---@param expected integer Сколько записей этого возраста в кластере
---@param workers integer
local function fan_out(age, expected, workers)
    g.router:exec(function(years, total, count)
        local fiber = require('fiber')
        ---@type any
        local User = rawget(_G, 'User')
        local seen = { whole = 0, partial = 0, refusals = {} }
        local going = true
        local finished = 0

        --- Сколько записей возраста отдал веер: нечётный файбер считает,
        --- чётный читает страницу.
        ---@param worker integer
        ---@return integer|nil answer
        ---@return any err
        local function asked(worker)
            local query = User.where('age', '=', years)

            if worker % 2 == 1 then
                return query:count()
            end

            local page, err = query:limit(1000):all()

            return page and #page, err
        end

        for worker = 1, count do
            fiber.create(function()
                while going do
                    local answer, err = asked(worker)

                    if answer == nil then
                        table.insert(seen.refusals, { err.kind, tostring(err) })
                    elseif answer == total then
                        seen.whole = seen.whole + 1
                    else
                        seen.partial = seen.partial + 1
                    end
                end

                finished = finished + 1
            end)
        end

        rawset(_G, 'fanning', {
            stop = function()
                going = false

                while finished < count do
                    fiber.sleep(0.01)
                end

                return seen
            end,
        })
    end, { age, expected, workers })
end

--- Останавливает файберы веера и отдаёт, что они видели.
---@return table seen
local function fan_out_stopped()
    return g.router:exec(function()
        return rawget(_G, 'fanning').stop()
    end)
end

-- Перечитывание конфигурации роутера заводит новые объекты репликасетов
-- и помечает прежние устаревшими. Веер держит прежние от ссылок до ответов,
-- и перечитывание посреди обрывает его `OBJECT_IS_OUTDATED`, хотя хранилища
-- живы. Чтобы перечитывание наверняка застало веер в пути, storage-b стоит
-- на паузе, пока роутер перечитывает конфигурацию: оба веера ждут от него
-- ответа на ссылку. Проснувшись, он отвечает, и голый `map_callrw` получает
-- `OBJECT_IS_OUTDATED`, а веер модели повторяется по свежим объектам
-- и отдаёт полный счёт.
g.test_a_fan_out_caught_by_a_router_reload_is_repeated = function()
    local storage = g.stand['storage-b']

    placed(3001, 12, 131)
    storage.process:kill('STOP')

    local started, err = pcall(g.router.exec, g.router, function()
        local fiber = require('fiber')
        ---@type any
        local vshard = require('vshard')
        ---@type any
        local config = require('config')
        ---@type any
        local User = rawget(_G, 'User')
        local caught = {}
        local query = { index = 'age', iterator = 'EQ', key = { 131 } }

        rawset(_G, 'caught', caught)

        fiber.create(function()
            local map, refusal = vshard.router.map_callrw('tnt_model_count', { 'users', query }, { timeout = 5 })

            caught.raw = map == nil and refusal.name or 'ответил'
        end)

        fiber.create(function()
            local counted, refusal = User.where('age', '=', 131):count()

            caught.model = { counted, refusal ~= nil and tostring(refusal) or nil }
        end)

        config:reload()
    end)

    storage.process:kill('CONT')

    local caught = t.helpers.retrying({ timeout = 10, delay = 0.05 }, function()
        local seen = g.router:exec(function()
            return rawget(_G, 'caught')
        end)

        t.assert_not_equals(seen.raw, nil)
        t.assert_not_equals(seen.model, nil)

        return seen
    end)

    forgotten(3001, 12)

    t.assert(started, err)
    t.assert_equals(
        caught.raw,
        'OBJECT_IS_OUTDATED',
        'перечитывание застало голый веер vshard'
    )
    t.assert_equals(caught.model, { 12 }, 'веер модели повторился и сосчитал всё')
end

-- Под нагрузкой — четыре файбера веера считают и читают страницы, роутер
-- двадцать раз перечитывает конфигурацию — ни одного отказа веера, каждый
-- счёт и каждая страница полны.
g.test_router_fans_out_through_reloads_of_its_configuration = function()
    placed(3001, 12, 131)

    local ok, seen = pcall(function()
        fan_out(131, 12, 4)

        g.router:exec(function()
            local fiber = require('fiber')
            ---@type any
            local config = require('config')

            for _ = 1, 20 do
                fiber.sleep(0.01)
                config:reload()
            end
        end)

        return fan_out_stopped()
    end)

    forgotten(3001, 12)

    t.assert(ok, seen)
    ---@cast seen any
    t.assert_equals(seen.refusals, {})
    t.assert_equals(seen.partial, 0)
    t.assert_gt(seen.whole, 0)
end

-- Веер берёт на каждом хранилище ссылку, которая держит бакеты на месте
-- до ответа, и во время переноса бакетов ждёт её. Ответ веера при этом
-- верен целиком либо это отказ `unavailable`, названный репликасетом:
-- неполного счёта и неполной страницы не бывает. Уезжает бакет с записью
-- проверки и возвращается на место.
g.test_a_fan_out_during_a_bucket_transfer_is_whole_or_names_the_storage = function()
    router_timeout(0.5)
    placed(3101, 12, 132)

    --- Отправляет бакет с хранилища в репликасет: «отправлен» либо текст отказа.
    local function sent(from, bucket_id, destination)
        return g.stand[from]:exec(function(id, to)
            ---@type any
            local storage = require('vshard.storage')
            local ok, err = storage.bucket_send(id, to, { timeout = 30 })

            return ok and 'отправлен' or tostring(err)
        end, { bucket_id, destination })
    end

    local ok, seen = pcall(function()
        local moving = g.stand['storage-a']:exec(function()
            return box.space.users.index.age:select({ 132 }, { limit = 1 })[1].bucket_id
        end)

        fan_out(132, 12, 2)

        local away = sent('storage-a', moving, 'storage-002')
        local fanned = fan_out_stopped()
        local back = sent('storage-b', moving, 'storage-001')

        return { away = away, back = back, fanned = fanned }
    end)

    router_timeout(nil)

    local after = g.router:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        return User.where('age', '=', 132):count()
    end)

    forgotten(3101, 12)

    t.assert(ok, seen)
    ---@cast seen any
    t.assert_equals(
        { seen.away, seen.back },
        { 'отправлен', 'отправлен' },
        'бакет уехал и вернулся'
    )
    t.assert_equals(seen.fanned.partial, 0, 'неполного ответа веера не бывает')
    t.assert_gt(seen.fanned.whole + #seen.fanned.refusals, 0, 'веер шёл, пока бакет переезжал')

    for _, refusal in ipairs(seen.fanned.refusals) do
        t.assert_equals(refusal[1], 'unavailable')
        t.assert_str_matches(refusal[2], 'хранилище storage%-00[12] не ответило: .+')
    end

    t.assert_equals(after, 12, 'после переноса веер видит все записи')
end

-- Хранилище молчит — отказ веера называет его. Процесс на паузе держит
-- соединение, и веер не дожидается ответа; погашенный узел соединения
-- не даёт вовсе. Вызов в один бакет живого хранилища идёт как шёл,
-- а поднятый снова узел веер слышит опять. Проверка последняя в группе:
-- она гасит узел стенда.
g.test_a_fan_out_names_the_storage_that_did_not_answer = function()
    local storage = g.stand['storage-b']

    --- Отказ веера модели и запись живого хранилища, найденная по ключу.
    local function heard()
        return g.router:exec(function()
            ---@type any
            local vshard = require('vshard')
            ---@type any
            local User = rawget(_G, 'User')
            local _, err = User.where('age', '=', 133):count()
            local near = nil

            for id = 3201, 3210 do
                if vshard.router.route(vshard.router.bucket_id_mpcrc32(id)).id == 'storage-001' then
                    near = User.find(id).id
                end
            end

            return { kind = err and err.kind, text = tostring(err), near = near }
        end)
    end

    router_timeout(0.5)
    placed(3201, 10, 133)
    storage.process:kill('STOP')

    local paused_ok, paused = pcall(heard)

    storage.process:kill('CONT')
    storage:stop()

    local stopped_ok, stopped = pcall(heard)

    storage:start()
    storage:wait_until_ready()

    t.helpers.retrying({ timeout = 10, delay = 0.1 }, function()
        t.assert_equals(
            g.router:exec(function()
                return rawget(_G, 'User').where('age', '=', 133):count()
            end),
            10
        )
    end)

    router_timeout(nil)
    forgotten(3201, 10)

    t.assert(paused_ok, paused)
    t.assert(stopped_ok, stopped)
    ---@cast paused any
    ---@cast stopped any
    t.assert_equals(paused.kind, 'unavailable')
    t.assert_equals(paused.text, 'хранилище storage-002 не ответило: timed out')
    t.assert_equals(stopped.kind, 'unavailable')
    t.assert_str_matches(stopped.text, 'хранилище storage%-002 не ответило: .+')
    t.assert_not_equals(
        paused.near,
        nil,
        'запись живого хранилища нашлась в паузу соседа'
    )
    t.assert_equals(stopped.near, paused.near)
end
