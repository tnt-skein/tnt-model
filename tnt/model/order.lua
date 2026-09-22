--- Порядок записей по индексу: сравнение частей, место курсора `after`
--- относительно выборки и слияние страниц с нескольких хранилищ.
---
--- Каждое хранилище отдаёт свою страницу уже в порядке индекса — так
--- её отдаёт `select`. Страница всего кластера — слияние таких страниц
--- по частям индекса, а при равных частях по первичному ключу, как
--- упорядочивает сам индекс TREE. Направление задаёт итератор: `LT`
--- и `LE` идут по убыванию.
---
--- Целые от 10^14 по модулю `box` и net.box отдают cdata `uint64_t`
--- либо `int64_t`, а меньшие — числом Lua, так что в одном столбце
--- лежит то и другое. Сравнивать их как есть нельзя: LuaJIT приводит
--- обе стороны к `uint64_t`, стоит одной из них быть `uint64_t`, и тогда
--- `-1` оказывается больше `5ULL`, а `-1LL == 2^64 − 1` — истиной.
--- Сравнение таких значений — в `wide` ниже.
---
--- Не-число (NaN) модель записать не даст — его отвергает проверка
--- входа, — но в поле `number`, записанном мимо модели, оно лежит,
--- и индекс TREE ставит его раньше любого числа, даже `-inf` (сверено
--- на 3.8). Так же его ставит и `compare`: и перед числом Lua, и перед
--- целым cdata, — иначе слитая страница расходилась бы с порядком
--- хранилищ.

local ffi = require('ffi')

local Module = {}

local INT64 = ffi.typeof('int64_t')
local UINT64 = ffi.typeof('uint64_t')

--- Первое целое, которого нет в `int64_t`: целые меньше него
--- сравниваются в `int64_t`, остальные — в `uint64_t`.
local UPPER_HALF = 2 ^ 63

--- Пределы целых cdata: меньше `-2^63` нет `int64_t`, с `2^64` нет
--- `uint64_t`. Число Lua за пределом дальше от нуля любого из них.
---
--- Те же пределы держит и `box`: целое число Lua он кладёт в поле
--- `integer` только в `[-2^63, 2^64)`, а дальше видит в нём `double`
--- (сверено на 3.8). Поэтому их знает и проверка входа (`tnt.model.check`).
Module.LOWEST = -2 ^ 63
Module.BEYOND = 2 ^ 64

--- Целое ли это 64-битное cdata: `int64_t` либо `uint64_t`.
---@param value any
---@return boolean
function Module.is_wide(value)
    return ffi.istype(INT64, value) or ffi.istype(UINT64, value)
end

--- Сравнение двумя строгими сравнениями: -1, 0, 1.
---
--- Равенство узнаётся последним: проверка на равенство первой сделала
--- бы `<` и `<=` ниже неразличимыми.
---@param left any
---@param right any
---@return integer
local function strict(left, right)
    if left < right then
        return -1
    end

    if right < left then
        return 1
    end

    return 0
end

--- Лежит ли значение в старшей половине: от `2^63`.
---
--- Граница — `2^63`, а не ноль, нарочно: у нуля знак для порядка
--- неважен, и сравнение с нулём дало бы мутантов `<` и `<=`, которых
--- не различит ни одна проверка. У `2^63` половина важна — `int64_t`
--- его не держит, и значение не в своей половине сравнивалось бы
--- после переполнения. `int64_t` всегда в младшей: `2^63` при сравнении
--- с ним не помещается в его тип.
---@param value any Число Lua либо целое cdata
---@return boolean
local function upper_half(value)
    return not ffi.istype(INT64, value) and value >= UPPER_HALF
end

--- Число Lua за пределами целых cdata.
---@param value any
---@return boolean
function Module.outside(value)
    return type(value) == 'number' and (value < Module.LOWEST or value >= Module.BEYOND)
end

--- Целая часть в типе половины и дробный остаток.
---
--- Дробь бывает только у числа Lua, и сравнивается она отдельно: приведение
--- к целому типу её отбросило бы, и `10^14 + 0.5` сравнялось бы с `10^14`.
---@param value any Число Lua в пределах типа, но не NaN, либо целое cdata
---@param ctype ffi.ctype* Тип половины
---@return any whole
---@return number rest
local function split(value, ctype)
    if type(value) ~= 'number' then
        return ffi.cast(ctype, value), 0
    end

    local whole = math.floor(value)

    return ffi.cast(ctype, whole), value - whole
end

--- Сравнение, где хотя бы одна сторона — целое 64-битное cdata.
---
--- Значения из разных половин различает половина. В одной половине
--- число Lua за пределом типа уходит от целых cdata в сторону своей
--- половины, а остальное сравнивается в типе половины — там оба целых
--- точны, — сначала целыми частями, затем дробью.
---@param left any
---@param right any
---@return integer
local function wide(left, right)
    local upper = upper_half(left)
    local toward = upper and 1 or -1

    if upper ~= upper_half(right) then
        return toward
    end

    if Module.outside(left) then
        return toward
    end

    if Module.outside(right) then
        return -toward --[[@as integer]]
    end

    local ctype = upper and UINT64 or INT64
    local left_whole, left_rest = split(left, ctype)
    local right_whole, right_rest = split(right, ctype)
    local verdict = strict(left_whole, right_whole)

    if verdict ~= 0 then
        return verdict
    end

    return strict(left_rest, right_rest)
end

--- Сравнение двух значений одного рода: -1, 0, 1.
---
--- Порядок — как в индексе TREE. Пустое значение необязательного поля
--- (NULL) идёт раньше любого, не-число (NaN) — сразу за ним, раньше
--- любого числа. Логические значения `<` не сравнивает; ложь идёт
--- первой. Целые 64-битные cdata вместе с числами Lua сравнивает `wide`.
--- Остальные роды — числа, строки, uuid, decimal, datetime — сравнивает
--- сам Lua либо метатаблица cdata.
---@param left any
---@param right any
---@return integer
function Module.compare(left, right)
    if left == nil or right == nil then
        return (left ~= nil and 1 or 0) - (right ~= nil and 1 or 0) --[[@as integer]]
    end

    -- Не-число узнаётся тем, что не равно себе, и отвечает здесь, до `wide`:
    -- там оно ушло бы в `ffi.cast` к целому типу, а это неопределённое
    -- поведение C — на x86 выходит `-2^63`, на arm64 ноль, и порядок
    -- зависел бы от машины. `<` же на нём всегда ложно, и NaN вышло бы
    -- равным любому числу.
    local left_nan = left ~= left
    local right_nan = right ~= right

    if left_nan or right_nan then
        return (left_nan and 0 or 1) - (right_nan and 0 or 1) --[[@as integer]]
    end

    if type(left) == 'boolean' then
        if left == right then
            return 0
        end

        return left and 1 or -1
    end

    if Module.is_wide(left) or Module.is_wide(right) then
        return wide(left, right)
    end

    return strict(left, right)
end

--- Сравнение записей по именам полей по порядку.
---@param names string[]
---@param left table
---@param right table
---@return integer
function Module.compare_by(names, left, right)
    for _, name in ipairs(names) do
        local verdict = Module.compare(left[name], right[name])

        if verdict ~= 0 then
            return verdict
        end
    end

    return 0
end

--- Имена, задающие порядок индекса: его части, затем первичный ключ.
---@param shape TntModelShape
---@param index TntModelIndex
---@return string[]
function Module.names_of(shape, index)
    local names = {}
    local seen = {}

    for _, list in ipairs({ index.parts, shape.primary }) do
        for _, name in ipairs(list) do
            if not seen[name] then
                seen[name] = true
                table.insert(names, name)
            end
        end
    end

    return names
end

--- Убывает ли обход по этому итератору.
---@param iterator string
---@return boolean
function Module.descending(iterator)
    return iterator == 'LT' or iterator == 'LE'
end

--- Итераторы, чья выборка не берёт записей со значением самого ключа:
--- курсор с этим значением стоит ещё до её начала.
---@type table<string, boolean>
local STRICT = { GT = true, LT = true }

--- Где курсор `after` стоит относительно выборки в порядке её обхода.
---
--- Страница после курсора — записи выборки строго после него, откуда бы
--- курсор ни пришёл: курсор раньше начала выборки оставляет её целиком,
--- курсор за концом — пустую страницу. Клиент приносит и курсор
--- от другой выборки, а `box` на такой отвечает не страницей (сверено
--- на 3.8): курсор раньше начала он отвергает исключением «Iterator
--- position is invalid», у `EQ` — и курсор за концом, а у `GT` и `LT`
--- курсор со значением самого ключа принимает и отдаёт после него записи
--- с этим значением, которых в выборке нет. Поэтому место курсора
--- решается здесь, до `box`.
---
--- Части курсора сверяются с частями ключа по порядку индекса — столько,
--- сколько частей в ключе: так выборку ведёт и сам `box`. Пустая часть
--- курсора раньше любого значения (`compare`). Конец выборки по ключу
--- есть только у равенства: у диапазона курсор дальше ключа — в выборке
--- либо за верхней границей, и там `box` отдаёт пустую страницу сам.
---@param parts string[] Части индекса по порядку
---@param iterator string Итератор выборки
---@param key any[] Ключ выборки в виде записи: части по порядку индекса
---@param cursor table Курсор: значения по именам полей
---@return boolean early Курсор раньше начала: выборка идёт целиком
---@return boolean late Курсор за концом выборки на равенство: страница пуста
function Module.placed(parts, iterator, key, cursor)
    local names = {}
    local bound = {}

    for position, value in ipairs(key) do
        names[position] = parts[position]
        bound[parts[position]] = value
    end

    local verdict = Module.compare_by(names, cursor, bound)

    if Module.descending(iterator) then
        verdict = -verdict
    end

    if STRICT[iterator] then
        return verdict <= 0, false
    end

    return verdict < 0, iterator == 'EQ' and verdict > 0
end

--- Страницы нескольких хранилищ — одной страницей в порядке индекса.
---
--- Сортировка устойчивая по построению: записи с равным ключом
--- различаются первичным ключом, а он уникален во всём кластере.
---@param shape TntModelShape
---@param index TntModelIndex
---@param iterator string
---@param pages table[][] Страницы хранилищ
---@param limit integer
---@return table[]
function Module.merged(shape, index, iterator, pages, limit)
    local names = Module.names_of(shape, index)
    local rows = {}

    for _, page in ipairs(pages) do
        for _, row in ipairs(page) do
            table.insert(rows, row)
        end
    end

    -- Ответ сравнения, с которым левая запись идёт раньше: по убыванию —
    -- «больше». Точное значение, а не знак: величину множителя знака
    -- сортировка не различала бы.
    local before = Module.descending(iterator) and 1 or -1

    table.sort(rows, function(left, right)
        return Module.compare_by(names, left, right) == before
    end)

    -- Страница — первые `limit` записей: лишнее срезается с хвоста.
    while #rows > limit do
        table.remove(rows)
    end

    return rows
end

return Module
