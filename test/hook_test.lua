--- Хуки записи на двойнике шлюза: порядок вызовов, отказ хука «до»,
--- прежняя запись у хуков изменения, удаление и восстановление.

local t = require('luatest')

local helper = dofile('test/helper.lua')

---@type any
local model

local g = helper.group('tnt.model.hook', function(loaded)
    model = loaded
end)

--- Отказы модели — модуль того же набора исходников.
---@return any
local function failure()
    return helper.module('tnt.model.failure')
end

--- Модель пользователей с хуками на двойнике шлюза.
---
--- Хуки пишут себя в тот же список, что и шлюз: порядок хуков и
--- обращений к данным виден одной таблицей. Поэтому хуки — функция
--- от списка: объявление модели видит их готовыми, как в приложении.
---@param hooks table|fun(calls: table[]): table Хуки по именам
---@param answers table|nil Ответы шлюза
---@return any User
---@return any calls
local function bound(hooks, answers)
    local gateway, calls = helper.fake_gateway(answers)

    if type(hooks) == 'function' then
        hooks = hooks(calls)
    end

    local User = helper.users(model, { hooks = hooks })

    User._bind(gateway)

    return User, calls
end

--- Хук, который пишет вызов в список и отвечает заготовленным.
---@param log table[]
---@param name string
---@param ... any Ответ хука
---@return function
local function spy(log, name, ...)
    local answer = { ... }
    local size = select('#', ...)

    return function(record, original)
        table.insert(log, {
            name = name,
            record = record:to_table(),
            original = original ~= nil and original:to_table() or false,
        })

        return unpack(answer, 1, size)
    end
end

g.test_create_runs_before_then_writes_then_after = function()
    local User, calls = bound(function(log)
        return {
            before_create = spy(log, 'before_create'),
            after_create = spy(log, 'after_create'),
        }
    end, { put = { id = 1, name = 'Мария', age = 46 } })

    local created, err = User.create({ id = 1, name = ' Мария ', age = 46 })

    t.assert_equals(err, nil)
    t.assert_equals(created:to_table(), { id = 1, name = 'Мария', age = 46 })
    t.assert_equals(calls, {
        { name = 'before_create', record = { id = 1, name = 'Мария', age = 46 }, original = false },
        { name = 'put', space = 'users', args = { { id = 1, name = 'Мария', age = 46 }, 'insert' } },
        { name = 'after_create', record = { id = 1, name = 'Мария', age = 46 }, original = false },
    })
end

g.test_before_hook_refusal_cancels_the_write = function()
    local User, calls = bound(function(log)
        return {
            before_create = spy(log, 'before_create', nil, 'имя занято'),
            after_create = spy(log, 'after_create'),
        }
    end, { put = { id = 1, name = 'a', age = 1 } })

    local refused, err = User.create({ id = 1, name = 'a', age = 1 })

    t.assert_equals(refused, nil)
    t.assert_equals({ err.kind, tostring(err) }, { 'refused', 'имя занято' })
    t.assert_equals(model.failure.is(err), true)
    t.assert_equals(#calls, 1, 'до шлюза запись не дошла, хук «после» не звался')
end

g.test_before_hook_refusal_forms = function()
    local own = failure().new('conflict', 'такой уже есть')
    local cases = {
        { { nil, own }, own.kind, 'такой уже есть' },
        { { false }, 'refused', 'хук before_create модели users отказал в записи' },
        { { false, 'нельзя' }, 'refused', 'нельзя' },
    }

    for index, case in ipairs(cases) do
        local User = bound({
            before_create = function()
                return unpack(case[1], 1, 2)
            end,
        }, { put = { id = 1, name = 'a', age = 1 } })
        local _, err = User.create({ id = 1, name = 'a', age = 1 })

        t.assert_equals({ err.kind, err.message }, { case[2], case[3] }, ('случай №%d'):format(index))
    end

    -- Отказ модели передаётся как есть, тем же объектом.
    local User = bound({
        before_create = function()
            return nil, own
        end,
    })
    local _, same = User.create({ id = 1, name = 'a', age = 1 })

    t.assert_is(same, own)

    -- Истина и пустота — не отказ.
    for _, allowed in ipairs({ true, 'да' }) do
        local Allowed = bound({
            before_create = function()
                return allowed
            end,
        }, { put = { id = 1, name = 'a', age = 1 } })

        t.assert_equals(Allowed.create({ id = 1, name = 'a', age = 1 }).id, 1)
    end
end

g.test_before_hook_may_amend_the_record_and_the_amendment_is_checked = function()
    local User, calls = bound({
        before_create = function(record)
            record.email = record.name .. '@x.ru'
        end,
    }, { put = { id = 1, name = 'a', age = 1, email = 'a@x.ru' } })

    User.create({ id = 1, name = 'a', age = 1 })

    t.assert_equals(calls[1].args[1], { id = 1, name = 'a', age = 1, email = 'a@x.ru' })

    local Bad, bad_calls = bound({
        before_create = function(record)
            record.age = 1000
        end,
    })
    local refused, err = Bad.create({ id = 1, name = 'a', age = 1 })

    t.assert_equals(refused, nil)
    t.assert_equals(err.fields, { age = 'должно быть целым числом от 0 до 150, а не 1000' })
    t.assert_equals(bad_calls, {}, 'поправленное хуком проверено до шлюза')
end

g.test_invalid_input_never_reaches_the_hook = function()
    local User, calls = bound(function(log)
        return {
            before_create = spy(log, 'before_create'),
        }
    end)

    local _, err = User.create({ id = 1, name = '', age = 1 })

    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(calls, {})
end

g.test_save_of_a_record_that_was_never_read_is_a_creation = function()
    local User, calls = bound(function(log)
        return {
            before_create = spy(log, 'before_create'),
            before_update = spy(log, 'before_update'),
        }
    end, { put = { id = 3, name = 'Анна', age = 19 } })

    local record = User.validate({ id = 3, name = 'Анна', age = 19 })

    t.assert_equals(User._original(record), nil)
    t.assert_is(record:save(), record)
    t.assert_equals(calls[1].name, 'before_create')
    t.assert_equals(calls[2].args[2], 'replace')
end

g.test_save_of_a_read_record_is_an_update_with_the_original = function()
    local User, calls = bound(function(log)
        return {
            before_update = spy(log, 'before_update'),
            after_update = spy(log, 'after_update'),
        }
    end, {
        find = { id = 3, name = 'Анна', age = 19 },
        put = { id = 3, name = 'Анна', age = 20 },
    })

    local record = User.find(3)

    record.age = 20

    t.assert_equals(User._original(record):to_table(), { id = 3, name = 'Анна', age = 19 })
    t.assert_equals(
        User._original(record):is_adult(),
        true,
        'прежняя запись — запись модели'
    )

    record:save()

    t.assert_equals(calls[2], {
        name = 'before_update',
        record = { id = 3, name = 'Анна', age = 20 },
        original = { id = 3, name = 'Анна', age = 19 },
    })
    t.assert_equals(calls[4], {
        name = 'after_update',
        record = { id = 3, name = 'Анна', age = 20 },
        original = { id = 3, name = 'Анна', age = 19 },
    })

    -- После сохранения прежней становится легшая запись.
    t.assert_equals(User._original(record):to_table(), { id = 3, name = 'Анна', age = 20 })
end

g.test_update_refusal_keeps_the_record_as_the_caller_left_it = function()
    local User, calls = bound({
        before_update = function(_, original)
            if original.age >= 18 then
                return nil, 'взрослым возраст не меняют'
            end
        end,
    }, { find = { id = 3, name = 'Анна', age = 19 } })

    local record = User.find(3)

    record.age = 30

    local refused, err = record:save()

    t.assert_equals(refused, nil)
    t.assert_equals({ err.kind, err.message }, { 'refused', 'взрослым возраст не меняют' })
    t.assert_equals(record.age, 30)
    t.assert_equals(#calls, 1, 'только чтение, записи не было')
end

g.test_records_of_a_model_without_hooks_keep_no_copy = function()
    local User = bound(
        {},
        { find = { id = 3, name = 'Анна', age = 19 }, select = { { id = 4, name = 'b', age = 5 } } }
    )

    t.assert_equals(User._original(User.find(3)), nil)
    t.assert_equals(User._original(User.scan():all()[1]), nil)
end

g.test_read_records_of_a_hooked_model_remember_how_they_were_read = function()
    local User = bound({ after_delete = function() end }, { select = { { id = 4, name = 'b', age = 5 } } })
    local page = User.scan():all()

    page[1].age = 6

    t.assert_equals(User._original(page[1]):to_table(), { id = 4, name = 'b', age = 5 })
end

g.test_delete_by_key_reads_the_record_for_its_hooks = function()
    local User, calls = bound(function(log)
        return {
            before_delete = spy(log, 'before_delete'),
            after_delete = spy(log, 'after_delete'),
        }
    end, { find = { id = 3, name = 'Анна', age = 19 }, delete = true })

    t.assert_equals(User.delete(3), true)
    t.assert_equals(calls, {
        { name = 'find', space = 'users', args = { { 3 } } },
        { name = 'before_delete', record = { id = 3, name = 'Анна', age = 19 }, original = false },
        { name = 'delete', space = 'users', args = { { 3 } } },
        { name = 'after_delete', record = { id = 3, name = 'Анна', age = 19 }, original = false },
    })
end

g.test_delete_by_key_of_a_missing_record_calls_no_hook = function()
    local User, calls = bound(function(log)
        return {
            before_delete = spy(log, 'before_delete'),
        }
    end, { delete = true })

    t.assert_equals({ User.delete(3) }, { false })
    t.assert_equals(calls, { { name = 'find', space = 'users', args = { { 3 } } } })

    local refusal = failure().new('unavailable', 'нет связи')
    local Silent = bound({ before_delete = function() end }, { find = { refusal = refusal } })
    local none, err = Silent.delete(3)

    t.assert_equals(none, nil)
    t.assert_is(err, refusal)

    local _, bad = User.delete('x')

    t.assert_equals(bad.kind, 'invalid')
end

g.test_delete_hook_refusal_keeps_the_record = function()
    local User, calls = bound({
        before_delete = function(record)
            if record:is_adult() then
                return nil, 'взрослых не удаляют'
            end
        end,
    }, { find = { id = 3, name = 'Анна', age = 19 }, delete = true })

    local none, err = User.delete(3)

    t.assert_equals(none, nil)
    t.assert_equals(err.message, 'взрослых не удаляют')
    t.assert_equals(#calls, 1)

    local record = User.validate({ id = 3, name = 'Анна', age = 19 })
    local _, again = record:delete()

    t.assert_equals(again.kind, 'refused')
    t.assert_equals(
        #calls,
        1,
        'запись в руках — читать нечего, удалять запрещено'
    )
end

g.test_only_an_after_hook_is_enough_to_read_the_record = function()
    local User, calls = bound(function(log)
        return {
            after_delete = spy(log, 'after_delete'),
        }
    end, { find = { id = 3, name = 'Анна', age = 19 }, delete = false })

    t.assert_equals(
        User.delete(3),
        false,
        'запись пропала между чтением и удалением'
    )
    t.assert_equals(calls[1].name, 'find')
    t.assert_equals(
        #calls,
        2,
        'хук «после» на несостоявшееся удаление не зовётся'
    )
end

g.test_delete_without_hooks_goes_straight_to_the_gateway = function()
    local refusal = failure().new('readonly', 'только чтение')
    local User, calls = bound({ after_create = function() end }, { delete = { refusal = refusal } })
    local none, err = User.delete(3)

    t.assert_equals(none, nil)
    t.assert_is(err, refusal)
    t.assert_equals(calls, { { name = 'delete', space = 'users', args = { { 3 } } } })

    local record = User.validate({ id = 3, name = 'Анна', age = 19 })
    local _, same = record:delete()

    t.assert_is(same, refusal)
end

g.test_force_delete_runs_the_delete_hooks = function()
    local User, calls = bound(function(log)
        return {
            before_delete = spy(log, 'before_delete'),
        }
    end, { find = { id = 3, name = 'Анна', age = 19 }, delete = true })

    t.assert_equals(User.force_delete(3), true)
    t.assert_equals(calls[3], { name = 'delete', space = 'users', args = { { 3 }, 'force' } })

    local Plain, plain_calls = bound({}, { delete = false })

    t.assert_equals(Plain.force_delete(4), false)
    t.assert_equals(plain_calls, { { name = 'delete', space = 'users', args = { { 4 }, 'force' } } })
end

g.test_after_hook_answer_changes_nothing = function()
    local User = bound({
        after_create = function()
            return nil, 'поздно'
        end,
    }, { put = { id = 1, name = 'a', age = 1 } })
    local created, err = User.create({ id = 1, name = 'a', age = 1 })

    t.assert_equals(err, nil)
    t.assert_equals(created.id, 1)
end

g.test_hook_helpers = function()
    local hook = helper.module('tnt.model.hook')
    local shape = helper.users(model, { hooks = { after_update = function() end } })._shape

    t.assert_equals(hook.event_of(nil), 'create')
    t.assert_equals(hook.event_of({}), 'update')
    t.assert_equals(hook.watched(shape, 'update'), true)
    t.assert_equals(hook.watched(shape, 'delete'), false)
    t.assert_equals(hook.refusal(shape, 'update', nil, nil), nil)
    t.assert_equals(hook.NAMES.before_restore, '?callable')
end
