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
---
--- Где данные, модель не знает: приложение при применении конфигурации
--- привязывает ей шлюз по узлу (`model.bind`) — `local` (данные здесь),
--- `sharded` (через роутер vshard), `remote` (по net.box в репликасет
--- с данными). Ключ шардирования `model.bucket_of` необязателен: без него
--- модель живёт на узле без шардирования, а в кортеже нет поля `bucket_id`.
---
--- Части: `shape` — объявление, `check` — проверка входа, `tuple` —
--- запись ↔ кортеж, `query` — выборка по индексу, `record` — класс
--- записи, `factory` — фабрика, `migration` — шаг схемы, `topology` —
--- правило выбора шлюза, `gateway.*` — шлюзы, `serve` — общие функции
--- узла с данными, `binding` — привязка, `entity` — сама модель.

local binding = require('tnt.model.binding')
local entity = require('tnt.model.entity')
local failure = require('tnt.model.failure')
local query = require('tnt.model.query')
local shapes = require('tnt.model.shape')
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

--- Привязка моделей приложения к шлюзу узла — при применении конфигурации.
---@param models TntModel[]
---@param settings TntModelSettings Проверенный раздел `models`
---@return TntModelBinding
function Module.bind(models, settings)
    return binding.new(models, settings)
end

--- Транзакция там, где данные: `box.atomic` на узле с данными.
---
--- Через роутер vshard и на узле без данных транзакции нет — это ошибка
--- программиста: тело транзакции живёт в функции узла с данными.
---@param fn function
---@param ... any
---@return any
function Module.atomic(fn, ...)
    local current = binding.current()

    if current == nil or current.gateway == nil then
        fail(
            'model.atomic: у узла нет привязанных моделей — конфигурация ещё не применена'
        )
    end

    return current.gateway.atomic(fn, ...)
end

return Module
