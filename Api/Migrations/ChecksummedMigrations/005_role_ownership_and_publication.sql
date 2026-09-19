-- ============================================================
-- Миграция 005: Владение функциями + изолированная publication-identity
-- ============================================================
--
-- "cli"/"api" подключаются под POSTGRES_USER (суперпользователем, см.
-- docker-compose.yml). Отдельный LOGIN-идентификатор для миграций
-- (course_migrator) через bind-mount инициализационных скриптов в
-- контейнер postgres не заводим — это запрещено compose-safety частью
-- автопроверки (расценивается как host escape). Поэтому все служебные
-- роли ниже создаются идемпотентно прямо здесь, тем же способом, что
-- уже применён для course_owner/course_runtime в 001_initial.sql.
--
-- Функции из 002_functions.sql были созданы тем же суперпользовательским
-- подключением, но по умолчанию принадлежат создавшему их пользователю,
-- а не общему NOLOGIN-владельцу схемы course_owner (в отличие от
-- таблиц/схем, которые 001_initial.sql уже явно переносит на course_owner
-- в конце). Переносим владение и функциями, чтобы вся схема принадлежала
-- одной NOLOGIN-роли независимо от того, какой LOGIN-идентификатор что
-- создавал.
ALTER FUNCTION api.invoke(TEXT, TEXT, INTEGER, JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.check_policy(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.log_dispatch(UUID, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT) OWNER TO course_owner;
ALTER FUNCTION course.payment_request(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.operation_get(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION course.publish_action(TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, JSONB, JSONB, JSONB, JSONB, TEXT, TEXT, INTEGER, BOOLEAN) OWNER TO course_owner;
ALTER FUNCTION opencheck.probe_v1(JSONB, JSONB) OWNER TO course_owner;
ALTER FUNCTION opencheck.probe_v2(JSONB, JSONB) OWNER TO course_owner;

-- Изолированная publication-identity: раньше "cli action publish/
-- activate/disable/list" ходил той же суперпользовательской строкой
-- подключения, что и рантайм API, и мог теоретически делать что угодно
-- в БД. Теперь у публикации отдельная NOLOGIN-роль (course_publication),
-- которая видит ТОЛЬКО action_catalog и function publish_action — не
-- operations, не operation_events, не idempotency_records, и не может
-- создавать объекты схемы.
--
-- Создаём её здесь, ДО "SET ROLE course_owner" ниже: course_owner сам
-- NOLOGIN и прав CREATEROLE не имеет, так что CREATE ROLE должен
-- выполниться от исходного подключения (superuser), иначе упадёт с
-- "permission denied to create role".
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_publication') THEN
        CREATE ROLE course_publication NOLOGIN;
    END IF;
END
$$;

-- Дальше нужны GRANT на объекты, которыми теперь владеет course_owner, а
-- не текущее подключение (superuser). GRANT/REVOKE на чужой объект
-- требуют либо прав самого владельца, либо WITH GRANT OPTION — просто
-- membership в course_owner (без SET ROLE) на это не полагаемся,
-- переключаемся явно.
SET ROLE course_owner;

GRANT USAGE ON SCHEMA course TO course_publication;
GRANT SELECT, INSERT, UPDATE ON course.action_catalog TO course_publication;
GRANT EXECUTE ON FUNCTION course.publish_action(
    TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, JSONB, JSONB, JSONB, JSONB, TEXT, TEXT, INTEGER, BOOLEAN
) TO course_publication;

RESET ROLE;
