--- Отметки времени записи: создана, изменена, мягко удалена.
---
--- Отметку ставит узел с данными — шлюз `local`, — а не тот, кто зовёт
--- модель. Замена берёт отметку создания и признак удаления у прежней
--- записи тем же обращением к спейсу, без уступки между чтением
--- и записью. Вызывающий же читал бы прежнюю запись по сети, с реплики,
--- которая отстаёт, и перетёр бы отметку создания записи, которой ещё
--- не увидел. Из входа отметки не берутся никогда: их нельзя ни подделать
--- запросом, ни потерять заменой.
---
--- Отметка — секунды от начала эпохи по стенным часам `tnt-clock`:
--- она переживает перезапуск и уезжает на другие узлы, а монотонные
--- часы чужого процесса со своими несравнимы.

local Module = {}

--- Отметка создания: ставится один раз, замена берёт её у прежней записи.
Module.CREATED = 'created'

--- Отметка изменения: ставится при каждой записи.
Module.UPDATED = 'updated'

--- Признак мягкого удаления: пусто — запись жива, отметка — когда удалили.
Module.DELETED = 'deleted'

--- Роды отметок, которые знает модель.
---@type table<string, boolean>
Module.KINDS = { [Module.CREATED] = true, [Module.UPDATED] = true, [Module.DELETED] = true }

--- Способ удаления мимо мягкого: запись уходит из спейса.
Module.FORCE = 'force'

--- Восстановление мягко удалённой записи.
Module.RESTORE = 'restore'

--- Отметки записи перед вставкой либо заменой.
---
--- Прежней записи нет — отметки создания и изменения ставятся часом
--- записи, признака удаления нет. Есть — отметка создания и признак
--- удаления переходят от неё: запись меняют, а не создают, и удаляют
--- её только удалением. Пустая отметка создания у записи, лёгшей до
--- появления отметок, так и остаётся пустой: час её создания неизвестен,
--- и выдумывать его заменой было бы неправдой.
---@param shape TntModelShape
---@param values table Значения записи — меняются на месте
---@param previous table|nil Прежняя запись по ключу; пусто — её нет
---@param now number Час записи
function Module.written(shape, values, previous, now)
    for kind, name in pairs(shape.stamps) do
        if kind == Module.UPDATED then
            values[name] = now
        elseif previous == nil then
            values[name] = kind == Module.CREATED and now or nil
        else
            values[name] = previous[name]
        end
    end
end

--- Значения записи после мягкого удаления либо восстановления.
---
--- Пусто — менять нечего: удалённую не удаляют второй раз, живую
--- не восстанавливают. Отметка изменения ставится и здесь: удаление
--- и восстановление — тоже изменение записи.
---
--- Модели без мягкого удаления восстанавливать нечего: признака нет,
--- и запись всегда «живая» — ответ пустой, запись не трогается.
---@param shape TntModelShape
---@param values table Значения записи — меняются на месте
---@param mode string|nil `restore` — восстановить; иначе — удалить мягко
---@param now number Час записи
---@return table|nil values
function Module.marked(shape, values, mode, now)
    local deleted = shape.stamps[Module.DELETED]
    local restoring = mode == Module.RESTORE

    if (values[deleted] == nil) == restoring then
        return nil
    end

    if restoring then
        values[deleted] = nil
    else
        values[deleted] = now
    end

    local updated = shape.stamps[Module.UPDATED]

    if updated ~= nil then
        values[updated] = now
    end

    return values
end

return Module
