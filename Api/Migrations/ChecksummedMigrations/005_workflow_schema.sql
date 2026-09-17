-- ============================================================
-- Миграция 005: Схема workflow — таблицы определения карты,
-- рантайм-состояние процесса и роль workflow_worker
-- ============================================================
--
-- Порядок таблиц идёт строго по зависимостям FOREIGN KEY: сначала
-- то, на что ссылаются, потом то, что ссылается. Ничего не создаём
-- через forward reference — PostgreSQL применяет CREATE TABLE
-- последовательно, а не как единый DDL-граф.

-- 1. Схема
CREATE SCHEMA IF NOT EXISTS workflow;

-- 2. Роль workflow_worker (идемпотентно — тот же паттерн, что для
--    course_runtime/course_owner в 001_initial.sql). Никаких GRANT
--    ей здесь не выдаём: по заданию workflow_worker не имеет
--    прямого DML ни на одну таблицу, включая эту схему — только
--    EXECUTE на workflow.claim_jobs / finish_job / fail_job /
--    api.invoke, и эти GRANT появятся в отдельной миграции после
--    того, как сами функции будут созданы (007/008).
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'workflow_worker') THEN
        CREATE ROLE workflow_worker NOLOGIN;
    END IF;
END
$$;

-- ============================================================
-- Definition: неизменяемые после публикации сущности карты
-- ============================================================

-- 3. flow_definition — стабильное имя процесса
CREATE TABLE workflow.flow_definition (
    flow_name TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4. flow_version — неизменяемая опубликованная версия карты.
--    Уникальность "ровно одна активная версия на flow_name" не
--    выразить как обычный UNIQUE/CHECK (он не видит другие строки),
--    поэтому это частичный уникальный индекс ниже, а не inline-
--    ограничение таблицы.
CREATE TABLE workflow.flow_version (
    flow_name TEXT NOT NULL REFERENCES workflow.flow_definition(flow_name),
    flow_version INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('PUBLISHED')),
    is_active BOOLEAN NOT NULL DEFAULT FALSE,
    map_definition JSONB NOT NULL,
    published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (flow_name, flow_version)
);

CREATE UNIQUE INDEX idx_flow_version_one_active
    ON workflow.flow_version (flow_name)
    WHERE is_active = TRUE;

-- 5. task_definition — закреплённый action contract и execution
--    policy автоматического шага. Создаётся до step_definition,
--    потому что step_definition на неё ссылается.
CREATE TABLE workflow.task_definition (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flow_name TEXT NOT NULL,
    flow_version INTEGER NOT NULL,
    action_module TEXT NOT NULL,
    action_name TEXT NOT NULL,
    action_version INTEGER NOT NULL,
    input_mapping JSONB NOT NULL DEFAULT '{}',
    input_constants JSONB NOT NULL DEFAULT '{}',
    max_attempts INTEGER NOT NULL CHECK (max_attempts BETWEEN 1 AND 10),
    delays_ms JSONB NOT NULL DEFAULT '[]',
    FOREIGN KEY (flow_name, flow_version) REFERENCES workflow.flow_version(flow_name, flow_version)
);

-- 6. step_definition — тип шага и параметры конкретной версии карты
CREATE TABLE workflow.step_definition (
    flow_name TEXT NOT NULL,
    flow_version INTEGER NOT NULL,
    step_key TEXT NOT NULL,
    step_type TEXT NOT NULL CHECK (step_type IN ('AUTOMATIC', 'WAIT_SIGNAL', 'MANUAL', 'END')),
    is_start BOOLEAN NOT NULL DEFAULT FALSE,
    task_definition_id UUID REFERENCES workflow.task_definition(id),
    wait_signal_type TEXT,
    PRIMARY KEY (flow_name, flow_version, step_key),
    FOREIGN KEY (flow_name, flow_version) REFERENCES workflow.flow_version(flow_name, flow_version)
);

-- Ровно один start_step на версию карты — сама достижимость и
-- прочая семантика проверяется валидатором на уровне CLI, но эту
-- конкретную инвариантность может держать и БД.
CREATE UNIQUE INDEX idx_step_definition_one_start
    ON workflow.step_definition (flow_name, flow_version)
    WHERE is_start = TRUE;

-- 7. transition_definition — переход для конкретного outcome
CREATE TABLE workflow.transition_definition (
    flow_name TEXT NOT NULL,
    flow_version INTEGER NOT NULL,
    step_key TEXT NOT NULL,
    outcome TEXT NOT NULL,
    next_step_key TEXT NOT NULL,
    PRIMARY KEY (flow_name, flow_version, step_key, outcome),
    FOREIGN KEY (flow_name, flow_version, step_key)
        REFERENCES workflow.step_definition(flow_name, flow_version, step_key)
);

-- ============================================================
-- Runtime state: конкретные запуски процессов
-- ============================================================

-- 8. process_instance — экземпляр конкретной версии карты.
--    process_data — источник для input_mapping (target payload
--    pointer -> source process data pointer из задания); без неё
--    mapping в принципе неоткуда читать.
--    UNIQUE (flow_name, business_key) — это и есть идемпотентность
--    flow start: один business key не создаёт второй процесс.
CREATE TABLE workflow.process_instance (
    process_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_key TEXT NOT NULL,
    flow_name TEXT NOT NULL,
    flow_version INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN (
        'CREATED', 'RUNNING', 'WAITING_SIGNAL', 'WAITING_MANUAL', 'COMPLETED', 'FAILED'
    )),
    current_step_key TEXT,
    process_data JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (flow_name, flow_version) REFERENCES workflow.flow_version(flow_name, flow_version),
    FOREIGN KEY (flow_name, flow_version, current_step_key)
        REFERENCES workflow.step_definition(flow_name, flow_version, step_key),
    UNIQUE (flow_name, business_key)
);

-- 9. step_instance — фактическое состояние шага конкретного процесса
CREATE TABLE workflow.step_instance (
    step_instance_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id UUID NOT NULL REFERENCES workflow.process_instance(process_id),
    step_key TEXT NOT NULL,
    step_type TEXT NOT NULL CHECK (step_type IN ('AUTOMATIC', 'WAIT_SIGNAL', 'MANUAL', 'END')),
    state TEXT NOT NULL CHECK (state IN (
        'PENDING', 'READY', 'RUNNING', 'WAITING', 'COMPLETED', 'FAILED'
    )),
    outcome TEXT,
    entered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);

-- 10. workflow_job — готовое, арендованное или отложенное задание.
--     execution_id — стабильный idempotency key предметного эффекта
--     ВСЕХ попыток этого job (не меняется при reclaim).
--     lease_version — возрастающая версия права на завершение;
--     finish_job/fail_job принимают запрос только при совпадении
--     job_id + lease_owner + lease_version + ожидаемого state.
CREATE TABLE workflow.workflow_job (
    job_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id UUID NOT NULL REFERENCES workflow.process_instance(process_id),
    step_instance_id UUID NOT NULL REFERENCES workflow.step_instance(step_instance_id),
    execution_id UUID NOT NULL DEFAULT gen_random_uuid(),
    state TEXT NOT NULL CHECK (state IN ('READY', 'LEASED', 'RETRY_WAIT', 'SUCCEEDED', 'DEAD')),
    lease_owner TEXT,
    lease_version BIGINT NOT NULL DEFAULT 0,
    lease_until TIMESTAMPTZ,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON COLUMN workflow.workflow_job.execution_id IS
    'Стабильный idempotency key предметного эффекта job. Не меняется между attempt при reclaim.';
COMMENT ON COLUMN workflow.workflow_job.lease_version IS
    'Возрастающая версия права на завершение job. Инкрементируется при каждом claim/reclaim.';

-- Индекс под claim_jobs: короткая транзакция с FOR UPDATE SKIP LOCKED
-- по готовым к обработке заданиям, отсортированным по времени.
CREATE INDEX idx_workflow_job_claimable
    ON workflow.workflow_job (next_attempt_at)
    WHERE state IN ('READY', 'RETRY_WAIT');

CREATE INDEX idx_workflow_job_state ON workflow.workflow_job (state);

-- 11. task_attempt — одна попытка выполнения job.
--     outcome — TEXT, а не JSONB: это простое имя исхода ("VALID",
--     "WITHIN_LIMIT"), контракт autocheck.attempts.outcome тоже text.
CREATE TABLE workflow.task_attempt (
    attempt_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id UUID NOT NULL REFERENCES workflow.workflow_job(job_id),
    execution_id UUID NOT NULL,
    lease_version BIGINT NOT NULL,
    attempt_number INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('RUNNING', 'SUCCEEDED', 'FAILED', 'STALE')),
    outcome TEXT,
    error_code TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ
);

-- 12. workflow_signal — идемпотентно принятый локальный сигнал.
--     message_id глобально уникален (PRIMARY KEY) — это и есть
--     дедупликация "duplicate только при полном совпадении
--     process+type+body". body хранится целиком, а не только его
--     хеш: без самого тела нечем будет применить сигнал при входе
--     в wait_signal.
CREATE TABLE workflow.workflow_signal (
    message_id TEXT PRIMARY KEY,
    process_id UUID NOT NULL REFERENCES workflow.process_instance(process_id),
    signal_type TEXT NOT NULL,
    body JSONB NOT NULL,
    body_hash TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('ACCEPTED', 'APPLIED')),
    received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 13. workflow_event — append-only история переходов.
--     Явно НЕ выдаём никому UPDATE/DELETE на эту таблицу ниже —
--     только INSERT/SELECT будут у course_owner (через SECURITY
--     DEFINER функции), append-only обеспечивается на уровне прав,
--     а не только по соглашению.
CREATE TABLE workflow.workflow_event (
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id UUID NOT NULL REFERENCES workflow.process_instance(process_id),
    step_instance_id UUID REFERENCES workflow.step_instance(step_instance_id),
    event_type TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- Владение и права
-- ============================================================
-- workflow_worker сознательно не получает здесь ничего: ни SELECT,
-- ни INSERT, ни любой другой DML на таблицы этой схемы. Это не
-- забытая часть миграции — это и есть требование задания ("не
-- имеет прямого DML"). Доступ появится только через EXECUTE на
-- workflow.claim_jobs/finish_job/fail_job (SECURITY DEFINER),
-- которые будут созданы в 007_workflow_functions.sql, а GRANT на
-- них — в 008_workflow_grants.sql.

ALTER SCHEMA workflow OWNER TO course_owner;

ALTER TABLE workflow.flow_definition OWNER TO course_owner;
ALTER TABLE workflow.flow_version OWNER TO course_owner;
ALTER TABLE workflow.task_definition OWNER TO course_owner;
ALTER TABLE workflow.step_definition OWNER TO course_owner;
ALTER TABLE workflow.transition_definition OWNER TO course_owner;
ALTER TABLE workflow.process_instance OWNER TO course_owner;
ALTER TABLE workflow.step_instance OWNER TO course_owner;
ALTER TABLE workflow.workflow_job OWNER TO course_owner;
ALTER TABLE workflow.task_attempt OWNER TO course_owner;
ALTER TABLE workflow.workflow_signal OWNER TO course_owner;
ALTER TABLE workflow.workflow_event OWNER TO course_owner;

COMMENT ON SCHEMA workflow IS 'Определения карт процессов и рантайм-состояние их исполнения (неделя 2)';
COMMENT ON TABLE workflow.flow_definition IS 'Стабильное имя процесса';
COMMENT ON TABLE workflow.flow_version IS 'Неизменяемая опубликованная версия карты; ровно одна активная на flow_name';
COMMENT ON TABLE workflow.task_definition IS 'Закреплённый action contract и execution policy автоматического шага';
COMMENT ON TABLE workflow.step_definition IS 'Тип шага и параметры конкретной версии карты';
COMMENT ON TABLE workflow.transition_definition IS 'Переход к следующему шагу для конкретного outcome';
COMMENT ON TABLE workflow.process_instance IS 'Экземпляр конкретной версии карты: текущий шаг, данные, состояние';
COMMENT ON TABLE workflow.step_instance IS 'Фактическое состояние одного шага одного экземпляра процесса';
COMMENT ON TABLE workflow.workflow_job IS 'Готовое, арендованное или отложенное задание для worker''а';
COMMENT ON TABLE workflow.task_attempt IS 'Одна попытка выполнения job';
COMMENT ON TABLE workflow.workflow_signal IS 'Идемпотентно принятый локальный сигнал (дедупликация по message_id)';
COMMENT ON TABLE workflow.workflow_event IS 'Append-only история переходов процесса';
