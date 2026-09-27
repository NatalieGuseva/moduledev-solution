using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace Api.Controllers;

[ApiController]
[Route("health")]
public class HealthController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;
    private readonly ILogger<HealthController> _logger;

    public HealthController(
        NpgsqlDataSource dataSource,
        ILogger<HealthController> logger)
    {
        _dataSource = dataSource;
        _logger = logger;
    }

    // Неделя 4, observability-контракт: liveness — процесс жив и
    // отвечает, БЕЗ обращения к PostgreSQL. Раньше отдавал
    // {"status":"alive"} — контракт требует ровно "live".
    [HttpGet("live")]
    public IActionResult Live()
    {
        return Ok(new { status = "live" });
    }

    // Готовность: единственная критическая зависимость api — PostgreSQL
    // (провайдер api не касается вообще). 503 body — {"status":"not_ready",
    // "code": "dependency.unavailable"} по контракту; "unhealthy" было
    // самодельным именем, не входящим ни в один зафиксированный контракт.
    [HttpGet("ready")]
    public async Task<IActionResult> Ready()
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));

            await using var connection = _dataSource.CreateConnection();
            await connection.OpenAsync(cts.Token);

            await using (var cmd = new NpgsqlCommand("SELECT 1", connection))
            {
                cmd.CommandTimeout = 5;
                var result = await cmd.ExecuteScalarAsync(cts.Token);
                if (result is not int and not long)
                {
                    return NotReady("dependency.unavailable", "Database check failed");
                }
            }

            await using (var cmd = new NpgsqlCommand(
                "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'course' AND table_name = 'action_catalog')",
                connection))
            {
                cmd.CommandTimeout = 5;
                var tableExists = (bool)(await cmd.ExecuteScalarAsync(cts.Token))!;
                if (!tableExists)
                {
                    _logger.LogDebug("Database is accessible but table 'action_catalog' does not exist");
                    return NotReady("dependency.unavailable", "Database not initialized");
                }
            }

            return Ok(new { status = "ready" });
        }
        catch (OperationCanceledException)
        {
            _logger.LogDebug("Readiness check timed out");
            return NotReady("dependency.unavailable", "Timeout");
        }
        catch (NpgsqlException ex)
        {
            _logger.LogDebug(ex, "PostgreSQL is unavailable");
            return NotReady("dependency.unavailable", "Database unavailable");
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Unexpected error during readiness check");
            return NotReady("internal.error", "Internal error");
        }
    }

    private ObjectResult NotReady(string code, string reason) =>
        StatusCode(StatusCodes.Status503ServiceUnavailable, new { status = "not_ready", code, reason });
}
