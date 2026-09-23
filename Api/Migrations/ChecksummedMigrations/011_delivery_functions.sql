-- ============================================================
-- Миграция 011: функции delivery-схемы + autocheck views
-- ============================================================
--
-- Три функции с ЗАФИКСИРОВАННОЙ заданием сигнатурой (см. docs/04-week-3.md,
-- "SQL boundaries Python") — claim_outbox/succeed_outbox/fail_outbox/
-- reconcile_inbox. Именно на них (и ни на что больше) получают EXECUTE
-- outbox_dispatcher и inbox_reconciler. Плюс три internal helper'а
-- (enqueue_outbox/confirm_outbox/record_inbox) — их вызывает будущая
-- миграция с payment-доменом (payment.prepare_external и receipt.accept),
-- а не Python напрямую, поэтому им EXECUTE для новых ролей не выдаём.

-- ============================================================
-- 1. delivery.claim_outbox — короткая транзакция, FOR UPDATE SKIP
--    LOCKED, ровно как workflow.claim_jobs в 007_workflow_functions.sql.
--    Возвращает amount уже как TEXT — NUMERIC(19,2)::TEXT в Postgres
--    всегда даёт ровно 2 знака после точки, это совпадает с форматом
--    из provider-v02-payment-request.schema.json.
--    Lease duration зафиксирован константой внутри функции: сигнатура
--    (text, integer) не оставляет места для третьего параметра.
-- ============================================================
CREATE OR REPLACE FUNCTION delivery.claim_outbox(
    p_owner TEXT,
    p_limit INTEGER
) RETURNS TABLE (
    outbox_id UUID,
    lease_version BIGINT,
    external_request_id TEXT,
    correlation_id UUID,
    amount TEXT,
    currency TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = delivery, public, pg_catalog
AS $$
DECLARE
    v_lease_seconds CONSTANT INTEGER := 30;
    v_ids UUID[];
BEGIN
    -- Кандидаты: обычные PENDING/RETRY_WAIT, готовые по времени, ПЛЮС
    -- LEASED, чей lease_until уже в прошлом — самореклейм после
    -- падения/пересоздания dispatcher'а (без этого просроченный lease
    -- висел бы вечно, ровно как объяснено в комментарии к
    -- workflow.claim_jobs).
    SELECT array_agg(candidate.outbox_id) INTO v_ids
    FROM (
        SELECT o.outbox_id
        FROM delivery.outbox o
        WHERE (
                o.state IN ('PENDING', 'RETRY_WAIT')
                AND (o.next_attempt_at IS NULL OR o.next_attempt_at <= now())
              )
           OR (
                o.state = 'LEASED'
                AND o.lease_until IS NOT NULL
                AND o.lease_until < now()
              )
        ORDER BY o.next_attempt_at NULLS FIRST, o.created_at
        FOR UPDATE SKIP LOCKED
        LIMIT p_limit
    ) candidate;

    IF v_ids IS NULL THEN
        RETURN; -- нечего отдавать этому dispatcher'у прямо сейчас
    END IF;

    UPDATE delivery.outbox o
    SET state = 'LEASED',
        lease_owner = p_owner,
        lease_version = o.lease_version + 1,
        lease_until = now() + (v_lease_seconds || ' seconds')::interval
    WHERE o.outbox_id = ANY(v_ids);

    RETURN QUERY
    SELECT o.outbox_id, o.lease_version, o.external_request_id, o.correlation_id,
           o.amount::TEXT, o.currency
    FROM delivery.outbox o
    WHERE o.outbox_id = ANY(v_ids);
END;
$$;

-- ============================================================
-- 2. delivery.succeed_outbox — принимается только при точном
--    совпадении owner + lease_version + state='LEASED' (тот же
--    conditional-update паттерн, что workflow.finish_job).
--    Ставит DELIVERED, а НЕ CONFIRMED — CONFIRMED выставляет только
--    receipt.accept (через delivery.confirm_outbox) после того, как
--    receipt реально применён, что и требует задание дословно.
-- ============================================================
CREATE OR REPLACE FUNCTION delivery.succeed_outbox(
    p_outbox_id UUID,
    p_owner TEXT,
    p_lease_version BIGINT,
    p_provider_payment_id TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = delivery, public, pg_catalog
AS $$
DECLARE
    v_row delivery.outbox%ROWTYPE;
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

    IF p_provider_payment_id IS NULL OR length(p_provider_payment_id) = 0 THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'delivery.invalid_provider_payment_id',
            'message', 'providerPaymentId must be a non-empty string'
        );
    END IF;

    UPDATE delivery.outbox
    SET state = 'DELIVERED',
        attempt_count = attempt_count + 1,
        provider_payment_id = p_provider_payment_id,
        delivered_at = now(),
        last_error_code = NULL,
        next_attempt_at = NULL
    WHERE outbox_id = p_outbox_id;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outboxId', p_outbox_id,
        'state', 'DELIVERED',
        'providerPaymentId', p_provider_payment_id
    );
END;
$$;

-- ============================================================
-- 3. delivery.fail_outbox — классификация retryable по СУФФИКСУ
--    error_code (см. provider_client.py: "*.retryable" / "*.terminal"),
--    а не по жёстко перечисленным кодам — так Python и SQL не должны
--    держать один и тот же список кодов синхронизированным вручную.
--    max_attempts=3 и delays_ms=[200,400,800] взяты дословно из таблицы
--    "Тестовый профиль" в 07-autocheck-outline.md ("Максимум попыток
--    Outbox: 3", "Задержки Outbox: 200, 400, 800 мс") — эти же числа
--    checker и использует для проверки retry-сценариев. Документ
--    отдельно допускает более консервативный (не более быстрый) прод-
--    профиль, но отдельного механизма переключения по COURSE_TEST_PROFILE
--    здесь нет: сигнатура функции фиксирована заданием и не принимает
--    доп. параметр — расширять до чтения профиля из отдельной
--    settings-таблицы, если понадобится другой профиль для прода.
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
    v_max_attempts CONSTANT INTEGER := 3;
    v_delays_ms CONSTANT INTEGER[] := ARRAY[200, 400, 800];
    v_delay_ms INTEGER;
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
            next_attempt_at = NULL
        WHERE outbox_id = p_outbox_id;

        RETURN jsonb_build_object('status', 'ok', 'outboxState', 'DEAD', 'errorCode', p_error_code);
    END IF;

    v_delay_ms := v_delays_ms[LEAST(v_row.attempt_count + 1, array_length(v_delays_ms, 1))];

    UPDATE delivery.outbox
    SET state = 'RETRY_WAIT',
        attempt_count = attempt_count + 1,
        last_error_code = p_error_code,
        next_attempt_at = now() + (v_delay_ms || ' milliseconds')::interval
    WHERE outbox_id = p_outbox_id;

    RETURN jsonb_build_object(
        'status', 'ok', 'outboxState', 'RETRY_WAIT',
        'nextAttemptDelayMs', v_delay_ms, 'errorCode', p_error_code
    );
END;
$$;

-- ============================================================
-- 4. delivery.reconcile_inbox — один вызов атомарно (per-row,
--    не одной большой транзакцией на весь batch) применяет
--    подходящие RECEIVED сообщения. Переиспользует
--    workflow.receive_signal (из 008_workflow_lifecycle.sql) —
--    он уже делает дедупликацию по message_id и немедленное
--    применение к ожидающему шагу, если процесс уже стоит на
--    wait_signal, либо просто сохраняет сигнал ACCEPTED, если
--    процесс до него ещё не дошёл (тогда его подхватит
--    workflow.enter_step при входе в wait_signal — "раннее
--    сообщение не теряется").
--    Каждая строка обрабатывается в СВОЁМ блоке с EXCEPTION,
--    чтобы дефект/гонка на одной записи не срывала весь батч —
--    такая запись просто остаётся RECEIVED и будет подхвачена
--    следующим вызовом.
-- ============================================================
CREATE OR REPLACE FUNCTION delivery.reconcile_inbox(
    p_limit INTEGER
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = delivery, workflow, course, public, pg_catalog
AS $$
DECLARE
    v_row RECORD;
    v_applied INTEGER := 0;
    v_signal_result JSONB;
    v_signal_status TEXT;
BEGIN
    -- 0. Синхронизация "снаружи": сигнал мог примениться НЕ отсюда, а
    --    обычным workflow.enter_step — когда процесс сам, каким-то
    --    другим job'ом, дошёл до wait_receipt и подхватил уже лежавший
    --    ACCEPTED-сигнал (тот же "раннее сообщение не теряется" путь из
    --    007/008 миграций). Inbox ничего не знает о переходах шагов сам
    --    по себе, поэтому reconcile_inbox обязан явно досмотреть уже
    --    существующие workflow_signal перед тем, как создавать новые —
    --    иначе такая строка Inbox зависла бы в RECEIVED навсегда.
    UPDATE delivery.inbox i
    SET state = 'APPLIED', applied_at = now()
    FROM workflow.workflow_signal s
    WHERE i.message_id = s.message_id
      AND i.state = 'RECEIVED'
      AND s.status = 'APPLIED';
    GET DIAGNOSTICS v_applied = ROW_COUNT;

    -- 1. Строки, для которых workflow_signal ещё вообще не создан.
    --    Уже существующий (но ещё ACCEPTED, не APPLIED) signal сюда не
    --    попадает намеренно: повторный workflow.receive_signal с тем же
    --    message_id просто вернёт "duplicate", ничего не решая — его
    --    прикладное применение случится только через enter_step (п.0
    --    на следующем вызове), поэтому такую строку трогать не нужно.
    FOR v_row IN
        SELECT i.message_id, i.process_id, i.signal_type, i.body
        FROM delivery.inbox i
        WHERE i.state = 'RECEIVED'
          AND NOT EXISTS (
              SELECT 1 FROM workflow.workflow_signal s WHERE s.message_id = i.message_id
          )
        ORDER BY i.received_at
        FOR UPDATE SKIP LOCKED
        LIMIT p_limit
    LOOP
        BEGIN
            v_signal_result := workflow.receive_signal(
                v_row.process_id, v_row.message_id, v_row.signal_type, v_row.body
            );
        EXCEPTION WHEN OTHERS THEN
            v_signal_result := jsonb_build_object('status', 'error', 'code', 'delivery.reconcile_failed');
        END;

        IF v_signal_result->>'status' <> 'ok' THEN
            -- process ещё не существует, unknown_signal_type, гонка —
            -- строка остаётся RECEIVED, заберём на следующем вызове.
            CONTINUE;
        END IF;

        SELECT status INTO v_signal_status
        FROM workflow.workflow_signal WHERE message_id = v_row.message_id;

        -- Inbox -> APPLIED только если сигнал ДЕЙСТВИТЕЛЬНО применился
        -- прямо сейчас (процесс уже стоял на нужном wait_signal). Если
        -- receive_signal лишь сохранил его как ACCEPTED (процесс ещё не
        -- дошёл до wait_receipt) — строка обязана остаться RECEIVED,
        -- это дословное требование 04-week-3.md ("неподходящее раннее
        -- сообщение остаётся RECEIVED"), и её потом досмотрит п.0.
        IF v_signal_status = 'APPLIED' THEN
            UPDATE delivery.inbox
            SET state = 'APPLIED', applied_at = now()
            WHERE message_id = v_row.message_id;

            v_applied := v_applied + 1;
        END IF;
    END LOOP;

    RETURN v_applied;
END;
$$;

-- ============================================================
-- 5. Internal helpers — НЕ для Python. Вызываются из будущей
--    payment-домен миграции (course_owner вызывает course_owner,
--    доп. GRANT не нужен: владелец функции всегда имеет EXECUTE
--    на свои же объекты, даже после REVOKE ... FROM PUBLIC ниже).
-- ============================================================

-- 5.1 enqueue_outbox — вызывается из payment.prepare_external.
--     Идемпотентен по external_request_id: повторный вызов с тем же
--     executionId (а значит тем же external_request_id) возвращает
--     ID уже существующей строки, а не создаёт вторую попытку.
CREATE OR REPLACE FUNCTION delivery.enqueue_outbox(
    p_operation_id UUID,
    p_external_request_id TEXT,
    p_correlation_id UUID,
    p_amount NUMERIC(19,2),
    p_currency TEXT,
    p_payload_hash TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = delivery, public, pg_catalog
AS $$
DECLARE
    v_outbox_id UUID;
BEGIN
    INSERT INTO delivery.outbox (
        operation_id, external_request_id, payload_hash, correlation_id, amount, currency, state
    ) VALUES (
        p_operation_id, p_external_request_id, p_payload_hash, p_correlation_id, p_amount, p_currency, 'PENDING'
    )
    ON CONFLICT (external_request_id) DO NOTHING
    RETURNING outbox_id INTO v_outbox_id;

    IF v_outbox_id IS NULL THEN
        SELECT outbox_id INTO v_outbox_id
        FROM delivery.outbox WHERE external_request_id = p_external_request_id;
    END IF;

    RETURN v_outbox_id;
END;
$$;

-- 5.2 confirm_outbox — вызывается из receipt.accept ПОСЛЕ того, как
--     receipt реально сохранён и связан с operation/process. Условие
--     "state <> 'CONFIRMED'" здесь же и есть требуемая невозможность
--     регресса — повторный вызов (duplicate receipt) просто не находит
--     что менять.
CREATE OR REPLACE FUNCTION delivery.confirm_outbox(
    p_external_request_id TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = delivery, public, pg_catalog
AS $$
BEGIN
    UPDATE delivery.outbox
    SET state = 'CONFIRMED', confirmed_at = now()
    WHERE external_request_id = p_external_request_id
      AND state <> 'CONFIRMED';
END;
$$;

-- 5.3 record_inbox — вызывается из receipt.accept. p_body_hash
--     ОБЯЗАН приходить готовым от вызывающей стороны, посчитанным над
--     точными полученными HTTP body bytes (см. комментарий на
--     delivery.inbox.body_hash) — эта функция его не пересчитывает.
CREATE OR REPLACE FUNCTION delivery.record_inbox(
    p_message_id TEXT,
    p_external_request_id TEXT,
    p_process_id UUID,
    p_signal_type TEXT,
    p_body JSONB,
    p_body_hash TEXT,
    p_outcome TEXT
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
        message_id, external_request_id, process_id, signal_type, body, body_hash, outcome, state
    ) VALUES (
        p_message_id, p_external_request_id, p_process_id, p_signal_type, p_body, p_body_hash, p_outcome, 'RECEIVED'
    );

    RETURN jsonb_build_object(
        'status', 'ok', 'outcome', 'RECEIVED',
        'messageId', p_message_id, 'state', 'RECEIVED'
    );
END;
$$;

-- ============================================================
-- 6. autocheck views — колонки ровно по docs/04-week-3.md
--    ("Проверочные проекции"): outbox и inbox.
-- ============================================================
CREATE OR REPLACE VIEW autocheck.outbox AS
SELECT
    outbox_id,
    external_request_id,
    state,
    attempt_count,
    next_attempt_at,
    last_error_code,
    created_at,
    delivered_at
FROM delivery.outbox;

CREATE OR REPLACE VIEW autocheck.inbox AS
SELECT
    message_id,
    body_hash,
    state,
    received_at,
    applied_at
FROM delivery.inbox;

-- external_requests по 04-week-3.md маппится из delivery.outbox — в
-- этом дизайне нет отдельной таблицы external_request (см. комментарий
-- в 010_delivery_schema.sql), поэтому её "domain state" (CREATED/SENT/
-- CONFIRMED из 07-autocheck-outline.md) выводится из transport state
-- Outbox: CREATED, пока запрос ещё не долетел до provider, SENT — после
-- 202 ACCEPTED (или после исчерпания попыток — сам факт того, что
-- запрос был отправлен, не отменяется), CONFIRMED — после применённого
-- receipt.
CREATE OR REPLACE VIEW autocheck.external_requests AS
SELECT
    external_request_id,
    operation_id,
    CASE
        WHEN state IN ('PENDING', 'LEASED', 'RETRY_WAIT') THEN 'CREATED'
        WHEN state IN ('DELIVERED', 'DEAD') THEN 'SENT'
        WHEN state = 'CONFIRMED' THEN 'CONFIRMED'
    END AS state,
    payload_hash,
    created_at
FROM delivery.outbox;

-- ============================================================
-- Владение и права
-- ============================================================
ALTER FUNCTION delivery.claim_outbox(TEXT, INTEGER) OWNER TO course_owner;
ALTER FUNCTION delivery.succeed_outbox(UUID, TEXT, BIGINT, TEXT) OWNER TO course_owner;
ALTER FUNCTION delivery.fail_outbox(UUID, TEXT, BIGINT, TEXT) OWNER TO course_owner;
ALTER FUNCTION delivery.reconcile_inbox(INTEGER) OWNER TO course_owner;
ALTER FUNCTION delivery.enqueue_outbox(UUID, TEXT, UUID, NUMERIC, TEXT, TEXT) OWNER TO course_owner;
ALTER FUNCTION delivery.confirm_outbox(TEXT) OWNER TO course_owner;
ALTER FUNCTION delivery.record_inbox(TEXT, TEXT, UUID, TEXT, JSONB, TEXT, TEXT) OWNER TO course_owner;
ALTER VIEW autocheck.outbox OWNER TO course_owner;
ALTER VIEW autocheck.inbox OWNER TO course_owner;
ALTER VIEW autocheck.external_requests OWNER TO course_owner;

-- Defense-in-depth, тот же приём, что 004_revoke_execute_public.sql
-- и 007_workflow_functions.sql: снимаем дефолтный PUBLIC EXECUTE сразу
-- в этой же миграции, не откладывая на отдельную.
SET ROLE course_owner;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA delivery FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA delivery REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
RESET ROLE;

-- outbox_dispatcher получает EXECUTE ровно на 3 функции — не на
-- enqueue_outbox/confirm_outbox и не на прямой DML таблиц.
GRANT USAGE ON SCHEMA delivery TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.claim_outbox(TEXT, INTEGER) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.succeed_outbox(UUID, TEXT, BIGINT, TEXT) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.fail_outbox(UUID, TEXT, BIGINT, TEXT) TO outbox_dispatcher;

-- inbox_reconciler получает EXECUTE ровно на 1 функцию.
GRANT USAGE ON SCHEMA delivery TO inbox_reconciler;
GRANT EXECUTE ON FUNCTION delivery.reconcile_inbox(INTEGER) TO inbox_reconciler;

-- autocheck views — course_runtime доступ, что у
-- остальных views схемы (006_workflow_autocheck_views.sql).

GRANT SELECT ON autocheck.outbox, autocheck.inbox, autocheck.external_requests TO course_runtime;

COMMENT ON FUNCTION delivery.claim_outbox(TEXT, INTEGER) IS
    'Захват до p_limit готовых Outbox-строк (FOR UPDATE SKIP LOCKED) + самореклейм просроченного lease. Один claim = одна HTTP попытка dispatcher''а.';
COMMENT ON FUNCTION delivery.succeed_outbox(UUID, TEXT, BIGINT, TEXT) IS
    'Provider принял платёж (202 ACCEPTED): PENDING/LEASED -> DELIVERED. Принимается только при точном owner+leaseVersion+state=LEASED.';
COMMENT ON FUNCTION delivery.fail_outbox(UUID, TEXT, BIGINT, TEXT) IS
    'Классификация по суффиксу error_code (.retryable/.terminal): DEAD сразу (non-retryable или исчерпаны попытки), либо RETRY_WAIT с backoff по фиксированному расписанию.';
COMMENT ON FUNCTION delivery.reconcile_inbox(INTEGER) IS
    'Атомарно (по одной строке) переводит RECEIVED Inbox в workflow-сигнал через workflow.receive_signal и помечает APPLIED.';
COMMENT ON FUNCTION delivery.enqueue_outbox(UUID, TEXT, UUID, NUMERIC, TEXT, TEXT) IS
    'internal: создаёт Outbox-запись для payment.prepare_external, идемпотентно по external_request_id.';
COMMENT ON FUNCTION delivery.confirm_outbox(TEXT) IS
    'internal: помечает Outbox CONFIRMED из receipt.accept после применения receipt. Никогда не регрессирует уже CONFIRMED.';
COMMENT ON FUNCTION delivery.record_inbox(TEXT, TEXT, UUID, TEXT, JSONB, TEXT, TEXT) IS
    'internal: идемпотентная запись Inbox из receipt.accept — DUPLICATE при том же body_hash, idempotency.conflict при другом.';
