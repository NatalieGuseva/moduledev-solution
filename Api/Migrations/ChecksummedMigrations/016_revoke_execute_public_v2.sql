-- ============================================================
-- Миграция 016: Defense-in-depth — EXECUTE PUBLIC revoke, часть 2
-- ============================================================
--
-- 004_revoke_execute_public.sql закрыл api/course/opencheck на момент
-- недели 1. Схемы workflow (005-008), delivery (010-011), training
-- (010_insert_training_canary_action) и функции pgcrypto в public
-- (extension pgcrypto) появились позже и под тот revoke не попали —
-- CREATE FUNCTION по умолчанию снова даёт EXECUTE роли PUBLIC на
-- каждую новую функцию. python-fixed-function-privileges чекера явно
-- проверяет, что EXECUTE есть РОВНО у 4 связок роль/функция — эта
-- миграция закрывает остальное.

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA course FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA delivery FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA workflow FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA training FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA course REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA delivery REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA workflow REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA training REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- course_owner исполняет SECURITY DEFINER функции course.*/workflow.*/
-- delivery.*, а внутри них вызывает pgcrypto DIGEST(...) (payment_submit,
-- receive_signal и т.д.) — это НЕ его собственные функции, владение
-- своими объектами тут не помогает, нужен явный grant. То же на всякий
-- случай — course_migrator/course_publisher, которые тоже исполняют
-- SQL внутри своих транзакций миграций/публикации.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO course_owner, course_migrator, course_publisher;

-- Единственные прямые вызовы, разрешённые Python-периметру — их
-- собственные 4 транспортные функции (см. python-fixed-sql-boundaries).
GRANT EXECUTE ON FUNCTION delivery.claim_outbox(TEXT, INTEGER) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.succeed_outbox(UUID, TEXT, BIGINT, TEXT) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.fail_outbox(UUID, TEXT, BIGINT, TEXT) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.reconcile_inbox(INTEGER) TO inbox_reconciler;