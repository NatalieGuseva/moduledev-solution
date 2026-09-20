using Dapper;
using Npgsql;
using Xunit;

namespace Api.Tests;

// Регрессионные тесты на пункты фидбэка:
// - "Высокий приоритет: API и CLI работают PostgreSQL superuser" — теперь
//   у каждой identity свой, минимальный набор прав; эти тесты проверяют
//   ОБЕ стороны контракта: что нужное разрешено, и что лишнее запрещено.
// - "Права ролей и неизменяемость: прикладная runtime-роль не может
//   изменять operation или удалять event" — раньше это было недоказуемо,
//   потому что api реально ходил под postgres-суперпользователем.
// - Найденный по week-1-public-report.json баг: таблица, которую заводит
//   фикстура автопроверки (в проде — суперпользователем postgres, см.
//   docker-compose.yml), должна быть доступна course_owner "на будущее",
//   а не только по жёстко прописанному имени (миграция 008, пункт 5).
[Collection("Postgres")]
public class RoleGrantsRegressionTests
{
    private readonly PostgresFixture _fixture;

    public RoleGrantsRegressionTests(PostgresFixture fixture)
    {
        _fixture = fixture;
    }

    [Fact]
    public async Task CourseRuntime_CannotInsertDirectlyIntoOperations()
    {
        // Предметные операции создаются ТОЛЬКО через SECURITY DEFINER
        // функцию course.payment_request (владелец course_owner), никогда
        // напрямую от лица course_runtime. Если этот тест начнёт падать
        // (т.е. INSERT вдруг станет разрешён), значит кто-то по ошибке
        // выдал course_runtime лишние права напрямую на таблицу.
        await using var connection = new NpgsqlConnection(_fixture.RuntimeConnectionString);
        await connection.OpenAsync();

        var ex = await Assert.ThrowsAsync<PostgresException>(() => connection.ExecuteAsync(@"
            INSERT INTO course.operations (request_id, principal, payload_hash, operation_kind, amount, currency, status)
            VALUES ('req-x', 'someone', 'hash', 'PAYMENT_EXECUTION', 10.00, 'RUB', 'CREATED')"));

        Assert.Equal("42501", ex.SqlState); // insufficient_privilege
    }

    [Fact]
    public async Task CourseRuntime_CannotUpdateActionCatalog()
    {
        // Публикация/активация/отключение версий — задача course_publisher,
        // не рантайма. course_runtime может только читать action_catalog.
        await using var connection = new NpgsqlConnection(_fixture.RuntimeConnectionString);
        await connection.OpenAsync();

        var ex = await Assert.ThrowsAsync<PostgresException>(() =>
            connection.ExecuteAsync("UPDATE course.action_catalog SET enabled = false WHERE module = 'opencheck'"));

        Assert.Equal("42501", ex.SqlState);
    }

    [Fact]
    public async Task CoursePublisher_CanReadWriteActionCatalog()
    {
        await using var connection = new NpgsqlConnection(_fixture.PublisherConnectionString);
        await connection.OpenAsync();

        var exception = await Record.ExceptionAsync(async () =>
        {
            await connection.ExecuteAsync(@"
                INSERT INTO course.action_catalog
                    (module, action, version, target_schema, target_function, request_schema, response_schema,
                     outcomes, required_policy, idempotency_mode, idempotency_scope, enabled, is_default)
                VALUES
                    ('regression', 'probe', 1, 'opencheck', 'probe_v1', '{}'::jsonb, '{}'::jsonb,
                     '[]'::jsonb, '[]'::jsonb, 'none', 'none', true, true)
                ON CONFLICT (module, action, version) DO NOTHING");

            await connection.ExecuteAsync(
                "UPDATE course.action_catalog SET enabled = true WHERE module = 'regression' AND action = 'probe'");
        });

        Assert.Null(exception);
    }

    [Fact]
    public async Task CoursePublisher_CannotAccessOperations()
    {
        // publication-identity — изолирована от operations/idempotency_records
        // (см. 005_role_ownership_and_publication.sql: только USAGE на схему
        // course + SELECT/INSERT/UPDATE на action_catalog + EXECUTE на
        // publish_action, ничего больше).
        await using var connection = new NpgsqlConnection(_fixture.PublisherConnectionString);
        await connection.OpenAsync();

        var ex = await Assert.ThrowsAsync<PostgresException>(() =>
            connection.QueryAsync("SELECT * FROM course.operations LIMIT 1"));

        Assert.Equal("42501", ex.SqlState);
    }

    [Fact]
    public async Task CourseRuntime_HasExecuteOnApiInvoke()
    {
        // Позитивная сторона того же контракта: боевой трафик обязан иметь
        // возможность реально вызвать api.invoke — без этого сломался бы
        // вообще весь runtime, а не только права на прямой доступ к таблицам.
        await using var connection = new NpgsqlConnection(_fixture.RuntimeConnectionString);
        await connection.OpenAsync();

        var hasExecute = await connection.ExecuteScalarAsync<bool>(@"
            SELECT has_function_privilege('course_runtime', 'api.invoke(text,text,integer,jsonb,jsonb)', 'EXECUTE')");

        Assert.True(hasExecute);
    }

    [Fact]
    public async Task CourseOwner_CanAccessAnyFutureTableCreatedByPostgresInSchemas()
    {
        // Тот же класс проблемы, что вызвал 500 "Target function execution
        // failed" в week-1-public-report.json (opencheck.canary, заведённая
        // фикстурой автопроверки, была недоступна course_owner) — но без
        // завязки на конкретный файл фикстуры: в этом репозитории нет
        // committed "900_opencheck_probe.sql" с таблицей opencheck.canary
        // (autocheck/fixtures/migrations содержит только фикстуру недели 2,
        // с полностью другой схемой), и тест на конкретное имя таблицы был
        // бы тестом на файл, которого нет, а не на сам механизм.
        //
        // Проверяем то, что реально должно защищать: "cli"/"api" в проде
        // подключаются суперпользователем (POSTGRES_USER, см.
        // docker-compose.yml) — точно так же, как этот тест создаёт
        // таблицу здесь. 008_grant_gaps_from_public_report.sql (пункт 5)
        // регистрирует "ALTER DEFAULT PRIVILEGES FOR ROLE postgres ...
        // GRANT ALL PRIVILEGES ON TABLES" в этих трёх схемах — значит,
        // ЛЮБАЯ будущая таблица (любое имя, любая версия фикстуры) должна
        // быть сразу доступна course_owner, без ручного GRANT под каждую.
        var tableName = $"future_fixture_{Guid.NewGuid():N}";

        await using var superuserConnection = new NpgsqlConnection(_fixture.SuperuserConnectionString);
        await superuserConnection.OpenAsync();
        await superuserConnection.ExecuteAsync(
            $"CREATE TABLE opencheck.{tableName} (marker TEXT PRIMARY KEY)");

        await superuserConnection.ExecuteAsync("SET ROLE course_owner");

        var exception = await Record.ExceptionAsync(() => superuserConnection.ExecuteAsync(
            $"INSERT INTO opencheck.{tableName} (marker) VALUES (@marker)",
            new { marker = $"regression-{Guid.NewGuid()}" }));

        Assert.Null(exception);
    }
}
