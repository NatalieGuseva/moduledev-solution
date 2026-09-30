#!/usr/bin/env bash
# Автоматические аварийные тесты недели 4.
#
# Все секреты и пароли читаются из окружения. Скрипт не хардкодит ни одного
# пароля, токена, capability или signing key. Если рядом есть .env —
# он подгружается автоматически (см. .env.example для шаблона).
# Обязательные переменные проверяются через ${VAR:?...}.
set -euo pipefail

export COMPOSE_INTERACTIVE_NO_CLI=1

REPO_DIR="${REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
cd "$REPO_DIR"

# --- Загрузка .env (не коммитится) ------------------------------------------
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# --- Дефолты для НЕ-секретных значений --------------------------------------
export COURSE_GATEWAY_PORT="${COURSE_GATEWAY_PORT:-8080}"
export COURSE_TEST_PROFILE="${COURSE_TEST_PROFILE:-1}"
export COURSE_JWT_ISSUER="${COURSE_JWT_ISSUER:-moduledev-course}"
export COURSE_JWT_AUDIENCE="${COURSE_JWT_AUDIENCE:-moduledev-api}"
export PROVIDER_URL="${PROVIDER_URL:-http://provider-simulator:8081}"
export OUTBOX_OWNER="${OUTBOX_OWNER:-outbox-dispatcher}"
export OUTBOX_OWNER_B="${OUTBOX_OWNER_B:-outbox-dispatcher-b}"
export RECEIPT_API_URL="${RECEIPT_API_URL:-http://gateway:8080/api/receipt/accept}"

# --- Обязательные секреты: без них не запускаемся ---------------------------
: "${COURSE_JWT_SIGNING_KEY:?COURSE_JWT_SIGNING_KEY is required (set it in .env)}"
: "${COURSE_POSTGRES_PASSWORD:?COURSE_POSTGRES_PASSWORD is required (set it in .env)}"
: "${COURSE_MIGRATOR_PASSWORD:?COURSE_MIGRATOR_PASSWORD is required (set it in .env)}"
: "${COURSE_PUBLISHER_PASSWORD:?COURSE_PUBLISHER_PASSWORD is required (set it in .env)}"
: "${COURSE_RUNTIME_PASSWORD:?COURSE_RUNTIME_PASSWORD is required (set it in .env)}"
: "${COURSE_WORKER_PASSWORD:?COURSE_WORKER_PASSWORD is required (set it in .env)}"
: "${COURSE_OUTBOX_PASSWORD:?COURSE_OUTBOX_PASSWORD is required (set it in .env)}"
: "${COURSE_INBOX_PASSWORD:?COURSE_INBOX_PASSWORD is required (set it in .env)}"
: "${COURSE_AUTOCHECK_PASSWORD:?COURSE_AUTOCHECK_PASSWORD is required (set it in .env)}"
: "${PROVIDER_HMAC_SECRET:?PROVIDER_HMAC_SECRET is required (set it in .env)}"
: "${PROVIDER_CALLBACK_CAPABILITY:?PROVIDER_CALLBACK_CAPABILITY is required (set it in .env)}"
: "${PROVIDER_CALLBACK_TOKEN:?PROVIDER_CALLBACK_TOKEN is required (set it in .env)}"

# PROVIDER_CALLBACK_TOKEN адаптер отправляет в Authorization как есть, и по
# docs4/04-week-3.md это JWT principal receipt-provider со scope receipt:write.
# Заглушка или просроченный токен дают 401 на receipt.accept, после чего
# failpoint after_inbox_saved недостижим, а причина выглядит неочевидно.
python3 - "$PROVIDER_CALLBACK_TOKEN" <<'PY' || exit 2
import base64, json, sys, time
parts = sys.argv[1].split(".")

def fail(msg):
    print("PROVIDER_CALLBACK_TOKEN: " + msg, file=sys.stderr)
    print("  выпустите токен и запишите его в .env как PROVIDER_CALLBACK_TOKEN:", file=sys.stderr)
    print("    python3 scripts/issue_token.py --sub receipt-provider --scope receipt:write --ttl 2592000", file=sys.stderr)
    print("  (значение --consumer см. docs4/04-week-3.md)", file=sys.stderr)
    sys.exit(2)

if len(parts) != 3:
    fail("это не JWT (ожидается header.payload.signature)")
try:
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
except Exception as exc:
    fail("payload не декодируется: %s" % exc)
exp = claims.get("exp")
if isinstance(exp, (int, float)) and exp < time.time():
    fail("токен просрочен")
PY
: "${PROVIDER_AUDIT_TOKEN:?PROVIDER_AUDIT_TOKEN is required (set it in .env)}"

GATEWAY_URL="http://127.0.0.1:${COURSE_GATEWAY_PORT}"

FAILPOINTS=(
  after_job_claim
  after_action_before_finish
  after_outbox_claim
  after_provider_response
  after_inbox_saved
  after_manual_decision
)

# Реплика, которая получает COURSE_FAILPOINT и должна «застрять» в точке.
# after_inbox_saved принадлежит api (receipt.accept: после commit Inbox,
# receipt и idempotency result, до HTTP-ответа), а не reconciler'у — см.
# docs4/07-autocheck-outline.md. Оба reconciler'а при этом остановлены
# (FAILPOINT_PEERS), чтобы signal не применился до проверяемой границы.
declare -A FAILPOINT_SERVICE=(
  [after_job_claim]=worker-a
  [after_action_before_finish]=worker-a
  [after_outbox_claim]=outbox-dispatcher
  [after_provider_response]=outbox-dispatcher
  [after_inbox_saved]=api
  [after_manual_decision]=api
)

# Все реплики группы, которые могут забрать работу. Их нужно остановить
# ДО создания операции, иначе peer (worker-b/dispatcher-b/reconciler-b)
# успеет claim'нуть job/delivery раньше, чем целевая реплика активирует
# failpoint. Перезапускаем потом только целевую реплику из FAILPOINT_SERVICE.
declare -A FAILPOINT_PEERS=(
  [after_job_claim]="worker-a worker-b"
  [after_action_before_finish]="worker-a worker-b"
  [after_outbox_claim]="outbox-dispatcher outbox-dispatcher-b"
  [after_provider_response]="outbox-dispatcher outbox-dispatcher-b"
  [after_inbox_saved]="inbox-reconciler inbox-reconciler-b"
  [after_manual_decision]="api"
)

# Failpoint'ы, которые срабатывают на стороне worker/dispatcher/reconciler,
# требуют, чтобы job/delivery ещё не была claim'нута до активации failpoint'а.
# Поэтому вся группа останавливается ДО создания операции.
is_processing_failpoint() {
  case "$1" in
    after_manual_decision) return 1 ;;
    *) return 0 ;;
  esac
}

# after_inbox_saved срабатывает на callback'е от провайдера, который приходит
# почти сразу после отправки платежа. Поэтому api нужно перезапустить с
# COURSE_FAILPOINT ДО создания операции, иначе callback успеет пройти через
# api без failpoint'а, и точка не будет достигнута.
activates_before_create() {
  [[ "$1" == "after_inbox_saved" ]]
}

cleanup() {
  docker compose down -v --remove-orphans </dev/null >/dev/null 2>&1 || true
}

# Диагностика при падении: состояние контейнеров и хвосты логов ключевых
# сервисов. Всё уходит в stderr и не влияет на код возврата.
dump_diagnostics() {
  {
    echo "--- diagnostics: docker compose ps ---"
    docker compose ps -a </dev/null 2>&1 || true
    local svc
    for svc in outbox-dispatcher outbox-dispatcher-b provider-simulator api gateway receipt-adapter; do
      echo "--- diagnostics: logs ${svc} (tail 30) ---"
      docker compose logs --no-color --no-log-prefix --tail 30 "$svc" </dev/null 2>&1 || true
    done
  } >&2
}

# Код возврата скрипта сохраняется (в EXIT-trap его не нужно возвращать явно).
# KEEP_STACK=1 оставляет стенд поднятым после падения — чтобы можно было
# зайти в БД и логи руками.
on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    dump_diagnostics
  fi
  if [[ -n "${KEEP_STACK:-}" ]]; then
    echo "KEEP_STACK is set: stack left running (docker compose down -v to remove)" >&2
  else
    cleanup
  fi
}
trap on_exit EXIT

wait_ready() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if curl -fsS "${GATEWAY_URL}/health/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "gateway readiness did not become 200" >&2
  return 1
}

psql_query() {
  docker compose exec -T \
    -e PGPASSWORD="${COURSE_AUTOCHECK_PASSWORD}" \
    postgres \
    psql -X -v ON_ERROR_STOP=1 -U autocheck_reader -d course -At -c "$1" </dev/null
}

# Ждёт появления job в autocheck.jobs для указанной operation.
wait_for_job_ready() {
  local operation_id="$1"
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    local count
    count=$(psql_query "SELECT count(*) FROM autocheck.jobs WHERE process_id = (SELECT process_id FROM autocheck.operations WHERE operation_id = '${operation_id}'::uuid)")
    if [[ "$count" -ge 1 ]]; then
      return 0
    fi
    sleep 0.3
  done
  echo "no workflow job appeared for operation ${operation_id}" >&2
  return 1
}

# Ждёт появления external_request для указанной operation.
wait_for_external_request() {
  local operation_id="$1"
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    local count
    count=$(psql_query "SELECT count(*) FROM autocheck.external_requests WHERE operation_id = '${operation_id}'::uuid")
    if [[ "$count" -ge 1 ]]; then
      return 0
    fi
    sleep 0.3
  done
  echo "no external_request appeared for operation ${operation_id}" >&2
  return 1
}

# Проверяет, сработал ли failpoint с указанным именем в логах сервиса.
#
# docker compose logs добавляет префикс вида "service-1  | ",
# из-за которого строка перестаёт быть валидным JSON.
# Используем --no-log-prefix (Docker Compose v2.x), плюс fallback
# через grep -F для двух возможных порядков полей:
#   C# AddJsonConsole:  {"event":"failpoint.reached","name":"<name>","instanceId":"..."}
#   Python observability: {"event": "failpoint.reached", "instanceId": "...",
#                          "level": "INFO", "name": "<name>", "service": "...", ...}
failpoint_reached() {
  local service="$1"
  local name="$2"

  local logs
  logs=$(docker compose logs --no-color --no-log-prefix "$service" </dev/null 2>/dev/null || true)

  # Здесь и ниже логи подаются через here-string, а не через пайп: при
  # `set -o pipefail` пайп с `grep -q` может дать ложный отказ из-за SIGPIPE.

  # C# AddJsonConsole — без пробелов, поля в порядке event, name, instanceId.
  if grep -Fq "\"event\":\"failpoint.reached\",\"name\":\"${name}\"" <<<"$logs"; then
    return 0
  fi

  # Python observability — с пробелами, поля в любом порядке. event и name
  # должны быть в ОДНОЙ строке лога: два независимых grep по всему выводу
  # дают ложное срабатывание, если поля встретились в разных записях.
  if grep -Eq "\"event\": \"failpoint\.reached\".*\"name\": \"${name}\"|\"name\": \"${name}\".*\"event\": \"failpoint\.reached\"" <<<"$logs"; then
    return 0
  fi

  # Fallback через jq, если grep не сработал.
  printf '%s' "$logs" \
    | jq -R 'fromjson? // empty' 2>/dev/null \
    | jq -e --arg name "$name" \
        'select(.event == "failpoint.reached" and .name == $name)' \
        >/dev/null 2>&1
}

issue_jwt() {
  local subject="$1"; shift
  local consumer="$1"; shift
  local scopes="$1"; shift
  python3 - "$subject" "$consumer" "$scopes" \
    "$COURSE_JWT_ISSUER" "$COURSE_JWT_AUDIENCE" "$COURSE_JWT_SIGNING_KEY" <<'PY'
import base64, hashlib, hmac, json, sys, time
subject, consumer, scopes, issuer, audience, secret = sys.argv[1:7]

def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

header = b64url(b'{"alg":"HS256","typ":"JWT"}')
payload = b64url(json.dumps({
    "iss": issuer,
    "aud": audience,
    "sub": subject,
    "consumer": consumer,
    "scope": scopes,
    "iat": int(time.time()) - 5,
    "exp": int(time.time()) + 3600,
}, separators=(",", ":"), sort_keys=True).encode("utf-8"))
signing_input = f"{header}.{payload}".encode("ascii")
signature = b64url(hmac.new(secret.encode("utf-8"), signing_input, hashlib.sha256).digest())
print(f"{header}.{payload}.{signature}")
PY
}

CLIENT_TOKEN="$(issue_jwt "recovery-client" "web" "payment:write payment:read workflow:read")"
REVIEWER_TOKEN="$(issue_jwt "recovery-reviewer" "backoffice" "workflow:manual payment:read")"

# ---------------------------------------------------------------------------
# Создание операции payment-processing.
# Body соответствует payment-request.payload.schema.json.
# ---------------------------------------------------------------------------
create_processing_operation() {
  local label="$1"
  local idem="recovery-${label}-$(date +%s%N)"
  local body
  body=$(curl -sS -X POST "${GATEWAY_URL}/api/payment/request" \
    -H "Authorization: Bearer ${CLIENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Action-Version: 1" \
    -H "Idempotency-Key: ${idem}" \
    -d '{"operationKind":"PAYMENT_EXECUTION","amount":"1000.00","currency":"RUB"}') || true

  if ! printf '%s' "$body" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    echo "payment.request failed for ${label}: ${body}" >&2
    return 1
  fi

  local operation_id
  operation_id=$(printf '%s' "$body" | jq -er '.result.operationId')

  local submit_body
  submit_body=$(curl -sS -X POST "${GATEWAY_URL}/api/payment/submit" \
    -H "Authorization: Bearer ${CLIENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Action-Version: 1" \
    -H "Idempotency-Key: ${idem}-submit" \
    -d "{\"operationId\":\"${operation_id}\"}") || true

  if ! printf '%s' "$submit_body" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    echo "payment.submit failed for ${label}: ${submit_body}" >&2
    return 1
  fi

  printf '%s' "$operation_id"
}

# ---------------------------------------------------------------------------
# Создание операции payment-review (уходит в WAITING_MANUAL).
# ---------------------------------------------------------------------------
create_review_operation() {
  local label="$1"
  local idem="recovery-${label}-$(date +%s%N)"
  local body
  body=$(curl -sS -X POST "${GATEWAY_URL}/api/payment/request" \
    -H "Authorization: Bearer ${CLIENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Action-Version: 1" \
    -H "Idempotency-Key: ${idem}" \
    -d '{"operationKind":"PAYMENT_APPROVAL","amount":"150000.00","currency":"RUB"}') || true

  if ! printf '%s' "$body" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    echo "payment.request (review) failed for ${label}: ${body}" >&2
    return 1
  fi

  local operation_id
  operation_id=$(printf '%s' "$body" | jq -er '.result.operationId')

  local submit_body
  submit_body=$(curl -sS -X POST "${GATEWAY_URL}/api/payment/submit" \
    -H "Authorization: Bearer ${CLIENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Action-Version: 1" \
    -H "Idempotency-Key: ${idem}-submit" \
    -d "{\"operationId\":\"${operation_id}\"}") || true

  if ! printf '%s' "$submit_body" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    echo "payment.submit (review) failed for ${label}: ${submit_body}" >&2
    return 1
  fi

  printf '%s' "$operation_id"
}

wait_manual_step() {
  local operation_id="$1"
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    local process_id
    process_id=$(psql_query "SELECT process_id FROM autocheck.operations WHERE operation_id = '${operation_id}'::uuid")
    if [[ -n "$process_id" ]]; then
      local step_id
      step_id=$(psql_query "SELECT step_instance_id FROM autocheck.steps WHERE process_id = '${process_id}'::uuid AND step_type = 'MANUAL' AND state = 'WAITING'")
      if [[ -n "$step_id" ]]; then
        printf '%s' "$step_id"
        return 0
      fi
    fi
    sleep 0.5
  done
  echo "manual step for ${operation_id} was not found" >&2
  return 1
}

# Один запрос к audit-эндпоинту provider-simulator.
#
# Образ провайдера (/provider-simulator) не содержит ни sh, ни wget, ни curl,
# поэтому `docker compose exec provider-simulator sh -c ...` в нём работать не
# может ("exec: sh: executable file not found"). Вместо этого запрос делается
# из соседнего контейнера с Python (по умолчанию receipt-adapter — он не
# участвует ни в одном failpoint'е и всегда поднят) по адресу PROVIDER_URL
# внутри compose-сети.
#
# Возвращает 0 и тело ответа при успехе; иначе 1 и одну строку с причиной.
AUDIT_EXEC_SERVICE="${AUDIT_EXEC_SERVICE:-receipt-adapter}"

provider_audit_fetch() {
  local external_id="$1"
  local url="${PROVIDER_URL}/internal/audit/${external_id}"
  local py='
import os, sys, urllib.request
try:
    req = urllib.request.Request(sys.argv[1], headers={"X-Audit-Token": os.environ["AUDIT_TOKEN"]})
    sys.stdout.write(urllib.request.urlopen(req, timeout=3).read().decode())
except Exception as exc:
    print("audit request failed: %r" % (exc,), file=sys.stderr)
    sys.exit(1)
'
  local bin out=""
  for bin in python python3; do
    if out=$(docker compose exec -T \
        -e AUDIT_TOKEN="${PROVIDER_AUDIT_TOKEN}" \
        "$AUDIT_EXEC_SERVICE" "$bin" -c "$py" "$url" </dev/null 2>&1); then
      printf '%s' "$out"
      return 0
    fi
    # Пробуем следующий интерпретатор только если этого нет в образе.
    [[ "$out" == *"executable file not found"* ]] || break
  done
  printf '%s' "$out"
  return 1
}

# Запасной источник истины, если audit недоступен: сколько раз провайдер
# принял платёж по этому id как НОВЫЙ (replay=false). Повторная доставка того
# же запроса при восстановлении логируется провайдером как replay=true и
# платежом не считается, так что значение 1 означает "ровно один платёж".
provider_accepts_from_logs() {
  local external_id="$1"
  docker compose logs --no-color --no-log-prefix provider-simulator </dev/null 2>/dev/null \
    | jq -Rr --arg id "$external_id" \
        'fromjson? | select(.msg == "payment accepted" and .operationId == $id and .replay == false) | 1' \
        2>/dev/null \
    | wc -l | tr -d ' '
}

# Возвращает число платежей, зафиксированных провайдером.
#
#   $1 — external_request_id
#   $2 — ожидаемое значение (по умолчанию 1)
#   $3 — сколько секунд ждать (по умолчанию 30)
#
# Опрашивает audit, пока значение не станет ожидаемым или не выйдет таймаут.
# Если audit недоступен, считает принятые платежи по логам провайдера (см.
# выше) и пишет об этом в stderr. Раньше функция молча превращала любую
# ошибку в 0, и "audit недоступен" выглядел как "платежа нет".
#
# При неудаче печатает в stderr последний реальный ответ и возвращает
# последнее увиденное число либо "unavailable". Код возврата всегда 0 (из-за
# set -e внутри $(...)) — решение принимает вызывающий код.
provider_payment_count() {
  local external_id="$1"
  local expected="${2:-1}"
  local timeout="${3:-30}"
  local deadline=$((SECONDS + timeout))
  local response="" count="" last_count="" log_count=""

  while (( SECONDS < deadline )); do
    if response=$(provider_audit_fetch "$external_id") && [[ "$response" == \{* ]]; then
      count=$(jq -r '.paymentCount // empty' <<<"$response" 2>/dev/null || true)
      if [[ -n "$count" ]]; then
        last_count="$count"
        if [[ "$count" == "$expected" ]]; then
          printf '%s' "$count"
          return 0
        fi
      fi
    else
      log_count=$(provider_accepts_from_logs "$external_id" || true)
      if [[ -n "$log_count" ]]; then
        last_count="$log_count"
        if [[ "$log_count" == "$expected" ]]; then
          echo "note: provider audit unavailable (${response%%$'\n'*}); payment count verified from provider logs" >&2
          printf '%s' "$log_count"
          return 0
        fi
      fi
    fi
    sleep 0.5
  done

  echo "provider payment check for ${external_id}: expected ${expected}, last audit response: ${response:-<empty>}" >&2
  printf '%s' "${last_count:-unavailable}"
}

# ONLY_FAILPOINT=after_provider_response ./recovery-tests.sh — прогнать одну
# точку (удобно вместе с KEEP_STACK=1 для отладки).
if [[ -n "${ONLY_FAILPOINT:-}" ]]; then
  if [[ ! -v "FAILPOINT_SERVICE[${ONLY_FAILPOINT}]" ]]; then
    echo "unknown ONLY_FAILPOINT '${ONLY_FAILPOINT}'; known: ${FAILPOINTS[*]}" >&2
    exit 2
  fi
  FAILPOINTS=("$ONLY_FAILPOINT")
fi

# ---------------------------------------------------------------------------
# Основной цикл.
# ---------------------------------------------------------------------------
for fp in "${FAILPOINTS[@]}"; do
  echo "=== failpoint: ${fp} ==="

  cleanup
  docker compose up -d </dev/null >/dev/null
  wait_ready

  SERVICE="${FAILPOINT_SERVICE[$fp]}"
  PEERS="${FAILPOINT_PEERS[$fp]}"
  OPERATION_ID=""
  STEP_ID=""
  IDEMPOTENCY_KEY=""

  if is_processing_failpoint "$fp"; then
    # Останавливаем ВСЮ группу реплик, а не только целевую: иначе
    # peer (worker-b/dispatcher-b/reconciler-b) успеет забрать job
    # раньше, чем целевая реплика активирует failpoint.
    # shellcheck disable=SC2086
    docker compose stop $PEERS </dev/null >/dev/null
  fi

  if activates_before_create "$fp"; then
    export COURSE_FAILPOINT="$fp"
    docker compose up -d --no-build "$SERVICE" </dev/null >/dev/null
    wait_ready
  fi

  if [[ "$fp" == "after_manual_decision" ]]; then
    OPERATION_ID=$(create_review_operation "manual")
    STEP_ID=$(wait_manual_step "$OPERATION_ID")
  else
    OPERATION_ID=$(create_processing_operation "$fp")
    wait_for_job_ready "$OPERATION_ID"
  fi

  # Активируем failpoint и перезапускаем ТОЛЬКО целевую реплику
  # (для after_inbox_saved это уже сделано выше, до создания операции).
  
  if ! activates_before_create "$fp"; then
    export COURSE_FAILPOINT="$fp"
    if is_processing_failpoint "$fp"; then
      docker compose up -d --no-build "$SERVICE" </dev/null >/dev/null
    else
      docker compose stop "$SERVICE" </dev/null >/dev/null
      docker compose up -d --no-build "$SERVICE" </dev/null >/dev/null
    fi

  # После перезапуска api gateway уже может быть доступен,
  # но сам api ещё может не слушать порт 8080.
  wait_ready
  fi

  # Для after_manual_decision failpoint срабатывает внутри запроса
  # /api/workflow/manual, поэтому запрос нужно отправить после запуска
  # api с COURSE_FAILPOINT, но до ожидания failpoint.reached.
  if [[ "$fp" == "after_manual_decision" ]]; then
    IDEMPOTENCY_KEY="recovery-manual-$(date +%s%N)"

    PROCESS_ID=$(psql_query \
      "SELECT process_id
         FROM autocheck.operations
        WHERE operation_id = '${OPERATION_ID}'::uuid")

    MANUAL_RESPONSE=$(curl -sS -w $'\n%{http_code}' \
      -X POST "${GATEWAY_URL}/api/workflow/manual" \
      -H "Authorization: Bearer ${REVIEWER_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "X-Action-Version: 1" \
      -H "Idempotency-Key: ${IDEMPOTENCY_KEY}" \
      -d "{\"processId\":\"${PROCESS_ID}\",\"stepInstanceId\":\"${STEP_ID}\",\"decision\":\"APPROVED\",\"reason\":\"recovery-tests\"}")

    MANUAL_STATUS="${MANUAL_RESPONSE##*$'\n'}"
    MANUAL_BODY="${MANUAL_RESPONSE%$'\n'*}"

    # 504 — это ожидаемый исход: failpoint after_manual_decision
    # «застревает» внутри обработки запроса, и gateway отдаёт таймаут.
    # Это признак того, что failpoint сработал, а не ошибка.
    if [[ "$MANUAL_STATUS" != "200" && "$MANUAL_STATUS" != "201" \
       && "$MANUAL_STATUS" != "202" && "$MANUAL_STATUS" != "504" ]]; then
      echo "manual decision request failed: HTTP ${MANUAL_STATUS}" >&2
      echo "$MANUAL_BODY" >&2
      exit 1
    fi
  fi

  # Ждём failpoint.reached в логах сервиса.
  deadline=$((SECONDS + 90))
  reached=0
  while (( SECONDS < deadline )); do
    if failpoint_reached "$SERVICE" "$fp"; then
      reached=1
      break
    fi
    sleep 0.5
  done
  if (( reached == 0 )); then
    echo "failpoint ${fp} was not reached" >&2
    docker compose logs --no-color "$SERVICE" </dev/null | tail -80 >&2
    if [[ "$fp" == "after_inbox_saved" ]]; then
      echo "--- callback chain: provider-simulator -> receipt-adapter -> gateway -> api ---" >&2
      docker compose logs --no-color --no-log-prefix receipt-adapter gateway api provider-simulator </dev/null 2>&1 \
        | grep -iE 'receipt|callback|401|unauthor|forbidden|failpoint' | tail -40 >&2 || true
      echo "hint: failpoint after_inbox_saved is reached only when provider callback is accepted by api (receipt.accept); HTTP 401 above means the callback is rejected before that" >&2
    fi
    exit 1
  fi

  # Останавливаем сервис, убираем failpoint, поднимаем весь стек.
  docker compose stop "$SERVICE" </dev/null >/dev/null
  unset COURSE_FAILPOINT
  docker compose up -d --no-build </dev/null >/dev/null
  wait_ready

  if is_processing_failpoint "$fp"; then
    wait_for_external_request "$OPERATION_ID" \
      || echo "warning: external_request for ${OPERATION_ID} did not appear after ${fp}; invariant checks below will decide" >&2
  fi

  # -------------------------------------------------------------------------
  # Проверки инвариантов.
  # -------------------------------------------------------------------------
  ROWS=$(psql_query "SELECT count(*) FROM autocheck.operations WHERE operation_id = '${OPERATION_ID}'::uuid")
  if [[ "$ROWS" != "1" ]]; then
    echo "operation ${OPERATION_ID} was lost after ${fp}" >&2
    exit 1
  fi

  EXTERNAL=$(psql_query "SELECT count(*) FROM autocheck.external_requests WHERE operation_id = '${OPERATION_ID}'::uuid")
  if [[ "$fp" == "after_manual_decision" ]]; then
    if [[ "$EXTERNAL" != "0" ]]; then
      echo "manual operation ${OPERATION_ID} unexpectedly has an external request" >&2
      exit 1
    fi
  else
    if [[ "$EXTERNAL" != "1" ]]; then
      echo "second external request after ${fp}" >&2
      exit 1
    fi
  fi

  case "$fp" in
    after_provider_response)
      EXTERNAL_ID=$(psql_query "SELECT external_request_id FROM autocheck.external_requests WHERE operation_id = '${OPERATION_ID}'::uuid")
      if [[ -z "$EXTERNAL_ID" ]]; then
        echo "no external_request_id found for operation ${OPERATION_ID} after ${fp}" >&2
        exit 1
      fi

      # 1) Провайдер должен зафиксировать платёж ровно один раз. Ждём
      #    значения 1, а не читаем счётчик один раз: провайдер и recovery
      #    работают асинхронно, и мгновенное чтение даёт ложный 0.
      PAYMENTS=$(provider_payment_count "$EXTERNAL_ID" 1 "${PROVIDER_AUDIT_TIMEOUT:-30}")
      if [[ "$PAYMENTS" != "1" ]]; then
        echo "provider paymentCount=${PAYMENTS} after ${fp}, expected 1 (external_request_id=${EXTERNAL_ID})" >&2
        exit 1
      fi

      # 2) Даём восстановленному dispatcher время повторить отправку
      #    (истечение lease, retry) и убеждаемся, что дубля не появилось:
      #    именно это и есть идемпотентность при сбое после ответа провайдера.
      sleep "${RECOVERY_SETTLE_SECONDS:-10}"
      PAYMENTS_SETTLED=$(provider_payment_count "$EXTERNAL_ID" 1 5)
      if [[ "$PAYMENTS_SETTLED" != "1" ]]; then
        echo "provider paymentCount=${PAYMENTS_SETTLED} after recovery from ${fp}, expected exactly 1 (duplicate payment?)" >&2
        exit 1
      fi
      ;;
    after_inbox_saved)
      INBOX_FROM="FROM autocheck.inbox WHERE message_id IN (SELECT message_id FROM autocheck.receipts WHERE external_request_id IN (SELECT external_request_id FROM autocheck.external_requests WHERE operation_id = '${OPERATION_ID}'::uuid))"

      # Inbox был durable ещё до остановки api, но ждём, пока после
      # перезапуска повтор callback и reconciler отработают.
      deadline=$((SECONDS + 60))
      INBOX_ROWS=0
      while (( SECONDS < deadline )); do
        INBOX_ROWS=$(psql_query "SELECT count(*) ${INBOX_FROM}")
        [[ "$INBOX_ROWS" -ge 1 ]] && break
        sleep 0.5
      done
      if [[ "$INBOX_ROWS" != "1" ]]; then
        echo "expected exactly one inbox row after ${fp}, got ${INBOX_ROWS}" >&2
        exit 1
      fi

      INBOX_STATE=$(psql_query "SELECT state ${INBOX_FROM}")
      if [[ "$INBOX_STATE" != "RECEIVED" && "$INBOX_STATE" != "APPLIED" ]]; then
        echo "unexpected inbox state '${INBOX_STATE}' after ${fp}" >&2
        exit 1
      fi

      # Повтор callback должен давать DUPLICATE, а не вторую запись Inbox.
      sleep "${RECOVERY_SETTLE_SECONDS:-10}"
      INBOX_ROWS_SETTLED=$(psql_query "SELECT count(*) ${INBOX_FROM}")
      if [[ "$INBOX_ROWS_SETTLED" != "1" ]]; then
        echo "inbox rows changed to ${INBOX_ROWS_SETTLED} after recovery from ${fp}, expected exactly 1" >&2
        exit 1
      fi
      ;;
    after_manual_decision)
      # Согласно 05-week-4.md, failpoint after_manual_decision достигается
      # ВНУТРИ незавершённой транзакции. Остановка api здесь обязана
      # привести к rollback: решение, переход и следующий job не должны
      # сохраниться. Проверяем именно это.
      sleep "${RECOVERY_SETTLE_SECONDS:-10}"

      DECISIONS=$(psql_query "SELECT count(*) FROM autocheck.decisions WHERE process_id = (SELECT process_id FROM autocheck.operations WHERE operation_id = '${OPERATION_ID}'::uuid)")
      if [[ "$DECISIONS" != "0" ]]; then
        echo "expected zero manual decisions after ${fp} (failpoint is inside uncommitted transaction), got ${DECISIONS}" >&2
        exit 1
      fi

      # Процесс не должен перейти в COMPLETED/FAILED — он остаётся
      # в WAITING_MANUAL, потому что решение не было закоммичено.
      PROCESS_STATE=$(psql_query "SELECT state FROM autocheck.processes WHERE process_id = (SELECT process_id FROM autocheck.operations WHERE operation_id = '${OPERATION_ID}'::uuid)")
      if [[ "$PROCESS_STATE" != "WAITING_MANUAL" ]]; then
        echo "expected process state WAITING_MANUAL after ${fp}, got '${PROCESS_STATE}'" >&2
        exit 1
      fi
      ;;
  esac

  echo "  ok"
done

echo "recovery tests passed"

    