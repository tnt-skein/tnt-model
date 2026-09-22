--- Шлюз `local` на двойнике `box`: счёт по диапазону двумя счётами
--- по индексу и обход кусками у выборки с условием.
---
--- Настоящий `box` живёт в дочернем узле (`local_live_test`), и там же
--- проверено главное — что счёт диапазона не боится среза файбера,
--- а обход с условием спасает уступка. Здесь двойник: он записывает, чем
--- именно шлюз спрашивает индекс, — счёты, размер куска, продолжение
--- и число уступок, — а на живом узле этого не увидеть, не подменив сам
--- индекс.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.local')

---@type any
local model

--- Так отказывает настоящий box, когда спейс снесли под обходом: номером
--- спейса, а не именем, — имени у снесённого уже нет.
local GONE = "Space '516' does not exist"

--- Сколько выборок двойник терпит, прежде чем счесть обход зациклившимся.
---
--- Обход по замыслу кончается за единицы кусков. Двойник, отвечающий
--- на любое число выборок, превратил бы сломанное условие выхода
--- в зависшую проверку, а не в падение с внятным текстом.
local CALLS_LIMIT = 10

--- Чем двойник индекса сравнивает возраст записи с ключом счёта.
---@type table<string, fun(age: integer, key: integer): boolean>
local COUNTED = {
    GE = function(age, key)
        return age >= key
    end,
    GT = function(age, key)
        return age > key
    end,
    LT = function(age, key)
        return age < key
    end,
}

--- Двойник индекса: страницы из готового списка кортежей.
---
--- `after` продолжает с кортежа, а не с ключа: так же, как настоящий
--- индекс, двойник ищет место по самому кортежу — на неуникальном
--- индексе ключ места не задаёт.
---@param tuples any[]
---@param calls table[] Куда писать обращения
---@param breaking integer|nil На каком по счёту `select` двойник отказывает
---@param text string|nil Чем отказывает; по умолчанию — снесённым спейсом
---@return table
local function fake_index(tuples, calls, breaking, text)
    local selects = 0

    --- Место кортежа в списке.
    ---@param wanted any
    ---@return integer
    local function place_of(wanted)
        for position, item in ipairs(tuples) do
            -- По ключу, а не по самому кортежу: курсор `after` шлюз
            -- собирает заново из записи, и это другая таблица.
            if item[1] == wanted[1] then
                return position
            end
        end

        error('двойник индекса: продолжение с чужого кортежа')
    end

    local index = {}

    -- Точкой, а не двоеточием: сам двойник себя не разглядывает,
    -- а шлюз зовёт через двоеточие — место для `self` в аргументах есть.
    --
    -- Счёт идёт по возрасту — третьему полю кортежа, как у индекса `age`:
    -- с ключом шлюз считает только по нему. Без ключа считается всё.
    function index.count(_, key, opts)
        table.insert(calls, { name = 'count', key = key, iterator = opts.iterator })

        local counted = 0

        for _, item in ipairs(tuples) do
            if key[1] == nil or COUNTED[opts.iterator](item[3], key[1]) then
                counted = counted + 1
            end
        end

        return counted
    end

    function index.select(_, key, opts)
        selects = selects + 1

        table.insert(calls, {
            name = 'select',
            key = key,
            iterator = opts.iterator,
            limit = opts.limit,
            -- Опознаватель записи, с которой продолжают, либо `false`:
            -- пустота в списке проверок оборвала бы его на первой странице.
            after = opts.after ~= nil and opts.after[1] or false,
        })

        -- Без места вызова, как у отказа `box`: текст отказа модели
        -- сверяется целиком.
        if selects == breaking then
            error(text or GONE, 0)
        end

        if selects > CALLS_LIMIT then
            error(
                ('двойник индекса: обход не кончился за %d выборок'):format(
                    CALLS_LIMIT
                )
            )
        end

        local from = opts.after ~= nil and place_of(opts.after) + 1 or 1
        local page = {}

        for position = from, math.min(#tuples, from + opts.limit - 1) do
            table.insert(page, tuples[position])
        end

        return page
    end

    return index
end

--- Кортежи пользователей: столько-то записей каждого возраста подряд.
---@param runs integer[][] Пары { возраст, сколько }
---@return any[]
local function tuples_of(runs)
    local tuples = {}

    for _, run in ipairs(runs) do
        for _ = 1, run[2] do
            table.insert(tuples, { #tuples + 1, 'Мария', run[1] })
        end
    end

    return tuples
end

--- Модель пользователей на шлюзе `local` с двойником `box`.
---@param tuples any[] Кортежи спейса по порядку индекса `age`
---@param in_transaction boolean Идёт ли вызов внутри транзакции
---@param breaking integer|nil На каком по счёту `select` отказывает box
---@param text string|nil Чем отказывает box
---@param overrides table|nil Поля объявления модели поверх образца
---@return any User
---@return table[] calls Обращения к индексу
---@return fun(): integer yields Сколько раз шлюз уступил
local function bound(tuples, in_transaction, breaking, text, overrides)
    local calls = {}
    local yields = 0
    local index = fake_index(tuples, calls, breaking, text)

    model._set_source({
        box = function()
            return {
                space = { users = { index = { age = index, primary = index } } },
                is_in_txn = function()
                    return in_transaction
                end,
            }
        end,
        fiber = function()
            return {
                yield = function()
                    yields = yields + 1
                end,
            }
        end,
    })

    local User = helper.users(model, overrides)

    User._bind(helper.module('tnt.model.gateway.local').new({ sharded = false }))

    return User, calls, function()
        return yields
    end
end

g.before_each(function()
    model = helper.load()
end)

g.after_each(function()
    model._set_source(nil)
    helper.unload()
end)

-- Диапазон `between` — два счёта по индексу: записи от нижней границы
-- без записей строго за верхней. Ни выборки, ни уступки: счёт не читает
-- записей и видит один снимок.
g.test_range_count_is_two_index_counts_without_a_yield = function()
    local User, calls, yields = bound(tuples_of({ { 30, 1500 }, { 31, 1000 }, { 40, 500 } }), false)

    t.assert_equals(User.where('age', 'between', { 30, 31 }):count(), 2500)
    t.assert_equals(yields(), 0)
    t.assert_equals(calls, {
        { name = 'count', key = { 30 }, iterator = 'GE' },
        { name = 'count', key = { 31 }, iterator = 'GT' },
    })
end

-- В транзакции счёт тот же: уступать ему незачем, и уступка не оборвёт
-- транзакцию.
g.test_range_count_inside_a_transaction_is_the_same_two_counts = function()
    local User, calls, yields = bound(tuples_of({ { 30, 1500 }, { 31, 1000 }, { 40, 500 } }), true)

    t.assert_equals(User.where('age', 'between', { 30, 31 }):count(), 2500)
    t.assert_equals(yields(), 0)
    t.assert_equals(#calls, 2)
end

-- Обе границы включительно; диапазон, в который не попала ни одна запись,
-- — ноль, и верхняя граница ниже нижней — тоже ноль, а не разность меньше
-- нуля: записей за верхней тогда больше, чем от нижней.
g.test_range_count_takes_both_bounds_and_never_goes_below_zero = function()
    local User = bound(tuples_of({ { 30, 3 }, { 31, 2 }, { 40, 1 } }), false)

    t.assert_equals(User.where('age', 'between', { 31, 31 }):count(), 2)
    t.assert_equals(User.where('age', 'between', { 31, 40 }):count(), 3)
    t.assert_equals(User.where('age', 'between', { 32, 39 }):count(), 0)
    t.assert_equals(User.where('age', 'between', { 40, 30 }):count(), 0)
end

-- Диапазон без верхней границы — один счёт: его считает сам индекс.
g.test_count_without_an_upper_bound_asks_the_index_itself = function()
    local User, calls, yields = bound(tuples_of({ { 30, 2500 } }), false)

    t.assert_equals(User.where('age', '>=', 30):count(), 2500)
    t.assert_equals(yields(), 0)
    t.assert_equals(calls, { { name = 'count', key = { 30 }, iterator = 'GE' } })
end

-- Верхняя граница ходит только с `GE`: её ставит `between`. С другим
-- итератором разность счётов посчитала бы чужие записи, и такую выборку
-- шлюз не исполняет вовсе — ни счётом, ни страницей, ни с условием.
-- Прийти она может только чужим вызовом мимо модели.
g.test_upper_bound_comes_only_with_ge = function()
    local User, calls = bound(tuples_of({ { 30, 2 } }), false)
    local gateway = User._gateway()
    local message = 'модель users: граница to — только у итератора GE, а не %s'

    t.assert_error_msg_equals(
        message:format('LT'),
        gateway.count,
        User._shape,
        { index = 'age', iterator = 'LT', key = { 40 }, to = 30, limit = 10 }
    )
    t.assert_error_msg_equals(
        message:format('EQ'),
        gateway.select,
        User._shape,
        { index = 'age', iterator = 'EQ', key = { 30 }, to = 40, limit = 10 }
    )
    t.assert_error_msg_equals(message:format('GT'), gateway.count, User._shape, {
        index = 'age',
        iterator = 'GT',
        key = { 20 },
        to = 40,
        limit = 10,
        filter = { { field = 'age', op = '>=', value = 18 } },
    })
    t.assert_equals(calls, {}, 'до box выборка не дошла')
    t.assert_equals(
        gateway.count(User._shape, { index = 'age', iterator = 'LT', key = { 40 }, limit = 10 }),
        2,
        'без границы итератор любой'
    )
end

--- Области пользователей для выборок с условиями.
local SCOPES = {
    scopes = {
        adults = { { 'age', '>=', 18 } },
        named = function(name)
            return { { 'name', '=', name } }
        end,
    },
}

--- Модель с областями на двойнике `box`.
---@param tuples any[]
---@param in_transaction boolean|nil
---@param breaking integer|nil
---@return any User
---@return any calls
---@return fun(): integer yields
local function scoped(tuples, in_transaction, breaking)
    return bound(tuples, in_transaction == true, breaking, nil, SCOPES)
end

-- Условия box не знает: записи индекса идут кусками по тысяче с уступкой
-- между ними, продолжение — с последнего кортежа куска, и обход кончается,
-- как только страница полна, — третий кусок не читается.
g.test_filtered_page_walks_chunks_until_the_page_is_full = function()
    local User, calls, yields = scoped(tuples_of({ { 10, 1500 }, { 30, 2000 } }))
    local page = User.scan():scope('adults'):limit(3):all()

    t.assert_equals(helper.ids(page), { 1501, 1502, 1503 })
    t.assert_equals(yields(), 1, 'уступка только между двумя кусками')
    t.assert_equals(calls, {
        { name = 'select', key = {}, iterator = 'ALL', limit = 1000, after = false },
        { name = 'select', key = {}, iterator = 'ALL', limit = 1000, after = 1000 },
    })
end

-- Смещение считает подошедшие записи: пропуск не подошедших box сделал
-- бы сам, и страница съехала бы на них.
g.test_filtered_offset_skips_matching_records_only = function()
    local User = scoped(tuples_of({ { 10, 5 }, { 30, 5 } }))

    t.assert_equals(helper.ids(User.scan():scope('adults'):limit(2):offset(2):all()), { 8, 9 })
    t.assert_equals(helper.ids(User.scan():scope('adults'):limit(9):offset(4):all()), { 10 })
    t.assert_equals(User.scan():scope('adults'):offset(5):all(), {})
end

-- Шлюз зовут модель и функции узла с данными, и обе проверяют курсор
-- раньше него: без обязательной части курсор до шлюза не доходит.
-- Прямой вызов с такой нехваткой — ошибка программиста, а не выборка
-- с NULL в части, которая пустоты не допускает.
g.test_gateway_refuses_a_cursor_without_a_required_part = function()
    local User, calls = bound(tuples_of({ { 30, 2 } }), false)
    local spec = { index = 'age', iterator = 'GE', key = { 18 }, limit = 10, after = { age = 30 } }

    t.assert_error_msg_equals(
        'модель users: в after нет поля id',
        User._gateway().select,
        User._shape,
        spec
    )
    t.assert_equals(calls, {}, 'до box выборка не дошла')
end

-- Продолжение с записи: первый кусок идёт уже после курсора.
g.test_filtered_page_continues_after_the_cursor = function()
    local User, calls = scoped(tuples_of({ { 30, 6 } }))
    local page = User.scan():scope('adults'):limit(2):after({ id = 3, age = 30 }):all()

    t.assert_equals(helper.ids(page), { 4, 5 })
    t.assert_equals(calls[1].after, 3)
end

-- Курсор от другой выборки: раньше её начала он до `box` не доходит —
-- после него идёт вся выборка, а `box` отверг бы его исключением. За концом
-- выборки на равенство страница пуста, и индекс не спрашивается вовсе.
-- С условием так же: курсор уходит и в обход кусками.
g.test_cursor_outside_the_selection_never_reaches_box = function()
    local User, calls = scoped(tuples_of({ { 30, 2 }, { 40, 1 } }))
    local early = { age = 5, id = 3 }
    local late = { age = 31, id = 1 }

    t.assert_equals(helper.ids(User.where('age', '>=', 30):after(early):all()), { 1, 2, 3 })
    t.assert_equals(helper.ids(User.where('age', '>=', 30):scope('adults'):after(early):all()), { 1, 2, 3 })
    t.assert_equals(calls, {
        { name = 'select', key = { 30 }, iterator = 'GE', limit = 100, after = false },
        { name = 'select', key = { 30 }, iterator = 'GE', limit = 1000, after = false },
    })
    t.assert_equals(User.where('age', '=', 30):after(late):all(), {})
    t.assert_equals(User.where('age', '=', 30):scope('adults'):after(late):all(), {})
    t.assert_equals(#calls, 2, 'за концом равенства box не спрашивается')
end

-- Верхняя граница `between` кончает обход и с условиями: дальше
-- по индексу записи только больше.
g.test_filtered_range_stops_at_the_upper_bound = function()
    local tuples = { { 1, 'a', 20 }, { 2, 'b', 20 }, { 3, 'a', 25 }, { 4, 'a', 40 } }
    local User = scoped(tuples)

    t.assert_equals(helper.ids(User.where('age', 'between', { 20, 30 }):scope('named', 'a'):all()), { 1, 3 })
    t.assert_equals(User.where('age', 'between', { 20, 30 }):scope('named', 'a'):count(), 2)
    t.assert_equals(User.where('age', 'between', { 20, 25 }):scope('named', 'b'):count(), 1)
end

-- Кусок, в котором запись ушла за границу, — последний и с условием:
-- дальше по индексу записи только больше, и следующий кусок не читается.
g.test_filtered_walk_reads_no_chunk_past_the_upper_bound = function()
    local User, calls = scoped(tuples_of({ { 20, 1500 }, { 40, 1000 } }))

    t.assert_equals(User.where('age', 'between', { 20, 30 }):scope('adults'):count(), 1500)
    t.assert_equals(#calls, 2, 'третий кусок целиком за границей')
    t.assert_equals(#User.where('age', 'between', { 20, 30 }):scope('adults'):limit(2000):all(), 1500)
    t.assert_equals(#calls, 4)
end

-- Смещение ноль — то же, что без смещения: страница с первой подошедшей.
g.test_filtered_zero_offset_skips_nothing = function()
    local User = scoped(tuples_of({ { 10, 2 }, { 30, 3 } }))

    t.assert_equals(helper.ids(User.scan():scope('adults'):limit(2):offset(0):all()), { 3, 4 })
    t.assert_equals(helper.ids(User.scan():scope('adults'):limit(2):all()), { 3, 4 })
end

-- Счёт с условием обходит выборку целиком: `index:count` условий не знает.
-- Уступка — после каждого полного куска, перед следующим.
g.test_filtered_count_walks_the_whole_selection = function()
    local User, calls, yields = scoped(tuples_of({ { 10, 1500 }, { 30, 1000 } }))

    t.assert_equals(User.scan():scope('adults'):count(), 1000)
    t.assert_equals(yields(), 2, 'два полных куска — две уступки')
    t.assert_equals(calls, {
        { name = 'select', key = {}, iterator = 'ALL', limit = 1000, after = false },
        { name = 'select', key = {}, iterator = 'ALL', limit = 1000, after = 1000 },
        { name = 'select', key = {}, iterator = 'ALL', limit = 1000, after = 2000 },
    })
end

-- Выборка, кончившаяся ровно на границе куска: следующий кусок приходит
-- пустым, и обход кончается на нём.
g.test_filtered_walk_ends_on_an_empty_chunk_after_a_full_one = function()
    local User, calls, yields = scoped(tuples_of({ { 30, 2000 } }))

    t.assert_equals(User.scan():scope('adults'):count(), 2000)
    t.assert_equals(yields(), 2, 'два полных куска и пустой третий')
    t.assert_equals(#calls, 3)
end

-- Выборка короче куска — один кусок без единой уступки: уступать перед
-- первым куском незачем, и короткий счёт видит один снимок.
g.test_short_filtered_walk_does_not_yield = function()
    local User, calls, yields = scoped(tuples_of({ { 10, 3 }, { 30, 7 } }))

    t.assert_equals(User.scan():scope('adults'):count(), 7)
    t.assert_equals(helper.ids(User.scan():scope('adults'):limit(2):all()), { 4, 5 })
    t.assert_equals(yields(), 0)
    t.assert_equals(#calls, 2)
end

-- В транзакции уступать нельзя: выборка с условием идёт теми же кусками
-- без уступок.
g.test_filtered_walk_inside_a_transaction_does_not_yield = function()
    local User, calls, yields = scoped(tuples_of({ { 30, 1500 } }), true)

    t.assert_equals(User.scan():scope('adults'):count(), 1500)
    t.assert_equals(#User.scan():scope('adults'):limit(1200):all(), 1200)
    t.assert_equals(yields(), 0)
    t.assert_equals(#calls, 4)
end

-- Спейс, снесённый соседом, пока обход стоял на уступке: box отказывает
-- на втором куске, и модель отвечает отказом узла парой, а не исключением
-- из глубины box. Прочитанное до отказа не отдаётся: итог неполон.
g.test_filtered_walk_broken_midway_is_a_refusal = function()
    local User, calls = scoped(tuples_of({ { 10, 1500 }, { 30, 10 } }), false, 2)
    local none, err = User.scan():scope('adults'):all()

    t.assert_equals(none, nil)
    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(
        tostring(err),
        "выборка users с условием оборвана: Space '516' does not exist"
    )
    t.assert_equals(#calls, 2, 'после отказа обход не продолжается')

    local Counting = scoped(tuples_of({ { 10, 1500 }, { 30, 10 } }), false, 2)
    local nothing, broken = Counting.scan():scope('adults'):count()

    t.assert_equals(nothing, nil)
    t.assert_equals(broken.kind, 'unavailable')
end

-- Отказ на первом куске — не про уступку: перед первым куском обход
-- не уступал, мир под ним не менялся, и негодный индекс либо итератор
-- остаётся ошибкой программиста, как у `select` без условий.
g.test_filtered_walk_broken_on_the_first_chunk_throws = function()
    local User, _, yields = scoped(tuples_of({ { 10, 1500 }, { 30, 10 } }), false, 1)

    t.assert_error_msg_contains("Space '516' does not exist", function()
        return User.scan():scope('adults'):count()
    end)
    t.assert_equals(yields(), 0, 'перед первым куском уступки нет')
end

-- Внутри транзакции обход не уступал, и отказ box на втором куске —
-- честная поломка: съеденный срез файбера, а не снесённый спейс.
-- Проглоченный, он превратил бы обречённую транзакцию в невнятный отказ
-- чтения — и летит исключением, как из глубины box.
g.test_filtered_walk_inside_a_transaction_throws_the_box_error_as_is = function()
    local User = bound(tuples_of({ { 10, 1500 }, { 30, 10 } }), true, 2, 'fiber slice is exceeded', SCOPES)

    t.assert_error_msg_contains('fiber slice is exceeded', function()
        return User.scan():scope('adults'):count()
    end)
end
