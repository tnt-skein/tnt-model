--- Общие средства проверок моделей.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.validate`, `tnt.must`, `tnt.external` — берутся
--- из `.rocks` обычным `require`: проверяется этот пакет, а не они.
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
    { name = 'tnt.model.shape', path = 'tnt/model/shape.lua' },
    { name = 'tnt.model.order', path = 'tnt/model/order.lua' },
    { name = 'tnt.model.check', path = 'tnt/model/check.lua' },
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
--- Права выданы глобально: на стенде спейс есть на каждом узле с данными,
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
          spaces: [users]
iproto:
  advertise:
    peer: { login: replicator }
    sharding: { login: storage }
]]

--- Конфигурация стенда без шардирования: учётки и группа `data`
--- с репликасетом core, где ведущий назначен вручную.
---
--- Узел core — имя и, вторым элементом, свои поля YAML без адреса:
--- `{ 'core-b', 'labels: { model_writes: forward }' }`; адрес iproto
--- берётся из порта узла.
---@param ports table<string, integer> Порт iproto по имени узла
---@param leader string Ведущий core
---@param members table[] Узлы core по порядку
---@param rest string|nil Прочие группы — продолжение раздела `groups`
---@return string
function helper.core_config(ports, leader, members, rest)
    local lines = {
        STAND_ACCESS .. 'groups:',
        '  data:',
        '    replication: { failover: manual }',
        '    replicasets:',
        '      core:',
        '        leader: ' .. leader,
        '        instances:',
    }

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

return helper
