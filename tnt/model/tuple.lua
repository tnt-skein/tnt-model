--- Запись ↔ кортеж: раскладка полей по формату спейса и бакет.
---
--- Запись — таблица по именам полей; кортеж — по формату спейса, где
--- поле шардирования стоит на своём месте только там, где узел
--- шардирован. Бакет считается от ключа шардирования тем же хешем,
--- что у `vshard.router.bucket_id_mpcrc32`: роутер и хранилище обязаны
--- сойтись в номере, иначе запись ляжет в чужой бакет.
---
--- Опознаватель у записи — строка в нижнем регистре (`tnt.model.check`),
--- а поле `uuid` спейса держит cdata и строки не примет ни в кортеже,
--- ни в ключе, ни в курсоре `after`: «expected uuid, got string» (сверено
--- на 3.8). Перевод идёт здесь, на границе с `box`, и только здесь:
--- по проводу, в слиянии страниц и в условиях областей опознаватель
--- остаётся строкой. Порядок от этого не страдает — строки одной длины
--- из шестнадцатеричных цифр в нижнем регистре идут в том же порядке, что
--- и опознаватели в индексе. Бакет считается от строки на роутере и на
--- хранилище одинаково.

local uuid = require('uuid')

local Module = {}

--- Значение поля в том виде, в каком его держит `box`.
---
--- Строка, которая не UUID, остаётся как есть: сюда она доходит только
--- умолчанием объявления мимо проверки, и `box` отвергнет её исключением,
--- а пустота на её месте легла бы в необязательное поле молча.
---@param field TntModelField
---@param value any
---@return any
local function stored(field, value)
    if field.type == 'uuid' and type(value) == 'string' then
        return uuid.fromstr(value) or value
    end

    return value
end

--- Значение из кортежа в виде записи: cdata `uuid` — строкой.
---@param value any
---@return any
local function recorded(value)
    if uuid.is_uuid(value) then
        return tostring(value)
    end

    return value
end

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

--- Ключ в том виде, в каком его ищет `box`: копия, а не правка на месте.
---@param shape TntModelShape
---@param names string[] Имена частей по порядку индекса
---@param key any[] Части ключа, проверенные правилами модели
---@return any[]
function Module.stored_key(shape, names, key)
    local parts = {}

    for position, value in ipairs(key) do
        parts[position] = stored(shape.by_name[names[position]], value)
    end

    return parts
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
        ---@type any
        local value = bucket_id

        if name ~= 'bucket_id' then
            value = stored(shape.by_name[name], values[name])
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
            values[name] = recorded(value)
        end
    end

    return values
end

--- Кортеж-курсор для `after`: заполнены только части индекса и ключа.
---
--- `select` с `after` смотрит на части индекса и первичного ключа,
--- остальные поля ему не нужны — они и не заполняются: страницу
--- продолжают по записи, в которой могут быть только эти поля.
---
--- Пустая часть необязательного поля — NULL, а не нехватка: так такая
--- запись и стоит в индексе, и `box` продолжает обход от этого места
--- в обе стороны (сверено на 3.8, и у уникального индекса тоже).
---@param shape TntModelShape
---@param sharded boolean
---@param index TntModelIndex
---@param after table Запись либо её часть с полями индекса и ключа
---@return any[]|nil tuple
---@return string|nil missing Имя обязательного поля, которого не хватает
function Module.cursor_of(shape, sharded, index, after)
    local needed = {}

    for _, name in ipairs(index.parts) do
        needed[name] = true
    end

    for _, name in ipairs(shape.primary) do
        needed[name] = true
    end

    for name in pairs(needed) do
        if after[name] == nil and not shape.by_name[name].optional then
            return nil, name
        end
    end

    local tuple = {}

    for position, name in ipairs(Module.names_of(shape, sharded)) do
        -- Пустая часть — тоже `box.NULL`, а не дыра: пустота в середине
        -- массива оборвала бы его, как и у `to_tuple`.
        if needed[name] and after[name] ~= nil then
            tuple[position] = stored(shape.by_name[name], after[name])
        else
            tuple[position] = box.NULL
        end
    end

    return tuple
end

return Module
