using Common.ActionExecution;
using Common.Contracts;
using Common.DTOs;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace Api.Controllers;

[ApiController]
[Route("api")]
public class ActionsController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;
    private readonly ActionExecutor _actionExecutor;
    private readonly ILogger<ActionsController> _logger;

    public ActionsController(NpgsqlDataSource dataSource, ActionExecutor actionExecutor, ILogger<ActionsController> logger)
    {
        _dataSource = dataSource;
        _actionExecutor = actionExecutor;
        _logger = logger;
    }

    [HttpPost("{module}/{actionName}")]
    public async Task<IActionResult> InvokeAction(string module, string actionName, CancellationToken cancellationToken)
    {
        var correlationId = HttpContext.Items["CorrelationId"] is Guid cid ? cid : Guid.NewGuid();
        var trustedContext = HttpContext.Items["TrustedContext"] as TrustedContext;
        var requestDto = HttpContext.Items["ValidatedRequest"] as RequestDTO;
        var rawPayload = HttpContext.Items["RawPayloadString"] as string ?? "{}";
        var requestedVersion = HttpContext.Items["ActionVersion"] as int?;
        var idempotencyKey = HttpContext.Items["IdempotencyKey"] as string;

        if (trustedContext == null || requestDto == null)
        {
            return StatusCode(StatusCodes.Status401Unauthorized, CreateErrorEnvelope("auth.invalid", "Authentication required", correlationId));
        }

        NpgsqlConnection connection;
        try
        {
            connection = await _dataSource.OpenConnectionAsync(cancellationToken);
        }
        catch (NpgsqlException ex)
        {
            _logger.LogDebug(ex, "PostgreSQL database unavailable");
            return StatusCode(StatusCodes.Status503ServiceUnavailable, CreateErrorEnvelope("dependency.unavailable", "PostgreSQL is unavailable", correlationId, requestedVersion));
        }

        await using (connection)
        {
            await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
            try
            {
                var result = await _actionExecutor.ExecuteAsync(
                    connection, transaction, module, actionName, requestedVersion,
                    trustedContext, rawPayload, idempotencyKey, cancellationToken);

                if (!result.IsSuccess)
                {
                    await transaction.RollbackAsync(cancellationToken);
                    var httpStatus = GetHttpStatusFromCode(result.ErrorCode!);
                    return StatusCode(httpStatus, CreateErrorEnvelope(result.ErrorCode!, result.ErrorMessage!, correlationId, result.EffectiveVersion));
                }

                await transaction.CommitAsync(cancellationToken);

                // ResponseJson уже содержит валидный конверт { status, outcome, result, meta } —
                // как для свежего вызова, так и для повтора по Idempotency-Key. Отдаём его как есть,
                // не пересобирая через Ok(object), чтобы не терять и не переформатировать байты ответа.
                return Content(result.ResponseJson!, "application/json");
            }
            catch (NpgsqlException ex)
            {
                await transaction.RollbackAsync(cancellationToken);
                _logger.LogDebug(ex, "PostgreSQL execution failed");
                return StatusCode(StatusCodes.Status503ServiceUnavailable, CreateErrorEnvelope("dependency.unavailable", "PostgreSQL database error during execution", correlationId, requestedVersion));
            }
            catch (Exception ex)
            {
                await transaction.RollbackAsync(cancellationToken);
                _logger.LogDebug(ex, "Unexpected error executing action");
                return StatusCode(StatusCodes.Status500InternalServerError, CreateErrorEnvelope("internal.error", "Internal execution error", correlationId, requestedVersion));
            }
        }
    }

    private static int GetHttpStatusFromCode(string code) => code switch
    {
        "access.denied" => StatusCodes.Status403Forbidden,
        "action.not_found" => StatusCodes.Status404NotFound,
        "idempotency.conflict" => StatusCodes.Status409Conflict,
        "idempotency.required" => StatusCodes.Status400BadRequest,
        "payload.invalid" => StatusCodes.Status422UnprocessableEntity,
        "action.timeout" => StatusCodes.Status504GatewayTimeout,
        "dependency.unavailable" => StatusCodes.Status503ServiceUnavailable,
        _ => StatusCodes.Status500InternalServerError
    };

    private static ErrorEnvelope CreateErrorEnvelope(string code, string message, Guid correlationId, int? version = null) => new()
    {
        Code = code,
        Message = message,
        Retryable = code == "dependency.unavailable" || code == "action.timeout",
        Meta = new Meta { CorrelationId = correlationId, ActionVersion = version }
    };
}
