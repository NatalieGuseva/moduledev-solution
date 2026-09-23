using System;
using System.Text.Json.Serialization;

namespace Common.Contracts;

// ============================================================
// TransportContext — trusted markers, которые generic C# signature boundary
// (Api/Middleware/ProviderSignatureMiddleware) кладёт в TrustedContext после
// успешной проверки X-Provider-Signature.
//
// Target-функции (payment.receipt_accept) читают эти маркеры и решают,
// обязательна ли подпись для их action.
//
// Поля:
//   - transport.signatureVerified — подпись проверена (bool);
//   - transport.signatureVersion  — версия подписи, сейчас всегда "v1";
//   - transport.rawBodyHash       — exact SHA-256 hex от raw HTTP body bytes,
//                                   посчитанный ProviderSignatureMiddleware
//                                   над теми же bytes, что проверены HMAC.
//
// rawBodyHash НЕ является частью "trust markers" в смысле 04-week-3.md
// (там про secret и полную signature) — это производная величина от body,
// которую SQL использует, чтобы записать body_hash в delivery.inbox,
// совпадающий с canonical receipt bytes (compact sorted JSON).
//
// Зачем это нужно: Postgres JSONB сортирует ключи по длине, потом по
// алфавиту, а canonical receipt — по алфавиту (json.dumps sort_keys=True).
// Поэтому SHA-256(jsonb::text) != SHA-256(canonical receipt bytes), и
// week-3 public checker (adapter-exact-signed-body) падает на сравнении
// receipt_body_hash / inbox_body_hash с expected_body_hash. Прокидываем
// точный хэш из C# middleware в p_context, а оттуда — в delivery.inbox.
// ============================================================
public record TransportContext
{
    [JsonPropertyName("signatureVerified")]
    public bool SignatureVerified { get; init; }

    [JsonPropertyName("signatureVersion")]
    public string? SignatureVersion { get; init; }

    // FIX: exact SHA-256 hex от raw HTTP body bytes, посчитанный
    // ProviderSignatureMiddleware над RawPayloadString (теми же bytes,
    // над которыми считается HMAC). Прокидывается в p_context, чтобы
    // SQL мог записать body_hash в delivery.inbox, совпадающий с
    // canonical receipt bytes (compact sorted JSON, который ожидает
    // week-3 public checker: adapter-exact-signed-body).
    [JsonPropertyName("rawBodyHash")]
    public string? RawBodyHash { get; init; }
}

public record TrustedContext
{
    [JsonPropertyName("principal")]
    public string Principal { get; init; } = string.Empty;

    [JsonPropertyName("consumer")]
    public string Consumer { get; init; } = string.Empty;

    [JsonPropertyName("scopes")]
    public string[] Scopes { get; init; } = Array.Empty<string>();

    [JsonPropertyName("correlationId")]
    public Guid CorrelationId { get; init; }

    [JsonPropertyName("requestId")]
    public string? RequestId { get; init; }

    [JsonPropertyName("deadline")]
    public DateTimeOffset Deadline { get; init; }

    // Заполняются только Workflow.Worker при вызове action изнутри workflow —
    // для обычных HTTP-вызовов через Api остаются null и просто не попадают
    // в сериализованный JSON. Обязательны по 04_assignment.md: "Worker создаёт
    // trusted context principal workflow-worker, добавляет processId, jobId,
    // executionId, attemptId". executionId используется целевыми функциями
    // как ключ идемпотентности предметного эффекта (см. probe-fixture недели 2:
    // p_context ->> 'executionId' используется как PRIMARY KEY).
    [JsonPropertyName("processId")]
    public Guid? ProcessId { get; init; }

    [JsonPropertyName("jobId")]
    public Guid? JobId { get; init; }

    [JsonPropertyName("executionId")]
    public Guid? ExecutionId { get; init; }

    [JsonPropertyName("attemptId")]
    public Guid? AttemptId { get; init; }

    // Заполняется только ProviderSignatureMiddleware (Api) после успешной
    // проверки X-Provider-Signature. Для всех остальных вызовов (JWT-only,
    // Workflow.Worker) остаётся null и не попадает в сериализованный JSON.
    // Target-функции (receipt.accept) читают p_context -> 'transport' ->>
    // 'signatureVerified' / 'signatureVersion' / 'rawBodyHash'.
    [JsonPropertyName("transport")]
    public TransportContext? Transport { get; init; }
}

public record Meta
{
    [JsonPropertyName("correlationId")]
    public Guid CorrelationId { get; init; }

    [JsonPropertyName("actionVersion")]
    public int? ActionVersion { get; init; }
}

public record SuccessEnvelope<T>
{
    [JsonPropertyName("status")]
    public string Status { get; init; } = "ok";

    [JsonPropertyName("outcome")]
    public string Outcome { get; init; } = string.Empty;

    [JsonPropertyName("result")]
    public T Result { get; init; } = default!;

    [JsonPropertyName("meta")]
    public Meta Meta { get; init; } = null!;
}

public record ErrorEnvelope
{
    [JsonPropertyName("status")]
    public string Status { get; init; } = "error";

    [JsonPropertyName("code")]
    public string Code { get; init; } = string.Empty;

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;

    [JsonPropertyName("retryable")]
    public bool Retryable { get; init; }

    [JsonPropertyName("details")]
    public object? Details { get; init; }

    [JsonPropertyName("meta")]
    public Meta Meta { get; init; } = null!;
}