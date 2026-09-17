using Dapper;
using Npgsql;
using Xunit;

namespace Api.Tests;

// Регрессионные тесты на пункт фидбэка "Средний приоритет: DB invariants и
// append-only history не защищены" (миграция
// 006_db_invariants_and_append_only.sql). Выполняются под course_owner
// через "SET ROLE" из course_migrator — то есть проверяют, что инварианты
// держатся даже для владельца схемы, а не только для ограниченного
// course_runtime (для которого это было бы тривиально из-за отсутствия
// прав, а не из-за самого constraint'а/триггера).
[Collection("Postgres")]
public class DbInvariantsRegressionTests : IAsyncLifetime
{
    private readonly PostgresFixture _fixture;
    private NpgsqlConnection _connection = null!;

    public DbInvariantsRegressionTests(PostgresFixture fixture)
    {
        _fixture = fixture;
    }

    public async Task InitializeAsync()
    {
        _connection = new NpgsqlConnection(_fixture.MigratorConnectionString);
        await _connection.OpenAsync();
        await _connection.ExecuteAsync("SET ROLE course_owner");
    }

    public async Task DisposeAsync()
    {
        await _connection.DisposeAsync();
    }

    private const string InsertOperationSql = @"
        INSERT INTO course.operations (request_id, principal, payload_hash, operation_kind, amount, currency, status)
        VALUES (@requestId, @principal, @payloadHash, @operationKind, @amount, @currency, 'CREATED')
        RETURNING operation_id";

    [Theory]
    [InlineData("PAYMENT_EXECUTION")]
    [InlineData("PAYMENT_APPROVAL")]
    public async Task Operations_AllowsKnownOperationKinds(string operationKind)
    {
        var operationId = await _connection.ExecuteScalarAsync<Guid?>(InsertOperationSql, NewOperationParams(operationKind: operationKind));

        Assert.NotNull(operationId);
    }

    [Fact]
    public async Task Operations_RejectsUnknownOperationKind()
    {
        var ex = await Assert.ThrowsAsync<PostgresException>(() =>
            _connection.ExecuteScalarAsync<Guid?>(InsertOperationSql, NewOperationParams(operationKind: "SOMETHING_ELSE")));

        Assert.Equal("23514", ex.SqlState); // check_violation
        Assert.Contains("ck_operations_operation_kind", ex.ConstraintName);
    }

    [Fact]
    public async Task Operations_RejectsNonRubCurrency()
    {
        var ex = await Assert.ThrowsAsync<PostgresException>(() =>
            _connection.ExecuteScalarAsync<Guid?>(InsertOperationSql, NewOperationParams(currency: "USD")));

        Assert.Equal("23514", ex.SqlState);
        Assert.Contains("ck_operations_currency", ex.ConstraintName);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-5.00")]
    public async Task Operations_RejectsNonPositiveAmount(string amount)
    {
        var ex = await Assert.ThrowsAsync<PostgresException>(() =>
            _connection.ExecuteScalarAsync<Guid?>(InsertOperationSql, NewOperationParams(amount: decimal.Parse(amount, System.Globalization.CultureInfo.InvariantCulture))));

        Assert.Equal("23514", ex.SqlState);
        Assert.Contains("ck_operations_amount_positive", ex.ConstraintName);
    }

    [Fact]
    public async Task OperationEvents_UpdateIsRejected_EvenForOwner()
    {
        var operationId = await _connection.ExecuteScalarAsync<Guid>(InsertOperationSql, NewOperationParams());
        var eventId = await _connection.ExecuteScalarAsync<Guid>(@"
            INSERT INTO course.operation_events (operation_id, event_type, payload_hash)
            VALUES (@operationId, 'CREATED', 'hash')
            RETURNING event_id", new { operationId });

        // Обычный REVOKE тут бы не сработал: владелец объекта всегда неявно
        // обладает всеми правами на него независимо от выданных/отозванных
        // грантов. Блокирует только BEFORE-триггер course.reject_mutation().
        var ex = await Assert.ThrowsAsync<PostgresException>(() =>
            _connection.ExecuteAsync("UPDATE course.operation_events SET event_type = 'TAMPERED' WHERE event_id = @eventId", new { eventId }));

        Assert.Contains("append-only", ex.MessageText, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ActionDispatches_DeleteIsRejected_EvenForOwner()
    {
        var correlationId = Guid.NewGuid();
        await _connection.ExecuteAsync(@"
            INSERT INTO course.action_dispatches (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome)
            VALUES (@correlationId, 'req-1', 'opencheck', 'probe', 1, 'regression-test', 'hash', 'OK', 'ok')",
            new { correlationId });

        var ex = await Assert.ThrowsAsync<PostgresException>(() =>
            _connection.ExecuteAsync("DELETE FROM course.action_dispatches WHERE correlation_id = @correlationId", new { correlationId }));

        Assert.Contains("append-only", ex.MessageText, StringComparison.OrdinalIgnoreCase);
    }

    private static object NewOperationParams(
        string operationKind = "PAYMENT_EXECUTION",
        decimal amount = 100.00m,
        string currency = "RUB")
    {
        return new
        {
            requestId = $"req-{Guid.NewGuid()}",
            principal = "regression-test",
            payloadHash = "hash",
            operationKind,
            amount,
            currency
        };
    }
}
