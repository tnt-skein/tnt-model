--- Внешние зависимости модели: box, конфигурация ядра, vshard, net.box.
---
--- Объявление одно на все части пакета: проверки подменяют мир одним вызовом,
--- и каждая часть видит ту же подмену. Всё берётся лениво и только там,
--- где нужно: vshard подключается внутри шлюза `sharded` и на узле без
--- шардирования не грузится вовсе, а `config` отвечает только под
--- кластерной конфигурацией.

local external = require('tnt.external')

---@class TntModelWorld
---@field current fun(): table Действующие средства
---@field _set_source fun(replacement: table|nil) Подмена средств — для проверок
local Module = {}

Module.current = external.install(Module, {
    --- Хранилище узла: `box` целиком — спейсы, `box.info`, `box.atomic`.
    box = function()
        return rawget(_G, 'box')
    end,

    --- Конфигурация ядра: место узла, роли шардирования, адреса соседей.
    config = function()
        return require('config')
    end,

    --- Роутер vshard — только на узле с ролью router.
    router = function()
        return require('vshard').router
    end,

    --- Хеш ключа шардирования — тот же, что у `bucket_id_mpcrc32` роутера.
    hash = function()
        return require('vshard.hash')
    end,

    --- Соединения с соседями — для шлюза `remote`.
    net_box = function()
        return require('net.box')
    end,

    --- Файбер: уступка управления в длинном обходе шлюза `local`.
    ---
    --- Через внешнюю зависимость затем, что уступка — развилка, а не мелочь: проверка
    --- встаёт на границу куска и считает уступки, иначе обход без них
    --- ничем не отличался бы от прежнего.
    fiber = function()
        return require('fiber')
    end,
})

return Module
