--- Шлюз `local` на двойнике `box`: счёт по диапазону с верхней границей.
---
--- Настоящий `box` живёт в дочернем узле (`local_live_test`), и там же
--- проверено главное — что уступка спасает от среза файбера. Здесь
--- двойник: он записывает, чем именно шлюз просит записи у индекса, —
--- размер куска, продолжение и число уступок, — а на живом узле этого
--- не увидеть, не подменив сам индекс.

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
            if item == wanted then
                return position
            end
        end

        error('двойник индекса: продолжение с чужого кортежа')
    end

    local index = {}

    -- Точкой, а не двоеточием: сам двойник себя не разглядывает,
    -- а шлюз зовёт через двоеточие — место для `self` в аргументах есть.
    function index.count(_, key, opts)
        table.insert(calls, { name = 'count', key = key, iterator = opts.iterator })

        return #tuples
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

        if selects == breaking then
            error(text or GONE)
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
---@return any User
---@return table[] calls Обращения к индексу
---@return fun(): integer yields Сколько раз шлюз уступил
local function bound(tuples, in_transaction, breaking, text)
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

    local User = helper.users(model)

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

-- Диапазон длиннее куска берётся кусками по тысяче записей, перед каждым
-- куском — уступка, а продолжение идёт с последнего кортежа куска.
-- Обход целиком, одним обращением, съедал бы срез файбера.
g.test_range_count_walks_in_chunks_of_a_thousand_with_a_yield_before_each = function()
    local User, calls, yields = bound(tuples_of({ { 30, 2500 } }), false)

    t.assert_equals(User.where('age', 'between', { 30, 31 }):count(), 2500)
    t.assert_equals(yields(), 3, 'две с половиной тысячи по тысяче — три куска')
    t.assert_equals(calls, {
        { name = 'select', key = { 30 }, iterator = 'GE', limit = 1000, after = false },
        { name = 'select', key = { 30 }, iterator = 'GE', limit = 1000, after = 1000 },
        { name = 'select', key = { 30 }, iterator = 'GE', limit = 1000, after = 2000 },
    })
end

-- Кусок, в котором нашлась запись за верхней границей, — последний:
-- дальше по индексу только записи ещё больше.
g.test_range_count_stops_at_the_chunk_that_crossed_the_upper_bound = function()
    local User, calls, yields = bound(tuples_of({ { 30, 1500 }, { 31, 1000 } }), false)

    t.assert_equals(User.where('age', 'between', { 30, 30 }):count(), 1500)
    t.assert_equals(yields(), 2)
    t.assert_equals(
        #calls,
        2,
        'третий кусок не нужен: граница пройдена во втором'
    )
end

-- Внутри транзакции уступок нет: уступка обрывает транзакцию memtx
-- и унесла бы с собой чужую работу. Считается то же самое, но узел
-- на время счёта никому не отвечает — цена названа в документе.
g.test_range_count_inside_a_transaction_counts_the_same_without_yielding = function()
    local User, calls, yields = bound(tuples_of({ { 30, 2500 } }), true)

    t.assert_equals(User.where('age', 'between', { 30, 31 }):count(), 2500)
    t.assert_equals(yields(), 0, 'уступка оборвала бы транзакцию')
    t.assert_equals(#calls, 3)
end

-- Диапазон, кончившийся ровно на границе куска: следующий кусок приходит
-- пустым, и обход кончается на нём, а не считает пустоту за границу.
g.test_range_count_ends_on_an_empty_chunk_after_a_full_one = function()
    local User, calls, yields = bound(tuples_of({ { 30, 2000 } }), false)

    t.assert_equals(User.where('age', 'between', { 30, 31 }):count(), 2000)
    t.assert_equals(yields(), 3, 'два полных куска и пустой третий')
    t.assert_equals(#calls, 3)
end

-- Диапазон без верхней границы обходить нечем и незачем: его считает
-- сам индекс, одним обращением и без уступок.
g.test_count_without_an_upper_bound_asks_the_index_itself = function()
    local User, calls, yields = bound(tuples_of({ { 30, 2500 } }), false)

    t.assert_equals(User.where('age', '>=', 30):count(), 2500)
    t.assert_equals(yields(), 0)
    t.assert_equals(calls, { { name = 'count', key = { 30 }, iterator = 'GE' } })
end

-- Спейс, снесённый соседом, пока обход стоял на уступке: box отказывает
-- на втором куске, и модель отвечает отказом узла парой, а не исключением
-- из глубины box. Посчитанное до отказа не отдаётся: счёт неполон.
g.test_range_count_broken_midway_is_a_refusal_not_a_throw = function()
    local User, calls = bound(tuples_of({ { 30, 2500 } }), false, 2)
    local counted, err = User.where('age', 'between', { 30, 31 }):count()

    t.assert_equals(counted, nil)
    t.assert_equals(err.kind, 'unavailable')
    t.assert_str_contains(tostring(err), 'счёт по диапазону users оборван')
    t.assert_str_contains(tostring(err), "Space '516' does not exist")
    t.assert_equals(#calls, 2, 'после отказа обход не продолжается')
end

-- Отказ на первом куске — не про уступку: до неё мир не менялся,
-- и негодный индекс либо итератор остаётся ошибкой программиста,
-- как у `select`.
g.test_range_count_broken_on_the_first_chunk_throws = function()
    local User = bound(tuples_of({ { 30, 2500 } }), false, 1)

    local ok, thrown = pcall(function()
        return User.where('age', 'between', { 30, 31 }):count()
    end)

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(thrown), "Space '516' does not exist")
end

-- Внутри транзакции обход не уступал, и отказ box на втором куске —
-- честная поломка: съеденный срез файбера, а не снесённый спейс.
-- Проглоченный, он превратил бы обречённую транзакцию в невнятный отказ
-- чтения — и летит исключением, как из глубины box.
g.test_range_count_inside_a_transaction_throws_the_box_error_as_is = function()
    local User = bound(tuples_of({ { 30, 2500 } }), true, 2, 'fiber slice is exceeded')

    local ok, thrown = pcall(function()
        return User.where('age', 'between', { 30, 31 }):count()
    end)

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(thrown), 'fiber slice is exceeded')
end
