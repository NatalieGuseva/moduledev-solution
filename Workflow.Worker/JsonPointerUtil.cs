using System.Text.Json.Nodes;

namespace Workflow.Worker;

/// <summary>
/// Минимальный JSON Pointer (RFC 6901) для чтения из process_data и записи
/// в собираемый payload по input_mapping. Разэкранирует ~0/~1 в сегментах.
/// Не претендует на 100% соответствие RFC 6901 в экзотических случаях
/// (см. оговорку в FlowValidator про то же самое упрощение при валидации
/// непересечения target-указателей) — покрывает объекты и массивы, чего
/// достаточно для карт course-1.
/// </summary>
public static class JsonPointerUtil
{
    public static bool TryGet(JsonNode? root, string pointer, out JsonNode? value)
    {
        value = root;
        var segments = SplitSegments(pointer);

        foreach (var segment in segments)
        {
            switch (value)
            {
                case JsonObject obj:
                    if (!obj.TryGetPropertyValue(segment, out value)) { value = null; return false; }
                    break;
                case JsonArray arr:
                    if (!int.TryParse(segment, out var index) || index < 0 || index >= arr.Count) { value = null; return false; }
                    value = arr[index];
                    break;
                default:
                    value = null;
                    return false;
            }
        }

        return true;
    }

    /// <summary>Устанавливает значение по указателю внутри root, создавая
    /// промежуточные объекты по мере необходимости. value клонируется —
    /// System.Text.Json.Nodes.JsonNode может принадлежать только одному
    /// родителю одновременно, а source-значение уже принадлежит process_data.</summary>
    public static void Set(JsonObject root, string pointer, JsonNode? value)
    {
        var segments = SplitSegments(pointer);
        if (segments.Length == 0) throw new ArgumentException("pointer must not be empty/root", nameof(pointer));

        var current = root;
        for (int i = 0; i < segments.Length - 1; i++)
        {
            if (current[segments[i]] is not JsonObject next)
            {
                next = new JsonObject();
                current[segments[i]] = next;
            }
            current = next;
        }

        current[segments[^1]] = value?.DeepClone();
    }

    private static string[] SplitSegments(string pointer) =>
        pointer.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Replace("~1", "/").Replace("~0", "~"))
            .ToArray();
}
