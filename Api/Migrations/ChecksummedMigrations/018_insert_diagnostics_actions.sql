-- ============================================================
-- Миграция 018: Регистрация actions diagnostics.trace / diagnostics.stalled
-- ============================================================
--
-- Обычные HTTP-доступные read-only actions через тот же generic
-- action runtime (api.invoke), что workflow.get/payment.* — см.
-- 009_insert_workflow_action.sql. Требуют scope "diagnostics:read"
-- в JWT вызывающего. idempotency: none — оба чисто читающие,
-- повторный вызов безопасен без всякой дедупликации.
--
-- request_schema/response_schema здесь — ТОЧНЫЕ копии
-- contracts/course-1/diagnostics-trace.{payload,result}.schema.json
-- и contracts/course-1/diagnostics-stalled.{payload,result}.schema.json.
-- Checker валидирует payload/result по этим схемам буквально, любое
-- расхождение (даже семантически эквивалентное) ловится как
-- action.contract_violation.

-- ------------------------------------------------------------
-- 1. diagnostics.trace version 1
--    Payload: {"identifier": "<строка>"} — одно поле.
--    Result:  query + dispatches + operation/events + process/steps +
--             jobs/attempts + outbox/inbox + receipts/decisions.
-- ------------------------------------------------------------
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'diagnostics', 'trace', 1, 'POST', 'diagnostics', 'trace_query',
    '{
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "required": ["identifier"],
      "properties": {
        "identifier": {
          "type": "string",
          "minLength": 1,
          "maxLength": 200,
          "pattern": "^[^\\r\\n]+$"
        }
      },
      "additionalProperties": false
    }'::jsonb,
    '{
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "required": [
        "query", "dispatches", "operation", "operationEvents", "process",
        "steps", "jobs", "attempts", "outbox", "inbox", "receipts", "decisions"
      ],
      "properties": {
        "query": {
          "type": "object",
          "required": ["identifier", "matchedBy"],
          "properties": {
            "identifier": { "type": "string", "minLength": 1, "maxLength": 200 },
            "matchedBy": {
              "type": "array",
              "minItems": 1,
              "uniqueItems": true,
              "items": {
                "enum": [
                  "correlationId", "requestId", "operationId", "processId",
                  "stepInstanceId", "jobId", "executionId", "attemptId",
                  "externalRequestId", "messageId", "decisionId"
                ]
              }
            }
          },
          "additionalProperties": false
        },
        "dispatches": { "type": "array" },
        "operation": {
          "oneOf": [ {"type": "null"}, {"type": "object"} ]
        },
        "operationEvents": { "type": "array" },
        "process": {
          "oneOf": [ {"type": "null"}, {"type": "object"} ]
        },
        "steps": { "type": "array" },
        "jobs": { "type": "array" },
        "attempts": { "type": "array" },
        "outbox": { "type": "array" },
        "inbox": { "type": "array" },
        "receipts": { "type": "array" },
        "decisions": { "type": "array" }
      },
      "additionalProperties": false
    }'::jsonb,
    '["FOUND"]'::jsonb,
    '["diagnostics:read"]'::jsonb,
    'none', 'none', 5000, true, true
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

-- ------------------------------------------------------------
-- 2. diagnostics.stalled version 1
--    Payload: {} — без дополнительных полей.
--    Result:  {"items": [{"operationId","processId","externalRequestId"}, ...]}
-- ------------------------------------------------------------
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'diagnostics', 'stalled', 1, 'POST', 'diagnostics', 'stalled_query',
    '{
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "properties": {},
      "additionalProperties": false
    }'::jsonb,
    '{
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "required": ["items"],
      "properties": {
        "items": {
          "type": "array",
          "uniqueItems": true,
          "items": {
            "type": "object",
            "required": ["operationId", "processId", "externalRequestId"],
            "properties": {
              "operationId": { "type": "string", "format": "uuid" },
              "processId": { "type": "string", "format": "uuid" },
              "externalRequestId": {
                "type": "string",
                "minLength": 1,
                "maxLength": 200,
                "not": { "pattern": "[\\r\\n]" }
              }
            },
            "additionalProperties": false
          }
        }
      },
      "additionalProperties": false
    }'::jsonb,
    '["FOUND"]'::jsonb,
    '["diagnostics:read"]'::jsonb,
    'none', 'none', 5000, true, true
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