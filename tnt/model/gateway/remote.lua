--- Шлюз `remote`: данных на узле нет, обращение к репликасету по net.box.
---
--- Стоит на узле-прослойке без vshard: роутер HTTP, который ходит
--- в репликасет с данными. Им же реплика с `writes = 'forward'`
--- пересылает запись ведущему своего репликасета — тогда в списке узлов
--- нет её самой. Зовутся те же общие функции `tnt_model_*`, что и у
--- vshard, под учёткой `iproto.advertise.sharding` — ей в конфигурации
--- выдаётся право `lua_call` на эти функции.
---
--- Ведущего шлюз не выбирает заранее: запись пробует узлы по порядку,
--- и тот, кто отвечает `readonly`, пропускается, — так смена ведущего
--- не требует перечитывания конфигурации. Узел, принявший запись,
--- запоминается и спрашивается первым. Чтение идёт на любой отвечающий
--- узел и может отставать от ведущего.
---
--- Соединение, которое не поднялось или оборвалось, заменяется новым
--- при следующем обращении: net.box без `reconnect_after` из состояния
--- `error` не выходит. Сверено на 3.8: узел перезапустили, а прежнее
--- соединение так и отвечает «Peer closed», — ведущий, вернувшийся после
--- перезапуска, оставался бы для шлюза молчащим до перечитывания
--- конфигурации. `reconnect_after` не берётся нарочно: пока net.box
--- переподключается, `wait_connected` ждёт весь срок, и каждое обращение
--- к упавшему узлу стоило бы срока, а новое соединение к закрытому порту
--- отказывает сразу.

local failure = require('tnt.model.failure')
local world = require('tnt.model.world')

local Module = {}

--- Имя шлюза.
Module.KIND = 'remote'

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

--- Состояние соединения net.box, из которого без `reconnect_after`
--- не выходят: связь не поднялась либо оборвалась. Сокета у такого
--- соединения уже нет, и заменить его можно, не закрывая.
local BROKEN = 'error'

---@class TntModelRemotePeer
---@field name string Имя инстанса
---@field uri string Адрес
---@field login string
---@field password string|nil

---@class TntModelRemoteOptions
---@field replicaset string Имя репликасета — для текста отказа
---@field peers TntModelRemotePeer[] Узлы репликасета по порядку
---@field timeout number Срок соединения и одного вызова, секунды

--- Заводит шлюз.
---@param options TntModelRemoteOptions
---@return TntModelGateway
function Module.new(options)
    local gateway = { kind = Module.KIND }

    ---@type table<string, table> Открытые соединения по имени узла
    local opened = {}

    --- Имя узла, принявшего последнюю запись.
    ---@type string|nil
    local leader = nil

    --- Соединение с узлом: открывается при первом обращении и заново,
    --- когда прежнее оборвалось.
    ---@param peer TntModelRemotePeer
    ---@return table
    local function connection(peer)
        local conn = opened[peer.name]

        if conn == nil or conn.state == BROKEN then
            conn = world.current().net_box().connect(peer.uri, {
                user = peer.login,
                password = peer.password,
                wait_connected = false,
            })
            opened[peer.name] = conn
        end

        return conn
    end

    --- Ответ узла на вызов либо причина, по которой ответа нет.
    ---@param peer TntModelRemotePeer
    ---@param name string
    ---@param args any[]
    ---@return table|nil reply
    ---@return string|nil reason
    local function asked(peer, name, args)
        local conn = connection(peer)

        if not conn:wait_connected(options.timeout) then
            return nil, ('%s не отвечает: %s'):format(peer.name, tostring(conn.error))
        end

        local ok, reply = pcall(conn.call, conn, name, args, { timeout = options.timeout })

        if not ok then
            return nil, ('%s отказал: %s'):format(peer.name, tostring(reply))
        end

        return reply
    end

    --- Узлы по порядку опроса: принявший запись — первым.
    ---@return TntModelRemotePeer[]
    local function ordered()
        local peers = {}

        for _, peer in ipairs(options.peers) do
            if peer.name == leader then
                table.insert(peers, 1, peer)
            else
                table.insert(peers, peer)
            end
        end

        return peers
    end

    --- Вызов на первом узле, который ответил; запись — на первом, кто
    --- не только для чтения.
    ---
    --- Отказ называет каждый узел: когда ведущего не нашлось, важно
    --- видеть, кто молчал, а кто ответил «только чтение», — иначе узел,
    --- упавший вместе со сменой ведущего, спрятался бы за словом readonly.
    ---@param writing boolean
    ---@param name string
    ---@param args any[]
    ---@return any value
    ---@return TntModelFailure|nil err
    local function called(writing, name, args)
        local reasons = {}
        local silent = false

        for _, peer in ipairs(ordered()) do
            local reply, reason = asked(peer, name, args)

            if reply == nil then
                silent = true
                table.insert(reasons, reason)
            elseif reply.ok == false and reply.kind == failure.READONLY and writing then
                table.insert(reasons, ('%s: %s'):format(peer.name, tostring(reply.message)))
            elseif reply.ok == false then
                return nil, failure.from_wire(reply)
            else
                if writing then
                    leader = peer.name
                end

                return reply.value
            end
        end

        local kind = silent and failure.UNAVAILABLE or failure.READONLY
        local what = silent and 'не ответил' or 'не принимает запись'

        return nil,
            failure.new(
                kind,
                ('репликасет %s %s: %s'):format(options.replicaset, what, table.concat(reasons, '; '))
            )
    end

    function gateway.find(shape, key)
        return called(false, 'tnt_model_find', { shape.space, key })
    end

    function gateway.put(shape, values, mode)
        return called(true, 'tnt_model_put', { shape.space, values, mode })
    end

    function gateway.delete(shape, key)
        return called(true, 'tnt_model_delete', { shape.space, key })
    end

    function gateway.select(shape, query)
        return called(false, 'tnt_model_select', { shape.space, query })
    end

    function gateway.count(shape, query)
        return called(false, 'tnt_model_count', { shape.space, query })
    end

    function gateway.atomic()
        local message =
            'транзакция на узле без данных невозможна: box.atomic живёт в функции узла с данными'

        fail(message)
    end

    --- Закрывает соединения: перечитывание конфигурации заводит шлюз заново.
    function gateway.close()
        for name, conn in pairs(opened) do
            conn:close()
            opened[name] = nil
        end
    end

    return gateway
end

return Module
