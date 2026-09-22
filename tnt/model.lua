--- Модели данных: одно объявление формы записи — схема спейса, проверка
--- входа, чтение и запись, фабрика для проверок. Одна модель работает
--- в любой топологии: одиночный узел, репликасет, шардированный кластер,
--- узел-прослойка без своих данных.
---
---     local model = require('tnt.model')
---
---     local User = model.define({
---         space = 'users',
---         fields = {
---             { 'id', 'unsigned', primary = true },
---             model.bucket_of('id'),
---             { 'name', 'string', max = 255, trim = true },
---             { 'age', 'unsigned', max = 150 },
---         },
---         indexes = { age = { parts = { 'age' }, unique = false } },
---         methods = { is_adult = function(self) return self.age >= 18 end },
---     })
---
---     User.migration()                 -- шаг tnt-schema: формат, индексы
---     User.validate(input)             -- запись по форме либо nil, err
---     User.create(input)               -- проверка и вставка
---     User.find(7)                     -- запись либо nil
---     record:save(); record:delete()
---     User.where('age', '>=', 18):limit(50):all()
---     User.where('age', '>=', 18):limit(50):offset(100):all()   -- третья страница
---
--- Отметки времени — поля `model.created_at()`, `model.updated_at()`,
--- `model.deleted_at()`: их ставит модель, а третья делает удаление мягким.
--- Хуки (`hooks`) идут до и после записи, и отказ хука «до» её отменяет.
--- Области (`scopes`) — именованные условия, которые сужают выборку:
--- `Post.scan():scope('published'):all()`.
---
--- Где данные, модель не знает: приложение при применении конфигурации
--- привязывает ей шлюз по узлу (`model.bind`) — `local` (данные здесь),
--- `sharded` (через роутер vshard), `remote` (по net.box в репликасет
--- с данными) либо `sql` (таблица PostgreSQL или MySQL, шлюз приложения).
--- Ключ шардирования `model.bucket_of` необязателен: без него модель живёт
--- на узле без шардирования, а в кортеже нет поля `bucket_id`.
---
--- Части: `shape` — объявление, `check` — проверка входа, `tuple` —
--- запись ↔ кортеж, `query` — выборка по индексу, `scope` — условия
--- областей, `stamp` — отметки времени, `hook` — хуки записи, `record` —
--- класс записи, `factory` — фабрика, `migration` — шаг схемы,
--- `topology` — правило выбора шлюза, `gateway.*` — шлюзы, `serve` —
--- общие функции узла с данными, `binding` — привязка, `entity` — сама
--- модель.

local binding = require('tnt.model.binding')
local entity = require('tnt.model.entity')
local failure = require('tnt.model.failure')
local query = require('tnt.model.query')
local shapes = require('tnt.model.shape')
local stamps = require('tnt.model.stamp')
local topology = require('tnt.model.topology')
local world = require('tnt.model.world')

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Отказы моделей: роды и проверка `failure.is`.
Module.failure = failure

--- Раздел настроек, принадлежащий моделям, и его проверка — приложению.
Module.SECTION = topology.SECTION
Module.settings = topology.settings

--- Страница по умолчанию: столько записей отдаёт `all()` без `limit`.
---
--- Фасад называет её затем, чтобы приложение видело конец выборки,
--- не заходя в части пакета: страница короче этой — последняя. Это копия:
--- правка поля выборку не меняет, её страницу держит `tnt.model.query`.
Module.LIMIT = query.LIMIT

--- Самое большое смещение `offset`: `box` держит его в 32 битах.
Module.OFFSET = query.OFFSET

--- Подмена внешних зависимостей — для проверок; сам мир держит `tnt.model.world`.
Module._set_source = world._set_source

--- Заводит модель по объявлению.
---@param spec table
---@return TntModel
function Module.define(spec)
    return entity.new(spec)
end

--- Модель ли это.
Module.is = entity.is

--- Поле шардирования: бакет считается от названного поля первичного ключа.
---
--- Место в списке полей — место `bucket_id` в кортеже там, где узел
--- шардирован; на узле без шардирования поля в кортеже нет.
---@param field string
---@return table
function Module.bucket_of(field)
    if type(field) ~= 'string' then
        fail(('model.bucket_of: имя поля — строка, а не %s'):format(type(field)))
    end

    return { name = shapes.BUCKET_FIELD, type = 'unsigned', bucket_of = field }
end

--- Поле отметки времени: секунды от начала эпохи, которые ставит модель.
---
--- Необязательное и без умолчания: вход его не несёт, а у записи, лёгшей
--- до появления отметки, оно пустое. Место в списке полей — место
--- в кортеже, как у всякого поля.
---@param kind string Род отметки
---@param name string|nil Имя поля
---@param default string Имя по умолчанию
---@return table
local function stamp_field(kind, name, default)
    return { name = name or default, type = 'number', optional = true, stamp = kind }
end

--- Отметка создания: ставится при вставке, замена берёт её у прежней записи.
---@param name string|nil Имя поля; по умолчанию `created_at`
---@return table
function Module.created_at(name)
    return stamp_field(stamps.CREATED, name, 'created_at')
end

--- Отметка изменения: ставится при каждой записи.
---@param name string|nil Имя поля; по умолчанию `updated_at`
---@return table
function Module.updated_at(name)
    return stamp_field(stamps.UPDATED, name, 'updated_at')
end

--- Признак мягкого удаления: `delete` ставит отметку, выборка удалённых
--- не видит, `restore` снимает, `force_delete` удаляет окончательно.
---@param name string|nil Имя поля; по умолчанию `deleted_at`
---@return table
function Module.deleted_at(name)
    return stamp_field(stamps.DELETED, name, 'deleted_at')
end

--- Привязка моделей приложения к шлюзу узла — при применении конфигурации.
---
--- Шлюз источника `sql` приносит вызывающий: `{ sql = gateway }` —
--- пакет моделей от баз SQL не зависит.
---@param models TntModel[]
---@param settings TntModelSettings Проверенный раздел `models`
---@param sources table<string, TntModelGateway>|nil Шлюзы извне: `sql`
---@return TntModelBinding
function Module.bind(models, settings, sources)
    return binding.new(models, settings, sources)
end

--- Транзакция там, где данные: `box.atomic` на узле с данными, а на узле
--- «и роутер, и хранилище» — по его бакетам.
---
--- На выделенном роутере vshard и на узле без данных транзакции нет — это
--- ошибка программиста: тело транзакции живёт в функции узла с данными.
--- Там же запись модели внутри транзакции `box` — исключение: она ушла бы
--- по сети и легла мимо транзакции.
---@param fn function
---@param ... any
---@return any
function Module.atomic(fn, ...)
    local current, reason = binding.current()

    if current == nil or current.gateway == nil then
        fail(
            ('model.atomic: у узла нет привязанных моделей — %s'):format(
                reason or 'конфигурация ещё не применена'
            )
        )
    end

    return current.gateway.atomic(fn, ...)
end

return Module
