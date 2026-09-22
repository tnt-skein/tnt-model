--- Запись ↔ кортеж: раскладка полей по формату спейса и бакет.
---
--- Запись — таблица по именам полей; кортеж — по формату спейса, где
--- поле шардирования стоит на своём месте только там, где узел
--- шардирован. Бакет считается от ключа шардирования тем же хешем,
--- что у `vshard.router.bucket_id_mpcrc32`: роутер и хранилище обязаны
--- сойтись в номере, иначе запись ляжет в чужой бакет.

local Module = {}

---@class TntModelLayout
---@field sharded boolean Есть ли в кортеже поле шардирования
---@field bucket_count integer|nil Число бакетов — для счёта на хранилище

--- Имена полей кортежа по порядку для узла: с полем шардирования или без.
---@param shape TntModelShape
---@param sharded boolean
---@return string[]
function Module.names_of(shape, sharded)
    local names = {}

    for _, name in ipairs(shape.layout) do
        if sharded or name ~= 'bucket_id' then
            table.insert(names, name)
        end
    end

    return names
end

--- Значение ключа шардирования из частей ключа.
---@param shape TntModelShape
---@param key any[] Части ключа по порядку первичного индекса
---@return any
function Module.shard_key_of(shape, key)
    for position, name in ipairs(shape.primary) do
        if name == shape.bucket_of then
            return key[position]
        end
    end

    return nil
end

--- Номер бакета по ключу шардирования — тем же хешем, что у роутера.
---@param hash { mpcrc32: fun(value: any): integer }
---@param shard_key any
---@param bucket_count integer
---@return integer
function Module.bucket_of(hash, shard_key, bucket_count)
    return hash.mpcrc32(shard_key) % bucket_count + 1
end

--- Кортеж из значений записи.
---
--- Отсутствующее значение кладётся `box.NULL`: пустота в середине массива
--- иначе оборвала бы его, и поля правее уехали бы на место левее.
---@param shape TntModelShape
---@param sharded boolean
---@param values table
---@param bucket_id integer|nil Номер бакета — на шардированном узле
---@return any[]
function Module.to_tuple(shape, sharded, values, bucket_id)
    local tuple = {}

    for position, name in ipairs(Module.names_of(shape, sharded)) do
        local value = values[name]

        if name == 'bucket_id' then
            value = bucket_id
        end

        if value == nil then
            value = box.NULL
        end

        tuple[position] = value
    end

    return tuple
end

--- Значения записи из кортежа: по именам, без поля шардирования.
---
--- Пустота из кортежа (`box.NULL`) в запись не кладётся: необязательное
--- поле, которого нет, — это отсутствующий ключ, как и во входе.
---@param shape TntModelShape
---@param sharded boolean
---@param tuple any Кортеж либо список по формату
---@return table
function Module.from_tuple(shape, sharded, tuple)
    local values = {}

    for position, name in ipairs(Module.names_of(shape, sharded)) do
        local value = tuple[position]

        if name ~= 'bucket_id' and value ~= nil then
            values[name] = value
        end
    end

    return values
end

--- Кортеж-курсор для `after`: заполнены только части индекса и ключа.
---
--- `select` с `after` смотрит на части индекса и первичного ключа,
--- остальные поля ему не нужны — они и не заполняются: страницу
--- продолжают по записи, в которой могут быть только эти поля.
---@param shape TntModelShape
---@param sharded boolean
---@param index TntModelIndex
---@param after table Запись либо её часть с полями индекса и ключа
---@return any[]|nil tuple
---@return string|nil missing Имя поля, которого не хватает
function Module.cursor_of(shape, sharded, index, after)
    local needed = {}

    for _, name in ipairs(index.parts) do
        needed[name] = true
    end

    for _, name in ipairs(shape.primary) do
        needed[name] = true
    end

    for name in pairs(needed) do
        if after[name] == nil then
            return nil, name
        end
    end

    local tuple = {}

    for position, name in ipairs(Module.names_of(shape, sharded)) do
        if needed[name] then
            tuple[position] = after[name]
        else
            tuple[position] = box.NULL
        end
    end

    return tuple
end

return Module
