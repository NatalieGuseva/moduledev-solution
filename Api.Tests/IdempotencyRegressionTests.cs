using Dapper;
using Npgsql;
using Xunit;

namespace Api.Tests;

// Регрессионные тесты на два пункта фидбэка:
// - "Критический приоритет: Idempotency record создаётся после предметного
//    эффекта" — атомарный claim до выполнения target'а.
// - Найденный по week-1-public-report.json баг: course_runtime не имел
//    UPDATE на course.idempotency_records (только SELECT, INSERT), из-за
//    чего любой успешно выполненный запрос с Idempotency-Key падал 503
//    dependency.unavailable уже ПОСЛЕ успешного выполнения target-функции.
//
// SQL здесь — дословно то же самое, что ClaimIdempotencyAsync/
// CheckIdempotencyAsync/CompleteIdempotencyAsync в
// Api/Controllers/ActionsController.cs, выполненное от лица course_runtime
// напрямую (без HTTP/JWT-обвязки) — тестируем именно контракт с БД: то, что
// не увидит ни один unit-тест на C#-логику без реального Postgres с реальными
// grants этой роли.
[Collection("Postgres")]
public class IdempotencyRegressionTests
{
    private readonly PostgresFixture _fixture;

    public IdempotencyRegressionTests(PostgresFixture fixture)
    {
        _fixture = fixture;
    }

    private const string ClaimSql = @"
        INSERT INTO course.idempotency_records (idempotency_key, module, action, version, principal, payload_hash, result, status, created_at)
        VALUES (@key, @module, @action, @version, @principal, @hash, '{}'::jsonb, 'pending', NOW())
        ON CONFLICT (idempotency_key, module, action, version, principal) DO NOTHING
        RETURNING id";

    private const string CompleteSql = @"
        UPDATE course.idempotency_records
        SET result = @resultJson::jsonb, status = 'OK'
        WHERE idempotency_key = @key AND module = @module AND action = @action AND version = @version AND principal = @principal";

    private const string CheckSql = @"
        SELECT payload_hash as PayloadHash, result as ResultJson, status as Status
        FROM course.idempotency_records
        WHERE idempotency_key = @key AND module = @module AND action = @action AND version = @version AND principal = @principal";

    [Fact]
    public async Task ConcurrentClaim_SameKey_OnlyOneWins()
    {
        // "Два конкурента могут оба не найти key, оба вызвать target и
        // только затем конкурировать при INSERT ON CONFLICT" — исходный
        // баг из фидбэка. После фикса claim атомарен: под одинаковым ключом
        // ровно один конкурент получает id, второй — null, ДО вызова
        // предметной функции, а не после.
        var key = $"concurrent-{Guid.NewGuid()}";

        var winners = await Task.WhenAll(
            ClaimAsync(key),
            ClaimAsync(key));

        Assert.Single(winners, claimed => claimed);
        Assert.Single(winners, claimed => !claimed);

        async Task<bool> ClaimAsync(string idempotencyKey)
        {
            await using var connection = new NpgsqlConnection(_fixture.RuntimeConnectionString);
            await connection.OpenAsync();
            await using var tx = await connection.BeginTransactionAsync();

            var claimedId = await connection.ExecuteScalarAsync<int?>(ClaimSql, new
            {
                key = idempotencyKey,
                module = "opencheck",
                action = "probe",
                version = 1,
                principal = "regression-test",
                hash = "hash-a"
            }, tx);

            await tx.CommitAsync();
            return claimedId.HasValue;
        }
    }

    [Fact]
    public async Task CourseRuntime_CanCompleteAClaimedRecord()
    {
        // Это ровно та проверка, которая поймала бы прод-баг ДО прогона
        // публичного автотеста: course_runtime должен иметь право не только
        // застолбить (INSERT), но и завершить (UPDATE) idempotency-запись
        // после успешного выполнения action.
        var key = $"complete-{Guid.NewGuid()}";
        var module = "opencheck";
        var action = "probe";
        var version = 1;
        var principal = "regression-test";

        await using var connection = new NpgsqlConnection(_fixture.RuntimeConnectionString);
        await connection.OpenAsync();

        var claimedId = await connection.ExecuteScalarAsync<int?>(ClaimSql, new
        {
            key,
            module,
            action,
            version,
            principal,
            hash = "hash-b"
        });
        Assert.NotNull(claimedId);

        var exception = await Record.ExceptionAsync(() => connection.ExecuteAsync(CompleteSql, new
        {
            key,
            module,
            action,
            version,
            principal,
            resultJson = "{\"status\":\"ok\"}"
        }));

        Assert.Null(exception);

        var record = await connection.QueryFirstOrDefaultAsync<IdempotencyRow>(CheckSql, new { key, module, action, version, principal });
        Assert.NotNull(record);
        Assert.Equal("OK", record!.Status);
    }

    [Fact]
    public async Task Replay_SameKeyAndHash_ReturnsCachedResult()
    {
        var key = $"replay-{Guid.NewGuid()}";
        var module = "payment";
        var action = "request";
        var version = 1;
        var principal = "regression-test";
        const string hash = "same-payload-hash";

        await using var connection = new NpgsqlConnection(_fixture.RuntimeConnectionString);
        await connection.OpenAsync();

        var claimedId = await connection.ExecuteScalarAsync<int?>(ClaimSql, new { key, module, action, version, principal, hash });
        Assert.NotNull(claimedId);
        await connection.ExecuteAsync(CompleteSql, new { key, module, action, version, principal, resultJson = "{\"operationId\":\"abc\"}" });

        // Повторный вызов с тем же ключом — ActionsController сначала делает
        // CheckIdempotencyAsync и, если payload_hash совпадает, возвращает
        // существующий result без повторного вызова target-функции.
        var existing = await connection.QueryFirstOrDefaultAsync<IdempotencyRow>(CheckSql, new { key, module, action, version, principal });

        Assert.NotNull(existing);
        Assert.Equal(hash, existing!.PayloadHash);
        Assert.Contains("abc", existing.ResultJson);
    }

    private class IdempotencyRow
    {
        public string PayloadHash { get; set; } = string.Empty;
        public string ResultJson { get; set; } = string.Empty;
        public string Status { get; set; } = string.Empty;
    }
}
