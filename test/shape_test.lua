--- Проверки объявления модели: форма записи и её ошибки.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.shape')

---@type any
local model

---@type any
local shapes

g.before_each(function()
    model = helper.load()
    shapes = helper.module('tnt.model.shape')
end)

g.after_each(helper.unload)

--- Объявление пользователей с правками.
---@param overrides table|nil
---@return table
local function spec(overrides)
    return helper.users_spec(model, overrides)
end

g.test_shape_keeps_field_order_primary_bucket_and_indexes = function()
    local shape = shapes.of(spec())

    t.assert_equals(shape.space, 'users')
    t.assert_equals(shape.layout, { 'id', 'bucket_id', 'name', 'age', 'email' })
    t.assert_equals(shape.primary, { 'id' })
    t.assert_equals(shape.bucket_of, 'id')
    t.assert_equals(#shape.fields, 4)
    t.assert_equals(shape.fields[2].name, 'name')
    t.assert_equals(shape.fields[2].trim, true)
    t.assert_equals(shape.fields[2].max, 255)
    t.assert_equals(shape.fields[4].optional, true)
    t.assert_equals(shape.by_name.age.min, 0)
    t.assert_equals(shape.by_name.id.primary, true)
    t.assert_equals(shape.by_name.name.primary, false)
    t.assert_equals(shape.by_name.name.optional, false)
    t.assert_equals(shape.indexes, {
        { name = 'primary', parts = { 'id' }, unique = true },
        { name = 'age', parts = { 'age' }, unique = false },
    })
    t.assert_type(shape.methods.is_adult, 'function')
    t.assert_equals(shape.rules, {})
    t.assert_equals(shape.factory, nil)
end

g.test_fields_are_declared_as_list_or_as_named_entries = function()
    local shape = shapes.of({
        space = 'notes',
        fields = {
            { name = 'key', type = 'string', primary = true, min = 1 },
            { name = 'body', type = 'string', default = '' },
            { 'flag', 'boolean' },
            { 'owner', 'uuid', optional = true },
            { 'weight', 'number', min = 0.5 },
            { 'rank', 'integer', max = 10 },
        },
    })

    t.assert_equals(shape.layout, { 'key', 'body', 'flag', 'owner', 'weight', 'rank' })
    t.assert_equals(shape.bucket_of, nil)
    t.assert_equals(shape.by_name.body.default, '')
    t.assert_equals(shape.by_name.weight.min, 0.5)
    t.assert_equals(shape.by_name.rank.max, 10)
    t.assert_equals(shape.indexes, { { name = 'primary', parts = { 'key' }, unique = true } })
end

g.test_composite_primary_key_and_indexes_sorted_by_name = function()
    local shape = shapes.of({
        space = 'links',
        fields = {
            { 'left', 'unsigned', primary = true },
            { 'right', 'unsigned', primary = true },
            model.bucket_of('right'),
            { 'kind', 'string' },
        },
        indexes = {
            right_kind = { parts = { 'right', 'kind' }, unique = false },
            kind = { parts = { 'kind' }, unique = false },
        },
    })

    t.assert_equals(shape.primary, { 'left', 'right' })
    t.assert_equals(shape.layout, { 'left', 'right', 'bucket_id', 'kind' })
    t.assert_equals(shape.indexes[2].name, 'kind')
    t.assert_equals(shape.indexes[3].name, 'right_kind')
    t.assert_equals(shapes.index_of(shape, 'right_kind').parts, { 'right', 'kind' })
    t.assert_equals(shapes.index_of(shape, 'none'), nil)

    -- Точный индекс по одному полю берётся раньше составного.
    t.assert_equals(shapes.index_for(shape, 'kind').name, 'kind')
    t.assert_equals(shapes.index_for(shape, 'right').name, 'right_kind')
    t.assert_equals(shapes.index_for(shape, 'left').name, 'primary')
end

g.test_index_for_prefers_the_exact_index_in_any_order = function()
    --- Форма с точным и составным индексом по одному первому звену.
    ---@param composite string Имя составного индекса
    ---@return TntModelShape
    local function shape_with(composite)
        return shapes.of({
            space = 'links',
            fields = { { 'id', 'unsigned', primary = true }, { 'right', 'unsigned' }, { 'kind', 'string' } },
            indexes = {
                right = { parts = { 'right' }, unique = false },
                [composite] = { parts = { 'right', 'kind' }, unique = false },
            },
        })
    end

    --- Имена индексов формы по порядку.
    ---@param shape TntModelShape
    ---@return string[]
    local function names_of(shape)
        local names = {}

        for _, index in ipairs(shape.indexes) do
            table.insert(names, index.name)
        end

        return names
    end

    -- Индексы идут по имени: составной раньше точного и позже него.
    local before = shape_with('a_right_kind')
    local after = shape_with('right_kind')

    t.assert_equals(names_of(before), { 'primary', 'a_right_kind', 'right' })
    t.assert_equals(shapes.index_for(before, 'right').name, 'right')
    t.assert_equals(names_of(after), { 'primary', 'right', 'right_kind' })
    t.assert_equals(shapes.index_for(after, 'right').name, 'right')

    -- Среди составных берётся первый по порядку.
    local composite = shapes.of({
        space = 'links',
        fields = { { 'id', 'unsigned', primary = true }, { 'right', 'unsigned' }, { 'kind', 'string' } },
        indexes = {
            right_id = { parts = { 'right', 'id' }, unique = true },
            right_kind = { parts = { 'right', 'kind' }, unique = false },
        },
    })

    t.assert_equals(shapes.index_for(composite, 'right').name, 'right_id')
end

g.test_names_of_one_letter_are_names = function()
    local shape = shapes.of({
        space = 'u',
        fields = { { 'x', 'unsigned', primary = true }, { 'y', 'string' } },
        indexes = { i = { parts = { 'y' }, unique = false } },
    })

    t.assert_equals(shape.space, 'u')
    t.assert_equals(shape.layout, { 'x', 'y' })
    t.assert_equals(shape.indexes[2].name, 'i')
end

g.test_index_for_names_available_indexes_in_refusal = function()
    local shape = shapes.of(spec())

    t.assert_error_msg_equals(
        'модель users: по полю name индекса нет; есть индексы primary (id), age (age)',
        shapes.index_for,
        shape,
        'name'
    )
end

g.test_declaration_errors_name_the_model_and_the_place = function()
    local cases = {
        { 'модель объявляется таблицей с именем спейса в space', 'users' },
        {
            'модель объявляется таблицей с именем спейса в space',
            { space = 'bad name' },
        },
        {
            'модель users: ключа «table» нет, есть factory, fields, hooks, indexes, methods, rules, scopes, space',
            spec({ table = 'users' }),
        },
        { 'модель users: fields — непустой список полей', spec({ fields = {} }) },
        { 'модель users: поле №1 объявляется таблицей', spec({ fields = { 'id' } }) },
        { 'модель users: у поля №1 нет имени', spec({ fields = { { type = 'unsigned' } } }) },
        {
            'модель users: у поля id род text, а бывает unsigned, integer, number, string, boolean, uuid',
            spec({ fields = { { 'id', 'text' } } }),
        },
        {
            'модель users: поле id не знает настройки pattern',
            spec({ fields = { { 'id', 'unsigned', pattern = '%d' } } }),
        },
        {
            'модель users: поле id объявлено дважды',
            spec({ fields = { { 'id', 'unsigned', primary = true }, { 'id', 'string' } } }),
        },
        {
            'модель users: поле bucket_id объявлено дважды',
            spec({ fields = { { 'id', 'unsigned', primary = true }, { 'bucket_id', 'unsigned' } } }),
        },
        {
            'модель users: ключ шардирования объявлен дважды',
            spec({ fields = { { 'id', 'unsigned', primary = true }, model.bucket_of('id'), model.bucket_of('id') } }),
        },
        {
            'модель users: поле первичного ключа id обязательно',
            spec({ fields = { { 'id', 'unsigned', primary = true, optional = true } } }),
        },
        {
            'модель users: поле первичного ключа id обязательно',
            spec({ fields = { { 'id', 'unsigned', primary = true, default = 1 } } }),
        },
        { 'модель users: нет поля с primary = true', spec({ fields = { { 'id', 'unsigned' } } }) },
        {
            'модель users: ключ шардирования name должен быть полем первичного ключа',
            spec({ fields = { { 'id', 'unsigned', primary = true }, { 'name', 'string' }, model.bucket_of('name') } }),
        },
        {
            'модель users: ключ шардирования nope должен быть полем первичного ключа',
            spec({ fields = { { 'id', 'unsigned', primary = true }, model.bucket_of('nope') } }),
        },
        {
            'модель users: имя индекса primary занято',
            spec({ indexes = { primary = { parts = { 'id' } } } }),
        },
        {
            'модель users: имя индекса bucket_id занято',
            spec({ indexes = { bucket_id = { parts = { 'id' } } } }),
        },
        {
            'модель users: имя индекса by-age занято',
            spec({ indexes = { ['by-age'] = { parts = { 'age' } } } }),
        },
        {
            'модель users: у индекса age нужны parts — список полей',
            spec({ indexes = { age = { unique = false } } }),
        },
        {
            'модель users: у индекса age нужно unique = true либо false',
            spec({ indexes = { age = { parts = { 'age' } } } }),
        },
        {
            'модель users: индекс age по неизвестному полю years',
            spec({ indexes = { age = { parts = { 'years' }, unique = false } } }),
        },
        {
            'модель users: правило 1 должно быть функцией',
            spec({ rules = { 'adult' } }),
        },
        {
            'модель users: метод greet должно быть функцией',
            spec({ methods = { greet = 'hi' } }),
        },
        {
            'модель users: метод save занят пакетом',
            spec({ methods = { save = function() end } }),
        },
        {
            'модель users: метод delete занят пакетом',
            spec({ methods = { delete = function() end } }),
        },
        {
            'модель users: метод to_table занят пакетом',
            spec({ methods = { to_table = function() end } }),
        },
        { 'модель users: factory должно быть функцией', spec({ factory = {} }) },
    }

    for index, case in ipairs(cases) do
        t.assert_error_msg_equals(case[1], shapes.of, case[2], ('случай №%d'):format(index))
    end
end

g.test_bucket_of_requires_a_field_name = function()
    t.assert_equals(model.bucket_of('id'), { name = 'bucket_id', type = 'unsigned', bucket_of = 'id' })
    t.assert_error_msg_equals('model.bucket_of: имя поля — строка, а не number', model.bucket_of, 7)
end

--- Объявление с отметками времени после ключа и имени, без индексов.
---@param ... table Поля отметок
---@return table
local function stamped(...)
    local fields = { { 'id', 'unsigned', primary = true }, { 'name', 'string' } }

    for _, field in ipairs({ ... }) do
        table.insert(fields, field)
    end

    return spec({ fields = fields, indexes = {} })
end

g.test_stamp_fields_are_optional_numbers_placed_where_declared = function()
    t.assert_equals(model.created_at(), { name = 'created_at', type = 'number', optional = true, stamp = 'created' })
    t.assert_equals(model.updated_at(), { name = 'updated_at', type = 'number', optional = true, stamp = 'updated' })
    t.assert_equals(model.deleted_at(), { name = 'deleted_at', type = 'number', optional = true, stamp = 'deleted' })
    t.assert_equals(model.created_at('made').name, 'made')
    t.assert_equals(model.updated_at('touched').name, 'touched')
    t.assert_equals(model.deleted_at('gone').name, 'gone')

    local shape = shapes.of(stamped(model.created_at(), model.updated_at('touched'), model.deleted_at()))

    t.assert_equals(shape.layout, { 'id', 'name', 'created_at', 'touched', 'deleted_at' })
    t.assert_equals(shape.stamps, { created = 'created_at', updated = 'touched', deleted = 'deleted_at' })
    t.assert_equals(shape.stamped, true)
    t.assert_equals(shape.by_name.touched.stamp, 'updated')
    t.assert_equals(shape.by_name.created_at.optional, true)

    local plain = shapes.of(spec())

    t.assert_equals(plain.stamps, {})
    t.assert_equals(plain.stamped, false)
    t.assert_equals(plain.by_name.age.stamp, nil)
end

g.test_stamp_declaration_errors = function()
    local cases = {
        {
            'модель users: у поля made отметка born, а бывает created, updated, deleted',
            stamped({ 'made', 'number', optional = true, stamp = 'born' }),
        },
        {
            'модель users: отметка created объявлена дважды',
            stamped(model.created_at(), model.created_at('made')),
        },
        {
            'модель users: поле made заполняет модель — оно необязательное и без умолчания',
            stamped({ 'made', 'number', stamp = 'created' }),
        },
        {
            'модель users: поле made заполняет модель — оно необязательное и без умолчания',
            stamped({ 'made', 'number', optional = true, default = 0, stamp = 'created' }),
        },
        {
            'модель users: поле made не знает настройки stamp',
            stamped({ 'made', 'string', optional = true, stamp = 'created' }),
        },
    }

    for index, case in ipairs(cases) do
        t.assert_error_msg_equals(case[1], shapes.of, case[2], ('случай №%d'):format(index))
    end
end

g.test_hooks_are_named_functions = function()
    local before = function() end
    local shape = shapes.of(spec({ hooks = { before_update = before, after_restore = before } }))

    t.assert_equals(shape.hooks, { before_update = before, after_restore = before })
    t.assert_equals(shape.hooked, true)
    t.assert_equals(shapes.of(spec()).hooks, {})
    t.assert_equals(shapes.of(spec()).hooked, false)

    t.assert_error_msg_equals(
        'модель users: хуки: ключа «before_save» нет, есть after_create, after_delete, after_restore, after_update, '
            .. 'before_create, before_delete, before_restore, before_update',
        shapes.of,
        spec({ hooks = { before_save = before } })
    )
    t.assert_error_msg_equals(
        'модель users: хуки.after_create — функция или вызываемая таблица, а не строка',
        shapes.of,
        spec({ hooks = { after_create = 'log' } })
    )
end

g.test_scopes_are_condition_lists_or_functions_by_name = function()
    local since = function() end
    local shape = shapes.of(spec({ scopes = { adults = { { 'age', '>=', 18 } }, since = since } }))

    t.assert_equals(shape.scopes, { adults = { { 'age', '>=', 18 } }, since = since })
    t.assert_equals(shapes.of(spec()).scopes, {})

    for index, scopes in ipairs({
        { { { 'age', '>=', 18 } } },
        { adults = 'age >= 18' },
        { ['by-age'] = {} },
    }) do
        local name = next(scopes)

        t.assert_error_msg_equals(
            ('модель users: область %s — список условий либо функция, которая его отдаёт'):format(
                name
            ),
            shapes.of,
            spec({ scopes = scopes }),
            ('случай №%d'):format(index)
        )
    end
end

g.test_record_methods_restore_and_force_delete_are_taken = function()
    for _, name in ipairs({ 'restore', 'force_delete' }) do
        t.assert_error_msg_equals(
            ('модель users: метод %s занят пакетом'):format(name),
            shapes.of,
            spec({ methods = { [name] = function() end } })
        )
    end
end
