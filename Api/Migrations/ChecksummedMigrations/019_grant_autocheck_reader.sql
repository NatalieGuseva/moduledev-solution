-- ============================================================
-- Миграция 019: SELECT-права autocheck_reader на views schema autocheck
-- ============================================================
-- Роль autocheck_reader создаётся postgres-init/00-bootstrap-roles.sh
-- (LOGIN + пароль из COURSE_AUTOCHECK_PASSWORD). Bootstrap выполняется
-- ДО миграций, поэтому схема autocheck и её views на тот момент ещё
-- не существуют — GRANT USAGE/SELECT выдаётся здесь, после того как
-- все views схемы созданы (001, 006, 011, 015, 017).
--
-- Проверено checker'ом: configuration.md требует, чтобы у
-- autocheck_reader были только CONNECT, USAGE schema и SELECT views,
-- без memberships, application function/sequence privileges, доступа
-- к physical relations, CREATE или TEMP. GRANT ниже — ровно это.

SET ROLE course_owner;

GRANT USAGE ON SCHEMA autocheck TO autocheck_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA autocheck TO autocheck_reader;

RESET ROLE;