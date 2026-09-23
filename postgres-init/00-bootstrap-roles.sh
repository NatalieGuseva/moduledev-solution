#!/bin/bash
# Запускается ОДИН раз официальным postgres-образом при первой инициализации
# data-директории (/docker-entrypoint-initdb.d), от имени реального init
# суперпользователя ($POSTGRES_USER). Больше никогда не выполняется на уже
# существующей БД — поэтому именно здесь, а не в checksummed-миграциях,
# заводятся LOGIN-роли course_migrator/course_publisher/outbox_dispatcher/
# inbox_reconciler: миграции — статичные .sql файлы без доступа к env, а
# cli НЕ входит в allow-list checker'а для COURSE_OUTBOX_PASSWORD/
# COURSE_INBOX_PASSWORD (checker проверяет, что значение этих секретов
# встречается только в env postgres и соответствующего python-сервиса —
# см. docs/configuration.md и _secret_distribution_findings в чекере).
set -euo pipefail

: "${COURSE_MIGRATOR_PASSWORD:?COURSE_MIGRATOR_PASSWORD is required}"
: "${COURSE_PUBLISHER_PASSWORD:?COURSE_PUBLISHER_PASSWORD is required}"
: "${COURSE_OUTBOX_PASSWORD:?COURSE_OUTBOX_PASSWORD is required}"
: "${COURSE_INBOX_PASSWORD:?COURSE_INBOX_PASSWORD is required}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- course_migrator запускает "cli migration apply". CREATEROLE нужен,
    -- потому что 001_initial.sql и последующие миграции сами создают роли
    -- (course_owner, course_runtime, workflow_worker, outbox_dispatcher,
    -- inbox_reconciler) — обычный member без этого атрибута такого не может.
    -- Postgres при этом автоматически даёт создателю ADMIN OPTION на роли,
    -- которые он создал через CREATEROLE (без нужды быть superuser), поэтому
    -- migrator может тут же выдать себе/другим членство в них.
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_migrator') THEN
            CREATE ROLE course_migrator WITH LOGIN CREATEROLE PASSWORD '$COURSE_MIGRATOR_PASSWORD';
        ELSE
            ALTER ROLE course_migrator WITH LOGIN CREATEROLE PASSWORD '$COURSE_MIGRATOR_PASSWORD';
        END IF;
    END
    \$\$;

    -- course_publisher — под ней работают "cli action publish/list/activate/
    -- disable" и "cli flow publish/activate/validate/start/signal/finish".
    -- Обычный LOGIN без CREATEROLE/CREATEDB: ей нужен только точечный DML на
    -- course.action_catalog/workflow.* и EXECUTE на конкретные функции —
    -- эти GRANT выдаёт уже сама миграция (014_publisher_grants.sql), после
    -- того как соответствующие таблицы/функции существуют.
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_publisher') THEN
            CREATE ROLE course_publisher WITH LOGIN PASSWORD '$COURSE_PUBLISHER_PASSWORD';
        ELSE
            ALTER ROLE course_publisher WITH LOGIN PASSWORD '$COURSE_PUBLISHER_PASSWORD';
        END IF;
    END
    \$\$;

    -- outbox_dispatcher / inbox_reconciler — LOGIN-роли Python
    -- outbox-dispatcher и inbox-reconciler (неделя 3). Пароль берётся из
    -- COURSE_OUTBOX_PASSWORD/COURSE_INBOX_PASSWORD — тех же переменных,
    -- которые checker подставляет synthetic-значением python-сервисам,
    -- поэтому роль в БД и клиент всегда согласованы. GRANT EXECUTE на
    -- конкретные функции выдаёт 011_delivery_functions.sql, когда функции
    -- уже существуют; здесь роль только создаётся/переустанавливает пароль.
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

    -- course_migrator должен иметь право создавать схемы/расширения и т.д.
    -- в этой конкретной базе — сама база создана init-суперпользователем
    -- ($POSTGRES_USER), поэтому по умолчанию (PG15+) CREATE на ней больше
    -- никому не разрешён. Владение базой — простейший способ дать
    -- migrator'у это право, не делая его суперпользователем.
    ALTER DATABASE "$POSTGRES_DB" OWNER TO course_migrator;
EOSQL

echo "course_migrator / course_publisher / outbox_dispatcher / inbox_reconciler bootstrap complete"
