using System.Security.Cryptography;
using System.Text;
using Common.Contracts;

namespace Api.Middleware;

// ============================================================
// ProviderSignatureMiddleware — generic HMAC-подпись transport-слоя,
// НЕ специфичная для receipt.accept: 07-autocheck-outline.md прямо
// говорит "Для signed requests API также принимает X-Provider-Signature.
// Неверная signature возвращает 401 signature.invalid; отсутствие
// подписи у receipt.accept возвращает 403 receipt.signature_required.
// Остальные actions не обязаны быть подписаны." — то есть заголовок
// проверяется для ЛЮБОГО запроса, где он присутствует.
//
// FIX-1 (missing-signature-rejected): для receipt.accept отсутствие
// заголовка — это НЕ "пусть решает target-функция", а именно 403
// receipt.signature_required, который обязан быть отдан транспортом
// ДО api.invoke. Иначе запрос доходит до course.invoke, тот пишет
// log_dispatch с principal = NULL и падает на NOT NULL в
// course.action_dispatches → 500 вместо 403. Поэтому здесь для
// /api/receipt/accept без заголовка сразу возвращаем 403, а в
// target-функции payment.receipt_accept проверка signatureVerified
// остаётся как defense-in-depth.
//
// FIX-2 (adapter-exact-signed-body): после успешной проверки HMAC
// middleware считает SHA-256 hex от rawPayload — тех же exact bytes,
// над которыми считался HMAC, — и кладёт в TransportContext.RawBodyHash.
// Это значение прокидывается в p_context.transport.rawBodyHash и
// используется payment.receipt_accept для записи body_hash в
// delivery.inbox. Без этого Postgres считал бы SHA-256 от jsonb::text,
// где ключи отсортированы по длине (а не по алфавиту, как в canonical
// receipt bytes), и week-3 public checker (adapter-exact-signed-body)
// падал бы на сравнении receipt_body_hash / inbox_body_hash с
// expected_body_hash.
//
// Порядок в конвейере: строго ПОСЛЕ JsonSchemaValidationMiddleware —
// оно уже вычитало тело через EnableBuffering()+сброс Position, распарсило
// его и положило точную UTF-8 строку в context.Items["RawPayloadString"].
// Этот middleware её переиспользует, а не читает поток второй раз:
// подпись обязана считаться над ТЕМИ ЖЕ exact bytes, что и JSON-парсинг
// (07-autocheck-outline.md: "над точными HTTP body bytes"), а
// повторное чтение того же буфера даёт побайтово те же данные.
//
// Секрет — точные UTF-8 bytes PROVIDER_HMAC_SECRET, без trim/decode
// (04-week-3.md, "Ключом являются точные UTF-8 bytes... без trim,
// Base64 или hex decoding").
public class ProviderSignatureMiddleware
{
    private const string HeaderName = "X-Provider-Signature";
    private const string SupportedVersion = "v1";

    // FIX: путь, для которого отсутствие подписи — это 403, а не "пусть
    // решает target-функция". Сравнение по StartsWithSegments, чтобы не
    // ловить /api/receipt/accept-fake.
    private static readonly PathString ReceiptAcceptPath = new("/api/receipt/accept");

    private readonly RequestDelegate _next;
    private readonly ILogger<ProviderSignatureMiddleware> _logger;
    private readonly byte[] _secretBytes;

    public ProviderSignatureMiddleware(
        RequestDelegate next,
        ILogger<ProviderSignatureMiddleware> logger,
        IConfiguration configuration)
    {
        _next = next;
        _logger = logger;

        // Секрет должен существовать всегда (как COURSE_JWT_SIGNING_KEY у
        // JwtContextMiddleware) — его отсутствие означает неверно собранное
        // окружение, а не "подписи временно не проверяем": молчаливый
        // no-op здесь означал бы, что receipt.accept принимает любую,
        // в том числе поддельную, подпись.
        var secret = configuration["PROVIDER_HMAC_SECRET"]
            ?? configuration["Course:Provider:HmacSecret"]
            ?? throw new InvalidOperationException("PROVIDER_HMAC_SECRET is not configured");
        _secretBytes = Encoding.UTF8.GetBytes(secret);
    }

    public async Task InvokeAsync(HttpContext context)
    {
        // Уже отвечено выше по конвейеру (например, JsonSchemaValidationMiddleware
        // отвергла запрос) — нечего проверять и некуда писать ответ.
        if (context.Response.HasStarted)
        {
            await _next(context);
            return;
        }

        if (!context.Request.Headers.TryGetValue(HeaderName, out var headerValues))
        {
            // FIX-1: для receipt.accept отсутствие подписи — это 403
            // receipt.signature_required, отданный транспортом, а НЕ
            // "пусть target-функция сама решит". Иначе запрос доходит
            // до api.invoke, тот на error-пути вызывает log_dispatch с
            // principal = NULL и падает на NOT NULL в action_dispatches,
            // превращая ожидаемый 403 в 500.
            if (context.Request.Path.StartsWithSegments(ReceiptAcceptPath))
            {
                var rejectCorrelationId = context.Items["CorrelationId"] is Guid cid
                    ? cid
                    : Guid.NewGuid();
                _logger.LogWarning(
                    "Rejecting {Path}: missing X-Provider-Signature (receipt.accept requires signature)",
                    context.Request.Path);
                await CorrelationAndErrorMiddleware.WriteErrorAsync(
                    context,
                    StatusCodes.Status403Forbidden,
                    "receipt.signature_required",
                    "X-Provider-Signature is required for receipt.accept",
                    rejectCorrelationId);
                return;
            }

            // Для остальных actions отсутствие заголовка — не ошибка
            // (07-autocheck-outline.md: "Остальные actions не обязаны
            // быть подписаны"). transport.signatureVerified просто не
            // попадёт в context.
            await _next(context);
            return;
        }

        var correlationId = context.Items["CorrelationId"] is Guid cid2 ? cid2 : Guid.NewGuid();
        var headerValue = headerValues.FirstOrDefault() ?? string.Empty;

        // Формат зафиксирован дословно: "v1=<lowercase-hex-hmac-sha256>"
        // (07-autocheck-outline.md). Один '=' разделитель, версия ДО него.
        var separatorIndex = headerValue.IndexOf('=');
        if (separatorIndex <= 0 || separatorIndex == headerValue.Length - 1)
        {
            await RejectAsync(context, correlationId, "X-Provider-Signature has invalid format");
            return;
        }

        var signatureVersion = headerValue[..separatorIndex];
        var providedHex = headerValue[(separatorIndex + 1)..];

        if (signatureVersion != SupportedVersion)
        {
            await RejectAsync(context, correlationId, $"unsupported signature version '{signatureVersion}'");
            return;
        }

        // Строго lowercase hex ожидаемой длины (SHA-256 = 32 байта = 64 hex-символа).
        // Не нормализуем регистр/пробелы — контракт фиксирует ИМЕННО
        // lowercase-hex, отклонение чего-то ещё "форматно похожего" —
        // осознанное поведение fail-closed, а не либеральный парсинг.
        if (providedHex.Length != 64 || !IsLowercaseHex(providedHex))
        {
            await RejectAsync(context, correlationId, "signature is not a lowercase-hex SHA-256 digest");
            return;
        }

        byte[] providedBytes;
        try
        {
            providedBytes = Convert.FromHexString(providedHex);
        }
        catch (FormatException)
        {
            await RejectAsync(context, correlationId, "signature is not valid hex");
            return;
        }

        // RawPayloadString кладёт JsonSchemaValidationMiddleware ДО этого
        // middleware (см. порядок регистрации в Program.cs) — то же самое
        // тело, что уйдёт в p_payload. Если его почему-то нет (не /api/*
        // маршрут, GET и т.п.), проверять подпись не над чем — пропускаем,
        // а не 500: сам JsonSchemaValidationMiddleware уже принял решение
        // по этому запросу раньше нас.
        if (context.Items["RawPayloadString"] is not string rawPayload)
        {
            await _next(context);
            return;
        }

        // Точные UTF-8 bytes тела — те же, над которыми считается HMAC
        // (07-autocheck-outline.md: "над точными HTTP body bytes") и над
        // которыми ниже посчитается SHA-256 для delivery.inbox.body_hash.
        var rawPayloadBytes = Encoding.UTF8.GetBytes(rawPayload);

        var expectedBytes = HMACSHA256.HashData(_secretBytes, rawPayloadBytes);

        // Сравнение с фиксированным временем выполнения — HMAC-подпись
        // сравнивается побайтово, а не через string.Equals/StringComparison,
        // чтобы не давать атакующему канал по времени ответа.
        if (!CryptographicOperations.FixedTimeEquals(expectedBytes, providedBytes))
        {
            _logger.LogDebug("Provider signature mismatch");
            await RejectAsync(context, correlationId, "signature does not match request body");
            return;
        }

        // FIX-2: exact SHA-256 hex от rawPayload — тех же bytes, над
        // которыми только что проверен HMAC. Прокидывается в
        // p_context.transport.rawBodyHash, оттуда payment.receipt_accept
        // передаёт его в delivery.record_inbox как body_hash. Это
        // гарантирует, что body_hash в delivery.inbox совпадает с
        // canonical receipt bytes (compact sorted JSON, который
        // подписывает adapter и ожидает week-3 public checker:
        // adapter-exact-signed-body). Без этого Postgres считал бы
        // SHA-256(jsonb::text), где порядок ключей — по длине, а не
        // по алфавиту, и хэши расходились бы.
        //
        // ToHexString даёт UPPERCASE; PostgreSQL ENCODE(..., 'hex') и
        // Python hashlib.hexdigest() дают lowercase, поэтому явно
        // приводим к нижнему регистру — иначе сравнение с
        // expected_body_hash у чекера не сойдётся по регистру.
        var rawBodyHash = Convert.ToHexString(SHA256.HashData(rawPayloadBytes))
            .ToLowerInvariant();

        var trustedContext = context.Items["TrustedContext"] as TrustedContext;
        if (trustedContext != null)
        {
            context.Items["TrustedContext"] = trustedContext with
            {
                Transport = new TransportContext
                {
                    SignatureVerified = true,
                    SignatureVersion = SupportedVersion,
                    RawBodyHash = rawBodyHash
                }
            };
        }
        // trustedContext == null здесь означает "запрос неаутентифицирован
        // вообще" — JsonSchemaValidationMiddleware для /api/* маршрутов уже
        // вернула бы 401 auth.invalid раньше нас (см. её порядок в
        // Program.cs), так что этот путь недостижим для /api/*, но мы не
        // должны падать, если сюда всё же дойдёт запрос вне /api/*.

        await _next(context);
    }

    private static bool IsLowercaseHex(string value)
    {
        foreach (var ch in value)
        {
            var isLowerHexDigit = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
            if (!isLowerHexDigit)
            {
                return false;
            }
        }
        return true;
    }

    private Task RejectAsync(HttpContext context, Guid correlationId, string reason)
    {
        _logger.LogDebug("Rejecting request: {Reason}", reason);
        return CorrelationAndErrorMiddleware.WriteErrorAsync(
            context, StatusCodes.Status401Unauthorized, "signature.invalid", "X-Provider-Signature is invalid", correlationId);
    }
}