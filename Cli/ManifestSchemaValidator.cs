using System.Text.Json;
using Json.Schema;

namespace Cli;

// Раньше это были private static методы прямо внутри Program (см. историю
// файла) — вынесены в отдельный public static класс по двум причинам:
// 1) Cli.Tests может дергать ValidateManifestSchemas напрямую, без разбора
//    stdout дочернего процесса CLI — регрессионные тесты на "Manifest/OpenAPI
//    contract" пункт фидбэка иначе пришлось бы делать через сборку и запуск
//    целого исполняемого файла ради проверки чистой функции.
// 2) Program.cs и так был перегружен: валидация JSON Schema — самостоятельная
//    обязанность, не относящаяся к диспетчеризации CLI-команд.
public static class ManifestSchemaValidator
{
    // Каноническая Draft 2020-12 meta-schema, которой должны соответствовать
    // сами схемы манифеста (не путать с валидацией payload ПО схеме — здесь
    // проверяется, что request_schema/response_schema — валидный документ
    // JSON Schema, а не просто JSON со знакомыми ключами).
    private static readonly JsonSchema Draft202012MetaSchema = MetaSchemas.Draft202012;

    private static readonly string[] RequiredDialect = { "https://json-schema.org/draft/2020-12/schema" };

    public static List<string> ValidateManifestSchemas(ActionManifest manifest)
    {
        var errors = new List<string>();
        ValidateSchemaDocument("request_schema", manifest.RequestSchema, errors);
        ValidateSchemaDocument("response_schema", manifest.ResponseSchema, errors);
        return errors;
    }

    private static void ValidateSchemaDocument(string fieldName, JsonElement? schemaElement, List<string> errors)
    {
        if (schemaElement == null)
        {
            // Поле не указано в манифесте — ActionsController в этом случае
            // трактует его как "без валидации payload", это существующее и
            // осознанное поведение, а не то, что нужно ловить здесь.
            return;
        }

        var raw = schemaElement.Value;

        // "{}" ("разрешено всё") — валидная и частая JSON Schema, отдельного
        // dialect для неё не требуем: там просто нечего проверять на предмет
        // конкретных keyword'ов конкретного драфта.
        var isEmptyObject = raw.ValueKind == JsonValueKind.Object && !raw.EnumerateObject().Any();
        if (!isEmptyObject)
        {
            if (raw.ValueKind != JsonValueKind.Object
                || !raw.TryGetProperty("$schema", out var dialectProp)
                || dialectProp.ValueKind != JsonValueKind.String
                || !RequiredDialect.Contains(dialectProp.GetString()))
            {
                errors.Add($"{fieldName}.$schema must declare \"{RequiredDialect[0]}\"");
            }
        }

        JsonSchema schema;
        try
        {
            schema = JsonSchema.FromText(raw.GetRawText());
        }
        catch (Exception ex)
        {
            errors.Add($"{fieldName} is not parseable as a JSON Schema: {ex.Message}");
            return;
        }

        // Canonical validator: сама схема должна быть валидным документом
        // Draft 2020-12, а не произвольным JSON, который случайно совпал по
        // структуре с нужными ключами (например, "type" с неверным типом
        // значения, некорректный "enum", и т.п. — раньше ничего этого не
        // ловилось, пока схема не "выстреливала" на рантайме).
        using var schemaDoc = JsonDocument.Parse(raw.GetRawText());
        var metaEvaluation = Draft202012MetaSchema.Evaluate(schemaDoc.RootElement, new EvaluationOptions
        {
            OutputFormat = OutputFormat.List
        });

        if (!metaEvaluation.IsValid)
        {
            var detail = CollectSchemaErrors(metaEvaluation);
            var message = detail.Count > 0 ? string.Join("; ", detail) : "invalid schema document";
            errors.Add($"{fieldName} does not conform to JSON Schema Draft 2020-12: {message}");
        }
    }

    private static List<string> CollectSchemaErrors(EvaluationResults evaluation)
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
}
