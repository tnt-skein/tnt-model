--- Отказ модели: таблица с родом, которая читается и как строка.
---
--- Отказ — это «так бывает»: запись не прошла проверку, узел только для
--- чтения, хранилище не ответило. Вызывающему нужен и текст — отдать
--- клиенту, записать в журнал, — и род, по которому обработчик выбирает
--- код ответа: 422 на `invalid`, 409 на `conflict`, 503 на `unavailable`.
--- Проверка входа отдаёт ещё и поля: «поле → причина», как `tnt-validate`,
--- чтобы ответ 422 называл каждое негодное поле, а не первое попавшееся.
---
--- Отказ ездит и по сети: роутер получает его от хранилища таблицей
--- без метатаблицы. Поэтому есть две записи — сама таблица отказа
--- и её вид для провода (`to_wire`/`from_wire`), одна таблица с `ok`.

local Module = {}

--- Запись либо выборка не прошла проверку: тип, границы, свои правила.
Module.INVALID = 'invalid'

--- Значение уникального индекса занято: `create` на занятый ключ либо
--- `create` и `save` со значением уникального вторичного индекса, которое
--- уже у другой записи.
Module.CONFLICT = 'conflict'

--- Узел только для чтения: реплика, ведущий ещё не выбран.
Module.READONLY = 'readonly'

--- Данные не ответили: хранилище недоступно, срок вышел, vshard отказал.
Module.UNAVAILABLE = 'unavailable'

--- Бакет ключа живёт на другом узле: запись мимо роутера на хранилище.
Module.MISROUTED = 'misrouted'

--- Спейс не обслуживается этим узлом: модели нет в белом списке.
Module.UNKNOWN = 'unknown'

--- Хук «до» модели отказал в записи: запись не легла.
---
--- Род свой, а не `invalid`: хук отказывает не входу, а действию —
--- «опубликованную запись не меняют», — и обработчик отвечает на это
--- иначе, чем на негодное поле.
Module.REFUSED = 'refused'

---@class TntModelFailure Отказ модели: род, текст и поля
---@field kind string Род: invalid, conflict, readonly, unavailable, misrouted, unknown, refused
---@field message string Причина для человека
---@field fields table<string, string>|nil Поле → причина; есть только у invalid

--- Поведение всех отказов: строкой, в JSON и в журнале — текстом,
--- склейка через `..` — как у строки.
local Failure = {}

Failure.__tostring = function(failure)
    return failure.message
end
Failure.__serialize = Failure.__tostring
Failure.__concat = function(left, right)
    return tostring(left) .. tostring(right)
end

--- Собирает отказ.
---@param kind string
---@param message string
---@param fields table<string, string>|nil
---@return TntModelFailure
function Module.new(kind, message, fields)
    return setmetatable({ kind = kind, message = message, fields = fields }, Failure)
end

--- Отказ ли это модели, а не чужая таблица.
---@param value any
---@return boolean
function Module.is(value)
    return getmetatable(value) == Failure
end

--- Отказ `invalid` по полям: поля по алфавиту в тексте, чтобы отказ
--- читался одинаково при любом порядке обхода таблицы.
---@param head string Начало текста: что не прошло проверку
---@param fields table<string, string>
---@return TntModelFailure
local function unfit(head, fields)
    local names = {}

    for name in pairs(fields) do
        table.insert(names, name)
    end

    table.sort(names)

    local parts = {}

    for _, name in ipairs(names) do
        table.insert(parts, ('%s — %s'):format(name, fields[name]))
    end

    return Module.new(Module.INVALID, ('%s: %s'):format(head, table.concat(parts, '; ')), fields)
end

--- Отказ проверки записи.
---@param space string Имя спейса — для текста
---@param fields table<string, string>
---@return TntModelFailure
function Module.invalid(space, fields)
    return unfit(('запись %s не прошла проверку'):format(space), fields)
end

--- Отказ проверки выборки: значение условия, курсора, страницы.
---
--- Текст свой, а не «запись … не прошла проверку»: негодна не запись,
--- а то, чем её ищут, и по тексту клиент видит, что править — запрос.
---@param space string Имя спейса — для текста
---@param fields table<string, string>
---@return TntModelFailure
function Module.invalid_query(space, fields)
    return unfit(('условие выборки %s'):format(space), fields)
end

--- Вид отказа для провода: одна таблица с `ok = false`.
---
--- Функции хранилища отвечают одной таблицей: vshard отдаёт вызывающему
--- только первое значение, а `false, err` потерял бы причину по дороге.
---@param failure TntModelFailure
---@return table
function Module.to_wire(failure)
    return { ok = false, kind = failure.kind, message = failure.message, fields = failure.fields }
end

--- Отказ из таблицы, пришедшей по проводу.
---@param wire table
---@return TntModelFailure
function Module.from_wire(wire)
    return Module.new(tostring(wire.kind), tostring(wire.message), wire.fields)
end

return Module
