-- ============================================================
-- Миграция 010: Идемпотентная тестовая PostgreSQL-экшен
-- training.canary — для workflow-smoke карт (недели 2)
-- ============================================================
--
-- Automatic-шаг workflow-карты не вызывает предметную функцию напрямую
-- и не содержит C#-handler — он лишь хранит module/action/action_version
-- и вызывается тем же shared executor'ом (api.invoke), что и обычные
-- HTTP-actions недели 1. Нужна собственная простая, идемпотентная
-- test-экшен — минимальный "эхо"-эффект без предметной сложности
-- (в отличие от payment.request/operation.get, которые для smoke-теста
-- workflow-движка избыточны и требуют предметного состояния).
--
-- Схема "training" — по аналогии с "opencheck" в 001_initial.sql:
-- отдельная, узкая, без пересечения с course/payment/opencheck.
CREATE SCHEMA IF NOT EXISTS training;

-- Идемпотентность эффекта: request_id (= executionId job'а, стабилен
-- между retry/reclaim одной и той же job) — первичный ключ. Повторный
-- вызов с тем же request_id — no-op на уровне эффекта, независимо от
-- того, сколько раз api.invoke был реально закоммичен (см. ADR 003).
CREATE TABLE IF NOT EXISTS training.canary_log (
    request_id  TEXT PRIMARY KEY,
    value       JSONB NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION training.canary(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = training, api, public, pg_catalog
AS $$
DECLARE
    v_request_id TEXT;
BEGIN
    v_request_id := p_context->>'requestId';

    IF v_request_id IS NULL OR v_request_id = '' THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Missing requestId in trusted context',
            'retryable', false
        );
    END IF;

    IF NOT (p_payload ? 'value') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Missing required field: value',
            'retryable', false
        );
    END IF;

    INSERT INTO training.canary_log (request_id, value)
    VALUES (v_request_id, p_payload->'value')
    ON CONFLICT (request_id) DO NOTHING;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', 'APPLIED',
        'result', jsonb_build_object(
            'requestId', v_request_id,
            'value', p_payload->'value'
        )
    );
END;
$$;

-- Владение переносим на course_owner сразу здесь же (а не отдельной
-- 005-миграцией, как для функций 002_functions.sql) — эта миграция
-- целиком применяется уже после 005_role_ownership_and_publication.sql,
-- так что можно не откладывать. course_owner получит USAGE на схему
-- "training" автоматически: она создаётся тем же подключением
-- (POSTGRES_USER), для которого 008_grant_gaps_from_public_report.sql
-- уже настроил "ALTER DEFAULT PRIVILEGES ... GRANT USAGE ON SCHEMAS".
ALTER TABLE training.canary_log OWNER TO course_owner;
ALTER FUNCTION training.canary(JSONB, JSONB) OWNER TO course_owner;

INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'training', 'canary', 1, 'POST', 'training', 'canary',
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["value"],
      "properties": {
        "value": {}
      }
    }'::jsonb,
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["requestId", "value"],
      "properties": {
        "requestId": { "type": "string" },
        "value": {}
      }
    }'::jsonb,
    '["APPLIED"]'::jsonb,
    '["workflow:execute"]'::jsonb,
    'none', 'none', 2000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema,
    target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema,
    response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes,
    required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode,
    idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms,
    enabled = EXCLUDED.enabled,
    is_default = EXCLUDED.is_default;
