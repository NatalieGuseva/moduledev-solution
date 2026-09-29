# Неделя 4. Надёжность, восстановление и доказательство результата

Решение ModuleDev — Неделя 4: конкурентная доставка Outbox двумя dispatcher,
конкурентное применение Inbox двумя reconciler, retry с backoff и dead-letter policy,
recovery просроченных job и delivery, failpoints, health/OpenMetrics,
`diagnostics.trace` и `diagnostics.stalled`, структурные JSON-логи.

Продолжение недель 1–3 в том же репозитории: C# gateway/API/worker и PostgreSQL-ядро
workflow-движка не переписаны, Python по-прежнему не выбирает flow, лимит, переход
или финальный статус — все решения остаются в PostgreSQL и C#.


command → gateway → api → PostgreSQL (operation + Outbox, одна транзакция)
                              │
              outbox-dispatcher ×2 ──HTTP──▶ provider-simulator v0.2.0
                              ▲                        │ callback
PostgreSQL ◀── api ◀── gateway ◀── receipt-adapter ◀───┘
    │ Inbox
    └─▶ inbox-reconciler ×2 ─▶ workflow signal ─▶ worker-a / worker-b

---

## Решение

### Архитектура

**Направление вызовов (кто кого вызывает):**

gateway ──HTTP──▶ api ──api.invoke──▶ PostgreSQL (course.*, api.*, payment.*)*
*worker-a/worker-b ──api.invoke──▶ PostgreSQL (workflow.*, payment.\*)
outbox-dispatcher / outbox-dispatcher-b
──delivery.claim_outbox──▶ PostgreSQL
──HTTP POST /payments──▶ provider-simulator
provider-simulator ──HTTP legacy callback──▶ receipt-adapter
receipt-adapter ──HTTP POST /api/receipt/accept──▶ gateway ──▶ api ──▶ PostgreSQL
inbox-reconciler / inbox-reconciler-b
──delivery.reconcile_inbox──▶ PostgreSQL
──workflow\.receive_signal──▶ PostgreSQL (workflow_signal)


```
`gateway` — единственная внешняя точка входа (host-порт). `api` и `worker-a`/`worker-b` —
generic C# action runtime и workflow-worker, без host-портов. Python-сервисы не выбирают
flow, лимит, переход или финальный статус — все решения принимает PostgreSQL через
`api.invoke`. `receipt-adapter` не имеет database credentials: путь до PostgreSQL идёт
через `gateway → api → api.invoke`.

**Ответственность сервисов.** К сервисам недель 1–3 (`gateway`, `api`, `cli`, `postgres`,
`worker-a`, `worker-b`, `outbox-dispatcher`, `receipt-adapter`, `inbox-reconciler`,
`provider-simulator`) добавляются:

- **outbox-dispatcher-b** — второй экземпляр того же локально собранного Python-образа,
  owner `outbox-dispatcher-b`. Один и тот же SQL boundary `delivery.claim_outbox`,
  разные owner'ы. Без host-портов.
- **inbox-reconciler-b** — второй экземпляр reconciler'а, та же least-privilege роль
  `inbox_reconciler`. Без host-портов.

Неделя 4 не создаёт новых сервисов, кроме этих двух: те же image, те же роли, те же
SQL-функции. Идемпотентность обеспечивается `externalRequestId` и provider v0.2.0.

**Неделя 4: два worker с fencing.** `worker-a` и `worker-b` используют одну роль
`workflow_worker` и одну функцию `workflow.claim_jobs`. Просроченный lease
реклеймится, stale completion возвращает `workflow.lease_stale`, `jobId`/`executionId`
сохраняются, `attemptId` — новый.

Диаграмма: [C4 Container diagram](docs/c4-container.md) (обновлена: добавлены вторые экземпляры).

---

### Запуск

**Prerequisites:** Docker Engine и Docker Compose v2 с поддержкой `!override`, `!reset`,
`service_completed_successfully`, `config --no-env-resolution`. Локально собранный Python 3.12+
образ для `outbox-dispatcher(-b)`/`receipt-adapter`/`inbox-reconciler(-b)` — тот же Dockerfile,
который собирает Compose.

**Команда запуска:**

```bash
cp .env.example .env      # заполнить значения
docker compose up -d --build
docker compose ps         # все сервисы healthy; cli — Exited (0)
```


**Что делает **`cli`** при старте.** `cli` — one-shot сервис с entrypoint `Cli/entrypoint.sh`.
Он применяет миграции (`migration apply /app/Migrations/ChecksummedMigrations`) и
публикует/активирует обе payment-карты (`payment-processing` v1, `payment-review` v1),
после чего успешно завершается (`exit 0`). Только после этого поднимаются `api`,
`worker-a`, `worker-b`, `outbox-dispatcher(-b)`, `receipt-adapter`,
`inbox-reconciler(-b)` — через `depends_on: cli: condition: service_completed_successfully`.

**Адрес и ожидаемый результат.**

`gateway` — единственный сервис, публикующий host-порт (по умолчанию `127.0.0.1:8080`).
Python-сервисы и `provider-simulator` host-портов не публикуют.


```
curl -fsS http://localhost:8080/health/live    # → HTTP 200 {"status":"live"}
curl -fsS http://localhost:8080/health/ready   # → HTTP 200 {"status":"ready"}
curl -fsS http://localhost:8080/metrics        # → OpenMetrics
```


`ready = 200` означает, что `postgres`, `api`, `cli`, `gateway` готовы, а миграции
и обе flow-карты применены. Недоступность provider **не** делает API/worker/dispatcher
`not ready` — копящийся Outbox это штатный режим.

Перед повторным запуском/проверкой:


```
docker compose down -v
```


---

### Python-периметр

SQL-контракт, которым Python обязан пользоваться (никакого прямого DML по
`delivery`/`payment`/`workflow` таблицам):

| **Функция**                                                           | **Назначение**                                                                  |
| :-------------------------------------------------------------------- | :------------------------------------------------------------------------------ |
| `delivery.claim_outbox(worker_id, batch_size)`                        | Забрать пачку готовых к отправке записей Outbox; один claim → одна HTTP-попытка |
| `delivery.succeed_outbox(id, provider_payment_id, attempt, response)` | Зафиксировать успешную доставку; не регрессирует уже `CONFIRMED` запись         |
| `delivery.fail_outbox(id, error_code, attempt, response)`             | Зафиксировать неуспешную попытку, PostgreSQL сам решает retry/next attempt      |
| `delivery.reconcile_inbox(batch_size)`                                | Применить необработанные записи Inbox                                           |

Retry сохраняет key/body/correlation между попытками — состояние и момент следующей
попытки считает PostgreSQL, а не Python-процесс.

---

### Provider

Один локальный Python-образ, пять entrypoints (`dispatcher`/`adapter`/`reconciler`),
контракт с provider v0.2.0:

- Запрос dispatcher → provider: `{"operationId": "<externalRequestId>", "amount": "1000.00", "currency": "RUB"}`, `Idempotency-Key = externalRequestId`.
- Callback provider → adapter (legacy v0.2.0, без токена и без HMAC): `{"providerPaymentId", "operationId", "result", "message", "occurredAt"}`, приходит на `receipt-adapter:8082/callbacks/provider-v02/<PROVIDER_CALLBACK_CAPABILITY>`.
- Receipt v1, который adapter кладёт в тело `POST /api/receipt/accept` через `gateway`:
  `{"externalRequestId", "messageId", "occurredAt", "outcome", "providerPaymentId", "version": 1}`,
  сериализован compact JSON с sorted keys, подписан `HMAC-SHA256` над точными UTF-8 байтами тела,
  передаётся как `X-Provider-Signature: v1=<lowercase hex>` вместе с JWT,
  `Idempotency-Key = messageId` и `X-Action-Version: 1`.

Проверку подписи выполняет generic C# boundary (`ProviderSignatureMiddleware`) до входа
в target action. `provider-simulator` закреплён по digest
(`ghcr.io/fintech-dev-lab/internship-provider-simulator:v0.2.0@sha256:...`), host-портов
не публикует.

---

### Payment flows

`payment.submit` принимает только `operationId` и `Idempotency-Key`; привязка flow — server-side:

- `PAYMENT_EXECUTION` → `payment-processing`
- `PAYMENT_APPROVAL` → `payment-review`


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


Правило `course-limit-v1`: суммы до `100000.00 RUB` включительно — auto approve
(`WITHIN_LIMIT`), выше — `REVIEW_REQUIRED` (шаг `manual`, закрывается HTTP-завершением
через `workflow.manual`).

`workflow.manual` принимает `process`/`step`, `decision` и `reason`; idempotency-key
берётся из HTTP-заголовка, principal — из доверенного context; decision, событие
и следующий job фиксируются атомарно.

---

### Обязательные actions

`payment.submit`, `operation.events`, `payment.validate`, `payment.prepare_external`,
`payment.apply_receipt`, `payment.complete`, `payment.reject`, `payment.check_limit`,
`payment.approve`, `receipt.accept`, `workflow.manual`,
`diagnostics.trace`, `diagnostics.stalled`.

---

### Миграции

**Когда и каким сервисом применяются.** Миграции применяет **только** сервис `cli`
(entrypoint `Cli/entrypoint.sh`) при каждом `docker compose up -d --build`. Применение
идемпотентно: уже применённые файлы (с совпадающим SHA-256 checksum в `course.migration_history`)
пропускаются.

Порядок применения — лексикографический по имени файла в `Api/Migrations/ChecksummedMigrations/`;
каждая миграция выполняется в **своей транзакции**. Недели 1–3 добавляют:

| **Файл**                                             | **Содержимое**                                                                      |
| :--------------------------------------------------- | :---------------------------------------------------------------------------------- |
| `001_initial.sql` … `009_insert_workflow_action.sql` | Недели 1–2: схемы, функции, actions, workflow                                       |
| `010_delivery_schema.sql`                            | Схема `delivery`: Outbox/Inbox таблицы, роли `outbox_dispatcher`/`inbox_reconciler` |
| `011_delivery_functions.sql`                         | `delivery.claim_outbox`, `succeed_outbox`, `fail_outbox`, `reconcile_inbox`         |
| `012_payment_domain.sql`                             | Предметная схема `payment`: операции, decision, лимиты                              |
| `013_insert_payment_actions.sql`                     | Регистрация обязательных `payment.*`/`receipt.accept`/`workflow.manual` actions     |
| `014_publisher_grants.sql`                           | Права публикации/активации новых payment-карт для `course_publisher`                |
| `015_autocheck_receipts_decisions.sql`               | Views `autocheck.receipts` и `autocheck.decisions`                                  |
| `016_revoke_execute_public_v2.sql`                   | Отзыв `EXECUTE FROM PUBLIC` с точечным re-grant                                     |

Неделя 4 добавляет:

| **Файл**                              | **Содержимое**                                                                                    |
| :------------------------------------ | :------------------------------------------------------------------------------------------------ |
| `017_reliability_and_diagnostics.sql` | `diagnostics.trace` и `diagnostics.stalled`, append-only гарантии, delivery/job lease constraints |
| `018_insert_diagnostics_actions.sql`  | Регистрация `diagnostics.trace` и `diagnostics.stalled` в `course.action_catalog`                 |
| `019_grant_autocheck_reader.sql`      | `GRANT SELECT` на views `autocheck.*` роли `autocheck_reader`                                     |
| `020_fix_outbox_view.sql`             | Исправление `autocheck.outbox` — `dead_at` как `timestamp with time zone`                         |
| `021_outbox_policy_from_session_settings.sql` | Lease и retry-политика Outbox читаются из session settings (`course.outbox_lease_ms`, `course.outbox_max_attempts`, `course.outbox_backoff_base_ms`, `course.outbox_backoff_max_ms`, `course.outbox_jitter_max_ms`); сигнатуры `delivery.claim_outbox` / `delivery.fail_outbox` не меняются |

Ручной запуск:


```
docker compose run --rm cli migration apply /app/Migrations/ChecksummedMigrations
```

---

### Конфигурация

Переменные окружения (реальные значения не хранятся в репозитории; шаблон — `.env.example`):

| **Переменная**                                                       | **Сервис**                      | **Назначение**                                  |
| :------------------------------------------------------------------- | :------------------------------ | :---------------------------------------------- |
| `COURSE_GATEWAY_PORT`                                                | gateway                         | Host-порт, единственный публикуемый наружу      |
| `COURSE_JWT_ISSUER`, `COURSE_JWT_AUDIENCE`, `COURSE_JWT_SIGNING_KEY` | api, cli, gateway, worker       | Проверка/выпуск JWT                             |
| `POSTGRES_USER`, `POSTGRES_DB`                                       | postgres                        | Параметры БД                                    |
| `COURSE_POSTGRES_PASSWORD`                                           | postgres                        | Пароль роли `postgres`                          |
| `COURSE_MIGRATOR_PASSWORD`                                           | postgres, cli                   | Пароль роли `course_migrator`                   |
| `COURSE_PUBLISHER_PASSWORD`                                          | postgres, cli                   | Пароль роли `course_publisher`                  |
| `COURSE_RUNTIME_PASSWORD`                                            | postgres, api                   | Пароль least-privilege роли `course_runtime`    |
| `COURSE_WORKER_PASSWORD`                                             | postgres, worker-a, worker-b    | Пароль роли `workflow_worker`                   |
| `COURSE_WORKFLOW_WORKER_PASSWORD`                                    | cli                             | Alias того же пароля `workflow_worker`          |
| `COURSE_OUTBOX_PASSWORD`                                             | postgres, outbox-dispatcher(-b) | Пароль least-privilege роли `outbox_dispatcher` |
| `COURSE_INBOX_PASSWORD`                                              | postgres, inbox-reconciler(-b)  | Пароль least-privilege роли `inbox_reconciler`  |
| `COURSE_AUTOCHECK_PASSWORD`                                          | postgres                        | Пароль read-only роли `autocheck_reader`        |
| `PROVIDER_URL`                                                       | оба dispatcher                  | Адрес provider-simulator                        |
| `OUTBOX_OWNER` / `OUTBOX_OWNER_B`                                    | оба dispatcher                  | Владельцы lease (разные)                        |
| `PROVIDER_CALLBACK_CAPABILITY`                                       | adapter, provider               | Сегмент callback-URL                            |
| `PROVIDER_CALLBACK_TOKEN`                                            | adapter                         | Bearer-токен adapter'а                          |
| `PROVIDER_HMAC_SECRET`                                               | adapter, api                    | Общий секрет для `X-Provider-Signature`         |
| `RECEIPT_API_URL`                                                    | adapter                         | URL `POST /api/receipt/accept`                  |
| `PROVIDER_AUDIT_TOKEN`                                               | provider                        | Технический токен аудита checker'а              |
| `COURSE_TEST_PROFILE`                                                | все                             | `1` — failpoints и короткие интервалы           |
| `COURSE_FAILPOINT`                                                   | проверяемый процесс             | Имя одного failpoint (пусто = выключен)         |
| `COURSE_PROVIDER_TIMEOUT_MS`                                         | оба dispatcher                  | Timeout запроса к provider (500)                |
| `COURSE_OUTBOX_MAX_ATTEMPTS`                                         | postgres, dispatcher            | Попытки, включая первую (4)                     |
| `COURSE_OUTBOX_BACKOFF_BASE_MS` / `_MAX_MS`                          | postgres                        | 200 → 400 → 800 мс                              |
| `COURSE_OUTBOX_JITTER_MAX_MS`                                        | postgres                        | Jitter 0…N мс (100)                             |
| `COURSE_OUTBOX_LEASE_MS`                                             | postgres, dispatcher            | Lease строки Outbox (2000)                      |
| `COURSE_OUTBOX_POLL_MS` / `COURSE_INBOX_POLL_MS`                     | dispatcher / reconciler         | 100 / 500                                       |
| `COURSE_JOB_LEASE_MS` / `COURSE_WORKER_POLL_MS`                      | postgres, worker                | 2000 / 100                                      |

`.env` с реальными секретами не входит в Git. Шаблон `.env.example` содержит заглушки
`REPLACE_WITH_*`.

Внутренние порты (публикуется только gateway): `api`, `worker-a/b`, `outbox-dispatcher(-b)`,
`inbox-reconciler(-b)` — `8080`; `receipt-adapter` — `8082`.

---
### Перед публичной проверкой

Checker запускает **свой изолированный Compose project** со случайным именем
(`week4-public-XXXX`), своим volume, своей сетью и своими контейнерами. Он не
использует ни один из твоих существующих ресурсов, но **Docker daemon у вас общий**.
Если в системе остаётся много мусора или работает второй стек, `up` внутри
checker'а может упасть с `candidate stack did not start`, даже если само решение
корректно.

Перед запуском `check.sh` обязательно:

1. **Останови локальный стек и удали его volume:**

   ```bash
   cd ~/projects/week
   docker compose down -v --remove-orphans
   ```

2. **Удали отладочные контейнеры, сети и volumes от ручных тестов:**

   ```bash
   docker ps -a --filter "name=week4-debug" -q | xargs -r docker rm -f
   docker network ls --filter "name=week4-debug" -q | xargs -r docker network rm
   docker volume ls --filter "name=week4-debug" -q | xargs -r docker volume rm
   ```

3. **Убедись, что Docker daemon не забит build cache.** В нашем случае именно
   разросшийся до ~10 GB build cache приводил к падению `up` внутри checker'а.
   Минимальная очистка:

   ```bash
   docker container prune -f
   docker builder prune -f
   docker system df
   ```

   Если `Build Cache` показывает больше 5 GB, а `Reclaimable` — больше 3 GB,
   снимай весь кэш:

   ```bash
   docker builder prune -a -f
   ```

   Это не сломает решение: следующий `docker compose build` просто соберёт
   образы заново.

4. **Проверь, что никакие `week-*` и `week4-*` контейнеры не работают:**

   ```bash
   docker ps -a
   ```

   В списке не должно быть контейнеров с именами `week-…`, `week4-public-…`
   или `week4-debug-…`.

5. **Проверь свободный порт 8080 на loopback** (checker выбирает случайный
   loopback-порт, но конфликтов быть не должно):

   ```bash
   ss -ltnp | grep -E ':8080|:18080' || true
   ```

На слабых машинах (4 GB RAM, 2 CPU) имеет смысл также поднять ресурсы
Docker Desktop: **Settings → Resources** → Memory ≥ 6 GB, CPUs ≥ 4.

### Проверка

Репозиторий задания (checker) и репозиторий решения — разные репозитории; `check.sh`
предыдущих недель не перезаписывается и не копируется поверх.

```
# Публичная проверка недели 4
./moduledev-week-4-reliability-task/check.sh --repo /path/to/solution

# Собственные Python-тесты (без Docker)
python3 -m pytest python/tests -q

# Собственные DB-тесты C# (Testcontainers, нужен Docker)
dotnet test Api.Tests
dotnet test Cli.Tests

# Аварийные тесты по всем шести failpoints
./scripts/recovery-tests.sh
```

Отчёт публичной проверки (`week-*-public-report.json`) в git не попадает.

**Compose seam, который проверяется:** ровно эти 12 service names должны существовать
и подниматься по `docker compose up -d --build` без ручного вмешательства:

```
gateway api cli postgres worker-a worker-b
outbox-dispatcher outbox-dispatcher-b receipt-adapter
inbox-reconciler inbox-reconciler-b provider-simulator
```

`cli` реализован как one-shot; единственный сервис с host-портом — `gateway`;
`receipt-adapter` не получает PostgreSQL-настроек; оба dispatcher используют
разные owner'ы, но одну роль `outbox_dispatcher`; оба reconciler используют
одну роль `inbox_reconciler`.

Коды завершения: `0` — все public checks пройдены, `1` — нарушен контракт решения,
`2` — checker или окружение не готовы.

---

### Собственные тесты

Python-периметр покрыт `pytest` (без Docker, юнит- и интеграционные тесты в `python/tests/`):

- `test_hmac.py` — корректность HMAC-подписи над compact JSON с sorted keys;
- `test_adapter.py` — перевод legacy callback в receipt v1, отклонение wrong capability/invalid JSON/large body/CRLF/unknown fields;
- `test_dispatcher.py` — claim/succeed/fail цикл dispatcher, классификация ответов provider (retryable/terminal), сохранение idempotency key между retry;
- `test_integration.py` — сквозной прогон периметра (dispatcher → adapter → receipt v1 → HMAC → duplicate/conflict).

C#-тесты (`Api.Tests`, `Cli.Tests`):

- `DbInvariantsRegressionTests` — DB-инварианты и append-only;
- `IdempotencyRegressionTests` — атомарный claim до предметного эффекта;
- `RoleGrantsRegressionTests` — least-privilege роли;
- `WorkflowReclaimRegressionTests` — два конкурентных claim, expired lease, stale finish;
- `ManifestSchemaValidatorTests` — валидация manifest Draft 2020-12.

Запуск:


```
source .venv/bin/activate
python -m pytest python/tests -v
dotnet test Api.Tests
dotnet test Cli.Tests
```


**Аварийные тесты** (`scripts/recovery-tests.sh`) гоняют все шесть failpoints:


```
cd ~/projects/week
docker compose down -v
./scripts/recovery-tests.sh
```


---

### Аварийные сценарии

Failpoint включается только при `COURSE_TEST_PROFILE=1` и только для **одного** имени
в `COURSE_FAILPOINT`. Компонент пишет в stdout одну строку и замирает до остановки:


```
{"event":"failpoint.reached","name":"after_job_claim","instanceId":"worker-a"}
```


| **Failpoint**                | **Компонент**           | **Что durable к моменту сбоя**     | **После restart**                                                |
| :--------------------------- | :---------------------- | :--------------------------------- | :--------------------------------------------------------------- |
| `after_job_claim`            | worker                  | lease job                          | другой worker делает reclaim после expiry, растёт `leaseVersion` |
| `after_action_before_finish` | worker                  | ничего (транзакция не закоммичена) | rollback и retry, один предметный эффект                         |
| `after_outbox_claim`         | dispatcher              | delivery lease                     | reclaim после expiry, тот же `externalRequestId`                 |
| `after_provider_response`    | dispatcher              | эффект у provider возможен         | retry с тем же ключом, второго эффекта нет                       |
| `after_inbox_saved`          | api (`receipt.accept`)  | Inbox, receipt, idempotency result | повтор callback → `DUPLICATE`, reconciler применяет signal       |
| `after_manual_decision`      | api (`workflow.manual`) | ничего (транзакция не закоммичена) | повтор создаёт ровно одно decision                               |

Production profile игнорирует failpoints; публичного endpoint для них нет.

**Сценарий «сломай → восстанови → докажи»:**


```
# 1. включить failpoint у одного сервиса (пример: dispatcher)
COURSE_FAILPOINT=after_provider_response docker compose up -d --force-recreate outbox-dispatcher
# 2. дождаться ack
docker compose logs outbox-dispatcher | grep failpoint.reached
# 3. остановить контейнер и убрать failpoint
docker compose stop outbox-dispatcher
COURSE_FAILPOINT= docker compose up -d outbox-dispatcher outbox-dispatcher-b
# 4. циклы сами подхватывают работу — ручной SQL не нужен
```


---

### Диагностика

**Health и OpenMetrics:**


```
curl -fsS http://localhost:8080/health/live
curl -fsS http://localhost:8080/health/ready
curl -fsS http://localhost:8080/metrics
```


`api:8080/metrics` публикует как минимум: `workflow_jobs_ready`,
`workflow_job_oldest_age_seconds`, `workflow_processes_waiting`, `outbox_pending`,
`outbox_oldest_age_seconds`, `workflow_failures_total`. Остальные `/metrics` тоже
возвращают валидный OpenMetrics document.

`diagnostics.trace` — вся цепочка фактов по любому из идентификаторов:


```
export $(grep -v '^#' .env | xargs)
TOKEN=$(python3 scripts/issue_token.py --scope "diagnostics:read")

curl -s -X POST localhost:8080/api/diagnostics/trace \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"identifier":"<operationId | processId | jobId | externalRequestId | ...>"}' | jq
```


`diagnostics.stalled` — операции, где Outbox `DEAD`, а квитанции нет:


```
curl -s -X POST localhost:8080/api/diagnostics/stalled \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' | jq
```


**Логи сервисов:**


```
docker compose logs outbox-dispatcher outbox-dispatcher-b
docker compose logs receipt-adapter
docker compose logs inbox-reconciler inbox-reconciler-b
docker compose logs api worker-a worker-b gateway cli
```


**PostgreSQL (read-only views):**


```
docker compose exec postgres psql -U postgres -d course -c \
  "SELECT * FROM autocheck.outbox ORDER BY created_at DESC LIMIT 5;"
docker compose exec postgres psql -U postgres -d course -c \
  "SELECT * FROM autocheck.receipts ORDER BY received_at DESC LIMIT 5;"
docker compose exec postgres psql -U postgres -d course -c \
  "SELECT * FROM autocheck.decisions ORDER BY created_at DESC LIMIT 5;"
```


**Типичные сбои:**

| **Симптом**                                 | **Где смотреть**                                                | **Причина / действие**                                                           |
| :------------------------------------------ | :-------------------------------------------------------------- | :------------------------------------------------------------------------------- |
| `docker compose up` завершается с кодом 1   | `docker compose ps -a`, `docker compose logs cli`               | `cli` не применил миграции → зависимые сервисы не стартуют                       |
| `permission denied for schema …` в миграции | `docker compose logs cli`                                       | схема создана не под `course_owner`; см. `postgres-init/00-bootstrap-roles.sh`   |
| Outbox остаётся `RETRY_WAIT`/`DEAD`         | `/metrics` (`outbox_pending`), trace → `outbox[].lastErrorCode` | provider недоступен: `transport.error.retryable`; 4xx (кроме 408/429) — terminal |
| Callback возвращает 400                     | логи `receipt-adapter`                                          | нет одного из пяти полей legacy-callback или тело > 64 KiB                       |
| Callback возвращает 409                     | trace → `inbox[]`                                               | тот же `messageId` с другими байтами тела                                        |
| Job завис в `LEASED`                        | trace → `jobs[]`, `attempts[]`                                  | worker упал; reclaim после `COURSE_JOB_LEASE_MS`                                 |
| `/health/ready` = 503                       | `docker compose logs postgres`                                  | PostgreSQL недоступен (для adapter — gateway)                                    |

`DEAD` Outbox-доставки — это **не** `REJECTED`: операция остаётся `PROCESSING`,
процесс — `WAITING_SIGNAL`, а поздняя валидная квитанция всё ещё переводит операцию
в `CONFIRMED`.

---

### История замечаний

Статусы по калибровке `late-week-quality.3` — сопоставление старого и нового результата:

| **Замечание**                                                    | **Неделя** | **Что было**                          | **Что сделано**                                                           | **Статус** |
| :--------------------------------------------------------------- | :--------- | :------------------------------------ | :------------------------------------------------------------------------ | :--------- |
| Широкие суперпользовательские DB-подключения                     | 1          | `api`/`cli` ходили одной учёткой      | Роли `course_owner`/`course_migrator`/`course_publisher`/`course_runtime` | `fixed`    |
| Отсутствие проверки типов `iat`/`scope` в JWT                    | 1          | JWT принимался без строгой проверки   | Добавлены type-проверки                                                   | `fixed`    |
| Неполная валидация manifest/OpenAPI                              | 1          | Manifest не проверялся по схеме       | [JsonSchema.Net](https://jsonschema.net/) Draft 2020-12 в CLI             | `fixed`    |
| Отсутствие DB-инвариантов/append-only                            | 1          | Не было ограничений на уровне БД      | Добавлены invariants и canary-таблица                                     | `fixed`    |
| `job.attempt_count` не обновлялся при реклейме                   | 2          | `two-worker-reclaim-and-stale-finish` | Миграция 011                                                              | `fixed`    |
| Все проверки Python-периметра                                    | 3          | —                                     | —                                                                         | `fixed`    |
| Некорректные пароли ролей `outbox_dispatcher`/`inbox_reconciler` | 3          | Задавались в миграции                 | Перенесены в `postgres-init/00-bootstrap-roles.sh`                        | `fixed`    |
| `EXECUTE FROM PUBLIC` давал лишний доступ                        | 3          | Функции доступны всем ролям           | Миграция 016                                                              | `fixed`    |
| `api` под широкой учётной записью                                | 3          | Использовал `POSTGRES_USER`           | Переведён на `course_runtime`                                             | `fixed`    |
| Type `outbox.dead_at` ожидался как `text`                        | 4          | Ошибка публичной проверки             | Checker `week-4-public-check/0.4` ожидает `timestamptz`                   | `fixed`    |
| Два запуска checker'а конфликтовали по `container_name`          | 4          | Жёсткие имена контейнеров             | Убраны все `container_name`                                               | `fixed`    |

---

### Ограничения

- Поддерживается только валюта `RUB` (унаследовано с недели 1).
- Python-сервисы не имеют host-портов — единственная точка входа снаружи `gateway`.
- `receipt-adapter` не имеет database credentials — путь до PostgreSQL идёт через
  `gateway → api → api.invoke`.
- Пересоздание Python-сервисов не теряет состояние — источник истины PostgreSQL
  (Outbox/Inbox/receipts/decisions), процессы Python stateless.
- Provider-simulator подключается по digest, а не по тегу.
- Журналы C# (`api`, `worker`) — валидный JSON по строке (`AddJsonConsole`), но имена
  полей формата Microsoft.Extensions.Logging, а не единая схема с Python. Обе схемы
  удовлетворяют требованию «одна строка = один JSON».
- Failpoint в `api` блокирует только текущий запрос; остальные запросы продолжают
  обслуживаться до остановки контейнера.

ADR и разборы:

- [ADR 001: Trust boundary](docs/001-trust-boundary.md)
- [ADR 002: Технический и предметный результат](docs/002-technical-vs-domain-result.md)
- [ADR 003: Lease, fencing и at-least-once](docs/003-lease-fencing-at-least-once.md)



