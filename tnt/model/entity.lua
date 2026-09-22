--- Модель: класс с функциями доступа над формой записи и шлюзом.
---
--- Функции зовутся точкой — `User.find(7)`, `User.create(input)`, — и
--- никакой магии за ними нет: это обычные замыкания над формой, и проверка
--- типов их видит. Где данные, модель не знает: шлюз ей привязывает
--- приложение при применении конфигурации, а до того обращение к данным —
--- ошибка программиста «узел ещё не применил конфигурацию».

local check = require('tnt.model.check')
local factory = require('tnt.model.factory')
local migration = require('tnt.model.migration')
local query = require('tnt.model.query')
local record = require('tnt.model.record')
local shapes = require('tnt.model.shape')

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Метка модели: по ней привязка отличает модель от чужой таблицы.
local MARK = {}

---@class TntModel Модель: доступ к записям одного спейса
---@field space string Имя спейса
---@field validate fun(input: any): TntModelRecord|nil, TntModelFailure|nil Запись по форме, без записи в хранилище
---@field find fun(key: any): TntModelRecord|nil, TntModelFailure|nil Запись по ключу; пусто — нет
---@field create fun(input: any): TntModelRecord|nil, TntModelFailure|nil Проверка и вставка; занятый ключ — conflict
---@field delete fun(key: any): boolean|nil, TntModelFailure|nil Удаление по ключу; ложь — записи не было
---@field where fun(field: string, op: string, value: any): TntModelQuery Выборка по индексу
---@field scan fun(): TntModelQuery Полный обход страницами
---@field factory fun(overrides: table|nil): TntModelRecord Запись для проверок, не сохранённая
---@field migration fun(): fun(box: table) Шаг схемы
---@field bound fun(): string|nil Имя привязанного шлюза; пусто — не привязана
---@field _shape TntModelShape
---@field _class table Метатаблица записей
---@field _bind fun(gateway: TntModelGateway|nil)
---@field _gateway fun(): TntModelGateway
---@field _key fun(key: any): any[]|nil, TntModelFailure|nil
---@field _values fun(input: any): table|nil, TntModelFailure|nil
---@field _put fun(values: table, mode: string): table|nil, TntModelFailure|nil
---@field _wrap fun(values: table): TntModelRecord
---@field _rule fun(name: string): TntValidateRule
---@field _query fun(spec: any): TntModelQuerySpec

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

    ---@type TntModelGateway|nil
    local gateway = nil

    --- Правила условий по именам полей — заводятся при первом обращении.
    ---@type table<string, TntValidateRule>
    local condition_rules = {}

    local sequence = 0

    ---@type TntModel
    ---@diagnostic disable-next-line: missing-fields
    local model = setmetatable({ space = shape.space, _shape = shape }, MARK)

    model._class = record.class_of(model)

    function model._bind(next_gateway)
        gateway = next_gateway
    end

    function model._gateway()
        if gateway == nil then
            fail(
                ('модель %s не привязана: узел ещё не применил конфигурацию'):format(
                    shape.space
                )
            )
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

    function model._rule(name)
        if condition_rules[name] == nil then
            condition_rules[name] = check.search_rule_of(shape.by_name[name])
        end

        return condition_rules[name]
    end

    function model._query(wire)
        return query.checked(shape, wire)
    end

    --- Проверка и запись: значения — те, что легли в хранилище.
    function model._put(values, mode)
        local checked, err = model._values(values)

        if checked == nil then
            return nil, err
        end

        return model._gateway().put(shape, checked, mode)
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

        if values == nil then
            return nil, refused
        end

        return model._wrap(values)
    end

    function model.create(input)
        local stored, err = model._put(input, 'insert')

        if stored == nil then
            return nil, err
        end

        return model._wrap(stored)
    end

    function model.delete(key)
        local parts, err = model._key(key)

        if parts == nil then
            return nil, err
        end

        return model._gateway().delete(shape, parts)
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

    function model.migration()
        return migration.step(shape)
    end

    function model.bound()
        return gateway ~= nil and gateway.kind or nil
    end

    return model
end

return Module
