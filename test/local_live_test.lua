--- Модель на настоящем `box` одиночного узла: миграция, шлюз `local`,
--- страницы по индексу, транзакция, реплика только для чтения, функции
--- узла с данными и шлюз хранилища vshard с полем шардирования.
---
--- Узел поднят без кластерной конфигурации: это и есть «одиночный узел
--- без шардирования» — конфигурации нет, роли шардирования нет, шлюз
--- `local`, поля `bucket_id` в кортеже нет.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.local_live')

--- Сколько записей в длинном диапазоне.
---
--- Столько же, сколько в сверке на 3.8: обход их итератором в транзакции
--- идёт от 0,1 с и срывается срезом файбера, а два счёта по индексу — нет.
--- Меньше трёхсот тысяч — и проверка перестала бы отличать одно
--- от другого.
local RECORDS = 300000

--- Срез файбера на время счёта, секунды.
---
--- Двадцать миллисекунд — та же мера, что у чистки кэша: обход идёт
--- около 2,7 млн записей в секунду, и настоящий срез ядра поймал бы ту же
--- поломку только на третьем миллионе — столько записей проверка клала бы
--- в спейс секунды.
local SLICE = 0.02

g.before_all(function()
    -- Памяти узлу — с запасом под длинный диапазон: триста тысяч записей
    -- с двумя индексами занимают около 45 МБ арены, а умолчание оснастки
    -- (64 МБ) оставило бы проверку на самой границе.
    g.server = helper.start_box({ memtx_memory = 256 * 1024 * 1024 })
    g.server:exec(function(layout)
        ---@type any
        local model = package.loaded['tnt.model']

        layout.methods = {
            is_adult = function(self)
                return self.age >= 18
            end,
        }

        rawset(_G, 'User', model.define(layout))
        rawset(_G, 'model', model)

        -- Схема и привязка — один раз на узел, как при применении
        -- конфигурации; проверки ниже смотрят на них.
        box.atomic(rawget(_G, 'User').migration(), box)

        local binding = model.bind({ rawget(_G, 'User') }, model.settings(nil))

        binding.attach()
        rawset(_G, 'binding', binding)
    end, { helper.users_layout() })
end)

g.after_all(function()
    helper.stop_node(g.server)
end)

g.before_each(function()
    g.server:exec(function()
        box.cfg({ read_only = false })
        box.space.users:truncate()
    end)
end)

g.test_migration_binding_and_the_whole_access_path = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')
        ---@type any
        local binding = rawget(_G, 'binding')
        local names = {}

        for _, field in ipairs(box.space.users:format()) do
            table.insert(names, field.name .. ':' .. field.type .. (field.is_nullable and '?' or ''))
        end

        local created = User.create({ id = 1, name = ' Мария ', age = 46 })
        local _, twice = User.create({ id = 1, name = 'Мария', age = 46 })
        local found = User.find(1)
        local record = User.validate({ id = 2, name = 'Иван', age = 30, email = 'i@x.ru' })

        record:save()
        record.age = 31
        record:save()

        for id = 3, 6 do
            User.factory({ id = id, name = 'Клиент ' .. id, age = 10 * id }):save()
        end

        local ids = function(rows)
            local listed = {}

            for _, row in ipairs(rows) do
                table.insert(listed, row.id)
            end

            return listed
        end

        local adults = User.where('age', '>=', 30):limit(2):all()
        local next_page = User.where('age', '>=', 30):limit(2):after(adults[#adults]):all()
        local total = model.atomic(function()
            User.create({ id = 7, name = 'Семь', age = 7 })

            return User.scan():count()
        end)
        local ok, rolled = pcall(model.atomic, function()
            User.create({ id = 8, name = 'Восемь', age = 8 })
            error('откат', 0)
        end)

        return {
            format = names,
            indexes = {
                primary = box.space.users.index.primary.unique,
                age = box.space.users.index.age.unique,
                bucket = box.space.users.index.bucket_id,
            },
            source = binding.source,
            status = binding.status(),
            bound = User.bound(),
            created = created:to_table(),
            adult = created:is_adult(),
            twice = { kind = twice.kind, text = tostring(twice) },
            found = found:to_table(),
            saved = User.find(2):to_table(),
            missing = User.find(404),
            adults = ids(adults),
            next_page = ids(next_page),
            younger = ids(User.where('age', '<', 30):all()),
            up_to = ids(User.where('age', '<=', 30):all()),
            older = ids(User.where('age', '>', 46):all()),
            between = ids(User.where('age', 'between', { 30, 46 }):all()),
            between_count = User.where('age', 'between', { 30, 46 }):count(),
            exact = ids(User.where('id', '=', 3):all()),
            first = User.where('age', '>=', 40):first().id,
            counted = User.where('age', '>=', 30):count(),
            scanned = ids(User.scan():limit(3):all()),
            scanned_after = ids(User.scan():limit(3):after({ id = 3 }):all()),
            total = total,
            rolled = { ok, rolled, User.find(8) },
            deleted = { User.delete(7), User.delete(7) },
            record_deleted = User.find(6):delete(),
            left = User.scan():count(),
        }
    end)

    t.assert_equals(seen.format, { 'id:unsigned', 'name:string', 'age:unsigned', 'email:string?' })
    t.assert_equals(seen.indexes, { primary = true, age = false })
    t.assert_equals(seen.source, 'local')
    t.assert_equals(seen.status, { source = 'local', sharded = false, serves = true, spaces = { 'users' } })
    t.assert_equals(seen.bound, 'local')
    t.assert_equals(seen.created, { id = 1, name = 'Мария', age = 46 })
    t.assert_equals(seen.adult, true)
    t.assert_equals(
        seen.twice,
        { kind = 'conflict', text = 'запись users с таким ключом уже есть' }
    )
    t.assert_equals(seen.found, { id = 1, name = 'Мария', age = 46 })
    t.assert_equals(seen.saved, { id = 2, name = 'Иван', age = 31, email = 'i@x.ru' })
    t.assert_equals(seen.missing, nil)
    t.assert_equals(seen.adults, { 3, 2 }, 'по возрасту: 30 (id 3), 31 (id 2)')
    t.assert_equals(
        seen.next_page,
        { 4, 1 },
        'страница продолжается после последней записи'
    )
    t.assert_equals(seen.younger, { 7 }, 'запись из транзакции видна')
    t.assert_equals(seen.up_to, { 3, 7 }, 'по убыванию')
    t.assert_equals(seen.older, { 5, 6 })
    t.assert_equals(seen.between, { 3, 2, 4, 1 })
    t.assert_equals(seen.between_count, 4)
    t.assert_equals(seen.exact, { 3 })
    t.assert_equals(seen.first, 4)
    t.assert_equals(seen.counted, 6)
    t.assert_equals(seen.scanned, { 1, 2, 3 })
    t.assert_equals(seen.scanned_after, { 4, 5, 6 })
    t.assert_equals(seen.total, 7)
    t.assert_equals(seen.rolled, { false, 'откат' })
    t.assert_equals(seen.deleted, { true, false })
    t.assert_equals(seen.record_deleted, true)
    t.assert_equals(seen.left, 5)
end

-- Страница по номеру — смещение `box`: записи идут порядком индекса,
-- граница `between` режет страницу после пропуска, смещение складывается
-- с курсором и доходит до узла с данными по проводу.
g.test_pages_by_number_skip_records_in_index_order = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')

        for id = 1, 7 do
            assert(User.create({ id = id, name = 'Клиент ' .. id, age = 20 + (id % 4) * 10 }))
        end

        local pages = {}

        for number = 1, 4 do
            pages[number] = User.where('age', '>=', 20):limit(3):offset((number - 1) * 3):all()
        end

        return {
            pages = pages,
            descending = User.where('age', '<=', 50):limit(2):offset(2):all(),
            between = User.where('age', 'between', { 30, 40 }):limit(2):offset(1):all(),
            beyond_bound = User.where('age', 'between', { 30, 40 }):limit(2):offset(4):all(),
            after = User.scan():after({ id = 2 }):offset(2):limit(2):all(),
            first = User.where('age', '>=', 20):offset(4):first().id,
            deepest = User.scan():offset(model.OFFSET):all(),
            longest = User.scan():limit(model.OFFSET):offset(5):all(),
            cut = {
                pcall(function()
                    return User.scan():limit(model.OFFSET + 6)
                end),
            },
            counted = User.where('age', '>=', 20):offset(5):count(),
            wire = rawget(_G, 'binding').functions.tnt_model_select('users', {
                index = 'age',
                iterator = 'GE',
                key = { 30 },
                limit = 2,
                offset = 2,
            }),
        }
    end)

    -- Возраст по id: 1 — 30, 2 — 40, 3 — 50, 4 — 20, 5 — 30, 6 — 40, 7 — 50;
    -- в индексе по возрасту равные идут порядком первичного ключа.
    local pages = {}

    for number, rows in ipairs(seen.pages) do
        pages[number] = helper.ids(rows)
    end

    t.assert_equals(pages, { { 4, 1, 5 }, { 2, 6, 3 }, { 7 }, {} })
    t.assert_equals(helper.ids(seen.descending), { 6, 2 }, 'по убыванию: 50 (7, 3), затем 40 (6, 2)')
    t.assert_equals(helper.ids(seen.between), { 5, 2 })
    t.assert_equals(
        helper.ids(seen.beyond_bound),
        {},
        'граница режет страницу после пропуска'
    )
    t.assert_equals(helper.ids(seen.after), { 5, 6 }, 'смещение отсчитывается от курсора')
    t.assert_equals(seen.first, 6)
    t.assert_equals(seen.deepest, {}, 'самое большое смещение box не обрезает')
    t.assert_equals(helper.ids(seen.longest), { 6, 7 }, 'и самую длинную страницу тоже')
    t.assert_equals(
        seen.cut,
        { false, 'модель users: limit — целое число от 1 до 4294967295, а не 4294967301' },
        'больший предел box обрезал бы до шести записей'
    )
    t.assert_equals(seen.counted, 7, 'счёт смещения не знает')
    t.assert_equals(seen.wire.ok, true)
    t.assert_equals(helper.ids(seen.wire.value), { 2, 6 }, 'от 30: 1, 5, затем 2, 6')
end

-- Курсор страницы приходит от клиента, чаще всего JSON-ом: строка, `-1`
-- и `null` в нём — отказ `invalid` до `box`. Без проверки `box` бросал бы
-- на каждый из них «Iterator position is invalid»: на узле с данными —
-- исключением, через роутер — отказом `unavailable`, бедой хранилища.
g.test_bad_cursor_values_are_refused_before_box = function()
    local seen = g.server:exec(function()
        local json = require('json')
        ---@type any
        local User = rawget(_G, 'User')

        assert(User.create({ id = 1, name = 'Мария', age = 46 }))
        assert(User.create({ id = 2, name = 'Иван', age = 30 }))

        -- Страница после курсора из тела запроса: ключи либо отказ.
        local page_after = function(body)
            local rows, err = User.where('age', '>=', 18):after(json.decode(body)):all()

            if rows == nil then
                return { kind = err.kind, fields = err.fields }
            end

            local ids = {}

            for position, row in ipairs(rows) do
                ids[position] = row.id
            end

            return ids
        end

        return {
            text = page_after('{"age": "x", "id": 1}'),
            negative = page_after('{"age": -1, "id": 1}'),
            null = page_after('{"age": null, "id": 1}'),
            good = page_after('{"age": 30, "id": 2}'),
        }
    end)

    t.assert_equals(seen.text, {
        kind = 'invalid',
        fields = { age = "должно быть целым числом не меньше 0, а не 'x'" },
    })
    t.assert_equals(seen.negative, {
        kind = 'invalid',
        fields = { age = 'должно быть целым числом не меньше 0, а не -1' },
    })
    t.assert_equals(seen.null, { kind = 'invalid', fields = { age = 'обязательное поле' } })
    t.assert_equals(seen.good, { 1 }, 'годный курсор: после 30 (id 2) — 46 (id 1)')
end

-- Курсор от другой выборки: клиент продолжает страницу записью, которой
-- в этой выборке нет. Страница — записи выборки строго после курсора:
-- раньше начала выборки курсор отдаёт её целиком, за концом — пустую
-- страницу, как шлюз `sql`. Настоящий `box` бросал на первое «Iterator
-- position is invalid», у `=` — и на второе, а у `>` и `<` курсор
-- со значением самого ключа принимал и отдавал записи с этим значением,
-- которых в выборке нет. Смещение, `first` и функции узла с данными
-- ведут себя так же, счёт курсора не знает.
g.test_cursor_from_another_selection_pages_it_whole_or_ends_it = function()
    local seen = g.server:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local fn = rawget(_G, 'binding').functions

        -- По индексу возраста: (5, 4), (100, 1), (100, 2), (100, 5), (120, 3), (149, 6).
        for id, age in ipairs({ 100, 100, 120, 5, 100, 149 }) do
            assert(User.create({ id = id, name = 'Клиент ' .. id, age = age }))
        end

        --- Ключи страницы по порядку выдачи.
        local function ids(query)
            local keys = {}

            for position, row in ipairs(assert(query:all())) do
                keys[position] = row.id
            end

            return keys
        end

        local early = { age = 5, id = 1 }
        local wire = { index = 'age', iterator = 'GE', key = { 100 }, limit = 10, after = early }

        return {
            from_before = ids(User.where('age', '>=', 100):after(early)),
            from_key = ids(User.where('age', '>=', 100):after({ age = 100, id = 2 })),
            from_inside = ids(User.where('age', '>=', 100):after({ age = 149, id = 1 })),
            above_key = ids(User.where('age', '>', 100):after({ age = 100, id = 1 })),
            above_before = ids(User.where('age', '>', 100):after({ age = 99, id = 7 })),
            below_key = ids(User.where('age', '<', 100):after({ age = 100, id = 5 })),
            down_before = ids(User.where('age', '<=', 100):after({ age = 120, id = 1 })),
            down_key = ids(User.where('age', '<=', 100):after({ age = 100, id = 2 })),
            equal_before = ids(User.where('age', '=', 100):after({ age = 5, id = 9 })),
            equal_key = ids(User.where('age', '=', 100):after({ age = 100, id = 1 })),
            equal_after = ids(User.where('age', '=', 100):after({ age = 120, id = 1 })),
            range_before = ids(User.where('age', 'between', { 100, 120 }):after(early)),
            range_after = ids(User.where('age', 'between', { 100, 120 }):after({ age = 149, id = 1 })),
            skipped = ids(User.where('age', '>=', 100):after(early):offset(1):limit(2)),
            first = User.where('age', '>=', 100):after(early):first().id,
            counted = User.where('age', '>=', 100):after(early):count(),
            wire_before = fn.tnt_model_select('users', wire),
            wire_after = fn.tnt_model_select(
                'users',
                { index = 'age', iterator = 'EQ', key = { 100 }, limit = 10, after = { age = 120, id = 1 } }
            ),
        }
    end)

    t.assert_equals(
        seen.from_before,
        { 1, 2, 5, 3, 6 },
        'курсор раньше начала — вся выборка'
    )
    t.assert_equals(
        seen.from_key,
        { 5, 3, 6 },
        'курсор на ключе — в выборке, запись 1 до него'
    )
    t.assert_equals(seen.from_inside, { 6 })
    t.assert_equals(seen.above_key, { 3, 6 }, 'записей возраста 100 в выборке > 100 нет')
    t.assert_equals(seen.above_before, { 3, 6 })
    t.assert_equals(seen.below_key, { 4 }, 'записей возраста 100 в выборке < 100 нет')
    t.assert_equals(
        seen.down_before,
        { 5, 2, 1, 4 },
        'по убыванию раньше начала — больше ключа'
    )
    t.assert_equals(seen.down_key, { 1, 4 })
    t.assert_equals(seen.equal_before, { 1, 2, 5 })
    t.assert_equals(seen.equal_key, { 2, 5 })
    t.assert_equals(
        seen.equal_after,
        {},
        'курсор за концом равенства — пустая страница'
    )
    t.assert_equals(seen.range_before, { 1, 2, 5, 3 })
    t.assert_equals(
        seen.range_after,
        {},
        'курсор за верхней границей — пустая страница'
    )
    t.assert_equals(seen.skipped, { 2, 5 }, 'смещение — от начала выборки')
    t.assert_equals(seen.first, 1)
    t.assert_equals(seen.counted, 5)
    t.assert_equals(seen.wire_before.ok, true)
    t.assert_equals(helper.ids(seen.wire_before.value), { 1, 2, 5, 3, 6 })
    t.assert_equals(seen.wire_after, { ok = true, value = {} })
end

-- Ключи за точностью double: `box` отдаёт целые от 10^14 cdata, и запись
-- с таким ключом обязана проходить собственную проверку в `find` и `save`.
-- 2^53 и 2^53 + 1 рядом нарочно: число Lua их не различает, и приведение
-- к нему слило бы две записи в одну.
g.test_keys_beyond_double_precision_keep_every_digit = function()
    local seen = g.server:exec(function()
        local json = require('json')
        local msgpack = require('msgpack')

        ---@type any
        local User = rawget(_G, 'User')
        ---@type any
        local binding = rawget(_G, 'binding')
        local max = 18446744073709551615ULL
        local exact = 9007199254740992ULL

        --- Ключи страницы цифрами вместе с родом: 7 и 7ULL для `==` равны.
        local function ids(rows)
            local listed = {}

            for _, row in ipairs(rows) do
                table.insert(listed, tostring(row.id))
            end

            return listed
        end

        assert(User.create({ id = 7, name = 'Семь', age = 30 }))
        assert(User.create({ id = 1e14, name = 'Граница', age = 30 }))
        assert(User.create({ id = exact, name = 'Точный', age = 30 }))
        assert(User.create(json.decode('{"id": 9007199254740993, "name": "Из JSON", "age": 30}')))
        assert(User.create({ id = max, name = 'Последний', age = 30 }))

        local _, twice = User.create({ id = max, name = 'Снова', age = 30 })
        local found = User.find(max)

        found.age = 31
        assert(found:save())

        local bound = User.find(1e14)

        bound.name = 'Граница снова'
        assert(bound:save())

        local first = User.where('age', '>=', 30):limit(2):all()
        local second = User.where('age', '>=', 30):limit(2):after(first[#first]):all()
        local third = User.where('age', '>=', 30):limit(2):after(second[#second]):all()
        local above = User.where('id', '>', exact):limit(1):all()
        local reply = binding.functions.tnt_model_find('users', max)

        return {
            twice = twice.kind,
            found = { tostring(User.find(max).id), User.find(max).name, User.find(max).age },
            json = json.encode(User.find(max):to_table()),
            bound = { tostring(User.find(1e14).id), User.find(1e14).name },
            neighbours = { User.find(exact).name, User.find(9007199254740993ULL).name },
            pages = { ids(first), ids(second), ids(third) },
            above = ids(above),
            above_after = ids(User.where('id', '>', exact):limit(1):after(above[1]):all()),
            from_exact = ids(User.where('id', '>=', exact):all()),
            below_max = ids(User.where('id', '<', max):limit(2):all()),
            between = ids(User.where('id', 'between', { exact, max }):all()),
            between_count = User.where('id', 'between', { exact, max }):count(),
            between_mixed = User.where('id', 'between', { 7, exact }):count(),
            between_reversed = User.where('id', 'between', { max, exact }):count(),
            exact_max = ids(User.where('id', '=', max):all()),
            wire = tostring(msgpack.decode(msgpack.encode(reply)).value.id),
            refused = tostring(select(2, User.find(-1LL))),
            deleted = { User.delete(max), User.delete(max), User.find(max) },
            tuple = tostring(assert(box.space.users:get(9007199254740993ULL))[1]),
        }
    end)

    t.assert_equals(seen.twice, 'conflict')
    t.assert_equals(seen.found, { '18446744073709551615ULL', 'Последний', 31 })
    t.assert_str_contains(seen.json, '"id":18446744073709551615')
    t.assert_equals(
        seen.bound,
        { '100000000000000ULL', 'Граница снова' },
        'с 10^14 box отдаёт cdata, и save его принимает'
    )
    t.assert_equals(seen.neighbours, { 'Точный', 'Из JSON' })
    t.assert_equals(seen.pages, {
        { '7', '100000000000000ULL' },
        { '9007199254740992ULL', '9007199254740993ULL' },
        { '18446744073709551615ULL' },
    })
    t.assert_equals(seen.above, { '9007199254740993ULL' })
    t.assert_equals(seen.above_after, { '18446744073709551615ULL' })
    t.assert_equals(seen.from_exact, { '9007199254740992ULL', '9007199254740993ULL', '18446744073709551615ULL' })
    t.assert_equals(seen.below_max, { '9007199254740993ULL', '9007199254740992ULL' }, 'по убыванию')
    t.assert_equals(seen.between, { '9007199254740992ULL', '9007199254740993ULL', '18446744073709551615ULL' })
    t.assert_equals(seen.between_count, 3)
    t.assert_equals(seen.between_mixed, 3, 'число Lua снизу, cdata сверху')
    t.assert_equals(seen.between_reversed, 0, 'верхняя граница ниже нижней')
    t.assert_equals(seen.exact_max, { '18446744073709551615ULL' })
    t.assert_equals(
        seen.wire,
        '18446744073709551615ULL',
        'ответ функции узла несёт ключ целиком'
    )
    t.assert_equals(
        seen.refused,
        'запись users не прошла проверку: id — должно быть целым числом не меньше 0, а не -1'
    )
    t.assert_equals(seen.deleted, { true, false })
    t.assert_equals(seen.tuple, '9007199254740993ULL')
end

-- Число Lua за пределом целого рода `box` не кладёт: он видит в нём
-- `double` и бросает «expected unsigned, got double». Приходит такое число
-- снаружи — `json.decode('{"id": 1e20}')`, — и модель отвечает на него
-- отказом `invalid` до `box`. Крайние числа в пределе рода `box` берёт:
-- граница модели проведена там же, где у него.
g.test_lua_numbers_beyond_the_kind_are_refused_before_box = function()
    local seen = g.server:exec(function()
        local json = require('json')
        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')

        --- Отказ вызова: род и поля.
        local function refused(_, err)
            return { err.kind, err.fields }
        end

        local result = {
            created = refused(User.create(json.decode('{"id": 1e20, "name": "Мария", "age": 46}'))),
            found = refused(User.find(2 ^ 64)),
            ranged = refused(User.where('id', '>=', 1e20):all()),
            cursor = refused(User.where('age', '>=', 18):after({ age = 20, id = 2 ^ 64 }):all()),
            edge = tostring(assert(User.create({ id = 2 ^ 64 - 2048, name = 'Край', age = 30 })).id),
            found_edge = User.find(2 ^ 64 - 2048).name,
        }

        local Ledger = model.define({
            space = 'ledger',
            fields = { { 'id', 'unsigned', primary = true }, { 'delta', 'integer' } },
        })

        box.atomic(Ledger.migration(), box)
        model.bind({ Ledger }, model.settings(nil)).attach()

        result.below = refused(Ledger.create({ id = 1, delta = -2 ^ 64 }))
        result.above = refused(Ledger.create({ id = 2, delta = 2 ^ 64 }))
        result.lowest = tostring(assert(Ledger.create({ id = 3, delta = -2 ^ 63 })).delta)
        result.highest = tostring(assert(Ledger.create({ id = 4, delta = 2 ^ 64 - 2048 })).delta)

        box.space.ledger:drop()
        rawget(_G, 'binding').attach()

        return result
    end)

    local beyond = 'должно быть целым числом от 0 до 18446744073709551615, а не %s'
    local whole =
        'должно быть целым числом от -9223372036854775808 до 18446744073709551615, а не %s'

    t.assert_equals(seen.created, { 'invalid', { id = beyond:format('1e+20') } })
    t.assert_equals(seen.found, { 'invalid', { id = beyond:format('1.844674407371e+19') } })
    t.assert_equals(seen.ranged, { 'invalid', { id = beyond:format('1e+20') } })
    t.assert_equals(seen.cursor, { 'invalid', { id = beyond:format('1.844674407371e+19') } })
    t.assert_equals(
        seen.edge,
        '18446744073709549568ULL',
        'наибольший double меньше 2^64 box кладёт целым'
    )
    t.assert_equals(seen.found_edge, 'Край')
    t.assert_equals(seen.below, { 'invalid', { delta = whole:format('-1.844674407371e+19') } })
    t.assert_equals(seen.above, { 'invalid', { delta = whole:format('1.844674407371e+19') } })
    t.assert_equals(seen.lowest, '-9223372036854775808LL')
    t.assert_equals(seen.highest, '18446744073709549568ULL')
end

g.test_read_only_node_serves_reads_and_refuses_writes = function()
    local seen = g.server:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        User.create({ id = 1, name = 'Мария', age = 46 })
        box.cfg({ read_only = true })

        local _, created = User.create({ id = 2, name = 'Иван', age = 30 })
        local _, deleted = User.delete(1)
        local _, saved = User.find(1):save()

        return {
            found = User.find(1).name,
            page = #User.where('age', '>=', 1):all(),
            created = { created.kind, tostring(created) },
            deleted = deleted.kind,
            saved = saved.kind,
        }
    end)

    t.assert_equals(seen.found, 'Мария')
    t.assert_equals(seen.page, 1)
    t.assert_equals(seen.created, { 'readonly', 'узел только для чтения: config' })
    t.assert_equals(seen.deleted, 'readonly')
    t.assert_equals(seen.saved, 'readonly')
end

g.test_missing_space_is_a_refusal_not_a_crash = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        local Ghost = model.define({ space = 'ghosts', fields = { { 'id', 'unsigned', primary = true } } })

        model.bind({ Ghost }, model.settings(nil)).attach()

        local _, found = Ghost.find(1)
        local _, created = Ghost.create({ id = 1 })
        local _, deleted = Ghost.delete(1)
        local _, page = Ghost.scan():all()
        local _, counted = Ghost.scan():count()

        return { tostring(found), created.kind, deleted.kind, page.kind, counted.kind }
    end)

    t.assert_equals(seen, {
        'спейса ghosts нет: схема на узле не поднята',
        'unavailable',
        'unavailable',
        'unavailable',
        'unavailable',
    })
end

g.test_box_errors_beyond_conflict_and_readonly_are_programmer_errors = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        local Odd = model.define({
            space = 'odd',
            fields = { { 'id', 'unsigned', primary = true }, { 'name', 'string' } },
        })

        -- Спейс с чужим форматом: имя объявлено числом, модель шлёт строку.
        local space = box.schema.space.create('odd', {
            format = { { name = 'id', type = 'unsigned' }, { name = 'name', type = 'unsigned' } },
        })

        space:create_index('primary', { parts = { 'id' } })
        model.bind({ Odd }, model.settings(nil)).attach()

        local ok, err = pcall(Odd.create, { id = 1, name = 'строка' })

        return { ok, tostring(err) }
    end)

    t.assert_equals(seen[1], false)
    t.assert_str_contains(seen[2], 'type does not match')
end

-- Отказ `conflict` называет занятый индекс: ключ свободен, а занят логин —
-- и `create`, и `save`. Первичный индекс зовётся ключом, и так же —
-- занятое без имени индекса: такую ошибку триггер спейса собирает кодом.
g.test_conflict_names_the_taken_unique_index = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        local Account = model.define({
            space = 'accounts',
            fields = { { 'id', 'unsigned', primary = true }, { 'login', 'string' } },
            indexes = { login = { parts = { 'login' }, unique = true } },
        })

        box.atomic(Account.migration(), box)
        model.bind({ Account }, model.settings(nil)).attach()

        assert(Account.create({ id = 1, login = 'L' }))

        local other = assert(Account.create({ id = 2, login = 'M' }))

        other.login = 'L'

        ---@type table<string, any[]>
        local refusals = {
            login = { Account.create({ id = 3, login = 'L' }) },
            key = { Account.create({ id = 1, login = 'N' }) },
            saved = { other:save() },
        }

        local errors = box.error --[[@as any]]

        -- Поле по номеру: имени поля кортеж в триггере `before_replace`
        -- не знает.
        box.space.accounts:before_replace(function(_, new)
            if new ~= nil and new[2] == 'X' then
                errors(errors.new({ code = errors.TUPLE_FOUND, reason = 'занято триггером' }))
            end
        end)

        refusals.trigger = { Account.create({ id = 4, login = 'X' }) }

        -- Пустота первым значением: отказ пришёл парой, записи нет.
        local answer = {}

        for name, refusal in pairs(refusals) do
            answer[name] = { refusal[1] == nil, refusal[2].kind, tostring(refusal[2]) }
        end

        answer.stored = Account.where('login', '=', 'L'):count()
        rawget(_G, 'binding').attach()
        box.space.accounts:drop()

        return answer
    end)

    t.assert_equals(seen, {
        login = { true, 'conflict', 'запись accounts с таким login уже есть' },
        key = { true, 'conflict', 'запись accounts с таким ключом уже есть' },
        saved = { true, 'conflict', 'запись accounts с таким login уже есть' },
        trigger = { true, 'conflict', 'запись accounts с таким ключом уже есть' },
        stored = 1,
    })
end

--- Опознаватели устройств по возрастанию: второй отличается от первого
--- узлом, третий — последовательностью, четвёртый — временем.
local IDS = {
    '6ba7b810-9dad-41d1-80b4-00c04fd430c8',
    '6ba7b810-9dad-41d1-80b4-00c04fd430c9',
    '6ba7b810-9dad-41d1-80b5-00c04fd430c8',
    '6ba7b810-9dae-41d1-80b4-00c04fd430c8',
}

--- Владелец трёх первых устройств.
local OWNER = 'c9bf9e57-1685-4c89-bafb-ff5af830be8a'

-- Поле `uuid` спейса держит cdata и строки не примет: без перевода
-- `create` со строкой ловил исключение `box`, а cdata `uuid.new()`
-- отвергала проверка модели. Теперь опознаватель приходит строкой в любом
-- регистре либо cdata на каждом пути — запись, ключ, условие, граница,
-- курсор, область, функции узла с данными, — в `box` лежит cdata, а у
-- записи он строка в нижнем регистре. Счёт диапазона без условий идёт
-- двумя счётами по индексу (`with_deleted`), с условием мягкого
-- удаления — обходом: оба переводят границу. Опознаватели различаются
-- разными полями, и порядок строк сверяется с индексом по каждому,
-- а не только по первому.
g.test_uuid_fields_take_strings_and_cdata_on_every_path = function()
    local seen = g.server:exec(function(ids, owner)
        local json = require('json')
        local msgpack = require('msgpack')
        local uuid = require('uuid')
        ---@type any
        local model = rawget(_G, 'model')
        local Device = model.define({
            space = 'devices',
            fields = {
                { 'id', 'uuid', primary = true },
                { 'owner', 'uuid' },
                { 'name', 'string' },
                { 'parent', 'uuid', optional = true },
                { 'serial', 'uuid', default = uuid.new },
                model.deleted_at(),
            },
            indexes = { owner = { parts = { 'owner' }, unique = false } },
            scopes = {
                of_parent = function(parent)
                    return { { 'parent', '=', parent } }
                end,
            },
        })

        box.atomic(Device.migration(), box)

        local binding = model.bind({ Device }, model.settings(nil))

        binding.attach()

        --- Ключи страницы по порядку.
        local function keys(rows)
            local listed = {}

            for _, row in ipairs(rows) do
                table.insert(listed, row.id)
            end

            return listed
        end

        local ok, result = pcall(function()
            local first = assert(Device.create({ id = ids[1]:upper(), owner = uuid.fromstr(owner), name = 'один' }))

            assert(Device.create({ id = uuid.fromstr(ids[2]), owner = owner, name = 'два', parent = ids[1] }))
            assert(
                Device.create({ id = ids[3], owner = owner:upper(), name = 'три', parent = uuid.fromstr(ids[1]) })
            )
            assert(Device.create({ id = ids[4], owner = ids[1], name = 'четыре' }))

            local raw = assert(box.space.devices:get(uuid.fromstr(ids[1])))
            local saved = assert(Device.find(uuid.fromstr(ids[2])))

            saved.name = 'два снова'
            saved.parent = uuid.fromstr(ids[4])
            assert(saved:save())

            local page = Device.where('owner', '=', uuid.fromstr(owner)):limit(2):all()
            local range = { ids[2], uuid.fromstr(ids[3]) }
            local reply = binding.functions.tnt_model_find('devices', uuid.fromstr(ids[3]))

            return {
                created = { first.id, first.owner, first.name, first.parent == nil },
                kinds = { type(first.id), type(first.owner), type(first.serial), #first.serial },
                stored = { uuid.is_uuid(raw.id), uuid.is_uuid(raw.owner), uuid.is_uuid(raw.serial), raw.parent == nil },
                serial = tostring(raw.serial) == first.serial,
                twice = select(2, Device.create({ id = uuid.fromstr(ids[1]), owner = owner, name = 'снова' })).kind,
                found = {
                    Device.find(ids[1]).name,
                    Device.find(ids[1]:upper()).name,
                    Device.find(uuid.fromstr(ids[1])).name,
                    Device.find({ uuid.fromstr(ids[1]) }).id,
                },
                missing = Device.find(uuid.new()) == nil,
                refused = tostring(select(2, Device.find('нет'))),
                saved = { saved.parent, Device.find(ids[2]).name, Device.find(ids[2]).parent },
                owned = keys(Device.where('owner', '=', owner:upper()):all()),
                pages = { keys(page), keys(Device.where('owner', '=', owner):limit(2):after(page[#page]):all()) },
                every = keys(Device.where('owner', '=', owner):with_deleted():limit(2):after(page[#page]):all()),
                counted = Device.where('owner', '=', uuid.fromstr(owner)):count(),
                above = keys(Device.where('id', '>', uuid.fromstr(ids[1])):all()),
                below = keys(Device.where('id', '<', ids[4]:upper()):all()),
                between = keys(Device.where('id', 'between', range):all()),
                between_every_page = keys(Device.where('id', 'between', range):with_deleted():all()),
                between_count = Device.where('id', 'between', range):count(),
                between_every = Device.where('id', 'between', range):with_deleted():count(),
                scanned = keys(Device.scan():limit(3):after({ id = uuid.fromstr(ids[1]) }):all()),
                scoped = keys(Device.where('owner', '=', owner):scope('of_parent', uuid.fromstr(ids[1])):all()),
                json = json.encode({ id = Device.find(ids[1]).id }),
                wire = { reply.value.id, msgpack.decode(msgpack.encode(reply)).value.parent },
                wire_count = binding.functions.tnt_model_count('devices', {
                    index = 'primary',
                    iterator = 'GE',
                    key = { uuid.fromstr(ids[2]) },
                    to = ids[3]:upper(),
                    limit = 1,
                }).value,
                removed = {
                    Device.delete(uuid.fromstr(ids[4])),
                    Device.find(ids[4]) == nil,
                    Device.restore(ids[4]:upper()),
                    Device.find(ids[4]).name,
                    Device.force_delete(ids[4]),
                    Device.force_delete(uuid.fromstr(ids[4])),
                    box.space.devices:count(),
                },
            }
        end)

        rawget(_G, 'binding').attach()
        box.space.devices:drop()

        return { ok, result }
    end, { IDS, OWNER })

    t.assert(seen[1], seen[2])
    t.assert_equals(seen[2], {
        created = { IDS[1], OWNER, 'один', true },
        kinds = { 'string', 'string', 'string', 36 },
        stored = { true, true, true, true },
        serial = true,
        twice = 'conflict',
        found = { 'один', 'один', 'один', IDS[1] },
        missing = true,
        refused = "запись devices не прошла проверку: id — должно быть UUID, а не 'нет'",
        saved = { IDS[4], 'два снова', IDS[4] },
        owned = { IDS[1], IDS[2], IDS[3] },
        pages = { { IDS[1], IDS[2] }, { IDS[3] } },
        every = { IDS[3] },
        counted = 3,
        above = { IDS[2], IDS[3], IDS[4] },
        below = { IDS[3], IDS[2], IDS[1] },
        between = { IDS[2], IDS[3] },
        between_every_page = { IDS[2], IDS[3] },
        between_count = 2,
        between_every = 2,
        scanned = { IDS[2], IDS[3], IDS[4] },
        scoped = { IDS[3] },
        json = ('{"id":"%s"}'):format(IDS[1]),
        wire = { IDS[3], IDS[1] },
        wire_count = 2,
        removed = { true, true, true, 'четыре', true, false, 3 },
    })
end

g.test_nested_atomic_and_a_second_step_are_box_exceptions = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')
        local nested = {
            pcall(model.atomic, function()
                assert(User.create({ id = 1, name = 'Внешняя', age = 30 }))

                return model.atomic(function() end)
            end),
        }
        local in_box = {
            pcall(box.atomic, function()
                assert(User.create({ id = 2, name = 'Внешняя', age = 30 }))

                return model.atomic(function() end)
            end),
        }
        local step = { pcall(box.atomic, User.migration(), box) }

        return {
            nested = { nested[1], tostring(nested[2]) },
            in_box = { in_box[1], tostring(in_box[2]) },
            left = User.scan():count(),
            in_txn = box.is_in_txn(),
            step = { step[1], tostring(step[2]) },
        }
    end)

    -- Вторую транзакцию внутри первой ядро не открывает, и исключение,
    -- дошедшее до внешней, уносит и её записи.
    local refusal = 'Operation is not permitted when there is an active transaction '

    t.assert_equals(seen.nested, { false, refusal })
    t.assert_equals(seen.in_box, { false, refusal })
    t.assert_equals(seen.left, 0)
    t.assert_equals(seen.in_txn, false)

    -- Шаг схемы не спрашивает, есть ли спейс: второй раз — исключение.
    t.assert_equals(seen.step, { false, "Space 'users' already exists" })
end

g.test_data_node_functions_outlive_close_and_the_model_names_it = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')
        local fresh = model.bind({ User }, model.settings(nil))
        local fn = fresh.functions

        fresh.attach()
        fresh.close()

        local found = { pcall(User.find, 1) }
        local atomic = { pcall(model.atomic, function() end) }
        local put = fn.tnt_model_put('users', { id = 1, name = 'После', age = 30 }, 'insert')
        local read = fn.tnt_model_find('users', { 1 })

        rawget(_G, 'binding').attach()

        return {
            bound = User.bound(),
            found = { found[1], tostring(found[2]) },
            atomic = { atomic[1], tostring(atomic[2]) },
            put = put,
            read = read,
        }
    end)

    t.assert_equals(
        seen.found,
        { false, 'модель users не привязана: привязка закрыта, новой нет' }
    )
    t.assert_equals(seen.atomic, {
        false,
        'model.atomic: у узла нет привязанных моделей — привязка закрыта, новой нет',
    })

    -- Функции узла с шлюзом привязки не связаны: их снимает тот, кто публиковал.
    t.assert_equals(seen.put, { ok = true, value = { id = 1, name = 'После', age = 30 } })
    t.assert_equals(seen.read, { ok = true, value = { id = 1, name = 'После', age = 30 } })
    t.assert_equals(seen.bound, 'local', 'модель вернулась к привязке узла')
end

g.test_data_node_functions_serve_the_whitelist_only = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')
        local binding = model.bind({ User }, model.settings(nil))
        local fn = binding.functions

        binding.attach()
        rawget(_G, 'binding').attach()

        local put = fn.tnt_model_put('users', { id = 1, name = 'Мария', age = 46 }, 'insert')
        local names = {}

        for name in pairs(fn) do
            table.insert(names, name)
        end

        table.sort(names)

        return {
            names = names,
            put = put,
            put_again = fn.tnt_model_put('users', { id = 1, name = 'Мария', age = 46 }, 'insert'),
            put_bad = fn.tnt_model_put('users', { id = 1, name = '', age = 46 }, 'replace'),
            put_mode = fn.tnt_model_put('users', { id = 1, name = 'a', age = 1 }, 'upsert'),
            find = fn.tnt_model_find('users', 1),
            find_missing = fn.tnt_model_find('users', 2),
            find_bad = fn.tnt_model_find('users', 'x'),
            unknown = fn.tnt_model_find('secrets', 1),
            unknown_put = fn.tnt_model_put('secrets', {}, 'insert'),
            unknown_delete = fn.tnt_model_delete('secrets', 1),
            unknown_select = fn.tnt_model_select('secrets', {}),
            unknown_count = fn.tnt_model_count(7, {}),
            select = fn.tnt_model_select('users', { index = 'age', iterator = 'GE', key = { 1 }, limit = 10 }),
            count = fn.tnt_model_count('users', { index = 'primary', iterator = 'ALL', key = {}, limit = 10 }),
            bad_query = { pcall(fn.tnt_model_select, 'users', { index = 'nope' }) },
            bad_after = fn.tnt_model_select('users', {
                index = 'age',
                iterator = 'GE',
                key = { 1 },
                limit = 1,
                after = { id = 1 },
            }),
            delete_bad = fn.tnt_model_delete('users', { 1, 2 }),
            delete = fn.tnt_model_delete('users', 1),
        }
    end)

    t.assert_equals(
        seen.names,
        { 'tnt_model_count', 'tnt_model_delete', 'tnt_model_find', 'tnt_model_put', 'tnt_model_select' }
    )
    t.assert_equals(seen.put, { ok = true, value = { id = 1, name = 'Мария', age = 46 } })
    t.assert_equals(seen.put_again, {
        ok = false,
        kind = 'conflict',
        message = 'запись users с таким ключом уже есть',
    })
    t.assert_equals(seen.put_bad.kind, 'invalid')
    t.assert_equals(
        seen.put_bad.fields.name,
        'должно быть строкой длиной от 1 до 255 знаков, а сейчас 0 знаков'
    )
    t.assert_equals(
        seen.put_mode,
        { ok = false, kind = 'invalid', message = 'способ записи upsert неизвестен' }
    )
    t.assert_equals(seen.find, { ok = true, value = { id = 1, name = 'Мария', age = 46 } })
    t.assert_equals(seen.find_missing, { ok = true })
    t.assert_equals(seen.find_bad.kind, 'invalid')
    t.assert_equals(seen.unknown, {
        ok = false,
        kind = 'unknown',
        message = 'спейс secrets этим узлом не обслуживается',
    })
    t.assert_equals(seen.unknown_put.kind, 'unknown')
    t.assert_equals(seen.unknown_delete.kind, 'unknown')
    t.assert_equals(seen.unknown_select.kind, 'unknown')
    t.assert_equals(seen.unknown_count.message, 'спейс 7 этим узлом не обслуживается')
    t.assert_equals(seen.select, { ok = true, value = { { id = 1, name = 'Мария', age = 46 } } })
    t.assert_equals(seen.count, { ok = true, value = 1 })
    t.assert_equals(seen.bad_query[1], false)
    t.assert_str_contains(seen.bad_query[2], 'выборка не по форме')
    t.assert_equals(seen.bad_after, {
        ok = false,
        kind = 'invalid',
        message = 'условие выборки users: age — обязательное поле',
        fields = { age = 'обязательное поле' },
    })
    t.assert_equals(seen.delete_bad.kind, 'invalid')
    t.assert_equals(seen.delete, { ok = true, value = true })
end

-- Функции узла с данными проверяют значения выборки заново, теми же
-- правилами, что и модель: негодное — отказ `invalid` таблицей, а не
-- исключение `box` и не весь спейс. Граница за объявлением `box` берёт,
-- и её пропускают и модель, и функции: `age < 200` — весь индекс
-- по убыванию.
g.test_query_values_follow_one_rule_at_the_model_and_on_the_wire = function()
    local seen = g.server:exec(function()
        ---@type any
        local User = rawget(_G, 'User')
        local fn = rawget(_G, 'binding').functions

        for id = 1, 3 do
            assert(User.create({ id = id, name = 'Клиент ' .. id, age = 20 * id }))
        end

        local _, equal = User.where('age', '=', 200):all()

        return {
            below = User.where('age', '<', 200):all(),
            between = User.where('age', 'between', { 0, 200 }):count(),
            equal = { equal.kind, equal.fields },
            text = fn.tnt_model_select('users', { index = 'age', iterator = 'GE', key = { 'много' }, limit = 10 }),
            to = fn.tnt_model_count(
                'users',
                { index = 'age', iterator = 'GE', key = { 1 }, to = 'пять', limit = 10 }
            ),
            negative = fn.tnt_model_select('users', { index = 'primary', iterator = 'ALL', key = {}, limit = -1 }),
            fraction = fn.tnt_model_select('users', { index = 'primary', iterator = 'ALL', key = {}, limit = 2.5 }),
            beyond_max = fn.tnt_model_select('users', { index = 'age', iterator = 'EQ', key = { 999 }, limit = 10 }),
            wire_below = fn.tnt_model_select('users', { index = 'age', iterator = 'LT', key = { 200 }, limit = 10 }),
            wire_between = fn.tnt_model_count(
                'users',
                { index = 'age', iterator = 'GE', key = { 0 }, to = 200, limit = 10 }
            ),
            wire_downward = {
                pcall(
                    fn.tnt_model_count,
                    'users',
                    { index = 'age', iterator = 'LT', key = { 200 }, to = 100, limit = 10 }
                ),
            },
            wire_after = fn.tnt_model_select('users', {
                index = 'age',
                iterator = 'GE',
                key = {},
                limit = 10,
                after = { age = 30, id = 9 },
            }),
        }
    end)

    local unsigned = 'должно быть целым числом не меньше 0, а не %s'
    local page = 'должно быть целым числом от 1 до 4294967295, а не %s'

    --- Отказ функции: род и поля, без текста — его сверяют проверки модели.
    ---@param reply table
    ---@return table
    local function refused(reply)
        return { reply.ok, reply.kind, reply.fields }
    end

    t.assert_equals(helper.ids(seen.below), { 3, 2, 1 }, 'граница за max обходит весь индекс')
    t.assert_equals(seen.between, 3)
    t.assert_equals(
        seen.equal,
        { 'invalid', { age = 'должно быть целым числом от 0 до 150, а не 200' } }
    )
    t.assert_equals(refused(seen.text), { false, 'invalid', { age = unsigned:format("'много'") } })
    t.assert_equals(refused(seen.to), { false, 'invalid', { age = unsigned:format("'пять'") } })
    t.assert_equals(refused(seen.negative), { false, 'invalid', { limit = page:format('-1') } })
    t.assert_equals(refused(seen.fraction), { false, 'invalid', { limit = page:format('2.5') } })
    t.assert_equals(
        refused(seen.beyond_max),
        { false, 'invalid', { age = 'должно быть целым числом от 0 до 150, а не 999' } }
    )
    t.assert_equals(helper.ids(seen.wire_below.value), { 3, 2, 1 })
    t.assert_equals(seen.wire_between, { ok = true, value = 3 })
    t.assert_equals(
        seen.wire_downward,
        { false, 'модель users: граница to — только у итератора GE, а не LT' },
        'граница не у GE — выборка не по форме, исключение'
    )
    t.assert_equals(
        helper.ids(seen.wire_after.value),
        { 2, 3 },
        'курсор за ключами записей — место в индексе'
    )
end

g.test_vshard_storage_keeps_bucket_id_and_refuses_foreign_buckets = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        local helper_config = {
            get = function(_, path)
                return ({ ['sharding.roles'] = { 'storage' }, ['sharding.bucket_count'] = 100 })[path]
            end,
        }

        model._set_source({
            config = function()
                return helper_config
            end,
        })

        local Order = model.define({
            space = 'orders',
            fields = {
                { 'id', 'unsigned', primary = true },
                model.bucket_of('id'),
                { 'total', 'number' },
            },
        })

        box.atomic(Order.migration(), box)

        local binding = model.bind({ Order }, model.settings(nil))

        binding.attach()

        local _, unmarked = Order.create({ id = 7, total = 1 })

        -- Разметка бакетов руками: бакет ключа 7 при ста бакетах — 98.
        local buckets = box.schema.space.create('_bucket', {
            format = { { name = 'id', type = 'unsigned' }, { name = 'status', type = 'string' } },
        })

        buckets:create_index('pk', { parts = { 'id' } })
        buckets:replace({ 98, 'active' })
        buckets:replace({ 11, 'sending' })

        -- Закреплённый бакет тоже здесь: его только не переносят.
        local hash = require('vshard.hash')
        local pinned_id = 9

        buckets:replace({ hash.mpcrc32(pinned_id) % 100 + 1, 'pinned' })

        local created = Order.create({ id = 7, total = 1 })
        local pinned = Order.create({ id = pinned_id, total = 2 })
        local _, foreign = Order.create({ id = 8, total = 1 })
        local _, sending = Order.create({ id = 3, total = 1 })
        local _, foreign_delete = Order.delete(8)
        local names = {}

        for _, field in ipairs(box.space.orders:format()) do
            table.insert(names, field.name)
        end

        model._set_source(nil)

        return {
            status = binding.status(),
            unmarked = tostring(unmarked),
            created = created:to_table(),
            pinned = pinned:to_table(),
            tuple = assert(box.space.orders:get(7)):totable(),
            bucket_index = box.space.orders.index.bucket_id.unique,
            format = names,
            foreign = { foreign.kind, tostring(foreign) },
            sending = sending.kind,
            foreign_delete = foreign_delete.kind,
            deleted = Order.delete(7),
            bucket_of_3 = hash.mpcrc32(3) % 100 + 1,
            bucket_of_8 = hash.mpcrc32(8) % 100 + 1,
            bucket_of_pinned = hash.mpcrc32(pinned_id) % 100 + 1,
        }
    end)

    t.assert_equals(seen.status, { source = 'local', sharded = true, serves = true, spaces = { 'orders' } })
    t.assert_equals(seen.unmarked, 'бакеты на узле не размечены')
    t.assert_equals(seen.created, { id = 7, total = 1 })
    t.assert_equals(seen.pinned, { id = 9, total = 2 })
    t.assert_not_equals(
        seen.bucket_of_pinned,
        seen.bucket_of_8,
        'у закреплённого бакета свой номер'
    )
    t.assert_not_equals(seen.bucket_of_pinned, 98)
    t.assert_equals(seen.tuple, { 7, 98, 1 })
    t.assert_equals(seen.bucket_index, false)
    t.assert_equals(seen.format, { 'id', 'bucket_id', 'total' })
    t.assert_equals(
        seen.foreign,
        { 'misrouted', 'бакет 62 не на этом узле: запись идёт через роутер' }
    )
    t.assert_equals(seen.sending, 'misrouted')
    t.assert_equals(
        seen.bucket_of_3,
        11,
        'бакет 3 — в переносе, запись в него не принимается'
    )
    t.assert_equals(seen.foreign_delete, 'misrouted')
    t.assert_equals(seen.deleted, true)
end

-- Индекс по необязательному полю: пустое значение идёт первым, как NULL
-- в индексе TREE, — последним по убыванию. Страница, кончившаяся записью
-- без метки, продолжается от её места: по убыванию — после неё только
-- записи без метки с меньшим ключом, в составном индексе по возрастанию —
-- записи без метки с большим ключом, затем с меткой. Курсор из JSON
-- с `null` вместо метки — то же место.
g.test_index_over_an_optional_field_keeps_empty_values_first = function()
    local seen = g.server:exec(function()
        local json = require('json')
        ---@type any
        local model = rawget(_G, 'model')
        local Tag = model.define({
            space = 'tags',
            fields = {
                { 'id', 'unsigned', primary = true },
                { 'kind', 'string' },
                { 'label', 'string', optional = true },
            },
            indexes = {
                label = { parts = { 'label' }, unique = false },
                sorted = { parts = { 'kind', 'label' }, unique = false },
            },
        })

        box.atomic(Tag.migration(), box)

        local tags = model.bind({ Tag }, model.settings(nil))

        tags.attach()

        assert(Tag.create({ id = 1, kind = 'x' }))
        assert(Tag.create({ id = 2, kind = 'x', label = 'b' }))
        assert(Tag.create({ id = 3, kind = 'x', label = 'a' }))
        assert(Tag.create({ id = 4, kind = 'x' }))
        assert(Tag.create({ id = 5, kind = 'y' }))

        -- Ключи страницы по порядку выдачи.
        local keys_of = function(query)
            local keys = {}

            for position, row in ipairs(assert(query:all())) do
                keys[position] = row.id
            end

            return keys
        end

        local grouped = Tag.where('kind', '=', 'x'):limit(2):all()
        local result = {
            nullable = box.space.tags.index.label.parts[1].is_nullable,
            descending = keys_of(Tag.where('label', '<', 'c')),
            ascending = keys_of(Tag.where('label', '>=', 'a')),
            counted = Tag.where('label', '<=', 'b'):count(),
            ranged = Tag.where('label', 'between', { 'a', 'b' }):count(),
            ranged_page = keys_of(Tag.where('label', 'between', { 'a', 'b' })),
            ranged_grouped = {
                Tag.where('kind', 'between', { 'x', 'x' }):count(),
                Tag.where('kind', 'between', { 'x', 'y' }):count(),
                Tag.where('kind', 'between', { 'a', 'w' }):count(),
            },
            empty = Tag.find(1):to_table(),
            after_empty = keys_of(Tag.where('label', '<', 'c'):after(Tag.find(4))),
            after_null = keys_of(Tag.where('label', '<=', 'c'):limit(1):after(json.decode('{"label": null, "id": 5}'))),
            grouped = keys_of(Tag.where('kind', '=', 'x'):limit(2)),
            grouped_next = keys_of(Tag.where('kind', '=', 'x'):limit(2):after(grouped[2])),
            grouped_after_first = keys_of(Tag.where('kind', '=', 'x'):after(grouped[1])),
            -- Записи без метки стоят до начала выборки по возрастанию:
            -- курсор с пустой меткой оставляет её целиком, и с ключом
            -- из двух частей, пришедшим по проводу, тоже.
            empty_before = keys_of(Tag.where('label', '>=', 'a'):after({ id = 4 })),
            wire_before = tags.functions.tnt_model_select('tags', {
                index = 'sorted',
                iterator = 'GE',
                key = { 'x', 'a' },
                limit = 10,
                after = { kind = 'x', id = 4 },
            }),
        }

        box.space.tags:drop()
        rawget(_G, 'binding').attach()

        return result
    end)

    t.assert_equals(seen.nullable, true, 'часть индекса берёт пустоту из формата')
    t.assert_equals(
        seen.descending,
        { 2, 3, 5, 4, 1 },
        'по убыванию пустое значение последним, равные — по убыванию ключа'
    )
    t.assert_equals(seen.ascending, { 3, 2 })
    t.assert_equals(seen.counted, 5)
    t.assert_equals(
        seen.ranged,
        2,
        'записи без метки под нижнюю границу не попадают'
    )
    t.assert_equals(seen.ranged_page, { 3, 2 })
    t.assert_equals(
        seen.ranged_grouped,
        { 4, 5, 0 },
        'составной индекс считается по первому звену, пустые метки — внутри'
    )
    t.assert_equals(seen.empty, { id = 1, kind = 'x' })
    t.assert_equals(
        seen.after_empty,
        { 1 },
        'после записи 4 без метки — только запись 1 без метки'
    )
    t.assert_equals(seen.after_null, { 4 }, 'null из JSON — то же место')
    t.assert_equals(
        seen.grouped,
        { 1, 4 },
        'в составном индексе по возрастанию пустые метки первыми'
    )
    t.assert_equals(seen.grouped_next, { 3, 2 })
    t.assert_equals(seen.grouped_after_first, { 4, 3, 2 })
    t.assert_equals(
        seen.empty_before,
        { 3, 2 },
        'курсор без метки раньше начала — вся выборка'
    )
    t.assert_equals(seen.wire_before.ok, true)
    t.assert_equals(helper.ids(seen.wire_before.value), { 3, 2, 5 })
end

-- Счёт по длинному диапазону — два счёта по индексу: при срезе файбера
-- в 20 мс он доходит до конца и вне транзакции, и внутри неё, не уступая
-- ни разу. Обход тех же записей в транзакции тот же срез срывает: он
-- здесь — сверка, что срез действует и проверка не пустая.
g.test_long_range_count_holds_under_the_slice_inside_a_transaction_too = function()
    local seen = g.server:exec(function(records, slice)
        local fiber = require('fiber')

        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')

        -- Записи кладутся мимо модели, партиями в транзакции: через
        -- `create` наполнение шло бы секунды вместо долей. Возраст
        -- перебирает весь допустимый разброс.
        box.begin()

        for id = 1, records do
            box.space.users:insert({ id, 'Мария', id % 151 })

            if id % 10000 == 0 then
                box.commit()
                fiber.yield()
                box.begin()
            end
        end

        box.commit()

        --- Работа в своём файбере с коротким срезом: срез живёт до первой
        --- уступки и только у своего файбера, а файбер проверки за ним
        --- остаётся с обычным. Исход — то, что отдал `join`: брошенное
        --- в файбере он возвращает вторым значением, а не бросает.
        ---@param work function
        ---@return table
        local function under_slice(work)
            local worker = fiber.new(function()
                ---@diagnostic disable-next-line: undefined-field
                fiber.self():set_max_slice(slice)

                return work()
            end)

            worker:set_joinable(true)

            local ok, value = worker:join()

            return { ok = ok, value = ok and value or tostring(value) }
        end

        --- Счёт по всему разбросу возрастов и по его части.
        ---@return integer[]
        local function counted()
            return {
                assert(User.where('age', 'between', { 0, 150 }):count()),
                assert(User.where('age', 'between', { 10, 60 }):count()),
            }
        end

        -- Уступки считаются через внешнюю зависимость: на живом узле иначе
        -- не увидеть, уступил ли счёт или просто оказался коротким.
        local yields = 0

        model._set_source({
            fiber = function()
                return {
                    yield = function()
                        yields = yields + 1

                        fiber.yield()
                    end,
                }
            end,
        })

        local outside = under_slice(counted)
        local inside = under_slice(function()
            return model.atomic(counted)
        end)

        model._set_source(nil)

        return {
            outside = outside,
            inside = inside,
            yields = yields,
            -- Обход — по записи, итератором: каждый его шаг — своё
            -- обращение к `box`, и срез сверяется на каждом. Один `select`
            -- на все записи сверяет срез не на каждой записи: в замере
            -- на 3.8 он проходил триста тысяч целиком в двух прогонах
            -- из трёх, а обход итератором срывался во всех ста.
            walked = under_slice(function()
                return box.atomic(function()
                    local steps = 0

                    for _ in box.space.users.index.age:pairs({ 0 }, { iterator = 'GE' }) do
                        steps = steps + 1
                    end

                    return steps
                end)
            end),
        }
    end, { RECORDS, SLICE })

    -- От 10 до 60 лет — 51 возраст, и у каждого 1987 записей: остаток
    -- от деления на 151 у чисел от 1 до 300 000 встречается 1987 раз,
    -- пока он не больше 114, и 1986 раз — после.
    t.assert_equals(seen.outside, { ok = true, value = { RECORDS, 51 * 1987 } })
    t.assert_equals(
        seen.inside,
        seen.outside,
        'в транзакции — те же числа и без отказа'
    )
    t.assert_equals(seen.yields, 0, 'счёт по индексу не уступает')
    t.assert_equals(seen.walked.ok, false, 'обход тех же записей срез срывает')
    t.assert_str_contains(seen.walked.value, 'fiber slice is exceeded')
end

-- Обе границы включительно и с равными ключами на них: полторы тысячи
-- ровесников не помещаются ни в какой кусок, и счёт их не теряет. Счёт
-- совпадает со страницей той же выборки, а верхняя граница ниже нижней —
-- пустой диапазон и у счёта, и у страницы.
g.test_range_count_takes_equal_keys_on_both_bounds = function()
    local seen = g.server:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        box.begin()

        for id = 1, 1500 do
            box.space.users:insert({ id, 'Мария', 30 })
        end

        for id = 1501, 1510 do
            box.space.users:insert({ id, 'Иван', 29 })
            box.space.users:insert({ id + 10, 'Пётр', 31 })
        end

        box.commit()

        local bounds = { { 30, 30 }, { 29, 30 }, { 30, 31 }, { 29, 31 }, { 32, 40 }, { 31, 29 } }
        local counts = {}
        local pages = {}

        for position, pair in ipairs(bounds) do
            counts[position] = User.where('age', 'between', pair):count()
            pages[position] = #User.where('age', 'between', pair):limit(2000):all()
        end

        return { counts = counts, pages = pages }
    end)

    t.assert_equals(seen.counts, { 1500, 1510, 1510, 1520, 0, 0 })
    t.assert_equals(seen.pages, seen.counts)
end

-- Спейс, снесённый соседом на первой уступке обхода. Счёт по диапазону
-- не уступает вовсе, и снести спейс посреди него некому: он отдаёт число.
-- Выборка с условием короче куска тоже не уступает. Длинная уступает
-- после первого куска, и настоящий box отвечает на второй «Space '512'
-- does not exist» из глубины, а модель — отказом узла парой. Спейс для
-- этого свой: снос `users` унёс бы и соседние проверки.
g.test_space_dropped_at_the_first_yield_is_a_refusal = function()
    local seen = g.server:exec(function()
        local fiber = require('fiber')

        ---@type any
        local model = rawget(_G, 'model')
        local Doomed = model.define({
            space = 'doomed',
            fields = { { 'id', 'unsigned', primary = true }, { 'age', 'unsigned' } },
            indexes = { age = { parts = { 'age' }, unique = false } },
            scopes = { adults = { { 'age', '>=', 18 } } },
        })

        box.atomic(Doomed.migration(), box)
        model.bind({ Doomed }, model.settings(nil)).attach()

        --- Кладёт записи ровесников с такими-то ключами.
        ---@param from integer
        ---@param to integer
        local function filled(from, to)
            box.begin()

            for id = from, to do
                box.space.doomed:insert({ id, 30 })
            end

            box.commit()
        end

        local yields = 0

        model._set_source({
            fiber = function()
                return {
                    yield = function()
                        yields = yields + 1

                        if yields == 1 then
                            box.space.doomed:drop()
                        end

                        fiber.yield()
                    end,
                }
            end,
        })

        filled(1, 10)

        local short = {
            ranged = Doomed.where('age', 'between', { 30, 30 }):count(),
            filtered = Doomed.scan():scope('adults'):count(),
            yields = yields,
        }

        -- Полторы тысячи записей — два куска: обход уступит после первого.
        filled(11, 1500)

        local ranged = Doomed.where('age', 'between', { 1, 5000 }):count()
        local ranged_yields = yields
        local counted, err = Doomed.scan():scope('adults'):count()

        model._set_source(nil)
        rawget(_G, 'binding').attach()

        return {
            short = short,
            ranged = { ranged, ranged_yields },
            counted = counted,
            kind = err.kind,
            text = tostring(err),
            yields = yields,
        }
    end)

    t.assert_equals(seen.short, { ranged = 10, filtered = 10, yields = 0 })
    t.assert_equals(seen.ranged, { 1500, 0 }, 'счёт по диапазону не уступает')
    t.assert_equals(seen.counted, nil, 'неполный счёт не отдаётся')
    t.assert_equals(seen.kind, 'unavailable')
    t.assert_equals(seen.yields, 1)
    t.assert_str_contains(seen.text, 'выборка doomed с условием оборвана')
    t.assert_str_contains(seen.text, 'does not exist')
end
