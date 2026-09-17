-- ============================================================
-- Миграция 002: Реализация функций api.invoke и target-функций
-- ============================================================

-- 1. api.invoke - диспетчер действий
CREATE OR REPLACE FUNCTION api.invoke(
    p_module TEXT,
    p_action TEXT,
    p_version INTEGER,
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = course, api, public, pg_catalog
AS $$
DECLARE
    v_action_catalog course.action_catalog%ROWTYPE;
    v_correlation_id UUID;
    v_principal TEXT;
    v_request_id TEXT;
    v_payload_hash TEXT;
    v_result JSONB;
    v_status TEXT;
    v_outcome TEXT;
    v_actual_version INTEGER;
BEGIN
    v_correlation_id := COALESCE((p_context->>'correlationId')::UUID, gen_random_uuid());
    v_principal := p_context->>'principal';
    v_request_id := p_context->>'requestId';
    v_payload_hash := ENCODE(DIGEST(p_payload::TEXT, 'sha256'), 'hex');

    IF p_version IS NOT NULL THEN
        SELECT * INTO v_action_catalog 
        FROM course.action_catalog
        WHERE module = p_module 
          AND action = p_action 
          AND version = p_version 
          AND enabled = TRUE;
    ELSE
        SELECT * INTO v_action_catalog 
        FROM course.action_catalog
        WHERE module = p_module 
          AND action = p_action 
          AND is_default = TRUE 
          AND enabled = TRUE
        LIMIT 1;
    END IF;

    IF v_action_catalog IS NULL THEN
        PERFORM course.log_dispatch(
            v_correlation_id, v_request_id, p_module, p_action, 
            COALESCE(p_version, 0), v_principal, v_payload_hash,
            'ERROR', NULL
        );
        
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'action.not_found',
            'message', 'Action not found or disabled',
            'retryable', false
        );
    END IF;

    v_actual_version := v_action_catalog.version;

    IF NOT course.check_policy(p_context, v_action_catalog.required_policy) THEN
        PERFORM course.log_dispatch(
            v_correlation_id, v_request_id, p_module, p_action,
            v_actual_version, v_principal, v_payload_hash,
            'ERROR', NULL
        );
        
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'access.denied',
            'message', 'Insufficient scopes',
            'retryable', false
        );
    END IF;

    BEGIN
        EXECUTE FORMAT(
            'SELECT %I.%I($1, $2)',
            v_action_catalog.target_schema,
            v_action_catalog.target_function
        )
        INTO v_result
        USING p_context, p_payload;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM course.log_dispatch(
                v_correlation_id, v_request_id, p_module, p_action,
                v_actual_version, v_principal, v_payload_hash,
                'ERROR', NULL
            );
            
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'internal.error',
                'message', 'Target function execution failed',
                'retryable', false
            );
    END;

    v_status := COALESCE(v_result->>'status', 'error');
    v_outcome := v_result->>'outcome';

    IF v_status NOT IN ('ok', 'error') THEN
        PERFORM course.log_dispatch(
            v_correlation_id, v_request_id, p_module, p_action,
            v_actual_version, v_principal, v_payload_hash,
            'ERROR', NULL
        );
        
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'action.contract_violation',
            'message', 'Invalid status in response',
            'retryable', false
        );
    END IF;

    IF v_status = 'ok' THEN
        IF NOT (v_action_catalog.outcomes ? v_outcome) THEN
            PERFORM course.log_dispatch(
                v_correlation_id, v_request_id, p_module, p_action,
                v_actual_version, v_principal, v_payload_hash,
                'ERROR', NULL
            );
            
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'action.contract_violation',
                'message', 'Outcome not declared in manifest',
                'retryable', false
            );
        END IF;

        IF NOT (v_result ? 'result') THEN
            PERFORM course.log_dispatch(
                v_correlation_id, v_request_id, p_module, p_action,
                v_actual_version, v_principal, v_payload_hash,
                'ERROR', NULL
            );
            
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'action.contract_violation',
                'message', 'Result is required for successful response',
                'retryable', false
            );
        END IF;
    END IF;

    PERFORM course.log_dispatch(
        v_correlation_id, v_request_id, p_module, p_action,
        v_actual_version, v_principal, v_payload_hash,
        CASE WHEN v_status = 'ok' THEN 'OK' ELSE 'ERROR' END,
        v_outcome
    );

    RETURN jsonb_build_object(
        'status', v_status,
        'outcome', v_outcome,
        'result', COALESCE(v_result->'result', '{}'::JSONB),
        'version', v_actual_version
    ) || CASE 
        WHEN v_result->>'message' IS NOT NULL 
        THEN jsonb_build_object('message', v_result->>'message')
        ELSE '{}'::JSONB
    END || CASE 
        WHEN v_result->>'code' IS NOT NULL 
        THEN jsonb_build_object('code', v_result->>'code')
        ELSE '{}'::JSONB
    END || CASE 
        WHEN v_result->>'retryable' IS NOT NULL 
        THEN jsonb_build_object('retryable', (v_result->>'retryable')::BOOLEAN)
        ELSE '{}'::JSONB
    END;
END;
$$;

-- 2. Вспомогательная функция для проверки политики
CREATE OR REPLACE FUNCTION course.check_policy(
    p_context JSONB,
    p_required_policy JSONB
) RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = course, api, public, pg_catalog
AS $$
DECLARE
    v_scope TEXT;
BEGIN
    IF p_required_policy IS NULL OR jsonb_array_length(p_required_policy) = 0 THEN
        RETURN TRUE;
    END IF;

    FOR v_scope IN SELECT jsonb_array_elements_text(p_required_policy)
    LOOP
        IF NOT (p_context->'scopes' ? v_scope) THEN
            RETURN FALSE;
        END IF;
    END LOOP;

    RETURN TRUE;
END;
$$;

-- 3. Вспомогательная функция для логирования диспатчей
CREATE OR REPLACE FUNCTION course.log_dispatch(
    p_correlation_id UUID,
    p_request_id TEXT,
    p_module TEXT,
    p_action TEXT,
    p_version INTEGER,
    p_principal TEXT,
    p_payload_hash TEXT,
    p_status TEXT,
    p_outcome TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = course, api, public, pg_catalog
AS $$
BEGIN
    INSERT INTO course.action_dispatches (
        correlation_id,
        request_id,
        module,
        action,
        version,
        principal,
        payload_hash,
        status,
        outcome
    ) VALUES (
        p_correlation_id,
        p_request_id,
        p_module,
        p_action,
        p_version,
        p_principal,
        p_payload_hash,
        p_status,
        p_outcome
    );
END;
$$;

-- 4. payment.request - создание платежа (course.payment_request)
CREATE OR REPLACE FUNCTION course.payment_request(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = course, api, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_request_id TEXT;
    v_principal TEXT;
    v_operation_kind TEXT;
    v_amount NUMERIC(19,2);
    v_currency TEXT;
    v_payload_hash TEXT;
    v_existing_record RECORD;
BEGIN
    v_request_id := p_context->>'requestId';
    v_principal := p_context->>'principal';
    
    IF NOT (p_payload ? 'operationKind') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Missing required field: operationKind'
        );
    END IF;

    IF NOT (p_payload ? 'amount') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Missing required field: amount'
        );
    END IF;

    IF NOT (p_payload ? 'currency') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Missing required field: currency'
        );
    END IF;

    v_operation_kind := p_payload->>'operationKind';
    v_currency := p_payload->>'currency';

    IF v_operation_kind NOT IN ('PAYMENT_EXECUTION', 'PAYMENT_APPROVAL') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'operationKind must be PAYMENT_EXECUTION or PAYMENT_APPROVAL'
        );
    END IF;

    IF v_currency != 'RUB' THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Currency must be RUB'
        );
    END IF;

    -- amount обязан быть JSON-строкой, а не числом
    IF jsonb_typeof(p_payload->'amount') != 'string' THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'amount must be a string'
        );
    END IF;

    BEGIN
        -- Точный формат из контракта
        IF p_payload->>'amount' !~ '^(?:0\.0[1-9]|0\.[1-9][0-9]?|[1-9][0-9]{0,15}(?:\.[0-9]{1,2})?)$' THEN
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'payload.invalid',
                'message', 'amount must match the required decimal format'
            );
        END IF;

        v_amount := (p_payload->>'amount')::NUMERIC(19,2);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'payload.invalid',
                'message', 'Invalid amount format'
            );
    END;

    IF EXISTS (
        SELECT 1 FROM jsonb_object_keys(p_payload) AS key
        WHERE key NOT IN ('operationKind', 'amount', 'currency')
    ) THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Unknown fields in payload'
        );
    END IF;

    v_payload_hash := ENCODE(DIGEST(p_payload::TEXT, 'sha256'), 'hex');

    BEGIN
        v_operation_id := gen_random_uuid();
        
        INSERT INTO course.operations (
            operation_id,
            request_id,
            principal,
            payload_hash,
            operation_kind,
            amount,
            currency,
            status
        ) VALUES (
            v_operation_id,
            v_request_id,
            v_principal,
            v_payload_hash,
            v_operation_kind,
            v_amount,
            v_currency,
            'CREATED'
        );

        INSERT INTO course.operation_events (
            operation_id,
            event_type,
            payload_hash
        ) VALUES (
            v_operation_id,
            'OPERATION_CREATED',
            v_payload_hash
        );

        RETURN jsonb_build_object(
            'status', 'ok',
            'outcome', 'CREATED',
            'result', jsonb_build_object(
                'operationId', v_operation_id,
                'requestId', v_request_id,
                'operationKind', v_operation_kind,
                'amount', v_amount::TEXT,
                'currency', v_currency,
                'status', 'CREATED'
            )
        );

    EXCEPTION 
        WHEN unique_violation THEN
            SELECT 
                operation_id,
                request_id,
                payload_hash,
                operation_kind,
                amount,
                currency,
                status
            INTO v_existing_record
            FROM course.operations
            WHERE principal = v_principal AND request_id = v_request_id;

            IF v_existing_record.payload_hash = v_payload_hash THEN
                RETURN jsonb_build_object(
                    'status', 'ok',
                    'outcome', 'CREATED',
                    'result', jsonb_build_object(
                        'operationId', v_existing_record.operation_id,
                        'requestId', v_existing_record.request_id,
                        'operationKind', v_existing_record.operation_kind,
                        'amount', v_existing_record.amount::TEXT,
                        'currency', v_existing_record.currency,
                        'status', v_existing_record.status
                    )
                );
            ELSE
                RETURN jsonb_build_object(
                    'status', 'error',
                    'code', 'idempotency.conflict',
                    'message', 'Same idempotency key with different payload',
                    'retryable', false
                );
            END IF;
    END;
END;
$$;

-- 5. operation.get - получение операции
CREATE OR REPLACE FUNCTION course.operation_get(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = course, api, public, pg_catalog
AS $$
DECLARE
    v_operation_id UUID;
    v_operation RECORD;
BEGIN
    IF NOT (p_payload ? 'operationId') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Missing required field: operationId'
        );
    END IF;

    BEGIN
        v_operation_id := (p_payload->>'operationId')::UUID;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'payload.invalid',
                'message', 'Invalid operationId format'
            );
    END;

    SELECT 
        operation_id,
        request_id,
        operation_kind,
        amount,
        currency,
        status
    INTO v_operation
    FROM course.operations
    WHERE operation_id = v_operation_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'operation.not_found',
            'message', 'Operation not found',
            'retryable', false
        );
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', 'FOUND',
        'result', jsonb_build_object(
            'operationId', v_operation.operation_id,
            'requestId', v_operation.request_id,
            'operationKind', v_operation.operation_kind,
            'amount', v_operation.amount::TEXT,
            'currency', v_operation.currency,
            'status', v_operation.status
        )
    );
END;
$$;

-- 6. Функция для публикации action (идемпотентная) - УПРОЩЕНА
CREATE OR REPLACE FUNCTION course.publish_action(
    p_module TEXT,
    p_action TEXT,
    p_version INTEGER,
    p_http_method TEXT,
    p_target_schema TEXT,
    p_target_function TEXT,
    p_request_schema JSONB,
    p_response_schema JSONB,
    p_outcomes JSONB,
    p_required_policy JSONB,
    p_idempotency_mode TEXT,
    p_idempotency_scope TEXT,
    p_timeout_ms INTEGER,
    p_enabled BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = course, api, public, pg_catalog
AS $$
DECLARE
    v_existing course.action_catalog%ROWTYPE;
    v_is_first_version BOOLEAN;
    v_existing_json JSONB;
    v_new_json JSONB;
BEGIN
    SELECT * INTO v_existing
    FROM course.action_catalog
    WHERE module = p_module AND action = p_action AND version = p_version;

    IF FOUND THEN
        -- ✅ Сравниваем JSON-представления всех полей
        v_existing_json := jsonb_build_object(
            'http_method', v_existing.http_method,
            'target_schema', v_existing.target_schema,
            'target_function', v_existing.target_function,
            'request_schema', v_existing.request_schema,
            'response_schema', v_existing.response_schema,
            'outcomes', v_existing.outcomes,
            'required_policy', v_existing.required_policy,
            'idempotency_mode', v_existing.idempotency_mode,
            'idempotency_scope', v_existing.idempotency_scope,
            'timeout_ms', v_existing.timeout_ms,
            'enabled', v_existing.enabled
        );

        v_new_json := jsonb_build_object(
            'http_method', p_http_method,
            'target_schema', p_target_schema,
            'target_function', p_target_function,
            'request_schema', p_request_schema,
            'response_schema', p_response_schema,
            'outcomes', p_outcomes,
            'required_policy', p_required_policy,
            'idempotency_mode', p_idempotency_mode,
            'idempotency_scope', p_idempotency_scope,
            'timeout_ms', p_timeout_ms,
            'enabled', p_enabled
        );

        IF v_existing_json <> v_new_json THEN
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'manifest.conflict',
                'message', 'Published action version cannot be changed: '
                            || p_module || '.' || p_action || ' v' || p_version,
                'meta', jsonb_build_object('contractVersion', 'course-1')
            );
        END IF;

        RETURN jsonb_build_object(
            'status', 'ok',
            'result', jsonb_build_object(
                'resource', 'action',
                'operation', 'published',
                'key', p_module || '.' || p_action,
                'version', p_version
            ),
            'meta', jsonb_build_object('contractVersion', 'course-1')
        );
    END IF;

    -- Определяем, является ли эта версия первой для данного action
    SELECT NOT EXISTS (
        SELECT 1 FROM course.action_catalog
        WHERE module = p_module AND action = p_action
    ) INTO v_is_first_version;

    INSERT INTO course.action_catalog (
        module, action, version, http_method,
        target_schema, target_function,
        request_schema, response_schema, outcomes,
        required_policy, idempotency_mode, idempotency_scope,
        timeout_ms, enabled, is_default
    ) VALUES (
        p_module, p_action, p_version, p_http_method,
        p_target_schema, p_target_function,
        p_request_schema, p_response_schema, p_outcomes,
        p_required_policy, p_idempotency_mode, p_idempotency_scope,
        p_timeout_ms,
        p_enabled,
        v_is_first_version
    );

    RETURN jsonb_build_object(
        'status', 'ok',
        'result', jsonb_build_object(
            'resource', 'action',
            'operation', 'published',
            'key', p_module || '.' || p_action,
            'version', p_version
        ),
        'meta', jsonb_build_object('contractVersion', 'course-1')
    );
END;
$$;

-- ============================================================
-- 7. Target функции для opencheck.probe
-- ============================================================

-- 7.1 opencheck.probe_v1
CREATE OR REPLACE FUNCTION opencheck.probe_v1(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = opencheck, course, api, public, pg_catalog
AS $$
DECLARE
    v_mode TEXT;
    v_value TEXT;
    v_correlation_id UUID;
    v_principal TEXT;
BEGIN
    v_correlation_id := COALESCE((p_context->>'correlationId')::UUID, gen_random_uuid());
    v_principal := p_context->>'principal';
    
    IF NOT (p_payload ? 'mode') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Missing required field: mode',
            'retryable', false
        );
    END IF;

    v_mode := p_payload->>'mode';
    v_value := p_payload->>'value';

    IF v_mode = 'ok' THEN
        INSERT INTO opencheck.canary (marker, correlation_id, principal, created_at)
        VALUES (v_value, v_correlation_id, v_principal, NOW());
        
        RETURN jsonb_build_object(
            'status', 'ok',
            'outcome', 'APPLIED',
            'result', jsonb_build_object(
                'stored', true,
                'revision', 1,
                'principal', v_principal
            ),
            'version', 1
        );
    ELSIF v_mode = 'error' THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'probe.forced',
            'message', 'Forced error for testing rollback',
            'retryable', false
        );
    ELSIF v_mode = 'unknown_outcome' THEN
        RETURN jsonb_build_object(
            'status', 'ok',
            'outcome', 'UNKNOWN',
            'result', jsonb_build_object(
                'message', 'Unknown outcome test'
            )
        );
    ELSIF v_mode = 'invalid_result' THEN
        RETURN jsonb_build_object(
            'status', 'ok',
            'outcome', 'APPLIED',
            'result', jsonb_build_object(
                'stored', 'not-a-boolean',
                'revision', 1,
                'principal', v_principal
            )
        );
    ELSE
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Invalid mode: ' || v_mode,
            'retryable', false
        );
    END IF;
END;
$$;

-- 7.2 opencheck.probe_v2
CREATE OR REPLACE FUNCTION opencheck.probe_v2(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = opencheck, course, api, public, pg_catalog
AS $$
DECLARE
    v_mode TEXT;
    v_value TEXT;
    v_correlation_id UUID;
    v_principal TEXT;
BEGIN
    v_correlation_id := COALESCE((p_context->>'correlationId')::UUID, gen_random_uuid());
    v_principal := p_context->>'principal';
    
    IF NOT (p_payload ? 'mode') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Missing required field: mode',
            'retryable', false
        );
    END IF;

    v_mode := p_payload->>'mode';
    v_value := p_payload->>'value';

    IF v_mode = 'ok' THEN
        INSERT INTO opencheck.canary (marker, correlation_id, principal, created_at)
        VALUES (v_value, v_correlation_id, v_principal, NOW());
        
        RETURN jsonb_build_object(
            'status', 'ok',
            'outcome', 'APPLIED',
            'result', jsonb_build_object(
                'message', 'Probe v2 executed successfully',
                'value', v_value,
                'correlationId', v_correlation_id
            ),
            'version', 2
        );
    ELSIF v_mode = 'error' THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'probe.forced',
            'message', 'Forced error for testing rollback',
            'retryable', false
        );
    ELSE
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'Invalid mode: ' || v_mode,
            'retryable', false
        );
    END IF;
END;
$$;