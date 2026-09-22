--- Привязка моделей приложения к шлюзу узла — при применении конфигурации.
---
--- Привязка собирается целиком до того, как отпущена прежняя:
--- шлюз заводится, топология сверяется с моделями, функции узла
--- с данными готовы, — и только потом модели переключаются на новый
--- шлюз (`attach`). Сорвавшаяся сборка ничего не меняет: узел отвечает
--- прежним применением.
---
--- Прежняя привязка отпускается после переключения (`close`), и вызов,
--- начатый на её шлюзе, доходит до ответа: шлюз `remote` новых обращений
--- не принимает, а соединения закрывает, когда вызовов в пути
--- не останется. Оборви он их сразу — запись, которую ведущий уже
--- принял, вызывающий получил бы отказом, и каждое перечитывание под
--- нагрузкой стоило бы отказов.
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

--- Отказ привязки источника `sql` без шлюза: текст называет, откуда его взять.
local NO_SQL_GATEWAY = 'источник sql: шлюза нет — его приносит тот, кто собирает привязку: '
    .. 'model.bind(модели, раздел, { sql = orm.gateway(db) })'

local Module = {}

---@class TntModelBinding
---@field source string|nil Шлюз: local, sharded, remote, sql; пусто — моделей нет
---@field topology TntModelTopology|nil
---@field gateway TntModelGateway|nil
---@field models TntModel[]
---@field functions table<string, function> Функции узла с данными к публикации
---@field attach fun() Переключить модели на этот шлюз
---@field close fun() Отпустить: модели отвязать, соединения закрыть, когда вызовы в пути кончатся
---@field status fun(): table

--- Почему у моделей нет шлюза после `close`: узел конфигурацию применил
--- и отпустил — роль остановлена либо новая привязка обошлась без модели.
local CLOSED = 'привязка закрыта, новой нет'

--- Действующая привязка процесса.
---@type TntModelBinding|nil
local current = nil

--- Закрыта ли действующая привязка процесса, а новой после неё нет.
local released = false

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

--- Место поля среди полей индекса; пусто — поля в индексе нет.
---@param index TntModelIndex
---@param name string
---@return integer|nil
local function place_in(index, name)
    for position, part in ipairs(index.parts) do
        if part == name then
            return position
        end
    end

    return nil
end

--- Сверяет уникальные индексы моделей узла с ролью vshard.
---
--- `box` держит уникальность в своём спейсе, то есть внутри репликасета.
--- По кластеру индекс уникален, только когда записи с равными значениями
--- индекса лежат в одном бакете: среди его полей есть ключ шардирования —
--- равные значения дают равный ключ, а равный ключ — один бакет. Место
--- ключа в индексе не важно, важно, что он там есть. Без него тот же
--- `login` у ключей из разных репликасетов ложится дважды молча, а `where`
--- отдаёт обе записи; поэтому такая модель — ошибка привязки, а не отказ
--- на первой записи.
---
--- Модель без ключа шардирования не сверяется: на роутере её не пускает
--- `gateway_of`, а на хранилище её данные не шардированы — у каждого
--- репликасета свои, и делить уникальность им не с кем.
---@param models TntModel[]
local function unique_across(models)
    for _, model in ipairs(models) do
        local shape = model._shape

        if shape.bucket_of ~= nil then
            for _, index in ipairs(shape.indexes) do
                if index.unique and place_in(index, shape.bucket_of) == nil then
                    fail(
                        (
                            'модель %s: уникальность индекса %s в шардированном кластере не гарантирована — '
                            .. 'среди его полей нет ключа шардирования %s'
                        ):format(shape.space, index.name, shape.bucket_of)
                    )
                end
            end
        end
    end
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
---@param sources table<string, TntModelGateway> Шлюзы, которые принёс вызывающий
---@return TntModelGateway
local function gateway_of(place, models, sources)
    if place.source == topology.SQL then
        if sources.sql == nil then
            fail(NO_SQL_GATEWAY)
        end

        return sources.sql
    end

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

        -- Узел «и роутер, и хранилище» держит часть бакетов сам: в транзакции
        -- модели идут к ним на месте, мимо своего же роутера.
        ---@type TntModelGateway|nil
        local here = nil

        if place.sharded then
            here = local_of(place)
        end

        return sharded_gateway.new({ timeout = place.timeout, here = here })
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
---
--- Шлюз к базе SQL пакет не заводит сам: шлюз живёт вне пакета, над
--- драйвером приложения, и его приносит вызывающий — `sources.sql`.
---@param models any Модели приложения
---@param settings TntModelSettings Раздел `models` настроек роли
---@param sources table<string, TntModelGateway>|nil Шлюзы извне: `sql`
---@return TntModelBinding
function Module.new(models, settings, sources)
    local listed = checked(models or {})

    ---@type TntModelBinding
    ---@diagnostic disable-next-line: missing-fields
    local binding = { models = listed, functions = {} }

    if listed[1] ~= nil then
        local place = topology.resolve(settings)

        -- Роль vshard у узла: роутер — источник sharded, хранилище —
        -- признак sharded. У источника sql данные в базе, и уникальность
        -- держит она.
        if place.source ~= topology.SQL and (place.source == 'sharded' or place.sharded) then
            unique_across(listed)
        end

        binding.source = place.source
        binding.topology = place
        binding.gateway = gateway_of(place, listed, sources or {})

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
    --- привязкой, остаётся при ней. Шлюз закрывается без обрыва вызовов
    --- в пути.
    function binding.close()
        for _, model in ipairs(listed) do
            if model.bound() ~= nil and model._gateway() == binding.gateway then
                model._bind(nil, CLOSED)
            end
        end

        if binding.gateway ~= nil then
            binding.gateway.close()
        end

        if current == binding then
            current = nil
            released = true
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

--- Действующая привязка процесса; пусто — узел ещё не применил
--- конфигурацию либо закрыл привязку, и тогда вторым значением идёт
--- причина: `model.atomic` после остановки роли не должен звать её
--- неприменённой конфигурацией.
---@return TntModelBinding|nil
---@return string|nil reason Причина, когда привязку закрыли
function Module.current()
    if current == nil and released then
        return nil, CLOSED
    end

    return current
end

return Module
