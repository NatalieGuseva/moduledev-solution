-- ============================================================
-- Миграция 020: Полная пересборка autocheck.outbox с lease-колонками
-- ============================================================
--
-- 017 создала autocheck.outbox с 9 колонками (без lease_owner/
-- lease_version/lease_until). Checker (week4-stable-view-columns)
-- требует все 12 из 07-autocheck-outline.md:
--   "С недели 4 autocheck.outbox дополнительно содержит
--    lease_owner text, lease_version bigint, lease_until timestamptz,
--    dead_at timestamptz."
--
-- CREATE OR REPLACE VIEW не может вставить колонки в середину
-- (PostgreSQL 42P16: "cannot change name of view column ... to ..."),
-- поэтому делаем DROP + CREATE.
--
-- DROP безопасен: view не имеет зависимостей (её читает только
-- checker через autocheck_reader), гранты на неё перевыдаются ниже.

DROP VIEW IF EXISTS autocheck.outbox;

CREATE VIEW autocheck.outbox AS
SELECT
    outbox_id,
    external_request_id,
    state,
    attempt_count,
    lease_owner,
    lease_version,
    lease_until,
    next_attempt_at,
    last_error_code,
    created_at,
    delivered_at,
    dead_at
FROM delivery.outbox;

ALTER VIEW autocheck.outbox OWNER TO course_owner;

-- autocheck_reader уже имеет USAGE на схему autocheck (миграция 019).
-- GRANT SELECT на новую view нужен заново, потому что DROP его снял.
GRANT SELECT ON autocheck.outbox TO autocheck_reader;

-- course_runtime — на случай, если метрики в C# API читают этот view
-- через роль course_runtime (как остальные autocheck.* views).
GRANT SELECT ON autocheck.outbox TO course_runtime;