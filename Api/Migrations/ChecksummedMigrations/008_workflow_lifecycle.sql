-- ============================================================
-- Миграция 008: жизненный цикл процесса на уровне CLI —
-- workflow.start_process, workflow.receive_signal,
-- общий helper workflow.apply_signal, и недостающие колонки,
-- которые выявились при разборе полной схемы workflow-map
-- (contracts/course-1/workflow-map.schema.json из шаблона недели 2).
-- ============================================================

-- declared_outcome — фиксированный outcome, который объявляет сама
-- карта для wait_signal и end шагов (см. waitSignalStep.outcome и
-- endStep.outcome в workflow-map.schema.json). Для AUTOMATIC/MANUAL
-- остаётся NULL — их outcome определяется по факту исполнения
-- action'а или решения человека, а не заранее.
ALTER TABLE workflow.step_definition ADD COLUMN IF NOT EXISTS declared_outcome TEXT;

-- ============================================================
-- 1. workflow.apply_signal — общий helper: применяет ОДИН уже
--    принятый (ACCEPTED) сигнал к ОДНОМУ конкретному WAITING
--    step_instance. Используется в двух местах: из enter_step,
--    когда сигнал пришёл РАНЬШЕ входа в wait_signal, и из
--    receive_signal, когда сигнал приходит, пока процесс УЖЕ
--    стоит на wait_signal (обычный, самый частый случай).
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.apply_signal(
    p_step_instance_id UUID,
    p_message_id TEXT
) RETURNS TEXT -- next_step_key, для дальнейшего workflow.enter_step вызывающей стороной
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, course, public, pg_catalog
AS $$
DECLARE
    v_step workflow.step_instance%ROWTYPE;
    v_process workflow.process_instance%ROWTYPE;
    v_step_def workflow.step_definition%ROWTYPE;
    v_next_step_key TEXT;
BEGIN
    SELECT * INTO v_step FROM workflow.step_instance WHERE step_instance_id = p_step_instance_id FOR UPDATE;
    SELECT * INTO v_process FROM workflow.process_instance WHERE process_id = v_step.process_id FOR UPDATE;
    SELECT * INTO v_step_def
    FROM workflow.step_definition
    WHERE flow_name = v_process.flow_name AND flow_version = v_process.flow_version AND step_key = v_step.step_key;

    UPDATE workflow.workflow_signal SET status = 'APPLIED' WHERE message_id = p_message_id;

    UPDATE workflow.step_instance
    SET state = 'COMPLETED', outcome = v_step_def.declared_outcome, completed_at = now()
    WHERE step_instance_id = p_step_instance_id;

    INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
    VALUES (v_process.process_id, p_step_instance_id, 'SignalApplied');

    SELECT next_step_key INTO v_next_step_key
    FROM workflow.transition_definition
    WHERE flow_name = v_process.flow_name AND flow_version = v_process.flow_version
      AND step_key = v_step.step_key AND outcome = v_step_def.declared_outcome;

    -- Отсутствие перехода здесь означало бы, что дефектная карта прошла
    -- publish-валидацию — не должно происходить, но не заглатываем тихо.
    IF v_next_step_key IS NULL THEN
        RAISE EXCEPTION 'workflow.apply_signal: no transition for step % outcome % — should have been caught at publish time',
            v_step.step_key, v_step_def.declared_outcome;
    END IF;

    RETURN v_next_step_key;
END;
$$;

-- ============================================================
-- 2. workflow.enter_step — переопределяется: WAIT_SIGNAL-ветка
--    теперь использует declared_outcome и общий apply_signal,
--    а не произвольный "LIMIT 1" по transition_definition.
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.enter_step(
    p_process_id UUID,
    p_step_key TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, course, public, pg_catalog
AS $$
DECLARE
    v_process workflow.process_instance%ROWTYPE;
    v_step_def workflow.step_definition%ROWTYPE;
    v_step_instance_id UUID;
    v_pending_signal workflow.workflow_signal%ROWTYPE;
    v_next_step_key TEXT;
BEGIN
    SELECT * INTO v_process FROM workflow.process_instance WHERE process_id = p_process_id FOR UPDATE;

    SELECT * INTO v_step_def
    FROM workflow.step_definition
    WHERE flow_name = v_process.flow_name AND flow_version = v_process.flow_version AND step_key = p_step_key;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'workflow.enter_step: step % not found for %/% — should have been caught by publish-time validation',
            p_step_key, v_process.flow_name, v_process.flow_version;
    END IF;

    INSERT INTO workflow.step_instance (process_id, step_key, step_type, state)
    VALUES (
        p_process_id, p_step_key, v_step_def.step_type,
        CASE v_step_def.step_type WHEN 'AUTOMATIC' THEN 'READY' ELSE 'WAITING' END
    )
    RETURNING step_instance_id INTO v_step_instance_id;

    UPDATE workflow.process_instance
    SET current_step_key = p_step_key,
        updated_at = now(),
        state = CASE v_step_def.step_type
            WHEN 'AUTOMATIC'    THEN 'RUNNING'
            WHEN 'WAIT_SIGNAL'  THEN 'WAITING_SIGNAL'
            WHEN 'MANUAL'       THEN 'WAITING_MANUAL'
            WHEN 'END'          THEN 'COMPLETED'
        END
    WHERE process_id = p_process_id;

    INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
    VALUES (p_process_id, v_step_instance_id, 'StepEntered');

    IF v_step_def.step_type = 'AUTOMATIC' THEN
        INSERT INTO workflow.workflow_job (process_id, step_instance_id, state)
        VALUES (p_process_id, v_step_instance_id, 'READY');

    ELSIF v_step_def.step_type = 'WAIT_SIGNAL' THEN
        -- "Сигнал типа, объявленного в pinned map, можно принять до входа
        -- в соответствующий wait_signal: он хранится как ACCEPTED и
        -- атомарно применяется при входе в ожидание" (04_assignment.md).
        SELECT * INTO v_pending_signal
        FROM workflow.workflow_signal
        WHERE process_id = p_process_id
          AND signal_type = v_step_def.wait_signal_type
          AND status = 'ACCEPTED'
        ORDER BY received_at
        LIMIT 1
        FOR UPDATE;

        IF FOUND THEN
            v_next_step_key := workflow.apply_signal(v_step_instance_id, v_pending_signal.message_id);
            PERFORM workflow.enter_step(p_process_id, v_next_step_key);
        END IF;

    ELSIF v_step_def.step_type = 'END' THEN
        UPDATE workflow.step_instance SET state = 'COMPLETED', outcome = v_step_def.declared_outcome, completed_at = now()
            WHERE step_instance_id = v_step_instance_id;
        INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
            VALUES (p_process_id, v_step_instance_id, 'ProcessCompleted');
    END IF;
    -- MANUAL: завершение — за пределами недели 2 (публичный action для
    -- этого входит в неделю 3), здесь шаг просто остаётся WAITING.

    RETURN v_step_instance_id;
END;
$$;

-- ============================================================
-- 3. workflow.start_process — вызывается CLI-командой flow start.
--    Идемпотентен по паре (flow_name, business_key): совпавший
--    process_data — тот же процесс; расхождение — conflict, даже
--    после смены активной версии (сравниваем с уже созданным
--    process_instance, а не с текущей активной версией заново).
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.start_process(
    p_flow_name TEXT,
    p_business_key TEXT,
    p_process_data JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, course, public, pg_catalog
AS $$
DECLARE
    v_existing workflow.process_instance%ROWTYPE;
    v_active_version INTEGER;
    v_start_step TEXT;
    v_process_id UUID;
    v_final workflow.process_instance%ROWTYPE;
BEGIN
    SELECT * INTO v_existing
    FROM workflow.process_instance
    WHERE flow_name = p_flow_name AND business_key = p_business_key
    FOR UPDATE;

    IF FOUND THEN
        IF v_existing.process_data = p_process_data THEN
            RETURN jsonb_build_object(
                'status', 'ok',
                'processId', v_existing.process_id,
                'flowName', v_existing.flow_name,
                'flowVersion', v_existing.flow_version,
                'state', v_existing.state
            );
        END IF;

        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.start_conflict',
            'message', 'business key already used with different process data'
        );
    END IF;

    SELECT flow_version INTO v_active_version
    FROM workflow.flow_version
    WHERE flow_name = p_flow_name AND is_active = TRUE;

    IF v_active_version IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.no_active_version',
            'message', format('flow %s has no active published version', p_flow_name)
        );
    END IF;

    SELECT step_key INTO v_start_step
    FROM workflow.step_definition
    WHERE flow_name = p_flow_name AND flow_version = v_active_version AND is_start = TRUE;

    INSERT INTO workflow.process_instance (business_key, flow_name, flow_version, state, process_data)
    VALUES (p_business_key, p_flow_name, v_active_version, 'CREATED', p_process_data)
    RETURNING process_id INTO v_process_id;

    PERFORM workflow.enter_step(v_process_id, v_start_step);

    SELECT * INTO v_final FROM workflow.process_instance WHERE process_id = v_process_id;

    RETURN jsonb_build_object(
        'status', 'ok',
        'processId', v_final.process_id,
        'flowName', v_final.flow_name,
        'flowVersion', v_final.flow_version,
        'state', v_final.state
    );
END;
$$;

-- ============================================================
-- 4. workflow.receive_signal — вызывается CLI-командой flow signal.
--    message_id глобально уникален: duplicate только при полном
--    совпадении process+type+body, любое расхождение — conflict
--    без изменения существующей строки.
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.receive_signal(
    p_process_id UUID,
    p_message_id TEXT,
    p_signal_type TEXT,
    p_body JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, course, public, pg_catalog
AS $$
DECLARE
    v_body_hash TEXT;
    v_existing workflow.workflow_signal%ROWTYPE;
    v_process workflow.process_instance%ROWTYPE;
    v_type_declared BOOLEAN;
    v_waiting_step workflow.step_instance%ROWTYPE;
    v_next_step_key TEXT;
BEGIN
    v_body_hash := ENCODE(DIGEST(p_body::TEXT, 'sha256'), 'hex');

    SELECT * INTO v_existing FROM workflow.workflow_signal WHERE message_id = p_message_id FOR UPDATE;

    IF FOUND THEN
        IF v_existing.process_id = p_process_id AND v_existing.signal_type = p_signal_type AND v_existing.body_hash = v_body_hash THEN
            RETURN jsonb_build_object(
                'status', 'ok', 'processId', p_process_id, 'messageId', p_message_id,
                'signalType', p_signal_type, 'signalStatus', 'duplicate'
            );
        END IF;

        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.signal_conflict',
            'message', 'message_id already used with different process/type/body'
        );
    END IF;

    SELECT * INTO v_process FROM workflow.process_instance WHERE process_id = p_process_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'error', 'code', 'process.not_found', 'message', 'process not found');
    END IF;

    -- Сигнал типа, не объявленного в закреплённой (pinned) версии
    -- карты этого процесса, отклоняется без вставки строки.
    SELECT EXISTS (
        SELECT 1 FROM workflow.step_definition
        WHERE flow_name = v_process.flow_name AND flow_version = v_process.flow_version
          AND step_type = 'WAIT_SIGNAL' AND wait_signal_type = p_signal_type
    ) INTO v_type_declared;

    IF NOT v_type_declared THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.unknown_signal_type',
            'message', format('signal type %s is not declared in pinned map %s v%s', p_signal_type, v_process.flow_name, v_process.flow_version)
        );
    END IF;

    INSERT INTO workflow.workflow_signal (message_id, process_id, signal_type, body, body_hash, status)
    VALUES (p_message_id, p_process_id, p_signal_type, p_body, v_body_hash, 'ACCEPTED');

    -- Сигнал для уже завершённого процесса сохраняется, но процесс не двигаем.
    IF v_process.state NOT IN ('WAITING_SIGNAL') THEN
        RETURN jsonb_build_object(
            'status', 'ok', 'processId', p_process_id, 'messageId', p_message_id,
            'signalType', p_signal_type, 'signalStatus', 'accepted'
        );
    END IF;

    -- Обычный случай: процесс прямо сейчас стоит на wait_signal с этим
    -- типом — применяем немедленно, а не оставляем висеть до
    -- гипотетического повторного входа в этот же шаг.
    SELECT si.* INTO v_waiting_step
    FROM workflow.step_instance si
    JOIN workflow.step_definition sd
        ON sd.flow_name = v_process.flow_name AND sd.flow_version = v_process.flow_version AND sd.step_key = si.step_key
    WHERE si.process_id = p_process_id AND si.state = 'WAITING' AND si.step_type = 'WAIT_SIGNAL'
      AND sd.wait_signal_type = p_signal_type
    FOR UPDATE;

    IF FOUND THEN
        v_next_step_key := workflow.apply_signal(v_waiting_step.step_instance_id, p_message_id);
        PERFORM workflow.enter_step(p_process_id, v_next_step_key);
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok', 'processId', p_process_id, 'messageId', p_message_id,
        'signalType', p_signal_type, 'signalStatus', 'accepted'
    );
END;
$$;

-- ============================================================
-- Владение
-- ============================================================
ALTER FUNCTION workflow.apply_signal(UUID, TEXT) OWNER TO course_owner;
ALTER FUNCTION workflow.enter_step(UUID, TEXT) OWNER TO course_owner;
ALTER FUNCTION workflow.start_process(TEXT, TEXT, JSONB) OWNER TO course_owner;
ALTER FUNCTION workflow.receive_signal(UUID, TEXT, TEXT, JSONB) OWNER TO course_owner;

-- start_process/receive_signal — это административно-доверенные CLI-
-- команды (flow start / flow signal), а не путь workflow_worker.
-- REVOKE EXECUTE ON ALL FUNCTIONS уже применялся в 007 и покрыл бы их
-- автоматически при создании в рамках той же миграции, но эти функции
-- создаются здесь, в 008, поэтому повторяем defense-in-depth явно.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA workflow FROM PUBLIC;

COMMENT ON FUNCTION workflow.apply_signal(UUID, TEXT) IS
    'Применяет один уже принятый (ACCEPTED) сигнал к одному WAITING step_instance; используется enter_step и receive_signal';
COMMENT ON FUNCTION workflow.start_process(TEXT, TEXT, JSONB) IS
    'flow start: идемпотентно по (flow_name, business_key), стартует по текущей активной версии карты';
COMMENT ON FUNCTION workflow.receive_signal(UUID, TEXT, TEXT, JSONB) IS
    'flow signal: дедупликация по message_id, отклонение необъявленных типов, немедленное применение к ожидающему шагу';
