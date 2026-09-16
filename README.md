# Неделя 1. Database-first action runtime

Решение задания ModuleDev — Неделя 1: C# gateway и generic action runtime, публикующий зарегистрированные PostgreSQL-функции как HTTP actions.

## Решение

### Архитектура

Решение состоит из четырёх сервисов в Docker Compose:

- **gateway** (ASP.NET Core, YARP) — единственная точка входа снаружи, публикует host-порт `8080`. Проксирует запросы во внутренний `api` по Compose DNS (`http://api:8080`), не содержит предметной логики и не имеет доступа к PostgreSQL.
- **api** — внутренний action runtime без опубликованных host-портов. Выполняет проверку JWT, формирует доверенный context, валидирует request/response schema и вызывает `api.invoke(...)` в одной Npgsql transaction. Подключается к PostgreSQL под ограниченной ролью `course_runtime` (см. «Роли PostgreSQL» ниже), а не под суперпользователем. Запускается только после того, как `cli` успешно применит миграции (`service_completed_successfully`).
- **cli** — Course CLI. При `docker compose up` по умолчанию выполняет `migration apply` и завершается — миграции применяются автоматически при каждом чистом запуске под ролью `course_migrator`. Для остальных команд (публикация/активация/отключение actions) запускается вручную через `docker compose run --rm cli ...` под ролью `course_publisher` — при этом переопределяет команду по умолчанию. Пишет в stdout ровно один JSON-документ (envelope `status: ok|error`), диагностика — в stderr.
- **postgres** — PostgreSQL 17, авторитетное состояние (схемы `course`, `api`, `autocheck`), данные хранятся в named volume `course_pgdata` и переживают пересоздание `gateway`/`api`/`cli`. При первой инициализации (`docker-entrypoint-initdb.d`) поднимает identity-роли (см. ниже) через `postgres-init/00-bootstrap-roles.sh`.

Направление вызовов: клиент → `gateway:8080` → `api` (internal, Compose DNS) → JWT + context → resolve action manifest → Npgsql transaction → `api.invoke(...)` → зарегистрированная PostgreSQL-функция → commit/rollback.

#### Роли PostgreSQL

Ни один сервис не подключается к PostgreSQL под `POSTGRES_USER` (суперпользователем). Вместо этого — четыре отдельные identity, минимальные по правам:

| Роль | LOGIN | Кто использует | Права |
|---|---|---|---|
| `course_owner` | нет (NOLOGIN) | никто напрямую | единственный настоящий владелец схемы/таблиц/функций, в том числе `SECURITY DEFINER` |
| `course_migrator` | да | `cli migration apply` | DDL — через членство в `course_owner`, без прямого доступа к `operations`/`action_catalog` |
| `course_publisher` | да | `cli action publish/activate/disable/list` | только `course.action_catalog` и `EXECUTE` на `course.publish_action` |
| `course_runtime` | да | `api` (боевой трафик) | `SELECT` на `action_catalog`, `SELECT/INSERT/UPDATE` на `idempotency_records`, `EXECUTE` на `api.invoke`; прямого DML к предметным таблицам (`operations`, `operation_events`, `action_dispatches`) нет |

`operation_events`/`action_dispatches` дополнительно защищены append-only триггером — `UPDATE`/`DELETE` запрещены даже для `course_owner`.

Диаграмма: [C4 Container diagram](docs/c4-container.md)

### Запуск

**Требования:** Docker Desktop с Compose v2.20+ (нужна поддержка `service_completed_successfully`).

```bash
docker compose up -d --build
```

Никаких ручных SQL-команд, `.env` или публикации встроенных actions после чистого запуска не требуется — в `docker-compose.yml` уже заданы безопасные значения по умолчанию (`POSTGRES_PASSWORD`, `COURSE_JWT_*`, пароли identity-ролей) для локальной разработки и проверки. `cli` применяет миграции автоматически, `api` стартует только после их успешного завершения.

Проверка доступности:

```bash
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready
```

#### Переопределение конфигурации (опционально)

Значения по умолчанию подходят для локального запуска и автопроверки "как есть". Если нужны свои — создайте `.env` в корне проекта (файл не коммитится в Git):

```bash
POSTGRES_USER=postgres
POSTGRES_PASSWORD=your_password_here
POSTGRES_DB=course
COURSE_JWT_ISSUER=moduledev-course
COURSE_JWT_AUDIENCE=moduledev-api
COURSE_JWT_SIGNING_KEY=your_signing_key_here_at_least_32_chars
COURSE_MIGRATOR_PASSWORD=your_migrator_password_here
COURSE_PUBLISHER_PASSWORD=your_publisher_password_here
COURSE_RUNTIME_PASSWORD=your_runtime_password_here
```

Проверка курса подставляет собственный `COURSE_JWT_SIGNING_KEY` через Compose override — значение из `.env` для неё не используется.

Пароли identity-ролей (`COURSE_MIGRATOR_PASSWORD`/`COURSE_PUBLISHER_PASSWORD`/`COURSE_RUNTIME_PASSWORD`) применяются только на **пустом** volume — их создаёт `postgres-init/00-bootstrap-roles.sh` при первой инициализации PostgreSQL. Смена пароля на уже поднятом стеке требует `docker compose down -v`.

### Конфигурация

`api` и `cli` читают переменные окружения. В `docker-compose.yml` для всех них заданы безопасные значения по умолчанию для локального запуска и автопроверки; `.env` нужен только если хотите их переопределить (реальные секреты в репозиторий не попадают):

| Переменная | Назначение |
|---|---|
| `COURSE_JWT_ISSUER` | issuer для проверки JWT (`moduledev-course`) |
| `COURSE_JWT_AUDIENCE` | audience для проверки JWT (`moduledev-api`) |
| `COURSE_JWT_SIGNING_KEY` | ключ подписи HS256, ≥ 32 байт |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | параметры подключения суперпользователя (только для init/диагностики, рантайм его не использует) |
| `COURSE_MIGRATOR_PASSWORD`, `COURSE_PUBLISHER_PASSWORD`, `COURSE_RUNTIME_PASSWORD` | пароли identity-ролей `course_migrator`/`course_publisher`/`course_runtime`, создаваемых `postgres-init/00-bootstrap-roles.sh` |
| `ConnectionStrings__CourseDb` | строка подключения `api` (роль `course_runtime`) |
| `ConnectionStrings__CourseDbMigration` | строка подключения `cli migration apply` (роль `course_migrator`) |
| `ConnectionStrings__CourseDbPublication` | строка подключения `cli action publish/activate/disable/list` (роль `course_publisher`) |

`.env` с реальными секретами не входит в Git.

### Миграции

SQL-миграции лежат в `Api/Migrations/ChecksummedMigrations/` и применяются сервисом `cli` под ролью `course_migrator`:

- **Автоматически** — при каждом `docker compose up` (в том числе `--force-recreate`), до старта `api`.
- **Вручную**, при необходимости повторного прогона на уже поднятом стеке:

```bash
docker compose run --rm cli migration apply /app/Migrations/ChecksummedMigrations
```

Миграции выполняются в лексикографическом порядке файлов, каждая — в отдельной транзакции. Применённые файлы фиксируются по SHA-256 checksum в `course.schema_migrations`: повтор с тем же содержимым безопасен (skip), изменение уже применённого файла возвращает `manifest.conflict`. `api` migration credentials не использует.

### Проверка

Важно: перед запуском проверки обязательно освободите порт и очистите состояние предыдущего запуска:

```bash
docker compose down -v
./check.sh
```

Результат записывается в `week-1-public-report.json`.

#### Собственные regression tests

Независимо от `check.sh` — два `dotnet test` проекта, оба запускаются из корня решения:

```bash
dotnet test Cli.Tests/Cli.Tests.csproj    # unit-тесты, без Docker и БД (~3 сек)
dotnet test Api.Tests/Api.Tests.csproj    # интеграционные, через Testcontainers — нужен Docker (~15 сек)
```

`Cli.Tests` проверяет валидацию манифеста (JSON Schema Draft 2020-12, обязательный `$schema`). `Api.Tests` поднимает настоящий `postgres:17-alpine`, накатывает те же файлы миграций, что и `cli migration apply` в проде, создаёт те же identity-роли и проверяет от их лица: атомарность idempotency claim, CHECK-constraints на `operations`, append-only триггеры на `operation_events`/`action_dispatches`, и то, что `course_runtime`/`course_publisher` не имеют доступа за пределами своего назначения. Подробности — в [`TESTS.md`](TESTS.md).

### Диагностика

```bash
docker compose logs gateway
docker compose logs api
docker compose logs cli
docker compose logs postgres
```

**Health-check:**

```bash
curl -i http://localhost:8080/health/live
# Ожидается: пустое тело, HTTP 200

curl http://localhost:8080/health/ready
# Ожидается: {"status":"ready"}
```

**OpenAPI:**

```bash
curl http://localhost:8080/openapi/default.json | head -50
curl http://localhost:8080/openapi/actions/payment/request/1.json
```

**Проверить, что миграции применились:**

```bash
docker compose exec postgres psql -U postgres -d course -c "\dt course.*"
docker compose exec postgres psql -U postgres -d course -c "\df opencheck.*"
```

**Тестовый вызов action напрямую в PostgreSQL** (в обход HTTP — удобно, когда нужно исключить gateway/api из диагностики):

```bash
docker compose exec postgres psql -U postgres -d course -c "
SELECT api.invoke(
  'payment', 'request', 1,
  '{\"principal\":\"test\",\"consumer\":\"test\",\"scopes\":[\"payment:write\"],\"correlationId\":\"00000000-0000-0000-0000-000000000001\",\"requestId\":\"test-req-1\",\"deadline\":\"2030-01-01T00:00:00Z\"}'::jsonb,
  '{\"operationKind\":\"PAYMENT_EXECUTION\",\"amount\":\"100.00\",\"currency\":\"RUB\"}'::jsonb
);
"
```

Подключение к БД для Windows (Git Bash), интерактивная сессия:

```bash
winpty docker compose exec postgres psql -U postgres -d course
```

### Ограничения

- На первой неделе `process_id` в `operations` всегда `null`, workflow ещё не реализован.
- Поддерживается только валюта `RUB`.
- Только `POST` в обязательной части action manifest.
- Rate limiting, CORS-трансформации и защитные очереди gateway не входят в неделю 1.


ADR:
- [ADR 001: Trust boundary](docs/001-trust-boundary.md)
- [ADR 002: Технический и предметный результат](docs/002-technical-vs-domain-result.md)
