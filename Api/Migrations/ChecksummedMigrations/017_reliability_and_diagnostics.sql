-- ============================================================
-- Миграция 017: Неделя 4 — надёжность + диагностика.
-- ============================================================
--
-- Часть A (правки фидбэка недели 3, Api/Migrations уже применены и
-- заморожены чексуммой — правим через CREATE OR REPLACE в НОВОМ файле,
-- а не редактируем 011/012):
--   A1. delivery.record_inbox — дедупликация по exact body_hash, а не
--       по JSONB-равенству body (фидбэк: "Duplicate receipt сравнивается
--       по JSONB, а не exact body hash").
--   A2. delivery.outbox — колонка dead_at (диагностика исчерпания).
--   A3. delivery.fail_outbox — test-profile retry: 4 attempts (было 3),
--       delays 200/400/800мс + jitter 0..100мс, dead_at при DEAD.
--
-- Часть B (неделя 4, новое):
--   B1. autocheck.jobs / autocheck.outbox — добавлены created_at/dead_at
--       (аддитивно, CREATE OR REPLACE VIEW с лишними колонками в конце —
--       не ломает уже выданные GRANT SELECT на эти view).
--   B2. Схема diagnostics: diagnostics.trace (action) и
--       diagnostics.stalled (action) — обе читающие, без DML.
--       Payload — {"identifier": "<строка>"} (см. 018, контракт
--       contracts/course-1/diagnostics-trace.payload.schema.json),
--       result — 12 полей включая query, dispatches, receipts.

-- ============================================================
-- A1. Exact-byte body_hash вместо JSONB-равенства.
-- ============================================================
CREATE OR REPLACE FUNCTION delivery.record_inbox(
    p_message_id TEXT,
    p_external_request_id TEXT,
    p_process_id UUID,
    p_signal_type TEXT,
    p_body JSONB,
    p_outcome TEXT,
    p_message_version INTEGER,
    p_signature_valid BOOLEAN,
    p_body_hash TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = delivery, public, pg_catalog
AS $$
DECLARE
    v_existing delivery.inbox%ROWTYPE;
BEGIN
    SELECT * INTO v_existing FROM delivery.inbox WHERE message_id = p_message_id FOR UPDATE;

    IF FOUND THEN
        IF v_existing.body_hash = p_body_hash THEN
            RETURN jsonb_build_object(
                'status', 'ok', 'outcome', 'DUPLICATE',
                'messageId', p_message_id, 'state', v_existing.state
            );
        END IF;

        RETURN jsonb_build_object(
            'status', 'error', 'code', 'idempotency.conflict',
            'message', 'messageId already used with a different body'
        );
    END IF;

    INSERT INTO delivery.inbox (
        message_id, external_request_id, process_id, signal_type, body, body_hash,
        outcome, message_version, signature_valid, state
       ) VALUES (
        p_message_id, p_external_request_id, p_process_id, p_signal_type, p_body, p_body_hash,
        p_outcome, p_message_version, p_signature_valid, 'RECEIVED'
    );

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'RECEIVED',
        'messageId', p_message_id, 'state', 'RECEIVED'
    );
END;
$$;

ALTER FUNCTION delivery.record_inbox(TEXT, TEXT, UUID, TEXT, JSONB, TEXT, INTEGER, BOOLEAN, TEXT) OWNER TO course_owner;

COMMENT ON FUNCTION delivery.record_inbox(TEXT, TEXT, UUID, TEXT, JSONB, TEXT, INTEGER, BOOLEAN, TEXT) IS
    'internal: идемпотентная запись Inbox — DUPLICATE при точном совпадении body_hash (exact-byte), idempotency.conflict при отличии.';

-- ============================================================
-- A2. delivery.outbox.dead_at — диагностика исчерпания попыток.
-- ============================================================
ALTER TABLE delivery.outbox ADD COLUMN IF NOT EXISTS dead_at TIMESTAMPTZ;

COMMENT ON COLUMN delivery.outbox.dead_at IS
    'Момент перехода в DEAD (терминальная ошибка доставки ИЛИ исчерпаны попытки). '
    'НЕ означает, что предметный платёж отклонён — DEAD отвечает только за Outbox-доставку; '
    'поздний валидный receipt всё ещё может перевести operation в CONFIRMED (см. payment.apply_receipt).';

-- ============================================================
-- A3. delivery.fail_outbox — test profile: 4 attempts (1 первая +
--     3 retry), базовые задержки 200/400/800мс + jitter 0..100мс,
--     dead_at проставляется при переходе в DEAD.
-- ============================================================
CREATE OR REPLACE FUNCTION delivery.fail_outbox(
    p_outbox_id UUID,
    p_owner TEXT,
    p_lease_version BIGINT,
    p_error_code TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = delivery, public, pg_catalog
AS $$
DECLARE
    v_row delivery.outbox%ROWTYPE;
    v_retryable BOOLEAN;
    v_max_attempts CONSTANT INTEGER := 4;
    v_delays_ms CONSTANT INTEGER[] := ARRAY[200, 400, 800];
    v_base_delay_ms INTEGER;
    v_jitter_ms INTEGER;
BEGIN
    SELECT * INTO v_row FROM delivery.outbox WHERE outbox_id = p_outbox_id FOR UPDATE;

    IF NOT FOUND
       OR v_row.lease_owner IS DISTINCT FROM p_owner
       OR v_row.lease_version <> p_lease_version
       OR v_row.state <> 'LEASED' THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'delivery.lease_stale',
            'message', 'outbox row not found, or owner/leaseVersion/state no longer match'
        );
    END IF;

    v_retryable := p_error_code LIKE '%.retryable';

    IF (NOT v_retryable) OR (v_row.attempt_count + 1 >= v_max_attempts) THEN
        UPDATE delivery.outbox
        SET state = 'DEAD',
            attempt_count = attempt_count + 1,
            last_error_code = p_error_code,
            next_attempt_at = NULL,
            dead_at = now()
        WHERE outbox_id = p_outbox_id;

        RETURN jsonb_build_object('status', 'ok', 'outboxState', 'DEAD', 'errorCode', p_error_code);
    END IF;

    v_base_delay_ms := v_delays_ms[LEAST(v_row.attempt_count + 1, array_length(v_delays_ms, 1))];
    v_jitter_ms := floor(random() * 100)::INTEGER;

    UPDATE delivery.outbox
    SET state = 'RETRY_WAIT',
        attempt_count = attempt_count + 1,
        last_error_code = p_error_code,
        next_attempt_at = now() + ((v_base_delay_ms + v_jitter_ms) || ' milliseconds')::interval
    WHERE outbox_id = p_outbox_id;

    RETURN jsonb_build_object(
        'status', 'ok', 'outboxState', 'RETRY_WAIT',
        'nextAttemptDelayMs', v_base_delay_ms + v_jitter_ms, 'errorCode', p_error_code
    );
END;
$$;

ALTER FUNCTION delivery.fail_outbox(UUID, TEXT, BIGINT, TEXT) OWNER TO course_owner;

-- ============================================================
-- B1. autocheck.jobs / autocheck.outbox — аддитивные колонки.
-- ============================================================
CREATE OR REPLACE VIEW autocheck.jobs AS
SELECT
    job_id,
    process_id,
    step_instance_id,
    execution_id,
    state,
    lease_owner,
    lease_version,
    lease_until,
    attempt_count,
    next_attempt_at,
    created_at
FROM workflow.workflow_job;

ALTER VIEW autocheck.jobs OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.outbox AS
SELECT
    outbox_id,
    external_request_id,
    state,
    attempt_count,
    next_attempt_at,
    last_error_code,
    created_at,
    delivered_at,
    dead_at
FROM delivery.outbox;

ALTER VIEW autocheck.outbox OWNER TO course_owner;

-- ============================================================
-- B2. Схема diagnostics — только чтение, без DML.
-- ============================================================
CREATE SCHEMA IF NOT EXISTS diagnostics;
ALTER SCHEMA diagnostics OWNER TO course_owner;

-- ------------------------------------------------------------
-- diagnostics.trace — принимает {"identifier": "<строка>"},
-- резолвит к operationId, возвращает 12 полей согласно
-- contracts/course-1/diagnostics-trace.result.schema.json.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION diagnostics.trace_query(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = diagnostics, delivery, workflow, payment, course, public, pg_catalog
AS $$
DECLARE
    v_id TEXT;
    v_operation_id UUID;
    v_process_id UUID;
    v_uuid UUID;
    v_correlation_id UUID;
    v_matched_by TEXT[] := ARRAY[]::TEXT[];
    v_operation JSONB;
    v_events JSONB;
    v_dispatches JSONB;
    v_process JSONB;
    v_steps JSONB;
    v_jobs JSONB;
    v_attempts JSONB;
    v_outbox JSONB;
    v_inbox JSONB;
    v_receipts JSONB;
    v_decisions JSONB;
BEGIN
    v_id := p_payload->>'identifier';

    IF v_id IS NULL OR length(trim(v_id)) = 0 THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'payload.invalid',
            'message', 'identifier is required', 'retryable', false
        );
    END IF;

    BEGIN
        v_uuid := v_id::UUID;
    EXCEPTION WHEN OTHERS THEN
        v_uuid := NULL;
    END;

    -- Резолв identifier к operationId. Порядок: от самого специфичного
    -- к общему. Для каждого случая заполняем matchedBy.
    IF v_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM course.operations WHERE operation_id = v_uuid) THEN
        v_operation_id := v_uuid;
        v_matched_by := ARRAY['operationId'];

    ELSIF v_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM workflow.process_instance WHERE process_id = v_uuid) THEN
        SELECT operation_id INTO v_operation_id FROM course.operations WHERE process_id = v_uuid LIMIT 1;
        v_matched_by := ARRAY['processId'];

    ELSIF v_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM delivery.outbox WHERE outbox_id = v_uuid) THEN
        SELECT operation_id, correlation_id INTO v_operation_id, v_correlation_id
        FROM delivery.outbox WHERE outbox_id = v_uuid;
        v_matched_by := ARRAY['operationId'];

    ELSIF v_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM delivery.outbox WHERE correlation_id = v_uuid) THEN
        SELECT operation_id INTO v_operation_id FROM delivery.outbox WHERE correlation_id = v_uuid LIMIT 1;
        v_correlation_id := v_uuid;
        v_matched_by := ARRAY['correlationId'];

    ELSIF EXISTS (SELECT 1 FROM delivery.outbox WHERE external_request_id = v_id) THEN
        SELECT operation_id, correlation_id INTO v_operation_id, v_correlation_id
        FROM delivery.outbox WHERE external_request_id = v_id LIMIT 1;
        v_matched_by := ARRAY['externalRequestId'];

    ELSIF EXISTS (SELECT 1 FROM delivery.outbox WHERE provider_payment_id = v_id) THEN
        SELECT operation_id, correlation_id INTO v_operation_id, v_correlation_id
        FROM delivery.outbox WHERE provider_payment_id = v_id LIMIT 1;
        v_matched_by := ARRAY['operationId'];

    ELSIF EXISTS (SELECT 1 FROM delivery.inbox WHERE message_id = v_id) THEN
        SELECT o.operation_id, o.correlation_id INTO v_operation_id, v_correlation_id
        FROM delivery.inbox i
        JOIN delivery.outbox o ON o.external_request_id = i.external_request_id
        WHERE i.message_id = v_id LIMIT 1;
        v_matched_by := ARRAY['messageId'];

    ELSIF v_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM workflow.workflow_job WHERE execution_id = v_uuid) THEN
        SELECT op.operation_id INTO v_operation_id
        FROM workflow.workflow_job j JOIN course.operations op ON op.process_id = j.process_id
        WHERE j.execution_id = v_uuid LIMIT 1;
        v_matched_by := ARRAY['executionId'];

    ELSIF v_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM workflow.workflow_job WHERE job_id = v_uuid) THEN
        SELECT op.operation_id INTO v_operation_id
        FROM workflow.workflow_job j JOIN course.operations op ON op.process_id = j.process_id
        WHERE j.job_id = v_uuid LIMIT 1;
        v_matched_by := ARRAY['jobId'];

    ELSIF v_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM workflow.task_attempt WHERE attempt_id = v_uuid) THEN
        SELECT op.operation_id INTO v_operation_id
        FROM workflow.task_attempt ta
        JOIN workflow.workflow_job j ON j.job_id = ta.job_id
        JOIN course.operations op ON op.process_id = j.process_id
        WHERE ta.attempt_id = v_uuid LIMIT 1;
        v_matched_by := ARRAY['attemptId'];

    ELSIF v_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM payment.decision WHERE decision_id = v_uuid) THEN
        SELECT op.operation_id INTO v_operation_id
        FROM payment.decision d JOIN course.operations op ON op.process_id = d.process_id
        WHERE d.decision_id = v_uuid LIMIT 1;
        v_matched_by := ARRAY['decisionId'];

    ELSIF EXISTS (SELECT 1 FROM course.operations WHERE request_id = v_id) THEN
        SELECT operation_id INTO v_operation_id FROM course.operations WHERE request_id = v_id LIMIT 1;
        v_matched_by := ARRAY['requestId'];
    END IF;

    IF v_operation_id IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'diagnostics.trace_not_found',
            'message', 'no operation matches the given identifier'
        );
    END IF;

    -- operation
    SELECT jsonb_build_object(
        'operationId', op.operation_id, 'requestId', op.request_id, 'operationKind', op.operation_kind,
        'amount', op.amount::TEXT, 'currency', op.currency, 'status', op.status,
        'processId', op.process_id,
        'createdAt', to_char(op.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'updatedAt', to_char(op.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    ) INTO v_operation
    FROM course.operations op WHERE op.operation_id = v_operation_id;

    -- operationEvents
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'eventId', oe.event_id,
        'eventType', oe.event_type,
        'occurredAt', to_char(oe.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    ) ORDER BY oe.occurred_at), '[]'::jsonb) INTO v_events
    FROM course.operation_events oe WHERE oe.operation_id = v_operation_id;

    -- dispatches — по correlation_id операции (если знаем) либо по request_id.
    -- Контракт допускает пустой массив; заполняем по максимуму.
    IF v_correlation_id IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'correlationId', ad.correlation_id,
            'requestId', ad.request_id,
            'module', ad.module,
            'action', ad.action,
            'version', ad.version,
            'status', ad.status,
            'outcome', ad.outcome,
            'occurredAt', to_char(ad.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ) ORDER BY ad.occurred_at), '[]'::jsonb) INTO v_dispatches
        FROM course.action_dispatches ad WHERE ad.correlation_id = v_correlation_id;
    ELSE
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'correlationId', ad.correlation_id,
            'requestId', ad.request_id,
            'module', ad.module,
            'action', ad.action,
            'version', ad.version,
            'status', ad.status,
            'outcome', ad.outcome,
            'occurredAt', to_char(ad.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ) ORDER BY ad.occurred_at), '[]'::jsonb) INTO v_dispatches
        FROM course.action_dispatches ad
        WHERE ad.request_id IS NOT NULL
          AND ad.request_id = (SELECT request_id FROM course.operations WHERE operation_id = v_operation_id);
    END IF;

    SELECT process_id INTO v_process_id FROM course.operations WHERE operation_id = v_operation_id;

    IF v_process_id IS NOT NULL THEN
        SELECT jsonb_build_object(
            'processId', pi.process_id, 'flowName', pi.flow_name, 'flowVersion', pi.flow_version,
            'state', pi.state, 'currentStepKey', pi.current_step_key,
            'createdAt', to_char(pi.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'updatedAt', to_char(pi.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ) INTO v_process
        FROM workflow.process_instance pi WHERE pi.process_id = v_process_id;

        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'stepInstanceId', si.step_instance_id, 'stepKey', si.step_key, 'stepType', si.step_type,
            'state', si.state, 'outcome', si.outcome,
            'enteredAt', to_char(si.entered_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'completedAt', CASE WHEN si.completed_at IS NULL THEN NULL
                ELSE to_char(si.completed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END
        ) ORDER BY si.entered_at), '[]'::jsonb) INTO v_steps
        FROM workflow.step_instance si WHERE si.process_id = v_process_id;

        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'jobId', j.job_id, 'stepInstanceId', j.step_instance_id, 'executionId', j.execution_id,
            'state', j.state, 'leaseVersion', j.lease_version,
            'attemptCount', j.attempt_count,
            'nextAttemptAt', CASE WHEN j.next_attempt_at IS NULL THEN NULL
                ELSE to_char(j.next_attempt_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END
        ) ORDER BY j.created_at), '[]'::jsonb) INTO v_jobs
        FROM workflow.workflow_job j WHERE j.process_id = v_process_id;

        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'attemptId', ta.attempt_id, 'jobId', ta.job_id, 'executionId', ta.execution_id,
            'leaseVersion', ta.lease_version, 'attemptNumber', ta.attempt_number,
            'status', ta.status, 'outcome', ta.outcome, 'errorCode', ta.error_code,
            'startedAt', to_char(ta.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'finishedAt', CASE WHEN ta.finished_at IS NULL THEN NULL
                ELSE to_char(ta.finished_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END
        ) ORDER BY ta.started_at), '[]'::jsonb) INTO v_attempts
        FROM workflow.task_attempt ta
        JOIN workflow.workflow_job j ON j.job_id = ta.job_id
        WHERE j.process_id = v_process_id;

        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'decisionId', d.decision_id, 'stepInstanceId', d.step_instance_id,
            'source', d.source, 'principal', d.principal,
            'outcome', d.outcome, 'ruleVersion', d.rule_version,
            'createdAt', to_char(d.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ) ORDER BY d.created_at), '[]'::jsonb) INTO v_decisions
        FROM payment.decision d WHERE d.process_id = v_process_id;
    ELSE
        v_process := 'null'::jsonb;
        v_steps := '[]'::jsonb;
        v_jobs := '[]'::jsonb;
        v_attempts := '[]'::jsonb;
        v_decisions := '[]'::jsonb;
    END IF;

    -- outbox
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'outboxId', o.outbox_id, 'externalRequestId', o.external_request_id, 'state', o.state,
        'attemptCount', o.attempt_count, 'leaseVersion', o.lease_version,
        'nextAttemptAt', CASE WHEN o.next_attempt_at IS NULL THEN NULL
            ELSE to_char(o.next_attempt_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END,
        'lastErrorCode', o.last_error_code,
        'createdAt', to_char(o.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'deliveredAt', CASE WHEN o.delivered_at IS NULL THEN NULL
            ELSE to_char(o.delivered_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END,
        'deadAt', CASE WHEN o.dead_at IS NULL THEN NULL
            ELSE to_char(o.dead_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END
    ) ORDER BY o.created_at), '[]'::jsonb) INTO v_outbox
    FROM delivery.outbox o WHERE o.operation_id = v_operation_id;

    -- inbox
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'messageId', i.message_id,
        'state', CASE WHEN i.state = 'RECEIVED' THEN 'RECEIVED'
                      WHEN i.state = 'APPLIED' THEN 'APPLIED'
                      ELSE 'CONFLICT' END,
        'receivedAt', to_char(i.received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'appliedAt', CASE WHEN i.applied_at IS NULL THEN NULL
            ELSE to_char(i.applied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END
    ) ORDER BY i.received_at), '[]'::jsonb) INTO v_inbox
    FROM delivery.inbox i
    JOIN delivery.outbox o ON o.external_request_id = i.external_request_id
    WHERE o.operation_id = v_operation_id;

    -- receipts — только applied + signature_valid
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'messageId', i.message_id, 'externalRequestId', i.external_request_id,
        'outcome', i.outcome,
        'signatureValid', i.signature_valid,
        'receivedAt', to_char(i.received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'appliedAt', CASE WHEN i.applied_at IS NULL THEN NULL
            ELSE to_char(i.applied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END
    ) ORDER BY i.received_at), '[]'::jsonb) INTO v_receipts
    FROM delivery.inbox i
    JOIN delivery.outbox o ON o.external_request_id = i.external_request_id
    WHERE o.operation_id = v_operation_id
      AND i.outcome IS NOT NULL
      AND i.signature_valid = TRUE;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', 'FOUND',
        'result', jsonb_build_object(
            'query', jsonb_build_object(
                'identifier', v_id,
                'matchedBy', to_jsonb(v_matched_by)
            ),
            'dispatches', COALESCE(v_dispatches, '[]'::jsonb),
            'operation', COALESCE(v_operation, 'null'::jsonb),
            'operationEvents', COALESCE(v_events, '[]'::jsonb),
            'process', COALESCE(v_process, 'null'::jsonb),
            'steps', COALESCE(v_steps, '[]'::jsonb),
            'jobs', COALESCE(v_jobs, '[]'::jsonb),
            'attempts', COALESCE(v_attempts, '[]'::jsonb),
            'outbox', COALESCE(v_outbox, '[]'::jsonb),
            'inbox', COALESCE(v_inbox, '[]'::jsonb),
            'receipts', COALESCE(v_receipts, '[]'::jsonb),
            'decisions', COALESCE(v_decisions, '[]'::jsonb)
        )
    );
END;
$$;

ALTER FUNCTION diagnostics.trace_query(JSONB, JSONB) OWNER TO course_owner;

-- ------------------------------------------------------------
-- diagnostics.stalled — операции, где Outbox delivery уже DEAD
-- (все попытки исчерпаны), а receipt так и не пришёл.
-- processId обязателен по contracts/course-1/diagnostics-stalled.result.schema.json,
-- поэтому INNER JOIN course.operations и отбрасывание операций без process_id.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION diagnostics.stalled_query(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = diagnostics, delivery, course, public, pg_catalog
AS $$
DECLARE
    v_items JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'operationId', o.operation_id,
        'processId', op.process_id,
        'externalRequestId', o.external_request_id
    ) ORDER BY o.operation_id), '[]'::jsonb) INTO v_items
    FROM delivery.outbox o
    LEFT JOIN delivery.inbox i ON i.external_request_id = o.external_request_id
    INNER JOIN course.operations op ON op.operation_id = o.operation_id
    WHERE o.state = 'DEAD'
      AND i.message_id IS NULL
      AND op.process_id IS NOT NULL;

    RETURN jsonb_build_object('status', 'ok', 'outcome', 'FOUND', 'result', jsonb_build_object('items', v_items));
END;
$$;

ALTER FUNCTION diagnostics.stalled_query(JSONB, JSONB) OWNER TO course_owner;

-- ------------------------------------------------------------
-- Defense-in-depth
-- ------------------------------------------------------------
SET ROLE course_owner;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA diagnostics FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA diagnostics REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
RESET ROLE;