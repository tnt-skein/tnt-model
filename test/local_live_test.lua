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
--- Столько же, сколько в сверке на 3.8: обход без уступки на них
--- срывается срезом файбера, а с уступкой проходит. Меньше трёхсот
--- тысяч — и проверка перестала бы отличать одно от другого.
local RECORDS = 300000

--- Размер куска, которым шлюз считает диапазон.
local CHUNK = 1000

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
            bad_after = {
                pcall(fn.tnt_model_select, 'users', {
                    index = 'age',
                    iterator = 'GE',
                    key = { 1 },
                    limit = 1,
                    after = { id = 1 },
                }),
            },
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
    t.assert_equals(seen.bad_after, { false, 'модель users: в after нет поля age' })
    t.assert_equals(seen.delete_bad.kind, 'invalid')
    t.assert_equals(seen.delete, { ok = true, value = true })
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

g.test_index_over_an_optional_field_keeps_empty_values_first = function()
    local seen = g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')
        local Tag = model.define({
            space = 'tags',
            fields = { { 'id', 'unsigned', primary = true }, { 'label', 'string', optional = true } },
            indexes = { label = { parts = { 'label' }, unique = false } },
        })

        box.atomic(Tag.migration(), box)
        model.bind({ Tag }, model.settings(nil)).attach()

        assert(Tag.create({ id = 1 }))
        assert(Tag.create({ id = 2, label = 'b' }))
        assert(Tag.create({ id = 3, label = 'a' }))

        -- Ключи страницы по порядку выдачи.
        local keys_of = function(query)
            local keys = {}

            for position, row in ipairs(query:all()) do
                keys[position] = row.id
            end

            return keys
        end

        local result = {
            nullable = box.space.tags.index.label.parts[1].is_nullable,
            descending = keys_of(Tag.where('label', '<', 'c')),
            ascending = keys_of(Tag.where('label', '>=', 'a')),
            counted = Tag.where('label', '<=', 'b'):count(),
            empty = Tag.find(1):to_table(),
        }

        box.space.tags:drop()
        rawget(_G, 'binding').attach()

        return result
    end)

    t.assert_equals(seen.nullable, true, 'часть индекса берёт пустоту из формата')
    t.assert_equals(
        seen.descending,
        { 2, 3, 1 },
        'по убыванию пустое значение последним'
    )
    t.assert_equals(seen.ascending, { 3, 2 })
    t.assert_equals(seen.counted, 3)
    t.assert_equals(seen.empty, { id = 1 })
end

-- Счёт по длинному диапазону вне транзакции доходит до конца при срезе
-- файбера в 20 мс: перед каждым куском уступка, и она же обновляет срез.
-- Внутри транзакции уступать нельзя — уступка оборвала бы транзакцию, —
-- и там тот же счёт срывается срезом. Это предел, названный в документе
-- пакета, а не случайность проверки: обе ветки идут по одним и тем же
-- записям в один и тот же миг.
g.test_long_range_count_survives_the_slice_outside_a_transaction_only = function()
    local seen = g.server:exec(function(records, slice)
        local clock = require('clock')
        local fiber = require('fiber')

        ---@type any
        local model = rawget(_G, 'model')
        ---@type any
        local User = rawget(_G, 'User')

        -- Записи кладутся мимо модели, партиями в транзакции: через
        -- `create` наполнение шло бы секунды вместо долей. Возраст
        -- перебирает весь допустимый разброс, и диапазон накрывает спейс
        -- целиком.
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
        --- остаётся с обычным.
        ---@param work function
        ---@return table
        local function under_slice(work)
            local outcome = {}

            local worker = fiber.new(function()
                ---@diagnostic disable-next-line: undefined-field
                fiber.self():set_max_slice(slice)

                local started = clock.monotonic()
                local ok, value = pcall(work)

                outcome.ok = ok
                outcome.value = ok and value or tostring(value)
                outcome.took = clock.monotonic() - started
            end)

            worker:set_joinable(true)
            worker:join()

            return outcome
        end

        --- Счёт по всему допустимому разбросу возрастов.
        ---@return integer|nil
        ---@return any
        local function counted()
            return User.where('age', 'between', { 0, 150 }):count()
        end

        -- Уступки считаются через внешнюю зависимость: на живом узле иначе не увидеть,
        -- уступил ли обход или просто оказался коротким. Уступает
        -- по-настоящему — срез обновляет только настоящая уступка.
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
        local counting_yields = yields
        local inside = under_slice(function()
            return model.atomic(counted)
        end)

        model._set_source(nil)

        return {
            outside = outside,
            yields = counting_yields,
            inside = inside,
            inside_yields = yields - counting_yields,
        }
    end, { RECORDS, SLICE })

    t.assert_equals(seen.outside.ok, true, tostring(seen.outside.value))
    t.assert_equals(seen.outside.value, RECORDS)
    t.assert_gt(
        seen.outside.took,
        SLICE * 3,
        'счёт короче трёх срезов ничего не доказывает'
    )
    t.assert_equals(
        seen.yields,
        RECORDS / CHUNK + 1,
        'триста полных кусков и пустой последний, перед каждым уступка'
    )
    t.assert_equals(seen.inside.ok, false, 'внутри транзакции уступок нет')
    t.assert_equals(seen.inside_yields, 0, 'уступка оборвала бы транзакцию')
    t.assert_str_contains(seen.inside.value, 'fiber slice is exceeded')
end

-- Продолжение куска идёт по кортежу, а не `GT` от его ключа: индекс
-- выборки неуникален, и полторы тысячи ровесников не помещаются в кусок.
-- `GT` от возраста последней записи куска потерял бы весь остаток —
-- ровно то, что здесь и считается.
g.test_range_count_keeps_records_with_equal_keys_across_chunks = function()
    local seen = g.server:exec(function()
        ---@type any
        local User = rawget(_G, 'User')

        box.begin()

        for id = 1, 1500 do
            box.space.users:insert({ id, 'Мария', 30 })
        end

        box.commit()

        return {
            counted = User.where('age', 'between', { 30, 30 }):count(),
            by_gt = #box.space.users.index.age:select({ 30 }, { iterator = 'GT' }),
        }
    end)

    t.assert_equals(seen.counted, 1500)
    t.assert_equals(
        seen.by_gt,
        0,
        'продолжение по GT от того же возраста не отдало бы ни одной записи'
    )
end

-- Спейс, снесённый соседом, пока обход стоял на уступке: настоящий box
-- отвечает «Space '512' does not exist» из глубины, а модель — отказом
-- узла парой. Спейс для этого свой: снос `users` унёс бы и соседние
-- проверки.
g.test_range_count_over_a_space_dropped_at_a_yield_is_a_refusal = function()
    local seen = g.server:exec(function()
        local fiber = require('fiber')

        ---@type any
        local model = rawget(_G, 'model')
        local Doomed = model.define({
            space = 'doomed',
            fields = { { 'id', 'unsigned', primary = true }, { 'age', 'unsigned' } },
            indexes = { age = { parts = { 'age' }, unique = false } },
        })

        box.atomic(Doomed.migration(), box)
        model.bind({ Doomed }, model.settings(nil)).attach()

        box.begin()

        -- Полторы тысячи записей — два куска: сносить спейс надо после
        -- первого, когда обход уже уступил и вернулся за продолжением.
        for id = 1, 1500 do
            box.space.doomed:insert({ id, 30 })
        end

        box.commit()

        local yields = 0

        model._set_source({
            fiber = function()
                return {
                    yield = function()
                        yields = yields + 1

                        if yields == 2 then
                            box.space.doomed:drop()
                        end

                        fiber.yield()
                    end,
                }
            end,
        })

        local counted, err = Doomed.where('age', 'between', { 30, 30 }):count()

        model._set_source(nil)
        rawget(_G, 'binding').attach()

        return { counted = counted, kind = err.kind, text = tostring(err), yields = yields }
    end)

    t.assert_equals(seen.counted, nil, 'неполный счёт не отдаётся')
    t.assert_equals(seen.kind, 'unavailable')
    t.assert_equals(seen.yields, 2)
    t.assert_str_contains(seen.text, 'счёт по диапазону doomed оборван')
    t.assert_str_contains(seen.text, 'does not exist')
end
