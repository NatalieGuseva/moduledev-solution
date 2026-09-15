-- ============================================================
-- Миграция 008: Донастройка прав после первого прогона под
-- course_runtime/course_migrator (по week-1-public-report.json)
-- ============================================================
--
-- Пока "api"/"cli" подключались POSTGRES_USER-суперпользователем, оба
-- пробела ниже ничем не проявлялись — суперпользователь игнорирует любые
-- GRANT/REVOKE. После перехода на реальные ограниченные роли (см.
-- 005_role_ownership_and_publication.sql) публичный прогон показал два
-- конкретных отказа.

-- 1) CompleteIdempotencyAsync (Api/Controllers/ActionsController.cs) делает
--    обычный (не через SECURITY DEFINER) UPDATE course.idempotency_records
--    от лица course_runtime ПОСЛЕ успешного выполнения action. В
--    001_initial.sql этой роли был выдан только "GRANT SELECT, INSERT" —
--    без UPDATE. Любой успешно выполненный запрос с Idempotency-Key падал
--    на этом шаге с 503 dependency.unavailable ("PostgreSQL database error
--    during execution"), включая payment.request — из-за чего дальше
--    operation.get получал operationId = null и падал уже на схеме.
--
-- course.idempotency_records принадлежит course_owner (см. 001_initial.sql),
-- подключены мы как course_migrator — переключаемся на владельца явно,
-- как и в предыдущих миграциях.
SET ROLE course_owner;
GRANT UPDATE ON course.idempotency_records TO course_runtime;
RESET ROLE;

-- 2) opencheck.probe_v1/v2 (SECURITY DEFINER, после 005 принадлежат
--    course_owner) пишут в opencheck.canary — таблицу, которую заводит НЕ
--    отслеживаемая в этом репозитории миграция автопроверки
--    (autocheck/fixtures/migrations/900_opencheck_probe.sql), применяемая
--    тем же "cli migration apply", только уже под course_migrator, и уже
--    ПОСЛЕ того, как отработали миграции 001–008. "GRANT ALL PRIVILEGES ON
--    ALL TABLES IN SCHEMA opencheck TO course_owner" в 001_initial.sql —
--    это снимок на момент выполнения той строки, а не отслеживаемое
--    правило: canary тогда ещё не существовала, поэтому реально ничего не
--    получила. course_owner оказывался без единого права на неё → INSERT
--    падал с ошибкой доступа → api.invoke ловил её в "EXCEPTION WHEN
--    OTHERS" и возвращал 500 "Target function execution failed" ещё до
--    того, как запрос вообще доходил до идемпотентности.
--
--    ALTER DEFAULT PRIVILEGES — правило "на будущее", а не снимок: для
--    любой таблицы/последовательности, которую course_migrator создаст в
--    этих схемах ПОСЛЕ этой миграции (в том числе внедряемые
--    автопроверкой фикстуры вроде opencheck.canary), права на неё
--    автоматически достаются course_owner в момент создания — без
--    ручного ALTER TABLE OWNER TO/GRANT под каждую новую такую таблицу.
--    Выполняется от лица самого course_migrator: "FOR ROLE course_migrator"
--    настраивает дефолты именно той роли, которая и создаёт объекты
--    (в том числе через будущие "cli migration apply" на фикстурах
--    автопроверки), поэтому SET ROLE здесь не нужен и не должен
--    использоваться — иначе правило привяжется не к той роли.
ALTER DEFAULT PRIVILEGES FOR ROLE course_migrator IN SCHEMA course, opencheck, payment
    GRANT ALL PRIVILEGES ON TABLES TO course_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE course_migrator IN SCHEMA course, opencheck, payment
    GRANT ALL PRIVILEGES ON SEQUENCES TO course_owner;

-- 3) ALTER DEFAULT PRIVILEGES из пункта (2) действует только на объекты,
--    которые course_migrator создаст ПОСЛЕ этой миграции — а opencheck.canary
--    к моменту применения 008 уже могла быть создана более ранним прогоном
--    "cli migration apply /autocheck/input/migrations" в ЭТОМ ЖЕ volume
--    (миграции 001–007 уже применены, и autocheck успел вставить canary
--    ДО того, как появился этот файл). Донастраиваем её задним числом:
--    переносим владение на course_owner напрямую — раз canary создавал
--    course_migrator (который её и вставлял), он остаётся её текущим
--    владельцем и одновременно состоит в course_owner, поэтому ALTER
--    ... OWNER TO выполняется им самим, без SET ROLE. Обёрнуто в DO-блок
--    с проверкой существования — на случай, если repo-миграции применяют
--    без фикстур автопроверки вообще (тогда canary ещё не существует, и
--    блок безопасно ничего не делает: ALTER DEFAULT PRIVILEGES из пункта
--    (2) всё равно сработает, когда она появится позже).
DO $do$
BEGIN
    IF EXISTS (SELECT FROM pg_catalog.pg_tables WHERE schemaname = 'opencheck' AND tablename = 'canary') THEN
        EXECUTE 'ALTER TABLE opencheck.canary OWNER TO course_owner';
    END IF;
END
$do$;

-- На случай, если у canary есть свой SERIAL/IDENTITY-столбец —
-- переносим владение и его последовательностью(-ями) тоже, той же логикой.
DO $do$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT sequencename FROM pg_catalog.pg_sequences WHERE schemaname = 'opencheck'
    LOOP
        EXECUTE format('ALTER SEQUENCE opencheck.%I OWNER TO course_owner', r.sequencename);
    END LOOP;
END
$do$;
