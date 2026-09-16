using System.Text.Json;
using Xunit;

namespace Cli.Tests;

// Регрессионные тесты на пункт фидбэка "Manifest/OpenAPI contract неполон":
// "CLI не валидирует полный manifest, built-in schemas без dialect".
// До фикса ValidateManifestSchemas не существовало вообще — "cli action
// validate/publish" проверял только присутствие обязательных строковых
// полей манифеста, и синтаксически сломанная или без-dialect'ная
// request_schema/response_schema спокойно проходила и публиковалась.
public class ManifestSchemaValidatorTests
{
    private static ActionManifest ManifestWith(string? requestSchemaJson, string? responseSchemaJson = "{}")
    {
        return new ActionManifest
        {
            Module = "test",
            Action = "probe",
            Version = 1,
            TargetSchema = "test",
            TargetFunction = "probe",
            RequestSchema = requestSchemaJson == null ? null : JsonSerializer.Deserialize<JsonElement>(requestSchemaJson),
            ResponseSchema = responseSchemaJson == null ? null : JsonSerializer.Deserialize<JsonElement>(responseSchemaJson)
        };
    }

    [Fact]
    public void MissingSchemaFields_AreNotValidated()
    {
        // request_schema/response_schema отсутствуют в манифесте вообще —
        // ActionsController трактует это как "без валидации payload",
        // существующее поведение, которое эта проверка не должна ломать.
        var manifest = ManifestWith(requestSchemaJson: null, responseSchemaJson: null);

        var errors = ManifestSchemaValidator.ValidateManifestSchemas(manifest);

        Assert.Empty(errors);
    }

    [Fact]
    public void EmptyObjectSchema_DoesNotRequireDialect()
    {
        // "{}" ("разрешено всё") — валидная и частая JSON Schema; для неё
        // отдельный $schema не требуем, поскольку проверять нечего.
        var manifest = ManifestWith(requestSchemaJson: "{}", responseSchemaJson: "{}");

        var errors = ManifestSchemaValidator.ValidateManifestSchemas(manifest);

        Assert.Empty(errors);
    }

    [Fact]
    public void ValidDraft202012Schema_ProducesNoErrors()
    {
        const string schema = """
            {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "properties": {
                    "operationId": { "type": "string", "format": "uuid" }
                },
                "required": ["operationId"],
                "additionalProperties": false
            }
            """;
        var manifest = ManifestWith(requestSchemaJson: schema);

        var errors = ManifestSchemaValidator.ValidateManifestSchemas(manifest);

        Assert.Empty(errors);
    }

    [Fact]
    public void NonEmptySchema_WithoutDialect_IsRejected()
    {
        // Ровно тот случай, который был у встроенных payment.request/
        // operation.get манифестов до миграции 007: непустая схема без
        // объявленного "$schema".
        const string schemaWithoutDialect = """
            {
                "type": "object",
                "properties": {
                    "operationId": { "type": "string" }
                }
            }
            """;
        var manifest = ManifestWith(requestSchemaJson: schemaWithoutDialect);

        var errors = ManifestSchemaValidator.ValidateManifestSchemas(manifest);

        Assert.Contains(errors, e => e.Contains("request_schema.$schema must declare"));
    }

    [Fact]
    public void WrongDialect_IsRejected()
    {
        const string draft07Schema = """
            {
                "$schema": "http://json-schema.org/draft-07/schema#",
                "type": "object"
            }
            """;
        var manifest = ManifestWith(requestSchemaJson: draft07Schema);

        var errors = ManifestSchemaValidator.ValidateManifestSchemas(manifest);

        Assert.Contains(errors, e => e.Contains("request_schema.$schema must declare"));
    }

    [Fact]
    public void MalformedSchemaDocument_IsRejected()
    {
        // "type" со значением не строка/массив строк — синтаксически валидный
        // JSON, но НЕ валидная JSON Schema Draft 2020-12. Раньше CLI такое
        // пропускал (проверялось только наличие нужных ключей манифеста, а
        // не то, что сама схема соответствует драфту) — ломалось бы уже на
        // рантайме, при первом реальном запросе к ActionsController.
        //
        // JsonSchema.Net бросает исключение уже при разборе такого "type" —
        // до того, как дело доходит до Draft202012MetaSchema.Evaluate — и
        // ValidateSchemaDocument ловит это как "not parseable", а не как
        // "does not conform". Обе ветки — валидный, ожидаемый отказ; тест
        // проверяет сам факт отказа, а не то, через какую именно из двух
        // веток он произошёл (это деталь реализации JsonSchema.Net, а не
        // часть контракта, который стоит закреплять тестом).
        const string malformedSchema = """
            {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": 123
            }
            """;
        var manifest = ManifestWith(requestSchemaJson: malformedSchema);

        var errors = ManifestSchemaValidator.ValidateManifestSchemas(manifest);

        Assert.Contains(errors, e =>
            e.StartsWith("request_schema")
            && (e.Contains("does not conform to JSON Schema Draft 2020-12") || e.Contains("is not parseable as a JSON Schema")));
    }

    [Fact]
    public void BothRequestAndResponseSchema_AreValidatedIndependently()
    {
        const string withoutDialect = """{ "type": "object" }""";
        var manifest = ManifestWith(requestSchemaJson: withoutDialect, responseSchemaJson: withoutDialect);

        var errors = ManifestSchemaValidator.ValidateManifestSchemas(manifest);

        Assert.Contains(errors, e => e.StartsWith("request_schema"));
        Assert.Contains(errors, e => e.StartsWith("response_schema"));
        Assert.Equal(2, errors.Count);
    }

    [Fact]
    public void UnparseableSchema_ReportsErrorInsteadOfThrowing()
    {
        // Валидный JSON, но не объект/булево значение — JsonSchema.Net не
        // сможет интерпретировать это как схему. Должно вернуться как
        // ошибка валидации, а не бросить необработанное исключение наружу
        // из "cli action validate/publish".
        var manifest = ManifestWith(requestSchemaJson: "\"not-a-schema\"");

        var exception = Record.Exception(() => ManifestSchemaValidator.ValidateManifestSchemas(manifest));

        Assert.Null(exception);
    }
}
