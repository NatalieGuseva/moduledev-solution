#!/bin/bash
# Запускается ОДИН раз официальным postgres-образом при первой инициализации
# data-директории (/docker-entrypoint-initdb.d), от имени реального init
# суперпользователя ($POSTGRES_USER). Больше никогда не выполняется на уже
# существующей БД — поэтому именно здесь, а не в checksummed-миграциях,
# заводятся LOGIN-роли: миграции — статичные .sql файлы без доступа к env.
set -euo pipefail

: "${COURSE_MIGRATOR_PASSWORD:?COURSE_MIGRATOR_PASSWORD is required}"
: "${COURSE_PUBLISHER_PASSWORD:?COURSE_PUBLISHER_PASSWORD is required}"
: "${COURSE_RUNTIME_PASSWORD:?COURSE_RUNTIME_PASSWORD is required}"
: "${COURSE_WORKER_PASSWORD:?COURSE_WORKER_PASSWORD is required}"
: "${COURSE_OUTBOX_PASSWORD:?COURSE_OUTBOX_PASSWORD is required}"
: "${COURSE_INBOX_PASSWORD:?COURSE_INBOX_PASSWORD is required}"
: "${COURSE_AUTOCHECK_PASSWORD:?COURSE_AUTOCHECK_PASSWORD is required}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- ============================================================
    -- 1. course_owner — NOLOGIN-владелец всех объектов схем.
    -- ============================================================
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_owner') THEN
            CREATE ROLE course_owner NOLOGIN;
        END IF;
    END
    \$\$;

    -- ============================================================
    -- 2. course_migrator — LOGIN + CREATEROLE.
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

    GRANT course_owner TO course_migrator WITH ADMIN OPTION;

    -- ============================================================
    -- 3. Схемы + владелец.
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
    -- 4. Default privileges.
    -- ============================================================
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA course, opencheck, payment
        GRANT ALL PRIVILEGES ON TABLES TO course_owner;
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA course, opencheck, payment
        GRANT ALL PRIVILEGES ON SEQUENCES TO course_owner;
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres
        GRANT USAGE ON SCHEMAS TO course_owner;

    -- ============================================================
    -- 5. course_publisher.
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
    -- 6. course_runtime.
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
    -- 7. workflow_worker.
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
    -- 8. outbox_dispatcher / inbox_reconciler.
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
    -- 9. autocheck_reader — LOGIN-роль checker'а. Read-only доступ
    --    ТОЛЬКО к views schema autocheck. GRANT'ы на views выдаются
    --    отдельной миграцией 019 (после того, как views созданы),
    --    потому что на момент bootstrap схема autocheck ещё не
    --    существует.
    -- ============================================================
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'autocheck_reader') THEN
            CREATE ROLE autocheck_reader WITH LOGIN PASSWORD '$COURSE_AUTOCHECK_PASSWORD';
        ELSE
            ALTER ROLE autocheck_reader WITH LOGIN PASSWORD '$COURSE_AUTOCHECK_PASSWORD';
        END IF;
    END
    \$\$;

    -- Defence-in-depth: никаких лишних атрибутов, никаких default-прав
    -- на public. USAGE/SELECT на autocheck.* выдаются миграцией 019.
    ALTER ROLE autocheck_reader NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION;
    REVOKE ALL ON DATABASE "$POSTGRES_DB" FROM autocheck_reader;
    GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO autocheck_reader;
    REVOKE ALL ON SCHEMA public FROM autocheck_reader;
     -- TEMP по умолчанию выдан роли PUBLIC на каждую базу. Роль
    -- autocheck_reader наследует его через PUBLIC, и простое
    -- REVOKE ALL ... FROM autocheck_reader это НЕ отменяет — нужен
    -- явный отзыв у PUBLIC. Checker проверяет именно
    -- has_database_privilege(current_user, current_database(), 'TEMP'),
    -- который считает эффективную привилегию с учётом PUBLIC.
    REVOKE TEMP ON DATABASE "$POSTGRES_DB" FROM PUBLIC;

    -- ============================================================
    -- 10. pgcrypto (public).
    -- ============================================================
    CREATE EXTENSION IF NOT EXISTS pgcrypto;

    REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
        REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public
        TO course_owner, course_migrator, course_publisher;

    -- ============================================================
    -- 11. course_migrator — владелец базы.
    -- ============================================================
    ALTER DATABASE "$POSTGRES_DB" OWNER TO course_migrator;
EOSQL

echo "course_owner / course_migrator / course_publisher / course_runtime / workflow_worker / outbox_dispatcher / inbox_reconciler / autocheck_reader bootstrap complete"