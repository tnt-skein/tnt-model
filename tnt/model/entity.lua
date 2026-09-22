--- Модель: класс с функциями доступа над формой записи и шлюзом.
---
--- Функции зовутся точкой — `User.find(7)`, `User.create(input)`, — и
--- никакой магии за ними нет: это обычные замыкания над формой, и проверка
--- типов их видит. Где данные, модель не знает: шлюз ей привязывает
--- приложение при применении конфигурации, а без шлюза обращение к данным —
--- ошибка программиста «модель не привязана» с причиной: до первой
--- привязки узел ещё не применил конфигурацию, после `close` — привязку
--- отпустили.
---
--- Хуки идут здесь, у вызывающего, вокруг обращения к шлюзу; отметки
--- времени и признак мягкого удаления ставит узел с данными — шлюз
--- `local`. Запись, прочитанная у модели с хуками, помнит, какой её
--- прочитали: это `original` хуков изменения, и по нему `save` отличает
--- изменение от создания.

local check = require('tnt.model.check')
local factory = require('tnt.model.factory')
local hook = require('tnt.model.hook')
local migration = require('tnt.model.migration')
local query = require('tnt.model.query')
local record = require('tnt.model.record')
local scopes = require('tnt.model.scope')
local shapes = require('tnt.model.shape')
local stamps = require('tnt.model.stamp')

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Метка модели: по ней привязка отличает модель от чужой таблицы.
local MARK = {}

--- Почему у модели нет шлюза, пока причину не назвал тот, кто её отвязал.
local NOT_APPLIED = 'узел ещё не применил конфигурацию'

--- Событие хуков по способу удаления: восстановление — своё, мягкое
--- и окончательное удаление — одно событие.
---@param mode string|nil
---@return string
local function removal_of(mode)
    return mode == stamps.RESTORE and hook.RESTORE or hook.DELETE
end

---@class TntModel Модель: доступ к записям одного спейса
---@field space string Имя спейса
---@field validate fun(input: any): TntModelRecord|nil, TntModelFailure|nil Запись по форме, без записи в хранилище
---@field find fun(key: any): TntModelRecord|nil, TntModelFailure|nil Запись по ключу; пусто — нет
---@field create fun(input: any): TntModelRecord|nil, TntModelFailure|nil Проверка и вставка; занятый ключ — conflict
---@field delete fun(key: any): boolean|nil, TntModelFailure|nil Удаление по ключу; у модели с deleted_at — мягкое
---@field force_delete fun(key: any): boolean|nil, TntModelFailure|nil Удаление мимо мягкого
---@field restore fun(key: any): boolean|nil, TntModelFailure|nil Восстановление мягко удалённой записи
---@field where fun(field: string, op: string, value: any): TntModelQuery Выборка по индексу
---@field scan fun(): TntModelQuery Полный обход страницами
---@field factory fun(overrides: table|nil): TntModelRecord Запись для проверок, не сохранённая
---@field migration fun(): fun(box: table) Шаг схемы
---@field bound fun(): string|nil Имя привязанного шлюза; пусто — не привязана
---@field _shape TntModelShape
---@field _class table Метатаблица записей
---@field _bind fun(gateway: TntModelGateway|nil, reason: string|nil) Шлюз; пусто — отвязать, reason — почему
---@field _gateway fun(): TntModelGateway
---@field _key fun(key: any): any[]|nil, TntModelFailure|nil
---@field _values fun(input: any): table|nil, TntModelFailure|nil
---@field _write fun(input: any, mode: string, was: TntModelRecord?, into: TntModelRecord?): TntModelRecord?, any
---@field _removed fun(target: TntModelRecord, mode: string|nil): boolean|nil, TntModelFailure|nil
---@field _soft fun(what: string)
---@field _wrap fun(values: table): TntModelRecord
---@field _loaded fun(values: table, target: TntModelRecord|nil): TntModelRecord
---@field _original fun(target: TntModelRecord): TntModelRecord|nil
---@field _scope fun(name: string, ...: any): TntModelCondition[]|nil, TntModelFailure|nil
---@field _rule fun(name: string, exact: boolean): TntValidateRule Правило значения выборки: искомого либо границы
---@field _query fun(spec: any): TntModelQuerySpec|nil, TntModelFailure|nil

--- Модель ли это.
---@param value any
---@return boolean
function Module.is(value)
    return getmetatable(value) == MARK
end

--- Заводит модель по объявлению.
---@param spec table Объявление: space, fields, indexes, rules, methods, factory
---@return TntModel
function Module.new(spec)
    local shape = shapes.of(spec)
    local schema = check.schema_of(shape)
    local key_rules = check.key_rules_of(shape)
    local exact_rules, bound_rules = check.query_rules_of(shape)

    ---@type TntModelGateway|nil
    local gateway = nil

    --- Причина в тексте отказа модели без шлюза.
    local unbound = NOT_APPLIED

    local sequence = 0

    --- Записи, какими их прочитали: запись → копия. Слабые ключи: запись,
    --- которую бросили, копию за собой не держит.
    ---@type table<TntModelRecord, TntModelRecord>
    local originals = setmetatable({}, { __mode = 'k' })

    --- Условия областей, объявленных списком: проверены при объявлении.
    ---@type table<string, TntModelCondition[]>
    local fixed = {}

    ---@type TntModel
    ---@diagnostic disable-next-line: missing-fields
    local model = setmetatable({ space = shape.space, _shape = shape }, MARK)

    model._class = record.class_of(model)

    --- Отвязанная после `close` модель называет эту причину: «узел ещё
    --- не применил конфигурацию» после остановки роли уводил бы искать
    --- поломку применения, которой не было.
    function model._bind(next_gateway, reason)
        gateway = next_gateway
        unbound = reason or NOT_APPLIED
    end

    function model._gateway()
        if gateway == nil then
            fail(('модель %s не привязана: %s'):format(shape.space, unbound))
        end

        return gateway
    end

    function model._key(key)
        return check.key_of(shape, key_rules, key)
    end

    function model._values(input)
        return check.values_of(shape, schema, input)
    end

    function model._wrap(values)
        return record.wrap(model._class, values)
    end

    --- Запись из хранилища: новая либо та же, заполненная заново.
    ---
    --- У модели с хуками запись запоминает, какой её прочитали, — копией:
    --- поля самой записи вызывающий вправе менять до `save`.
    function model._loaded(values, target)
        local loaded = target

        if loaded == nil then
            loaded = model._wrap(values)
        else
            for key in pairs(loaded) do
                loaded[key] = nil
            end

            for key, value in pairs(values) do
                loaded[key] = value
            end
        end

        if shape.hooked then
            originals[loaded] = model._wrap(table.copy(values))
        end

        return loaded
    end

    function model._original(target)
        return originals[target]
    end

    function model._rule(name, exact)
        return (exact and exact_rules or bound_rules)[name]
    end

    function model._query(wire)
        return query.checked(model, wire)
    end

    --- Значения после хука «до»: хука нет — те же; отказ — пусто и отказ.
    ---
    --- Хук получает запись после проверки и вправе её поправить;
    --- поправленное проверяется ещё раз — в спейс ложится только то,
    --- что прошло форму.
    ---@param event string
    ---@param values table
    ---@param original TntModelRecord|nil
    ---@return table|nil values
    ---@return TntModelFailure|nil err
    local function before(event, values, original)
        local run = hook.before(shape, event)

        if run == nil then
            return values
        end

        local draft = model._wrap(values)
        local refusal = hook.refusal(shape, event, run(draft, original))

        if refusal ~= nil then
            return nil, refusal
        end

        return model._values(draft)
    end

    function model._write(input, mode, original, target)
        local event = hook.event_of(original)
        local values, err = model._values(input)

        if values ~= nil then
            values, err = before(event, values, original)
        end

        if values == nil then
            return nil, err
        end

        local stored, refused = model._gateway().put(shape, values, mode)

        if stored == nil then
            return nil, refused
        end

        local written = model._loaded(stored, target)

        hook.after(shape, event, written, original)

        return written
    end

    --- Удаление, окончательное удаление либо восстановление записи.
    ---
    --- Хук «до» получает саму запись, «после» — её же, заполненную тем,
    --- что осталось в хранилище: у мягкого удаления — с отметкой. Удаляет
    --- шлюз по ключу записи; ложь — удалять либо восстанавливать нечего.
    ---
    --- Ключ записи проверяется, как ключ `delete`: поля записи вызывающий
    --- вправе испортить, и негодный ключ — отказ `invalid`, а не
    --- исключение из глубины `box`.
    function model._removed(target, mode)
        local parts, invalid = model._key(check.key_from(shape, target))

        if parts == nil then
            return nil, invalid
        end

        local event = removal_of(mode)
        local run = hook.before(shape, event)

        if run ~= nil then
            local refusal = hook.refusal(shape, event, run(target))

            if refusal ~= nil then
                return nil, refusal
            end
        end

        local left, err = model._gateway().delete(shape, parts, mode)

        if left == nil then
            return nil, err
        end

        if left == false then
            return false
        end

        -- Мягкое удаление и восстановление отдают запись, какой она легла.
        if type(left) == 'table' then
            model._loaded(left, target)
        end

        hook.after(shape, event, target, nil)

        return true
    end

    function model._soft(what)
        if shape.stamps[stamps.DELETED] == nil then
            fail(
                ('модель %s: %s — только у модели с мягким удалением, model.deleted_at()'):format(
                    shape.space,
                    what
                )
            )
        end
    end

    function model._scope(name, ...)
        local declared = shape.scopes[name]

        if declared == nil then
            local names = {}

            for known in pairs(shape.scopes) do
                table.insert(names, known)
            end

            table.sort(names)

            fail(
                ('модель %s: области %s нет; объявлены: %s'):format(
                    shape.space,
                    tostring(name),
                    names[1] and table.concat(names, ', ') or 'ни одной'
                )
            )
        end

        if type(declared) == 'function' then
            return scopes.conditions_of(shape, model._rule, name, declared(...))
        end

        if select('#', ...) > 0 then
            fail(
                ('модель %s: область %s объявлена списком и аргументов не ждёт'):format(
                    shape.space,
                    name
                )
            )
        end

        return fixed[name]
    end

    function model.validate(input)
        local values, err = model._values(input)

        if values == nil then
            return nil, err
        end

        return model._wrap(values)
    end

    function model.find(key)
        local parts, err = model._key(key)

        if parts == nil then
            return nil, err
        end

        local values, refused = model._gateway().find(shape, parts)

        -- Мягко удалённая запись поиском по ключу не находится: её видит
        -- только выборка `with_deleted` либо `only_deleted`.
        if values == nil or values[shape.stamps[stamps.DELETED]] ~= nil then
            return nil, refused
        end

        return model._loaded(values)
    end

    function model.create(input)
        return model._write(input, 'insert', nil, nil)
    end

    --- Удаление по ключу.
    ---
    --- Без хуков события ключ уходит шлюзу сразу. С хуками запись
    --- сначала читается: хуку нужна запись, а не ключ. Не нашлась —
    --- ложь, и хук не зовётся: удалять нечего.
    ---@param key any
    ---@param mode string|nil
    ---@return boolean|nil removed
    ---@return TntModelFailure|nil err
    local function removed_by_key(key, mode)
        local parts, err = model._key(key)

        if parts == nil then
            return nil, err
        end

        if not hook.watched(shape, removal_of(mode)) then
            local left, refused = model._gateway().delete(shape, parts, mode)

            if left == nil then
                return nil, refused
            end

            return left ~= false
        end

        local values, refused = model._gateway().find(shape, parts)

        if refused ~= nil then
            return nil, refused
        end

        if values == nil then
            return false
        end

        return model._removed(model._loaded(values), mode)
    end

    function model.delete(key)
        return removed_by_key(key, nil)
    end

    function model.force_delete(key)
        return removed_by_key(key, stamps.FORCE)
    end

    function model.restore(key)
        model._soft('restore')

        return removed_by_key(key, stamps.RESTORE)
    end

    function model.where(field, op, value)
        return query.where(model, field, op, value)
    end

    function model.scan()
        return query.scan(model)
    end

    --- Запись для проверок: фабрика обязана собрать годную запись,
    --- иначе это ошибка объявления, а не данных.
    function model.factory(overrides)
        sequence = sequence + 1

        local built, err = model.validate(factory.values_of(shape, sequence, overrides))

        if built == nil then
            fail(
                ('фабрика модели %s собрала негодную запись: %s'):format(
                    shape.space,
                    tostring(err)
                )
            )
        end

        return built
    end

    --- Шаг смотрит на шлюз в миг, когда идёт, а не когда его взяли:
    --- шаги регистрируются при загрузке, а привязка приходит позже.
    function model.migration()
        return migration.step(shape, function()
            return gateway
        end)
    end

    function model.bound()
        return gateway ~= nil and gateway.kind or nil
    end

    for name, declared in pairs(shape.scopes) do
        if type(declared) == 'table' then
            local conditions, err = scopes.conditions_of(shape, model._rule, name, declared)

            if conditions == nil then
                ---@cast err TntModelFailure
                local field, reason = next(err.fields or {})

                fail(('модель %s: область %s: %s — %s'):format(shape.space, name, field, reason))
            end

            fixed[name] = conditions
        end
    end

    return model
end

return Module
