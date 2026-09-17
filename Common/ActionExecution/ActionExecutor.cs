using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Common.Contracts;
using Dapper;
using Json.Schema;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace Common.ActionExecution;

/// <summary>
/// Единая точка выполнения одного экшена через course.action_catalog / api.invoke.
/// Раньше вся эта логика жила внутри Api.Controllers.ActionsController.InvokeAction —
/// вынесена сюда, чтобы её мог использовать и HTTP-контроллер Api, и будущий
/// Workflow.Worker (неделя 2), не дублируя проверку схем, idempotency и policy.
///
/// ВАЖНО: ExecuteAsync работает внутри уже открытой вызывающей стороной транзакции
/// и НИКОГДА сам не вызывает transaction.CommitAsync()/RollbackAsync(). Решение —
/// коммитить или откатывать — остаётся за вызывающим кодом, потому что у Api и
/// у Workflow.Worker разные границы транзакции (Worker в неделе 2 должен успеть
/// вызвать ещё и workflow.finish_job внутри той же транзакции перед коммитом).
/// </summary>
public class ActionExecutor
{
    private readonly ILogger<ActionExecutor> _logger;

    public ActionExecutor(ILogger<ActionExecutor> logger)
    {
        _logger = logger;
    }

    public async Task<ActionExecutionResult> ExecuteAsync(
        NpgsqlConnection connection,
        NpgsqlTransaction transaction,
        string module,
        string actionName,
        int? requestedVersion,
        TrustedContext trustedContext,
        string rawPayloadJson,
        string? idempotencyKey,
        CancellationToken cancellationToken,
        int? timeoutMsOverride = null,
        ActionManifest? preResolvedManifest = null,
        bool useIdempotencyStore = true)
    {
        // Api/cli подключаются "широкой" учётной записью и могут читать
        // course.action_catalog напрямую. Workflow.Worker — нет: он живёт под
        // ограниченной ролью workflow_worker без единого табличного GRANT.
        // Поэтому workflow.claim_jobs заранее джойнит action_catalog и отдаёт
        // все нужные поля манифеста одним вызовом (см. комментарий в
        // 007_workflow_functions.sql) — вызывающая сторона передаёт их сюда
        // через preResolvedManifest вместо повторного (и для worker'а —
        // невозможного из-за прав) чтения таблицы.
        var manifest = preResolvedManifest ?? await ResolveManifestAsync(connection, transaction, module, actionName, requestedVersion);
        if (manifest == null)
        {
            return ActionExecutionResult.Failure(
                "action.not_found",
                $"Action {module}.{actionName} (version: {requestedVersion?.ToString() ?? "default"}) not found or disabled",
                requestedVersion);
        }

        var effectiveVersion = manifest.Version;

        // Валидация request schema до вызова api.invoke
        if (!string.IsNullOrEmpty(manifest.RequestSchema) && manifest.RequestSchema != "{}" && manifest.RequestSchema != "[]")
        {
            try
            {
                using var payloadDoc = JsonDocument.Parse(rawPayloadJson);
                var schema = JsonSchema.FromText(manifest.RequestSchema);
                var evaluation = schema.Evaluate(payloadDoc.RootElement, new EvaluationOptions
                {
                    OutputFormat = OutputFormat.List
                });

                if (!evaluation.IsValid)
                {
                    var errors = CollectValidationErrors(evaluation);
                    var errorMessage = errors.Count > 0 ? string.Join("; ", errors) : "Unknown validation error";
                    _logger.LogWarning("Request schema validation failed: {Errors}", errorMessage);

                    return ActionExecutionResult.Failure(
                        "payload.invalid", $"Request payload does not match schema: {errorMessage}", effectiveVersion);
                }
            }
            catch (JsonException ex)
            {
                _logger.LogDebug(ex, "Failed to parse request payload");
                return ActionExecutionResult.Failure("payload.invalid", "Request payload is not valid JSON", effectiveVersion);
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "Failed to validate request schema");
                return ActionExecutionResult.Failure("internal.error", "Failed to validate request schema", effectiveVersion);
            }
        }

        if (manifest.IdempotencyMode == "required" && string.IsNullOrEmpty(idempotencyKey))
        {
            return ActionExecutionResult.Failure(
                "idempotency.required", "Idempotency key is required for this action", effectiveVersion);
        }

        if (!string.IsNullOrEmpty(manifest.RequiredPolicy) && manifest.RequiredPolicy != "[]")
        {
            var allowedScopes = JsonSerializer.Deserialize<List<string>>(manifest.RequiredPolicy) ?? new List<string>();
            // Политика — это набор ВСЕХ обязательных scope, а не "любой из": должны
            // присутствовать все scope из required_policy, иначе HTTP-граница была бы
            // слабее повторной проверки внутри api.invoke (course.check_policy делает AND).
            if (allowedScopes.Any() && !allowedScopes.All(scope => trustedContext.Scopes.Contains(scope)))
            {
                return ActionExecutionResult.Failure("access.denied", "Access denied by action policy", effectiveVersion);
            }
        }

        // useIdempotencyStore=false (Workflow.Worker): course.idempotency_records
        // требует табличный GRANT, которого у ограниченной роли workflow_worker
        // нет и не должно быть (см. 007_workflow_functions.sql — только 4 EXECUTE).
        // Это не ослабляет гарантию "один предметный эффект": она обеспечивается
        // на уровне самой карты — RequestId эффективного context'а не меняется
        // между попытками ОДНОГО job'а (= job.ExecutionId), и целевые
        // action-функции (например course.payment_request) сами дедуплицируют
        // по этому requestId через свой собственный unique-constraint/replay —
        // так же, как для обычного HTTP-вызова с тем же Idempotency-Key.
        if (!string.IsNullOrEmpty(idempotencyKey) && useIdempotencyStore)
        {
            var existingRecord = await CheckIdempotencyAsync(
                connection, transaction, idempotencyKey, module, actionName, effectiveVersion, trustedContext.Principal);
            if (existingRecord != null)
            {
                if (existingRecord.PayloadHash != GetHash(rawPayloadJson))
                {
                    return ActionExecutionResult.Failure(
                        "idempotency.conflict", "Idempotency key reused with different payload", effectiveVersion);
                }

                using var cachedDoc = JsonDocument.Parse(existingRecord.ResultJson);
                var cachedOutcome = cachedDoc.RootElement.TryGetProperty("outcome", out var co) ? co.GetString() ?? "" : "";
                var cachedResult = cachedDoc.RootElement.TryGetProperty("result", out var cr) ? cr.Clone() : default;

                return ActionExecutionResult.Success(
                    cachedOutcome, cachedResult, effectiveVersion, existingRecord.ResultJson, isIdempotentReplay: true);
            }
        }

        // Дособираем TrustedContext значениями, которые ещё не были известны раньше в конвейере:
        // - RequestId берётся из Idempotency-Key (ADR 001), а не из payload;
        // - Deadline вычисляется из timeoutMsOverride, если вызывающая сторона его передала
        //   (например, Workflow.Worker — из task.timeout_ms конкретной карты), иначе из
        //   timeout_ms самого манифеста в action_catalog.
        var effectiveContext = trustedContext with
        {
            RequestId = idempotencyKey,
            Deadline = DateTimeOffset.UtcNow.AddMilliseconds(timeoutMsOverride ?? manifest.TimeoutMs)
        };

        var contextJson = JsonSerializer.Serialize(effectiveContext, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        var invokeResultJson = await InvokeApiFunctionAsync(connection, transaction, module, actionName, effectiveVersion, contextJson, rawPayloadJson);

        using var doc = JsonDocument.Parse(invokeResultJson);
        var root = doc.RootElement;
        var status = root.TryGetProperty("status", out var st) ? st.GetString() : "error";

        if (status != "ok")
        {
            var code = root.TryGetProperty("code", out var c) ? c.GetString() ?? "internal.error" : "internal.error";
            var message = root.TryGetProperty("message", out var m) ? m.GetString() ?? "Action failed" : "Action failed";
            var retryable = !root.TryGetProperty("retryable", out var r) || r.ValueKind != JsonValueKind.False;
            return ActionExecutionResult.Failure(code, message, effectiveVersion, retryable);
        }

        var outcome = root.TryGetProperty("outcome", out var oc) ? oc.GetString() ?? "" : "";

        if (!string.IsNullOrEmpty(manifest.OutcomesJson) && manifest.OutcomesJson != "[]")
        {
            var allowedOutcomes = JsonSerializer.Deserialize<List<string>>(manifest.OutcomesJson) ?? new List<string>();
            if (!allowedOutcomes.Contains(outcome))
            {
                return ActionExecutionResult.Failure(
                    "action.contract_violation", $"Outcome '{outcome}' is not declared in manifest", effectiveVersion);
            }
        }

        var resultElement = root.TryGetProperty("result", out var res) ? res : default;

        // Безопасное копирование result: исходный JsonDocument закроется вместе с invokeResultJson,
        // поэтому нужен независимый клон, а не ссылка на его элемент.
        JsonElement copiedResult;
        if (resultElement.ValueKind != JsonValueKind.Undefined && resultElement.ValueKind != JsonValueKind.Null)
        {
            try
            {
                using var tempDoc = JsonDocument.Parse(resultElement.GetRawText());
                copiedResult = tempDoc.RootElement.Clone();
            }
            catch
            {
                using var emptyDoc = JsonDocument.Parse("{}");
                copiedResult = emptyDoc.RootElement.Clone();
            }
        }
        else
        {
            using var emptyDoc = JsonDocument.Parse("{}");
            copiedResult = emptyDoc.RootElement.Clone();
        }

        if (!string.IsNullOrEmpty(manifest.ResponseSchema) && manifest.ResponseSchema != "{}" && manifest.ResponseSchema != "[]")
        {
            try
            {
                var schema = JsonSchema.FromText(manifest.ResponseSchema);
                var evaluation = schema.Evaluate(copiedResult, new EvaluationOptions
                {
                    OutputFormat = OutputFormat.List
                });

                if (!evaluation.IsValid)
                {
                    var errors = CollectValidationErrors(evaluation);
                    var errorMessage = errors.Count > 0 ? string.Join("; ", errors) : "Unknown validation error";
                    _logger.LogWarning("Response schema validation failed: {Errors}", errorMessage);

                    return ActionExecutionResult.Failure(
                        "action.contract_violation", $"Result does not match response schema: {errorMessage}", effectiveVersion);
                }
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "Failed to validate response schema");
                return ActionExecutionResult.Failure(
                    "action.contract_violation", "Failed to validate response schema", effectiveVersion);
            }
        }

        var finalSuccessResponse = new
        {
            status = "ok",
            outcome,
            result = copiedResult,
            meta = new
            {
                correlationId = trustedContext.CorrelationId,
                actionVersion = effectiveVersion
            }
        };
        var finalSuccessJson = JsonSerializer.Serialize(finalSuccessResponse);

        if (!string.IsNullOrEmpty(idempotencyKey) && useIdempotencyStore)
        {
            await SaveIdempotencyAsync(
                connection, transaction, idempotencyKey, module, actionName, effectiveVersion,
                trustedContext.Principal, GetHash(rawPayloadJson), finalSuccessJson);
        }

        return ActionExecutionResult.Success(outcome, copiedResult, effectiveVersion, finalSuccessJson);
    }

    private static List<string> CollectValidationErrors(EvaluationResults evaluation)
    {
        var errors = new List<string>();

        if (evaluation.Errors != null)
        {
            foreach (var error in evaluation.Errors)
            {
                errors.Add($"{error.Key}: {error.Value}");
            }
        }

        if (errors.Count == 0 && evaluation.Details != null)
        {
            foreach (var detail in evaluation.Details)
            {
                if (detail.Errors != null)
                {
                    foreach (var error in detail.Errors)
                    {
                        errors.Add($"{error.Key}: {error.Value}");
                    }
                }
            }
        }

        return errors;
    }

    private async Task<ActionManifest?> ResolveManifestAsync(NpgsqlConnection conn, NpgsqlTransaction tx, string module, string action, int? version)
    {
        string sql;
        if (version.HasValue)
        {
            sql = @"
                SELECT module, action, version, http_method as HttpMethod, request_schema::text as RequestSchema, 
                       response_schema::text as ResponseSchema, outcomes::text as OutcomesJson, 
                       required_policy::text as RequiredPolicy, idempotency_mode as IdempotencyMode,
                       timeout_ms as TimeoutMs
                FROM course.action_catalog
                WHERE module = @module AND action = @action AND version = @version AND enabled = true";
            return await conn.QueryFirstOrDefaultAsync<ActionManifest>(sql, new { module, action, version = version.Value }, tx);
        }

        sql = @"
            SELECT module, action, version, http_method as HttpMethod, request_schema::text as RequestSchema, 
                   response_schema::text as ResponseSchema, outcomes::text as OutcomesJson, 
                   required_policy::text as RequiredPolicy, idempotency_mode as IdempotencyMode,
                   timeout_ms as TimeoutMs
            FROM course.action_catalog
            WHERE module = @module AND action = @action AND is_default = true AND enabled = true";
        return await conn.QueryFirstOrDefaultAsync<ActionManifest>(sql, new { module, action }, tx);
    }

    private async Task<string> InvokeApiFunctionAsync(NpgsqlConnection conn, NpgsqlTransaction tx, string module, string action, int version, string contextJson, string payloadJson)
    {
        const string sql = "SELECT api.invoke(@module, @action, @version, @context::jsonb, @payload::jsonb)";
        var res = await conn.ExecuteScalarAsync<string>(sql, new { module, action, version, context = contextJson, payload = payloadJson }, tx);
        return res ?? "{}";
    }

    private async Task<IdempotencyRecord?> CheckIdempotencyAsync(NpgsqlConnection conn, NpgsqlTransaction tx, string key, string module, string action, int version, string principal)
    {
        const string sql = @"
            SELECT payload_hash as PayloadHash, result as ResultJson
            FROM course.idempotency_records
            WHERE idempotency_key = @key AND module = @module AND action = @action AND version = @version AND principal = @principal";
        return await conn.QueryFirstOrDefaultAsync<IdempotencyRecord>(sql, new { key, module, action, version, principal }, tx);
    }

    private async Task SaveIdempotencyAsync(NpgsqlConnection conn, NpgsqlTransaction tx, string key, string module, string action, int version, string principal, string hash, string resultJson)
    {
        const string sql = @"
            INSERT INTO course.idempotency_records (idempotency_key, module, action, version, principal, payload_hash, result, status, created_at)
            VALUES (@key, @module, @action, @version, @principal, @hash, @resultJson::jsonb, 'OK', NOW())
            ON CONFLICT (idempotency_key, module, action, version, principal) DO NOTHING";
        await conn.ExecuteAsync(sql, new { key, module, action, version, principal, hash, resultJson }, tx);
    }

    private static string GetHash(string text)
    {
        using var sha = SHA256.Create();
        var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(text));
        return Convert.ToBase64String(bytes);
    }
}