-- ============================================================
-- Миграция 003: Вставка встроенных actions
-- ============================================================

-- 1. payment.request version 1
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'request', 1, 'POST', 'course', 'payment_request',
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["operationKind", "amount", "currency"],
      "properties": {
        "operationKind": { "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"] },
        "amount": { "type": "string", "pattern": "^(?:0\\.0[1-9]|0\\.[1-9][0-9]?|[1-9][0-9]{0,15}(?:\\.[0-9]{1,2})?)$" },
        "currency": { "const": "RUB" }
      }
    }'::jsonb,
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["operationId", "requestId", "operationKind", "amount", "currency", "status"],
      "properties": {
        "operationId": { "type": "string", "format": "uuid" },
        "requestId": { "type": "string" },
        "operationKind": { "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"] },
        "amount": { "type": "string" },
        "currency": { "const": "RUB" },
        "status": { "enum": ["CREATED", "PROCESSING", "COMPLETED", "REJECTED"] }
      }
    }'::jsonb,
    '["CREATED"]'::jsonb,
    '["payment:write"]'::jsonb,
    'required', 'principal_action', 5000, true, true
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

-- 2. operation.get version 1
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'operation', 'get', 1, 'POST', 'course', 'operation_get',
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["operationId"],
      "properties": {
        "operationId": { "type": "string", "format": "uuid" }
      }
    }'::jsonb,
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["operationId", "requestId", "operationKind", "amount", "currency", "status"],
      "properties": {
        "operationId": { "type": "string", "format": "uuid" },
        "requestId": { "type": "string" },
        "operationKind": { "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"] },
        "amount": { "type": "string" },
        "currency": { "const": "RUB" },
        "status": { "enum": ["CREATED", "PROCESSING", "COMPLETED", "REJECTED"] }
      }
    }'::jsonb,
    '["FOUND"]'::jsonb,
    '["payment:read"]'::jsonb,
    'none', 'none', 5000, true, false
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

-- 3. workflow.get version 1
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
      "type": "object",
      "additionalProperties": false,
      "required": ["processId", "flowName", "flowVersion", "state", "currentStepKey"],
      "properties": {
        "processId": { "type": "string", "format": "uuid" },
        "flowName": { "type": "string" },
        "flowVersion": { "type": "integer" },
        "state": { "type": "string" },
        "currentStepKey": { "type": "string" }
      }
    }'::jsonb,
    '["FOUND"]'::jsonb,
    '["workflow:read"]'::jsonb,
    'none', 'none', 5000, true, false
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