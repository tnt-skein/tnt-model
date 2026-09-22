--- Шлюз реплики с пересылкой записи: чтение на месте, запись — ведущему.
---
--- Стоит на узле с данными без шардирования, которому раздел `models`
--- велел пересылать запись (`writes = 'forward'`). Чтение, счёт
--- и транзакция идут шлюзом `local`. Запись тоже идёт им первой: узел,
--- ставший ведущим после смены, пишет у себя без перечитывания
--- конфигурации, — и только отказ `readonly` отправляет её шлюзом
--- `remote` соседям по репликасету. Тот сам находит ведущего и в отказе
--- называет каждый узел: молчащий ведущий — `unavailable`, а не `readonly`.
---
--- Пересылать ли, решает отказ шлюза `local`, а не `box.info.ro` здесь:
--- признак «только для чтения» проверяется в одном месте. Узел, который
--- между отказом и пересылкой сам стал ведущим, получит от соседей
--- `readonly` — повтор запишет на месте.
---
--- Внутри транзакции запись не пересылается: вызов по сети уступает
--- управление, уступка обрывает транзакцию memtx, а пересланная запись
--- легла бы мимо транзакции — откат на реплике её бы не отменил. Там
--- остаётся отказ `readonly` с объяснением.
---
--- Функции узла с данными (`tnt_model_*`) этим шлюзом не отвечают — только
--- своим `local`: иначе две реплики с пересылкой гоняли бы запись друг
--- другу до срока. Это держит привязка.

local failure = require('tnt.model.failure')
local world = require('tnt.model.world')

local Module = {}

--- Заводит шлюз.
---@param here TntModelGateway Шлюз `local` к данным узла
---@param there TntModelGateway Шлюз `remote` к соседям по репликасету
---@return TntModelGateway
function Module.new(here, there)
    ---@type TntModelGateway
    ---@diagnostic disable-next-line: missing-fields
    local gateway = { kind = here.kind }

    --- Запись шлюзом на месте; отказ «только для чтения» — пересылкой.
    ---@param own function Действие шлюза `local`
    ---@param forwarded function То же действие шлюза `remote`
    ---@param ... any Аргументы действия
    ---@return any value
    ---@return TntModelFailure|nil err
    local function written(own, forwarded, ...)
        local value, err = own(...)

        if err == nil or err.kind ~= failure.READONLY then
            return value, err
        end

        if world.current().box().is_in_txn() then
            return nil,
                failure.new(
                    failure.READONLY,
                    ('%s; в транзакции запись ведущему не пересылается'):format(
                        err.message
                    )
                )
        end

        return forwarded(...)
    end

    gateway.find = here.find
    gateway.select = here.select
    gateway.count = here.count
    gateway.atomic = here.atomic

    function gateway.put(shape, values, mode)
        return written(here.put, there.put, shape, values, mode)
    end

    function gateway.delete(shape, key)
        return written(here.delete, there.delete, shape, key)
    end

    --- Закрывает соединения с соседями: перечитывание заводит шлюз заново.
    function gateway.close()
        there.close()
        here.close()
    end

    return gateway
end

return Module
