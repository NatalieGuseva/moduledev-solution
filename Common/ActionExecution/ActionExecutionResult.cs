using System.Text.Json;

namespace Common.ActionExecution;

/// <summary>
/// Итог выполнения одного экшена через ActionExecutor. Намеренно не содержит ничего
/// HTTP-специфичного (StatusCodes, ErrorEnvelope) — маппинг в HTTP-ответ делает вызывающая
/// сторона (сейчас Api.Controllers.ActionsController, позже — Workflow.Worker).
///
/// ActionExecutor НЕ коммитит и НЕ откатывает переданную ему транзакцию ни при успехе,
/// ни при ошибке — это решение остаётся за вызывающим кодом.
/// </summary>
public sealed class ActionExecutionResult
{
    public bool IsSuccess { get; }

    /// <summary>Действие уже было выполнено ранее с тем же Idempotency-Key и тем же payload:
    /// executor не звал api.invoke повторно, а вернул сохранённый результат как есть.</summary>
    public bool IsIdempotentReplay { get; }

    /// <summary>Итоговый outcome экшена (только при успехе).</summary>
    public string? Outcome { get; }

    /// <summary>Поле result из ответа api.invoke, провалидированное по response schema
    /// (только при успехе).</summary>
    public JsonElement Result { get; }

    /// <summary>Версия манифеста, по которой реально исполнился экшен (default-версия,
    /// если версия не была указана явно).</summary>
    public int? EffectiveVersion { get; }

    /// <summary>Готовый к отдаче наружу JSON-конверт ответа: { status, outcome, result, meta }
    /// при успехе, либо ранее сохранённый в course.idempotency_records JSON при повторе.
    /// Позволяет вызывающей стороне не пересобирать конверт вручную.</summary>
    public string? ResponseJson { get; }

    /// <summary>Код ошибки (только при неуспехе), например "payload.invalid",
    /// "action.not_found", "action.contract_violation" — тот же словарь кодов, что и раньше.</summary>
    public string? ErrorCode { get; }

    /// <summary>Человекочитаемое сообщение об ошибке (только при неуспехе).</summary>
    public string? ErrorMessage { get; }

    /// <summary>Стоит ли повторять попытку (только при неуспехе). Для ошибок, которые
    /// ActionExecutor формирует сам (невалидная схема, не найден экшен, нарушение исходящего
    /// контракта и т.п.) — всегда false: это дефект вызова или карты, повтор не поможет.
    /// Для ошибок, пришедших из самого api.invoke — берётся поле "retryable" из его JSON
    /// (по умолчанию true, если поле не указано явно).</summary>
    public bool Retryable { get; }

    private ActionExecutionResult(
        bool isSuccess,
        bool isIdempotentReplay,
        string? outcome,
        JsonElement result,
        int? effectiveVersion,
        string? responseJson,
        string? errorCode,
        string? errorMessage,
        bool retryable)
    {
        IsSuccess = isSuccess;
        IsIdempotentReplay = isIdempotentReplay;
        Outcome = outcome;
        Result = result;
        EffectiveVersion = effectiveVersion;
        ResponseJson = responseJson;
        ErrorCode = errorCode;
        ErrorMessage = errorMessage;
        Retryable = retryable;
    }

    public static ActionExecutionResult Success(
        string outcome, JsonElement result, int effectiveVersion, string responseJson, bool isIdempotentReplay = false)
        => new(true, isIdempotentReplay, outcome, result, effectiveVersion, responseJson, null, null, retryable: false);

    public static ActionExecutionResult Failure(string errorCode, string errorMessage, int? effectiveVersion = null, bool retryable = false)
        => new(false, false, null, default, effectiveVersion, null, errorCode, errorMessage, retryable);
}
