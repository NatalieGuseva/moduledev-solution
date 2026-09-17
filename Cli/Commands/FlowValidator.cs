using Dapper;
using Npgsql;
using System.Text.Json;

namespace Cli.Commands;

/// <summary>
/// Семантическая валидация карты процесса перед публикацией (используется
/// и flow validate, и flow publish — второй вызывает первый перед записью).
///
/// Покрывает основные пункты из 04_assignment.md/"Semantic validation":
/// один start_step, уникальные ключи шагов, достижимость всех шагов,
/// хотя бы один достижимый end, отсутствие циклов и тупиковых
/// non-end путей, существование/enabled ссылаемого action, точное
/// равенство required_policy карты и action'а, ровно один transition
/// на каждый outcome (action/manual/wait_signal), отсутствие transitions
/// из end, базовая корректность JSON Pointer mapping и его непересечение,
/// длина delays_ms.
/// </summary>
public static class FlowValidator
{
    public static async Task<List<string>> ValidateAsync(FlowManifest manifest, NpgsqlConnection conn, NpgsqlTransaction? tx)
    {
        var errors = new List<string>();

        if (manifest.ContractVersion != "course-1")
            errors.Add($"contract_version must be 'course-1', got '{manifest.ContractVersion}'");

        if (string.IsNullOrEmpty(manifest.FlowName))
            errors.Add("flow_name is required");

        if (manifest.Version < 1)
            errors.Add("version must be >= 1");

        if (manifest.Steps.Count < 2)
            errors.Add("steps must contain at least 2 entries");

        // --- уникальность ключей шагов ---
        var stepsByKey = new Dictionary<string, FlowStep>();
        foreach (var step in manifest.Steps)
        {
            if (string.IsNullOrEmpty(step.Key))
            {
                errors.Add("a step is missing 'key'");
                continue;
            }
            if (!stepsByKey.TryAdd(step.Key, step))
                errors.Add($"duplicate step key '{step.Key}'");
        }

        // --- ровно один существующий start_step ---
        if (string.IsNullOrEmpty(manifest.StartStep))
        {
            errors.Add("start_step is required");
        }
        else if (!stepsByKey.ContainsKey(manifest.StartStep))
        {
            errors.Add($"start_step '{manifest.StartStep}' does not reference an existing step");
        }

        // --- transitions: ссылки на существующие шаги ---
        var outgoing = new Dictionary<string, List<FlowTransition>>();
        foreach (var t in manifest.Transitions)
        {
            if (!stepsByKey.ContainsKey(t.From))
                errors.Add($"transition from unknown step '{t.From}'");
            if (!stepsByKey.ContainsKey(t.To))
                errors.Add($"transition to unknown step '{t.To}' (from '{t.From}')");

            if (!outgoing.TryGetValue(t.From, out var list))
            {
                list = new List<FlowTransition>();
                outgoing[t.From] = list;
            }
            list.Add(t);
        }

        // --- запрет исходящих transitions из end-шагов ---
        foreach (var step in manifest.Steps.Where(s => s.Type == "end"))
        {
            if (outgoing.ContainsKey(step.Key))
                errors.Add($"end step '{step.Key}' must not have outgoing transitions");
        }

        // --- достижимость: BFS от start_step ---
        var reachable = new HashSet<string>();
        if (stepsByKey.ContainsKey(manifest.StartStep))
        {
            var queue = new Queue<string>();
            queue.Enqueue(manifest.StartStep);
            reachable.Add(manifest.StartStep);
            while (queue.Count > 0)
            {
                var current = queue.Dequeue();
                if (!outgoing.TryGetValue(current, out var edges)) continue;
                foreach (var edge in edges)
                {
                    if (stepsByKey.ContainsKey(edge.To) && reachable.Add(edge.To))
                        queue.Enqueue(edge.To);
                }
            }
        }

        foreach (var step in manifest.Steps)
        {
            if (!reachable.Contains(step.Key))
                errors.Add($"step '{step.Key}' is not reachable from start_step");
        }

        var reachableEnds = manifest.Steps.Where(s => s.Type == "end" && reachable.Contains(s.Key)).ToList();
        if (reachableEnds.Count == 0)
            errors.Add("no 'end' step is reachable from start_step");

        // --- отсутствие циклов (DFS с трёхцветной раскраской) ---
        var color = new Dictionary<string, int>(); // 0=white, 1=gray, 2=black
        bool hasCycle = false;
        void Dfs(string key)
        {
            if (hasCycle || !stepsByKey.ContainsKey(key)) return;
            color[key] = 1;
            if (outgoing.TryGetValue(key, out var edges))
            {
                foreach (var edge in edges)
                {
                    if (!stepsByKey.ContainsKey(edge.To)) continue;
                    var c = color.GetValueOrDefault(edge.To, 0);
                    if (c == 1) { hasCycle = true; return; }
                    if (c == 0) Dfs(edge.To);
                }
            }
            color[key] = 2;
        }
        foreach (var step in manifest.Steps)
        {
            if (color.GetValueOrDefault(step.Key, 0) == 0) Dfs(step.Key);
        }
        if (hasCycle)
            errors.Add("transition graph contains a cycle");

        // --- тупиковые non-end пути (шаг без исходящих transitions) ---
        foreach (var step in manifest.Steps.Where(s => s.Type != "end"))
        {
            if (!outgoing.ContainsKey(step.Key) || outgoing[step.Key].Count == 0)
                errors.Add($"non-end step '{step.Key}' has no outgoing transitions (dead end)");
        }

        // --- per-step проверки по типу ---
        foreach (var step in manifest.Steps)
        {
            var stepOutcomes = outgoing.TryGetValue(step.Key, out var edges)
                ? edges.Select(e => e.Outcome).ToList()
                : new List<string>();

            switch (step.Type)
            {
                case "automatic":
                    await ValidateAutomaticStep(step, stepOutcomes, conn, tx, errors);
                    break;

                case "manual":
                    if (step.AllowedOutcomes == null || step.AllowedOutcomes.Count == 0)
                    {
                        errors.Add($"manual step '{step.Key}' must declare allowed_outcomes");
                        break;
                    }
                    CheckExactOutcomeCoverage(step.Key, step.AllowedOutcomes, stepOutcomes, errors);
                    break;

                case "wait_signal":
                    if (string.IsNullOrEmpty(step.SignalType))
                        errors.Add($"wait_signal step '{step.Key}' must declare signal_type");
                    if (string.IsNullOrEmpty(step.Outcome))
                        errors.Add($"wait_signal step '{step.Key}' must declare outcome");
                    else
                        CheckExactOutcomeCoverage(step.Key, new List<string> { step.Outcome }, stepOutcomes, errors);
                    break;

                case "end":
                    if (string.IsNullOrEmpty(step.Outcome))
                        errors.Add($"end step '{step.Key}' must declare outcome");
                    break;

                default:
                    errors.Add($"step '{step.Key}' has unknown type '{step.Type}'");
                    break;
            }
        }

        return errors;
    }

    private static void CheckExactOutcomeCoverage(string stepKey, List<string> declaredOutcomes, List<string> transitionOutcomes, List<string> errors)
    {
        var declaredSet = declaredOutcomes.ToHashSet();
        var transitionSet = transitionOutcomes.ToHashSet();

        if (transitionOutcomes.Count != transitionSet.Count)
            errors.Add($"step '{stepKey}' has duplicate transitions for the same outcome");

        foreach (var missing in declaredSet.Except(transitionSet))
            errors.Add($"step '{stepKey}' has no transition for declared outcome '{missing}'");

        foreach (var extra in transitionSet.Except(declaredSet))
            errors.Add($"step '{stepKey}' has a transition for undeclared outcome '{extra}'");
    }

    private static async Task ValidateAutomaticStep(
        FlowStep step, List<string> transitionOutcomes, NpgsqlConnection conn, NpgsqlTransaction? tx, List<string> errors)
    {
        if (step.Task == null)
        {
            errors.Add($"automatic step '{step.Key}' must declare task");
            return;
        }

        var task = step.Task;

        if (task.Service != "postgres")
        {
            errors.Add($"step '{step.Key}': task.service must be 'postgres' (the only supported action runtime), got '{task.Service}'");
        }

        if (task.Retry.DelaysMs.Count != task.Retry.MaxAttempts - 1)
        {
            errors.Add(
                $"step '{step.Key}': delays_ms must have exactly max_attempts-1 ({task.Retry.MaxAttempts - 1}) entries, got {task.Retry.DelaysMs.Count}");
        }

        var actionRow = await conn.QueryFirstOrDefaultAsync<(string OutcomesJson, string RequiredPolicyJson, bool Enabled)>(
            @"SELECT outcomes::text AS OutcomesJson, required_policy::text AS RequiredPolicyJson, enabled AS Enabled
              FROM course.action_catalog
              WHERE module = @module AND action = @action AND version = @version",
            new { module = task.Module, action = task.Action, version = task.ActionVersion },
            tx);

        if (actionRow.OutcomesJson == null)
        {
            errors.Add($"step '{step.Key}': referenced action {task.Module}.{task.Action}@{task.ActionVersion} does not exist");
            return;
        }

        if (!actionRow.Enabled)
        {
            errors.Add($"step '{step.Key}': referenced action {task.Module}.{task.Action}@{task.ActionVersion} is not enabled");
        }

        var actionOutcomes = JsonSerializer.Deserialize<List<string>>(actionRow.OutcomesJson) ?? new();
        var actionPolicy = JsonSerializer.Deserialize<List<string>>(actionRow.RequiredPolicyJson) ?? new();

        if (!actionPolicy.ToHashSet().SetEquals(task.RequiredPolicy.ToHashSet()))
        {
            errors.Add(
                $"step '{step.Key}': task.required_policy [{string.Join(",", task.RequiredPolicy)}] must exactly equal action's required_policy [{string.Join(",", actionPolicy)}]");
        }

        CheckExactOutcomeCoverage(step.Key, actionOutcomes, transitionOutcomes, errors);

        ValidateMapping(step.Key, task, errors);
    }

    private static void ValidateMapping(string stepKey, FlowTask task, List<string> errors)
    {
        var targetPointers = new List<string>(task.InputMapping.Keys);
        var constantPointers = new List<string>();

        // Собираем все пути из input_constants (рекурсивно)
        if (task.InputConstants.ValueKind == JsonValueKind.Object)
        {
            CollectConstantPointers(task.InputConstants, "", constantPointers);
        }

        // Проверка, что все target pointers начинаются с '/'
        foreach (var pointer in targetPointers)
        {
            if (!pointer.StartsWith('/'))
                errors.Add($"step '{stepKey}': input_mapping target pointer '{pointer}' must start with '/'");
        }

        // Проверка, что все source pointers начинаются с '/'
        foreach (var source in task.InputMapping.Values)
        {
            if (!source.StartsWith('/'))
                errors.Add($"step '{stepKey}': input_mapping source pointer '{source}' must start with '/'");
        }

        // Проверка на пересечение всех target pointers (mapping + constants)
        var allTargets = targetPointers.Concat(constantPointers).ToList();
        for (int i = 0; i < allTargets.Count; i++)
        {
            for (int j = i + 1; j < allTargets.Count; j++)
            {
                if (PointersOverlap(allTargets[i], allTargets[j]))
                    errors.Add($"step '{stepKey}': target pointers '{allTargets[i]}' and '{allTargets[j]}' overlap");
            }
        }
    }

    /// <summary>
    /// Рекурсивно собирает все JSON Pointer пути из объекта input_constants.
    /// </summary>
    private static void CollectConstantPointers(JsonElement element, string prefix, List<string> pointers)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var prop in element.EnumerateObject())
                {
                    var path = prefix + "/" + prop.Name;
                    pointers.Add(path);
                    CollectConstantPointers(prop.Value, path, pointers);
                }
                break;
            case JsonValueKind.Array:
                int index = 0;
                foreach (var item in element.EnumerateArray())
                {
                    var path = prefix + "/" + index;
                    pointers.Add(path);
                    CollectConstantPointers(item, path, pointers);
                    index++;
                }
                break;
            // Примитивы (string, number, boolean, null) — сам путь уже добавлен родителем
            default:
                break;
        }
    }

    /// <summary>
    /// Пересечением считается равенство или отношение предок/потомок по
    /// сегментам JSON Pointer: "/a" пересекается с "/a/b", но не с "/ab".
    /// Сравнение по сырым сегментам, без RFC 6901 unescaping ~0/~1.
    /// </summary>
    private static bool PointersOverlap(string a, string b)
    {
        var segA = a.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var segB = b.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var shorter = segA.Length <= segB.Length ? segA : segB;
        var longer = segA.Length <= segB.Length ? segB : segA;

        for (int i = 0; i < shorter.Length; i++)
        {
            if (shorter[i] != longer[i]) return false;
        }
        return true; // shorter is a prefix of longer (or they're equal)
    }
}