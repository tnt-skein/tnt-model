--- Привязка моделей приложения к шлюзу узла — при применении конфигурации.
---
--- Привязка собирается целиком до того, как отпущена прежняя:
--- шлюз заводится, топология сверяется с моделями, функции узла
--- с данными готовы, — и только потом модели переключаются на новый
--- шлюз (`attach`). Сорвавшаяся сборка ничего не меняет: узел отвечает
--- прежним применением.
---
--- Привязка одна на процесс, как и место узла в кластере: `model.atomic`
--- спрашивает у неё шлюз. Список моделей при этом принадлежит
--- приложению: белый список функций узла с данными — ровно его модели.
---
--- Функции узла с данными отвечают только шлюзом `local`, даже когда
--- модели узла пересылают запись ведущему (`writes = 'forward'`): вызов
--- по `lua_call` приходит от прослойки, роутера или пересылающей реплики,
--- и пересылка в ответ на него гоняла бы запись по кругу между двумя
--- репликами до срока. Реплика отвечает им `readonly`, и шлюз `remote`
--- вызывающего идёт к следующему узлу.

local entity = require('tnt.model.entity')
local forward_gateway = require('tnt.model.gateway.forward')
local local_gateway = require('tnt.model.gateway.local')
local remote_gateway = require('tnt.model.gateway.remote')
local serve = require('tnt.model.serve')
local sharded_gateway = require('tnt.model.gateway.sharded')
local topology = require('tnt.model.topology')

--- Отказ без места вызова: текст уходит в alerts.
local fail = require('tnt.must.fail').raise

local Module = {}

---@class TntModelBinding
---@field source string|nil Шлюз: local, sharded, remote; пусто — моделей нет
---@field topology TntModelTopology|nil
---@field gateway TntModelGateway|nil
---@field models TntModel[]
---@field functions table<string, function> Функции узла с данными к публикации
---@field attach fun() Переключить модели на этот шлюз
---@field close fun() Отпустить: модели отвязать, соединения закрыть
---@field status fun(): table

--- Действующая привязка процесса.
---@type TntModelBinding|nil
local current = nil

--- Проверенный список моделей: каждая — модель, спейсы без повторов.
---@param models any
---@return TntModel[]
local function checked(models)
    local seen = {}

    for index, model in ipairs(models) do
        if not entity.is(model) then
            fail(('модели: запись №%d — не модель, а %s'):format(index, type(model)))
        end

        if seen[model.space] then
            fail(('модели: спейс %s объявлен дважды'):format(model.space))
        end

        seen[model.space] = true
    end

    return models
end

--- Шлюз `local` к данным узла.
---@param place TntModelTopology
---@return TntModelGateway
local function local_of(place)
    return local_gateway.new({ sharded = place.sharded, bucket_count = place.bucket_count })
end

--- Шлюз `remote` к узлам, которые назвала топология.
---@param place TntModelTopology
---@return TntModelGateway
local function remote_of(place)
    return remote_gateway.new({
        replicaset = assert(place.replicaset),
        peers = assert(place.peers),
        timeout = place.timeout,
    })
end

--- Шлюз по топологии.
---@param place TntModelTopology
---@param models TntModel[]
---@return TntModelGateway
local function gateway_of(place, models)
    if place.source == 'sharded' then
        for _, model in ipairs(models) do
            if model._shape.bucket_of == nil then
                fail(
                    ('модель %s без ключа шардирования: в шардированном кластере нужен model.bucket_of(поле)'):format(
                        model.space
                    )
                )
            end
        end

        return sharded_gateway.new({ timeout = place.timeout })
    end

    if place.source == 'remote' then
        return remote_of(place)
    end

    if place.writes == topology.WRITES_FORWARD then
        return forward_gateway.new(local_of(place), remote_of(place))
    end

    return local_of(place)
end

--- Собирает привязку, ничего ещё не переключая.
---@param models any Модели приложения
---@param settings TntModelSettings Раздел `models` настроек роли
---@return TntModelBinding
function Module.new(models, settings)
    local listed = checked(models or {})

    ---@type TntModelBinding
    ---@diagnostic disable-next-line: missing-fields
    local binding = { models = listed, functions = {} }

    if listed[1] ~= nil then
        local place = topology.resolve(settings)

        binding.source = place.source
        binding.topology = place
        binding.gateway = gateway_of(place, listed)

        if place.serves then
            binding.functions = serve.functions(listed, local_of(place))
        end
    end

    function binding.attach()
        for _, model in ipairs(listed) do
            model._bind(binding.gateway)
        end

        current = binding
    end

    --- Отвязывает только свои модели: модель, уже переключённая новой
    --- привязкой, остаётся при ней.
    function binding.close()
        for _, model in ipairs(listed) do
            if model.bound() ~= nil and model._gateway() == binding.gateway then
                model._bind(nil)
            end
        end

        if binding.gateway ~= nil then
            binding.gateway.close()
        end

        if current == binding then
            current = nil
        end
    end

    function binding.status()
        local spaces = {}

        for _, model in ipairs(listed) do
            table.insert(spaces, model.space)
        end

        local place = binding.topology or {}

        return {
            source = binding.source,
            sharded = place.sharded,
            serves = place.serves,
            writes = place.writes,
            spaces = spaces,
        }
    end

    return binding
end

--- Действующая привязка процесса; пусто — узел ещё не применил конфигурацию.
---@return TntModelBinding|nil
function Module.current()
    return current
end

return Module
