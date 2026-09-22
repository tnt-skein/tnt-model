rockspec_format = '3.0'

package = 'tnt-model'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-model.git',
    branch = 'main',
}

description = {
    summary = 'Модели данных: одно объявление — схема, проверка, доступ, фабрика; любая топология',
    detailed = [[
        Объявление формы записи — единственный источник: из него следуют
        шаг миграции спейса (функция от box — формат, первичный индекс,
        индексы модели), проверка входа с отказом «поле → причина
        по-русски», чтение и запись по ключу, выборка по индексу
        страницами с продолжением по записи, фабрика годных записей
        для проверок. Магии нет: запись — обычная таблица с классом
        методов, который видит проверка типов.

        Одна модель работает в любой топологии. Где данные, она не знает:
        шлюз ей привязывают по конфигурации узла — local (данные здесь:
        одиночный узел, ведущий и реплики репликасета, хранилище vshard),
        sharded (через роутер vshard: запись в бакет ключа, страницы
        слиянием с хранилищ), remote (по net.box в репликасет с данными
        с узла-прослойки). Реплика с writes = forward пересылает запись
        ведущему. Узел с данными публикует пять общих функций tnt_model_*
        по белому списку своих моделей.

        Отказ — пара nil, err с родом: invalid, conflict, readonly,
        unavailable, misrouted, unknown; ошибка программиста — исключение.
        Целые ключи от 2^53 проходят cdata без потери цифр.

        Зависимости: tnt-validate (проверка входа и раздела настроек),
        tnt-must (бросок без места вызова, текст о незнакомой настройке)
        и tnt-external (подмена box, конфигурации, vshard, net.box
        и файбера в проверках). Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-model',
    issues_url = 'https://github.com/tnt-skein/tnt-model/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'model', 'orm', 'vshard', 'validation', 'schema' },
}

dependencies = {
    'lua >= 5.1',
    -- Бросок без места вызова и текст отказа о незнакомой настройке.
    'tnt-must',
    -- Внешние зависимости: box, конфигурация, vshard, net.box, файбер.
    'tnt-external',
    -- Проверка входа по форме записи и раздела настроек `models`.
    'tnt-validate',
    -- Не объявлен `vshard`: его берут шлюз `sharded` и хранилище, то есть
    -- только узел с ролью шардирования, где рок стоит и так; на узле без
    -- шардирования он не подключается вовсе. `config` и `net.box` —
    -- части Tarantool.
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.model'] = 'tnt/model.lua',
        ['tnt.model.binding'] = 'tnt/model/binding.lua',
        ['tnt.model.check'] = 'tnt/model/check.lua',
        ['tnt.model.entity'] = 'tnt/model/entity.lua',
        ['tnt.model.factory'] = 'tnt/model/factory.lua',
        ['tnt.model.failure'] = 'tnt/model/failure.lua',
        ['tnt.model.gateway.forward'] = 'tnt/model/gateway/forward.lua',
        ['tnt.model.gateway.local'] = 'tnt/model/gateway/local.lua',
        ['tnt.model.gateway.remote'] = 'tnt/model/gateway/remote.lua',
        ['tnt.model.gateway.sharded'] = 'tnt/model/gateway/sharded.lua',
        ['tnt.model.migration'] = 'tnt/model/migration.lua',
        ['tnt.model.order'] = 'tnt/model/order.lua',
        ['tnt.model.query'] = 'tnt/model/query.lua',
        ['tnt.model.record'] = 'tnt/model/record.lua',
        ['tnt.model.serve'] = 'tnt/model/serve.lua',
        ['tnt.model.shape'] = 'tnt/model/shape.lua',
        ['tnt.model.topology'] = 'tnt/model/topology.lua',
        ['tnt.model.tuple'] = 'tnt/model/tuple.lua',
        ['tnt.model.world'] = 'tnt/model/world.lua',
    },
}
