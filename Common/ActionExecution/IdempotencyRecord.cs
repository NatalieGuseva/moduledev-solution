namespace Common.ActionExecution;

/// <summary>
/// Строка course.idempotency_records, прочитанная через Dapper. Публичная версия
/// того, что раньше было приватным IdempotencyRecordDb внутри ActionsController.
/// </summary>
public class IdempotencyRecord
{
    public string PayloadHash { get; set; } = "";
    public string ResultJson { get; set; } = "";
}
