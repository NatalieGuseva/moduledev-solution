# Патч: правки фидбэка недель 2/3 + неделя 4 (аварийный режим)

Пути в этом архиве повторяют пути в `moduledev-solution` — просто скопируй
файлы поверх репозитория (или `git apply`/`cp -r` вручную) и накати новые
миграции через `cli`.

**Важно: код не собирался и не гонялся против настоящего PostgreSQL/docker
compose в этой сессии** (для .NET нет доступа к nuget.org в этой песочнице,
для docker нет daemon'а). Логику миграций, ролей/грантов и bootstrap-фикс
я проверил напрямую на локальном PostgreSQL 16 (реальные `psql`-сессии,
не догадки) — на это ушла отдельная часть времени. C#/Python код собран
по прочитанному исходнику и существующим паттернам репозитория максимально
аккуратно, но перед мержем прогони `dotnet build` + полный `docker compose up`
и локальные тесты сам.

## Что было исправлено (фидбэк недель 2–3)

Неделя 2 (просроченный LEASED / job attempt_count / регрессии) — **уже
исправлено в текущем коде репозитория** (007_workflow_functions.sql:
reclaim expired LEASED, attempt_count синхронизирован; регрессии есть).
Раньше присланный PDF был по commit `eb21a1be70cf`, а актуальный код —
уже после этого. Тут я ничего не трогал.

Неделя 3, из присланного PDF `d9eb2c36c720`:

| # | Файл(ы) | Что было | Что стало |
|---|---|---|---|
| 1 | `python/receipt_adapter.py` | INFO-лог с URL, signature, telom receipt | `log_event()` без signature/body — только `externalRequestId`/`messageId`/`httpStatus`/`durationMs` |
| 2 | `Api/Migrations/.../017_...sql` (`delivery.record_inbox`) | DUPLICATE по `body = p_body` (JSONB) | DUPLICATE по exact `body_hash = p_body_hash` |
| 3 | `python/models.py`, `python/receipt_adapter.py` | `message` не обязателен; `content_length or 0` перед `request.text()` | `message` в `REQUIRED_FIELDS`; `_read_bounded_body()` — потоковое чтение с обрывом на `max_body_size` независимо от `Content-Length` |
| 4 | `Api.Tests/PostgresFixture.cs` | bootstrap не создавал схемы/владение, миграции шли под суперпользователем | bootstrap воспроизводит `postgres-init/00-bootstrap-roles.sh` 1:1 (схемы `course/opencheck/payment/workflow/delivery/training` сразу под `course_owner`), миграции идут под `course_migrator` — как в проде. **Корневую причину `permission denied for schema training` я воспроизвёл и проверил фикс на реальном Postgres 16** (см. ниже) |
| 5 | `Api.Tests/Api.Tests.csproj` | транзитивный SSH.NET 2024.1.0 (GHSA-mggc-4xg6-vcxf, GHSA-q939-rpr3-3284) | прямой `PackageReference SSH.NET 2024.2.0` (nearest-wins) |

### Корневая причина permission denied for schema training (проверено на Postgres 16)

`ALTER FUNCTION ... OWNER TO course_owner` и `REVOKE EXECUTE ON ALL
FUNCTIONS IN SCHEMA training FROM PUBLIC` требуют, чтобы **новый
владелец** (`course_owner`) имел `CREATE`/`USAGE` на схему `training`.
В проде это гарантирует `bootstrap-roles.sh` (`ALTER SCHEMA training OWNER
TO course_owner` до всяких миграций). В тесте схему `training` создавала
голая миграция 010 под суперпользователем — `course_owner` её не владел,
отсюда падение. `ALTER DEFAULT PRIVILEGES IN SCHEMA training`, вопреки
интуиции, к этой ошибке отношения не имеет — она проходит и без
владения; ловят именно `ALTER FUNCTION ... OWNER TO` и `REVOKE ... IN
SCHEMA`.

## Неделя 4 — что добавлено

### SQL (`017_reliability_and_diagnostics.sql`, `018_insert_diagnostics_actions.sql`)
- `delivery.outbox.dead_at` + `delivery.fail_outbox`: 4 attempts (было 3),
  задержки 200/400/800мс + jitter 0..100мс, `dead_at` при DEAD.
- `autocheck.jobs`/`autocheck.outbox` — аддитивные колонки `created_at`/`dead_at`
  для `/metrics` (без новых грантов — GRANT на сам view уже был).
- Схема `diagnostics`, функции `diagnostics.trace_query`/`diagnostics.stalled_query`
  (SECURITY DEFINER, OWNER `course_owner`, EXECUTE PUBLIC отозван) +
  регистрация actions `diagnostics.trace`/`diagnostics.stalled` в
  `course.action_catalog` — вызываются через тот же generic `api.invoke`,
  что и все остальные actions, никакого нового C#-контроллера не нужно.
- **Проверь на своих данных**: резолвинг 11 identifiers в `trace_query`
  построен по реальной схеме таблиц (`course.operations.process_id`,
  `delivery.outbox.correlation_id/provider_payment_id`, `workflow.task_attempt`,
  `payment.decision`), но я не гонял её против живых данных — стоит
  прогнать на паре реальных operationId/jobId/outboxId и свериться с
  `docs/observability-contracts.md`.

### `Api/Controllers/ActionsController.cs`
Добавлен маппинг `diagnostics.trace_not_found -> 404` (без него ушёл бы в 500).

### `Api/Controllers/HealthController.cs`, `Gateway/Controllers/HealthController.cs`
`{"status":"alive"}` → `{"status":"live"}`, `{"status":"unhealthy"}` →
`{"status":"not_ready","code":"dependency.unavailable"}` — под контракт.

### `Api/Controllers/MetricsController.cs` (новый)
Единственный `/metrics` во всём контуре (по схеме задания — только на api),
OpenMetrics text format, `# EOF` в конце, все 6 серий поверх уже
существующих `autocheck.jobs`/`autocheck.processes`/`autocheck.outbox`.

### Python (`python/observability.py` — новый, плюс правки dispatcher/reconciler/adapter/config/__main__)
- `configure_json_logging()` + `log_event()` — один лог = один JSON object.
- `Failpoint` — `after_outbox_claim`/`after_provider_response` (dispatcher),
  `after_inbox_saved` (reconciler).
- `HealthServer`/`add_health_routes` — `/health/live`+`/health/ready` для
  dispatcher (порт 8090), reconciler (8091), adapter (тот же 8080, что и
  callback — через `add_health_routes` в уже существующий `web.Application`).
- `RuntimeProfile.from_env()` — общий `COURSE_TEST_PROFILE`/`COURSE_FAILPOINT`/
  `COURSE_INSTANCE_ID`/`COURSE_HEALTH_PORT` для трёх сервисов.
- `SIGTERM` теперь по-настоящему graceful (раньше `except KeyboardInterrupt`
  не ловил SIGTERM вообще на Linux — только SIGINT).

### Workflow.Worker (C#)
`after_job_claim`/`after_action_before_finish` **уже были реализованы** в
`StepRunner.cs` — не трогал. Добавлено:
- `WorkerHealthServer.cs` (новый) — `/health/live`+`/health/ready` через
  `System.Net.HttpListener` (без ASP.NET Core, проект консольный).
  Порт по умолчанию 8092, `COURSE_HEALTH_PORT`.
- `Program.cs` — подключение health-сервера + `AddJsonConsole()` вместо
  `AddSimpleConsole()` (валидный JSON per line; это НЕ та же схема полей,
  что в python/observability.py — унификация полей `correlationId`/`event`
  между C# и Python выходит за рамки этого патча).
- `Workflow.Worker/Dockerfile` — добавлен `curl` (нужен для healthcheck,
  `mcr.microsoft.com/dotnet/runtime` не содержит его по умолчанию).

### `docker-compose.yml`
- Новые сервисы `outbox-dispatcher-b`, `inbox-reconciler-b` (тот же образ,
  свой `OUTBOX_OWNER`/`COURSE_INSTANCE_ID`, те же грант-роли — фактическая
  устойчивость к двум диспетчерам обеспечена в SQL, не в compose).
- `healthcheck:` добавлен для `worker-a`, `worker-b`, обоих dispatcher,
  обоих reconciler, `receipt-adapter`.

## Что осознанно не сделано / требует твоего решения
- Единая схема JSON-полей логов между C# (`AddJsonConsole`) и Python
  (`observability.py`) — сейчас это два разных, хоть и валидных, JSON-формата.
- `docs/*.md` не обновлял (assignment ссылается на файлы задания, не на
  файлы решения).
- Ни один из новых/изменённых файлов не прогонялся через `dotnet build`/
  `pytest`/`docker compose up` в этой сессии — только миграции проверены
  на реальном Postgres 16 напрямую.
