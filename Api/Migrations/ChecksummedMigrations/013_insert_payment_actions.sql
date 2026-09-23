-- ============================================================
-- Миграция 013: регистрация payment-домена в course.action_catalog
-- ============================================================
--
-- Тот же паттерн, что 003_insert_actions.sql/009_insert_workflow_action.sql:
-- INSERT ... ON CONFLICT (module, action, version) DO UPDATE, чтобы
-- повторное применение миграции (или её редактирование до заморозки
-- MANIFEST.sha256) не падало на PRIMARY KEY.
--
-- required_policy и idempotency_mode/scope взяты дословно из
-- docs/04-week-3.md:
--   payment.submit   -> "payment:write",  Idempotency-Key обязателен
--   receipt.accept   -> "receipt:write",  idempotency mode required
--   workflow.manual  -> "workflow:manual", Idempotency-Key обязателен
--   payment.validate/prepare_external/apply_receipt/complete/reject/
--   check_limit/approve -> "payment:internal" (ровно как в task.action
--   каждого automatic-шага в payment-processing-v1.flow.yaml и
--   payment-review-v1.flow.yaml) — эти вызывает только worker с
--   trusted context (Scopes = job.RequiredPolicy), внешнему JWT scope
--   "payment:internal" никогда не выдаётся, поэтому "HTTP-доступность"
--   этих action ограничена не самим action_catalog, а тем, что такой
--   scope просто неоткуда взять — тем же способом, каким уже защищены
--   automatic-шаги недели 2.
--   idempotency_mode='none' для этих семи: worker всегда вызывает их с
--   useIdempotencyStore=false и своим executionId (Workflow.Worker/
--   StepRunner.cs), поэтому generic course.idempotency_records для них
--   не используется в принципе — 'required' здесь означало бы то же
--   самое поведение (idempotencyKey у worker'а всегда непустой), но
--   'none' точнее описывает факт "своего хранилища идемпотентности нет".
--   operation.events -> "payment:read" (тот же scope, что уже
--   зарегистрированный operation.get в 003_insert_actions.sql).

-- 1. payment.submit v1
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'submit', 1, 'POST', 'course', 'payment_submit',
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["operationId"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"}
      }
    }'::jsonb,
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["operationId", "processId", "flowName", "flowVersion", "status"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"},
        "processId": {"type": "string", "format": "uuid"},
        "flowName": {"enum": ["payment-processing", "payment-review"]},
        "flowVersion": {"type": "integer", "minimum": 1},
        "status": {"const": "PROCESSING"}
      }
    }'::jsonb,
    '["PROCESSING"]'::jsonb,
    '["payment:write"]'::jsonb,
    'required', 'principal_action', 5000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 2. operation.events v1
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'operation', 'events', 1, 'POST', 'course', 'operation_events',
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["operationId"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"}
      }
    }'::jsonb,
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["operationId", "events"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"},
        "events": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["eventId", "eventType", "payloadHash", "occurredAt"],
            "properties": {
              "eventId": {"type": "string", "format": "uuid"},
              "eventType": {"type": "string"},
              "payloadHash": {"type": "string"},
              "occurredAt": {"type": "string"}
            }
          }
        }
      }
    }'::jsonb,
    '["FOUND"]'::jsonb,
    '["payment:read"]'::jsonb,
    'none', 'none', 5000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 3. payment.validate v1 -> payment.validate_operation
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'validate', 1, 'POST', 'payment', 'validate_operation',
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId"],
      "properties": {"operationId": {"type": "string", "format": "uuid"}}
    }'::jsonb,
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId"],
      "properties": {"operationId": {"type": "string", "format": "uuid"}}
    }'::jsonb,
    '["VALID"]'::jsonb,
    '["payment:internal"]'::jsonb,
    'none', 'none', 2000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 4. payment.prepare_external v1 -> payment.prepare_external
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'prepare_external', 1, 'POST', 'payment', 'prepare_external',
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId"],
      "properties": {"operationId": {"type": "string", "format": "uuid"}}
    }'::jsonb,
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId", "externalRequestId"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"},
        "externalRequestId": {"type": "string"}
      }
    }'::jsonb,
    '["PREPARED"]'::jsonb,
    '["payment:internal"]'::jsonb,
    'none', 'none', 2000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 5. payment.apply_receipt v1 -> payment.apply_receipt
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'apply_receipt', 1, 'POST', 'payment', 'apply_receipt',
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId"],
      "properties": {"operationId": {"type": "string", "format": "uuid"}}
    }'::jsonb,
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId", "outcome"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"},
        "outcome": {"enum": ["COMPLETED", "REJECTED"]}
      }
    }'::jsonb,
    '["COMPLETED", "REJECTED"]'::jsonb,
    '["payment:internal"]'::jsonb,
    'none', 'none', 2000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 6. payment.complete v1 -> payment.complete_operation
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'complete', 1, 'POST', 'payment', 'complete_operation',
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId"],
      "properties": {"operationId": {"type": "string", "format": "uuid"}}
    }'::jsonb,
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId", "status"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"},
        "status": {"const": "COMPLETED"}
      }
    }'::jsonb,
    '["COMPLETED"]'::jsonb,
    '["payment:internal"]'::jsonb,
    'none', 'none', 2000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 7. payment.reject v1 -> payment.reject_operation (общий для обеих карт)
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'reject', 1, 'POST', 'payment', 'reject_operation',
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId"],
      "properties": {"operationId": {"type": "string", "format": "uuid"}}
    }'::jsonb,
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId", "status"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"},
        "status": {"const": "REJECTED"}
      }
    }'::jsonb,
    '["REJECTED"]'::jsonb,
    '["payment:internal"]'::jsonb,
    'none', 'none', 2000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 8. payment.check_limit v1 -> payment.check_limit
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'check_limit', 1, 'POST', 'payment', 'check_limit',
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId"],
      "properties": {"operationId": {"type": "string", "format": "uuid"}}
    }'::jsonb,
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId", "ruleVersion"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"},
        "ruleVersion": {"type": "string"}
      }
    }'::jsonb,
    '["WITHIN_LIMIT", "REVIEW_REQUIRED"]'::jsonb,
    '["payment:internal"]'::jsonb,
    'none', 'none', 2000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 9. payment.approve v1 -> payment.approve_operation
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'payment', 'approve', 1, 'POST', 'payment', 'approve_operation',
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId"],
      "properties": {"operationId": {"type": "string", "format": "uuid"}}
    }'::jsonb,
    '{
      "type": "object", "additionalProperties": false, "required": ["operationId", "status"],
      "properties": {
        "operationId": {"type": "string", "format": "uuid"},
        "status": {"const": "COMPLETED"}
      }
    }'::jsonb,
    '["APPROVED"]'::jsonb,
    '["payment:internal"]'::jsonb,
    'none', 'none', 2000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 10. receipt.accept v1 -> payment.receipt_accept
--     request_schema — ровно contracts/course-1/receipt-v1.schema.json
--     (то самое тело, которое Python receipt-adapter подписывает и
--     шлёт в generic API). response — messageId/externalRequestId/state
--     дословно по 04-week-3.md ("Успешный result содержит messageId,
--     externalRequestId и сохранённый state").
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'receipt', 'accept', 1, 'POST', 'payment', 'receipt_accept',
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["externalRequestId", "messageId", "occurredAt", "outcome", "providerPaymentId", "version"],
      "properties": {
        "externalRequestId": {"type": "string", "minLength": 1, "maxLength": 128, "not": {"pattern": "[\\r\\n]"}},
        "messageId": {"type": "string", "minLength": 1, "maxLength": 128, "not": {"pattern": "[\\r\\n]"}},
        "occurredAt": {"type": "string", "format": "date-time", "maxLength": 64, "pattern": "Z$", "not": {"pattern": "[\\r\\n]"}},
        "outcome": {"enum": ["COMPLETED", "REJECTED"]},
        "providerPaymentId": {"type": "string", "minLength": 1, "maxLength": 128, "not": {"pattern": "[\\r\\n]"}},
        "version": {"const": 1}
      }
    }'::jsonb,
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["messageId", "externalRequestId", "state"],
      "properties": {
        "messageId": {"type": "string"},
        "externalRequestId": {"type": "string"},
        "state": {"enum": ["RECEIVED", "APPLIED"]}
      }
    }'::jsonb,
    '["RECEIVED", "DUPLICATE"]'::jsonb,
    '["receipt:write"]'::jsonb,
    'required', 'principal_action', 5000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;

-- 11. workflow.manual v1 -> workflow.manual_decision
INSERT INTO course.action_catalog (
    module, action, version, http_method, target_schema, target_function,
    request_schema, response_schema, outcomes, required_policy,
    idempotency_mode, idempotency_scope, timeout_ms, enabled, is_default
) VALUES (
    'workflow', 'manual', 1, 'POST', 'workflow', 'manual_decision',
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["processId", "stepInstanceId", "decision", "reason"],
      "properties": {
        "processId": {"type": "string", "format": "uuid"},
        "stepInstanceId": {"type": "string", "format": "uuid"},
        "decision": {"enum": ["APPROVED", "REJECTED"]},
        "reason": {"type": "string", "minLength": 1, "maxLength": 500}
      }
    }'::jsonb,
    '{
      "type": "object",
      "additionalProperties": false,
      "required": ["decisionId", "processId", "stepInstanceId", "decision", "source", "principal"],
      "properties": {
        "decisionId": {"type": "string", "format": "uuid"},
        "processId": {"type": "string", "format": "uuid"},
        "stepInstanceId": {"type": "string", "format": "uuid"},
        "decision": {"enum": ["APPROVED", "REJECTED"]},
        "source": {"const": "MANUAL"},
        "principal": {"type": "string", "minLength": 1, "maxLength": 128}
      }
    }'::jsonb,
    '["APPROVED", "REJECTED"]'::jsonb,
    '["workflow:manual"]'::jsonb,
    'required', 'principal_action', 5000, true, true
)
ON CONFLICT (module, action, version) DO UPDATE SET
    target_schema = EXCLUDED.target_schema, target_function = EXCLUDED.target_function,
    request_schema = EXCLUDED.request_schema, response_schema = EXCLUDED.response_schema,
    outcomes = EXCLUDED.outcomes, required_policy = EXCLUDED.required_policy,
    idempotency_mode = EXCLUDED.idempotency_mode, idempotency_scope = EXCLUDED.idempotency_scope,
    timeout_ms = EXCLUDED.timeout_ms, enabled = EXCLUDED.enabled, is_default = EXCLUDED.is_default;
