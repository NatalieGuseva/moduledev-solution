namespace Common.ActionExecution;

/// <summary>
/// Строка course.action_catalog, прочитанная через Dapper. Публичная версия того,
/// что раньше было приватным ActionManifestDb внутри ActionsController — вынесена
/// сюда, чтобы её мог использовать и Api (через ActionExecutor), и будущий
/// Workflow.Worker недели 2, без дублирования модели.
/// </summary>
public class ActionManifest
{
    public string Module { get; set; } = "";
    public string Action { get; set; } = "";
    public int Version { get; set; }
    public string HttpMethod { get; set; } = "POST";
    public string RequestSchema { get; set; } = "{}";
    public string ResponseSchema { get; set; } = "{}";
    public string OutcomesJson { get; set; } = "[]";
    public string RequiredPolicy { get; set; } = "[]";
    public string IdempotencyMode { get; set; } = "none";
    public int TimeoutMs { get; set; } = 30000;
}
