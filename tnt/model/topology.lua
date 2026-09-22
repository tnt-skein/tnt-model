--- Топология узла: какой шлюз нужен моделям и держит ли узел данные.
---
--- Две оси, и они независимы: есть ли у узла vshard и есть ли у него
--- свои данные. Отсюда четыре сочетания и три шлюза:
---
---   * без шардирования, с данными — одиночный узел, ведущий и реплики
---     репликасета: `local`;
---   * без шардирования, без данных — узел-прослойка, который ходит
---     в репликасет по net.box: `remote`, и это единственное сочетание,
---     которое узел обязан объявить сам (`source = 'remote'`) — без vshard
---     узел с данными и узел без данных по ролям неотличимы;
---   * шардирование без выделенного роутера — узел «и роутер,
---     и хранилище»: `sharded` через свой же роутер vshard;
---   * шардирование с выделенными роутерами: на роутере `sharded`,
---     на хранилище `local` с полем шардирования.
---
--- Правило: есть роль router vshard → `sharded`; иначе узел держит данные
--- → `local`; иначе — `remote`, и адрес репликасета обязан быть назван.
--- Раздел `models` настроек роли перебивает правило явно (`source`),
--- а противоречие между ним и ролями узла — ошибка привязки.
---
--- Вторая настройка раздела — `writes`: что узел с данными без
--- шардирования делает с записью, которую сам принять не может.
--- `local` — отказ `readonly`; `forward` — пересылка ведущему своего
--- репликасета путём шлюза `remote`. Пересылка включается только явно:
--- ей нужна учётка `iproto.advertise.sharding` с правами на функции
--- `tnt_model_*`, а запись, ушедшая по сети, на самой реплике видна лишь
--- после журнала — это решение оператора, а не умолчание.

local validate = require('tnt.validate')

local world = require('tnt.model.world')

--- Отказ без места вызова: текст уходит в alerts.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Раздел настроек роли, принадлежащий моделям.
Module.SECTION = 'models'

--- Срок обращения к чужому узлу, секунды, если раздел его не задал.
Module.DEFAULT_TIMEOUT = 5

--- Источник по правилу.
Module.AUTO = 'auto'

--- Запись только на месте: реплика отвечает `readonly`.
Module.WRITES_LOCAL = 'local'

--- Запись, которую узел не принял сам, уходит ведущему своего репликасета.
Module.WRITES_FORWARD = 'forward'

---@class TntModelSettings Раздел `models` настроек роли, проверенный
---@field source string auto, local, sharded либо remote
---@field replicaset string|nil Репликасет с данными — для remote
---@field timeout number Срок обращения к чужому узлу, секунды
---@field writes string local либо forward — пересылка записи с реплики ведущему

---@class TntModelTopology
---@field source string Шлюз: local, sharded либо remote
---@field sharded boolean Узел — хранилище vshard: в кортеже есть поле шардирования
---@field serves boolean Держит ли узел данные — тогда публикуются функции tnt_model_*
---@field bucket_count integer|nil Число бакетов — на хранилище vshard
---@field timeout number
---@field replicaset string|nil Куда ходит шлюз remote: репликасет с данными прослойки либо свой — при пересылке
---@field peers TntModelRemotePeer[]|nil Узлы этого репликасета; при пересылке — без самого узла
---@field writes string|nil forward — запись с реплики уходит ведущему; пусто — пересылки нет

--- Схема раздела `models`.
local SCHEMA = {
    source = validate.string({
        one_of = { Module.AUTO, 'local', 'sharded', 'remote' },
        default = Module.AUTO,
        title = 'источник',
        gender = 'm',
    }),
    replicaset = validate.string({ min = 1, optional = true, title = 'репликасет', gender = 'm' }),
    timeout = validate.number({ min = 0.001, default = Module.DEFAULT_TIMEOUT, title = 'срок', gender = 'm' }),
    writes = validate.string({
        one_of = { Module.WRITES_LOCAL, Module.WRITES_FORWARD },
        default = Module.WRITES_LOCAL,
        title = 'запись',
        gender = 'f',
    }),
}

--- Проверенный раздел `models`; отсутствующий — умолчания.
---@param section any
---@return TntModelSettings
function Module.settings(section)
    if section ~= nil and type(section) ~= 'table' then
        fail(
            ('раздел %s должен быть таблицей, получено %s'):format(
                Module.SECTION,
                type(section)
            )
        )
    end

    local settings, err = validate.settings(section or {}, SCHEMA)

    if settings == nil then
        fail(('раздел %s: %s'):format(Module.SECTION, err))
    end

    return settings
end

--- Значение конфигурации ядра; пусто — вне кластерной конфигурации.
---@param path string
---@return any
local function configured(path)
    local ok, value = pcall(function()
        return world.current().config():get(path)
    end)

    if not ok then
        return nil
    end

    return value
end

--- Роли шардирования узла: router, storage.
---@return table<string, boolean>
local function sharding_roles()
    local roles = {}

    for _, role in ipairs(configured('sharding.roles') or {}) do
        roles[role] = true
    end

    return roles
end

--- Узел — хранилище vshard: в его кортежах есть поле шардирования.
---
--- Спрашивается и шагом миграции: он выполняется на узле, и решает
--- по узлу, а не по объявлению модели.
---@return boolean
function Module.vshard_storage()
    return sharding_roles().storage == true
end

--- Имена узлов репликасета, кроме названного.
---@param config table Конфигурация ядра
---@param replicaset string|nil
---@param except string|nil Имя узла, которого в списке быть не должно
---@return string[]
local function members(config, replicaset, except)
    local names = {}

    for name, place in pairs(config:instances()) do
        if place.replicaset_name == replicaset and name ~= except then
            table.insert(names, name)
        end
    end

    table.sort(names)

    return names
end

--- Узлы с адресом и учёткой, под которой к ним ходит шлюз `remote`.
---
--- Адрес и учётка — `iproto.advertise.sharding`: та же, под которой
--- узлы кластера ходят друг к другу; ей выдаётся `lua_call` на функции
--- `tnt_model_*`. Без неё ходить не под кем — это ошибка привязки.
---@param config table Конфигурация ядра
---@param what string Кто просит узлы — начало текста отказа
---@param names string[]
---@return TntModelRemotePeer[]
local function addressed(config, what, names)
    local peers = {}

    for _, name in ipairs(names) do
        local address = config:instance_uri('sharding', { instance = name })

        if type(address) ~= 'table' or address.login == nil then
            fail(
                ('%s: у узла %s нет учётки — задайте iproto.advertise.sharding'):format(
                    what,
                    name
                )
            )
        end

        table.insert(peers, { name = name, uri = address.uri, login = address.login, password = address.password })
    end

    return peers
end

--- Узлы репликасета с данными для шлюза `remote`.
---@param replicaset string
---@return TntModelRemotePeer[]
local function peers_of(replicaset)
    local config = world.current().config()
    local own = config:info().hierarchy.replicaset

    if own == replicaset then
        fail(
            ('источник remote: репликасет %s — свой, данные были бы на месте'):format(
                replicaset
            )
        )
    end

    local names = members(config, replicaset, nil)

    if names[1] == nil then
        fail(
            ('источник remote: репликасета %s нет в конфигурации кластера'):format(
                replicaset
            )
        )
    end

    return addressed(config, 'источник remote', names)
end

--- Соседи узла по репликасету — куда реплика пересылает запись.
---
--- Пересылка — только у узла с данными без vshard: прослойка и так пишет
--- на ведущем, а у vshard запись ходит через роутер, и ведущий
--- репликасета хранилища принял бы её мимо него. Себя в списке нет:
--- узел, отвергший запись сам, спрашивать незачем.
---@param source string Шлюз узла
---@param roles table<string, boolean> Роли шардирования узла
---@return string replicaset Свой репликасет
---@return TntModelRemotePeer[] peers
local function neighbours_of(source, roles)
    if source == 'remote' then
        fail(
            'пересылка записи: у прослойки данных нет — шлюз remote и так пишет на ведущем'
        )
    end

    if roles.router or roles.storage then
        fail(
            'пересылка записи: у узла с ролью vshard запись ходит через роутер'
        )
    end

    local config = world.current().config()
    local place = config:info().hierarchy
    local names = members(config, place.replicaset, place.instance)

    if names[1] == nil then
        fail(
            ('пересылка записи: у узла %s нет соседей по репликасету %s'):format(
                tostring(place.instance),
                tostring(place.replicaset)
            )
        )
    end

    return place.replicaset, addressed(config, 'пересылка записи', names)
end

--- Топология узла по его ролям и разделу `models`.
---@param settings TntModelSettings
---@return TntModelTopology
function Module.resolve(settings)
    local roles = sharding_roles()
    local source = settings.source

    if source == Module.AUTO then
        source = roles.router and 'sharded' or 'local'
    end

    if source == 'sharded' and not roles.router then
        fail('источник sharded: у узла нет роли router vshard')
    end

    if source == 'local' and roles.router and not roles.storage then
        fail('источник local: роутер vshard данных не держит')
    end

    if source == 'remote' and (roles.router or roles.storage) then
        fail('источник remote: у узла с ролью vshard данные ходят через vshard')
    end

    local topology = {
        source = source,
        sharded = roles.storage == true,
        serves = source ~= 'remote' and not (roles.router and not roles.storage),
        bucket_count = roles.storage and configured('sharding.bucket_count') or nil,
        timeout = settings.timeout,
    }

    if settings.writes == Module.WRITES_FORWARD then
        topology.writes = Module.WRITES_FORWARD
        topology.replicaset, topology.peers = neighbours_of(source, roles)
    end

    if source == 'remote' then
        if settings.replicaset == nil then
            fail('источник remote: назовите replicaset с данными')
        end

        topology.replicaset = settings.replicaset
        topology.peers = peers_of(settings.replicaset)
    end

    return topology
end

return Module
