-- ============================================================
-- Миграция 006: Views для autocheck — workflow-часть
-- ============================================================
--
-- Схема autocheck уже создана в 001_initial.sql, здесь только
-- добавляем новые views поверх таблиц из 005_workflow_schema.sql.
-- Имена и обязательные колонки — часть проверочного контракта
-- (см. 04_assignment.md, раздел "Диагностика и evidence"), лишние
-- диагностические колонки допустимы, но эти убирать нельзя.

-- 1. flow_versions
CREATE OR REPLACE VIEW autocheck.flow_versions AS
SELECT
    flow_name,
    flow_version,
    status,
    is_active,
    published_at
FROM workflow.flow_version;

-- 2. processes
CREATE OR REPLACE VIEW autocheck.processes AS
SELECT
    process_id,
    business_key,
    flow_name,
    flow_version,
    state,
    current_step_key,
    created_at,
    updated_at
FROM workflow.process_instance;

-- 3. steps
CREATE OR REPLACE VIEW autocheck.steps AS
SELECT
    step_instance_id,
    process_id,
    step_key,
    step_type,
    state,
    outcome,
    entered_at,
    completed_at
FROM workflow.step_instance;

-- 4. jobs
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
    next_attempt_at
FROM workflow.workflow_job;

-- 5. attempts
CREATE OR REPLACE VIEW autocheck.attempts AS
SELECT
    attempt_id,
    job_id,
    execution_id,
    lease_version,
    attempt_number,
    status,
    outcome,
    error_code,
    started_at,
    finished_at
FROM workflow.task_attempt;

-- 6. signals
-- Намеренно без колонки body — только хеш. Само тело сигнала может
-- содержать предметные данные, которым не место в диагностическом view.
CREATE OR REPLACE VIEW autocheck.signals AS
SELECT
    message_id,
    process_id,
    signal_type,
    body_hash,
    status,
    received_at
FROM workflow.workflow_signal;

-- 7. workflow_events
CREATE OR REPLACE VIEW autocheck.workflow_events AS
SELECT
    event_id,
    process_id,
    step_instance_id,
    event_type,
    occurred_at
FROM workflow.workflow_event;

-- ============================================================
-- Права доступа для проверяющего контура
-- ============================================================

-- Даем доступ к схеме autocheck для PUBLIC (проверяющий контур)
GRANT USAGE ON SCHEMA autocheck TO PUBLIC;

-- Даем SELECT на все view в схеме autocheck для PUBLIC
GRANT SELECT ON
    autocheck.flow_versions,
    autocheck.processes,
    autocheck.steps,
    autocheck.jobs,
    autocheck.attempts,
    autocheck.signals,
    autocheck.workflow_events
TO PUBLIC;

-- Даем SELECT для course_runtime
GRANT SELECT ON
    autocheck.flow_versions,
    autocheck.processes,
    autocheck.steps,
    autocheck.jobs,
    autocheck.attempts,
    autocheck.signals,
    autocheck.workflow_events
TO course_runtime;

-- Назначаем владельца (course_owner должен существовать из 001_initial.sql)
ALTER VIEW autocheck.flow_versions OWNER TO course_owner;
ALTER VIEW autocheck.processes OWNER TO course_owner;
ALTER VIEW autocheck.steps OWNER TO course_owner;
ALTER VIEW autocheck.jobs OWNER TO course_owner;
ALTER VIEW autocheck.attempts OWNER TO course_owner;
ALTER VIEW autocheck.signals OWNER TO course_owner;
ALTER VIEW autocheck.workflow_events OWNER TO course_owner;

-- Комментарии для документации
COMMENT ON VIEW autocheck.flow_versions IS 'Опубликованные версии карт для autocheck';
COMMENT ON VIEW autocheck.processes IS 'Экземпляры процессов для autocheck';
COMMENT ON VIEW autocheck.steps IS 'Состояния шагов процессов для autocheck';
COMMENT ON VIEW autocheck.jobs IS 'Задания worker''ов для autocheck';
COMMENT ON VIEW autocheck.attempts IS 'Попытки выполнения заданий для autocheck';
COMMENT ON VIEW autocheck.signals IS 'Принятые сигналы (без тела) для autocheck';
COMMENT ON VIEW autocheck.workflow_events IS 'Append-only история переходов для autocheck';