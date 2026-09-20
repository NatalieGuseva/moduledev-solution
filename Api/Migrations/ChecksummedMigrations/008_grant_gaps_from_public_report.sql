-- ============================================================
-- Миграция 008: Донастройка прав после первого прогона (по
-- week-1-public-report.json)
-- ============================================================
--
-- Пока "api"/"cli" подключаются POSTGRES_USER-суперпользователем, оба
-- пробела ниже сами по себе ничем не проявляются — суперпользователь
-- игнорирует любые GRANT/REVOKE. Но после изоляции владения объектами
-- схемы под course_owner (см. 005_role_ownership_and_publication.sql)
-- публичный прогон показал два конкретных отказа, которые всплывают,
-- как только код начинает работать через ограниченные роли
-- (course_runtime/course_owner), а не напрямую суперпользователем.

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
-- подключены мы суперпользователем — переключаемся на владельца явно,
-- как и в предыдущих миграциях.
SET ROLE course_owner;
GRANT UPDATE ON course.idempotency_records TO course_runtime;
RESET ROLE;

-- 2) opencheck.probe_v1/v2 (SECURITY DEFINER, после 005 принадлежат
--    course_owner) пишут в opencheck.canary — таблицу, которую заводит НЕ
--    отслеживаемая в этом репозитории миграция автопроверки
--    (autocheck/fixtures/migrations/900_opencheck_probe.sql), применяемая
--    тем же "cli migration apply" уже ПОСЛЕ того, как отработали миграции
--    001–008. "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA opencheck TO
--    course_owner" в 001_initial.sql — это снимок на момент выполнения той
--    строки, а не отслеживаемое правило: canary тогда ещё не существовала,
--    поэтому реально ничего не получила. course_owner оказывался без
--    единого права на неё → INSERT падал с ошибкой доступа → api.invoke
--    ловил её в "EXCEPTION WHEN OTHERS" и возвращал 500 "Target function
--    execution failed" ещё до того, как запрос вообще доходил до
--    идемпотентности.
--
--    ALTER DEFAULT PRIVILEGES — правило "на будущее", а не снимок: для
--    любой таблицы/последовательности, которую создающая роль заведёт в
--    этих схемах ПОСЛЕ этой миграции (в том числе внедряемые
--    автопроверкой фикстуры вроде opencheck.canary), права на неё
--    автоматически достаются course_owner в момент создания — без
--    ручного ALTER TABLE OWNER TO/GRANT под каждую новую такую таблицу.
--
--    "cli"/"api" в этом репозитории подключаются под POSTGRES_USER
--    (см. docker-compose.yml), а не под отдельным LOGIN-идентификатором
--    course_migrator. Роль course_migrator нужна здесь только как ЦЕЛЬ
--    для "FOR ROLE" в ALTER DEFAULT PRIVILEGES — если автопроверка сама
--    создаёт фикстуры (вроде opencheck.canary) под этим именем, они
--    сразу попадут под правило; если нет — правило просто не сработает,
--    без ошибок. Заводим её идемпотентно прямо здесь, тем же способом,
--    что и course_publication в 005: без bind-mount'а postgres-init в
--    контейнер postgres, это запрещено compose-safety частью
--    автопроверки.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_migrator') THEN
        CREATE ROLE course_migrator NOLOGIN;
    END IF;
END
$$;

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
--    переносим владение на course_owner напрямую. Обёрнуто в DO-блок с
--    проверкой существования — на случай, если repo-миграции применяют
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

-- 4) Тот же класс проблемы, что в пункте (2), только на уровень выше:
--    воркфлоу-фикстуры автопроверки (see autocheck/fixtures/migrations)
--    заводят не таблицу в уже существующей схеме, а СОВЕРШЕННО НОВУЮ
--    схему со случайным именем на каждый прогон (например,
--    probe_<hex>), внутри которой лежит SECURITY DEFINER функция —
--    именно её и вызывает api.invoke динамически через
--    "EXECUTE FORMAT('SELECT %I.%I($1,$2)', target_schema, target_function)"
--    (см. 002_functions.sql). У новой схемы по умолчанию НЕТ USAGE ни
--    у кого, кроме создавшей её роли (в отличие от EXECUTE на функциях,
--    который PUBLIC получает автоматически) — эмпирически проверено:
--    "permission denied for schema <имя>" при обращении от лица
--    course_owner. api.invoke ловит эту ошибку в "EXCEPTION WHEN
--    OTHERS" и возвращает тот же generic 'internal.error' — воркер
--    считает шаг проваленным/уходит в ретраи, и весь флоу зависает,
--    не доходя до ожидаемого состояния (отсюда падения execution/
--    versioning/concurrency/recovery/resilience при прогоне week-2
--    checker'а: буквально ни один флоу, чей первый шаг — реальный
--    вызов action'а, не может продвинуться дальше).
--
--    Имя схемы заранее не известно (генерируется на каждый прогон) —
--    точечный ALTER TABLE/SCHEMA OWNER TO, как в пункте (3), тут не
--    применить. Нужно правило "на будущее" уровня СХЕМЫ, а не
--    "IN SCHEMA <конкретное имя>": ALTER DEFAULT PRIVILEGES ... ON
--    SCHEMAS (без "IN SCHEMA") — правило не про объекты внутри
--    конкретных схем, а про сами схемы, которые FOR ROLE создаст в
--    будущем где угодно в базе. "cli"/"api" подключаются под
--    POSTGRES_USER (см. docker-compose.yml) — тем же подключением
--    применяются и штатные миграции, и фикстуры автопроверки, поэтому
--    правило регистрируем именно "FOR ROLE postgres".
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
    GRANT USAGE ON SCHEMAS TO course_owner;

-- На случай, если фикстура уже успела создать свою схему в ЭТОМ ЖЕ
-- volume до появления этого файла (миграции применяются по одному
-- разу, и правило из пункта выше защищает только будущее) —
-- донастраиваем задним числом все схемы, которые ещё не выдали
-- course_owner USAGE. Не трогаем системные/наши штатные схемы: им
-- права уже расставлены явно предыдущими миграциями, а трогать
-- pg_catalog/information_schema/public не нужно и не нужно.
DO $do$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT nspname FROM pg_catalog.pg_namespace
        WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'public',
                               'api', 'course', 'opencheck', 'payment', 'workflow')
          AND nspname NOT LIKE 'pg_%'
          AND NOT has_schema_privilege('course_owner', nspname, 'USAGE')
    LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO course_owner', r.nspname);
    END LOOP;
END
$do$;

-- 5) Тот же класс проблемы, что в пункте (2), но для роли, которая
--    реально создаёт объекты в проде. Правило "FOR ROLE course_migrator
--    ... GRANT ALL PRIVILEGES ON TABLES" из пункта (2) в реальности НИКОГДА
--    не срабатывает: "cli"/"api" подключаются под POSTGRES_USER (см.
--    docker-compose.yml и пункт 4 выше), а не под course_migrator — то
--    есть НИ ОДНА таблица в этой базе фактически не создаётся ролью
--    course_migrator. Единственное, что до сих пор закрывало этот пробел
--    для opencheck.canary конкретно — точечный ALTER TABLE OWNER TO из
--    пункта (3) по жёстко прописанному имени. Любая ДРУГАЯ будущая
--    таблица в course/opencheck/payment (другое имя фикстуры, другая
--    версия автопроверки) наступит на ровно ту же ошибку доступа, что
--    описана в пункте (2), в обход и пункта (2), и пункта (3).
--
--    Эмпирически проверено: CREATE TABLE opencheck.<любое имя> суперюзером
--    postgres → INSERT от course_owner → "permission denied for table" —
--    до этого правила пункт (4) (USAGE ON SCHEMAS) тут не помогает, он
--    защищает только СХЕМЫ целиком, а не таблицы внутри уже существующих
--    (opencheck и так существует с 001_initial.sql). Регистрируем то же
--    самое правило, что в пункте (2), но "FOR ROLE postgres" — по факту
--    рабочую версию этого правила.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA course, opencheck, payment
    GRANT ALL PRIVILEGES ON TABLES TO course_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA course, opencheck, payment
    GRANT ALL PRIVILEGES ON SEQUENCES TO course_owner;

-- Донастройка задним числом — по той же логике, что и в пункте (4): если
-- в этом же volume уже успела появиться таблица в одной из этих схем,
-- созданная postgres до появления этого файла, отдаём её course_owner
-- сразу, не дожидаясь следующего пересоздания таблицы.
DO $do$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT schemaname, tablename FROM pg_catalog.pg_tables
        WHERE schemaname IN ('course', 'opencheck', 'payment')
          AND tableowner = 'postgres'
    LOOP
        EXECUTE format('ALTER TABLE %I.%I OWNER TO course_owner', r.schemaname, r.tablename);
    END LOOP;
END
$do$;
