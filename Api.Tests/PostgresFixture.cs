using Npgsql;
using Testcontainers.PostgreSql;
using Xunit;

namespace Api.Tests;

// Поднимает настоящий postgres:17-alpine в Docker и накатывает РОВНО те же
// файлы, что и "cli migration apply" в проде (см. Api.Tests.csproj —
// Api/Migrations/ChecksummedMigrations/*.sql и
// autocheck/fixtures/migrations/*.sql копируются как есть, не переписываются
// вручную под тест). Роли — тот же набор, что создаёт
// postgres-init/00-bootstrap-roles.sh. Смысл: регрессионные тесты должны
// ловить поломки в РЕАЛЬНЫХ grants/constraints/triggers, а не в отдельной
// "тестовой" копии схемы, которая может незаметно разойтись с прод-версией.
public sealed class PostgresFixture : IAsyncLifetime
{
    private const string MigratorPassword = "test_migrator_pw";
    private const string PublisherPassword = "test_publisher_pw";
    private const string RuntimePassword = "test_runtime_pw";

    private PostgreSqlContainer _container = null!;

    public string SuperuserConnectionString { get; private set; } = string.Empty;
    public string MigratorConnectionString { get; private set; } = string.Empty;
    public string PublisherConnectionString { get; private set; } = string.Empty;
    public string RuntimeConnectionString { get; private set; } = string.Empty;

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

    // Тот же набор ролей, что и postgres-init/00-bootstrap-roles.sh — тест
    // проверяет ровно ту схему прав, что реально накатывается в проде.
    private async Task BootstrapRolesAsync()
    {
        var sql = @"
            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_owner') THEN
                    CREATE ROLE course_owner NOLOGIN;
                END IF;
            END
            $do$;

            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_migrator') THEN
                    CREATE ROLE course_migrator LOGIN PASSWORD '" + MigratorPassword + @"';
                END IF;
            END
            $do$;
            GRANT course_owner TO course_migrator;
            GRANT CREATE, CONNECT ON DATABASE course TO course_owner;
            GRANT CREATE ON SCHEMA public TO course_owner;

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
                    CREATE ROLE course_publisher LOGIN PASSWORD '" + PublisherPassword + @"';
                END IF;
            END
            $do$;
            GRANT course_publication TO course_publisher;

            DO $do$
            BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'course_runtime') THEN
                    CREATE ROLE course_runtime LOGIN PASSWORD '" + RuntimePassword + @"';
                ELSE
                    ALTER ROLE course_runtime LOGIN PASSWORD '" + RuntimePassword + @"';
                END IF;
            END
            $do$;
        ";

        await using var connection = new NpgsqlConnection(SuperuserConnectionString);
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }

    // Применяет файлы из Api/Migrations/ChecksummedMigrations (001-010) и,
    // следом за ними, autocheck/fixtures/migrations/900_opencheck_probe.sql —
    // именно тот файл, который в проде создаёт opencheck.canary и вскрыл
    // пробел в правах course_owner (см. миграцию 008 и RoleGrantsRegressionTests).
    //
    // Подключение — СУПЕРПОЛЬЗОВАТЕЛЕМ (SuperuserConnectionString), не
    // course_migrator: ровно так же, как реально подключается "cli" в
    // docker-compose.yml (ConnectionStrings__CourseDb с POSTGRES_USER).
    // course_migrator, даже будучи членом course_owner, не имеет CREATEROLE
    // (членство в роли не передаёт role-атрибуты вроде CREATEROLE/CREATEDB) —
    // подключение им сюда падало бы на "CREATE ROLE workflow_worker" в
    // 005_workflow_schema.sql с "permission denied to create role".
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

        await using var connection = new NpgsqlConnection(SuperuserConnectionString);
        await connection.OpenAsync();

        foreach (var file in files)
        {
            var content = await File.ReadAllTextAsync(file);
            await using var command = new NpgsqlCommand(content, connection);
            await command.ExecuteNonQueryAsync();
        }
    }
}

[CollectionDefinition("Postgres")]
public sealed class PostgresCollection : ICollectionFixture<PostgresFixture>
{
    // Контейнер дорогой (несколько секунд на старт + прогон 001-008) —
    // делится между всеми классами теста через xUnit collection fixture,
    // вместо того чтобы поднимать новый Postgres на каждый [Fact].
}
