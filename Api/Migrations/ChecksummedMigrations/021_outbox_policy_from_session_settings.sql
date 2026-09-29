-- ============================================================
-- Миграция 021: lease и retry-политика Outbox из конфигурации
-- ============================================================
--
-- docs/configuration.md: COURSE_OUTBOX_LEASE_MS, COURSE_OUTBOX_MAX_ATTEMPTS,
-- COURSE_OUTBOX_BACKOFF_BASE_MS, COURSE_OUTBOX_BACKOFF_MAX_MS,
-- COURSE_OUTBOX_JITTER_MAX_MS — обязательные переменные, получатель
-- «PostgreSQL/dispatcher». До этой миграции lease был зашит в claim_outbox
-- как 30 секунд (011), а retry-политика — константами в fail_outbox (017):
-- переменные окружения ни на что не влияли, и после падения dispatcher'а
-- reclaim строки ждал 30 с вместо контрактных 2000 мс.
--
-- PostgreSQL не читает env контейнера, поэтому dispatcher передаёт значения
-- параметрами СЕССИИ (asyncpg server_settings -> GUC course.outbox_*), а
-- функции читают их через current_setting(..., true) с безопасными
-- значениями по умолчанию. Сигнатуры функций НЕ меняются:
--   claim_outbox(text, integer), fail_outbox(uuid, text, bigint, text) —
-- набор fixed SQL boundaries Python-ролей проверяется checker'ом
-- (python-fixed-sql-boundaries / python-fixed-function-privileges),
-- поэтому новые overload'ы и дополнительные аргументы недопустимы.

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
    v_ids UUID[];
    v_lease_ms INTEGER;
BEGIN
    -- COURSE_OUTBOX_LEASE_MS; без настройки — консервативные 30 секунд.
    v_lease_ms := COALESCE(NULLIF(current_setting('course.outbox_lease_ms', true), '')::INTEGER, 30000);

    -- Кандидаты: PENDING/RETRY_WAIT, готовые по времени, ПЛЮС LEASED с
    -- истёкшим lease_until (самореклейм после падения dispatcher'а).
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
        RETURN;
    END IF;

    UPDATE delivery.outbox o
    SET state = 'LEASED',
        lease_owner = p_owner,
        lease_version = o.lease_version + 1,
        lease_until = now() + (v_lease_ms || ' milliseconds')::interval
    WHERE o.outbox_id = ANY(v_ids);

    RETURN QUERY
    SELECT o.outbox_id, o.lease_version, o.external_request_id, o.correlation_id,
           o.amount::TEXT, o.currency
    FROM delivery.outbox o
    WHERE o.outbox_id = ANY(v_ids);
END;
$$;

ALTER FUNCTION delivery.claim_outbox(TEXT, INTEGER) OWNER TO course_owner;

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
    v_max_attempts INTEGER;
    v_backoff_base_ms INTEGER;
    v_backoff_max_ms INTEGER;
    v_jitter_max_ms INTEGER;
    v_base_delay_ms INTEGER;
    v_jitter_ms INTEGER;
BEGIN
    -- COURSE_OUTBOX_MAX_ATTEMPTS / _BACKOFF_BASE_MS / _BACKOFF_MAX_MS /
    -- _JITTER_MAX_MS; значения по умолчанию совпадают с test profile
    -- контракта: 4 попытки включая первую, 200/400/800 мс, jitter 0..100 мс.
    v_max_attempts    := COALESCE(NULLIF(current_setting('course.outbox_max_attempts', true), '')::INTEGER, 4);
    v_backoff_base_ms := COALESCE(NULLIF(current_setting('course.outbox_backoff_base_ms', true), '')::INTEGER, 200);
    v_backoff_max_ms  := COALESCE(NULLIF(current_setting('course.outbox_backoff_max_ms', true), '')::INTEGER, 800);
    v_jitter_max_ms   := COALESCE(NULLIF(current_setting('course.outbox_jitter_max_ms', true), '')::INTEGER, 100);

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

    -- base * 2^(уже сделанные попытки), не больше max: при 200/800 это 200, 400, 800.
    v_base_delay_ms := LEAST(v_backoff_base_ms * power(2, v_row.attempt_count)::INTEGER, v_backoff_max_ms);
    v_jitter_ms := CASE WHEN v_jitter_max_ms > 0 THEN floor(random() * (v_jitter_max_ms + 1))::INTEGER ELSE 0 END;

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
