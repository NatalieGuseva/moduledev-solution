using Npgsql;
using Testcontainers.PostgreSql;
using Xunit;

namespace Api.Tests;

// Поднимает настоящий postgres:17-alpine в Docker и накатывает РОВНО те же
// файлы, что и "cli migration apply" в проде (Api/Migrations/ChecksummedMigrations/*.sql).
//
// FIX (неделя 4, фидбэк недели 3 "Синхронизировать Testcontainers bootstrap
// с production role/schema ownership и запускать migrations тем же
// разрешённым principal"): раньше BootstrapRolesAsync заводил только
// course_owner/course_migrator/course_publication/course_publisher/
// course_runtime и НИ ОДНОЙ схемы, а ApplyMigrationsAsync подключался
// SuperuserConnectionString (буквально Postgres superuser, не course_migrator).
// В проде postgres-init/00-bootstrap-roles.sh делает СУЩЕСТВЕННО больше:
//   - создаёт схемы course/opencheck/payment/workflow/delivery/training
//     и СРАЗУ отдаёт их course_owner (ALTER SCHEMA ... OWNER TO course_owner);
//   - выставляет ALTER DEFAULT PRIVILEGES FOR ROLE postgres ... GRANT USAGE
//     ON SCHEMAS TO course_owner (для схем, которые появятся позже);
//   - настраивает pgcrypto (REVOKE PUBLIC + explicit GRANT back);
//   - переключает владельца самой БД на course_migrator (без этого
//     CREATE SCHEMA/EXTENSION внутри миграций падает на PG15+).
// Миграции в проде реально накатывает "cli" ПОД course_migrator, а не
// суперпользователем. Из-за этого расхождения 010_insert_training_canary_action.sql
// создавало schema training без ALTER OWNER (там его специально нет —
// комментарий в файле: "по аналогии с opencheck в 001_initial.sql", т.е.
// полагается на то, что bootstrap уже отдал схему course_owner заранее).
// В тесте schema training создавалась суперпользователем, и 016-я миграция
// (SET ROLE course_owner; REVOKE ... IN SCHEMA training; ALTER DEFAULT
// PRIVILEGES IN SCHEMA training ...) падала с "permission denied for schema
// training", потому что course_owner не владел этой схемой и не имел на неё
// CREATE. Ниже — тот же набор действий, что в реальном bootstrap-скрипте,
// плюс сам ApplyMigrationsAsync теперь подключается MigratorConnectionString.
public sealed class PostgresFixture : IAsyncLifetime
{
    private const string MigratorPassword = "test_migrator_pw";
    private const string PublisherPassword = "test_publisher_pw";
    private const string RuntimePassword = "test_runtime_pw";
    private const string WorkerPassword = "test_worker_pw";
    private const string OutboxPassword = "test_outbox_pw";
    private const string InboxPassword = "test_inbox_pw";

    private PostgreSqlContainer _container = null!;

    public string SuperuserConnectionString { get; private set; } = string.Empty;
    public string MigratorConnectionString { get; private set; } = string.Empty;
    public string PublisherConnectionString { get; private set; } = string.Empty;
    public string RuntimeConnectionString { get; private set; } = string.Empty;
    public string WorkerConnectionString { get; private set; } = string.Empty;
    public string OutboxConnectionString { get; private set; } = string.Empty;
    public string InboxConnectionString { get; private set; } = string.Empty;

    public async Task InitializeAsync()
    {
        _container = new PostgreSqlBuilder()
            .WithImage("postgres:17-alpine")
            .WithDatabase("course")
            .WithUsername("postgres")
            .WithPassword("postgres")
            .Build();

        await _container.StartAsync();

        SuperuserConnectionString = _container.GetConnectionString();
        MigratorConnectionString = WithCredentials(SuperuserConnectionString, "course_migrator", MigratorPassword);
        PublisherConnectionString = WithCredentials(SuperuserConnectionString, "course_publisher", PublisherPassword);
        RuntimeConnectionString = WithCredentials(SuperuserConnectionString, "course_runtime", RuntimePassword);
        WorkerConnectionString = WithCredentials(SuperuserConnectionString, "workflow_worker", WorkerPassword);
        OutboxConnectionString = WithCredentials(SuperuserConnectionString, "outbox_dispatcher", OutboxPassword);
        InboxConnectionString = WithCredentials(SuperuserConnectionString, "inbox_reconciler", InboxPassword);

        await BootstrapRolesAsync();
        await ApplyMigrationsAsync();
    }

    public async Task DisposeAsync()
    {
        await _container.DisposeAsync();
    }

    private static string WithCredentials(string baseConnectionString, string username, string password)
    {
        var builder = new NpgsqlConnectionStringBuilder(baseConnectionString)
        {
            Username = username,
            Password = password
        };
        return builder.ConnectionString;
    }

    // Faithful копия postgres-init/00-bootstrap-roles.sh (то, что реально
    // выполняется ОДИН раз при инициализации тома в проде), под литеральными
    // паролями теста вместо COURSE_*_PASSWORD переменных окружения.
    private async Task BootstrapRolesAsync()
    {
        var sql = @"
            -- 1. course_owner — NOLOGIN-владелец всех объектов схем.
            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_owner') THEN
                    CREATE ROLE course_owner NOLOGIN;
                END IF;
            END
            $do$;

            -- 2. course_migrator — LOGIN + CREATEROLE (миграции сами создают роли).
            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_migrator') THEN
                    CREATE ROLE course_migrator WITH LOGIN CREATEROLE PASSWORD '" + MigratorPassword + @"';
                ELSE
                    ALTER ROLE course_migrator WITH LOGIN CREATEROLE PASSWORD '" + MigratorPassword + @"';
                END IF;
            END
            $do$;

            GRANT course_owner TO course_migrator WITH ADMIN OPTION;

            -- 3. Схемы, созданные и отданные course_owner ДО миграций — ровно
            --    как в постоянном томе прода. 010_insert_training_canary_action.sql
            --    и 017_reliability_and_diagnostics.sql полагаются именно на это
            --    (CREATE SCHEMA IF NOT EXISTS training / diagnostics — no-op,
            --    раз схема уже тут, владелец не трогается).
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

            -- 4. Default privileges для будущих объектов/схем, создаваемых
            --    postgres (сюда же попадает schema api/autocheck из
            --    001_initial.sql, если их создаст суперпользователь; но
            --    миграции теперь идут под course_migrator — см. ниже).
            ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA course, opencheck, payment
                GRANT ALL PRIVILEGES ON TABLES TO course_owner;
            ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA course, opencheck, payment
                GRANT ALL PRIVILEGES ON SEQUENCES TO course_owner;
            ALTER DEFAULT PRIVILEGES FOR ROLE postgres
                GRANT USAGE ON SCHEMAS TO course_owner;

            -- 5. course_publisher.
            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_publication') THEN
                    CREATE ROLE course_publication NOLOGIN;
                END IF;
            END
            $do$;

            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_publisher') THEN
                    CREATE ROLE course_publisher WITH LOGIN PASSWORD '" + PublisherPassword + @"';
                ELSE
                    ALTER ROLE course_publisher WITH LOGIN PASSWORD '" + PublisherPassword + @"';
                END IF;
            END
            $do$;
            GRANT course_publication TO course_publisher;

            -- 6. course_runtime — LOGIN-роль C# API.
            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_runtime') THEN
                    CREATE ROLE course_runtime WITH LOGIN PASSWORD '" + RuntimePassword + @"';
                ELSE
                    ALTER ROLE course_runtime WITH LOGIN PASSWORD '" + RuntimePassword + @"';
                END IF;
            END
            $do$;

            -- 7. workflow_worker — LOGIN-роль C# worker'ов (обычно создаётся
            --    самими миграциями 005_workflow_schema.sql; заводим здесь тоже,
            --    идемпотентно, чтобы WorkerConnectionString был валиден сразу
            --    после InitializeAsync, ещё до применения миграций).
            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'workflow_worker') THEN
                    CREATE ROLE workflow_worker WITH LOGIN PASSWORD '" + WorkerPassword + @"';
                ELSE
                    ALTER ROLE workflow_worker WITH LOGIN PASSWORD '" + WorkerPassword + @"';
                END IF;
            END
            $do$;

            -- 8. outbox_dispatcher / inbox_reconciler — LOGIN-роли Python.
            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'outbox_dispatcher') THEN
                    CREATE ROLE outbox_dispatcher WITH LOGIN PASSWORD '" + OutboxPassword + @"';
                ELSE
                    ALTER ROLE outbox_dispatcher WITH LOGIN PASSWORD '" + OutboxPassword + @"';
                END IF;
            END
            $do$;

            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'inbox_reconciler') THEN
                    CREATE ROLE inbox_reconciler WITH LOGIN PASSWORD '" + InboxPassword + @"';
                ELSE
                    ALTER ROLE inbox_reconciler WITH LOGIN PASSWORD '" + InboxPassword + @"';
                END IF;
            END
            $do$;

            -- 9. pgcrypto (public) — CREATE EXTENSION ДО REVOKE, иначе REVOKE
            --    накладывать не на что; затем explicit GRANT back только
            --    course_owner/course_migrator/course_publisher (Python-ролям —
            --    намеренно нет, ровно как в проде).
            CREATE EXTENSION IF NOT EXISTS pgcrypto;

            REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
            ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
                REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
            GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public
                TO course_owner, course_migrator, course_publisher;

            -- 10. course_migrator должен владеть базой — иначе CREATE SCHEMA/
            --     EXTENSION внутри миграций падает на PG15+ (CREATE на базе
            --     разрешён только владельцу и суперпользователю).
            ALTER DATABASE course OWNER TO course_migrator;
        ";

        await using var connection = new NpgsqlConnection(SuperuserConnectionString);
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }

    // FIX: подключение теперь MigratorConnectionString (course_migrator),
    // РОВНО как реальный "cli" в docker-compose.yml
    // (ConnectionStrings__CourseDb=...Username=course_migrator...), а не
    // суперпользователем. Это и есть "запускать migrations тем же
    // разрешённым principal" из фидбэка: миграции теперь видят ТОЧНО ту же
    // картину владения объектами (course_migrator создаёт api/autocheck,
    // course_owner уже владеет course/opencheck/payment/workflow/delivery/
    // training с самого начала), что и в проде.
    private async Task ApplyMigrationsAsync()
    {
        var migrationsDir = Path.Combine(AppContext.BaseDirectory, "Migrations");
        var files = Directory.GetFiles(migrationsDir, "*.sql")
            .OrderBy(Path.GetFileName, StringComparer.Ordinal)
            .ToList();

        if (files.Count == 0)
        {
            throw new InvalidOperationException(
                $"No migration files found under '{migrationsDir}'. Check the <None Include=.../> globs in Api.Tests.csproj.");
        }

        await using var connection = new NpgsqlConnection(MigratorConnectionString);
        await connection.OpenAsync();

        foreach (var file in files)
        {
            var content = await File.ReadAllTextAsync(file);
            await using var command = new NpgsqlCommand(content, connection);
            try
            {
                await command.ExecuteNonQueryAsync();
            }
            catch (PostgresException ex)
            {
                throw new InvalidOperationException($"Migration '{Path.GetFileName(file)}' failed: {ex.MessageText}", ex);
            }
        }
    }
}

[CollectionDefinition("Postgres")]
public sealed class PostgresCollection : ICollectionFixture<PostgresFixture>
{
    // Контейнер дорогой (несколько секунд на старт + прогон всех миграций) —
    // делится между всеми классами теста через xUnit collection fixture,
    // вместо того чтобы поднимать новый Postgres на каждый [Fact].
}
