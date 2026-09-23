# Неделя 3. Python-периметр

Решение ModuleDev — Неделя 3: durable-доставка Outbox во внешний provider через Python-dispatcher, приём provider callback через Python-adapter с переводом его в подписанный receipt v1, применение Inbox через Python-reconciler. Продолжение заданий недель 1–2 в этом же репозитории: C# gateway/API/worker и PostgreSQL-ядро workflow-движка не переписаны, Python не выбирает flow, лимит, переход или финальный статус — все решения остаются в PostgreSQL и C#.

```
Outbox -> Python dispatcher -> provider v0.2.0
provider legacy callback -> Python adapter -> generic C# API -> Inbox
Inbox -> Python reconciler -> workflow signal -> generic C# worker
```

---

## Решение

### Архитектура

**Направление вызовов (кто кого вызывает):**

```
gateway ──HTTP──▶ api ──api.invoke──▶ PostgreSQL (course.*, api.*)
worker-a/worker-b ──api.invoke──▶ PostgreSQL (workflow.*, payment.*)
outbox-dispatcher ──delivery.claim_outbox──▶ PostgreSQL
outbox-dispatcher ──HTTP POST /payments──▶ provider-simulator
provider-simulator ──HTTP legacy callback──▶ receipt-adapter
receipt-adapter ──HTTP POST /api/receipt/accept──▶ gateway ──▶ api ──▶ PostgreSQL
inbox-reconciler ──delivery.reconcile_inbox──▶ PostgreSQL
inbox-reconciler ──workflow.receive_signal──▶ PostgreSQL (workflow_signal)
```

`gateway` — единственная внешняя точка входа (host-порт). `api` и `worker-a`/`worker-b` — generic C# action runtime и workflow-worker, без host-портов. Python-сервисы не выбирают flow, лимит, переход или финальный статус — все решения принимает PostgreSQL через `api.invoke`, а Python только доставляет сообщения между PostgreSQL и внешним provider. `receipt-adapter` не имеет database credentials: путь до PostgreSQL идёт через `gateway → api → api.invoke`.

**Ответственность сервисов.** К шести сервисам недели 2 (`gateway`, `api`, `cli`, `postgres`, `worker-a`, `worker-b`) добавляются:

- **outbox-dispatcher** — Python 3.12+, читает `delivery.outbox` через `delivery.claim_outbox(...)`, вызывает provider `POST` с `Idempotency-Key = externalRequestId`, результат фиксирует через `delivery.succeed_outbox(...)`/`delivery.fail_outbox(...)`. Без host-портов, роль в PostgreSQL — `outbox_dispatcher`, без прямого DML по предметным таблицам.
- **receipt-adapter** — тот же Python-образ, другой entrypoint. Принимает provider legacy callback, собирает receipt v1 (compact JSON, sorted keys), считает `HMAC-SHA256` над точными UTF-8 байтами тела и вызывает `POST /api/receipt/accept` через `gateway` с JWT, `Idempotency-Key = messageId`, `X-Action-Version: 1` и `X-Provider-Signature: v1=<lowercase hex>`. Без database credentials — только HTTP наружу и внутрь периметра.
- **inbox-reconciler** — тот же Python-образ, третий entrypoint. Применяет `delivery.reconcile_inbox(...)` и подтверждённые receipts, инициируя `workflow signal` для generic C# worker. Роль в PostgreSQL — `inbox_reconciler`, тоже без прямого DML.
- **provider-simulator** — выданный образ `ghcr.io/fintech-dev-lab/internship-provider-simulator:v0.2.0`, закреплён по digest, наружу не публикуется.

Диаграмма: [C4 Container diagram](docs/c4-container.md) (обновлена: добавлены `outbox-dispatcher`, `receipt-adapter`, `inbox-reconciler`, `provider-simulator`).

---

### Запуск

**Prerequisites:** Docker Engine и Docker Compose v2 с поддержкой `!override`, `!reset`, `service_completed_successfully`, `config --no-env-resolution`. Локально собранный Python 3.12+ образ для `outbox-dispatcher`/`receipt-adapter`/`inbox-reconciler` — тот же Dockerfile, который собирает Compose, никаких отдельных шагов не требуется.

**Команда запуска:**

```bash
docker compose up -d --build
```

**Что делает `cli` при старте.** `cli` — one-shot сервис с entrypoint `Cli/entrypoint.sh`. Он применяет миграции (`migration apply /app/Migrations/ChecksummedMigrations`) и публикует/активирует обе payment-карты (`payment-processing` v1, `payment-review` v1), после чего успешно завершается (`exit 0`). Только после этого поднимаются `api`, `worker-a`, `worker-b`, `outbox-dispatcher`, `receipt-adapter`, `inbox-reconciler` — через `depends_on: cli: condition: service_completed_successfully`.

**Адрес и ожидаемый результат.**

`gateway` — единственный сервис, публикующий host-порт (по умолчанию `127.0.0.1:8080`). Python-сервисы и `provider-simulator` host-портов не публикуют.

```bash
curl -fsS http://localhost:8080/health/live    # → HTTP 200
curl -fsS http://localhost:8080/health/ready   # → HTTP 200
```

`ready = 200` означает, что `postgres`, `api`, `cli`, `gateway` готовы, а миграции и обе flow-карты применены. `gateway` доступен по адресу `http://localhost:8080`.

Перед повторным запуском/проверкой — как и раньше:

```bash
docker compose down -v
```

---

### Python-периметр

SQL-контракт, которым Python обязан пользоваться (никакого прямого DML по `delivery`/`payment`/`workflow` таблицам):

| Функция | Назначение |
|---|---|
| `delivery.claim_outbox(worker_id, batch_size)` | Забрать пачку готовых к отправке записей Outbox; один claim → одна HTTP-попытка |
| `delivery.succeed_outbox(id, provider_payment_id, attempt, response)` | Зафиксировать успешную доставку; не регрессирует уже `CONFIRMED` запись |
| `delivery.fail_outbox(id, error_code, attempt, response)` | Зафиксировать неуспешную попытку, PostgreSQL сам решает retry/next attempt |
| `delivery.reconcile_inbox(batch_size)` | Применить необработанные записи Inbox |

Retry сохраняет key/body/correlation между попытками — состояние и момент следующей попытки считает PostgreSQL, а не Python-процесс.

---

### Provider

Один локальный Python-образ, три entrypoint'а (`dispatcher`/`adapter`/`reconciler`, см. `docker-compose.yml`), контракт с provider v0.2.0 — по [external-contracts.md](docs/external-contracts.md) задания:

- Запрос dispatcher → provider: `{"operationId": "<externalRequestId>", "amount": "1000.00", "currency": "RUB"}`, `Idempotency-Key = externalRequestId`.
- Callback provider → adapter (legacy v0.2.0, без токена и без HMAC): `{"providerPaymentId", "operationId", "result", "message", "occurredAt"}`, приходит на `receipt-adapter:8080/callbacks/provider-v02/<PROVIDER_CALLBACK_CAPABILITY>`.
- Receipt v1, который adapter кладёт в тело `POST /api/receipt/accept` через `gateway`: `{"externalRequestId", "messageId", "occurredAt", "outcome", "providerPaymentId", "version": 1}`, сериализован compact JSON с sorted keys, подписан `HMAC-SHA256` над точными UTF-8 байтами тела, передаётся как `X-Provider-Signature: v1=<lowercase hex>` вместе с JWT, `Idempotency-Key = messageId` и `X-Action-Version: 1`.

Проверку подписи выполняет generic C# boundary (`ProviderSignatureMiddleware`) до входа в target action: он передаёт action'у только доверенные маркеры `transport.signatureVerified`/`transport.signatureVersion`, невалидная подпись до target не доходит. `provider-simulator` закреплён по digest (`ghcr.io/fintech-dev-lab/internship-provider-simulator:v0.2.0@sha256:...`), host-портов не публикует.

---

### Payment flows

`payment.submit` принимает только `operationId` и `Idempotency-Key`; привязка flow — server-side:

- `PAYMENT_EXECUTION` → `payment-processing`
- `PAYMENT_APPROVAL` → `payment-review`

```
payment-processing:
  validate -> prepare_external -> wait_receipt -> apply_receipt
    -> COMPLETED: complete -> end
    -> REJECTED: reject -> end

payment-review:
  validate -> check_limit
    -> WITHIN_LIMIT: approve -> end
    -> REVIEW_REQUIRED: manual
         -> APPROVED: approve -> end
         -> REJECTED: reject -> end
```

Правило `course-limit-v1`: суммы до `100000.00 RUB` включительно — auto approve (`WITHIN_LIMIT`), выше — `REVIEW_REQUIRED` (шаг `manual`, реализованный ещё на неделе 2 как `wait_signal`/`manual`, на неделе 3 закрывается HTTP-завершением через `workflow.manual`).

`workflow.manual` принимает `process`/`step`, `decision` и `reason`; idempotency-key берётся из HTTP-заголовка, principal — из доверенного context; decision, событие и следующий job фиксируются атомарно.

---

### Обязательные actions

`payment.submit`, `operation.events`, `payment.validate`, `payment.prepare_external`, `payment.apply_receipt`, `payment.complete`, `payment.reject`, `payment.check_limit`, `payment.approve`, `receipt.accept`, `workflow.manual`.

---

### Миграции

**Когда и каким сервисом применяются.** Миграции применяет **только** сервис `cli` (entrypoint `Cli/entrypoint.sh`) при каждом `docker compose up -d --build`. Применение идемпотентно: уже применённые файлы (с совпадающим SHA-256 checksum в `course.migration_history`) пропускаются. Другие сервисы миграции не применяют — `api`, `worker-a`, `worker-b`, Python-сервисы зависят от `cli` через `depends_on: cli: condition: service_completed_successfully`.

Порядок применения — лексикографический по имени файла в `Api/Migrations/ChecksummedMigrations/`; каждая миграция выполняется в **своей транзакции**. Файлы продолжают нумерацию недель 1–2, неделя 3 добавляет:

| Файл | Содержимое |
|---|---|
| `010_delivery_schema.sql` | Схема `delivery`: Outbox/Inbox таблицы, роли `outbox_dispatcher`/`inbox_reconciler` |
| `011_delivery_functions.sql` | `delivery.claim_outbox`, `succeed_outbox`, `fail_outbox`, `reconcile_inbox` |
| `012_payment_domain.sql` | Предметная схема `payment`: операции, decision, лимиты |
| `013_insert_payment_actions.sql` | Регистрация обязательных `payment.*`/`receipt.accept`/`workflow.manual` actions в `course.action_catalog` |
| `014_publisher_grants.sql` | Права публикации/активации новых payment-карт для роли `course_publisher` |
| `015_autocheck_receipts_decisions.sql` | Views `autocheck.receipts` (из `delivery.inbox`) и `autocheck.decisions` (из `payment.decision`) |
| `016_revoke_execute_public_v2.sql` | Отзыв `EXECUTE FROM PUBLIC` по схемам `course`/`delivery`/`workflow`/`api`/`opencheck`/`public` (включая `pgcrypto`) с точечным re-grant только нужных `delivery`-функций ролям `outbox_dispatcher`/`inbox_reconciler` |

Пароли ролей `outbox_dispatcher`/`inbox_reconciler` не хардкодятся в миграции — выставляются в `postgres-init/00-bootstrap-roles.sh` (по аналогии с `course_migrator`/`course_publisher`), чтобы совпадать с синтетическими `COURSE_OUTBOX_PASSWORD`/`COURSE_INBOX_PASSWORD` checker'а и не светиться нигде, кроме `postgres` и соответствующего Python-сервиса.

Ручной запуск (если нужно применить миграции без `up`):

```bash
docker compose run --rm cli migration apply /app/Migrations/ChecksummedMigrations
```

---

### Конфигурация

Переменные окружения (реальные значения не хранятся в репозитории, задаются через `.env` или Compose override):

| Переменная | Сервис | Назначение |
|---|---|---|
| `COURSE_GATEWAY_PORT` | gateway | Host-порт, единственный публикуемый наружу (`127.0.0.1:<port>:8080`) |
| `COURSE_JWT_ISSUER`, `COURSE_JWT_AUDIENCE`, `COURSE_JWT_SIGNING_KEY` | api, cli | Проверка/выпуск JWT |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | postgres | Параметры БД |
| `COURSE_POSTGRES_PASSWORD` | postgres | Пароль роли `postgres` |
| `COURSE_MIGRATOR_PASSWORD` | postgres, cli | Пароль роли `course_migrator` |
| `COURSE_PUBLISHER_PASSWORD` | postgres | Пароль роли `course_publisher` |
| `COURSE_RUNTIME_PASSWORD` | postgres, api | Пароль least-privilege роли `course_runtime`, под которой ходит `api` |
| `COURSE_WORKER_PASSWORD` | postgres, worker-a, worker-b | Пароль роли `workflow_worker` |
| `COURSE_WORKFLOW_WORKER_PASSWORD` | cli | Alias того же пароля `workflow_worker`, который читает `Cli/Program.cs` при bootstrap роли |
| `COURSE_OUTBOX_PASSWORD` / `COURSE_OUTBOX_USER` | postgres, outbox-dispatcher | Логин/пароль least-privilege роли `outbox_dispatcher` (используются и как `PGUSER`/`PGPASSWORD`) |
| `COURSE_INBOX_PASSWORD` / `COURSE_INBOX_USER` | postgres, inbox-reconciler | Логин/пароль least-privilege роли `inbox_reconciler` |
| `PROVIDER_URL` | outbox-dispatcher | Адрес provider-simulator (по умолчанию `http://provider-simulator:8081`) |
| `OUTBOX_OWNER` | outbox-dispatcher | Владелец лизинга в `delivery.claim_outbox` |
| `PROVIDER_CALLBACK_CAPABILITY` | receipt-adapter, provider-simulator | Сегмент callback-URL provider'а |
| `PROVIDER_CALLBACK_TOKEN` | receipt-adapter | Bearer-токен, которым adapter ходит в gateway — **не** передаётся в provider-simulator |
| `PROVIDER_HMAC_SECRET` | receipt-adapter, api | Общий секрет для `X-Provider-Signature: v1=<hmac>` |
| `RECEIPT_API_URL` | receipt-adapter | URL `POST /api/receipt/accept` через gateway |
| `RECEIPT_ADAPTER_PORT` | receipt-adapter | Порт, который слушает adapter (`8080`) |
| `PROVIDER_AUDIT_TOKEN` | provider-simulator | Технический токен аудита checker'а |
| `COURSE_TEST_PROFILE` | все сервисы | Укороченные интервалы/тестовый профиль |

`.env` с реальными секретами не входит в Git.

---

### Проверка

Репозиторий задания (checker) и репозиторий решения — разные репозитории; `check.sh` предыдущих недель не перезаписывается и не копируется поверх.

Требуются Python 3.11+ для самого checker'а, Docker Engine и Docker Compose v2 с поддержкой `!override`, `!reset` и `config --no-env-resolution`.

```bash
git clone https://github.com/fintech-dev-lab/moduledev-week-3-python-perimeter-task.git
./moduledev-week-3-python-perimeter-task/check.sh --repo /path/to/moduledev-solution
```

Путь после `--repo` может быть абсолютным или относительным — checker сам находит Compose-файл в корне указанного решения и туда же пишет `week-3-public-report.json` (без баллов и секретов).

**Compose seam, который проверяется:** ровно эти 10 service names должны существовать и подниматься по `docker compose up -d --build` без ручного вмешательства —

```text
gateway api cli postgres worker-a worker-b
outbox-dispatcher receipt-adapter inbox-reconciler provider-simulator
```

`cli` реализован как one-shot через `Cli/entrypoint.sh` — успешно завершается после миграций и публикации карт. Единственный сервис с host-портом — `gateway`; сначала checker валидирует tracked-контракт с `COURSE_GATEWAY_PORT=8080`, затем поднимает изолированный override со случайным loopback host-портом и тем же `8080` внутри контейнера. Python-сервисы и `provider-simulator` host-портов не публикуют; `receipt-adapter` не получает PostgreSQL-настроек; `outbox-dispatcher`/`inbox-reconciler` используют разные least-privilege роли.

Все переменные из таблицы «Конфигурация» checker подставляет своими synthetic-значениями в изолированном окружении — tracked `docker-compose.yml` должен на них только ссылаться и не требовать `.env` для подъёма. Для паролей PostgreSQL допустим локальный dev-плейсхолдер по умолчанию — checker всё равно подставит собственное значение.

Что именно делает checker:

- Compose admission и cold build;
- поднимает отдельный project с synthetic secrets;
- проверяет границы образов C#/Python/provider;
- останавливает и заново поднимает dispatcher (durable Outbox не теряется);
- прогоняет provider success, duplicate/conflict callback и обе review-ветки (`WITHIN_LIMIT`/`REVIEW_REQUIRED`);
- проверяет stable views `autocheck.*` и least-privilege роли (`week3-stable-views`, `python-roles-no-table-privileges`, `python-fixed-function-privileges`);
- пересоздаёт Python-сервисы и убеждается, что состояние определяется PostgreSQL, а не памятью процесса;
- пишет `week-3-public-report.json`;
- удаляет project, volumes и локальные images, если не передан `--keep-stack`.

Коды завершения: `0` — все public checks пройдены, `1` — нарушен контракт решения, `2` — checker или окружение не готовы.

```bash
docker compose down -v   # освободить порт и убрать состояние прошлого запуска перед прогоном checker'а
```

Текущее состояние решения — `week-3-public-report.json`: `status: passed`, `failedChecks: []`.

---

### Собственные тесты

Python-периметр покрыт `pytest` (без Docker, юнит- и интеграционные тесты в `python/tests/`):

- `test_hmac.py` — корректность HMAC-подписи над compact JSON с sorted keys;
- `test_adapter.py` — перевод legacy callback в receipt v1, отклонение wrong capability/invalid JSON/large body/CRLF/unknown fields;
- `test_dispatcher.py` — claim/succeed/fail цикл outbox-dispatcher, классификация ответов provider (retryable/terminal), сохранение idempotency key между retry;
- `test_integration.py` — сквозной прогон периметра (dispatcher → adapter → receipt v1 → HMAC → duplicate/conflict сценарии).

Один раз поставить зависимости в venv:

```bash
cd ~/projects/week
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Запуск тестов:

```bash
source .venv/bin/activate
python -m pytest python/tests -v
```

Если venv не активирован и системный `python3` не находит `pytest`, используйте интерпретатор из venv напрямую:

```bash
~/projects/week/.venv/bin/python -m pytest python/tests -v
```

Полезные варианты:

```bash
python -m pytest python/tests            # краткий вывод
python -m pytest python/tests -v -s      # с stdout/stderr
python -m pytest python/tests -v -x      # остановиться на первом падении
python -m pytest python/tests/test_hmac.py -v
```

C#-тесты (`Cli.Tests`, `Api.Tests`) — без изменений в контракте команды запуска, см. [TESTS.md](TESTS.md).

---

### Диагностика

**Логи сервисов:**

```bash
docker compose logs outbox-dispatcher
docker compose logs receipt-adapter
docker compose logs inbox-reconciler
docker compose logs api
docker compose logs worker-a
docker compose logs worker-b
docker compose logs gateway
docker compose logs cli
```

**Health (`gateway`):**

```bash
curl -fsS http://localhost:8080/health/live
curl -fsS http://localhost:8080/health/ready
```

**OpenAPI (generic action runtime):**

```bash
curl -fsS http://localhost:8080/openapi/default.json | head
curl -fsS http://localhost:8080/openapi/actions/payment/request/1.json | head
```

**PostgreSQL (read-only autocheck views + диагностика):**

```bash
docker compose exec postgres psql -U postgres -d course
# примеры:
docker compose exec postgres psql -U postgres -d course -c \
  "SELECT * FROM autocheck.receipts ORDER BY received_at DESC LIMIT 5;"
docker compose exec postgres psql -U postgres -d course -c \
  "SELECT * FROM autocheck.decisions ORDER BY created_at DESC LIMIT 5;"
docker compose exec postgres psql -U postgres -d course -c \
  "SELECT * FROM autocheck.outbox ORDER BY created_at DESC LIMIT 5;"
```

**CLI (one-shot, `exec` не работает — только `run --rm`):**

```bash
docker compose run --rm -T --no-deps cli action list
docker compose run --rm -T --no-deps cli action publish /app/<manifest>.json
docker compose run --rm -T --no-deps cli flow list
docker compose run --rm -T --no-deps cli migration apply /app/Migrations/ChecksummedMigrations
```

Автосводки по периметру — через read-only views `autocheck.receipts`/`autocheck.decisions` (см. «Миграции») в дополнение к `autocheck.processes`/`autocheck.steps`/`autocheck.jobs`/`autocheck.attempts` недели 2.

---

### История замечаний

Статусы по калибровке `late-week-quality.2` (`fixed` / `remaining` / `regression` / `not_applicable` / `unverified`) — сопоставление старого и нового результата, а не предположение:

| Замечание | Неделя | Что было | Что сделано | Статус |
|---|---|---|---|---|
| Широкие суперпользовательские DB-подключения вместо раздельных identity | 1 | `api`/`cli` ходили в БД одной учёткой | Введены роли `course_owner`/`course_migrator`/`course_publisher`/`course_runtime`, разнесены connection strings | `fixed` |
| Отсутствие проверки типов `iat`/`scope` в JWT | 1 | JWT принимался без строгой проверки этих полей | Добавлены type-проверки `iat`/`scope` | `fixed` |
| Неполная валидация manifest/OpenAPI | 1 | Manifest не проверялся по схеме | JsonSchema.Net Draft 2020-12 валидация в CLI | `fixed` |
| Отсутствие DB-инвариантов/append-only | 1 | Не было ограничений на уровне БД | Добавлены invariants и canary-таблица | `fixed` |
| `job.attempt_count` не обновлялся при реклейме | 2 | `two-worker-reclaim-and-stale-finish`, `action-finish-rollback-and-recovery` | Миграция 011 (`workflow_job.failure_count` отдельно от `attempt_count`, `UNIQUE(job_id, attempt_number)`) | `fixed` |
| Все проверки Python-периметра | 3 | — | — | `fixed` — `week-3-public-report.json`: `status: passed`, `failedChecks: []` |
| Некорректные пароли ролей `outbox_dispatcher`/`inbox_reconciler` | 3 | Миграция `010_delivery_schema.sql` задавала пароли напрямую | Пароли перенесены в `postgres-init/00-bootstrap-roles.sh` | `fixed` |
| `EXECUTE FROM PUBLIC` давал лишний доступ Python-ролям | 3 | Функции `workflow`/`delivery`/`public` (включая `pgcrypto`) и `course.auto_enable_first_version` были доступны всем ролям | Миграция 016 отзывает `EXECUTE FROM PUBLIC` по всем схемам, точечно re-grant только нужных `delivery`-функций | `fixed` |
| `api` под широкой учётной записью вместо `course_runtime` | 3 | `api` использовал `POSTGRES_USER`/`COURSE_POSTGRES_PASSWORD` | `api` переведён на `Username=course_runtime;Password=${COURSE_RUNTIME_PASSWORD}`; `worker-a/b` — на `COURSE_WORKER_PASSWORD` | `fixed` |

---

### Ограничения

- Поддерживается только валюта `RUB` (унаследовано с недели 1).
- Python-сервисы не имеют host-портов и не публикуются наружу напрямую — единственная точка входа снаружи по-прежнему `gateway`.
- `receipt-adapter` не имеет database credentials — весь путь до PostgreSQL идёт через `gateway → api → api.invoke`.
- Пересоздание Python-сервисов не должно терять состояние — источник истины остаётся в PostgreSQL (Outbox/Inbox/receipts/decisions), сами процессы Python — stateless.
- Provider-simulator подключается по digest, а не по тегу — обновление образа требует явного изменения digest в compose-файле.

ADR и разборы:
- [ADR 001: Trust boundary](docs/001-trust-boundary.md)
- [ADR 002: Технический и предметный результат](docs/002-technical-vs-domain-result.md)
- [ADR 003: Lease, fencing и at-least-once](docs/003-lease-fencing-at-least-once.md)