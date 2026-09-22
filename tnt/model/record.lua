--- Запись модели: таблица по именам полей с классом методов.
---
--- Никакой магии: запись — обычная таблица, поля читаются и пишутся как
--- поля, а методы лежат в метатаблице класса, который виден проверке типов.
--- Свои методы приходят из объявления модели
--- (`methods = { is_adult = function(self) … end }`) и зовутся двоеточием,
--- как и пять методов пакета.

local stamps = require('tnt.model.stamp')

local Module = {}

---@class TntModelRecord Запись: поля по именам и методы класса
---@field save fun(self: TntModelRecord): TntModelRecord|nil, TntModelFailure|nil
---@field delete fun(self: TntModelRecord): boolean|nil, TntModelFailure|nil
---@field force_delete fun(self: TntModelRecord): boolean|nil, TntModelFailure|nil
---@field restore fun(self: TntModelRecord): boolean|nil, TntModelFailure|nil
---@field to_table fun(self: TntModelRecord): table

--- Класс записей модели: метатаблица с методами пакета и модели.
---@param model TntModel
---@return table
function Module.class_of(model)
    local methods = {}

    for name, method in pairs(model._shape.methods) do
        methods[name] = method
    end

    --- Сохраняет запись: проверка и замена по ключу.
    ---
    --- Поля записи после сохранения — те, что легли в хранилище:
    --- умолчания заполнены, пробелы обрезаны, отметки поставлены.
    --- Для хуков запись, прочитанная из хранилища, — изменение, а не
    --- читанная (`validate`, `factory`) — создание.
    ---@param self TntModelRecord
    ---@return TntModelRecord|nil record
    ---@return TntModelFailure|nil err
    function methods.save(self)
        return model._write(self:to_table(), 'replace', model._original(self), self)
    end

    --- Удаляет запись по её ключу: у модели с `deleted_at` — мягко,
    --- и запись получает отметку удаления.
    ---@param self TntModelRecord
    ---@return boolean|nil deleted
    ---@return TntModelFailure|nil err
    function methods.delete(self)
        return model._removed(self, nil)
    end

    --- Удаляет запись окончательно, мимо мягкого удаления.
    ---@param self TntModelRecord
    ---@return boolean|nil deleted
    ---@return TntModelFailure|nil err
    function methods.force_delete(self)
        return model._removed(self, stamps.FORCE)
    end

    --- Восстанавливает мягко удалённую запись: отметка удаления снята.
    ---@param self TntModelRecord
    ---@return boolean|nil restored
    ---@return TntModelFailure|nil err
    function methods.restore(self)
        model._soft('restore')

        return model._removed(self, stamps.RESTORE)
    end

    --- Поля записи обычной таблицей — без метатаблицы, копией.
    ---@param self TntModelRecord
    ---@return table
    function methods.to_table(self)
        local plain = {}

        for key, value in pairs(self) do
            plain[key] = value
        end

        return plain
    end

    return { __index = methods }
end

--- Запись из значений: та же таблица, с классом модели.
---@param class table
---@param values table
---@return TntModelRecord
function Module.wrap(class, values)
    return setmetatable(values, class)
end

return Module
