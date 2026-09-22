--- Проверка входа по форме записи: схема `tnt-validate` из полей,
--- обрезка пробелов, свои правила, проверка ключа.
---
--- Схема собирается один раз на модель: правило `tnt-validate` — значение,
--- и собирать его на каждый запрос значило бы платить за объявление при
--- каждой проверке. Лишнее поле — отказ, как и у `tnt-validate`: поле,
--- о котором модель не знает, в спейс не попадёт, и клиент узнаёт об этом
--- сразу.

local validate = require('tnt.validate')

local failure = require('tnt.model.failure')
local order = require('tnt.model.order')

local Module = {}

--- Место отказа, когда он не про поле, а про запись целиком.
Module.WHOLE = '$'

--- Пределы целого рода цифрами — так их называет отказ: `2^64 − 1`
--- число Lua не держит вовсе, а `-2^63` оно показало бы как
--- `-9.2233720368548e+18`.
local LOWEST_DIGITS = '-9223372036854775808'
local HIGHEST_DIGITS = '18446744073709551615'

--- Опознаватель в виде записи: строка в нижнем регистре из строки
--- либо cdata `uuid` — им проходит умолчание поля `uuid`.
local SPELLING = validate.uuid({ coerce = true })

--- Ожидание числового правила теми же словами, что у `tnt-validate`:
--- «целым числом от 0 до 150».
---
--- Своё, а не взятое у правила: правило его наружу не отдаёт, а отказ
--- по целому cdata обязан читаться так же, как отказ по числу Lua.
--- Зовётся только при отказе, то есть хотя бы с одной границей:
--- без границ целое cdata отказа не получает.
---@param word string Ожидание без границ в творительном падеже
---@param min number|nil
---@param max number|nil
---@return string
local function expectation_of(word, min, max)
    if min == nil then
        return ('%s не больше %s'):format(word, max)
    end

    if max == nil then
        return ('%s не меньше %s'):format(word, min)
    end

    return ('%s от %s до %s'):format(word, min, max)
end

--- Причина отказа по целому cdata за границей поля.
---
--- Значение называется цифрами, без `ULL` и `LL` на конце: клиент
--- прислал число, и в ответе 422 он должен узнать своё. `node:must_be`
--- так не умеет — cdata он называет «значением не из Lua», — поэтому
--- он зовётся только у поля с тайной в имени: там значение не
--- показывается вовсе, как и у правил `tnt-validate`.
---@param node table Место проверки `tnt-validate`
---@param expectation string
---@param value any Целое cdata
---@return string
local function refusal(node, expectation, value)
    if node.secret then
        return node:must_be(expectation, value)
    end

    -- Суффикс срезается, а не цифры выбираются образцом: у образца `%d+`
    -- мутант `%d*` неотличим — цифры в записи целого cdata есть всегда.
    -- Скобки оставляют от `gsub` одну строку, без числа замен.
    local digits = (tostring(value):gsub('U?LL$', ''))

    return ('быть %s, а не %s'):format(expectation, digits)
end

--- Правило числового поля: число Lua проверяет правило `tnt-validate`,
--- целое 64-битное cdata — своя проверка границ.
---
--- Целые от 10^14 по модулю `box` отдаёт cdata `uint64_t` либо `int64_t`,
--- `json.decode` — от 2^53. Правило `tnt-validate` cdata отвергает,
--- и без своей ветки запись с таким ключом не проходила бы собственной
--- проверки: ни `find`, ни `save` записи, прочитанной из `box`. К числу
--- Lua значение не приводится: число держит целые подряд только до
--- 2^53, и приведение потеряло бы младшие цифры ключа. Границы
--- сравнивает `order.compare`, а не `<` LuaJIT: тот привёл бы
--- отрицательную границу к `uint64_t`.
---
--- У целого рода число Lua держит ещё и граница самого рода: `box`
--- кладёт его в поле `unsigned` и `integer` только в `[-2^63, 2^64)`,
--- а дальше видит в нём `double` и бросает исключение. Такое число
--- приходит снаружи — `json.decode('{"id": 1e20}')`, — и отказ по нему
--- обязан быть `invalid`, а не броском на узле с данными и не
--- `unavailable` через роутер. Граница рода в отказе — только когда
--- её перешли: объявленные пределы полю важнее, и у обычного промаха
--- текст прежний. Целое cdata за границу рода не выходит вовсе.
---@param common table Общие настройки правила: optional, default, min, max
---@param word string Ожидание без границ: «целым числом» либо «числом»
---@param plain TntValidateRule Правило `tnt-validate` для остальных значений
---@param integral boolean Целый ли род: у числа Lua тогда граница рода
---@return TntValidateRule
local function numeric(common, word, plain, integral)
    return validate.rule({
        name = plain.name,
        optional = common.optional,
        default = common.default,
        check = function(value, node)
            if not order.is_wide(value) then
                local ready, err = plain.check(value, node)

                -- Отказ правила идёт мимо: пустой ответ за пределом не бывает.
                if integral and order.outside(ready) then
                    local expectation = expectation_of(word, common.min or LOWEST_DIGITS, common.max or HIGHEST_DIGITS)

                    return nil, node:must_be(expectation, ready)
                end

                return ready, err
            end

            local low = common.min ~= nil and order.compare(value, common.min) < 0
            local high = common.max ~= nil and order.compare(value, common.max) > 0

            if low or high then
                return nil, refusal(node, expectation_of(word, common.min, common.max), value)
            end

            return value
        end,
    })
end

--- Умолчание поля `uuid` в виде записи.
---
--- Умолчание `tnt-validate` проверку минует, а `default = uuid.new`
--- отдаёт cdata: запись из `validate` и хук «до» видели бы опознаватель
--- не тем видом, что запись, прочитанная из спейса. Поэтому умолчание
--- проходит то же приведение, что и вход. Негодное остаётся как есть:
--- это ошибка объявления, и `box` отвергнет его исключением.
---@param default any Умолчание объявления: значение либо функция
---@return (fun(): any)|nil
local function uuid_default(default)
    if default == nil then
        return nil
    end

    return function()
        local value = default

        if type(value) == 'function' then
            value = value()
        end

        return validate.check(value, SPELLING) or value
    end
end

--- Правило проверки одного поля.
---
--- Беззнаковое — целое не меньше нуля: нижняя граница объявления
--- поднимается до нуля, а не заменяет его. Целое — ещё и в пределах
--- рода (`numeric`). Умолчание и необязательность у ключа
--- отбрасываются: ключ ищут, а не заполняют.
---@param field TntModelField
---@param as_key boolean Правило для значения ключа: без умолчания и необязательности
---@return TntValidateRule
function Module.rule_of(field, as_key)
    local common = {}

    -- Умолчание `false` — тоже умолчание: `or nil` его потерял бы.
    if not as_key then
        common.optional = field.optional or nil
        common.default = field.default
    end

    if field.type == 'string' then
        common.min = field.min
        common.max = field.max
        common.pattern = field.pattern
        common.one_of = field.one_of

        return validate.string(common)
    end

    if field.type == 'boolean' then
        return validate.boolean(common)
    end

    if field.type == 'uuid' then
        -- Опознаватель приходит и строкой — из JSON, из адреса, — и cdata:
        -- его отдают `uuid.new()` и кортеж чужого спейса. Приведение —
        -- только у этого правила: cdata `uuid` оно делает строкой, строку
        -- другого регистра — строкой в нижнем. У записи один вид
        -- опознавателя, а в cdata для `box` его переводит раскладка
        -- (`tnt.model.tuple`).
        common.coerce = true
        common.default = uuid_default(common.default)

        return validate.uuid(common)
    end

    common.min = field.min
    common.max = field.max

    if field.type == 'unsigned' then
        -- Без своей границы аргумент `math.max` — минус бесконечность, а не ноль:
        -- любое число не больше нуля дало бы тот же ответ, и поломку этой
        -- записи не заметила бы ни одна проверка.
        common.min = math.max(0, field.min or -math.huge)
    end

    if field.type == 'number' then
        return numeric(common, 'числом', validate.number(common), false)
    end

    -- Граница объявления шире рода ничего не сужает: такого целого `box`
    -- не примет и так. Она снимается, чтобы отказ за пределом называл
    -- предел рода, а не значение, которого в поле быть не может.
    if common.min ~= nil and common.min <= order.LOWEST then
        common.min = nil
    end

    if common.max ~= nil and common.max >= order.BEYOND then
        common.max = nil
    end

    return numeric(common, 'целым числом', validate.integer(common), true)
end

--- Схема проверки записи целиком.
---@param shape TntModelShape
---@return table<string, TntValidateRule>
function Module.schema_of(shape)
    local schema = {}

    for _, field in ipairs(shape.fields) do
        schema[field.name] = Module.rule_of(field, false)
    end

    return schema
end

--- Правило значения, по которому ищут: части ключа либо искомого
--- значения условия выборки (`=`).
---
--- Одно на оба случая нарочно: у поля первичного ключа умолчания
--- и необязательности не бывает вовсе, и разницу между правилом ключа
--- и правилом записи видно только на условии по другому полю.
---@param field TntModelField
---@return TntValidateRule
function Module.search_rule_of(field)
    return Module.rule_of(field, true)
end

--- Правило границы выборки: границы диапазона и части курсора `after`.
---
--- Граница — место в порядке индекса, а не значение записи: `login >= ''`
--- обходит весь индекс, `age < 200` — его же по убыванию, хотя ни пустого
--- имени, ни возраста 200 в записи быть не может. Курсор к тому же берут
--- из записи, лёгшей до того, как объявление сузили, и её страница
--- обязана продолжаться. Поэтому от объявления остаётся только род —
--- то, что `box` примет частью ключа: строка любой длины, целое в пределах
--- рода, у беззнакового — от нуля. Дробь и `-1` в индексе `unsigned`
--- `box` не принимает (сверено на 3.8), и они по-прежнему отказ.
---@param field TntModelField
---@return TntValidateRule
function Module.bound_rule_of(field)
    -- Поле из одного рода: границ, длины, образца, перечня, умолчания
    -- и необязательности у него нет.
    ---@type TntModelField
    ---@diagnostic disable-next-line: missing-fields
    local bare = { type = field.type }

    return Module.search_rule_of(bare)
end

--- Правила значений выборки по именам полей: искомых значений и границ.
---
--- Собираются при объявлении модели, как и схема записи: правило —
--- значение, и собирать его на каждый запрос значило бы платить
--- за объявление при каждой выборке.
---@param shape TntModelShape
---@return table<string, TntValidateRule> exact Правила искомых значений
---@return table<string, TntValidateRule> bounds Правила границ
function Module.query_rules_of(shape)
    local exact, bounds = {}, {}

    for _, field in ipairs(shape.fields) do
        exact[field.name] = Module.search_rule_of(field)
        bounds[field.name] = Module.bound_rule_of(field)
    end

    return exact, bounds
end

--- Значение выборки, проверенное правилом; отказ — вместо него.
---@param space string Имя спейса — для текста
---@param name string Место отказа: имя поля либо настройки выборки
---@param rule TntValidateRule
---@param value any
---@return any checked
---@return TntModelFailure|nil err
function Module.query_value(space, name, rule, value)
    local ready, errors = validate.check(value, rule)

    if errors ~= nil then
        return nil, failure.invalid_query(space, { [name] = errors[Module.WHOLE] })
    end

    return ready
end

--- Правила проверки частей ключа по порядку первичного индекса.
---@param shape TntModelShape
---@return TntValidateRule[]
function Module.key_rules_of(shape)
    local rules = {}

    for _, name in ipairs(shape.primary) do
        table.insert(rules, Module.search_rule_of(shape.by_name[name]))
    end

    return rules
end

--- Вход с обрезанными пробелами у полей с `trim`.
---
--- Копия, а не правка на месте: таблица пришла от вызывающего, и менять
--- её под ним нельзя. Обрезка идёт до проверки — иначе имя из одних
--- пробелов прошло бы как непустое.
---@param shape TntModelShape
---@param input table
---@return table
local function trimmed(shape, input)
    local copy = {}

    for key, value in pairs(input) do
        local field = shape.by_name[key]

        if field ~= nil and field.trim and type(value) == 'string' then
            copy[key] = value:match('^%s*(.-)%s*$')
        else
            copy[key] = value
        end
    end

    return copy
end

--- Запись по форме: приведённые значения либо отказ `invalid`.
---
--- Свои правила зовутся все, а не до первого отказа, и только на записи,
--- прошедшей проверку полей: правилу вроде «возраст не меньше 18»
--- незачем защищаться от строки в поле возраста.
---@param shape TntModelShape
---@param schema table Схема из `schema_of`
---@param input any
---@return table|nil values
---@return TntModelFailure|nil err
function Module.values_of(shape, schema, input)
    if type(input) ~= 'table' then
        return nil,
            failure.invalid(shape.space, { [Module.WHOLE] = 'должно быть таблицей полей' })
    end

    local values, errors = validate.check(trimmed(shape, input), schema)

    if values == nil then
        ---@cast errors table<string, string>
        return nil, failure.invalid(shape.space, errors)
    end

    local broken = {}
    local found = false

    for _, rule in ipairs(shape.rules) do
        local message, field = rule(values)

        if message ~= nil then
            broken[field or Module.WHOLE] = message
            found = true
        end
    end

    if found then
        return nil, failure.invalid(shape.space, broken)
    end

    return values
end

--- Ключ записи списком частей: скаляр — ключ из одного поля, таблица —
--- части по порядку первичного индекса. Каждая часть проверяется
--- правилом своего поля: `find('abc')` по числовому ключу — отказ,
--- а не исключение из глубины `box`.
---@param shape TntModelShape
---@param rules TntValidateRule[] Правила из `key_rules_of`
---@param key any
---@return any[]|nil parts
---@return TntModelFailure|nil err
function Module.key_of(shape, rules, key)
    local parts = key

    if type(key) ~= 'table' then
        parts = { key }
    end

    if #parts ~= #shape.primary then
        return nil,
            failure.invalid(shape.space, {
                [Module.WHOLE] = ('ключ — %d %s: %s'):format(
                    #shape.primary,
                    #shape.primary == 1 and 'значение' or 'значения по порядку',
                    table.concat(shape.primary, ', ')
                ),
            })
    end

    local checked = {}

    for position, rule in ipairs(rules) do
        local value, errors = validate.check(parts[position], rule)

        if errors ~= nil then
            return nil, failure.invalid(shape.space, { [shape.primary[position]] = errors[Module.WHOLE] })
        end

        checked[position] = value
    end

    return checked
end

--- Ключ из значений записи — по порядку первичного индекса.
---@param shape TntModelShape
---@param values table
---@return any[]
function Module.key_from(shape, values)
    local parts = {}

    for position, name in ipairs(shape.primary) do
        parts[position] = values[name]
    end

    return parts
end

return Module
