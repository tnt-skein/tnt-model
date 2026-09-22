--- Отметки времени, хуки, мягкое удаление и области на настоящем `box`
--- одиночного узла.
---
--- Узел поднят без кластерной конфигурации — шлюз `local`, как у
--- приложения на одном узле. Час узла подменён через внешнюю зависимость
--- `clock`: отметки сверяются точным значением, а «создание взято
--- у прежней записи» отличается от «поставлено заново» без пауз между
--- записями. Одна проверка идёт с настоящими часами `tnt-clock`.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.features_live')

--- Сколько записей в долгом обходе с условием.
---
--- Разбор записи и сверка с условием стоят около 2,5 мкс (замер на 3.8:
--- двадцать тысяч записей — 50 мс, кусок в тысячу — до 6 мс). Обход
--- без уступок съел бы срез в 20 мс, а с уступкой между кусками
--- проходит. Срез `box` сверяет только внутри своих обращений — в выборке
--- куска, — поэтому и под сбором покрытия, где разбор в десятки раз
--- дольше, вне транзакции обход проходит, а в транзакции срывается.
local RECORDS = 20000

--- Срез файбера на время обхода, секунды.
local SLICE = 0.02

g.before_all(function()
    g.server = helper.start_box()
    g.server:exec(function()
        ---@type any
        local model = package.loaded['tnt.model']
        local journal = {}

        local Post = model.define({
            space = 'posts',
            fields = {
                { 'id', 'unsigned', primary = true },
                { 'title', 'string', min = 1, max = 100, trim = true },
                { 'published', 'boolean', default = false },
                { 'locked', 'boolean', default = false },
                { 'rating', 'integer', optional = true },
                model.created_at(),
                model.updated_at(),
                model.deleted_at(),
            },
            indexes = { created = { parts = { 'created_at' }, unique = false } },
            hooks = {
                before_update = function(_, original)
                    if original.locked then
                        return nil, 'запись заперта — менять её нельзя'
                    end
                end,
                before_delete = function(post)
                    if post.locked then
                        return nil, 'запись заперта — удалять её нельзя'
                    end
                end,
                after_create = function(post)
                    table.insert(journal, 'создана ' .. post.id)

                    if post.title == 'откат' then
                        error('хук «после» упал', 0)
                    end
                end,
            },
            scopes = {
                published = { { 'published', '=', true } },
                rated_above = function(rating)
                    return { { 'rating', '>', rating } }
                end,
            },
        })

        box.atomic(Post.migration(), box)

        local binding = model.bind({ Post }, model.settings(nil))

        binding.attach()

        -- Ключи записей страницы: проверки сверяют страницу одной строкой.
        rawset(_G, 'ids', function(rows)
            local listed = {}

            for _, row in ipairs(rows) do
                table.insert(listed, row.id)
            end

            return listed
        end)
        rawset(_G, 'Post', Post)
        rawset(_G, 'model', model)
        rawset(_G, 'binding', binding)
        rawset(_G, 'journal', journal)
    end)
end)

g.after_all(function()
    helper.stop_node(g.server)
end)

g.before_each(function()
    g.server:exec(function()
        ---@type any
        local model = rawget(_G, 'model')

        box.space.posts:truncate()
        rawset(_G, 'now', 1000)

        -- Час узла — то, что проверка положила в `now`.
        model._set_source({
            clock = function()
                return {
                    realtime = function()
                        return rawget(_G, 'now')
                    end,
                }
            end,
        })
    end)
end)

g.after_each(function()
    g.server:exec(function()
        rawget(_G, 'model')._set_source(nil)
    end)
end)

g.test_record_gets_its_stamps_from_the_data_node = function()
    local seen = g.server:exec(function()
        ---@type any
        local Post = rawget(_G, 'Post')
        local names = {}

        for _, field in ipairs(box.space.posts:format()) do
            table.insert(names, field.name .. ':' .. field.type .. (field.is_nullable and '?' or ''))
        end

        -- Отметки из входа не берутся: их ставит узел.
        local created = Post.create({ id = 1, title = ' Первая ', created_at = 1, deleted_at = 2 })

        rawset(_G, 'now', 2000)

        local found = Post.find(1)

        found.title = 'Первая, правка'
        found.created_at = 5
        found:save()

        -- Запись, которую не читали, заменяет прежнюю — отметка создания
        -- и признак удаления берутся у прежней.
        rawset(_G, 'now', 3000)

        local blind = Post.validate({ id = 1, title = 'Вслепую' })

        blind:save()

        return {
            format = names,
            created = created:to_table(),
            saved = found:to_table(),
            blind = blind:to_table(),
            tuple = assert(box.space.posts:get(1)):totable(),
        }
    end)

    t.assert_equals(seen.format, {
        'id:unsigned',
        'title:string',
        'published:boolean',
        'locked:boolean',
        'rating:integer?',
        'created_at:number?',
        'updated_at:number?',
        'deleted_at:number?',
    })
    t.assert_equals(seen.created, {
        id = 1,
        title = 'Первая',
        published = false,
        locked = false,
        created_at = 1000,
        updated_at = 1000,
    })
    t.assert_equals(seen.saved.created_at, 1000)
    t.assert_equals(seen.saved.updated_at, 2000)
    t.assert_equals(seen.blind.created_at, 1000)
    t.assert_equals(seen.blind.updated_at, 3000)
    t.assert_equals(seen.tuple, { 1, 'Вслепую', false, false, nil, 1000, 3000, nil })
end

g.test_stamps_come_from_the_real_clock_by_default = function()
    local seen = g.server:exec(function()
        ---@type any
        local Post = rawget(_G, 'Post')
        local clock = require('clock')

        rawget(_G, 'model')._set_source(nil)

        local before = clock.realtime()
        local created = Post.create({ id = 1, title = 'Сейчас' })
        local after = clock.realtime()

        return { before = before, stamp = created.created_at, after = after }
    end)

    t.assert_ge(seen.stamp, seen.before)
    t.assert_le(seen.stamp, seen.after)
end

g.test_hook_forbids_changing_a_locked_record = function()
    local seen = g.server:exec(function()
        ---@type any
        local Post = rawget(_G, 'Post')

        Post.create({ id = 1, title = 'Заперта', locked = true })

        local post = Post.find(1)

        post.title = 'Отперта'
        post.locked = false

        local refused, err = post:save()
        local _, delete_err = Post.delete(1)
        local _, force_err = Post.force_delete(1)

        return {
            refused = refused,
            kind = err.kind,
            text = tostring(err),
            delete = { delete_err.kind, delete_err.message },
            force = force_err.message,
            stored = Post.find(1):to_table(),
            journal = rawget(_G, 'journal'),
        }
    end)

    t.assert_equals(seen.refused, nil)
    t.assert_equals(
        { seen.kind, seen.text },
        { 'refused', 'запись заперта — менять её нельзя' }
    )
    t.assert_equals(seen.delete, { 'refused', 'запись заперта — удалять её нельзя' })
    t.assert_equals(seen.force, 'запись заперта — удалять её нельзя')
    t.assert_equals(seen.stored.title, 'Заперта', 'в спейсе запись прежняя')
    t.assert_equals(seen.stored.locked, true)
    t.assert_equals(seen.stored.updated_at, 1000)
end

g.test_after_hook_failure_rolls_back_inside_a_transaction = function()
    local seen = g.server:exec(function()
        ---@type any
        local Post = rawget(_G, 'Post')
        ---@type any
        local model = rawget(_G, 'model')
        local ok, thrown = pcall(model.atomic, function()
            Post.create({ id = 1, title = 'Первая' })
            Post.create({ id = 2, title = 'откат' })
        end)

        return { ok = ok, thrown = thrown, count = box.space.posts:len() }
    end)

    t.assert_equals(seen.ok, false)
    t.assert_equals(seen.thrown, 'хук «после» упал')
    t.assert_equals(seen.count, 0, 'обе записи откатились вместе с транзакцией')
end

g.test_soft_deleted_record_is_hidden_and_seen_on_request = function()
    local seen = g.server:exec(function()
        ---@type any
        local Post = rawget(_G, 'Post')
        local ids = rawget(_G, 'ids')

        for id = 1, 4 do
            Post.create({ id = id, title = 'Запись ' .. id })
        end

        rawset(_G, 'now', 1500)

        local record = Post.find(2)
        local deleted = record:delete()
        local by_key = Post.delete(3)
        local again = Post.delete(3)
        local missing = Post.delete(404)
        local observed = {
            deleted = deleted,
            record = record:to_table(),
            by_key = by_key,
            again = again,
            missing = missing,
            find = Post.find(2),
            page = ids(Post.scan():all()),
            count = Post.scan():count(),
            by_index = ids(Post.where('created_at', '>=', 0):all()),
            with_deleted = ids(Post.scan():with_deleted():all()),
            with_count = Post.scan():with_deleted():count(),
            only_deleted = ids(Post.scan():only_deleted():all()),
            special = Post.where('id', '=', 2):with_deleted():first():to_table(),
            tuple = assert(box.space.posts:get(2)):totable(),
        }

        rawset(_G, 'now', 1700)

        observed.restored = Post.restore(2)
        observed.restored_again = Post.restore(2)
        observed.alive_restore = Post.restore(1)
        observed.after_restore = Post.find(2):to_table()

        local gone = Post.where('id', '=', 3):only_deleted():first()

        observed.revived = gone:restore()
        observed.revived_record = gone:to_table()
        observed.forced = Post.force_delete(4)
        observed.forced_missing = Post.force_delete(4)
        observed.forced_tuple = box.space.posts:get(4)
        observed.final = ids(Post.scan():with_deleted():all())

        return observed
    end)

    t.assert_equals(seen.deleted, true)
    t.assert_equals(seen.record.deleted_at, 1500, 'запись в руках получила отметку')
    t.assert_equals(seen.record.updated_at, 1500)
    t.assert_equals({ seen.by_key, seen.again, seen.missing }, { true, false, false })
    t.assert_equals(seen.find, nil, 'поиск по ключу удалённую не видит')
    t.assert_equals(seen.page, { 1, 4 })
    t.assert_equals(seen.count, 2)
    t.assert_equals(seen.by_index, { 1, 4 })
    t.assert_equals(seen.with_deleted, { 1, 2, 3, 4 })
    t.assert_equals(seen.with_count, 4)
    t.assert_equals(seen.only_deleted, { 2, 3 })
    t.assert_equals(seen.special.deleted_at, 1500)
    t.assert_equals(seen.tuple, { 2, 'Запись 2', false, false, nil, 1000, 1500, 1500 })
    t.assert_equals({ seen.restored, seen.restored_again, seen.alive_restore }, { true, false, false })
    t.assert_equals(seen.after_restore, {
        id = 2,
        title = 'Запись 2',
        published = false,
        locked = false,
        created_at = 1000,
        updated_at = 1700,
    })
    t.assert_equals(seen.revived, true)
    t.assert_equals(seen.revived_record.deleted_at, nil)
    t.assert_equals(seen.revived_record.updated_at, 1700)
    t.assert_equals({ seen.forced, seen.forced_missing, seen.forced_tuple }, { true, false, nil })
    t.assert_equals(seen.final, { 1, 2, 3 })
end

g.test_scopes_narrow_the_page_on_a_real_index = function()
    local seen = g.server:exec(function()
        ---@type any
        local Post = rawget(_G, 'Post')
        local ids = rawget(_G, 'ids')

        for id = 1, 10 do
            rawset(_G, 'now', 1000 + id)
            Post.create({ id = id, title = 'Запись ' .. id, published = id % 2 == 0, rating = id })
        end

        Post.delete(6)

        local first = Post.where('created_at', '>=', 1003):scope('published'):limit(2):all()
        local _, refused = Post.scan():scope('rated_above', 'много'):all()

        return {
            first = ids(first),
            next = ids(Post.where('created_at', '>=', 1003):scope('published'):limit(2):after(first[2]):all()),
            offset = ids(Post.where('created_at', '>=', 1003):scope('published'):limit(2):offset(1):all()),
            descending = ids(Post.where('created_at', '<=', 1009):scope('published'):limit(3):all()),
            both = ids(Post.scan():scope('published'):scope('rated_above', 5):all()),
            between = Post.where('created_at', 'between', { 1002, 1008 }):scope('published'):count(),
            with_deleted = ids(Post.scan():scope('published'):with_deleted():all()),
            refused = refused.fields,
        }
    end)

    t.assert_equals(seen.first, { 4, 8 }, 'шестая удалена, третья не опубликована')
    t.assert_equals(seen.next, { 10 })
    t.assert_equals(seen.offset, { 8, 10 })
    t.assert_equals(seen.descending, { 8, 4, 2 })
    t.assert_equals(seen.both, { 8, 10 })
    t.assert_equals(seen.between, 3)
    t.assert_equals(seen.with_deleted, { 2, 4, 6, 8, 10 })
    t.assert_equals(seen.refused, { rating = "должно быть целым числом, а не 'много'" })
end

g.test_wire_functions_carry_the_delete_mode_and_the_filter = function()
    local seen = g.server:exec(function()
        ---@type any
        local Post = rawget(_G, 'Post')
        local fn = rawget(_G, 'binding').functions

        Post.create({ id = 1, title = 'Первая', published = true })
        Post.create({ id = 2, title = 'Вторая' })

        local query = {
            index = 'primary',
            iterator = 'ALL',
            key = {},
            limit = 10,
            filter = { { field = 'published', op = '=', value = true } },
        }

        return {
            bogus = fn.tnt_model_delete('posts', 1, 'purge'),
            soft = fn.tnt_model_delete('posts', 2),
            restore = fn.tnt_model_delete('posts', 2, 'restore'),
            select = fn.tnt_model_select('posts', query),
            count = fn.tnt_model_count('posts', query),
            bad = {
                pcall(
                    fn.tnt_model_select,
                    'posts',
                    { index = 'primary', iterator = 'ALL', key = {}, limit = 1, filter = 'x' }
                ),
            },
            force = fn.tnt_model_delete('posts', 1, 'force'),
            put = fn.tnt_model_put('posts', { id = 3, title = 'Третья', created_at = 1 }, 'insert'),
            left = box.space.posts:len(),
        }
    end)

    t.assert_equals(seen.bogus, {
        ok = false,
        kind = 'invalid',
        message = 'способ удаления purge неизвестен',
    })
    t.assert_equals(seen.soft.ok, true)
    t.assert_equals(seen.soft.value.deleted_at, 1000)
    t.assert_equals(seen.restore.value.deleted_at, nil)
    t.assert_equals(seen.select.value[1].id, 1)
    t.assert_equals(#seen.select.value, 1)
    t.assert_equals(seen.count, { ok = true, value = 1 })
    t.assert_equals(seen.bad[1], false)
    t.assert_str_contains(tostring(seen.bad[2]), 'выборка не по форме')
    t.assert_equals(seen.force, { ok = true, value = true })
    t.assert_equals(
        seen.put.value.created_at,
        1000,
        'отметку ставит узел и для записи с провода'
    )
    t.assert_equals(seen.left, 2)
end

-- Обход с условием уступает между кусками, и срез файбера его
-- не рвёт; в транзакции уступок нет, и тот же обход срез срывает.
g.test_filtered_walk_survives_a_fiber_slice = function()
    local seen = g.server:exec(function(records, slice)
        ---@type any
        local Post = rawget(_G, 'Post')
        ---@type any
        local model = rawget(_G, 'model')
        local fiber = require('fiber')

        box.begin()

        for id = 1, records do
            box.space.posts:insert({ id, 'Запись', id % 2 == 0, false, box.NULL, 1000, 1000, box.NULL })
        end

        box.commit()

        --- Счёт под срезом в своём файбере: срез ставится на файбер.
        ---@param work function
        ---@return table
        local function under_slice(work)
            local outcome = {}
            local worker = fiber.new(function()
                fiber.set_slice(slice)

                local ok, value = pcall(work)

                outcome.ok = ok
                outcome.value = ok and value or tostring(value)
            end)

            worker:set_joinable(true)
            worker:join()

            return outcome
        end

        local counted = function()
            return Post.scan():scope('published'):count()
        end

        return {
            outside = under_slice(counted),
            inside = under_slice(function()
                return model.atomic(counted)
            end),
        }
    end, { RECORDS, SLICE })

    t.assert_equals(seen.outside, { ok = true, value = RECORDS / 2 })
    t.assert_equals(seen.inside.ok, false, 'внутри транзакции уступок нет')
    t.assert_str_contains(seen.inside.value, 'fiber slice is exceeded')
end
