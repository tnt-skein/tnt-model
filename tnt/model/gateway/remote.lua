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
--- запоминается и спрашивается первым; до первой записи первым идёт
--- первый узел по имени. Чтение идёт тем же порядком и может отставать
--- от ведущего.
---
--- Узел, который промолчал, — соединение не поднялось, срок вышел, связь
--- оборвалась, — ведущим больше не считается и уходит в конец порядка,
--- пока снова не ответит. Иначе зависший узел так и стоял бы первым:
--- ведущего сменяет только принятая запись, а запись, ушедшая молчащему,
--- кончается отказом (ниже), — и каждое обращение ждало бы срок, пока
--- узел не проснётся. Из опроса молчащий узел не выпадает: его спрашивают,
--- когда остальные промолчали или ответили `readonly`, и ответ
--- возвращает его на место. Срок тут не нужен: узел в конце порядка
--- ничего не стоит, пока отвечают прочие.
---
--- Срок `timeout` — на узел: соединение и вызов укладываются в него
--- вместе. Худший срок обращения — срок, умноженный на число узлов:
--- столько ждёт вызов, когда молчат все.
---
--- Запись исполняется не больше одного раза. К следующему узлу она идёт,
--- только когда на этом точно не легла: соединение не поднялось за срок
--- и запрос не ушёл, узел ответил `readonly` либо отверг вызов, не исполнив
--- функцию. Вызов, который ушёл и не вернулся ответом, — срок вышел,
--- связь оборвалась, функция бросила исключение, — узел мог исполнить.
--- Зависший ведущий при выборах исполняет такой запрос из сокета, когда
--- проснётся, и повтор у нового ведущего положил бы запись второй раз —
--- поэтому здесь запись кончается отказом `unavailable`. Чтение данных
--- не меняет и идёт к следующему узлу после любой ошибки.
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
---
--- Транзакции на узле без данных нет: запись ушла бы по сети и легла
--- на узле с данными мимо транзакции вызывающего. Поэтому запись внутри
--- транзакции `box` — исключение, как и `atomic`.
---
--- Закрытие (`close` при перечитывании конфигурации) вызовов в пути
--- не обрывает. К этому мигу модели уже смотрят на новую привязку, а вызов,
--- который ждёт ответа узла, начался раньше: оборви его соединение —
--- и запись, которую ведущий принял, кончилась бы отказом `unavailable`
--- «исход неизвестен», а чтение пошло бы к следующему узлу. Поэтому
--- закрытый шлюз новых обращений не принимает, а соединения закрывает все
--- разом, когда вернётся последний вызов в пути. До тех пор вызов идёт
--- прежними правилами, и соединение, которого ему не хватает, открывает:
--- свежая привязка ведущего ещё не знает и спрашивает первым первый узел
--- по имени, и запись, которой тот ответил `readonly`, идёт к узлу,
--- с которым соединения не было. Откажи ей закрытый шлюз — перечитывание,
--- пришедшее вскоре после прежнего, стоило бы отказов записям, которые
--- ведущий принял бы. Такое соединение закрывается вместе с прочими
--- и не висит до сборки мусора. Отдельный срок закрытию не нужен: вызов
--- кончается не позже срока на каждый узел, а оборванный по сроку
--- закрытия вызов на втором узле был бы той же записью с неизвестным
--- исходом.

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

--- Род ошибки, которой net.box кончает вызов по сроку. Код у неё 0,
--- и узнаётся она только по роду; сверено на 3.8, в том числе при сроке 0
--- и отрицательном.
local TIMED_OUT = 'TimedOut'

--- Как узел обошёлся с вызовом, не дав ответа: срок вышел.
local TIMED = 'timed'

--- Промолчал иначе: связь не поднялась либо оборвалась.
local SILENT = 'silent'

--- Ответил ошибкой: отказ сервера либо исключение функции.
local ANSWERED = 'answered'

--- Почему закрытый шлюз отказывает новому обращению: модели смотрят
--- на новую привязку, а эта отпущена.
local CLOSED = 'привязка закрыта'

--- Начало текста об узле в отказе — по тому, как он обошёлся с вызовом:
--- «core-a: нет ответа за 2 с», «core-a не отвечает: Peer closed»,
--- «core-a ответил ошибкой: …».
---@type table<string, string>
local HEADS = { [TIMED] = '%s: ', [SILENT] = '%s не отвечает: ', [ANSWERED] = '%s ' }

--- Отверг ли узел вызов, не исполнив функцию.
---
--- Такие отказы сервер шлёт до вызова функции либо на первой её записи
--- в спейс: функции нет — узел ещё не опубликовал `tnt_model_*`
--- (`ER_NO_SUCH_PROC`), на неё нет права (`ER_ACCESS_DENIED`), узел
--- только для чтения (`ER_READONLY`). Функции `tnt_model_*` пишут одним
--- действием, и после этих отказов запись на узле не легла. Прочие
--- ошибки исхода не говорят. Перечислены отказы сервера, а не ошибки
--- связи: срок вызова у net.box — ошибка `TimedOut` без кода, а обрыв
--- связи после отправки — тот же `ER_NO_CONNECTION`, что и отказ
--- соединения до неё, и по коду их не различить.
---
--- Код берётся полем без проверки рода ошибки: net.box бросает объект
--- ошибки `box`, а у строки такого поля нет — она считается ошибкой
--- с неизвестным исходом, как и требует осторожность.
---@param err any Ошибка вызова net.box
---@return boolean
local function unperformed(err)
    local errors = world.current().box().error
    local code = err.code

    return code == errors.NO_SUCH_PROC or code == errors.ACCESS_DENIED or code == errors.READONLY
end

--- Как узел обошёлся с вызовом, если ответа нет.
---
--- Молчание — ошибки, которые ставит сам net.box, без ответа узла: срок
--- (`TimedOut`) и связь (`ER_NO_CONNECTION` — не поднялась либо оборвалась,
--- «Peer closed»; сверено на 3.8). Ошибка не из `box` — строка, как
--- `conn.error` соединения, — тоже молчание: что узел ответил, из неё
--- не видно. Прочее — ответ узла: отказ сервера (`ER_NO_SUCH_PROC`,
--- `ER_ACCESS_DENIED`) либо исключение функции (`LuajitError`).
---@param cause any Ошибка вызова либо связи; пусто — срок вышел без ошибки
---@return string how TIMED, SILENT либо ANSWERED
local function silence_of(cause)
    if cause == nil or cause.type == TIMED_OUT then
        return TIMED
    end

    local code = cause.code

    if code == nil or code == world.current().box().error.NO_CONNECTION then
        return SILENT
    end

    return ANSWERED
end

---@class TntModelRemotePeer
---@field name string Имя инстанса
---@field uri string Адрес
---@field login string
---@field password string|nil

---@class TntModelRemoteOptions
---@field replicaset string Имя репликасета — для текста отказа
---@field peers TntModelRemotePeer[] Узлы репликасета по порядку
---@field timeout number Срок обращения к одному узлу — соединение и вызов вместе, секунды

--- Что вышло из обращения к узлу: ответ либо причина, по которой его нет.
---@class TntModelRemoteAnswer
---@field reply table|nil Ответ узла; пусто — ответа нет
---@field reason string|nil Узел и причина — для текста отказа
---@field silent boolean|nil Узел промолчал; иначе — ответил ошибкой
---@field unknown boolean|nil Запись ушла, а исход неизвестен: дальше её не нести

--- Заводит шлюз.
---@param options TntModelRemoteOptions
---@return TntModelGateway
function Module.new(options)
    local gateway = { kind = Module.KIND }

    ---@type table<string, table> Открытые соединения по имени узла
    local opened = {}

    --- Имя узла, принявшего последнюю запись. Промолчавший узел ведущим
    --- не бывает: молчание сбрасывает его отсюда.
    ---@type string|nil
    local leader = nil

    --- Промолчавшие узлы — в том порядке, в каком замолчали: первым из них
    --- спрашивается тот, у кого было больше времени проснуться.
    ---@type string[]
    local muted = {}

    --- Шлюз закрыт: новых обращений нет, соединения закрываются, как только
    --- в пути не останется вызовов.
    ---@type boolean
    local closed = false

    --- Сколько вызовов в пути — начатых и ещё не вернувшихся.
    local in_flight = 0

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

    --- Узел ответил, пусть и ошибкой: он жив и спрашивается в свой черёд.
    ---@param name string
    local function heard(name)
        for position, silent in ipairs(muted) do
            if silent == name then
                table.remove(muted, position)

                return
            end
        end
    end

    --- Узел промолчал: ведущим он больше не считается, опрос идёт к нему
    --- последним.
    ---@param name string
    local function silenced(name)
        heard(name)
        table.insert(muted, name)

        if leader == name then
            leader = nil
        end
    end

    --- Отказ узла, не давшего ответа.
    ---
    --- Промолчавший узел уходит в конец опроса, ответивший ошибкой остаётся
    --- на месте. Текст говорит, что было (`HEADS`), а у записи
    --- с неизвестным исходом — «исход записи на core-a неизвестен: …»
    --- с той же причиной.
    ---@param peer TntModelRemotePeer
    ---@param cause any Ошибка вызова либо связи; пусто — срок вышел без ошибки
    ---@param sent boolean Ушла ли узлу запись
    ---@return TntModelRemoteAnswer
    local function missed(peer, cause, sent)
        local how = silence_of(cause)
        local head = HEADS[how]
        local detail = tostring(cause)

        if how == TIMED then
            detail = ('нет ответа за %s с'):format(options.timeout)
        elseif how == ANSWERED then
            detail = 'ответил ошибкой: ' .. detail
        end

        if how == ANSWERED then
            heard(peer.name)
        else
            silenced(peer.name)
        end

        local unknown = sent and not unperformed(cause)

        if unknown then
            head = 'исход записи на %s неизвестен: '
        end

        return { reason = head:format(peer.name) .. detail, silent = how ~= ANSWERED, unknown = unknown }
    end

    --- Ответ узла на вызов либо причина, по которой ответа нет.
    ---
    --- Не поднявшееся соединение значит, что запрос не уходил. Поднявшееся —
    --- что ушёл: между ожиданием и вызовом файбер не уступает, и net.box
    --- ставит запрос в очередь отправки соединения, которое ожидание
    --- застало поднятым. Оборвись оно раньше, чем запрос дошёл, — исход
    --- тоже сочтётся неизвестным: лишний отказ дешевле записи, легшей дважды.
    ---
    --- Срок — на узел, а не на каждый шаг: соединение, поднявшееся к концу
    --- срока, оставляет вызову остаток. Отмечается срок монотонными
    --- часами в миг обращения, а остаток считается от отметки цикла:
    --- ожидание net.box отсчитывает его от неё и кончится ровно в срок
    --- (`tnt-clock`, правило выбора часов). Остатка нет — запрос не уходит:
    --- вызов со сроком 0 и меньше net.box всё равно отправляет, и узел его
    --- исполняет (сверено на 3.8), — запись получила бы неизвестный исход
    --- без нужды.
    ---@param peer TntModelRemotePeer
    ---@param writing boolean
    ---@param name string
    ---@param args any[]
    ---@return TntModelRemoteAnswer
    local function asked(peer, writing, name, args)
        local clock = world.current().clock()
        local deadline = clock.monotonic() + options.timeout
        local conn = connection(peer)

        if not conn:wait_connected(options.timeout) then
            return missed(peer, conn.error, false)
        end

        local left = deadline - clock.scheduler_now()

        if left <= 0 then
            return missed(peer, nil, false)
        end

        local ok, reply = pcall(conn.call, conn, name, args, { timeout = left })

        if not ok then
            return missed(peer, reply, writing)
        end

        heard(peer.name)

        return { reply = reply }
    end

    --- Узлы по порядку опроса: принявший запись — первым, промолчавшие —
    --- последними, прочие — по имени.
    ---@return TntModelRemotePeer[]
    local function ordered()
        local peers = {}
        local by_name = {}
        local quiet = {}

        for _, name in ipairs(muted) do
            quiet[name] = true
        end

        for _, peer in ipairs(options.peers) do
            by_name[peer.name] = peer

            if peer.name == leader then
                table.insert(peers, 1, peer)
            elseif not quiet[peer.name] then
                table.insert(peers, peer)
            end
        end

        for _, name in ipairs(muted) do
            table.insert(peers, by_name[name])
        end

        return peers
    end

    --- Вызов на первом узле, который ответил; запись — на первом, кто
    --- не только для чтения.
    ---
    --- Отказ называет каждый узел: когда ведущего не нашлось, важно
    --- видеть, кто молчал, кто ответил ошибкой, а кто — «только чтение», —
    --- иначе узел, упавший вместе со сменой ведущего, спрятался бы за словом
    --- readonly. Итог — по худшему: промолчал хоть один — «не ответил»,
    --- ответил ошибкой — «отказал»; род обоих — `unavailable`, ведущим мог
    --- быть любой из них. Запись с неизвестным исходом обход кончает: узлы
    --- после неё не спрашиваются, и отказ называет только пройденные.
    ---@param writing boolean
    ---@param name string
    ---@param args any[]
    ---@return any value
    ---@return TntModelFailure|nil err
    local function called(writing, name, args)
        local reasons = {}
        local silent = false
        local refused = false

        for _, peer in ipairs(ordered()) do
            local answer = asked(peer, writing, name, args)
            local reply = answer.reply

            if reply == nil then
                if answer.silent then
                    silent = true
                else
                    refused = true
                end

                table.insert(reasons, answer.reason)

                if answer.unknown then
                    break
                end
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

        local kind = (silent or refused) and failure.UNAVAILABLE or failure.READONLY
        local what = silent and 'не ответил'
            or refused and 'отказал'
            or 'не принимает запись'

        return nil,
            failure.new(
                kind,
                ('репликасет %s %s: %s'):format(options.replicaset, what, table.concat(reasons, '; '))
            )
    end

    --- Закрывает соединения закрытого шлюза, когда в пути не осталось
    --- вызовов, и забывает их.
    local function drained()
        if closed and in_flight == 0 then
            for name, conn in pairs(opened) do
                conn:close()
                opened[name] = nil
            end
        end
    end

    --- Вызов со счётом вызовов в пути.
    ---
    --- Закрытый шлюз отказывает сразу: модели уже смотрят на новую
    --- привязку, а сюда приходит лишь тот, кто держит прежний шлюз.
    --- Исключение внутри вызова — ответ узла не той формы — счёт тоже
    --- уменьшает и уходит вызывающему как есть: иначе закрытый шлюз
    --- ждал бы вызова, который уже не вернётся, и соединения висели бы
    --- до конца процесса.
    ---@param writing boolean
    ---@param name string
    ---@param args any[]
    ---@return any value
    ---@return TntModelFailure|nil err
    local function tracked(writing, name, args)
        if closed then
            return nil,
                failure.new(failure.UNAVAILABLE, ('репликасет %s: %s'):format(options.replicaset, CLOSED))
        end

        in_flight = in_flight + 1

        local ok, value, err = pcall(called, writing, name, args)

        in_flight = in_flight - 1
        drained()

        if not ok then
            fail(value)
        end

        return value, err
    end

    function gateway.find(shape, key)
        return tracked(false, 'tnt_model_find', { shape.space, key })
    end

    --- Запись вне транзакции `box`; внутри неё — исключение.
    ---
    --- Вызов по сети уступает управление, а запись ложится на узле
    --- с данными своей транзакцией, мимо здешней: откат вызывающего её
    --- не отменил бы, и транзакция молча вышла бы частичной. Реплика
    --- с пересылкой сюда в транзакции не приходит — там отказ `readonly`
    --- шлюза `forward`.
    ---@param shape TntModelShape
    ---@param name string
    ---@param args any[]
    ---@return any value
    ---@return TntModelFailure|nil err
    local function written(shape, name, args)
        if world.current().box().is_in_txn() then
            fail(
                (
                    'модель %s: запись на узле без данных в транзакции невозможна — она ушла бы по сети '
                    .. 'и легла мимо транзакции; box.atomic живёт в функции узла с данными'
                ):format(shape.space)
            )
        end

        return tracked(true, name, args)
    end

    function gateway.put(shape, values, mode)
        return written(shape, 'tnt_model_put', { shape.space, values, mode })
    end

    function gateway.delete(shape, key, mode)
        return written(shape, 'tnt_model_delete', { shape.space, key, mode })
    end

    function gateway.select(shape, query)
        return tracked(false, 'tnt_model_select', { shape.space, query })
    end

    function gateway.count(shape, query)
        return tracked(false, 'tnt_model_count', { shape.space, query })
    end

    function gateway.atomic()
        local message =
            'транзакция на узле без данных невозможна: box.atomic живёт в функции узла с данными'

        fail(message)
    end

    --- Закрывает шлюз: перечитывание конфигурации заводит новый.
    ---
    --- Соединения закрываются сразу, если вызовов в пути нет, а иначе —
    --- когда вернётся последний из них.
    function gateway.close()
        closed = true
        drained()
    end

    return gateway
end

return Module
