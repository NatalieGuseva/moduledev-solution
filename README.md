# Неделя 2. Персистентное workflow-ядро

Решение ModuleDev — Неделя 2: версионированные workflow maps, персистентное состояние в PostgreSQL, общий C# worker (`Workflow.Worker`), lease/fencing, ограниченный retry и восстановление после остановки worker. Продолжение задания недели 1 в этом же репозитории — action runtime не переписан, а используется воркером как есть.

---

## Решение

### Архитектура

Решение состоит из **шести** сервисов в Docker Compose:

- **gateway** (ASP.NET Core, YARP) — единственная точка входа снаружи, публикует host-порт `8080`. Проксирует запросы во внутренний `api` по Compose DNS (`http://api:8080`), не содержит предметной логики и не имеет доступа к PostgreSQL.
- **api** — внутренний action runtime без опубликованных host-портов. Выполняет проверку JWT, формирует доверенный context, валидирует request/response schema и вызывает `api.invoke(...)` в одной Npgsql transaction. Запускается только после того, как `cli` успешно применит миграции (`service_completed_successfully`).
- **cli** — Course CLI. При `docker compose up` по умолчанию выполняет `migration apply` и завершается. Для остальных команд (публикация/активация actions и workflow maps, запуск процессов, сигналы) запускается вручную через `docker compose run --rm cli ...`. Пишет в stdout ровно один JSON-документ (envelope `status: ok|error`), диагностика — в stderr.
- **postgres** — PostgreSQL 17, авторитетное состояние (схемы `course`, `api`, `workflow`, `autocheck`), данные хранятся в named volume `course_pgdata` и переживают пересоздание любого другого контейнера.
- **worker-a** и **worker-b** — два экземпляра одного и того же образа `Workflow.Worker`, с разными `COURSE_INSTANCE_ID` (владелец лизинга). Опрашивают очередь готовых заданий (`workflow.claim_jobs`), выполняют автоматические шаги через тот же shared `ActionExecutor`, что и `api`, и продвигают процесс через `workflow.finish_job`/`fail_job`.

Направление вызовов для HTTP-actions: клиент → `gateway:8080` → `api` → JWT + context → resolve action manifest → Npgsql transaction → `api.invoke(...)` → зарегистрированная PostgreSQL-функция → commit/rollback.

Направление вызовов для workflow: `cli flow start` → `workflow.start_process` → `workflow.enter_step` создаёт job → worker забирает его через `workflow.claim_jobs` → выполняет action через `ActionExecutor` → `workflow.finish_job` продвигает процесс на следующий шаг (или `workflow.fail_job` планирует retry/переводит в `DEAD`).

Диаграмма: [C4 Container diagram](docs/c4-container.md)

---

### Запуск

Требования: Docker Desktop с Compose v2, поддерживающим `service_completed_successfully`, `!override`, `!reset` и `config --no-env-resolution` (нужен достаточно свежий Docker Desktop — если `./check.sh` падает на `compose-contract` с exit-кодом 125, в первую очередь проверьте `docker compose version` и обновите Docker Desktop).

```bash
docker compose up -d --build
```

`cli` применяет миграции автоматически при каждом чистом запуске, `api` и оба worker'а стартуют только после их успешного завершения. Проверка доступности:

```bash
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready
```

**Перед повторным запуском/проверкой** (в том числе перед `./check.sh`) обязательно гасите предыдущий стек, чтобы не занимать порт `8080` и не тащить состояние прошлого запуска:

```bash
docker compose down -v
```

---

### Workflow-карты

Workflow map — исполняемый контракт процесса, а не документация: набор шагов (`automatic`/`wait_signal`/`manual`/`end`), объявленных `outcome` и переходов между ними по формату `contracts/course-1/workflow-map.schema.json`. Карта — конечный автомат: экземпляр процесса в любой момент находится ровно на одном шаге, переход возможен только по заранее объявленному результату.

Жизненный цикл управляется через `cli flow ...` (каждая команда — отдельный `docker compose run --rm cli flow ...`):

| Команда | Назначение |
|---|---|
| `flow validate <map.json\|map.yaml>` | Семантическая проверка карты без записи в БД: достижимость всех шагов, хотя бы один достижимый `end`, отсутствие циклов и тупиков, точное соответствие `required_policy` и outcome'ов зарегистрированному action |
| `flow publish <map.json\|map.yaml>` | Публикация версии карты. Идемпотентна: повторная публикация с тем же содержимым (в т.ч. тем же документом в другом формате) — не ошибка, с другим содержимым той же версии — `manifest.conflict` |
| `flow list` | Список опубликованных версий карт и их статус активности |
| `flow activate <flow> --version <v>` | Переключение активной версии; новые процессы стартуют по ней, уже идущие — по своей закреплённой (pinned) версии |
| `flow start <flow> --business-key <key> [--data <file>]` | Запуск процесса. Идемпотентен по паре (flow, business-key): повтор с теми же данными возвращает тот же процесс, с другими — конфликт |
| `flow get <process-id>` | Компактный статус процесса (шаг, состояние) |
| `flow signal <process-id> --type <type> --message-id <id> --payload <file>` | Внешний сигнал для шага `wait_signal`. Дедупликация по `message-id`; сигнал для ещё не наступившего `wait_signal` сохраняется и применяется атомарно при входе в него |

Формат карты (JSON или YAML) не завязан на расширение файла: `cli` сначала пробует разобрать содержимое как JSON, и только если это не JSON по синтаксису — как YAML (актуально в том числе для `/dev/stdin`, где расширения нет). В обоих случаях действует одна и та же строгая проверка схемы (неизвестные поля отклоняются), поэтому семантически одинаковая карта в JSON и в YAML — это один и тот же документ с точки зрения `flow publish`.

Версия карты фиксируется в момент старта процесса (`flowVersion` в `workflow.process_instance`) — публикация новой версии не затрагивает уже идущие процессы.

Отдельный HTTP-action `workflow.get` (module=`workflow`, action=`get`, policy `workflow:read`) отдаёт снимок процесса вместе с шагами, заданиями и попытками — тот же путь `Gateway → Api → api.invoke`, что и обычные actions недели 1.

---

### Worker

`Workflow.Worker` — общий C#-исполнитель automatic-шагов, запускается как `worker-a` и `worker-b` из одного образа с разными `COURSE_INSTANCE_ID`.

Цикл на каждой итерации:

1. `workflow.claim_jobs(owner, batchSize, leaseSeconds)` — короткая транзакция, `FOR UPDATE SKIP LOCKED`, гарантирует, что два worker'а не возьмут одно и то же задание.
2. Собирает payload для action по `input_mapping`/`input_constants` из данных процесса (JSON Pointer). Если источник в mapping отсутствует — не вызывает action вообще, сразу `workflow.fail_job` с non-retryable `workflow.mapping_missing`.
3. Вызывает **тот же** `Common.ActionExecution.ActionExecutor`, что использует `api` — с `trustedContext.principal = "workflow-worker"` и `RequestId = executionId` (идемпотентность на уровне action не завязана на HTTP `Idempotency-Key`).
4. При успехе — `workflow.finish_job` в той же транзакции, что и сам action, затем commit. При неуспехе — rollback транзакции action, затем `workflow.fail_job` уже в отдельной транзакции: не исчерпан бюджет попыток и ошибка retryable → `RETRY_WAIT` с задержкой из `delays_ms`; иначе → `DEAD`, шаг и процесс переводятся в `FAILED`, пишется событие `TaskFailed`.

Гарантии:

- **Lease/fencing** — `finish_job`/`fail_job` принимают запрос только при точном совпадении `job_id` + `owner` + `lease_version` + ожидаемого состояния `LEASED`. Просроченный, но ещё не переподхваченный лизинг не тратит бюджет попыток (попытка помечается `STALE`).
- **Один предметный эффект** — `executionId` job'а не меняется между попытками одного и того же задания и используется как ключ идемпотентности при вызове action.
- **Восстановление после recreate** — состояние процессов, заданий и история переходов живут в PostgreSQL, а не в памяти worker'а; после пересоздания контейнера worker продолжает разбирать очередь с нуля, не теряя прогресс уже идущих процессов.

`workflow_worker` — отдельная ограниченная роль PostgreSQL (`LOGIN`, пароль из `COURSE_WORKFLOW_WORKER_PASSWORD`) без единого прямого `GRANT` на таблицы: только `EXECUTE` на `workflow.claim_jobs`, `workflow.finish_job`, `workflow.fail_job` и `api.invoke`. `api`/`cli` продолжают подключаться отдельной (более широкой) учётной записью — это разные роли с разным набором прав.

**Test profile и failpoints** (`COURSE_TEST_PROFILE=1`, `COURSE_FAILPOINT=after_job_claim|after_action_before_finish`): при достижении заданной точки worker пишет одну строку `{"event":"failpoint.reached","name":"...","instanceId":"..."}` в stdout и блокируется до принудительной остановки — используется для проверки reclaim/stale-fencing сценариев. Для точечных fencing-проб без поднятия воркера доступна `cli flow test-finish <job-id> --owner <owner> --lease-version <v> --outcome <outcome> --result <file>` (только при `COURSE_TEST_PROFILE=1`, вызывает ту же production-границу `finish_job`, не отдельный бэкдор).

---

### Конфигурация

Переменные окружения (реальные значения не хранятся в репозитории, задаются через `.env` или Compose override):

| Переменная | Сервис | Назначение |
|---|---|---|
| `COURSE_JWT_ISSUER`, `COURSE_JWT_AUDIENCE`, `COURSE_JWT_SIGNING_KEY` | api | Проверка JWT |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | postgres | Параметры БД |
| `ConnectionStrings__CourseDb` | api, cli | Строка подключения к PostgreSQL (широкая учётная запись) |
| `COURSE_WORKFLOW_WORKER_PASSWORD` | cli, worker-a, worker-b | Пароль ограниченной роли `workflow_worker`; `cli` выставляет его через `ALTER ROLE` сразу после применения миграций |
| `COURSE_INSTANCE_ID` | worker-a, worker-b | Идентификатор владельца лизинга (`worker-a`/`worker-b`) |
| `COURSE_TEST_PROFILE` | worker-a, worker-b, cli | `1` включает укороченные lease/poll интервалы и `flow test-finish` |
| `COURSE_FAILPOINT` | worker-a, worker-b | `after_job_claim` \| `after_action_before_finish` — см. раздел «Worker» |
| `COURSE_LEASE_SECONDS`, `COURSE_POLL_INTERVAL_MS`, `COURSE_CLAIM_BATCH_SIZE` | worker-a, worker-b | Переопределение таймингов worker'а (по умолчанию зависят от `COURSE_TEST_PROFILE`) |

`.env` с реальными секретами не входит в Git.

---

### Миграции

SQL-миграции лежат в `Api/Migrations/ChecksummedMigrations/` и применяются сервисом `cli` в лексикографическом порядке, каждая — в отдельной транзакции, идемпотентно (по SHA-256 checksum в `course.migration_history`). Неделя 2 добавляет:

| Файл | Содержимое |
|---|---|
| `005_workflow_schema.sql` | Схема `workflow`: таблицы определения карты и рантайм-состояния, роль `workflow_worker` |
| `006_workflow_autocheck_views.sql` | Views `autocheck.flow_versions/processes/steps/jobs/attempts/signals/workflow_events` |
| `007_workflow_functions.sql` | `workflow.claim_jobs`, `finish_job`, `fail_job`, `enter_step`, `get_process` |
| `008_workflow_lifecycle.sql` | `workflow.start_process`, `workflow.receive_signal`, `apply_signal` |
| `009_insert_workflow_action.sql` | Регистрация HTTP-action `workflow.get` в `course.action_catalog` |

```bash
docker compose run --rm cli migration apply /app/Migrations/ChecksummedMigrations
```

---

### Проверка

```bash
docker compose down -v   # освободить порт 8080 и убрать состояние прошлого запуска
./check.sh
```

Результат пишется в `week-2-public-report.json`. Свои дополнительные проверки (при наличии) не заменяют `./check.sh`, а дополняют его.

---

### Диагностика

```bash
docker compose logs gateway
docker compose logs api
docker compose logs cli
docker compose logs worker-a
docker compose logs worker-b
docker compose logs postgres

curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready

docker compose exec postgres psql -U postgres -d course
```

Компактный статус процесса без прямых SQL-запросов:

```bash
docker compose run --rm cli flow get <process-id>
```

Полный снимок (процесс + шаги + задания + попытки) — через HTTP-action `workflow.get` (нужен JWT со scope `workflow:read`), либо напрямую в БД через views `autocheck.processes`/`autocheck.steps`/`autocheck.jobs`/`autocheck.attempts`/`autocheck.workflow_events`.

---

### Ограничения

- Docker Compose должен поддерживать `!override`, `!reset` и `config --no-env-resolution` — устаревшая версия падает на `compose-contract` в `./check.sh` с exit-кодом 125.
- Import BPMN XML, parallel gateways, timers, boundary events, compensation, subprocesses и произвольные expressions не реализованы — сознательно вне рамок недели 2.
- Завершение шага `manual` по HTTP не реализовано — вынесено в неделю 3.
- Ветвление `wait_signal` по содержимому сигнала не поддержано: ровно один объявленный переход на declared outcome шага.
- Количество попыток retry ограничено `task.max_attempts` из карты; `delays_ms` — фиксированный список задержек, не экспоненциальный backoff.
- На первой неделе `process_id` в `operations` мог быть `null` — с недели 2 worker заполняет его при вызове action из workflow, но записи, созданные до этой миграции, не мигрируются задним числом.
- Поддерживается только валюта `RUB` (унаследовано от `payment.request` недели 1).

ADR:
- [ADR 001: Trust boundary](docs/001-trust-boundary.md)
- [ADR 002: Технический и предметный результат](docs/002-technical-vs-domain-result.md)