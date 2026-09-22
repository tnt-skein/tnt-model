# tnt-model

Модели данных для Tarantool: одно объявление формы записи даёт шаг
миграции спейса, проверку входа, чтение и запись, выборку по индексу
и фабрику записей для проверок. Одна и та же модель работает в любой
топологии — на одиночном узле, в репликасете, в шардированном кластере,
на узле-прослойке без своих данных.

```lua
local model = require('tnt.model')

local User = model.define({
    space = 'users',
    fields = {
        { 'id', 'unsigned', primary = true },
        model.bucket_of('id'),                              -- ключ шардирования: бакет считается от id
        { 'name', 'string', min = 1, max = 255, trim = true },
        { 'age', 'unsigned', min = 0, max = 150 },
        { 'email', 'string', optional = true },
    },
    indexes = { age = { parts = { 'age' }, unique = false } },
    methods = {
        is_adult = function(self)
            return self.age >= 18
        end,
    },
})

local created, err = User.create({ id = 1, name = 'Мария', age = 46 })   --> запись либо nil, err
User.find(1):is_adult()                                                   --> true
User.where('age', '>=', 18):limit(50):all()                               -- страница по индексу
```

Зависимости: [tnt-validate](https://github.com/tnt-skein/tnt-validate),
[tnt-must](https://github.com/tnt-skein/tnt-must),
[tnt-external](https://github.com/tnt-skein/tnt-external).

## Зачем

- **Одно объявление — четыре следствия.** Шаг миграции
  (`User.migration()`), проверка входа (`User.validate`), доступ
  (`find`, `create`, `save`, `delete`, `where`) и фабрика записей для
  проверок (`User.factory`) выходят из одной таблицы и разойтись
  не могут.
- **Где данные, модель не знает.** Шлюз ей привязывает приложение
  по ролям узла: `local` — данные здесь, `sharded` — через роутер vshard,
  `remote` — по net.box в репликасет с данными. `User.find(7)` одинаков
  на роутере, хранилище, реплике и прослойке.
- **Отказ — пара `nil, err` с родом.** `invalid` с полями, `conflict`,
  `readonly`, `unavailable`, `misrouted`, `unknown`: обработчик выбирает
  по роду код ответа, а текст отдаёт клиенту. Ошибка программиста —
  исключение, которое называет модель и место.
- **Большие целые не теряют цифр.** Ключ от 2^53 проходит `create`,
  `find`, `where` и `after` как cdata, без приведения к числу Lua.
- **Никакой магии.** Запись — обычная таблица с классом методов,
  функции модели — замыкания над формой; проверка типов видит и то,
  и другое.

## Установка

```sh
tt rocks install tnt-model --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-model.git
cd tnt-model && tt rocks install --server=https://tnt-skein.github.io/rocks --only-deps tnt-model-scm-1.rockspec && tt rocks make
```

## Как пользоваться

| Объявление | Что это |
|---|---|
| `space` | имя спейса |
| `fields` | поля **списком**, по порядку кортежа: `{ 'name', 'string', max = 255 }` либо `{ name = 'name', type = 'string' }` |
| `indexes` | `имя = { parts = { поля }, unique = true/false }`; первичный строится из полей с `primary = true` |
| `rules` | свои правила: `function(record) return 'текст', 'поле' end` |
| `methods` | методы записи, зовутся двоеточием; имена `save`, `delete`, `to_table` заняты |
| `factory` | `function(sequence) return { … } end` — значения фабрики поверх умолчаний по роду |

Роды полей: `unsigned`, `integer`, `number`, `string`, `boolean`, `uuid`.
Настройки: `primary`, `optional`, `default`; у чисел `min`, `max`;
у строк `min`, `max` (в знаках), `pattern`, `one_of`, `trim`.

| Функция модели | Что делает |
|---|---|
| `validate(input)` | запись по форме, в хранилище не пишет |
| `create(input)` | проверка и вставка; занятый ключ — `conflict` |
| `find(key)` | запись либо `nil`; `nil, err` — отказ узла |
| `delete(key)` | `true` — была, `false` — не было |
| `where(field, op, value)` | выборка по индексу: `=`, `>`, `>=`, `<`, `<=`, `between` |
| `scan()` | полный обход — только явно и страницами |
| `factory(overrides)` | годная запись для проверок; `:save()` кладёт |
| `migration()` | шаг схемы: функция от `box` |
| `bound()` | имя привязанного шлюза; `nil` — не привязана |

У записи — `save()`, `delete()`, `to_table()` и методы объявления.
Выборка: `limit(n)` (по умолчанию `model.LIMIT`, 100), `after(record)`,
`all()`, `first()`, `count()`.

### Привязка к узлу

```lua
local settings = model.settings(section)              -- раздел `models` настроек; nil — умолчания
local binding = model.bind({ User }, settings)        -- шлюз по ролям узла
binding.attach()                                       -- модели переключаются на него

for name, fn in pairs(binding.functions) do           -- на узле с данными — функции tnt_model_*
    rawset(_G, name, fn)
end
```

`bind` собирает привязку целиком, ничего не переключая: сорвавшаяся
сборка оставляет узел при прежней. Настройки раздела: `source`
(`auto`, `local`, `sharded`, `remote`), `replicaset`, `timeout`,
`writes` (`local`, `forward` — пересылка записи с реплики ведущему).
Транзакция — `model.atomic(fn, …)` там, где данные.

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov, vshard и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (104 проверки,
1294 строки, 904 мутанта в девятнадцати модулях). Пять наборов живых
проверок поднимают настоящие узлы в дочерних процессах: одиночный узел,
репликасет из трёх процессов с пересылкой записи, прослойка перед
репликасетом, роутер с двумя хранилищами, узел с обеими ролями vshard.

## Документ

Полное описание с обоснованием решений: [docs/model.md](docs/model.md).

## Лицензия

MIT.
