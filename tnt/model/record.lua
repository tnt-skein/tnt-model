--- Запись модели: таблица по именам полей с классом методов.
---
--- Никакой магии: запись — обычная таблица, поля читаются и пишутся как
--- поля, а методы лежат в метатаблице класса, который виден проверке типов.
--- Свои методы приходят из объявления модели
--- (`methods = { is_adult = function(self) … end }`) и зовутся двоеточием,
--- как и три метода пакета.

local check = require('tnt.model.check')

local Module = {}

---@class TntModelRecord Запись: поля по именам и методы класса
---@field save fun(self: TntModelRecord): TntModelRecord|nil, TntModelFailure|nil
---@field delete fun(self: TntModelRecord): boolean|nil, TntModelFailure|nil
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
    --- умолчания заполнены, пробелы обрезаны.
    ---@param self TntModelRecord
    ---@return TntModelRecord|nil record
    ---@return TntModelFailure|nil err
    function methods.save(self)
        local stored, err = model._put(self:to_table(), 'replace')

        if stored == nil then
            return nil, err
        end

        for key in pairs(self) do
            self[key] = nil
        end

        for key, value in pairs(stored) do
            self[key] = value
        end

        return self
    end

    --- Удаляет запись по её ключу.
    ---@param self TntModelRecord
    ---@return boolean|nil deleted
    ---@return TntModelFailure|nil err
    function methods.delete(self)
        return model.delete(check.key_from(model._shape, self))
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
