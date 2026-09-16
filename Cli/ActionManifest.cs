using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cli;

// Раньше был private-классом внутри Program — вынесен в public, чтобы
// Cli.Tests мог собирать ActionManifest напрямую для unit-тестов
// ManifestSchemaValidator, не проходя через файловую систему/аргументы CLI.
public class ActionManifest
{
    [JsonPropertyName("module")]
    public string Module { get; set; } = string.Empty;

    [JsonPropertyName("action")]
    public string Action { get; set; } = string.Empty;

    [JsonPropertyName("version")]
    public int Version { get; set; }

    [JsonPropertyName("http_method")]
    public string? HttpMethod { get; set; }

    [JsonPropertyName("target_schema")]
    public string TargetSchema { get; set; } = string.Empty;

    [JsonPropertyName("target_function")]
    public string TargetFunction { get; set; } = string.Empty;

    [JsonPropertyName("request_schema")]
    public JsonElement? RequestSchema { get; set; }

    [JsonPropertyName("response_schema")]
    public JsonElement? ResponseSchema { get; set; }

    [JsonPropertyName("outcomes")]
    public string[]? Outcomes { get; set; }

    [JsonPropertyName("required_policy")]
    public string[]? RequiredPolicy { get; set; }

    [JsonPropertyName("idempotency_mode")]
    public string? IdempotencyMode { get; set; }

    [JsonPropertyName("idempotency_scope")]
    public string? IdempotencyScope { get; set; }

    [JsonPropertyName("timeout_ms")]
    public int? TimeoutMs { get; set; }
}
