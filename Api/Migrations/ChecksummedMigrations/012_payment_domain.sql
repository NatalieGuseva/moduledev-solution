-- ============================================================
-- Миграция 012: Payment-домен — все target-функции для
-- payment-processing и payment-review (04-week-3.md, "Обязательные
-- actions"). Регистрация в course.action_catalog — в отдельной
-- 013_insert_payment_actions.sql, после того как сами функции
-- здесь уже существуют.
-- ============================================================
--
-- Соглашение об именах: module.action (как в HTTP/workflow-карте) не
-- обязан совпадать с target_schema.target_function — ровно как
-- payment.request уже маппится на course.payment_request. Здесь:
--   payment.submit          -> course.payment_submit    (пересекает course+workflow)
--   operation.events        -> course.operation_events  (рядом с course.operation_get)
--   payment.validate        -> payment.validate_operation
--   payment.prepare_external-> payment.prepare_external
--   payment.apply_receipt   -> payment.apply_receipt
--   payment.complete        -> payment.complete_operation
--   payment.reject          -> payment.reject_operation   (общий для обеих карт)
--   payment.check_limit     -> payment.check_limit
--   payment.approve         -> payment.approve_operation
--   receipt.accept          -> payment.receipt_accept
--   workflow.manual         -> workflow.manual_decision

-- ============================================================
-- 0. Точечные правки уже сданных 010/011: добавляем то, что стало
--    нужно только сейчас, когда появился реальный вызывающий код —
--    новые файлы не создаём, чтобы не дублировать схему/роли.
-- ============================================================

-- 0.1 delivery.inbox: недостающие колонки под autocheck.receipts
--     (message_version, signature_valid) — их некому было заполнить
--     до появления receipt.accept.
ALTER TABLE delivery.inbox ADD COLUMN message_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE delivery.inbox ADD COLUMN signature_valid BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE delivery.inbox ALTER COLUMN message_version DROP DEFAULT;
ALTER TABLE delivery.inbox ALTER COLUMN signature_valid DROP DEFAULT;

DROP FUNCTION IF EXISTS delivery.record_inbox(TEXT, TEXT, UUID, TEXT, JSONB, TEXT, TEXT);
DROP FUNCTION IF EXISTS delivery.record_inbox(TEXT, TEXT, UUID, TEXT, JSONB, TEXT, INTEGER, BOOLEAN);

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
    -- p_body_hash — exact SHA-256 hex от raw HTTP body bytes, посчитанный
    -- ProviderSignatureMiddleware (RawBodyHash в TransportContext) и
    -- проброшенный через p_context.transport.rawBodyHash. Единственный
    -- источник body_hash, совпадающий с canonical receipt bytes
    -- (compact sorted JSON, json.dumps(sort_keys=True, separators=(',',':'),
    -- ensure_ascii=False)). Postgres НЕ может восстановить такие байты
    -- из p_body::TEXT: JSONB сортирует ключи по длине, потом по алфавиту,
    -- а canonical receipt — чисто по алфавиту. Дедупликация ниже
    -- по-прежнему сравнивает САМ p_body (JSONB), а не хэш — хэш нужен
    -- только для аудита и сравнения с canonical bytes на стороне чекера.

    SELECT * INTO v_existing FROM delivery.inbox WHERE message_id = p_message_id FOR UPDATE;

    IF FOUND THEN
        IF v_existing.body = p_body THEN
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
    'internal: идемпотентная запись Inbox из payment.receipt_accept — DUPLICATE при JSONB-равенстве body, idempotency.conflict при отличии; body_hash берётся из p_body_hash (exact SHA-256 от raw HTTP bytes, посчитанный ProviderSignatureMiddleware).';



-- 0.3 payment.decision — аудит авто/ручного решения payment-review.
--     Таблицы раньше не было ни в одном применённом файле (010/011
--     создавали только delivery.outbox/inbox) — обнаружилось только при
--     реальном прогоне этой миграции: следующая строка (ADD CONSTRAINT)
--     падала с "relation payment.decision does not exist". Создаём её
--     здесь, а не отдельным файлом — по той же причине, что 0.1/0.2 выше.
--     UNIQUE(step_instance_id) сразу в CREATE TABLE — это и есть
--     идемпотентность payment.check_limit/workflow.manual_decision на
--     повторный вызов с тем же шагом, отдельный ALTER TABLE не нужен.
CREATE TABLE payment.decision (
    decision_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id UUID NOT NULL REFERENCES workflow.process_instance(process_id),
    step_instance_id UUID NOT NULL UNIQUE REFERENCES workflow.step_instance(step_instance_id),
    source TEXT NOT NULL CHECK (source IN ('LIMIT_RULE', 'MANUAL')),
    principal TEXT NOT NULL,
    reason_hash TEXT,
    outcome TEXT NOT NULL CHECK (outcome IN ('APPROVED', 'REJECTED')),
    rule_version TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE payment.decision OWNER TO course_owner;
COMMENT ON TABLE payment.decision IS 'Аудит авто/ручного решения payment-review (payment.check_limit/payment.approve/workflow.manual_decision)';

-- ============================================================
-- 1. course.payment_submit — payment.submit v1.
--    business_key = operationId::text — это и есть требуемая пиновка:
--    workflow.start_process уже реализует "тот же business_key + тот
--    же process_data -> тот же существующий process, другой
--    process_data -> conflict" (008_workflow_lifecycle.sql). Здесь
--    process_data детерминирован от operationId, поэтому конфликтов
--    в реальности не бывает — просто переиспользуем готовую пиновку,
--    а не пишем её здесь второй раз.
--    Идентичный Idempotency-Key с другим телом ловится ДО этой функции
--    generic API-слоем (course.idempotency_records, ActionExecutor.cs) —
--    "Изменённый body с тем же idempotency key" сюда вообще не доходит.
-- ============================================================
CREATE OR REPLACE FUNCTION course.payment_submit(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = course, workflow, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_operation course.operations%ROWTYPE;
    v_flow_name TEXT;
    v_process_data JSONB;
    v_start_result JSONB;
    v_process_id UUID;
    v_flow_version INTEGER;
    v_payload_hash TEXT;
    v_rows INTEGER;
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;
    v_payload_hash := ENCODE(DIGEST(p_payload::TEXT, 'sha256'), 'hex');

    SELECT * INTO v_operation FROM course.operations WHERE operation_id = v_operation_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'operation.not_found',
            'message', 'operation not found', 'retryable', false
        );
    END IF;

    v_flow_name := CASE v_operation.operation_kind
        WHEN 'PAYMENT_EXECUTION' THEN 'payment-processing'
        WHEN 'PAYMENT_APPROVAL' THEN 'payment-review'
        ELSE NULL
    END;

    IF v_flow_name IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'internal.error',
            'message', 'unknown operationKind, no flow binding', 'retryable', false
        );
    END IF;

    v_process_data := jsonb_build_object('operationId', v_operation_id::TEXT);
    v_start_result := workflow.start_process(v_flow_name, v_operation_id::TEXT, v_process_data);

    IF v_start_result->>'status' <> 'ok' THEN
        RETURN v_start_result;
    END IF;

    v_process_id := (v_start_result->>'processId')::UUID;
    -- flowVersion — тот, что реально вернул start_process (закреплённый
    -- на существующем процессе при replay), а НЕ активная версия карты
    -- на момент вызова — это и даёт "закреплённые processId/flowVersion
    -- даже после смены default flow version".
    v_flow_version := (v_start_result->>'flowVersion')::INTEGER;

    UPDATE course.operations
    SET status = 'PROCESSING', process_id = v_process_id, updated_at = now()
    WHERE operation_id = v_operation_id AND status = 'CREATED';
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows > 0 THEN
        INSERT INTO course.operation_events (operation_id, event_type, payload_hash)
        VALUES (v_operation_id, 'OPERATION_SUBMITTED', v_payload_hash);
    END IF;

    -- status здесь — литерал контракта ("успешный submit -> PROCESSING"),
    -- а не текущее состояние operation, которое к моменту повторного
    -- submit может уже уйти вперёд (external-contracts.md, "Повтор
    -- payment.submit").
    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'PROCESSING',
        'result', jsonb_build_object(
            'operationId', v_operation_id,
            'processId', v_process_id,
            'flowName', v_flow_name,
            'flowVersion', v_flow_version,
            'status', 'PROCESSING'
        )
    );
END;
$$;

-- ============================================================
-- 2. course.operation_events — operation.events v1. Читает append-only
--    журнал операции; аналог course.operation_get, но со списком событий.
-- ============================================================
CREATE OR REPLACE FUNCTION course.operation_events(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = course, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_exists BOOLEAN;
    v_events JSONB;
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;

    SELECT EXISTS(SELECT 1 FROM course.operations WHERE operation_id = v_operation_id) INTO v_exists;
    IF NOT v_exists THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'operation.not_found',
            'message', 'operation not found', 'retryable', false
        );
    END IF;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'eventId', event_id, 'eventType', event_type,
            'payloadHash', payload_hash, 'occurredAt', occurred_at
        ) ORDER BY occurred_at
    ), '[]'::jsonb) INTO v_events
    FROM course.operation_events WHERE operation_id = v_operation_id;

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'FOUND',
        'result', jsonb_build_object('operationId', v_operation_id, 'events', v_events)
    );
END;
$$;

-- ============================================================
-- 3. payment.validate_operation — payment.validate v1 (первый
--    automatic шаг обеих карт). Операция обязана существовать —
--    её создал payment_request, а payment_submit уже запустил
--    процесс над ней; отсутствие означает дефект вызова, а не
--    ожидаемую ветку, поэтому RAISE EXCEPTION, а не 'ok'/'error'
--    (тот же приём, что workflow.apply_signal для "не должно
--    происходить, но не проглатываем тихо").
-- ============================================================
CREATE OR REPLACE FUNCTION payment.validate_operation(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = payment, course, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_exists BOOLEAN;
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;

    SELECT EXISTS(SELECT 1 FROM course.operations WHERE operation_id = v_operation_id) INTO v_exists;
    IF NOT v_exists THEN
        RAISE EXCEPTION 'payment.validate_operation: operation % not found — should have been created before payment.submit', v_operation_id;
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'VALID',
        'result', jsonb_build_object('operationId', v_operation_id)
    );
END;
$$;

-- ============================================================
-- 4. payment.prepare_external — payment.prepare_external v1.
--    externalRequestId = operationId::text — детерминированно, без
--    какого-либо доп. состояния. Это и есть "все retries job
--    используют один executionId, поэтому создаётся один external
--    request": каждый повтор (тот же executionId, новая попытка job)
--    вычисляет ТОТ ЖЕ externalRequestId, а delivery.enqueue_outbox
--    идемпотентен по нему (ON CONFLICT DO NOTHING + SELECT существующей
--    строки, см. 011_delivery_functions.sql).
-- ============================================================
CREATE OR REPLACE FUNCTION payment.prepare_external(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = payment, delivery, course, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_amount NUMERIC(19,2);
    v_currency TEXT;
    v_external_request_id TEXT;
    v_correlation_id UUID;
    v_payload_hash TEXT;
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;

    SELECT amount, currency INTO v_amount, v_currency
    FROM course.operations WHERE operation_id = v_operation_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment.prepare_external: operation % not found', v_operation_id;
    END IF;

    v_external_request_id := v_operation_id::TEXT;
    v_correlation_id := gen_random_uuid();
    v_payload_hash := ENCODE(DIGEST(
        jsonb_build_object(
            'operationId', v_external_request_id, 'amount', v_amount::TEXT, 'currency', v_currency
        )::TEXT, 'sha256'), 'hex');

    PERFORM delivery.enqueue_outbox(
        v_operation_id, v_external_request_id, v_correlation_id, v_amount, v_currency, v_payload_hash
    );

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'PREPARED',
        'result', jsonb_build_object('operationId', v_operation_id, 'externalRequestId', v_external_request_id)
    );
END;
$$;

-- ============================================================
-- 5. payment.apply_receipt — payment.apply_receipt v1. ЧИТАЕТ, а не
--    решает: единственный источник итога — уже применённая (APPLIED)
--    строка Inbox для этого процесса. Клиентский body/transport response
--    сюда вообще не попадают (apply_receipt их даже не видит).
-- ============================================================
CREATE OR REPLACE FUNCTION payment.apply_receipt(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = payment, delivery, course, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_process_id UUID;
    v_receipt_outcome TEXT;
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;

    SELECT process_id INTO v_process_id FROM course.operations WHERE operation_id = v_operation_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment.apply_receipt: operation % not found', v_operation_id;
    END IF;

    SELECT outcome INTO v_receipt_outcome
    FROM delivery.inbox
    WHERE process_id = v_process_id AND signal_type = 'payment.receipt' AND state = 'APPLIED'
    ORDER BY applied_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment.apply_receipt: no applied receipt found for process % — unreachable per map (only entered after wait_receipt)', v_process_id;
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', v_receipt_outcome,
        'result', jsonb_build_object('operationId', v_operation_id, 'outcome', v_receipt_outcome)
    );
END;
$$;

-- ============================================================
-- 6/7. payment.complete_operation / payment.reject_operation —
--      payment.complete v1 (только payment-processing) и payment.reject
--      v1 (общий для обеих карт). Идемпотентны по текущему статусу
--      operation: повтор с тем же executionId, если статус уже
--      выставлен, ничего не переписывает и не плодит второе событие.
-- ============================================================
CREATE OR REPLACE FUNCTION payment.complete_operation(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = payment, course, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_status TEXT;
    v_payload_hash TEXT;
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;
    v_payload_hash := ENCODE(DIGEST(p_payload::TEXT, 'sha256'), 'hex');

    SELECT status INTO v_status FROM course.operations WHERE operation_id = v_operation_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment.complete_operation: operation % not found', v_operation_id;
    END IF;

    IF v_status <> 'COMPLETED' THEN
        UPDATE course.operations SET status = 'COMPLETED', updated_at = now() WHERE operation_id = v_operation_id;
        INSERT INTO course.operation_events (operation_id, event_type, payload_hash)
        VALUES (v_operation_id, 'OPERATION_COMPLETED', v_payload_hash);
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'COMPLETED',
        'result', jsonb_build_object('operationId', v_operation_id, 'status', 'COMPLETED')
    );
END;
$$;

CREATE OR REPLACE FUNCTION payment.reject_operation(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = payment, course, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_status TEXT;
    v_payload_hash TEXT;
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;
    v_payload_hash := ENCODE(DIGEST(p_payload::TEXT, 'sha256'), 'hex');

    SELECT status INTO v_status FROM course.operations WHERE operation_id = v_operation_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment.reject_operation: operation % not found', v_operation_id;
    END IF;

    IF v_status <> 'REJECTED' THEN
        UPDATE course.operations SET status = 'REJECTED', updated_at = now() WHERE operation_id = v_operation_id;
        INSERT INTO course.operation_events (operation_id, event_type, payload_hash)
        VALUES (v_operation_id, 'OPERATION_REJECTED', v_payload_hash);
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'REJECTED',
        'result', jsonb_build_object('operationId', v_operation_id, 'status', 'REJECTED')
    );
END;
$$;

-- ============================================================
-- 8. payment.check_limit — payment.check_limit v1 (payment-review).
--    step_instance_id для payment.decision берём из
--    workflow.workflow_job по context.jobId — это ТОЧНО текущий
--    выполняющийся job, надёжнее, чем угадывать "последний RUNNING
--    step по process_id+step_key". context.jobId кладёт туда worker
--    (TrustedContext.JobId, Workflow.Worker/StepRunner.cs); функция
--    имеет неявный доступ к workflow.workflow_job как SECURITY DEFINER
--    course_owner — отдельный GRANT не нужен.
--    Порог 100000.00 RUB и rule_version — server-side константы,
--    клиент их не передаёт и не может повлиять (04-week-3.md).
-- ============================================================
CREATE OR REPLACE FUNCTION payment.check_limit(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = payment, workflow, course, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_amount NUMERIC(19,2);
    v_process_id UUID;
    v_step_instance_id UUID;
    v_principal TEXT;
    v_threshold CONSTANT NUMERIC(19,2) := 100000.00;
    v_rule_version CONSTANT TEXT := 'course-limit-v1';
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;

    SELECT amount, process_id INTO v_amount, v_process_id
    FROM course.operations WHERE operation_id = v_operation_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment.check_limit: operation % not found', v_operation_id;
    END IF;

    SELECT step_instance_id INTO v_step_instance_id
    FROM workflow.workflow_job WHERE job_id = (p_context->>'jobId')::UUID;

    v_principal := COALESCE(p_context->>'principal', 'system');

    IF v_amount <= v_threshold THEN
        INSERT INTO payment.decision (
            process_id, step_instance_id, source, principal, reason_hash, outcome, rule_version
        ) VALUES (
            v_process_id, v_step_instance_id, 'LIMIT_RULE', v_principal, NULL, 'APPROVED', v_rule_version
        )
        ON CONFLICT (step_instance_id) DO NOTHING;

        RETURN jsonb_build_object(
            'status', 'ok', 'outcome', 'WITHIN_LIMIT',
            'result', jsonb_build_object('operationId', v_operation_id, 'ruleVersion', v_rule_version)
        );
    END IF;

    -- REVIEW_REQUIRED: решение ещё не принято — decision появится
    -- только из workflow.manual_decision, не отсюда.
    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'REVIEW_REQUIRED',
        'result', jsonb_build_object('operationId', v_operation_id, 'ruleVersion', v_rule_version)
    );
END;
$$;

-- ============================================================
-- 9. payment.approve_operation — payment.approve v1 (payment-review).
--    Общий для двух путей: авто (WITHIN_LIMIT) и после ручного
--    APPROVED — сама approve_operation не знает и не обязана знать,
--    откуда пришла: decision уже записан либо check_limit, либо
--    workflow.manual_decision до входа в этот шаг.
-- ============================================================
CREATE OR REPLACE FUNCTION payment.approve_operation(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = payment, course, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_status TEXT;
    v_payload_hash TEXT;
BEGIN
    v_operation_id := (p_payload->>'operationId')::UUID;
    v_payload_hash := ENCODE(DIGEST(p_payload::TEXT, 'sha256'), 'hex');

    SELECT status INTO v_status FROM course.operations WHERE operation_id = v_operation_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'payment.approve_operation: operation % not found', v_operation_id;
    END IF;

    IF v_status <> 'COMPLETED' THEN
        UPDATE course.operations SET status = 'COMPLETED', updated_at = now() WHERE operation_id = v_operation_id;
        INSERT INTO course.operation_events (operation_id, event_type, payload_hash)
        VALUES (v_operation_id, 'OPERATION_APPROVED', v_payload_hash);
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'APPROVED',
        'result', jsonb_build_object('operationId', v_operation_id, 'status', 'COMPLETED')
    );
END;
$$;

-- ============================================================
-- 10. payment.receipt_accept — receipt.accept v1. Generic signature
--     boundary (Api/Middleware/ProviderSignatureMiddleware.cs) кладёт в
--     context ТОЛЬКО transport.signatureVerified и transport.signatureVersion
--     (04-week-3.md: "в context не попадают secret и полная signature" —
--     дословно только эти два поля, ничего больше). Значит body_hash
--     здесь не может прийти готовым снаружи, и дедупликация "тот же
--     messageId, другой body" ниже сделана прямым JSONB-сравнением
--     (delivery.record_inbox: v_existing.body = p_body), а не сверкой
--     хэшей — см. комментарий в этой функции в 012 (0.2).
-- ============================================================
CREATE OR REPLACE FUNCTION payment.receipt_accept(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = payment, delivery, course, public, pg_catalog
AS $$
DECLARE
    v_signature_verified BOOLEAN;
    v_raw_body_hash TEXT;
    v_external_request_id TEXT;
    v_message_id TEXT;
    v_occurred_at TEXT;
    v_outcome TEXT;
    v_version INTEGER;
    v_operation_id UUID;
    v_process_id UUID;
    v_record_result JSONB;
BEGIN
    v_signature_verified := COALESCE((p_context #>> '{transport,signatureVerified}')::BOOLEAN, FALSE);
        IF NOT v_signature_verified THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'receipt.signature_required',
            'message', 'X-Provider-Signature is required for receipt.accept', 'retryable', false
        );
    END IF;

    -- FIX: exact SHA-256 hex от raw HTTP body bytes, посчитанный
    -- ProviderSignatureMiddleware. Обязателен: иначе body_hash пришлось
    -- бы считать из p_body::TEXT, что даёт Postgres-канонический
    -- JSONB-порядок (по длине ключа), а не compact sorted JSON
    -- (по алфавиту), который подписывает adapter и ожидает week-3
    -- public checker (adapter-exact-signed-body).
    v_raw_body_hash := p_context #>> '{transport,rawBodyHash}';
    IF v_raw_body_hash IS NULL OR v_raw_body_hash = '' THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'internal.error',
            'message', 'transport.rawBodyHash is required for receipt.accept', 'retryable', false
        );
    END IF;

    v_external_request_id := p_payload->>'externalRequestId';
    v_message_id := p_payload->>'messageId';
    v_occurred_at := p_payload->>'occurredAt';
    v_outcome := p_payload->>'outcome';
    v_version := (p_payload->>'version')::INTEGER;

    SELECT o.operation_id, o.process_id INTO v_operation_id, v_process_id
    FROM delivery.outbox ob
    JOIN course.operations o ON o.operation_id = ob.operation_id
    WHERE ob.external_request_id = v_external_request_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'receipt.external_request_not_found',
            'message', 'externalRequestId is not known', 'retryable', false
        );
    END IF;

        v_record_result := delivery.record_inbox(
        v_message_id, v_external_request_id, v_process_id, 'payment.receipt',
        p_payload, v_outcome, v_version, v_signature_verified, v_raw_body_hash
    );

    IF v_record_result->>'status' <> 'ok' THEN
        RETURN v_record_result; -- idempotency.conflict — пробрасываем как есть
    END IF;

    -- Переводим Outbox в CONFIRMED только для НОВОГО receipt (RECEIVED).
    -- Повторный тот же receipt (DUPLICATE) уже подтвердил его в первый раз.
    IF v_record_result->>'outcome' = 'RECEIVED' THEN
        PERFORM delivery.confirm_outbox(v_external_request_id);
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', v_record_result->>'outcome',
        'result', jsonb_build_object(
            'messageId', v_message_id,
            'externalRequestId', v_external_request_id,
            'state', v_record_result->>'state'
        )
    );
END;
$$;

-- ============================================================
-- 11. workflow.manual_decision — workflow.manual v1. Аналог
--     workflow.apply_signal/receive_signal, но для MANUAL step_type:
--     исход задаёт человек (decision), а не карта заранее
--     (declared_outcome у MANUAL остаётся NULL, см. 008_workflow_lifecycle.sql).
--     Идентичный Idempotency-Key с тем же payload не доходит сюда
--     (generic store вернёт кеш раньше). Если мы здесь и step уже
--     COMPLETED — это либо конкурирующее, либо изменённое решение,
--     оба случая -> 409 workflow.decision_conflict.
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.manual_decision(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, payment, course, public, pg_catalog
AS $$
DECLARE
    v_process_id UUID;
    v_step_instance_id UUID;
    v_decision TEXT;
    v_reason TEXT;
    v_reason_hash TEXT;
    v_principal TEXT;
    v_step workflow.step_instance%ROWTYPE;
    v_process workflow.process_instance%ROWTYPE;
    v_next_step_key TEXT;
    v_decision_id UUID;
BEGIN
    v_process_id := (p_payload->>'processId')::UUID;
    v_step_instance_id := (p_payload->>'stepInstanceId')::UUID;
    v_decision := p_payload->>'decision';
    v_reason := p_payload->>'reason';
    v_principal := p_context->>'principal'; -- trusted context, НЕ payload
    v_reason_hash := ENCODE(DIGEST(v_reason, 'sha256'), 'hex');

    SELECT * INTO v_step FROM workflow.step_instance WHERE step_instance_id = v_step_instance_id FOR UPDATE;
    IF NOT FOUND OR v_step.process_id <> v_process_id OR v_step.step_type <> 'MANUAL' THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.step_not_found',
            'message', 'stepInstanceId does not match a pending manual step of processId', 'retryable', false
        );
    END IF;

    IF v_step.state <> 'WAITING' THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.decision_conflict',
            'message', 'manual step is already decided', 'retryable', false
        );
    END IF;

    SELECT * INTO v_process FROM workflow.process_instance WHERE process_id = v_process_id FOR UPDATE;

    SELECT next_step_key INTO v_next_step_key
    FROM workflow.transition_definition
    WHERE flow_name = v_process.flow_name AND flow_version = v_process.flow_version
      AND step_key = v_step.step_key AND outcome = v_decision;

    IF v_next_step_key IS NULL THEN
        RAISE EXCEPTION 'workflow.manual_decision: no transition for step % outcome % — should have been caught at publish time',
            v_step.step_key, v_decision;
    END IF;

    UPDATE workflow.step_instance
    SET state = 'COMPLETED', outcome = v_decision, completed_at = now()
    WHERE step_instance_id = v_step_instance_id;

    INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
    VALUES (v_process_id, v_step_instance_id, 'ManualDecisionApplied');

    INSERT INTO payment.decision (
        process_id, step_instance_id, source, principal, reason_hash, outcome, rule_version
    ) VALUES (
        v_process_id, v_step_instance_id, 'MANUAL', v_principal, v_reason_hash, v_decision, NULL
    )
    ON CONFLICT (step_instance_id) DO NOTHING
    RETURNING decision_id INTO v_decision_id;

    IF v_decision_id IS NULL THEN
        SELECT decision_id INTO v_decision_id FROM payment.decision WHERE step_instance_id = v_step_instance_id;
    END IF;

    PERFORM workflow.enter_step(v_process_id, v_next_step_key);

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', v_decision,
        'result', jsonb_build_object(
            'decisionId', v_decision_id,
            'processId', v_process_id,
            'stepInstanceId', v_step_instance_id,
            'decision', v_decision,
            'source', 'MANUAL',
            'principal', v_principal
        )
    );
END;
$$;

-- ============================================================
-- Владение
-- ============================================================
ALTER FUNCTION course.payment_submit(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.operation_events(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION payment.validate_operation(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION payment.prepare_external(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION payment.apply_receipt(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION payment.complete_operation(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION payment.reject_operation(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION payment.check_limit(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION payment.approve_operation(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION payment.receipt_accept(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION workflow.manual_decision(JSONB, JSONB) OWNER TO course_owner;

COMMENT ON FUNCTION course.payment_submit(JSONB, JSONB) IS 'payment.submit v1: пиновка процесса на operationId через workflow.start_process + CREATED -> PROCESSING один раз.';
COMMENT ON FUNCTION payment.prepare_external(JSONB, JSONB) IS 'payment.prepare_external v1: externalRequestId = operationId, идемпотентно ставит в delivery.outbox.';
COMMENT ON FUNCTION payment.apply_receipt(JSONB, JSONB) IS 'payment.apply_receipt v1: читает только уже применённый Inbox, не принимает client body напрямую.';
COMMENT ON FUNCTION payment.check_limit(JSONB, JSONB) IS 'payment.check_limit v1: server-side rule course-limit-v1, порог 100000.00 RUB.';
COMMENT ON FUNCTION payment.receipt_accept(JSONB, JSONB) IS 'receipt.accept v1: требует transport.signatureVerified, иначе 403 без мутации Inbox.';
COMMENT ON FUNCTION workflow.manual_decision(JSONB, JSONB) IS 'workflow.manual v1: решение только для текущего WAITING manual step; конкурирующее/изменённое -> 409.';

-- ============================================================
-- Defense-in-depth для схемы payment — единственной, которую
-- 004_revoke_execute_public.sql сознательно пропустил ("payment
-- функций не содержит — только таблицы"). Теперь функции появились,
-- поэтому без explicit REVOKE здесь они по умолчанию Postgres
-- останутся исполняемыми ЛЮБОЙ ролью, способной подключиться к БД
-- (course_runtime, workflow_worker, outbox_dispatcher, ...), а не
-- только через api.invoke — тот же пробел, который 004 закрыла для
-- api/course/opencheck, и 007 для workflow.
-- ============================================================
SET ROLE course_owner;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA payment FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA payment REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
RESET ROLE;