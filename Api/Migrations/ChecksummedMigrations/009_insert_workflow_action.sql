-- ============================================================
-- Миграция 009: Регистрация action workflow.get
-- ============================================================
--
-- Обычный HTTP-доступный action, как payment.request/operation.get —
-- вызывается внешним клиентом (или самим CLI/checker'ом) через
-- Gateway -> Api -> api.invoke -> workflow.get_process (создана в
-- 007_workflow_functions.sql). К роли workflow_worker и её
-- ограничениям на прямой DML отношения не имеет: это отдельный путь
-- чтения через обычный action runtime, требующий scope "workflow:read"
-- в JWT вызывающего, а не какого-либо доступа воркера.

INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'workflow', 'get', 1, 'POST', 'workflow', 'get_process',
    '{
  "type": "object",
  "additionalProperties": false,
  "required": ["processId"],
  "properties": {
    "processId": { "type": "string", "format": "uuid" }
  }
}'::jsonb,
    '{
  "oneOf": [
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["process", "steps", "jobs", "attempts"],
      "properties": {
        "process": { "type": "object" },
        "steps": { "type": "array" },
        "jobs": { "type": "array" },
        "attempts": { "type": "array" }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "maxProperties": 0
    }
  ]
}'::jsonb,
    '["FOUND", "NOT_FOUND"]'::jsonb,
    '["workflow:read"]'::jsonb,
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
