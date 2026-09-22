--- Общие средства проверок моделей.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.validate`, `tnt.must`, `tnt.external`, `tnt.clock` —
--- берутся из `.rocks` обычным `require`: проверяется этот пакет, а не они.
--- Оснастка в `test/testing/` грузится так же и один раз на процесс:
--- второй экземпляр загрузчика не знал бы, что вытеснил первый,
--- и не вернул бы вытесненное на место.
---
--- Настоящий `box` живёт в дочернем узле (`t.Server`), в процессе
--- проверок его нет; шлюзы `sharded` и `remote` проверяются двойниками
--- роутера и net.box через внешнюю зависимость.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    module = package.loaded['tnt.testing.sources'].module,
    start_node = package.loaded['tnt.testing.node'].start,
    stop_node = package.loaded['tnt.testing.node'].stop,
    free_port = package.loaded['tnt.testing.node'].free_port,
    write_file = package.loaded['tnt.testing.files'].write,
}

--- Корень репозитория: от него строятся пути узлов стенда.
---
--- Считается от этого файла, а не от рабочего каталога: узел стенда
--- живёт в своём временном каталоге, и относительный путь он не понял бы.
local this_file =
    assert(debug.getinfo(1), 'нет отладочной информации о файле').source:sub(2)
local project_root = fio.abspath(fio.pathjoin(fio.dirname(this_file), '..'))

local helper = {}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.model.world', path = 'tnt/model/world.lua' },
    { name = 'tnt.model.failure', path = 'tnt/model/failure.lua' },
    { name = 'tnt.model.stamp', path = 'tnt/model/stamp.lua' },
    { name = 'tnt.model.hook', path = 'tnt/model/hook.lua' },
    { name = 'tnt.model.shape', path = 'tnt/model/shape.lua' },
    { name = 'tnt.model.order', path = 'tnt/model/order.lua' },
    { name = 'tnt.model.check', path = 'tnt/model/check.lua' },
    { name = 'tnt.model.scope', path = 'tnt/model/scope.lua' },
    { name = 'tnt.model.tuple', path = 'tnt/model/tuple.lua' },
    { name = 'tnt.model.topology', path = 'tnt/model/topology.lua' },
    { name = 'tnt.model.migration', path = 'tnt/model/migration.lua' },
    { name = 'tnt.model.query', path = 'tnt/model/query.lua' },
    { name = 'tnt.model.record', path = 'tnt/model/record.lua' },
    { name = 'tnt.model.factory', path = 'tnt/model/factory.lua' },
    { name = 'tnt.model.entity', path = 'tnt/model/entity.lua' },
    { name = 'tnt.model.gateway.local', path = 'tnt/model/gateway/local.lua' },
    { name = 'tnt.model.gateway.sharded', path = 'tnt/model/gateway/sharded.lua' },
    { name = 'tnt.model.gateway.remote', path = 'tnt/model/gateway/remote.lua' },
    { name = 'tnt.model.gateway.forward', path = 'tnt/model/gateway/forward.lua' },
    { name = 'tnt.model.serve', path = 'tnt/model/serve.lua' },
    { name = 'tnt.model.binding', path = 'tnt/model/binding.lua' },
    { name = 'tnt.model', path = 'tnt/model.lua' },
}

--- Загружает исходники заново.
---@return any model Фасад `tnt.model`
function helper.load()
    return testing.load_sources(helper.MODULES, 'tnt.model')
end

--- Заводит группу проверок со свежими исходниками на каждую проверку.
---
--- Фасад отдаётся вызывающему через `on_load`: проверки держат его
--- в своей локальной переменной, а не в группе.
---@param name string
---@param on_load fun(model: any)
---@return table g
function helper.group(name, on_load)
    local g = t.group(name)

    g.before_each(function()
        on_load(helper.load())
    end)

    g.after_each(function()
        testing.unload_sources(helper.MODULES)
    end)

    return g
end

--- Уже загруженный модуль пакета.
helper.module = testing.module

--- Убирает исходники: следующая проверка грузит их заново.
function helper.unload()
    testing.unload_sources(helper.MODULES)
end

--- Свободный порт TCP — под iproto узла стенда.
helper.free_port = testing.free_port

--- Останавливает узел оснастки и убирает его каталог.
helper.stop_node = testing.stop_node

--- Ключи записей страницы по порядку.
---
--- Записи приходят с узла таблицами через `exec`, и сверять страницу
--- удобнее ключами: порядок и состав видны одной строкой.
---@param rows table[]
---@return any[]
function helper.ids(rows)
    local ids = {}

    for position, row in ipairs(rows) do
        ids[position] = row.id
    end

    return ids
end

--- Форма модели пользователей без функций: годится дочернему узлу.
---
--- Ключ шардирования объявлен: на узле без шардирования он просто
--- не заводит поля, и одно объявление служит всем топологиям.
---@return table
function helper.users_layout()
    return {
        space = 'users',
        fields = {
            { 'id', 'unsigned', primary = true },
            { name = 'bucket_id', type = 'unsigned', bucket_of = 'id' },
            { 'name', 'string', min = 1, max = 255, trim = true },
            { 'age', 'unsigned', min = 0, max = 150 },
            { 'email', 'string', optional = true },
        },
        indexes = { age = { parts = { 'age' }, unique = false } },
    }
end

--- Объявление модели пользователей — образец на все проверки.
---@param _ any Фасад `tnt.model` — форма от него не зависит
---@param overrides table|nil Поля объявления поверх образца
---@return table spec
function helper.users_spec(_, overrides)
    local spec = helper.users_layout()

    spec.methods = {
        is_adult = function(self)
            return self.age >= 18
        end,
    }

    for key, value in pairs(overrides or {}) do
        spec[key] = value
    end

    return spec
end

--- Модель пользователей по образцу.
---@param model any Фасад `tnt.model`
---@param overrides table|nil
---@return any User
function helper.users(model, overrides)
    return model.define(helper.users_spec(model, overrides))
end

--- Двойник шлюза: пишет вызовы, отвечает заготовленным.
---
--- Каждое действие отдаёт `answers[имя]` как есть — значение либо пару
--- `{ nil, отказ }` в поле `refusal`.
---@param answers table|nil
---@return table gateway
---@return table[] calls
function helper.fake_gateway(answers)
    local calls = {}
    local gateway = { kind = 'fake' }

    for _, name in ipairs({ 'find', 'put', 'delete', 'select', 'count' }) do
        gateway[name] = function(shape, ...)
            table.insert(calls, { name = name, space = shape.space, args = { ... } })

            local answer = (answers or {})[name]

            if type(answer) == 'table' and answer.refusal ~= nil then
                return nil, answer.refusal
            end

            return answer
        end
    end

    gateway.atomic = function(fn, ...)
        table.insert(calls, { name = 'atomic' })

        return fn(...)
    end

    gateway.close = function()
        table.insert(calls, { name = 'close' })
    end

    return gateway, calls
end

--- Двойник net.box для шлюза `remote`: соединения с узлами по адресу.
---
--- Состояние соединения — как у net.box без `reconnect_after`: не
--- поднявшееся остаётся в `error`, медленное — ещё в `initial`,
--- оборванное посреди вызова (`drops`) — в `error`, закрытое — в `closed`.
--- Узел отвечает `reply` либо бросает `throws` — ту ошибку, что бросил бы
--- net.box: отказ сервера, срок, обрыв связи.
---
--- Узел двойника — таблица по адресу: `reachable`, `pending`, `error`,
--- `reply`, `throws`, `drops`, `connecting`, `gate` задаёт проверка,
--- а `opened`, `opts`, `waited`, `waits`, `closed` дописывает сам двойник.
--- `connecting` — сколько секунд поднимается соединение: на столько
--- ожидание двигает двойник часов (`helper.fake_clock`), если он дан.
--- `gate` — канал `fiber`: вызов ждёт из него значения, прежде чем ответить,
--- и так остаётся в пути, пока проверка его не отпустит. Ответ берётся
--- уже после ожидания. Соединение, закрытое, пока вызов ждал, кончает
--- его ошибкой «Connection closed» с кодом `ER_NO_CONNECTION` — так
--- поступает net.box 3.8 (сверено на узле).
---@param nodes table<string, table> Узлы по адресу
---@param calls table[] Журнал вызовов: uri, name, args, opts
---@param clock table|nil Двойник часов, которые двигает ожидание соединения
---@return table net_box
function helper.fake_net_box(nodes, calls, clock)
    local net_box = {}

    function net_box.connect(uri, opts)
        local node = nodes[uri]

        node.opened = (node.opened or 0) + 1
        node.opts = opts

        return {
            error = node.error,
            state = 'initial',
            wait_connected = function(self, timeout)
                node.waited = timeout
                node.waits = (node.waits or 0) + 1

                if clock ~= nil then
                    clock.pass(node.connecting or 0)
                end

                if node.reachable == false then
                    self.state = node.pending and 'initial' or 'error'
                    self.error = node.error

                    return false
                end

                self.state = 'active'

                return true
            end,
            call = function(self, name, args, call_opts)
                table.insert(calls, { uri = uri, name = name, args = args, opts = call_opts })

                if node.gate ~= nil then
                    node.gate:get()
                end

                if self.state == 'closed' then
                    ---@type any
                    local box_error = box.error

                    error(box_error.new({ code = box_error.NO_CONNECTION, reason = 'Connection closed' }), 0)
                end

                if node.drops then
                    self.state = 'error'
                end

                if node.throws ~= nil then
                    error(node.throws, 0)
                end

                return node.reply
            end,
            close = function(self)
                node.closed = (node.closed or 0) + 1
                self.state = 'closed'
            end,
        }
    end

    return net_box
end

--- Двойник часов `tnt-clock` для шлюза `remote`: время стоит, пока его
--- не сдвинет проверка или двойник net.box.
---
--- Монотонные часы (`monotonic`) показывают `now`, отметка цикла
--- (`scheduler_now`) отстаёт от них на `lag` — так отметка отстаёт,
--- когда файбер работал, не уступая управления. `pass(seconds)` двигает
--- обе.
---@param lag number|nil Отставание отметки цикла, секунды
---@return table clock
function helper.fake_clock(lag)
    local clock = { now = 100, lag = lag or 0 }

    function clock.monotonic()
        return clock.now
    end

    function clock.scheduler_now()
        return clock.now - clock.lag
    end

    function clock.pass(seconds)
        clock.now = clock.now + seconds
    end

    return clock
end

--- Ошибка, которой net.box 3.8 кончает вызов по сроку: род `TimedOut`,
--- кода нет — такой её бросает настоящий net.box, сверено на узле.
---@return table
function helper.timed_out()
    ---@type any
    local box_error = box.error

    return box_error.new({ type = 'TimedOut', reason = 'timed out' })
end

--- Двойник конфигурации узла для топологии.
---@param overrides table|nil sharding_roles, bucket_count, replicaset, instance, instances, uris
---@return table
function helper.fake_config(overrides)
    local given = overrides or {}

    return {
        get = function(_, path)
            if path == 'sharding.roles' then
                return given.sharding_roles
            end

            if path == 'sharding.bucket_count' then
                return given.bucket_count
            end

            error(('двойник конфигурации не знает %s'):format(tostring(path)))
        end,
        info = function()
            return { hierarchy = { replicaset = given.replicaset or 'own', instance = given.instance } }
        end,
        instances = function()
            return given.instances or {}
        end,
        instance_uri = function(_, kind, opts)
            assert(kind == 'sharding', 'шлюз remote ходит под учёткой sharding')

            return (given.uris or {})[opts.instance]
        end,
    }
end

--- Учётки стенда без шардирования — начало `config.yaml`.
---
--- Клиент проверок, репликация и учётка `iproto.advertise.sharding`,
--- под которой прослойка и реплика с пересылкой записи зовут функции
--- узла с данными: ей нужны `lua_call` на них и права на спейс модели.
--- Права выданы глобально: на стенде спейсы есть на каждом узле с данными,
--- а предупреждение прослойки о спейсе, которого у неё нет, проверкам
--- не мешает.
local STAND_ACCESS = [[
credentials:
  users:
    client: { password: 'client-secret', roles: [super] }
    replicator: { password: 'replicator-secret', roles: [replication] }
    storage:
      password: 'storage-secret'
      privileges:
        - permissions: [execute]
          lua_call: [tnt_model_find, tnt_model_put, tnt_model_delete, tnt_model_select, tnt_model_count]
        - permissions: [read, write]
          spaces: [users, posts]
iproto:
  advertise:
    peer: { login: replicator }
    sharding: { login: storage }
]]

--- Конфигурация стенда без шардирования: учётки и группа `data`
--- с репликасетом core, где ведущий назначен вручную либо выбирается.
---
--- Узел core — имя и, вторым элементом, свои поля YAML без адреса:
--- `{ 'core-b', 'labels: { model_writes: forward }' }`; адрес iproto
--- берётся из порта узла. Без ведущего репликасет идёт с `failover:
--- election`: ведущего выбирают сами узлы, и после его зависания — нового.
---@param ports table<string, integer> Порт iproto по имени узла
---@param leader string|nil Ведущий core; пусто — выборы
---@param members table[] Узлы core по порядку
---@param rest string|nil Прочие группы — продолжение раздела `groups`
---@return string
function helper.core_config(ports, leader, members, rest)
    local lines = {
        STAND_ACCESS .. 'groups:',
        '  data:',
        ('    replication: { failover: %s }'):format(leader == nil and 'election' or 'manual'),
        '    replicasets:',
        '      core:',
    }

    if leader ~= nil then
        table.insert(lines, '        leader: ' .. leader)
    end

    table.insert(lines, '        instances:')

    for _, member in ipairs(members) do
        local fields = { ("iproto: { listen: [{ uri: '127.0.0.1:%d' }] }"):format(ports[member[1]]) }

        if member[2] ~= nil then
            table.insert(fields, 1, member[2])
        end

        table.insert(lines, ('          %s: { %s }'):format(member[1], table.concat(fields, ', ')))
    end

    table.insert(lines, rest or '')

    return table.concat(lines, '\n')
end

--- Узел с настоящим `box`: временный каталог, исходники по путям.
---
--- Узел — из оснастки: исходники в `package.loaded` абсолютными путями
--- (загрузчик `.rocks` иначе подсунул бы установленную копию) и строгий
--- режим глобалов, как в процессе проверок. Останавливает его
--- `helper.stop_node`.
---@param box_cfg table|nil
---@return table server
function helper.start_box(box_cfg)
    return testing.start_node({ modules = helper.MODULES, box_cfg = box_cfg })
end

---@class TntModelStandOptions
---@field script string|nil Сценарий узла от корня репозитория; по умолчанию — `test/node.lua`

--- Сценарий узла по умолчанию: модель, привязка по топологии и функции
--- узла с данными — руками, в самом сценарии.
local DEFAULT_SCRIPT = 'test/node.lua'

--- Поднимает узел стенда по готовому тексту `config.yaml`.
---
--- У оснастки узел одиночный (`start_node`): голый `box_cfg` и iproto
--- на unix-сокете. У стенда узлов несколько, в разных репликасетах, один
--- файл описывает всех, а net.box ходит на порт TCP под учёткой клиента, —
--- поэтому узел стенда поднимается здесь. Сценарий узла по умолчанию —
--- свой `test/node.lua`: он заводит модель, привязывает её по топологии
--- и публикует функции узла с данными; чужой стенд подставляет свой.
---
--- Узлы репликасета ждут друг друга при первом подъёме: стенд запускает
--- все узлы, не дожидаясь готовности, а ждёт каждый уже потом
--- (`server:wait_until_ready()`). Останавливает узел `helper.stop_node`.
---@param name string Имя инстанса
---@param config string Текст config.yaml
---@param port integer Порт iproto узла — для net.box
---@param options TntModelStandOptions|nil
---@return table server
local function start_member(name, config, port, options)
    local workdir = fio.tempdir()
    local given = options or {}

    testing.write_file(fio.pathjoin(workdir, 'config.yaml'), config)

    local rocks = project_root .. '/.rocks'
    local paths = {
        project_root .. '/?.lua',
        rocks .. '/share/tarantool/?.lua',
        rocks .. '/share/tarantool/?/init.lua',
    }

    -- Счётчик покрытия — собранная библиотека: без пути к ней
    -- дочерний узел считался бы непокрытым.
    local env = { TT_CONFIG = 'config.yaml', TT_INSTANCE_NAME = name, LUA_PATH = table.concat(paths, ';') .. ';' }

    env.LUA_CPATH = rocks .. '/lib/tarantool/?.so;'

    local server = t.Server:new({
        alias = name,
        command = arg[-1],
        args = { fio.pathjoin(project_root, given.script or DEFAULT_SCRIPT) },
        chdir = workdir,
        net_box_port = port,
        net_box_credentials = { user = 'client', password = 'client-secret' },
        setsearchroot = false,
        env = env,
    })

    server:start({ wait_until_ready = false })

    return server
end

--- Поднимает узлы стенда вместе и ждёт готовности каждого.
---@param config string Текст config.yaml
---@param ports table<string, integer> Порт iproto по имени узла
---@param names string[] Узлы по порядку
---@param options TntModelStandOptions|nil
---@return table<string, table> servers
function helper.start_stand(config, ports, names, options)
    local servers = {}

    for _, name in ipairs(names) do
        servers[name] = start_member(name, config, ports[name], options)
    end

    for _, name in ipairs(names) do
        servers[name]:wait_until_ready()
    end

    return servers
end

--- Останавливает узлы стенда и убирает их каталоги.
---@param servers table<string, table>
function helper.stop_stand(servers)
    for _, server in pairs(servers) do
        testing.stop_node(server)
    end
end

--- Ждёт, пока репликация между названными узлами встанет: у каждого
--- к каждому соседу идут и приём, и отдача.
---
--- Узлы стенда поднимаются разом и достраивают репликацию уже после
--- готовности: соединение соседа, пришедшее посреди проверки, сдвинуло бы
--- число соединений узла, хотя шлюз тут ни при чём.
---@param servers table<string, table>
---@param names string[]
function helper.await_replication(servers, names)
    for _, name in ipairs(names) do
        t.helpers.retrying({ timeout = 30, delay = 0.1 }, function()
            local stalled = servers[name]:exec(function()
                local lagging = {}

                for _, peer in pairs(box.info.replication) do
                    local upstream = (peer.upstream or {}).status
                    local downstream = (peer.downstream or {}).status

                    if peer.id ~= box.info.id and (upstream ~= 'follow' or downstream ~= 'follow') then
                        table.insert(lagging, ('%s: %s/%s'):format(peer.name, tostring(upstream), tostring(downstream)))
                    end
                end

                return lagging
            end)

            t.assert_equals(stalled, {}, ('%s: репликация ещё не встала'):format(name))
        end)
    end
end

--- Соединения iproto на узлах стенда по имени: шлюзов, клиента проверок,
--- репликации.
---
--- Соединение, закрытое клиентом, узел видит не сразу: сверяют число
--- с повтором. Репликация к этому мигу должна стоять
--- (`helper.await_replication`).
---@param servers table<string, table>
---@param names string[]
---@return table<string, integer>
function helper.connections(servers, names)
    local counted = {}

    for _, name in ipairs(names) do
        counted[name] = servers[name]:exec(function()
            return box.stat.net().CONNECTIONS.current
        end)
    end

    return counted
end

--- Пишет моделью на узле стенда из двадцати файберов, пока узел десять раз
--- перечитывает конфигурацию (`rebind` сценария узла), и считает отказы.
---
--- Писатели пишут, пока идут перечитывания: перед каждым из них главный
--- файбер уступает, и перечитывание застаёт записи в пути, как бы быстро
--- ни отвечал ведущий. Перечитывания идут парами: второе приходит через
--- миллисекунду, когда первые записи свежей привязки, ещё не знающей
--- ведущего, ждут ответа первого по имени узла, — и запись, которой
--- тот ответит `readonly`, пойдёт к узлу, с которым у закрытой уже
--- привязки соединения не было. Ключи — от `base`, у каждого писателя свои.
---@param server table Узел стенда
---@param base integer Начало ключей
---@return table seen `written` — сколько записей принято, `refusals` — тексты отказов
function helper.write_under_reloads(server, base)
    return server:exec(function(first)
        local fiber = require('fiber')
        ---@type any
        local User = rawget(_G, 'User')
        local seen = { written = 0, refusals = {} }
        local writers = 20
        local reloading = true
        local finished = 0

        for writer = 1, writers do
            fiber.create(function()
                local id = first + writer * 100000

                while reloading do
                    id = id + 1

                    local created, err = User.create({ id = id, name = 'Вера', age = 33 })

                    if created ~= nil then
                        seen.written = seen.written + 1
                    else
                        table.insert(seen.refusals, tostring(err))
                    end
                end

                finished = finished + 1
            end)
        end

        for step = 1, 10 do
            fiber.sleep(step % 2 == 0 and 0.001 or 0.02)
            rawget(_G, 'rebind')()
        end

        reloading = false

        while finished < writers do
            fiber.sleep(0.01)
        end

        return seen
    end, { base })
end

--- Публикует на узлах стенда функцию `aged(id, age)` — тело транзакции
--- из документа пакета: роутер зовёт её `callrw` в бакет ключа, и на узле
--- с данными `model.atomic` читает и пишет одной транзакцией. Ответ —
--- одна таблица: роутер отдаёт вызывающему только первое значение.
---@param servers table<string, table>
---@param names string[]
function helper.publish_aged(servers, names)
    for _, name in ipairs(names) do
        servers[name]:exec(function()
            local model = rawget(_G, 'model')
            ---@type any
            local User = rawget(_G, 'User')

            rawset(_G, 'aged', function(id, age)
                return model.atomic(function()
                    local user = assert(User.find(id))

                    user.age = age

                    return { age = assert(user:save()).age }
                end)
            end)
        end)
    end
end

--- Запись моделью на узле стенда, которая обязана лечь.
---@param server table Узел стенда
---@param id integer
function helper.created(server, id)
    server:exec(function(key)
        local created, err = rawget(_G, 'User').create({ id = key, name = 'Олег', age = 20 })

        assert(created, tostring(err))
    end, { id })
end

--- Сколько записей с ключом не меньше `base` лежит на узле.
---@param server table
---@param base integer
---@return integer
function helper.stored_from(server, base)
    return server:exec(function(first)
        return box.space.users.index.primary:count(first, { iterator = 'GE' })
    end, { base })
end

--- Удаляет на ведущем записи с ключом не меньше `base`: проверки,
--- которые идут следом, сверяют состав спейса целиком.
---@param server table Ведущий
---@param base integer
function helper.forget_from(server, base)
    server:exec(function(first)
        local keys = {}

        for _, stored in box.space.users.index.primary:pairs(first, { iterator = 'GE' }) do
            table.insert(keys, stored[1])
        end

        box.atomic(function()
            for _, key in ipairs(keys) do
                box.space.users:delete(key)
            end
        end)
    end, { base })
end

--- Почта записей обхода по порядку ключей; ложь — запись без почты.
---
--- Записи без почты вперемешку с остальными и почти половина всех:
--- при любом размере страницы какая-то из них её кончает.
local MAILS = { 'c@x', false, 'a@x', false, 'b@x', 'a@x', false, 'd@x', false }

--- Обходит на узле стенда индекс почты страницами 1, 3 и 7 — каждую
--- после последней записи прошлой: по убыванию знаками `<` и `<=`,
--- где записи без почты идут последними, и по возрастанию `>=`.
---
--- Записи с ключами от `base + 1` кладутся моделью и стираются в конце:
--- соседние проверки считают свои во всём кластере. Их записи без почты
--- стоят в том же индексе, поэтому обход сверяется с выборкой целиком,
--- а не с готовым списком. Курсор `<=` идёт через JSON — так клиент
--- возвращает последнюю запись страницы, — и пустая почта в нём `null`.
---@param server table Узел стенда
---@param base integer Начало ключей
---@return table seen `whole` — ключи выборки целиком по знаку, `walks` — ключи обхода по знаку и размеру: `'< 3'`
function helper.pages_by_email(server, base)
    return server:exec(function(first, mails)
        local json = require('json')
        ---@type any
        local User = rawget(_G, 'User')
        local bounds = { ['<'] = 'z', ['<='] = 'z', ['>='] = 'a' }
        local seen = { whole = {}, walks = {} }

        for offset, email in ipairs(mails) do
            assert(User.create({ id = first + offset, name = 'Почта ' .. offset, age = 40, email = email or nil }))
        end

        --- Ключи записей страницы в конец списка.
        local function append(keys, page)
            for _, row in ipairs(page) do
                table.insert(keys, row.id)
            end
        end

        for sign, bound in pairs(bounds) do
            seen.whole[sign] = {}
            append(seen.whole[sign], assert(User.where('email', sign, bound):limit(1000):all()))

            for _, size in ipairs({ 1, 3, 7 }) do
                local keys = {}
                ---@type any
                local last = nil
                local page

                repeat
                    local query = User.where('email', sign, bound):limit(size)

                    if last ~= nil and sign == '<=' then
                        query:after(json.decode(json.encode({ email = last.email or json.NULL, id = last.id })))
                    elseif last ~= nil then
                        query:after(last)
                    end

                    page = assert(query:all())
                    append(keys, page)
                    last = page[#page]
                until #page < size

                seen.walks[sign .. ' ' .. size] = keys
            end
        end

        for offset = 1, #mails do
            assert(User.delete(first + offset))
        end

        return seen
    end, { base, MAILS })
end

--- Сверяет обход страницами из `helper.pages_by_email` с выборкой целиком:
--- каждая запись ровно по разу и в порядке индекса.
---@param seen table Итог `helper.pages_by_email`
---@param base integer Начало ключей обхода
function helper.assert_pages_by_email(seen, base)
    for sign, whole in pairs(seen.whole) do
        for _, size in ipairs({ 1, 3, 7 }) do
            t.assert_equals(
                seen.walks[sign .. ' ' .. size],
                whole,
                ('%s страницами по %d'):format(sign, size)
            )
        end
    end

    --- Ключи обхода среди всех, сдвинутые к началу: порядок своих записей.
    local function own(keys)
        local shifted = {}

        for _, key in ipairs(keys) do
            if key > base then
                table.insert(shifted, key - base)
            end
        end

        return shifted
    end

    -- По убыванию записи без почты — последними, равные — по убыванию
    -- ключа; по возрастанию их нет вовсе.
    t.assert_equals(own(seen.whole['<']), { 8, 1, 5, 6, 3, 9, 7, 4, 2 })
    t.assert_equals(own(seen.whole['<=']), { 8, 1, 5, 6, 3, 9, 7, 4, 2 })
    t.assert_equals(own(seen.whole['>=']), { 3, 6, 5, 1, 8 })
end

return helper
