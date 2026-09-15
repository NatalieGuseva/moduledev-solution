-- ============================================================
-- Миграция 005: Владение функциями + изолированная publication-identity
-- ============================================================
--
-- Начиная с этой миграции "cli migration apply" подключается не под
-- POSTGRES_USER (суперпользователь), а под course_migrator (см.
-- postgres-init/00-bootstrap-roles.sh и docker-compose.yml). Функции из
-- 002_functions.sql были созданы тем подключением, которым применялись
-- миграции — то есть теперь они принадлежат course_migrator, а не
-- общему NOLOGIN-владельцу схемы course_owner (в отличие от таблиц/схем,
-- которые 001_initial.sql уже явно переносит на course_owner в конце).
-- Переносим владение и функциями, чтобы вся схема принадлежала одной
-- NOLOGIN-роли независимо от того, какой LOGIN-идентификатор что создавал.
ALTER FUNCTION api.invoke(TEXT, TEXT, INTEGER, JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.check_policy(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.log_dispatch(UUID, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT) OWNER TO course_owner;
ALTER FUNCTION course.payment_request(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.operation_get(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.publish_action(TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, JSONB, JSONB, JSONB, JSONB, TEXT, TEXT, INTEGER) OWNER TO course_owner;
ALTER FUNCTION opencheck.probe_v1(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION opencheck.probe_v2(JSONB, JSONB) OWNER TO course_owner;

-- Дальше нужны GRANT на объекты, которыми теперь владеет course_owner, а
-- не подключение (course_migrator). GRANT/REVOKE на чужой объект требуют
-- либо прав самого владельца, либо WITH GRANT OPTION — просто membership
-- в course_owner (без SET ROLE) на это не полагаемся, переключаемся явно.
SET ROLE course_owner;

-- Изолированная publication-identity: раньше "cli action publish/
-- activate/disable/list" ходил той же суперпользовательской строкой
-- подключения, что и рантайм API, и мог теоретически делать что угодно
-- в БД. Теперь у публикации отдельная NOLOGIN-роль (course_publication),
-- которая видит ТОЛЬКО action_catalog и function publish_action — не
-- operations, не operation_events, не idempotency_records, и не может
-- создавать объекты схемы.
GRANT USAGE ON SCHEMA course TO course_publication;
GRANT SELECT, INSERT, UPDATE ON course.action_catalog TO course_publication;
GRANT EXECUTE ON FUNCTION course.publish_action(
    TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, JSONB, JSONB, JSONB, JSONB, TEXT, TEXT, INTEGER
) TO course_publication;

RESET ROLE;
