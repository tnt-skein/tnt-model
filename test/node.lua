--- Сценарий узла стенда: модель пользователей, привязанная по топологии.
---
--- Здесь руками и по порядку сделано то, что приложение делает при
--- применении конфигурации: раздел `models` — из меток узла
--- (`model_source`, `model_replicaset`, `model_writes`), привязка целиком,
--- переключение моделей, публикация функций узла с данными глобалами.
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
    },
    indexes = { age = { parts = { 'age' }, unique = false } },
    methods = {
        is_adult = function(self)
            return self.age >= 18
        end,
    },
})

local labels = require('config'):get('labels', {}) or {}
local settings = model.settings({
    source = labels.model_source,
    replicaset = labels.model_replicaset,
    writes = labels.model_writes,
})
local binding = model.bind({ User }, settings)

binding.attach()

for name, fn in pairs(binding.functions) do
    rawset(_G, name, fn)
end

if assert(binding.topology).serves and not box.info.ro and box.space.users == nil then
    box.atomic(User.migration(), box)
end

rawset(_G, 'User', User)
rawset(_G, 'model', model)
rawset(_G, 'binding', binding)
rawset(_G, 'ready', true)
