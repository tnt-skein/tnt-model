--- Мягкое удаление и области на двойнике шлюза: что модель просит
--- у шлюза и что отдаёт вызывающему.
---
--- Сами отметки ставит узел с данными — это проверено на двойнике `box`
--- (`local_test`) и на живом узле (`features_live_test`). Здесь —
--- путь модели: скрытая удалённая запись, способ удаления в шлюз,
--- условия выборки по областям и по признаку удаления.

local t = require('luatest')

local helper = dofile('test/helper.lua')

---@type any
local model

local g = helper.group('tnt.model.deleted', function(loaded)
    model = loaded
end)

--- Объявление записей блога: отметки, мягкое удаление, области.
---@param overrides table|nil
---@return table
local function posts_spec(overrides)
    local spec = {
        space = 'posts',
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'title', 'string', min = 1 },
            { 'published', 'boolean', default = false },
            { 'rating', 'integer', optional = true },
            model.created_at(),
            model.updated_at(),
            model.deleted_at(),
        },
        indexes = { created = { parts = { 'created_at' }, unique = false } },
        scopes = {
            published = { { 'published', '=', true } },
            rated_above = function(rating)
                return { { 'rating', '>', rating } }
            end,
        },
    }

    for key, value in pairs(overrides or {}) do
        spec[key] = value
    end

    return spec
end

--- Модель записей блога на двойнике шлюза.
---@param answers table|nil
---@param overrides table|nil
---@return any Post
---@return any calls
local function bound(answers, overrides)
    local Post = model.define(posts_spec(overrides))
    local gateway, calls = helper.fake_gateway(answers)

    Post._bind(gateway)

    return Post, calls
end

--- Живая запись: каждый раз новая таблица — модель оборачивает ответ
--- шлюза на месте, и общая таблица перетекала бы из проверки в проверку.
---@return table
local function alive()
    return { id = 1, title = 'Первая', published = true, created_at = 10, updated_at = 10 }
end

--- Та же запись, мягко удалённая.
---@return table
local function gone()
    return { id = 1, title = 'Первая', published = true, created_at = 10, updated_at = 20, deleted_at = 20 }
end

g.test_find_does_not_see_a_deleted_record = function()
    t.assert_equals(bound({ find = gone() }).find(1), nil)
    t.assert_equals(bound({ find = alive() }).find(1):to_table(), alive())

    local refusal = model.failure.new('unavailable', 'нет связи')
    local none, err = bound({ find = { refusal = refusal } }).find(1)

    t.assert_equals(none, nil)
    t.assert_is(err, refusal)
end

g.test_delete_asks_the_gateway_by_the_model_and_refills_the_record = function()
    local Post, calls = bound({ delete = gone(), find = alive() })

    t.assert_equals(Post.delete(1), true)
    t.assert_equals(calls[1], { name = 'delete', space = 'posts', args = { { 1 } } })

    local record = Post.find(1)

    t.assert_equals(record:delete(), true)
    t.assert_equals(record.deleted_at, 20, 'запись взяла то, что легло')
    t.assert_equals(record:to_table(), gone())

    local Missing = bound({ delete = false })

    t.assert_equals(Missing.delete(1), false)
end

g.test_restore_and_force_delete_name_their_way = function()
    local Post, calls = bound({ delete = alive(), find = alive() })

    t.assert_equals(Post.restore(1), true)
    t.assert_equals(Post.force_delete(1), true)
    t.assert_equals(calls[1].args, { { 1 }, 'restore' })
    t.assert_equals(calls[2].args, { { 1 }, 'force' })

    local record = Post.validate(gone())

    t.assert_equals(record:restore(), true)
    t.assert_equals(record:to_table(), alive())
    t.assert_equals(calls[3].args, { { 1 }, 'restore' })

    t.assert_equals(record:force_delete(), true)
    t.assert_equals(calls[4].args, { { 1 }, 'force' })

    local _, bad = Post.restore('x')

    t.assert_equals(bad.kind, 'invalid')
end

g.test_record_with_a_spoilt_key_is_refused_before_the_gateway = function()
    local Post, calls = bound({ delete = gone() })
    local record = Post.validate(alive())

    record.id = 'первая'

    for _, method in ipairs({ 'delete', 'force_delete', 'restore' }) do
        local none, err = record[method](record)

        t.assert_equals(none, nil, method)
        t.assert_equals(
            err.fields,
            { id = "должно быть целым числом не меньше 0, а не 'первая'" },
            method
        )
    end

    t.assert_equals(calls, {}, 'негодный ключ до шлюза не доходит')
end

g.test_restore_hooks_see_the_record = function()
    local seen = {}
    local Post = bound({ find = gone(), delete = alive() }, {
        hooks = {
            before_restore = function(record)
                table.insert(seen, { 'before', record.deleted_at })
            end,
            after_restore = function(record)
                table.insert(seen, { 'after', record.deleted_at })
            end,
        },
    })

    t.assert_equals(Post.restore(1), true)
    t.assert_equals(seen, { { 'before', 20 }, { 'after', nil } })
end

g.test_soft_deletion_methods_need_a_deletion_stamp = function()
    local fields = { { 'id', 'unsigned', primary = true }, { 'title', 'string' } }
    local Plain = bound({}, { fields = fields, indexes = {}, scopes = {} })
    local message =
        'модель posts: %s — только у модели с мягким удалением, model.deleted_at()'

    t.assert_error_msg_equals(message:format('restore'), Plain.restore, 1)
    t.assert_error_msg_equals(message:format('restore'), function()
        return Plain.validate({ id = 1, title = 'a' }):restore()
    end)
    t.assert_error_msg_equals(message:format('with_deleted'), function()
        return Plain.scan():with_deleted()
    end)
    t.assert_error_msg_equals(message:format('only_deleted'), function()
        return Plain.scan():only_deleted()
    end)
end

g.test_query_hides_deleted_records_unless_asked = function()
    local Post, calls = bound({ select = { alive() }, count = 1 })
    local query = Post.scan()

    query:all()
    query:all()
    Post.scan():with_deleted():all()
    Post.scan():only_deleted():count()

    t.assert_equals(calls[1].args[1].filter, { { field = 'deleted_at', op = '=' } })
    t.assert_equals(
        calls[2].args[1].filter,
        { { field = 'deleted_at', op = '=' } },
        'условие не копится'
    )
    t.assert_equals(calls[3].args[1].filter, nil)
    t.assert_equals(calls[4].args[1].filter, { { field = 'deleted_at', op = '~=' } })
end

g.test_scopes_add_their_conditions = function()
    local Post, calls = bound({ select = { alive() }, count = 1 })

    Post.where('created_at', '>=', 5):scope('published'):scope('rated_above', 3):limit(10):all()
    Post.scan():scope('published'):with_deleted():first()

    t.assert_equals(calls[1].args[1], {
        index = 'created',
        iterator = 'GE',
        key = { 5 },
        limit = 10,
        filter = {
            { field = 'published', op = '=', value = true },
            { field = 'rating', op = '>', value = 3 },
            { field = 'deleted_at', op = '=' },
        },
    })
    t.assert_equals(calls[2].args[1].filter, { { field = 'published', op = '=', value = true } })
    t.assert_equals(calls[2].args[1].limit, 1)
end

g.test_scope_argument_from_outside_is_a_refusal = function()
    local Post, calls = bound({ select = {}, count = 0 })

    for _, finish in ipairs({ 'all', 'first', 'count' }) do
        local query = Post.scan():scope('rated_above', 'высокий')
        local none, err = query[finish](query)

        t.assert_equals(none, nil, finish)
        t.assert_equals(
            err.fields,
            { rating = "должно быть целым числом, а не 'высокий'" },
            finish
        )
    end

    t.assert_equals(calls, {}, 'до шлюза выборка не дошла')
end

g.test_scope_programmer_errors = function()
    local Post = bound({})

    t.assert_error_msg_equals(
        'модель posts: области draft нет; объявлены: published, rated_above',
        function()
            return Post.scan():scope('draft')
        end
    )
    t.assert_error_msg_equals(
        'модель posts: область published объявлена списком и аргументов не ждёт',
        function()
            return Post.scan():scope('published', true)
        end
    )

    local Single = bound({}, { scopes = { published = { { 'published', '=', true } } } })

    t.assert_error_msg_equals(
        'модель posts: области draft нет; объявлены: published',
        function()
            return Single.scan():scope('draft')
        end
    )

    local Bare = bound({}, { scopes = {} })

    t.assert_error_msg_equals(
        'модель posts: области draft нет; объявлены: ни одной',
        function()
            return Bare.scan():scope('draft')
        end
    )
end

g.test_list_scope_is_checked_at_declaration = function()
    t.assert_error_msg_equals(
        "модель posts: область published: published — должно быть логическим значением, а не 'да'",
        model.define,
        posts_spec({ scopes = { published = { { 'published', '=', 'да' } } } })
    )
    t.assert_error_msg_equals(
        'модель posts: область top — список условий { поле, знак, значение }: '
            .. 'поле из объявления, знак =, ~=, <, <=, >, >=',
        model.define,
        posts_spec({ scopes = { top = { { 'stars', '>', 3 } } } })
    )
end
