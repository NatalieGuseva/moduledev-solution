#!/bin/bash
# Запускается ОДИН раз официальным postgres-образом при первой инициализации
# data-директории (/docker-entrypoint-initdb.d), от имени реального init
# суперпользователя ($POSTGRES_USER). Больше никогда не выполняется на уже
# существующей БД — поэтому именно здесь, а не в checksummed-миграциях,
# заводятся LOGIN-роли course_migrator/course_publisher/course_runtime/
# workflow_worker/outbox_dispatcher/inbox_reconciler: миграции — статичные
# .sql файлы без доступа к env, а cli НЕ входит в allow-list checker'а для
# COURSE_OUTBOX_PASSWORD/COURSE_INBOX_PASSWORD (checker проверяет, что
# значение этих секретов встречается только в env postgres и
# соответствующего python-сервиса — см. docs/configuration.md и
# _secret_distribution_findings в чекере).
set -euo pipefail

: "${COURSE_MIGRATOR_PASSWORD:?COURSE_MIGRATOR_PASSWORD is required}"
: "${COURSE_PUBLISHER_PASSWORD:?COURSE_PUBLISHER_PASSWORD is required}"
: "${COURSE_RUNTIME_PASSWORD:?COURSE_RUNTIME_PASSWORD is required}"
: "${COURSE_WORKER_PASSWORD:?COURSE_WORKER_PASSWORD is required}"
: "${COURSE_OUTBOX_PASSWORD:?COURSE_OUTBOX_PASSWORD is required}"
: "${COURSE_INBOX_PASSWORD:?COURSE_INBOX_PASSWORD is required}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- ============================================================
    -- 1. course_owner — NOLOGIN-владелец всех объектов схем.
    --    Создаём ПЕРВОЙ, потому что ниже идёт ALTER SCHEMA ...
    --    OWNER TO course_owner — он требует, чтобы роль уже
    --    существовала. 001_initial.sql тоже создаёт эту роль через
    --    IF NOT EXISTS, поэтому повторное создание безопасно.
    -- ============================================================
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_owner') THEN
            CREATE ROLE course_owner NOLOGIN;
        END IF;
    END
    \$\$;

    -- ============================================================
    -- 2. course_migrator — LOGIN + CREATEROLE. Под ней cli делает
    --    migration apply. CREATEROLE нужен, потому что миграции сами
    --    создают роли (course_owner, course_runtime, workflow_worker,
    --    outbox_dispatcher, inbox_reconciler).
    -- ============================================================
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_migrator') THEN
            CREATE ROLE course_migrator WITH LOGIN CREATEROLE PASSWORD '$COURSE_MIGRATOR_PASSWORD';
        ELSE
            ALTER ROLE course_migrator WITH LOGIN CREATEROLE PASSWORD '$COURSE_MIGRATOR_PASSWORD';
        END IF;
    END
    \$\$;

    -- migrator должен уметь SET ROLE course_owner. WITH ADMIN OPTION —
    -- чтобы он мог в дальнейшем выдавать это членство другим ролям.
    GRANT course_owner TO course_migrator WITH ADMIN OPTION;

    -- ============================================================
    -- 3. Схемы. 001_initial.sql тоже создаёт их через IF NOT EXISTS,
    --    но не меняет владельца — если схему создали здесь под
    --    postgres, то владельцем останется postgres, и
    --    course_migrator не сможет в ней ничего делать. Поэтому
    --    явно отдаём course_owner.
    -- ============================================================
    CREATE SCHEMA IF NOT EXISTS course;
    CREATE SCHEMA IF NOT EXISTS opencheck;
    CREATE SCHEMA IF NOT EXISTS payment;
    CREATE SCHEMA IF NOT EXISTS workflow;
    CREATE SCHEMA IF NOT EXISTS delivery;
    CREATE SCHEMA IF NOT EXISTS training;

    ALTER SCHEMA course OWNER TO course_owner;
    ALTER SCHEMA opencheck OWNER TO course_owner;
    ALTER SCHEMA payment OWNER TO course_owner;
    ALTER SCHEMA workflow OWNER TO course_owner;
    ALTER SCHEMA delivery OWNER TO course_owner;
    ALTER SCHEMA training OWNER TO course_owner;

    -- ============================================================
    -- 4. Default privileges для будущих объектов (создаваемых
    --    postgres — тем же подключением, что init-скрипт и фикстуры
    --    checker'а). Любая таблица в course/opencheck/payment и
    --    любая новая схема автоматически получают course_owner.
    -- ============================================================
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA course, opencheck, payment
        GRANT ALL PRIVILEGES ON TABLES TO course_owner;
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA course, opencheck, payment
        GRANT ALL PRIVILEGES ON SEQUENCES TO course_owner;
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres
        GRANT USAGE ON SCHEMAS TO course_owner;

    -- ============================================================
    -- 5. course_publisher — под ней cli action/flow publish.
    -- ============================================================
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_publisher') THEN
            CREATE ROLE course_publisher WITH LOGIN PASSWORD '$COURSE_PUBLISHER_PASSWORD';
        ELSE
            ALTER ROLE course_publisher WITH LOGIN PASSWORD '$COURSE_PUBLISHER_PASSWORD';
        END IF;
    END
    \$\$;

    -- ============================================================
    -- 6. course_runtime — LOGIN-роль C# API. Least-privilege.
    -- ============================================================
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_runtime') THEN
            CREATE ROLE course_runtime WITH LOGIN PASSWORD '$COURSE_RUNTIME_PASSWORD';
        ELSE
            ALTER ROLE course_runtime WITH LOGIN PASSWORD '$COURSE_RUNTIME_PASSWORD';
        END IF;
    END
    \$\$;

    -- ============================================================
    -- 7. workflow_worker — LOGIN-роль C# worker'ов.
    -- ============================================================
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'workflow_worker') THEN
            CREATE ROLE workflow_worker WITH LOGIN PASSWORD '$COURSE_WORKER_PASSWORD';
        ELSE
            ALTER ROLE workflow_worker WITH LOGIN PASSWORD '$COURSE_WORKER_PASSWORD';
        END IF;
    END
    \$\$;

    -- ============================================================
    -- 8. outbox_dispatcher / inbox_reconciler — LOGIN-роли Python.
    -- ============================================================
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'outbox_dispatcher') THEN
            CREATE ROLE outbox_dispatcher WITH LOGIN PASSWORD '$COURSE_OUTBOX_PASSWORD';
        ELSE
            ALTER ROLE outbox_dispatcher WITH LOGIN PASSWORD '$COURSE_OUTBOX_PASSWORD';
        END IF;
    END
    \$\$;

    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'inbox_reconciler') THEN
            CREATE ROLE inbox_reconciler WITH LOGIN PASSWORD '$COURSE_INBOX_PASSWORD';
        ELSE
            ALTER ROLE inbox_reconciler WITH LOGIN PASSWORD '$COURSE_INBOX_PASSWORD';
        END IF;
    END
    \$\$;

    -- ============================================================
    -- 9. pgcrypto (public).
    --
    --    ВАЖНО: CREATE EXTENSION делаем ЗДЕСЬ, до REVOKE, а не в
    --    001_initial.sql. Иначе функции расширения создаёт
    --    course_migrator уже после init-скрипта, и наш REVOKE PUBLIC
    --    оказывается не на что наложить (функций ещё нет) —
    --    pgcrypto остаётся доступна PUBLIC, и outbox_dispatcher /
    --    inbox_reconciler получают лишний EXECUTE на digest/hmac/
    --    gen_random_uuid/... Checker недели 3 требует, чтобы у них
    --    был EXECUTE РОВНО на 4 функции delivery.*.
    --
    --    public принадлежит postgres — course_migrator туда не
    --    достаёт, поэтому REVOKE делаем здесь, под postgres.
    --    001_initial.sql использует CREATE EXTENSION IF NOT EXISTS,
    --    так что повторное создание — no-op.
    -- ============================================================
    CREATE EXTENSION IF NOT EXISTS pgcrypto;

    REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
        REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public
        TO course_owner, course_migrator, course_publisher;

    -- ============================================================
    -- 10. course_migrator должен владеть базой — иначе CREATE SCHEMA/
    --     EXTENSION внутри миграций упадёт (PG15+ запрещает CREATE
    --     на базе всем, кроме владельца и суперпользователя).
    -- ============================================================
    ALTER DATABASE "$POSTGRES_DB" OWNER TO course_migrator;
EOSQL

echo "course_owner / course_migrator / course_publisher / course_runtime / workflow_worker / outbox_dispatcher / inbox_reconciler bootstrap complete"