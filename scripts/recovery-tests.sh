#!/usr/bin/env bash
# Автоматические аварийные тесты недели 4.
set -euo pipefail

export COMPOSE_INTERACTIVE_NO_CLI=1

REPO_DIR="${REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
cd "$REPO_DIR"

GATEWAY_PORT="${COURSE_GATEWAY_PORT:-8080}"
GATEWAY_URL="http://127.0.0.1:${GATEWAY_PORT}"

export COURSE_GATEWAY_PORT
export COURSE_TEST_PROFILE=1
export COURSE_JWT_ISSUER="moduledev-course"
export COURSE_JWT_AUDIENCE="moduledev-api"
export COURSE_JWT_SIGNING_KEY="local-recovery-jwt-0123456789abcdef0123456789abcdef"
export COURSE_POSTGRES_PASSWORD="local-postgres-pw"
export COURSE_MIGRATOR_PASSWORD="local-migrator-pw"
export COURSE_PUBLISHER_PASSWORD="local-publisher-pw"
export COURSE_RUNTIME_PASSWORD="local-runtime-pw"
export COURSE_WORKER_PASSWORD="local-worker-pw"
export COURSE_OUTBOX_PASSWORD="local-outbox-pw"
export COURSE_INBOX_PASSWORD="local-inbox-pw"
export COURSE_AUTOCHECK_PASSWORD="local-autocheck-pw"
export PROVIDER_URL="http://provider-simulator:8081"
export OUTBOX_OWNER="outbox-dispatcher"
export OUTBOX_OWNER_B="outbox-dispatcher-b"
export PROVIDER_CALLBACK_CAPABILITY="local-recovery-capability"
export PROVIDER_CALLBACK_TOKEN="local-recovery-token"
export PROVIDER_HMAC_SECRET="local-recovery-hmac-0123456789abcdef"
export RECEIPT_API_URL="http://gateway:8080/api/receipt/accept"
export PROVIDER_AUDIT_TOKEN="local-recovery-audit"

FAILPOINTS=(
  after_job_claim
  after_action_before_finish
  after_outbox_claim
  after_provider_response
  after_inbox_saved
  after_manual_decision
)

declare -A FAILPOINT_SERVICE=(
  [after_job_claim]=worker-a
  [after_action_before_finish]=worker-a
  [after_outbox_claim]=outbox-dispatcher
  [after_provider_response]=outbox-dispatcher
  [after_inbox_saved]=inbox-reconciler
  [after_manual_decision]=api
)

cleanup() {
  docker compose down -v --remove-orphans </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT

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
# Body соответствует payment-request.payload.schema.json:
#   required: operationKind, amount, currency
#   operationKind: PAYMENT_EXECUTION | PAYMENT_APPROVAL
#   amount: string, pattern с 1-2 знаками после точки
#   currency: "RUB"
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

provider_payment_count() {
  local external_id="$1"
  docker compose exec -T \
    -e AUDIT_TOKEN="${PROVIDER_AUDIT_TOKEN}" \
    provider-simulator \
    sh -c "wget -q -O - --header=\"X-Audit-Token: \${AUDIT_TOKEN}\" http://127.0.0.1:8081/internal/audit/${external_id}" \
    </dev/null | jq -r '.paymentCount // 0'
}

for fp in "${FAILPOINTS[@]}"; do
  echo "=== failpoint: ${fp} ==="

  cleanup
  docker compose up -d </dev/null >/dev/null
  wait_ready

  SERVICE="${FAILPOINT_SERVICE[$fp]}"
  OPERATION_ID=""
  STEP_ID=""
  IDEMPOTENCY_KEY=""

  if [[ "$fp" == "after_manual_decision" ]]; then
    OPERATION_ID=$(create_review_operation "manual")
    STEP_ID=$(wait_manual_step "$OPERATION_ID")
  else
    OPERATION_ID=$(create_processing_operation "$fp")
  fi

  export COURSE_FAILPOINT="$fp"
  docker compose stop "$SERVICE" </dev/null >/dev/null
  docker compose up -d --no-build "$SERVICE" </dev/null >/dev/null

  deadline=$((SECONDS + 90))
  reached=0
  while (( SECONDS < deadline )); do
    if docker compose logs --no-color "$SERVICE" </dev/null 2>/dev/null \
       | grep -Eq "\"event\": ?\"failpoint.reached\", ?\"name\": ?\"${fp}\""; then
      reached=1
      break
    fi
    sleep 0.5
  done
  if (( reached == 0 )); then
    echo "failpoint ${fp} was not reached" >&2
    docker compose logs --no-color "$SERVICE" </dev/null | tail -50 >&2
    exit 1
  fi

  if [[ "$fp" == "after_manual_decision" ]]; then
    IDEMPOTENCY_KEY="recovery-manual-$(date +%s%N)"
    curl -sS -X POST "${GATEWAY_URL}/api/workflow/manual" \
      -H "Authorization: Bearer ${REVIEWER_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "X-Action-Version: 1" \
      -H "Idempotency-Key: ${IDEMPOTENCY_KEY}" \
      -d "{\"processId\":\"$(psql_query "SELECT process_id FROM autocheck.operations WHERE operation_id = '${OPERATION_ID}'::uuid")\",\"stepInstanceId\":\"${STEP_ID}\",\"decision\":\"APPROVED\",\"reason\":\"recovery-tests\"}" \
      >/dev/null || true
  fi

  docker compose stop "$SERVICE" </dev/null >/dev/null
  unset COURSE_FAILPOINT
  docker compose up -d --no-build </dev/null >/dev/null
  wait_ready

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
      PAYMENTS=$(provider_payment_count "$EXTERNAL_ID")
      if [[ "$PAYMENTS" != "1" ]]; then
        echo "provider paymentCount=${PAYMENTS} after ${fp}, expected 1" >&2
        exit 1
      fi
      ;;
    after_inbox_saved)
      INBOX_STATE=$(psql_query "SELECT state FROM autocheck.inbox WHERE message_id IN (SELECT message_id FROM autocheck.receipts WHERE external_request_id IN (SELECT external_request_id FROM autocheck.external_requests WHERE operation_id = '${OPERATION_ID}'::uuid))")
      if [[ "$INBOX_STATE" != "RECEIVED" && "$INBOX_STATE" != "APPLIED" ]]; then
        echo "unexpected inbox state '${INBOX_STATE}' after ${fp}" >&2
        exit 1
      fi
      ;;
    after_manual_decision)
      DECISIONS=$(psql_query "SELECT count(*) FROM autocheck.decisions WHERE process_id = (SELECT process_id FROM autocheck.operations WHERE operation_id = '${OPERATION_ID}'::uuid)")
      if [[ "$DECISIONS" != "1" ]]; then
        echo "expected exactly one manual decision after ${fp}, got ${DECISIONS}" >&2
        exit 1
      fi
      ;;
  esac

  echo "  ok"
done

echo "recovery tests passed"