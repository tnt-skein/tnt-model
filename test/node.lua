--- Сценарий узла стенда: модели пользователей и записей блога,
--- привязанные по топологии.
---
--- Почта пользователя необязательна и стоит в индексе: страницы по ней
--- проходят записи без почты — место NULL в индексе — через роутер
--- и прослойку.
---
--- Записи блога — модель с отметками времени, мягким удалением
--- и областью: через роутер и прослойку отметку ставит узел с данными,
--- способ удаления и условия выборки едут к нему по проводу.
---
--- Здесь руками и по порядку сделано то, что приложение делает при
--- применении конфигурации: раздел `models` — из меток узла
--- (`model_source`, `model_replicaset`, `model_writes`, `model_timeout` —
--- метка всегда строка, и срок из неё читается числом), привязка целиком,
--- переключение моделей, публикация функций узла с данными глобалами.
--- Перечитывание конфигурации — глобал `rebind`: новая привязка по тому же
--- разделу и отпускание прежней, как у приложения при применении; модели
--- сверх стендовых проверка передаёт ему списком.
--- Схема поднимается там, где узел держит данные и принимает запись;
--- реплика получает её журналом. Ничего сверх пакета здесь нет нарочно:
--- проверяется сам пакет, а не то, что поверх него.
---
--- Сценарий зовётся после применения конфигурации, и отметка `ready`
--- в конце — «узел поднят» для luatest.

require('strict').on()

local model = require('tnt.model')

local User = model.define({
    space = 'users',
    fields = {
        { 'id', 'unsigned', primary = true },
        model.bucket_of('id'),
        { 'name', 'string', min = 1, max = 255, trim = true },
        { 'age', 'unsigned', min = 0, max = 150 },
        { 'email', 'string', optional = true },
    },
    indexes = {
        age = { parts = { 'age' }, unique = false },
        email = { parts = { 'email' }, unique = false },
    },
    methods = {
        is_adult = function(self)
            return self.age >= 18
        end,
    },
})

local Post = model.define({
    space = 'posts',
    fields = {
        { 'id', 'unsigned', primary = true },
        model.bucket_of('id'),
        { 'title', 'string', min = 1 },
        { 'published', 'boolean', default = false },
        model.created_at(),
        model.updated_at(),
        model.deleted_at(),
    },
    scopes = { published = { { 'published', '=', true } } },
})

local labels = require('config'):get('labels', {}) or {}
local settings = model.settings({
    source = labels.model_source,
    replicaset = labels.model_replicaset,
    writes = labels.model_writes,
    timeout = tonumber(labels.model_timeout),
})

--- Привязка по разделу: собрана целиком, модели переключены на неё,
--- функции узла с данными опубликованы.
---@param extra TntModel[]|nil Модели сверх стендовых: их приносит проверка
---@return TntModelBinding
local function bound(extra)
    local models = { User, Post }

    for _, other in ipairs(extra or {}) do
        table.insert(models, other)
    end

    local fresh = model.bind(models, settings)

    fresh.attach()

    for name, fn in pairs(fresh.functions) do
        rawset(_G, name, fn)
    end

    return fresh
end

local binding = bound()

if assert(binding.topology).serves and not box.info.ro and box.space.users == nil then
    box.atomic(function()
        User.migration()(box)
        Post.migration()(box)
    end)
end

rawset(_G, 'User', User)
rawset(_G, 'Post', Post)
rawset(_G, 'model', model)
rawset(_G, 'binding', binding)

--- Перечитывание конфигурации с тем же разделом: новая привязка
--- собирается рядом, модели переключаются на неё, и только потом
--- прежняя отпускается — порядок приложения при применении. Модели
--- сверх стендовых приходят аргументом: проверка, которой нужна своя
--- модель на всех узлах, привязывает её перечитыванием со списком,
--- а перечитыванием без списка отпускает.
rawset(_G, 'rebind', function(extra)
    local previous = rawget(_G, 'binding')

    rawset(_G, 'binding', bound(extra))
    previous.close()
end)

rawset(_G, 'ready', true)
