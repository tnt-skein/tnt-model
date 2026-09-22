--- Общие функции узла с данными: `tnt_model_*` для роутеров и прослоек.
---
--- Роутер vshard и узел-прослойка не знают спейсов — они зовут эти пять
--- функций по имени спейса, а узел ищет модель в белом списке своего
--- приложения. Чужой спейс по имени недоступен: модель, которой нет
--- в списке, — отказ `unknown`, а не чтение произвольного спейса.
---
--- Каждая функция отвечает одной таблицей — `{ ok = true, value = … }`
--- либо отказом для провода: vshard передаёт вызывающему только первое
--- значение, и пара `nil, err` потеряла бы причину. Вход проверяется
--- здесь заново: роутер проверил его у себя, но узел с данными не обязан
--- верить вызывающему — по `lua_call` сюда ходят и чужие. Ключ, запись
--- и значения выборки — теми же правилами, что у модели, и негодное —
--- отказ `invalid`, а не исключение из глубины `box`.

local failure = require('tnt.model.failure')
local stamps = require('tnt.model.stamp')

local Module = {}

--- Имена функций, которые публикуются на узле с данными.
Module.NAMES = { 'tnt_model_count', 'tnt_model_delete', 'tnt_model_find', 'tnt_model_put', 'tnt_model_select' }

--- Способы записи, которые принимает `tnt_model_put`.
---@type table<string, boolean>
local MODES = { insert = true, replace = true }

--- Способы удаления, которые принимает `tnt_model_delete` сверх пустого —
--- «по модели»: мягко у модели с признаком удаления, иначе окончательно.
---@type table<string, boolean>
local REMOVALS = { [stamps.FORCE] = true, [stamps.RESTORE] = true }

--- Ответ с значением.
---@param value any
---@return table
local function replied(value)
    return { ok = true, value = value }
end

--- Отказ для провода о незнакомом способе.
---@param what string Что за способ: «записи», «удаления»
---@param mode any
---@return table
local function unknown_mode(what, mode)
    return failure.to_wire(
        failure.new(failure.INVALID, ('способ %s %s неизвестен'):format(what, tostring(mode)))
    )
end

--- Ответ по паре «значение, отказ».
---@param value any
---@param err TntModelFailure|nil
---@return table
local function answered(value, err)
    if err ~= nil then
        return failure.to_wire(err)
    end

    return replied(value)
end

--- Функции узла с данными над моделями белого списка.
---@param models TntModel[] Модели приложения, привязанные на этом узле
---@param gateway TntModelGateway Шлюз `local` к данным узла
---@return table<string, function>
function Module.functions(models, gateway)
    ---@type table<string, TntModel>
    local by_space = {}

    for _, model in ipairs(models) do
        by_space[model.space] = model
    end

    --- Модель по имени спейса либо отказ для провода.
    ---@param space any
    ---@return TntModel|nil model
    ---@return table|nil refusal
    local function served(space)
        local model = type(space) == 'string' and by_space[space] or nil

        if model == nil then
            return nil,
                failure.to_wire(
                    failure.new(
                        failure.UNKNOWN,
                        ('спейс %s этим узлом не обслуживается'):format(tostring(space))
                    )
                )
        end

        return model
    end

    --- Модель и проверенный вход либо отказ для провода.
    ---@param space any
    ---@param method string Проверка модели: `_key` — ключ, `_query` — выборка
    ---@param input any
    ---@return TntModel|nil model
    ---@return any checked_or_refusal Проверенный вход при успехе, отказ — без модели
    local function located(space, method, input)
        local model, refusal = served(space)

        if model == nil then
            return nil, refusal
        end

        local checked, err = model[method](input)

        if checked == nil then
            ---@cast err TntModelFailure
            return nil, failure.to_wire(err)
        end

        return model, checked
    end

    return {
        tnt_model_find = function(space, key)
            local model, parts = located(space, '_key', key)

            if model == nil then
                return parts
            end

            return answered(gateway.find(model._shape, parts))
        end,

        tnt_model_put = function(space, values, mode)
            local model, refusal = served(space)

            if model == nil then
                return refusal
            end

            if not MODES[mode] then
                return unknown_mode('записи', mode)
            end

            local checked, err = model._values(values)

            if checked == nil then
                ---@cast err TntModelFailure
                return failure.to_wire(err)
            end

            return answered(gateway.put(model._shape, checked, mode))
        end,

        tnt_model_delete = function(space, key, mode)
            local model, parts = located(space, '_key', key)

            if model == nil then
                return parts
            end

            if mode ~= nil and not REMOVALS[mode] then
                return unknown_mode('удаления', mode)
            end

            return answered(gateway.delete(model._shape, parts, mode))
        end,

        tnt_model_select = function(space, query)
            local model, spec = located(space, '_query', query)

            if model == nil then
                return spec
            end

            return answered(gateway.select(model._shape, spec))
        end,

        tnt_model_count = function(space, query)
            local model, spec = located(space, '_query', query)

            if model == nil then
                return spec
            end

            return answered(gateway.count(model._shape, spec))
        end,
    }
end

return Module
