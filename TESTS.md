# Regression tests

Закрывает пункт из фидбэка: *«Тестирование: собственных regression tests
нет»* — и отдельно пункт *«Не хватает собственных регрессий состояния и
сбоев»* (двумя новыми тестовыми классами в `Api.Tests`, см. ниже). Оба
проекта независимы от `autocheck` и гоняются локально/в CI одной командой
`dotnet test`.

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
(`Api/Migrations/ChecksummedMigrations/*.sql`, 001–010, плюс любые файлы из
`autocheck/fixtures/migrations/`), создаёт те же четыре identity, что и
`postgres-init/00-bootstrap-roles.sh` — и проверяет контракт с БД напрямую,
от лица каждой роли.

Миграции применяются **суперпользователем** (`SuperuserConnectionString`),
не `course_migrator` — так же, как реально подключается `cli` в
`docker-compose.yml` (`ConnectionStrings__CourseDb` с `POSTGRES_USER`).
`course_migrator`, даже будучи членом `course_owner`, не имеет `CREATEROLE`
(членство в роли не передаёт role-атрибуты вроде `CREATEROLE`/`CREATEDB`) —
подключение им сюда падало бы уже на `CREATE ROLE workflow_worker` в
`005_workflow_schema.sql` с `permission denied to create role`, и **весь**
`Api.Tests` не проходил бы дальше инициализации фикстуры, независимо от
содержимого конкретных тестов.

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
  роли есть именно то, что ей нужно (`EXECUTE` на `api.invoke` для runtime).
  Отдельно — `CourseOwner_CanAccessAnyFutureTableCreatedByPostgresInSchemas`:
  создаёт таблицу со случайным именем в `opencheck` от лица суперпользователя
  (так же, как это делает любая фикстура автопроверки в проде) и проверяет,
  что `course_owner` получает к ней доступ автоматически, без ручного
  `GRANT` под конкретное имя. Тест умышленно не завязан на committed файл
  фикстуры с фиксированным именем таблицы (`opencheck.canary` из более
  ранних комментариев к миграции 008 — такой файл в этом репозитории не
  поставляется, `autocheck/fixtures/migrations/` содержит только фикстуру
  недели 2 с другой схемой) — проверяется сам механизм (`ALTER DEFAULT
  PRIVILEGES FOR ROLE postgres`, миграция 008, пункт 5), а не конкретное имя.
- **`WorkflowReclaimRegressionTests`** — самостоятельный набор на lease/
  fencing/reclaim, независимый от `autocheck`, на границе `SET ROLE
  workflow_worker` (не суперпользователем — чтобы ловить и grant-ошибки
  тоже):
  - `TwoWorkers_CompetingClaim_OnlyOneWins` — два конкурирующих
    `claim_jobs` за одну и ту же `READY` job; ровно один получает её
    (`FOR UPDATE SKIP LOCKED`).
  - `ExpiredLease_ReclaimedByAnotherWorker_PreservesJobAndExecutionId_NewAttempt` —
    протухший лизинг реклеймится другим воркером: `jobId`/`executionId`
    сохраняются, новый `attemptId`, `leaseVersion` растёт, прежняя попытка
    помечается `STALE`.
  - `StaleFinish_RejectedWithLeaseStale_DoesNotOverwriteReclaimedJob` —
    устаревший `finish_job` (старые `owner`/`leaseVersion`) отклоняется
    как `workflow.lease_stale`, не трогая состояние, которое уже
    принадлежит новому владельцу.
  - `CrashBetweenActionAndFinish_RecoveredByAnotherWorker_ExactlyOneEffect` —
    воспроизводит «остановился между действием и подтверждением»: первый
    worker успевает вызвать action, «падает» до `finish_job`; второй
    реклеймит job, тоже вызывает action тем же `executionId` и корректно
    завершает. Проверяется не только ответ команд, но и итоговое число
    предметных эффектов (`training.canary_log`) — ровно один, несмотря на
    два физических вызова `api.invoke`.
  - `AttemptCountTracksAllClaims_FailureCountTracksOnlyDomainFailures_StaysConsistentWithTaskAttemptHistory` —
    пункт фидбэка «Job-счётчик попыток не обновляется вместе с attempt»:
    прогоняет job через stale-реклейм → реальный retryable-провал →
    успешное завершение и проверяет, что `job.attempt_count` в точности
    равен числу строк `task_attempt` на каждом шаге (миграция 011
    разделила единый счётчик на `attempt_count`, растущий на каждый
    claim, и `failure_count`, растущий только на реальных доменных
    провалах — см. [ADR 003](../docs/003-lease-fencing-at-least-once.md)).
  - `TaskAttempt_DuplicateAttemptNumberForSameJob_IsRejectedByUniqueConstraint` —
    прямая проверка `UNIQUE (job_id, attempt_number)` из миграции 011:
    защита инварианта «attempt_count == count(task_attempt)» от будущей
    регрессии в логике нумерации, а не только доказательство текущего
    отсутствия бага.
  - `ReceiveSignal_DuplicateMessageId_ReturnsDuplicateWithoutReapplying` —
    "повтор сигнала" из фидбэка: тот же `message_id`/процесс/тип/тело
    второй раз возвращает `duplicate`, не заводит вторую строку в
    `workflow_signal` и не продвигает процесс повторно.
  - `ReceiveSignal_ConflictingMessageId_RejectedWithoutOverwritingOriginal` —
    "конфликт сигнала": тот же `message_id`, но другое тело отклоняется как
    `workflow.signal_conflict`, не перезаписывая исходную принятую запись.

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
