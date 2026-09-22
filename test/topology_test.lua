--- Правило выбора шлюза, раздел `models` и привязка моделей.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.topology')

---@type any
local model

---@type any
local topology

---@type table Что отдаёт двойник конфигурации
local cluster

g.before_each(function()
    model = helper.load()
    topology = helper.module('tnt.model.topology')
    cluster = {}

    model._set_source({
        config = function()
            return helper.fake_config(cluster)
        end,
    })
end)

g.after_each(function()
    model._set_source(nil)
    helper.unload()
end)

--- Сверяет, что `model.atomic` привязки — это `box.atomic` узла: двойник
--- `box` зовёт тело сразу и считает транзакции.
local function assert_atomic_is_box_atomic()
    local calls = {}

    model._set_source({
        config = function()
            return helper.fake_config(cluster)
        end,
        box = function()
            return {
                space = {},
                atomic = function(fn, ...)
                    table.insert(calls, 'atomic')

                    return fn(...)
                end,
            }
        end,
    })

    t.assert_equals(
        model.atomic(function(a, b)
            return a + b
        end, 1, 2),
        3
    )
    t.assert_equals(calls, { 'atomic' })
end

g.test_settings_have_defaults_and_refuse_odd_values = function()
    t.assert_equals(model.settings(nil), { source = 'auto', timeout = 5, writes = 'local', driver = 'db' })
    t.assert_equals(model.settings({}), { source = 'auto', timeout = 5, writes = 'local', driver = 'db' })
    t.assert_equals(model.settings({ source = 'remote', replicaset = 'core', timeout = 0.5 }), {
        source = 'remote',
        replicaset = 'core',
        timeout = 0.5,
        writes = 'local',
        driver = 'db',
    })
    t.assert_equals(model.settings({ source = 'sql', driver = 'reports' }), {
        source = 'sql',
        timeout = 5,
        writes = 'local',
        driver = 'reports',
    })
    t.assert_equals(model.settings({ driver = 'd' }).driver, 'd')
    t.assert_error_msg_equals(
        'раздел models: драйвер должен быть строкой длиной не меньше 1 знака, а сейчас 0 знаков',
        model.settings,
        { driver = '' }
    )
    t.assert_equals(model.settings({ writes = 'forward' }).writes, 'forward')
    t.assert_equals(model.SECTION, 'models')
    t.assert_error_msg_equals(
        'раздел models должен быть таблицей, получено string',
        model.settings,
        'remote'
    )
    t.assert_error_msg_equals(
        "раздел models: источник должен быть одним из: 'auto', 'local', 'sharded', 'remote', 'sql', а не 'vshard'",
        model.settings,
        { source = 'vshard' }
    )
    t.assert_error_msg_equals(
        'раздел models: срок должен быть числом не меньше 0.001, а не 0',
        model.settings,
        { timeout = 0 }
    )
    t.assert_error_msg_equals(
        "раздел models: запись должна быть одним из: 'local', 'forward', а не 'always'",
        model.settings,
        { writes = 'always' }
    )

    -- Имя репликасета — непустая строка: в один знак уже годится.
    t.assert_equals(model.settings({ source = 'remote', replicaset = 'c' }).replicaset, 'c')
    t.assert_error_msg_equals(
        'раздел models: репликасет должен быть строкой длиной не меньше 1 знака, а сейчас 0 знаков',
        model.settings,
        { source = 'remote', replicaset = '' }
    )
    t.assert_error_msg_equals(
        'раздел models: неизвестная настройка peers',
        model.settings,
        { peers = {} }
    )
end

g.test_rule_by_vshard_roles = function()
    local cases = {
        { roles = nil, source = 'local', sharded = false, serves = true },
        { roles = {}, source = 'local', sharded = false, serves = true },
        { roles = { 'storage' }, source = 'local', sharded = true, serves = true, bucket_count = 300 },
        { roles = { 'router' }, source = 'sharded', sharded = false, serves = false },
        { roles = { 'router', 'storage' }, source = 'sharded', sharded = true, serves = true, bucket_count = 300 },
    }

    for index, case in ipairs(cases) do
        cluster = { sharding_roles = case.roles, bucket_count = 300 }

        local place = topology.resolve(model.settings(nil))

        t.assert_equals(place, {
            source = case.source,
            sharded = case.sharded,
            serves = case.serves,
            bucket_count = case.bucket_count,
            timeout = 5,
        }, ('случай №%d'):format(index))
    end

    -- Вне кластерной конфигурации ролей нет: одиночный узел, шлюз local.
    model._set_source({
        config = function()
            error('config:get(): no instance config available yet')
        end,
    })

    t.assert_equals(topology.resolve(model.settings(nil)).source, 'local')
    t.assert_equals(topology.vshard_storage(), false)

    cluster = { sharding_roles = { 'storage' } }
    model._set_source({
        config = function()
            return helper.fake_config(cluster)
        end,
    })

    t.assert_equals(topology.vshard_storage(), true)
end

g.test_sql_is_only_explicit_and_serves_nothing_whatever_the_roles = function()
    for _, roles in ipairs({ {}, { 'storage' }, { 'router' }, { 'router', 'storage' } }) do
        cluster = { sharding_roles = roles, bucket_count = 30 }

        local place = topology.resolve(model.settings({ source = 'sql' }))

        t.assert_equals(
            { place.source, place.serves, place.sharded },
            { 'sql', false, roles[#roles] == 'storage' },
            table.concat(roles, ',')
        )
    end

    t.assert_error_msg_equals(
        'пересылка записи: у источника sql данные в базе — запись и так уходит туда',
        topology.resolve,
        model.settings({ source = 'sql', writes = 'forward' })
    )
end

g.test_explicit_source_must_agree_with_the_roles = function()
    cluster = { sharding_roles = { 'router' } }

    t.assert_equals(topology.resolve(model.settings({ source = 'sharded' })).source, 'sharded')
    t.assert_error_msg_equals(
        'источник local: роутер vshard данных не держит',
        topology.resolve,
        model.settings({ source = 'local' })
    )
    t.assert_error_msg_equals(
        'источник remote: у узла с ролью vshard данные ходят через vshard',
        topology.resolve,
        model.settings({ source = 'remote', replicaset = 'core' })
    )

    cluster = { sharding_roles = { 'storage' }, bucket_count = 10 }

    t.assert_equals(topology.resolve(model.settings({ source = 'local' })).bucket_count, 10)
    t.assert_error_msg_equals(
        'источник sharded: у узла нет роли router vshard',
        topology.resolve,
        model.settings({ source = 'sharded' })
    )

    cluster = {}

    t.assert_error_msg_equals(
        'источник remote: назовите replicaset с данными',
        topology.resolve,
        model.settings({ source = 'remote' })
    )
end

g.test_remote_takes_peers_of_the_replicaset_under_the_sharding_login = function()
    cluster = {
        replicaset = 'gw',
        instances = {
            ['core-b'] = { replicaset_name = 'core' },
            ['core-a'] = { replicaset_name = 'core' },
            ['gw-a'] = { replicaset_name = 'gw' },
        },
        uris = {
            ['core-a'] = { uri = '127.0.0.1:3391', login = 'storage', password = 's' },
            ['core-b'] = { uri = '127.0.0.1:3392', login = 'storage', password = 's' },
        },
    }

    local place = topology.resolve(model.settings({ source = 'remote', replicaset = 'core', timeout = 1 }))

    t.assert_equals(place, {
        source = 'remote',
        sharded = false,
        serves = false,
        timeout = 1,
        replicaset = 'core',
        peers = {
            { name = 'core-a', uri = '127.0.0.1:3391', login = 'storage', password = 's' },
            { name = 'core-b', uri = '127.0.0.1:3392', login = 'storage', password = 's' },
        },
    })

    t.assert_error_msg_equals(
        'источник remote: репликасет gw — свой, данные были бы на месте',
        topology.resolve,
        model.settings({ source = 'remote', replicaset = 'gw' })
    )
    t.assert_error_msg_equals(
        'источник remote: репликасета nope нет в конфигурации кластера',
        topology.resolve,
        model.settings({ source = 'remote', replicaset = 'nope' })
    )

    cluster.uris['core-a'] = { uri = '127.0.0.1:3391' }

    t.assert_error_msg_equals(
        'источник remote: у узла core-a нет учётки — задайте iproto.advertise.sharding',
        topology.resolve,
        model.settings({ source = 'remote', replicaset = 'core' })
    )
end

--- Кластер из репликасета core на три узла и прослойки: узел — core-b.
---@param roles string[]|nil Роли шардирования узла
---@return table
local function replicaset_of_three(roles)
    return {
        sharding_roles = roles,
        replicaset = 'core',
        instance = 'core-b',
        instances = {
            ['core-c'] = { replicaset_name = 'core' },
            ['core-a'] = { replicaset_name = 'core' },
            ['core-b'] = { replicaset_name = 'core' },
            ['gw-a'] = { replicaset_name = 'gw' },
        },
        uris = {
            ['core-a'] = { uri = '127.0.0.1:3391', login = 'storage', password = 's' },
            ['core-b'] = { uri = '127.0.0.1:3392', login = 'storage', password = 's' },
            ['core-c'] = { uri = '127.0.0.1:3393', login = 'storage', password = 's' },
            ['gw-a'] = { uri = '127.0.0.1:3394', login = 'storage', password = 's' },
        },
    }
end

g.test_forward_takes_the_neighbours_of_its_own_replicaset = function()
    cluster = replicaset_of_three()

    t.assert_equals(topology.WRITES_LOCAL, 'local')
    t.assert_equals(topology.WRITES_FORWARD, 'forward')
    t.assert_equals(topology.resolve(model.settings({ writes = 'forward', timeout = 2 })), {
        source = 'local',
        sharded = false,
        serves = true,
        timeout = 2,
        writes = 'forward',
        replicaset = 'core',
        peers = {
            { name = 'core-a', uri = '127.0.0.1:3391', login = 'storage', password = 's' },
            { name = 'core-c', uri = '127.0.0.1:3393', login = 'storage', password = 's' },
        },
    }, 'себя и чужой репликасет в списке нет, соседи — по имени')

    -- Явный источник local — то же самое; replicaset раздела пересылке
    -- не нужен: она ходит только в свой репликасет.
    local explicit = topology.resolve(model.settings({ source = 'local', replicaset = 'gw', writes = 'forward' }))

    t.assert_equals({ explicit.source, explicit.replicaset, #explicit.peers }, { 'local', 'core', 2 })

    -- Репликасет из двух узлов: сосед ровно один, и его достаточно.
    cluster.instances['core-c'] = nil

    t.assert_equals(
        topology.resolve(model.settings({ writes = 'forward' })).peers,
        { { name = 'core-a', uri = '127.0.0.1:3391', login = 'storage', password = 's' } }
    )

    -- Без пересылки ни соседей, ни признака.
    t.assert_equals(topology.resolve(model.settings(nil)), {
        source = 'local',
        sharded = false,
        serves = true,
        timeout = 5,
    })
end

g.test_forward_must_agree_with_the_place_of_the_node = function()
    local message =
        'пересылка записи: у узла с ролью vshard запись ходит через роутер'

    for _, roles in ipairs({ { 'storage' }, { 'router' }, { 'router', 'storage' } }) do
        cluster = replicaset_of_three(roles)

        t.assert_error_msg_equals(message, topology.resolve, model.settings({ writes = 'forward' }))
    end

    cluster = replicaset_of_three()
    cluster.replicaset = 'gw'
    cluster.instance = 'gw-a'

    t.assert_error_msg_equals(
        'пересылка записи: у прослойки данных нет — шлюз remote и так пишет на ведущем',
        topology.resolve,
        model.settings({ source = 'remote', replicaset = 'core', writes = 'forward' })
    )

    -- Узел один в своём репликасете: пересылать некому.
    t.assert_error_msg_equals(
        'пересылка записи: у узла gw-a нет соседей по репликасету gw',
        topology.resolve,
        model.settings({ writes = 'forward' })
    )

    -- Вне кластерной конфигурации ни имени узла, ни репликасета нет.
    cluster = {}
    model._set_source({
        config = function()
            local config = helper.fake_config(cluster)

            config.info = function()
                return { hierarchy = {} }
            end

            return config
        end,
    })

    t.assert_error_msg_equals(
        'пересылка записи: у узла nil нет соседей по репликасету nil',
        topology.resolve,
        model.settings({ writes = 'forward' })
    )

    -- Сосед без учётки: ходить к нему не под кем.
    cluster = replicaset_of_three()
    cluster.uris['core-c'] = { uri = '127.0.0.1:3393' }
    model._set_source({
        config = function()
            return helper.fake_config(cluster)
        end,
    })

    t.assert_error_msg_equals(
        'пересылка записи: у узла core-c нет учётки — задайте iproto.advertise.sharding',
        topology.resolve,
        model.settings({ writes = 'forward' })
    )

    cluster.uris['core-c'] = 'storage@127.0.0.1:3393'

    t.assert_error_msg_equals(
        'пересылка записи: у узла core-c нет учётки — задайте iproto.advertise.sharding',
        topology.resolve,
        model.settings({ writes = 'forward' })
    )
end

g.test_binding_checks_models_builds_gateway_and_switches_on_attach = function()
    local User = helper.users(model)
    local Plain = model.define({ space = 'plain', fields = { { 'id', 'unsigned', primary = true } } })

    t.assert_error_msg_equals(
        'модели: запись №1 — не модель, а string',
        model.bind,
        { 'users' },
        model.settings(nil)
    )
    t.assert_error_msg_equals(
        'модели: спейс users объявлен дважды',
        model.bind,
        { User, helper.users(model) },
        model.settings(nil)
    )

    t.assert_error_msg_equals(
        'model.atomic: у узла нет привязанных моделей — конфигурация ещё не применена',
        model.atomic,
        function() end
    )

    local empty = model.bind({}, model.settings(nil))

    t.assert_equals(empty.status(), { spaces = {} })
    t.assert_equals(empty.functions, {})
    empty.attach()
    t.assert_error_msg_equals(
        'model.atomic: у узла нет привязанных моделей — конфигурация ещё не применена',
        model.atomic,
        function() end
    )
    empty.close()

    cluster = { sharding_roles = { 'router' } }

    t.assert_error_msg_equals(
        'модель plain без ключа шардирования: в шардированном кластере нужен model.bucket_of(поле)',
        model.bind,
        { User, Plain },
        model.settings(nil)
    )

    local binding = model.bind({ User }, model.settings(nil))

    t.assert_equals(binding.source, 'sharded')
    t.assert_equals(
        binding.functions,
        {},
        'роутер данных не держит — функций узла нет'
    )
    t.assert_equals(User.bound(), nil, 'до attach модель не тронута')

    binding.attach()

    t.assert_equals(User.bound(), 'sharded')
    t.assert_equals(binding.status(), { source = 'sharded', sharded = false, serves = false, spaces = { 'users' } })
    t.assert_error_msg_contains(
        'транзакция через роутер невозможна',
        model.atomic,
        function() end
    )

    -- Перечитывание: новая привязка собирается рядом, старая закрывается
    -- и не отвязывает модель, уже переключённую на новую.
    cluster = { sharding_roles = { 'router', 'storage' }, bucket_count = 100 }

    local fresh = model.bind({ User }, model.settings(nil))

    t.assert_equals(fresh.status(), { source = 'sharded', sharded = true, serves = true, spaces = { 'users' } })
    t.assert_type(fresh.functions.tnt_model_find, 'function')

    fresh.attach()
    binding.close()

    t.assert_equals(User.bound(), 'sharded')
    t.assert_is(User._gateway(), fresh.gateway)

    -- Узел «и роутер, и хранилище» держит свои бакеты: транзакция у него
    -- есть, и это `box.atomic`.
    assert_atomic_is_box_atomic()

    fresh.close()

    -- После close текст называет закрытую привязку: «конфигурация ещё
    -- не применена» после остановки роли уводил бы искать не то.
    t.assert_equals(User.bound(), nil)
    t.assert_error_msg_equals(
        'модель users не привязана: привязка закрыта, новой нет',
        User.find,
        7
    )
    t.assert_error_msg_equals(
        'model.atomic: у узла нет привязанных моделей — привязка закрыта, новой нет',
        model.atomic,
        function() end
    )

    -- Новая привязка после закрытой — снова действующая.
    local again = model.bind({ User }, model.settings(nil))

    again.attach()

    t.assert_is(helper.module('tnt.model.binding').current(), again)
    again.close()
end

g.test_binding_local_binds_models_and_serves_functions_on_the_node = function()
    cluster = { sharding_roles = { 'storage' }, bucket_count = 100 }

    local User = helper.users(model)
    local binding = model.bind({ User }, model.settings(nil))

    binding.attach()

    t.assert_equals(User.bound(), 'local')
    t.assert_equals(binding.status(), { source = 'local', sharded = true, serves = true, spaces = { 'users' } })
    t.assert_type(binding.functions.tnt_model_put, 'function')

    assert_atomic_is_box_atomic()

    binding.close()
end

g.test_binding_remote_closes_connections_on_close = function()
    cluster = {
        replicaset = 'gw',
        instances = { ['core-a'] = { replicaset_name = 'core' } },
        uris = { ['core-a'] = { uri = 'a', login = 'storage', password = 's' } },
    }

    local closed = 0

    model._set_source({
        config = function()
            return helper.fake_config(cluster)
        end,
        net_box = function()
            return {
                connect = function()
                    return {
                        wait_connected = function()
                            return true
                        end,
                        call = function()
                            return { ok = true, value = { id = 1, name = 'a', age = 1 } }
                        end,
                        close = function()
                            closed = closed + 1
                        end,
                    }
                end,
            }
        end,
    })

    local User = helper.users(model)
    local binding = model.bind({ User }, model.settings({ source = 'remote', replicaset = 'core' }))

    binding.attach()

    t.assert_equals(binding.status(), { source = 'remote', sharded = false, serves = false, spaces = { 'users' } })
    t.assert_equals(binding.functions, {})
    t.assert_equals(User.find(1).id, 1)

    binding.close()

    t.assert_equals(closed, 1)
    t.assert_equals(User.bound(), nil)
end

g.test_binding_forward_writes_through_neighbours_and_serves_only_its_own_data = function()
    cluster = replicaset_of_three()

    local calls = {}
    local closed = {}
    local in_txn = false

    model._set_source({
        config = function()
            return helper.fake_config(cluster)
        end,
        box = function()
            return {
                space = { users = {} },
                info = { ro = true, ro_reason = 'config' },
                is_in_txn = function()
                    return in_txn
                end,
                atomic = function(fn, ...)
                    in_txn = true

                    local value, err = fn(...)

                    in_txn = false

                    return value, err
                end,
            }
        end,
        net_box = function()
            return {
                connect = function(uri)
                    return {
                        wait_connected = function()
                            return uri == '127.0.0.1:3391'
                        end,
                        error = 'Connection refused',
                        call = function(_, name, args)
                            table.insert(calls, { uri = uri, name = name, args = args })

                            return { ok = true, value = args[2] }
                        end,
                        close = function()
                            table.insert(closed, uri)
                        end,
                    }
                end,
            }
        end,
    })

    local User = helper.users(model)
    local binding = model.bind({ User }, model.settings({ writes = 'forward' }))

    binding.attach()

    t.assert_equals(User.bound(), 'local', 'модели читают своим шлюзом local')
    t.assert_equals(binding.source, 'local')
    t.assert_equals(
        binding.status(),
        { source = 'local', sharded = false, serves = true, writes = 'forward', spaces = { 'users' } }
    )

    -- Запись узла только для чтения ушла соседу, принявшему её.
    t.assert_equals(
        User.create({ id = 1, name = 'Мария', age = 46 }):to_table(),
        { id = 1, name = 'Мария', age = 46 }
    )
    t.assert_equals(calls, {
        {
            uri = '127.0.0.1:3391',
            name = 'tnt_model_put',
            args = { 'users', { id = 1, name = 'Мария', age = 46 }, 'insert' },
        },
    })

    -- Функция узла с данными отвечает своими данными и не пересылает.
    t.assert_equals(binding.functions.tnt_model_put('users', { id = 2, name = 'Иван', age = 30 }, 'insert'), {
        ok = false,
        kind = 'readonly',
        message = 'узел только для чтения: config',
    })
    t.assert_equals(#calls, 1, 'соседям от функции узла ничего не ушло')

    -- Транзакция — на месте, запись в ней не пересылается.
    local _, refused = model.atomic(function()
        return User.create({ id = 3, name = 'Анна', age = 19 })
    end)

    t.assert_equals(
        tostring(refused),
        'узел только для чтения: config; в транзакции запись ведущему не пересылается'
    )
    t.assert_equals(#calls, 1)

    binding.close()

    t.assert_equals(
        closed,
        { '127.0.0.1:3391' },
        'соединение с соседом закрыто вместе с привязкой'
    )
    t.assert_equals(User.bound(), nil)
end

g.test_binding_sql_takes_the_gateway_of_the_caller = function()
    local User = helper.users(model)
    local settings = model.settings({ source = 'sql' })
    local missing = 'источник sql: шлюза нет — его приносит тот, кто собирает привязку: '
        .. 'model.bind(модели, раздел, { sql = orm.gateway(db) })'

    t.assert_error_msg_equals(missing, model.bind, { User }, settings)
    t.assert_error_msg_equals(missing, model.bind, { User }, settings, { local_ = true })

    local gateway, calls = helper.fake_gateway({ find = { id = 7, name = 'Мария', age = 46 } })

    gateway.kind = 'sql'

    local binding = model.bind({ User }, settings, { sql = gateway })

    t.assert_equals(binding.functions, {})
    t.assert_equals(binding.status(), { source = 'sql', sharded = false, serves = false, spaces = { 'users' } })

    binding.attach()

    t.assert_equals(User.bound(), 'sql')
    t.assert_equals(User.find(7).name, 'Мария')
    t.assert_equals(
        model.atomic(function()
            return 'в базе'
        end),
        'в базе'
    )

    -- Шлюз прочих источников извне не берётся: он заводится по топологии.
    local fresh = model.bind({ User }, model.settings(nil), { sql = gateway })

    t.assert_equals(fresh.source, 'local')
    t.assert_not_equals(fresh.gateway, gateway)

    binding.close()

    t.assert_equals(calls[#calls].name, 'close')
    t.assert_equals(User.bound(), nil)
end

--- Модели для сверки уникальности: логин уникален без ключа
--- шардирования, логин уникален в пределах арендатора — ключ в индексе,
--- но не первым полем, и модель без ключа шардирования.
---@return table models `account`, `member`, `tag`
local function unique_models()
    return {
        account = model.define({
            space = 'accounts',
            fields = {
                { 'id', 'unsigned', primary = true },
                model.bucket_of('id'),
                { 'login', 'string' },
            },
            indexes = { login = { parts = { 'login' }, unique = true } },
        }),
        member = model.define({
            space = 'members',
            fields = {
                { 'tenant', 'unsigned', primary = true },
                model.bucket_of('tenant'),
                { 'id', 'unsigned', primary = true },
                { 'login', 'string' },
            },
            indexes = { login = { parts = { 'login', 'tenant' }, unique = true } },
        }),
        tag = model.define({
            space = 'tags',
            fields = { { 'id', 'unsigned', primary = true }, { 'code', 'string' } },
            indexes = { code = { parts = { 'code' }, unique = true } },
        }),
    }
end

-- Уникальный индекс без ключа шардирования держит уникальность только
-- внутри репликасета: на узле с ролью vshard это ошибка привязки, и текст
-- называет модель, индекс и ключ. Индекс с ключом среди полей уникален
-- по кластеру на любом месте ключа; модель без ключа шардирования на
-- хранилище не шардирована и не сверяется. Без vshard данные в одном
-- репликасете, у источника sql — в базе при любых ролях, и модель
-- привязывается без сверки.
g.test_binding_refuses_a_unique_index_without_the_shard_key_on_vshard_nodes = function()
    local models = unique_models()
    local User = helper.users(model)
    local refusal = 'модель accounts: уникальность индекса login в шардированном кластере не гарантирована — '
        .. 'среди его полей нет ключа шардирования id'

    for _, roles in ipairs({ { 'router' }, { 'storage' }, { 'router', 'storage' } }) do
        cluster = { sharding_roles = roles, bucket_count = 30 }

        local where = table.concat(roles, ',')

        t.assert_error_msg_equals(refusal, model.bind, { User, models.account }, model.settings(nil))
        t.assert_equals(model.bind({ User, models.member }, model.settings(nil)).status().spaces, {
            'users',
            'members',
        }, where)
    end

    cluster = { sharding_roles = { 'storage' }, bucket_count = 30 }

    t.assert_equals(model.bind({ models.tag }, model.settings(nil)).source, 'local')

    local unchecked = {
        { roles = {}, source = 'local' },
        { roles = { 'storage' }, source = 'sql' },
        { roles = { 'router' }, source = 'sql' },
        { roles = { 'router', 'storage' }, source = 'sql' },
    }

    for _, case in ipairs(unchecked) do
        cluster = { sharding_roles = case.roles, bucket_count = 30 }

        local binding = model.bind(
            { models.account },
            model.settings({ source = case.source }),
            { sql = helper.fake_gateway({}) }
        )

        t.assert_equals(
            { binding.source, binding.status().spaces },
            { case.source, { 'accounts' } },
            table.concat(case.roles, ',')
        )
    end
end
