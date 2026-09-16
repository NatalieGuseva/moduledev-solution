# Regression tests

Закрывает единственный оставшийся пункт из фидбэка: *«Тестирование:
собственных regression tests нет»*. Два новых проекта, оба независимы от
`autocheck` и гоняются локально/в CI одной командой `dotnet test`.

## Cli.Tests — unit-тесты (без Docker, без БД)

Тестирует `ManifestSchemaValidator` — Draft 2020-12 валидацию манифестов,
добавленную в CLI (пункт «Manifest/OpenAPI contract неполон»): требование
`$schema`, canonical meta-schema validation, обработка `{}`/отсутствующих
полей/сломанного JSON без падения с необработанным исключением.

```bash
dotnet test Cli.Tests/Cli.Tests.csproj
```

## Api.Tests — integration/regression-тесты (нужен Docker)

Поднимает настоящий `postgres:17-alpine` через Testcontainers, накатывает
**те же самые** файлы, что и `cli migration apply` в проде
(`Api/Migrations/ChecksummedMigrations/*.sql` + `autocheck/fixtures/migrations/
900_opencheck_probe.sql`), создаёт те же четыре identity, что и
`postgres-init/00-bootstrap-roles.sh` — и проверяет контракт с БД напрямую,
от лица каждой роли:

- **`IdempotencyRegressionTests`** — атомарный claim до эффекта
  («Idempotency record создаётся после предметного эффекта»), и отдельно —
  что `course_runtime` реально может завершить (`UPDATE`) claimed-запись.
  Второе — ровно тот баг, который всплыл в `week-1-public-report.json` уже
  после первого раунда фиксов и был закрыт миграцией 008; этот тест поймал
  бы его сразу, без ожидания прогона публичного чекера.
- **`DbInvariantsRegressionTests`** — CHECK-constraints на
  `operation_kind`/`currency`/`amount` и append-only триггеры на
  `operation_events`/`action_dispatches`, причём именно от лица
  `course_owner` (владельца), а не ограниченного `course_runtime` — иначе
  тест доказывал бы только отсутствие грантов, а не сам constraint/триггер.
- **`RoleGrantsRegressionTests`** — обе стороны контракта на роли:
  `course_runtime` не может писать в `operations`/`action_catalog` напрямую,
  `course_publisher` не видит `operations` вообще, и наоборот — у каждой
  роли есть именно то, что ей нужно (`EXECUTE` на `api.invoke` для runtime,
  `course_owner` может писать в `opencheck.canary`).

```bash
dotnet test Api.Tests/Api.Tests.csproj
```

Первый прогон класса поднимает контейнер и применяет миграции один раз
(shared `[CollectionDefinition("Postgres")]` fixture) — это несколько секунд,
не по контейнеру на тест.

## В CI

Оба проекта — обычные `dotnet test`, никакой привязки к `check.sh`/autocheck.
`Api.Tests` требует доступный Docker-демон в раннере (GitHub Actions —
`ubuntu-latest` его уже включает).
