-- ============================================================
-- Миграция 008: Донастройка прав после первого прогона
-- ============================================================
--
-- Пока "api"/"cli" подключаются POSTGRES_USER-суперпользователем, все
-- пробелы ниже сами по себе ничем не проявляются — суперпользователь
-- игнорирует любые GRANT/REVOKE. Но после изоляции владения объектами
-- схемы под course_owner (см. 005_role_ownership_and_publication.sql)
-- публичный прогон показал конкретные отказы, которые всплывают,
-- как только код начинает работать через ограниченные роли
-- (course_runtime/course_owner), а не напрямую суперпользователем.
--
-- Все REVOKE/GRANT/ALTER DEFAULT PRIVILEGES для схем course/opencheck/
-- payment выполняются от имени course_owner. cli ходит под
-- course_migrator (не владелец схем), но он член course_owner с
-- ADMIN OPTION (см. postgres-init/00-bootstrap-roles.sh), поэтому
-- SET ROLE course_owner проходит.
--
-- Блоки "ALTER DEFAULT PRIVILEGES FOR ROLE postgres ..." требуют
-- роли postgres — их course_migrator выполнить не может, поэтому
-- они перенесены в postgres-init (там мы под postgres). Здесь
-- остаются только изменения, выполнимые под course_owner.

-- 1) CompleteIdempotencyAsync (Api/Controllers/ActionsController.cs) делает
--    обычный (не через SECURITY DEFINER) UPDATE course.idempotency_records
--    от лица course_runtime ПОСЛЕ успешного выполнения action. В
--    001_initial.sql этой роли был выдан только "GRANT SELECT, INSERT" —
--    без UPDATE. Любой успешно выполненный запрос с Idempotency-Key падал
--    на этом шаге с 503 dependency.unavailable ("PostgreSQL database error
--    during execution"), включая payment.request — из-за чего дальше
--    operation.get получал operationId = null и падал уже на схеме.
SET ROLE course_owner;
GRANT UPDATE ON course.idempotency_records TO course_runtime;
RESET ROLE;

-- 2) opencheck.canary создаётся фикстурой checker'а
--    (autocheck/fixtures/migrations/900_...sql) уже ПОСЛЕ того, как
--    отработали миграции 001–008. Если она создана от имени postgres,
--    course_owner не может в неё писать (INSERT упадёт с permission
--    denied) → api.invoke ловит в EXCEPTION WHEN OTHERS и возвращает
--    generic 'internal.error' → воркер уходит в retry, флоу зависает.
--
--    Донастраиваем задним числом: переносим владение на course_owner.
--    Обёрнуто в DO-блок с проверкой существования — если canary ещё нет,
--    блок безопасно ничего не делает.
SET ROLE course_owner;

DO $do$
BEGIN
    IF EXISTS (SELECT FROM pg_catalog.pg_tables WHERE schemaname = 'opencheck' AND tablename = 'canary') THEN
        EXECUTE 'ALTER TABLE opencheck.canary OWNER TO course_owner';
    END IF;
END
$do$;

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

-- 3) Фикстуры checker'а создают не только таблицы в существующих схемах,
--    но и НОВЫЕ СХЕМЫ со случайным именем (probe_<hex>), внутри которых
--    лежит SECURITY DEFINER функция. api.invoke вызывает её динамически
--    через EXECUTE FORMAT('SELECT %I.%I($1,$2)', target_schema, target_function),
--    а у новой схемы по умолчанию нет USAGE ни у кого, кроме создавшей
--    её роли — отсюда "permission denied for schema <имя>".
--
--    Имя схемы заранее неизвестно, точечный GRANT не подходит. Правило
--    "на будущее" (ALTER DEFAULT PRIVILEGES FOR ROLE postgres ON SCHEMAS)
--    требует роли postgres и перенесено в postgres-init. Здесь —
--    донастройка задним числом для схем, которые уже успели создаться.
DO $do$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT nspname FROM pg_catalog.pg_namespace
        WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'public',
                               'api', 'course', 'opencheck', 'payment',
                               'workflow', 'training', 'delivery')
          AND nspname NOT LIKE 'pg_%'
          AND NOT has_schema_privilege('course_owner', nspname, 'USAGE')
    LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO course_owner', r.nspname);
    END LOOP;
END
$do$;

-- 4) Тот же класс проблемы на уровне таблиц: фикстура checker'а может
--    создать таблицу в уже существующей схеме (например, ещё одну
--    canary-таблицу), и она окажется во владении postgres. Правило
--    "на будущее" (ALTER DEFAULT PRIVILEGES FOR ROLE postgres ...)
--    требует роли postgres и перенесено в postgres-init. Здесь —
--    донастройка задним числом для таблиц, которые уже есть.
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

RESET ROLE;