using System.Text.Json;
using System.Text.Json.Nodes;
using Common.ActionExecution;
using Common.Contracts;
using Dapper;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace Workflow.Worker;

/// <summary>
/// Обрабатывает один захваченный job: строит payload по input_mapping,
/// вызывает общий ActionExecutor (Common) с trusted context principal
/// "workflow-worker", завершает через finish_job/fail_job.
///
/// Коды, которые ActionExecutor формирует сам (не пришедшие из api.invoke) —
/// action.not_found, payload.invalid, action.contract_violation,
/// access.denied, idempotency.*, internal.error — считаются НЕ retryable
/// независимо от Result.Retryable: это дефект вызова/карты, а не
/// транзиентная проблема, повтор той же карты даст тот же результат.
/// </summary>
public class StepRunner
{
    private static readonly HashSet<string> NonRetryableRegardless = new()
    {
        "action.not_found", "payload.invalid", "action.contract_violation",
        "access.denied", "idempotency.required", "idempotency.conflict", "internal.error"
    };

    private readonly NpgsqlDataSource _dataSource;
    private readonly ActionExecutor _actionExecutor;
    private readonly WorkerConfig _config;
    private readonly ILogger<StepRunner> _logger;

    public StepRunner(NpgsqlDataSource dataSource, ActionExecutor actionExecutor, WorkerConfig config, ILogger<StepRunner> logger)
    {
        _dataSource = dataSource;
        _actionExecutor = actionExecutor;
        _config = config;
        _logger = logger;
    }

    public async Task RunAsync(ClaimedJob job, CancellationToken cancellationToken)
    {
        // Граница failpoint "after_job_claim": ПОСЛЕ commit лизинга и attempt
        // (claim_jobs уже закоммитил это сам), ДО вызова api.invoke.
        await MaybeHitFailpoint("after_job_claim", cancellationToken);

        JsonObject payload;
        try
        {
            payload = BuildPayload(job);
        }
        catch (MappingMissingException ex)
        {
            _logger.LogWarning("job {JobId}: mapping source missing at {Pointer} — non-retryable, action not called", job.JobId, ex.Pointer);
            await CallFailJob(job, "workflow.mapping_missing", retryable: false, cancellationToken);
            return;
        }

        var trustedContext = new TrustedContext
        {
            Principal = "workflow-worker",
            Consumer = "workflow-worker",
            Scopes = JsonSerializer.Deserialize<string[]>(job.RequiredPolicy) ?? Array.Empty<string>(),
            CorrelationId = Guid.NewGuid(),
            RequestId = job.ExecutionId.ToString(),
            Deadline = DateTimeOffset.UtcNow.AddMilliseconds(job.TimeoutMs ?? 30000), // окончательно пересчитывается ActionExecutor'ом из timeoutMsOverride ниже
            ProcessId = job.ProcessId,
            JobId = job.JobId,
            ExecutionId = job.ExecutionId,
            AttemptId = job.AttemptId
        };

        await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        // claim_jobs уже сделал JOIN до course.action_catalog и вернул всё
        // нужное манифесту одним вызовом — workflow_worker не имеет и не
        // должен иметь GRANT на прямое чтение этой таблицы (только 4 EXECUTE,
        // см. 007_workflow_functions.sql), поэтому передаём манифест сюда,
        // а не даём ActionExecutor'у самому его резолвить через SQL.
        var manifest = new ActionManifest
        {
            Module = job.ActionModule,
            Action = job.ActionName,
            Version = job.ActionVersion,
            RequestSchema = job.RequestSchema,
            ResponseSchema = job.ResponseSchema,
            OutcomesJson = job.Outcomes,
            RequiredPolicy = job.RequiredPolicy,
            TimeoutMs = job.TimeoutMs ?? 30000
        };

        ActionExecutionResult result;
        try
        {
            result = await _actionExecutor.ExecuteAsync(
                connection, transaction, job.ActionModule, job.ActionName, job.ActionVersion,
                trustedContext, payload.ToJsonString(), idempotencyKey: job.ExecutionId.ToString(), cancellationToken,
                timeoutMsOverride: job.TimeoutMs, preResolvedManifest: manifest, useIdempotencyStore: false);
        }
        catch (Exception ex)
        {
            // Инфраструктурный сбой (обрыв соединения, таймаут БД и т.п.) —
            // всегда трактуем как retryable: это не дефект карты/контракта.
            await transaction.RollbackAsync(cancellationToken);
            _logger.LogWarning(ex, "job {JobId}: action execution threw, treating as retryable infra failure", job.JobId);
            await CallFailJob(job, "dependency.unavailable", retryable: true, cancellationToken);
            return;
        }

        if (!result.IsSuccess)
        {
            await transaction.RollbackAsync(cancellationToken);
            var retryable = result.Retryable && !NonRetryableRegardless.Contains(result.ErrorCode!);
            _logger.LogInformation("job {JobId}: action failed with {Code} (retryable={Retryable})", job.JobId, result.ErrorCode, retryable);
            await CallFailJob(job, result.ErrorCode!, retryable, cancellationToken);
            return;
        }

        // Граница failpoint "after_action_before_finish": ПОСЛЕ эффекта действия
        // и валидации контракта ВНУТРИ транзакции, ДО finish_job и commit —
        // транзакция намеренно остаётся открытой, пока процесс не убьют извне.
        await MaybeHitFailpoint("after_action_before_finish", cancellationToken);

        var finishResultJson = await connection.ExecuteScalarAsync<string>(
            "SELECT workflow.finish_job(@jobId, @owner, @leaseVersion, @outcome, @result::jsonb)",
            new
            {
                jobId = job.JobId,
                owner = _config.InstanceId,
                leaseVersion = job.LeaseVersion,
                outcome = result.Outcome,
                result = JsonSerializer.Serialize(result.Result)
            },
            transaction);

        using var finishDoc = JsonDocument.Parse(finishResultJson ?? "{}");
        var finishStatus = finishDoc.RootElement.TryGetProperty("status", out var s) ? s.GetString() : "error";

        if (finishStatus != "ok")
        {
            // Гонка с reclaim (лизинг успел устареть между claim и finish) —
            // ничего страшного, просто откатываем и не подтверждаем job:
            // другой worker (или мы сами на следующем claim) обработает его заново.
            await transaction.RollbackAsync(cancellationToken);
            _logger.LogInformation("job {JobId}: finish_job rejected ({Reason}), letting it be reclaimed", job.JobId, finishResultJson);
            return;
        }

        await transaction.CommitAsync(cancellationToken);
        _logger.LogInformation("job {JobId}: completed with outcome {Outcome}", job.JobId, result.Outcome);
    }

    private async Task CallFailJob(ClaimedJob job, string errorCode, bool retryable, CancellationToken cancellationToken)
    {
        // По заданию — отдельная транзакция ПОСЛЕ отката транзакции с самим action.
        await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken);
        var resultJson = await connection.ExecuteScalarAsync<string>(
            "SELECT workflow.fail_job(@jobId, @owner, @leaseVersion, @errorCode, @retryable)",
            new { jobId = job.JobId, owner = _config.InstanceId, leaseVersion = job.LeaseVersion, errorCode, retryable });

        _logger.LogInformation("job {JobId}: fail_job -> {Result}", job.JobId, resultJson);
    }

    private JsonObject BuildPayload(ClaimedJob job)
    {
        var processData = JsonNode.Parse(job.ProcessData);
        var inputConstants = JsonNode.Parse(job.InputConstants) as JsonObject ?? new JsonObject();
        var inputMapping = JsonSerializer.Deserialize<Dictionary<string, string>>(job.InputMapping) ?? new();

        var payload = new JsonObject();
        foreach (var kvp in inputConstants)
            payload[kvp.Key] = kvp.Value?.DeepClone();

        foreach (var (targetPointer, sourcePointer) in inputMapping)
        {
            if (!JsonPointerUtil.TryGet(processData, sourcePointer, out var value))
                throw new MappingMissingException(sourcePointer);

            JsonPointerUtil.Set(payload, targetPointer, value);
        }

        return payload;
    }

    private async Task MaybeHitFailpoint(string name, CancellationToken cancellationToken)
    {
        if (!_config.TestProfile || _config.Failpoint != name) return;

        // Точный формат из 04_assignment.md — одна строка structured log,
        // без обёртки логгера, чтобы формат не зависел от его конфигурации.
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            @event = "failpoint.reached",
            name,
            instanceId = _config.InstanceId
        }));

        // "Затем worker блокируется до принудительной остановки" — не sleep
        // с таймаутом, а бессрочное ожидание внешнего kill/stop.
        await Task.Delay(Timeout.Infinite, cancellationToken);
    }

    private class MappingMissingException : Exception
    {
        public string Pointer { get; }
        public MappingMissingException(string pointer) : base($"mapping source missing: {pointer}") => Pointer = pointer;
    }
}