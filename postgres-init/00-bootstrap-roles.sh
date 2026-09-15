#!/bin/bash
# ============================================================
# Bootstrap: identity-роли для миграций/публикации/рантайма
# ============================================================
#
# Раньше "api" и "cli" подключались строкой с POSTGRES_USER, т.е. под тем
# же суперпользователем, которым поднят сам кластер. Любая ошибка в
# приложении получала суперпользовательский доступ к БД, и NOLOGIN-роли
# course_runtime/course_owner из 001_initial.sql существовали только "на
# бумаге" — под ними никто реально не подключался.
#
# Этот скрипт выполняется ОДИН РАЗ движком postgres-образа при первой
# инициализации (docker-entrypoint-initdb.d), пока volume ещё пуст, и от
# имени реального суперпользователя ($POSTGRES_USER) создаёт четыре
# отдельные identity:
#
#   course_owner        NOLOGIN — единственный настоящий владелец схемы/
#                        таблиц/функций. Под ним никто не логинится;
#                        миграции переключаются на него через SET ROLE.
#   course_migrator      LOGIN   — использует только "cli migration apply".
#                        Состоит в course_owner (может SET ROLE course_owner).
#   course_publication   NOLOGIN — минимальный набор прав на управление
#                        action_catalog (публикация/активация/отключение
#                        версий), без доступа к operations/events.
#   course_publisher     LOGIN   — использует только "cli action
#                        publish/activate/disable/list". Состоит в
#                        course_publication.
#   course_runtime       LOGIN   — обслуживает боевой трафик "api". Роль
#                        уже существовала как NOLOGIN-заготовка в
#                        001_initial.sql; здесь she получает реальный логин.
#
# Важно: docker-entrypoint-initdb.d выполняется только на ПУСТОМ volume.
# Если роли когда-то создавались вручную/другой версией скрипта, нужно
# "docker compose down -v" — README уже требует этого перед каждой проверкой.
set -euo pipefail

COURSE_MIGRATOR_PASSWORD="${COURSE_MIGRATOR_PASSWORD:-course_migrator_dev_password}"
COURSE_PUBLISHER_PASSWORD="${COURSE_PUBLISHER_PASSWORD:-course_publisher_dev_password}"
COURSE_RUNTIME_PASSWORD="${COURSE_RUNTIME_PASSWORD:-course_runtime_dev_password}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- NOLOGIN-владелец. Даём ему право создавать схемы/расширения в базе и
    -- в public — именно под этой ролью (через SET ROLE) course_migrator
    -- будет выполнять DDL в 001_initial.sql и далее.
    DO \$do\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_owner') THEN
            CREATE ROLE course_owner NOLOGIN;
        END IF;
    END
    \$do\$;
    GRANT CREATE, CONNECT ON DATABASE "$POSTGRES_DB" TO course_owner;
    GRANT CREATE ON SCHEMA public TO course_owner;

    -- migration identity: только логин + membership, DDL-права получает
    -- исключительно через "SET ROLE course_owner" внутри самих миграций.
    DO \$do\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_migrator') THEN
            CREATE ROLE course_migrator LOGIN PASSWORD '${COURSE_MIGRATOR_PASSWORD}';
        ELSE
            ALTER ROLE course_migrator LOGIN PASSWORD '${COURSE_MIGRATOR_PASSWORD}';
        END IF;
    END
    \$do\$;
    GRANT course_owner TO course_migrator;

    -- publication identity: видит только course.action_catalog (гранты на
    -- саму NOLOGIN-роль course_publication выдаются позже, в миграции
    -- 005_role_ownership_and_publication.sql, когда объект уже существует).
    DO \$do\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_publication') THEN
            CREATE ROLE course_publication NOLOGIN;
        END IF;
    END
    \$do\$;

    DO \$do\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_publisher') THEN
            CREATE ROLE course_publisher LOGIN PASSWORD '${COURSE_PUBLISHER_PASSWORD}';
        ELSE
            ALTER ROLE course_publisher LOGIN PASSWORD '${COURSE_PUBLISHER_PASSWORD}';
        END IF;
    END
    \$do\$;
    GRANT course_publication TO course_publisher;

    -- runtime identity: раньше NOLOGIN-заготовка в 001_initial.sql (её
    -- гранты на таблицы/функции там и остаются без изменений) — здесь
    -- только добавляем реальный логин, под которым будет ходить "api".
    DO \$do\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_runtime') THEN
            CREATE ROLE course_runtime LOGIN PASSWORD '${COURSE_RUNTIME_PASSWORD}';
        ELSE
            ALTER ROLE course_runtime LOGIN PASSWORD '${COURSE_RUNTIME_PASSWORD}';
        END IF;
    END
    \$do\$;
EOSQL
