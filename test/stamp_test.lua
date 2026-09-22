--- Отметки времени записи: что ставит вставка, замена, мягкое удаление
--- и восстановление.
---
--- Здесь сама раскладка отметок, без спейса: шлюз `local` зовёт её
--- с прежней записью и часом, и проверки на двойнике `box` и на живом
--- узле смотрят уже на то, что легло.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.model.stamp')

---@type any
local model

---@type any
local stamps

---@type any
local shapes

g.before_each(function()
    model = helper.load()
    stamps = helper.module('tnt.model.stamp')
    shapes = helper.module('tnt.model.shape')
end)

g.after_each(helper.unload)

--- Форма записи с названными отметками.
---@param ... table Поля отметок
---@return table
local function shape_of(...)
    local fields = { { 'id', 'unsigned', primary = true }, { 'title', 'string' } }

    for _, field in ipairs({ ... }) do
        table.insert(fields, field)
    end

    return shapes.of({ space = 'posts', fields = fields })
end

g.test_new_record_is_created_and_updated_now_and_not_deleted = function()
    local shape = shape_of(model.created_at(), model.updated_at(), model.deleted_at())
    local values = { id = 1, title = 'a', created_at = 1, updated_at = 2, deleted_at = 3 }

    stamps.written(shape, values, nil, 100)

    t.assert_equals(values, { id = 1, title = 'a', created_at = 100, updated_at = 100 })
end

g.test_replacement_keeps_creation_and_deletion_of_the_previous_record = function()
    local shape = shape_of(model.created_at(), model.updated_at(), model.deleted_at())
    local values = { id = 1, title = 'b', created_at = 1, updated_at = 2 }

    stamps.written(shape, values, { id = 1, title = 'a', created_at = 10, updated_at = 20, deleted_at = 30 }, 100)

    t.assert_equals(values, { id = 1, title = 'b', created_at = 10, updated_at = 100, deleted_at = 30 })

    -- Запись, лёгшая до появления отметок: час создания неизвестен
    -- и заменой не выдумывается; живая запись живой и остаётся.
    local legacy = { id = 2, title = 'c', created_at = 5, deleted_at = 6 }

    stamps.written(shape, legacy, { id = 2, title = 'c' }, 100)

    t.assert_equals(legacy, { id = 2, title = 'c', updated_at = 100 })
end

g.test_only_declared_stamps_are_written = function()
    local values = { id = 1, title = 'a' }

    stamps.written(shape_of(model.updated_at('touched')), values, nil, 7)

    t.assert_equals(values, { id = 1, title = 'a', touched = 7 })

    local plain = { id = 1, title = 'a', created_at = 3 }

    stamps.written(shape_of(), plain, nil, 7)

    t.assert_equals(plain, { id = 1, title = 'a', created_at = 3 })
end

g.test_soft_deletion_marks_a_live_record_and_touches_it = function()
    local shape = shape_of(model.updated_at(), model.deleted_at())
    local values = { id = 1, title = 'a', updated_at = 1 }

    t.assert_is(stamps.marked(shape, values, nil, 50), values)
    t.assert_equals(values, { id = 1, title = 'a', updated_at = 50, deleted_at = 50 })

    -- Удалённую второй раз не удаляют: отметка осталась прежней.
    t.assert_equals(stamps.marked(shape, values, nil, 60), nil)
    t.assert_equals(values.deleted_at, 50)
end

g.test_restoring_clears_the_mark_of_a_deleted_record_only = function()
    local shape = shape_of(model.updated_at(), model.deleted_at('gone'))
    local values = { id = 1, title = 'a', updated_at = 1, gone = 5 }

    t.assert_is(stamps.marked(shape, values, 'restore', 70), values)
    t.assert_equals(values, { id = 1, title = 'a', updated_at = 70 })

    -- Живую не восстанавливают.
    t.assert_equals(stamps.marked(shape, values, 'restore', 80), nil)
    t.assert_equals(values.updated_at, 70)
end

g.test_marking_without_an_update_stamp_leaves_other_fields = function()
    local values = { id = 1, title = 'a' }

    t.assert_equals(stamps.marked(shape_of(model.deleted_at()), values, nil, 9), values)
    t.assert_equals(values, { id = 1, title = 'a', deleted_at = 9 })
end

g.test_restoring_a_model_without_soft_deletion_changes_nothing = function()
    local values = { id = 1, title = 'a', deleted_at = 3 }

    t.assert_equals(stamps.marked(shape_of(model.updated_at()), values, 'restore', 9), nil)
    t.assert_equals(values, { id = 1, title = 'a', deleted_at = 3 })
    t.assert_equals(stamps.KINDS, { created = true, updated = true, deleted = true })
    t.assert_equals({ stamps.FORCE, stamps.RESTORE }, { 'force', 'restore' })
end
