-- ============================================================
-- Миграция 015: недостающие autocheck views — receipts, decisions
-- ============================================================
--
-- delivery.inbox (010, + колонки message_version/signature_valid из
-- 012) и payment.decision (тоже 012) уже содержат всё нужное для
-- autocheck.receipts и autocheck.decisions — сами VIEW создать забыли.
-- week3-stable-views/week3-stable-view-columns требуют ровно эти два
-- имени в схеме autocheck с колонками, зафиксированными в
-- REQUIRED_VIEW_COLUMNS чекера — здесь просто прямой SELECT без
-- преобразований, поэтому типы колонок наследуются от исходных таблиц
-- и совпадают с ожиданиями чекера автоматически.

CREATE OR REPLACE VIEW autocheck.receipts AS
SELECT
    message_id,
    external_request_id,
    message_version,
    outcome,
    signature_valid,
    body_hash,
    received_at,
    applied_at
FROM delivery.inbox;

CREATE OR REPLACE VIEW autocheck.decisions AS
SELECT
    decision_id,
    process_id,
    step_instance_id,
    source,
    principal,
    reason_hash,
    outcome,
    rule_version,
    created_at
FROM payment.decision;

ALTER VIEW autocheck.receipts OWNER TO course_owner;
ALTER VIEW autocheck.decisions OWNER TO course_owner;

COMMENT ON VIEW autocheck.receipts IS 'Принятые receipt (delivery.inbox) для autocheck — обзорная проекция, не транспортная таблица';
COMMENT ON VIEW autocheck.decisions IS 'Аудит авто/ручных решений payment-review (payment.decision) для autocheck';

-- Тот же паттерн доступа, что уже выдан для autocheck.outbox/inbox/
-- external_requests в 011_delivery_functions.sql.

GRANT SELECT ON autocheck.receipts, autocheck.decisions TO course_runtime;