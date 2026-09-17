using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cli.Commands;

/// <summary>
/// DTO под contracts/course-1/workflow-map.schema.json. Поля названы
/// как в JSON (snake_case через JsonPropertyName), а не переименованы
/// под C#-конвенции — так проще сверять с самой схемой при чтении.
/// </summary>
public class FlowManifest
{
    [JsonPropertyName("contract_version")]
    public string ContractVersion { get; set; } = "";

    [JsonPropertyName("flow_name")]
    public string FlowName { get; set; } = "";

    [JsonPropertyName("version")]
    public int Version { get; set; }

    [JsonPropertyName("start_step")]
    public string StartStep { get; set; } = "";

    [JsonPropertyName("steps")]
    public List<FlowStep> Steps { get; set; } = new();

    [JsonPropertyName("transitions")]
    public List<FlowTransition> Transitions { get; set; } = new();
}

/// <summary>
/// Один шаг карты. Схема описывает четыре РАЗНЫХ формы через oneOf
/// (automaticStep/waitSignalStep/manualStep/endStep) — здесь это одна
/// плоская модель с полями от всех четырёх, лишние для конкретного
/// Type остаются null/default. Различаем по строке Type.
/// </summary>
public class FlowStep
{
    [JsonPropertyName("key")]
    public string Key { get; set; } = "";

    [JsonPropertyName("type")]
    public string Type { get; set; } = ""; // "automatic" | "wait_signal" | "manual" | "end"

    // automatic
    [JsonPropertyName("task")]
    public FlowTask? Task { get; set; }

    // wait_signal
    [JsonPropertyName("signal_type")]
    public string? SignalType { get; set; }

    // wait_signal и end используют одно и то же поле "outcome" в схеме
    // (в разных oneOf-ветках, но с одним и тем же именем)
    [JsonPropertyName("outcome")]
    public string? Outcome { get; set; }

    // manual
    [JsonPropertyName("allowed_outcomes")]
    public List<string>? AllowedOutcomes { get; set; }
}

public class FlowTask
{
    [JsonPropertyName("service")]
    public string Service { get; set; } = "";

    [JsonPropertyName("module")]
    public string Module { get; set; } = "";

    [JsonPropertyName("action")]
    public string Action { get; set; } = "";

    [JsonPropertyName("action_version")]
    public int ActionVersion { get; set; }

    [JsonPropertyName("required_policy")]
    public List<string> RequiredPolicy { get; set; } = new();

    [JsonPropertyName("timeout_ms")]
    public int TimeoutMs { get; set; }

    [JsonPropertyName("retry")]
    public FlowRetry Retry { get; set; } = new();

    [JsonPropertyName("input_mapping")]
    public Dictionary<string, string> InputMapping { get; set; } = new();

    [JsonPropertyName("input_constants")]
    public JsonElement InputConstants { get; set; }
}

public class FlowRetry
{
    [JsonPropertyName("max_attempts")]
    public int MaxAttempts { get; set; }

    [JsonPropertyName("delays_ms")]
    public List<int> DelaysMs { get; set; } = new();
}

public class FlowTransition
{
    [JsonPropertyName("from")]
    public string From { get; set; } = "";

    [JsonPropertyName("outcome")]
    public string Outcome { get; set; } = "";

    [JsonPropertyName("to")]
    public string To { get; set; } = "";
}
