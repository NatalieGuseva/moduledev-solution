-- ============================================================
-- Миграция 016: Defense-in-depth — EXECUTE PUBLIC revoke, часть 2
-- ============================================================
--
-- 004_revoke_execute_public.sql закрыл api/course/opencheck на момент
-- недели 1. Схемы workflow (005-008), delivery (010-011), training
-- (010_insert_training_canary_action) появились позже и под тот
-- revoke не попали — CREATE FUNCTION по умолчанию снова даёт EXECUTE
-- роли PUBLIC на каждую новую функцию. python-fixed-function-privileges
-- чекера явно проверяет, что EXECUTE есть РОВНО у 4 связок
-- роль/функция — эта миграция закрывает остальное.
--
-- pgcrypto в схеме public закрывается в postgres-init/00-bootstrap-roles.sh:
-- public принадлежит postgres, course_migrator туда не достаёт.
--
-- REVOKE/ALTER DEFAULT PRIVILEGES работают только от имени владельца
-- схемы. cli ходит под course_migrator (не владелец схем), но
-- course_migrator — член course_owner с ADMIN OPTION (см.
-- postgres-init/00-bootstrap-roles.sh), поэтому SET ROLE course_owner
-- здесь проходит.
--
-- Отдельный случай — course.auto_enable_first_version: 001_initial.sql
-- создаёт её под course_migrator (CREATE FUNCTION выполняется от
-- подключения cli), а ALTER ... OWNER TO course_owner для неё нигде
-- не было. REVOKE EXECUTE ... FROM PUBLIC от course_owner для чужой
-- функции не срабатывает. Поэтому сначала передаём владение.

-- Передаём владение триггерной функцией course_owner — без этого
-- последующий REVOKE FROM PUBLIC не сработает (функция принадлежит
-- course_migrator, а не course_owner).
ALTER FUNCTION course.auto_enable_first_version() OWNER TO course_owner;

SET ROLE course_owner;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA course FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA delivery FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA opencheck FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA workflow FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA training FROM PUBLIC;

-- Явный REVOKE по имени — теперь работает, потому что владелец уже
-- course_owner. Покрывает случай, когда триггерная функция пересоздана
-- после ALTER DEFAULT PRIVILEGES IN SCHEMA course REVOKE EXECUTE ...
ALTER DEFAULT PRIVILEGES IN SCHEMA api REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA course REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA delivery REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA opencheck REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA workflow REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA training REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

RESET ROLE;

-- pgcrypto в public закрыт в postgres-init/00-bootstrap-roles.sh:
-- схема public принадлежит postgres, course_migrator туда не достаёт.
-- Там же явно возвращён EXECUTE для course_owner/course_migrator/
-- course_publisher — они вызывают DIGEST() из SECURITY DEFINER
-- функций. Python-ролям (outbox_dispatcher, inbox_reconciler) EXECUTE
-- на pgcrypto НЕ выдаём.

-- Единственные прямые вызовы, разрешённые Python-периметру — их
-- собственные 4 транспортные функции (см. python-fixed-sql-boundaries).
GRANT EXECUTE ON FUNCTION delivery.claim_outbox(TEXT, INTEGER) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.succeed_outbox(UUID, TEXT, BIGINT, TEXT) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.fail_outbox(UUID, TEXT, BIGINT, TEXT) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.reconcile_inbox(INTEGER) TO inbox_reconciler;