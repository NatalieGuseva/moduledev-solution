-- ============================================================
-- Миграция 006: DB-инварианты и append-only история
-- ============================================================
--
-- До этой миграции operation_kind/currency/amount проверялись только
-- внутри PL/pgSQL-функций (002_functions.sql, course.payment_request).
-- Это защищает путь через api.invoke, но ничего не мешает произвольному
-- INSERT/UPDATE напрямую в course.operations (например, будущей миграцией
-- с опечаткой, или ручным psql-подключением course_owner) записать
-- некорректные данные. CHECK-constraints переносят инвариант на уровень
-- самой таблицы — независимо от того, кто и как в неё пишет.
--
-- course.operations принадлежит course_owner (см. 001_initial.sql), а
-- подключены мы как course_migrator — переключаемся на владельца явно.
SET ROLE course_owner;

ALTER TABLE course.operations
    ADD CONSTRAINT ck_operations_operation_kind
        CHECK (operation_kind IN ('PAYMENT_EXECUTION', 'PAYMENT_APPROVAL')),
    ADD CONSTRAINT ck_operations_currency
        CHECK (currency = 'RUB'),
    ADD CONSTRAINT ck_operations_amount_positive
        CHECK (amount > 0);

-- Append-only история: operation_events и action_dispatches — журналы, из
-- которых читают autocheck-проекции (autocheck.operation_events,
-- autocheck.action_dispatches). UPDATE/DELETE по ним не должны быть
-- возможны вообще — в том числе для course_owner. Обычный REVOKE тут не
-- поможет: владелец объекта всегда неявно обладает всеми правами на него
-- независимо от выданных/отозванных грантов. Единственное, что реально
-- блокирует и владельца — BEFORE-триггер, который выполняется до самой
-- операции и просто запрещает её.
CREATE OR REPLACE FUNCTION course.reject_mutation()
RETURNS TRIGGER AS $do$
BEGIN
    RAISE EXCEPTION '% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$do$ LANGUAGE plpgsql;

-- Функция создана под SET ROLE course_owner, поэтому уже принадлежит
-- course_owner; на всякий случай явно закрываем EXECUTE для PUBLIC — она
-- не предназначена для прямого вызова, только для триггерного механизма.
REVOKE EXECUTE ON FUNCTION course.reject_mutation() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_operation_events_append_only ON course.operation_events;
CREATE TRIGGER trg_operation_events_append_only
    BEFORE UPDATE OR DELETE ON course.operation_events
    FOR EACH ROW
    EXECUTE FUNCTION course.reject_mutation();

DROP TRIGGER IF EXISTS trg_action_dispatches_append_only ON course.action_dispatches;
CREATE TRIGGER trg_action_dispatches_append_only
    BEFORE UPDATE OR DELETE ON course.action_dispatches
    FOR EACH ROW
    EXECUTE FUNCTION course.reject_mutation();

RESET ROLE;
