# Проверки пакета: форматирование, линт, тесты, покрытие, мутанты.

LUATEST  := .rocks/bin/luatest
LUACHECK := .rocks/bin/luacheck
COVERAGE_MIN ?= 100

.PHONY: help
help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*?## " } { printf "  %-12s %s\n", $$1, $$2 }'

# Шардирование: живые проверки поднимают кластер vshard, а проверки
# на двойниках берут у него хеш ключа (`vshard.hash`) — тот самый, которым
# хранилище считает бакет. Выпуск закреплён: веер `map_callrw` и номера
# бакетов сверены на 0.1.42, а новый выпуск мог бы молча поменять и то,
# и другое. Сам пакет vshard не требует: на узле без шардирования он
# не подключается вовсе, поэтому его нет и в зависимостях рокспека.
.PHONY: deps
deps: ## Поставить зависимости пакета и инструменты проверок в .rocks
	tt rocks install --server=https://luarocks.org luatest
	tt rocks install --server=https://luarocks.org luacheck 1.2.0
	tt rocks install --server=https://luarocks.org luacov 0.17.0
	tt rocks install --server=https://luarocks.org cluacov
	tt rocks install --server=https://rocks.tarantool.org vshard 0.1.42
	tt rocks install --server=https://tnt-skein.github.io/rocks --only-deps tnt-model-scm-1.rockspec

.PHONY: fmt
fmt: ## Отформатировать код
	stylua .

.PHONY: fmt-check
fmt-check: ## Проверить форматирование, ничего не меняя
	stylua --check .

.PHONY: lint
lint: ## Линт
	$(LUACHECK) . --formatter plain --codes

.PHONY: test
test: ## Прогон проверок
	$(LUATEST) test/

.PHONY: coverage
coverage: ## Проверки с покрытием и порогом
	mkdir -p var && rm -f var/luacov.stats.out
	$(LUATEST) test/ --coverage
	tarantool tools/coverage_gate.lua $(COVERAGE_MIN)

# Мутационное тестирование — утилитой tnt-mutants (github.com/tnt-skein/tnt-mutants).
.PHONY: mutants
mutants: ## Мутационное тестирование изменённых модулей
	tnt-mutants

.PHONY: mutants-all
mutants-all: ## Мутационное тестирование всех модулей
	tnt-mutants $(shell find tnt -name '*.lua' | sort)

.PHONY: check
check: fmt-check lint test coverage ## Все проверки, кроме мутантов

.PHONY: clean
clean: ## Убрать рабочие каталоги
	rm -rf var
