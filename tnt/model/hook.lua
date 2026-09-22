--- Хуки записи: до и после создания, изменения, удаления и восстановления.
---
--- Хук идёт там, где зовут модель, — на роутере, на прослойке, на узле
--- с данными, — и ровно один раз: функции `tnt_model_*` узла с данными
--- хуков не зовут, иначе запись через роутер прошла бы их дважды,
--- а хук, который сам пишет через модель, писал бы на хранилище мимо
--- роутера.
---
--- Хук «до» отказывает так же, как всякая функция набора, — парой:
--- `return nil, 'причина'` либо `return nil, отказ` с родом
--- (`model.failure.new`); голое `return false` — отказ без причины.
--- Отказ отменяет запись: до шлюза она не доходит, вызывающий получает
--- отказ парой. Хук «после» идёт, когда запись уже легла, и его ответ
--- ничего не отменяет — отменить легшую запись вне транзакции нечем.

local failure = require('tnt.model.failure')

local Module = {}

--- Создание: `create` и `save` записи, которую не читали из хранилища.
Module.CREATE = 'create'

--- Изменение: `save` записи, прочитанной из хранилища.
Module.UPDATE = 'update'

--- Удаление: мягкое и окончательное.
Module.DELETE = 'delete'

--- Восстановление мягко удалённой записи.
Module.RESTORE = 'restore'

--- Имена хуков в объявлении: `before_*` и `after_*` каждого события.
---
--- Описание для `tnt-must`: значение — функция, если задано; незнакомое
--- имя — отказ с перечнем знакомых.
---@type table<string, string>
Module.NAMES = {}

for _, event in ipairs({ Module.CREATE, Module.UPDATE, Module.DELETE, Module.RESTORE }) do
    Module.NAMES['before_' .. event] = '?callable'
    Module.NAMES['after_' .. event] = '?callable'
end

--- Событие записи: прежней записи нет — создание, есть — изменение.
---@param original TntModelRecord|nil
---@return string
function Module.event_of(original)
    return original == nil and Module.CREATE or Module.UPDATE
end

--- Отказ по ответу хука «до»; пусто — запись идёт дальше.
---
--- Отказ модели (`model.failure`) передаётся как есть: хук, который сам
--- зовёт модель, отдаёт её отказ — `unavailable` соседней записи —
--- без перевода в другой род. Причина строкой — род `refused`.
---@param shape TntModelShape
---@param event string
---@param allowed any Первое значение хука
---@param err any Второе значение хука
---@return TntModelFailure|nil
function Module.refusal(shape, event, allowed, err)
    if err ~= nil then
        return failure.is(err) and err or failure.new(failure.REFUSED, tostring(err))
    end

    if allowed == false then
        return failure.new(
            failure.REFUSED,
            ('хук before_%s модели %s отказал в записи'):format(event, shape.space)
        )
    end

    return nil
end

--- Хук «до» события; пусто — не объявлен.
---@param shape TntModelShape
---@param event string
---@return function|nil
function Module.before(shape, event)
    return shape.hooks['before_' .. event]
end

--- Зовёт хук «после», если он объявлен: запись уже легла.
---@param shape TntModelShape
---@param event string
---@param record TntModelRecord
---@param original TntModelRecord|nil
function Module.after(shape, event, record, original)
    local run = shape.hooks['after_' .. event]

    if run ~= nil then
        run(record, original)
    end
end

--- Объявлен ли у события хоть один хук.
---@param shape TntModelShape
---@param event string
---@return boolean
function Module.watched(shape, event)
    return Module.before(shape, event) ~= nil or shape.hooks['after_' .. event] ~= nil
end

return Module
