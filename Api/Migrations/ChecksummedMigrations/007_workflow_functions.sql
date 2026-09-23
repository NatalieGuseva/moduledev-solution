-- ============================================================
-- Миграция 007: workflow.claim_jobs / finish_job / fail_job,
-- внутренний helper workflow.enter_step и функция под action
-- "workflow.get" — workflow.get_process
-- ============================================================

-- Диагностическая колонка: сохранённый result последней попытки
-- пригождается для отладки, контрактом не является (см. 04_assignment.md:
-- "дополнительные диагностические колонки не являются контрактом").
ALTER TABLE workflow.task_attempt ADD COLUMN IF NOT EXISTS result JSONB;

-- task.timeout_ms — обязательное поле карты (contracts/course-1/workflow-map.schema.json),
-- позволяющее переопределить дедлайн конкретного использования action внутри
-- карты, а не всегда брать timeout_ms из самого action_catalog. Добавляется
-- здесь, а не в 008, потому что claim_jobs (эта миграция) уже должен его отдавать.
ALTER TABLE workflow.task_definition ADD COLUMN IF NOT EXISTS timeout_ms INTEGER;

-- ============================================================
-- 1. workflow.enter_step — внутренний helper.
--    НЕ входит в список функций, на которые получает EXECUTE
--    workflow_worker (только claim_jobs/finish_job/fail_job/
--    api.invoke). Вызывается изнутри finish_job тем же владельцем
--    (course_owner), поэтому отдельный GRANT ему не нужен —
--    владелец объекта имеет EXECUTE на свои же функции всегда,
--    даже после REVOKE ... FROM PUBLIC ниже.
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
        -- Не должно происходить: semantic validator на этапе publish обязан
        -- гарантировать, что каждый next_step_key существует. Если это всё
        -- же случилось — это дефект карты, который прополз мимо валидации,
        -- а не runtime-ситуация, которую стоит тихо проглатывать.
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
        -- Если сигнал этого типа уже был принят раньше (ACCEPTED, "Сигнал
        -- типа, объявленного в pinned map, можно принять до входа в
        -- соответствующий wait_signal" из 04_assignment.md) — применяем
        -- его немедленно и атомарно, в этой же транзакции.
        SELECT * INTO v_pending_signal
        FROM workflow.workflow_signal
        WHERE process_id = p_process_id
          AND signal_type = v_step_def.wait_signal_type
          AND status = 'ACCEPTED'
        ORDER BY received_at
        LIMIT 1
        FOR UPDATE;

        IF FOUND THEN
            UPDATE workflow.workflow_signal SET status = 'APPLIED' WHERE message_id = v_pending_signal.message_id;
            UPDATE workflow.step_instance SET state = 'COMPLETED', completed_at = now()
                WHERE step_instance_id = v_step_instance_id;
            INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
                VALUES (p_process_id, v_step_instance_id, 'SignalApplied');

            -- В рамках course-1 wait_signal не ветвится по содержимому
            -- сигнала: ровно один объявленный transition уводит дальше.
            -- Если карта когда-нибудь потребует ветвление по сигналу —
            -- это отдельное расширение контракта, не покрытое неделей 2.
            SELECT next_step_key INTO v_next_step_key
            FROM workflow.transition_definition
            WHERE flow_name = v_process.flow_name AND flow_version = v_process.flow_version
              AND step_key = p_step_key
            LIMIT 1;

            IF v_next_step_key IS NOT NULL THEN
                PERFORM workflow.enter_step(p_process_id, v_next_step_key);
            END IF;
        END IF;

    ELSIF v_step_def.step_type = 'END' THEN
        UPDATE workflow.step_instance SET state = 'COMPLETED', completed_at = now()
            WHERE step_instance_id = v_step_instance_id;
        INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
            VALUES (p_process_id, v_step_instance_id, 'ProcessCompleted');
    END IF;
    -- MANUAL: ничего дополнительно не создаём — шаг просто лежит в
    -- WAITING/WAITING_MANUAL до завершения через публичный action,
    -- которое по заданию входит в неделю 3, не в эту миграцию.

    RETURN v_step_instance_id;
END;
$$;

-- ============================================================
-- 2. workflow.claim_jobs — короткая транзакция без удержания
--    блокировки на время выполнения action. FOR UPDATE SKIP LOCKED
--    гарантирует, что два worker'а не возьмут один и тот же job.
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.claim_jobs(
    p_owner TEXT,
    p_limit INTEGER,
    p_lease_seconds INTEGER
) RETURNS TABLE (
    job_id UUID,
    execution_id UUID,
    attempt_id UUID,
    lease_version BIGINT,
    process_id UUID,
    step_instance_id UUID,
    action_module TEXT,
    action_name TEXT,
    action_version INTEGER,
    input_mapping JSONB,
    input_constants JSONB,
    max_attempts INTEGER,
    delays_ms JSONB,
    timeout_ms INTEGER,
    process_data JSONB,
    request_schema JSONB,
    response_schema JSONB,
    outcomes JSONB,
    required_policy JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, course, public, pg_catalog
AS $$
DECLARE
    v_job_ids UUID[];
BEGIN
    -- Кандидаты на захват — это не только READY/RETRY_WAIT: LEASED job,
    -- чей lease_until уже в прошлом, тоже обязан быть реклеймлен другим
    -- (или тем же) worker'ом. Раньше сюда попадали только READY/RETRY_WAIT,
    -- из-за чего job, чей владелец умер между claim и finish/fail (failpoint,
    -- kill -9), оставался в LEASED навсегда — никто и никогда не забирал
    -- его снова, finish_job/fail_job лишь ОТКЛОНЯЛИ запоздалый ответ
    -- прежнего владельца, но сами не возвращали job в оборот.
    SELECT array_agg(candidate.job_id) INTO v_job_ids
    FROM (
        SELECT j.job_id
        FROM workflow.workflow_job j
        WHERE (
                j.state IN ('READY', 'RETRY_WAIT')
                AND (j.next_attempt_at IS NULL OR j.next_attempt_at <= now())
              )
           OR (
                j.state = 'LEASED'
                AND j.lease_until IS NOT NULL
                AND j.lease_until < now()
              )
        ORDER BY j.next_attempt_at NULLS FIRST, j.created_at
        FOR UPDATE SKIP LOCKED
        LIMIT p_limit
    ) candidate;

    IF v_job_ids IS NULL THEN
        RETURN; -- нечего отдавать этому worker'у прямо сейчас
    END IF;

    -- Если среди захватываемых job'ов есть реклейм протухшего LEASED —
    -- предыдущая попытка (ещё формально 'RUNNING') больше никогда не будет
    -- закрыта своим воркером (он мёртв/завис на failpoint) — помечаем её
    -- STALE тем же способом, что finish_job/fail_job делают при запоздалом
    -- ответе, чтобы в task_attempt не оставалось вечно висящих RUNNING строк.
    UPDATE workflow.task_attempt ta
    SET status = 'STALE', finished_at = now()
    FROM workflow.workflow_job j
    WHERE ta.job_id = j.job_id
      AND j.job_id = ANY(v_job_ids)
      AND j.state = 'LEASED'
      AND ta.lease_version = j.lease_version
      AND ta.status = 'RUNNING';

    UPDATE workflow.workflow_job j
    SET state = 'LEASED',
        lease_owner = p_owner,
        lease_version = j.lease_version + 1,
        lease_until = now() + (p_lease_seconds || ' seconds')::interval
    WHERE j.job_id = ANY(v_job_ids);

    UPDATE workflow.step_instance si
    SET state = 'RUNNING'
    FROM workflow.workflow_job j
    WHERE j.job_id = ANY(v_job_ids) AND si.step_instance_id = j.step_instance_id;

    INSERT INTO workflow.task_attempt (job_id, execution_id, lease_version, attempt_number, status)
    SELECT
        j.job_id,
        j.execution_id,
        j.lease_version,
        COALESCE((SELECT MAX(ta.attempt_number) FROM workflow.task_attempt ta WHERE ta.job_id = j.job_id), 0) + 1,
        'RUNNING'
    FROM workflow.workflow_job j
    WHERE j.job_id = ANY(v_job_ids);

    -- Единый JOIN до action_catalog: worker получает всё нужное shared
    -- ActionExecutor'у одним вызовом, отдельное чтение каталога не требуется
    -- (прямая цитата требования из 04_assignment.md).
    RETURN QUERY
    SELECT
        j.job_id, j.execution_id, ta.attempt_id, j.lease_version,
        j.process_id, j.step_instance_id,
        td.action_module, td.action_name, td.action_version,
        td.input_mapping, td.input_constants, td.max_attempts, td.delays_ms, td.timeout_ms,
        pi.process_data,
        ac.request_schema, ac.response_schema, ac.outcomes, ac.required_policy
    FROM workflow.workflow_job j
    JOIN workflow.step_instance si ON si.step_instance_id = j.step_instance_id
    JOIN workflow.process_instance pi ON pi.process_id = j.process_id
    JOIN workflow.step_definition sd
        ON sd.flow_name = pi.flow_name AND sd.flow_version = pi.flow_version AND sd.step_key = si.step_key
    JOIN workflow.task_definition td ON td.id = sd.task_definition_id
    JOIN course.action_catalog ac
        ON ac.module = td.action_module AND ac.action = td.action_name AND ac.version = td.action_version
    JOIN workflow.task_attempt ta ON ta.job_id = j.job_id AND ta.lease_version = j.lease_version
    WHERE j.job_id = ANY(v_job_ids);
END;
$$;

-- ============================================================
-- 3. workflow.finish_job — принимается только при точном совпадении
--    job_id + owner + lease_version + ожидаемого state ('LEASED').
--    Сама схему/контракт результата НЕ валидирует — это уже сделал
--    C#-код (ActionExecutor) до вызова этой функции.
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.finish_job(
    p_job_id UUID,
    p_owner TEXT,
    p_lease_version BIGINT,
    p_outcome TEXT,
    p_result JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, course, public, pg_catalog
AS $$
DECLARE
    v_job workflow.workflow_job%ROWTYPE;
    v_step workflow.step_instance%ROWTYPE;
    v_process workflow.process_instance%ROWTYPE;
    v_transition workflow.transition_definition%ROWTYPE;
    v_next_step_instance_id UUID;
BEGIN
    SELECT * INTO v_job FROM workflow.workflow_job WHERE job_id = p_job_id FOR UPDATE;

    IF NOT FOUND
       OR v_job.lease_owner IS DISTINCT FROM p_owner
       OR v_job.lease_version <> p_lease_version
       OR v_job.state <> 'LEASED' THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.lease_stale',
            'message', 'job not found, or owner/leaseVersion/state no longer match'
        );
    END IF;

    -- Лизинг формально ещё не переиспользован (state всё ещё LEASED на
    -- это же owner/lease_version), но уже истёк по времени: reclaim мог
    -- ещё не случиться. По заданию это не должно расходовать attempt
    -- budget — помечаем попытку STALE и не трогаем job/step/process,
    -- дальше этим job'ом займётся claim_jobs при следующем reclaim.
    IF v_job.lease_until IS NOT NULL AND v_job.lease_until < now() THEN
        UPDATE workflow.task_attempt
        SET status = 'STALE', finished_at = now()
        WHERE job_id = p_job_id AND lease_version = p_lease_version AND status = 'RUNNING';

        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.lease_stale',
            'message', 'lease expired before finish was received'
        );
    END IF;

    SELECT * INTO v_step FROM workflow.step_instance WHERE step_instance_id = v_job.step_instance_id FOR UPDATE;
    SELECT * INTO v_process FROM workflow.process_instance WHERE process_id = v_job.process_id FOR UPDATE;

    -- attempt_count должен отражать реальное число попыток (как и на
    -- retry-ветке в fail_job) — иначе при успехе с первой попытки
    -- job.attempt_count остаётся 0, а task_attempt уже содержит 1
    -- строку: их количества расходятся.
    UPDATE workflow.workflow_job SET state = 'SUCCEEDED', attempt_count = attempt_count + 1 WHERE job_id = p_job_id;

    UPDATE workflow.task_attempt
    SET status = 'SUCCEEDED', outcome = p_outcome, result = p_result, finished_at = now()
    WHERE job_id = p_job_id AND lease_version = p_lease_version;

    UPDATE workflow.step_instance
    SET state = 'COMPLETED', outcome = p_outcome, completed_at = now()
    WHERE step_instance_id = v_step.step_instance_id;

    INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
    VALUES (v_process.process_id, v_step.step_instance_id, 'StepCompleted');

    SELECT * INTO v_transition
    FROM workflow.transition_definition
    WHERE flow_name = v_process.flow_name AND flow_version = v_process.flow_version
      AND step_key = v_step.step_key AND outcome = p_outcome;

    IF NOT FOUND THEN
        -- "Неизвестный runtime outcome не выбирает fallback transition"
        -- (04_assignment.md). Job/attempt/step уже честно зафиксировали
        -- результат выше, но дальше маршрут вести некуда — это дефект
        -- карты/контракта action'а, а не переходное состояние, поэтому
        -- переводим процесс в FAILED, а не оставляем его подвешенным.
        -- Job тоже терминальный: раз маршрута дальше нет, "SUCCEEDED"
        -- (проставленный выше как факт исполнения) вводит в заблуждение —
        -- с точки зрения процесса это несостоявшийся шаг, поэтому job
        -- переводим в DEAD, а не оставляем в SUCCEEDED.
        UPDATE workflow.workflow_job SET state = 'DEAD' WHERE job_id = p_job_id;
        UPDATE workflow.process_instance SET state = 'FAILED', updated_at = now()
            WHERE process_id = v_process.process_id;
        INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
            VALUES (v_process.process_id, v_step.step_instance_id, 'TaskFailed');

        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.unknown_outcome',
            'message', format('no transition declared for outcome %s from step %s', p_outcome, v_step.step_key)
        );
    END IF;

    v_next_step_instance_id := workflow.enter_step(v_process.process_id, v_transition.next_step_key);

    RETURN jsonb_build_object(
        'status', 'ok',
        'jobId', p_job_id,
        'processId', v_process.process_id,
        'nextStepKey', v_transition.next_step_key,
        'stepInstanceId', v_next_step_instance_id
    );
END;
$$;

-- ============================================================
-- 4. workflow.fail_job — вызывается отдельной транзакцией ПОСЛЕ
--    того, как транзакция с самим action уже откатилась.
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.fail_job(
    p_job_id UUID,
    p_owner TEXT,
    p_lease_version BIGINT,
    p_error_code TEXT,
    p_retryable BOOLEAN
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, course, public, pg_catalog
AS $$
DECLARE
    v_job workflow.workflow_job%ROWTYPE;
    v_step workflow.step_instance%ROWTYPE;
    v_task_def workflow.task_definition%ROWTYPE;
    v_delay_ms BIGINT;
BEGIN
    SELECT * INTO v_job FROM workflow.workflow_job WHERE job_id = p_job_id FOR UPDATE;

    IF NOT FOUND
       OR v_job.lease_owner IS DISTINCT FROM p_owner
       OR v_job.lease_version <> p_lease_version
       OR v_job.state <> 'LEASED' THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.lease_stale',
            'message', 'job not found, or owner/leaseVersion/state no longer match'
        );
    END IF;

    IF v_job.lease_until IS NOT NULL AND v_job.lease_until < now() THEN
        UPDATE workflow.task_attempt
        SET status = 'STALE', finished_at = now()
        WHERE job_id = p_job_id AND lease_version = p_lease_version AND status = 'RUNNING';

        RETURN jsonb_build_object(
            'status', 'error', 'code', 'workflow.lease_stale',
            'message', 'lease expired before fail was received'
        );
    END IF;

    SELECT * INTO v_step FROM workflow.step_instance WHERE step_instance_id = v_job.step_instance_id FOR UPDATE;

    SELECT td.* INTO v_task_def
    FROM workflow.process_instance pi
    JOIN workflow.step_definition sd
        ON sd.flow_name = pi.flow_name AND sd.flow_version = pi.flow_version AND sd.step_key = v_step.step_key
    JOIN workflow.task_definition td ON td.id = sd.task_definition_id
    WHERE pi.process_id = v_job.process_id;

    UPDATE workflow.task_attempt
    SET status = 'FAILED', error_code = p_error_code, finished_at = now()
    WHERE job_id = p_job_id AND lease_version = p_lease_version;

    -- Mapping error, unknown outcome и response contract violation
    -- (p_retryable = false, классификацию делает C#-сторона) либо
    -- исчерпанный бюджет попыток — job DEAD, step/process FAILED,
    -- обязательное событие TaskFailed (единственное имя события,
    -- жёстко зафиксированное заданием).
    IF (NOT p_retryable) OR (v_job.attempt_count + 1 >= v_task_def.max_attempts) THEN
        UPDATE workflow.workflow_job SET state = 'DEAD', attempt_count = attempt_count + 1 WHERE job_id = p_job_id;
        UPDATE workflow.step_instance SET state = 'FAILED', completed_at = now()
            WHERE step_instance_id = v_step.step_instance_id;
        UPDATE workflow.process_instance SET state = 'FAILED', updated_at = now()
            WHERE process_id = v_job.process_id;
        INSERT INTO workflow.workflow_event (process_id, step_instance_id, event_type)
            VALUES (v_job.process_id, v_step.step_instance_id, 'TaskFailed');

        RETURN jsonb_build_object('status', 'ok', 'jobState', 'DEAD', 'errorCode', p_error_code);
    END IF;

    -- "После retryable failure N используется delays_ms[N - 1]" — N это
    -- порядковый номер только что случившегося отказа (1-based), т.е.
    -- N = attempt_count + 1. delays_ms[N-1] в 1-based нотации задания —
    -- это ровно v_task_def.delays_ms ->> attempt_count в 0-based индексации
    -- jsonb-массива Postgres. attempt_count здесь гарантированно в
    -- пределах [0, max_attempts-2] — проверено веткой выше.
    v_delay_ms := (v_task_def.delays_ms ->> v_job.attempt_count)::bigint;

    UPDATE workflow.workflow_job
    SET state = 'RETRY_WAIT',
        attempt_count = attempt_count + 1,
        next_attempt_at = now() + (v_delay_ms || ' milliseconds')::interval
    WHERE job_id = p_job_id;

    RETURN jsonb_build_object('status', 'ok', 'jobState', 'RETRY_WAIT', 'nextAttemptDelayMs', v_delay_ms);
END;
$$;

-- ============================================================
-- 5. workflow.get_process — target-функция под будущий action
--    "workflow.get" (регистрация в course.action_catalog делается
--    отдельной миграцией, здесь только сама функция).
-- ============================================================
CREATE OR REPLACE FUNCTION workflow.get_process(
    p_context JSONB,
    p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = workflow, course, public, pg_catalog
AS $$
DECLARE
    v_process_id UUID;
    v_process JSONB;
    v_steps JSONB;
    v_jobs JSONB;
    v_attempts JSONB;
BEGIN
    BEGIN
        v_process_id := (p_payload->>'processId')::UUID;
    EXCEPTION WHEN OTHERS THEN
        v_process_id := NULL;
    END;

    IF v_process_id IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error', 'code', 'payload.invalid',
            'message', 'processId is required and must be a UUID', 'retryable', false
        );
    END IF;

    -- ВАЖНО: собираем объект вручную, а не через to_jsonb(pi.*) —
    -- колонки таблицы snake_case (process_id, business_key, ...), а
    -- контракт action'а (как и flow get у CLI) отдаёт camelCase.
    -- to_jsonb(pi.*) тут раньше молча ломал processId в ответе.
    SELECT jsonb_build_object(
        'processId', pi.process_id,
        'businessKey', pi.business_key,
        'flowName', pi.flow_name,
        'flowVersion', pi.flow_version,
        'state', pi.state,
        'currentStepKey', pi.current_step_key,
        'processData', pi.process_data,
        'createdAt', pi.created_at,
        'updatedAt', pi.updated_at
    ) INTO v_process
    FROM workflow.process_instance pi
    WHERE pi.process_id = v_process_id;

    IF v_process IS NULL THEN
        RETURN jsonb_build_object('status', 'ok', 'outcome', 'NOT_FOUND', 'result', '{}'::jsonb);
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(si.*) ORDER BY si.entered_at), '[]'::jsonb) INTO v_steps
    FROM workflow.step_instance si WHERE si.process_id = v_process_id;

    SELECT COALESCE(jsonb_agg(to_jsonb(j.*) ORDER BY j.created_at), '[]'::jsonb) INTO v_jobs
    FROM workflow.workflow_job j WHERE j.process_id = v_process_id;

    SELECT COALESCE(jsonb_agg(to_jsonb(ta.*) ORDER BY ta.started_at), '[]'::jsonb) INTO v_attempts
    FROM workflow.task_attempt ta
    JOIN workflow.workflow_job j ON j.job_id = ta.job_id
    WHERE j.process_id = v_process_id;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', 'FOUND',
        'result', jsonb_build_object('process', v_process, 'steps', v_steps, 'jobs', v_jobs, 'attempts', v_attempts)
    );
END;
$$;

-- ============================================================
-- Владение и права
-- ============================================================
ALTER FUNCTION workflow.enter_step(UUID, TEXT) OWNER TO course_owner;
ALTER FUNCTION workflow.claim_jobs(TEXT, INTEGER, INTEGER) OWNER TO course_owner;
ALTER FUNCTION workflow.finish_job(UUID, TEXT, BIGINT, TEXT, JSONB) OWNER TO course_owner;
ALTER FUNCTION workflow.fail_job(UUID, TEXT, BIGINT, TEXT, BOOLEAN) OWNER TO course_owner;
ALTER FUNCTION workflow.get_process(JSONB, JSONB) OWNER TO course_owner;

-- Defense-in-depth по образцу 004_revoke_execute_public.sql: по
-- умолчанию PostgreSQL выдаёт EXECUTE роли PUBLIC при CREATE FUNCTION.
-- Отзываем сразу здесь же, не откладывая до отдельной миграции —
-- иначе между применением 007 и гипотетической будущей "миграцией
-- с правами" любая роль с доступом к БД могла бы дёргать эти функции
-- напрямую.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA workflow FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA workflow REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- workflow_worker получает EXECUTE ровно на четыре функции, как
-- прямо требует 04_assignment.md, и ни на что больше — ни на
-- enter_step/get_process, ни тем более прямой DML на таблицы.
-- USAGE ON SCHEMA обязателен отдельно от EXECUTE на саму функцию —
-- без него роль не видит объекты схемы вообще, даже с выданным EXECUTE.
GRANT USAGE ON SCHEMA workflow TO workflow_worker;
GRANT USAGE ON SCHEMA api TO workflow_worker;
GRANT EXECUTE ON FUNCTION workflow.claim_jobs(TEXT, INTEGER, INTEGER) TO workflow_worker;
GRANT EXECUTE ON FUNCTION workflow.finish_job(UUID, TEXT, BIGINT, TEXT, JSONB) TO workflow_worker;
GRANT EXECUTE ON FUNCTION workflow.fail_job(UUID, TEXT, BIGINT, TEXT, BOOLEAN) TO workflow_worker;
GRANT EXECUTE ON FUNCTION api.invoke(TEXT, TEXT, INTEGER, JSONB, JSONB) TO workflow_worker;

COMMENT ON FUNCTION workflow.enter_step(UUID, TEXT) IS
    'Внутренний helper: создаёт step_instance для шага, переводит process в соответствующее состояние, при AUTOMATIC создаёт job, при WAIT_SIGNAL применяет уже накопленный ACCEPTED-сигнал';
COMMENT ON FUNCTION workflow.claim_jobs(TEXT, INTEGER, INTEGER) IS
    'Захват до p_limit готовых job короткой транзакцией (FOR UPDATE SKIP LOCKED), возвращает всё нужное shared ActionExecutor одним вызовом';
COMMENT ON FUNCTION workflow.finish_job(UUID, TEXT, BIGINT, TEXT, JSONB) IS
    'Фиксация успешного исхода job: принимается только при точном совпадении job_id/owner/lease_version/state';
COMMENT ON FUNCTION workflow.fail_job(UUID, TEXT, BIGINT, TEXT, BOOLEAN) IS
    'Фиксация неуспешного исхода job: DEAD при исчерпании попыток или non-retryable ошибке, иначе RETRY_WAIT по delays_ms';
COMMENT ON FUNCTION workflow.get_process(JSONB, JSONB) IS
    'Target-функция для action workflow.get: снимок process + steps + jobs + attempts по processId';