using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Dapper;
using Npgsql;
using YamlDotNet.Core;
using YamlDotNet.RepresentationModel;

namespace Cli.Commands;

/// <summary>
/// CLI-команды `flow validate/publish/list/activate/start/get/signal`
/// из 04_assignment.md ("Формат и публикация карты"). Подключается к БД
/// напрямую (как и остальные команды Cli), никакого HTTP.
/// </summary>
public static class FlowCommands
{
    public static async Task<int> Handle(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli flow <validate|publish|list|activate|start|get|signal> [args...]");
            return 1;
        }

        var subcommand = args[0];
        var subArgs = args.Skip(1).ToArray();

        return subcommand switch
        {
            "validate" => await HandleValidate(subArgs),
            "publish" => await HandlePublish(subArgs),
            "list" => await HandleList(subArgs),
            "activate" => await HandleActivate(subArgs),
            "start" => await HandleStart(subArgs),
            "get" => await HandleGet(subArgs),
            "signal" => await HandleSignal(subArgs),
            "test-finish" => await HandleTestFinish(subArgs),
            _ => throw new InvalidOperationException($"Unknown flow subcommand: {subcommand}")
        };
    }

    // ------------------------------------------------------------
    // flow validate <file>
    // ------------------------------------------------------------
    private static async Task<int> HandleValidate(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli flow validate <map.json>");
            return 1;
        }

        var (manifest, _, readError) = await ReadManifest(args[0]);
        if (readError != null) return WriteError("manifest.invalid", readError);

        await using var connection = await OpenConnection();
        var errors = await FlowValidator.ValidateAsync(manifest!, connection, tx: null);

        if (errors.Count > 0)
            return WriteError("manifest.invalid", string.Join("; ", errors));

        return WriteOk(new
        {
            resource = "flow",
            operation = "validated",
            flowName = manifest!.FlowName,
            flowVersion = manifest.Version
        });
    }

    // ------------------------------------------------------------
    // flow publish <file>
    // ------------------------------------------------------------
    private static async Task<int> HandlePublish(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli flow publish <map.json>");
            return 1;
        }

        var (manifest, rawJson, readError) = await ReadManifest(args[0]);
        if (readError != null) return WriteError("manifest.invalid", readError);

        if (string.IsNullOrWhiteSpace(rawJson))
        {
            return WriteError("manifest.invalid", "Map content is empty");
        }

        await using var connection = await OpenConnection();
        await using var transaction = await connection.BeginTransactionAsync();

        try
        {
            var errors = await FlowValidator.ValidateAsync(manifest!, connection, transaction);
            if (errors.Count > 0)
            {
                await transaction.RollbackAsync();
                return WriteError("manifest.invalid", string.Join("; ", errors));
            }

            await connection.ExecuteAsync(
                "INSERT INTO workflow.flow_definition (flow_name) VALUES (@flowName) ON CONFLICT DO NOTHING",
                new { flowName = manifest!.FlowName }, transaction);

            var existingSame = await connection.QueryFirstOrDefaultAsync<bool?>(
                @"SELECT (map_definition = @raw::jsonb) FROM workflow.flow_version
                  WHERE flow_name = @flowName AND flow_version = @flowVersion",
                new { flowName = manifest.FlowName, flowVersion = manifest.Version, raw = rawJson },
                transaction);

            if (existingSame.HasValue)
            {
                if (existingSame.Value)
                {
                    await transaction.CommitAsync();
                    return WriteOk(new
                    {
                        resource = "flow",
                        operation = "published",
                        flowName = manifest.FlowName,
                        flowVersion = manifest.Version
                    });
                }

                await transaction.RollbackAsync();
                return WriteError("manifest.conflict",
                    $"flow {manifest.FlowName} v{manifest.Version} was already published with different content");
            }

            await connection.ExecuteAsync(
                @"INSERT INTO workflow.flow_version (flow_name, flow_version, status, is_active, map_definition)
                  VALUES (@flowName, @flowVersion, 'PUBLISHED', false, @raw::jsonb)",
                new { flowName = manifest.FlowName, flowVersion = manifest.Version, raw = rawJson }, transaction);

            var taskIdByStepKey = new Dictionary<string, Guid>();

            foreach (var step in manifest.Steps.Where(s => s.Type == "automatic"))
            {
                var task = step.Task!;
                var taskId = await connection.QuerySingleAsync<Guid>(
                    @"INSERT INTO workflow.task_definition
                          (flow_name, flow_version, action_module, action_name, action_version,
                           input_mapping, input_constants, max_attempts, delays_ms, timeout_ms)
                      VALUES
                          (@flowName, @flowVersion, @module, @action, @actionVersion,
                           @inputMapping::jsonb, @inputConstants::jsonb, @maxAttempts, @delaysMs::jsonb, @timeoutMs)
                      RETURNING id",
                    new
                    {
                        flowName = manifest.FlowName,
                        flowVersion = manifest.Version,
                        module = task.Module,
                        action = task.Action,
                        actionVersion = task.ActionVersion,
                        inputMapping = JsonSerializer.Serialize(task.InputMapping),
                        inputConstants = task.InputConstants.GetRawText(),
                        maxAttempts = task.Retry.MaxAttempts,
                        delaysMs = JsonSerializer.Serialize(task.Retry.DelaysMs),
                        timeoutMs = task.TimeoutMs
                    },
                    transaction);

                taskIdByStepKey[step.Key] = taskId;
            }

            foreach (var step in manifest.Steps)
            {
                await connection.ExecuteAsync(
                    @"INSERT INTO workflow.step_definition
                          (flow_name, flow_version, step_key, step_type, is_start,
                           task_definition_id, wait_signal_type, declared_outcome)
                      VALUES
                          (@flowName, @flowVersion, @stepKey, @stepType, @isStart,
                           @taskDefinitionId, @waitSignalType, @declaredOutcome)",
                    new
                    {
                        flowName = manifest.FlowName,
                        flowVersion = manifest.Version,
                        stepKey = step.Key,
                        stepType = step.Type.ToUpperInvariant(),
                        isStart = step.Key == manifest.StartStep,
                        taskDefinitionId = taskIdByStepKey.TryGetValue(step.Key, out var tid) ? (Guid?)tid : null,
                        waitSignalType = step.Type == "wait_signal" ? step.SignalType : null,
                        declaredOutcome = step.Type is "wait_signal" or "end" ? step.Outcome : null
                    },
                    transaction);
            }

            foreach (var t in manifest.Transitions)
            {
                await connection.ExecuteAsync(
                    @"INSERT INTO workflow.transition_definition (flow_name, flow_version, step_key, outcome, next_step_key)
                      VALUES (@flowName, @flowVersion, @stepKey, @outcome, @nextStepKey)",
                    new
                    {
                        flowName = manifest.FlowName,
                        flowVersion = manifest.Version,
                        stepKey = t.From,
                        outcome = t.Outcome,
                        nextStepKey = t.To
                    },
                    transaction);
            }

            await transaction.CommitAsync();

            return WriteOk(new
            {
                resource = "flow",
                operation = "published",
                flowName = manifest.FlowName,
                flowVersion = manifest.Version
            });
        }
        catch
        {
            await transaction.RollbackAsync();
            throw;
        }
    }

    // ------------------------------------------------------------
    // flow list
    // ------------------------------------------------------------
    private static async Task<int> HandleList(string[] args)
    {
        await using var connection = await OpenConnection();

        var items = await connection.QueryAsync(
            @"SELECT flow_name AS FlowName, flow_version AS FlowVersion, status AS Status, is_active AS IsActive
              FROM workflow.flow_version
              ORDER BY flow_name, flow_version");

        return WriteOk(new { resource = "flow", operation = "listed", items });
    }

    // ------------------------------------------------------------
    // flow activate <flow> --version <version>
    // ------------------------------------------------------------
    private static async Task<int> HandleActivate(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli flow activate <flow-name> --version <version>");
            return 1;
        }

        var flowName = args[0];
        int? version = null;
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--version" && i + 1 < args.Length)
                version = int.Parse(args[i + 1]);
        }

        if (version == null)
        {
            Console.Error.WriteLine("--version is required");
            return 1;
        }

        await using var connection = await OpenConnection();
        await using var transaction = await connection.BeginTransactionAsync();

        try
        {
            await connection.ExecuteAsync(
                "UPDATE workflow.flow_version SET is_active = false WHERE flow_name = @flowName AND is_active = true",
                new { flowName }, transaction);

            var rows = await connection.ExecuteAsync(
                @"UPDATE workflow.flow_version SET is_active = true
                  WHERE flow_name = @flowName AND flow_version = @version AND status = 'PUBLISHED'",
                new { flowName, version }, transaction);

            if (rows == 0)
            {
                await transaction.RollbackAsync();
                return WriteError("flow.version_not_found", $"{flowName} v{version} is not a published version");
            }

            await transaction.CommitAsync();

            return WriteOk(new { resource = "flow", operation = "activated", flowName, flowVersion = version });
        }
        catch
        {
            await transaction.RollbackAsync();
            throw;
        }
    }

    // ------------------------------------------------------------
    // flow start <flow> --business-key <key> [--data <file>]
    // ------------------------------------------------------------
    private static async Task<int> HandleStart(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli flow start <flow-name> --business-key <key> [--data <file>]");
            return 1;
        }

        var flowName = args[0];
        string? businessKey = null;
        string? dataFile = null;
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--business-key" && i + 1 < args.Length) businessKey = args[++i];
            else if (args[i] == "--data" && i + 1 < args.Length) dataFile = args[++i];
        }

        if (string.IsNullOrEmpty(businessKey))
        {
            Console.Error.WriteLine("--business-key is required");
            return 1;
        }

        var dataJson = "{}";
        if (dataFile != null)
        {
            if (!File.Exists(dataFile))
            {
                Console.Error.WriteLine($"Data file not found: {dataFile}");
                return 1;
            }
            dataJson = await File.ReadAllTextAsync(dataFile);
        }

        await using var connection = await OpenConnection();

        var resultJson = await connection.ExecuteScalarAsync<string>(
            "SELECT workflow.start_process(@flowName, @businessKey, @data::jsonb)",
            new { flowName, businessKey, data = dataJson });

        return EmitFunctionResult(resultJson, ok => new
        {
            resource = "process",
            operation = "started",
            processId = ok.GetProperty("processId").GetString(),
            flowName = ok.GetProperty("flowName").GetString(),
            flowVersion = ok.GetProperty("flowVersion").GetInt32(),
            state = ok.GetProperty("state").GetString()
        });
    }

    // ------------------------------------------------------------
    // flow get <process-id> - ИСПРАВЛЕН
    // ------------------------------------------------------------
    private static async Task<int> HandleGet(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli flow get <process-id>");
            return 1;
        }

        if (!Guid.TryParse(args[0], out var processId))
            return WriteError("payload.invalid", "process-id must be a UUID");

        await using var connection = await OpenConnection();

        // ✅ Исправлено: используем анонимный тип без AS, чтобы Dapper правильно сопоставил
        var row = await connection.QueryFirstOrDefaultAsync(
            @"SELECT process_id, flow_name, flow_version, state, current_step_key
              FROM workflow.process_instance
              WHERE process_id = @processId",
            new { processId });

        if (row == null)
            return WriteError("process.not_found", $"process {processId} not found");

        return WriteOk(new
        {
            resource = "process",
            processId = row.process_id,
            flowName = row.flow_name,
            flowVersion = row.flow_version,
            state = row.state,
            currentStepKey = row.current_step_key
        });
    }

    // ------------------------------------------------------------
    // flow signal <process-id> --type <type> --message-id <id> --payload <file>
    // ------------------------------------------------------------
    private static async Task<int> HandleSignal(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli flow signal <process-id> --type <type> --message-id <id> --payload <file>");
            return 1;
        }

        if (!Guid.TryParse(args[0], out var processId))
            return WriteError("payload.invalid", "process-id must be a UUID");

        string? signalType = null, messageId = null, payloadFile = null;
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--type" && i + 1 < args.Length) signalType = args[++i];
            else if (args[i] == "--message-id" && i + 1 < args.Length) messageId = args[++i];
            else if (args[i] == "--payload" && i + 1 < args.Length) payloadFile = args[++i];
        }

        if (string.IsNullOrEmpty(signalType)) { Console.Error.WriteLine("--type is required"); return 1; }
        if (string.IsNullOrEmpty(messageId)) { Console.Error.WriteLine("--message-id is required"); return 1; }
        if (string.IsNullOrEmpty(payloadFile) || !File.Exists(payloadFile))
        {
            Console.Error.WriteLine("--payload <file> is required and must exist");
            return 1;
        }

        var body = await File.ReadAllTextAsync(payloadFile);

        await using var connection = await OpenConnection();

        var resultJson = await connection.ExecuteScalarAsync<string>(
            "SELECT workflow.receive_signal(@processId, @messageId, @signalType, @body::jsonb)",
            new { processId, messageId, signalType, body });

        return EmitFunctionResult(resultJson, ok => new
        {
            resource = "signal",
            processId = ok.GetProperty("processId").GetString(),
            messageId = ok.GetProperty("messageId").GetString(),
            signalType = ok.GetProperty("signalType").GetString(),
            status = ok.GetProperty("signalStatus").GetString()
        });
    }

    // ------------------------------------------------------------
    // flow test-finish <job-id> --owner <owner> --lease-version <v>
    //   --outcome <outcome> --result <file>
    // ------------------------------------------------------------
    private static async Task<int> HandleTestFinish(string[] args)
    {
        if (Environment.GetEnvironmentVariable("COURSE_TEST_PROFILE") != "1")
        {
            Console.Error.WriteLine("flow test-finish is only available when COURSE_TEST_PROFILE=1");
            return 1;
        }

        if (args.Length == 0)
        {
            Console.Error.WriteLine(
                "Usage: cli flow test-finish <job-id> --owner <owner> --lease-version <v> --outcome <outcome> --result <file>");
            return 1;
        }

        if (!Guid.TryParse(args[0], out var jobId))
            return WriteError("payload.invalid", "job-id must be a UUID");

        string? owner = null, outcome = null, resultFile = null;
        long? leaseVersion = null;
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--owner" && i + 1 < args.Length) owner = args[++i];
            else if (args[i] == "--lease-version" && i + 1 < args.Length) leaseVersion = long.Parse(args[++i]);
            else if (args[i] == "--outcome" && i + 1 < args.Length) outcome = args[++i];
            else if (args[i] == "--result" && i + 1 < args.Length) resultFile = args[++i];
        }

        if (owner == null) { Console.Error.WriteLine("--owner is required"); return 1; }
        if (leaseVersion == null) { Console.Error.WriteLine("--lease-version is required"); return 1; }
        if (outcome == null) { Console.Error.WriteLine("--outcome is required"); return 1; }
        if (resultFile == null || !File.Exists(resultFile)) { Console.Error.WriteLine("--result <file> is required and must exist"); return 1; }

        var resultBody = await File.ReadAllTextAsync(resultFile);

        await using var connection = await OpenConnection();

        var resultJson = await connection.ExecuteScalarAsync<string>(
            "SELECT workflow.finish_job(@jobId, @owner, @leaseVersion, @outcome, @result::jsonb)",
            new { jobId, owner, leaseVersion, outcome, result = resultBody });

        return EmitFunctionResult(resultJson, ok => new
        {
            resource = "job",
            operation = "finished",
            jobId = jobId.ToString(),
            processId = ok.GetProperty("processId").GetString(),
            nextStepKey = ok.TryGetProperty("nextStepKey", out var n) ? n.GetString() : null
        });
    }

    // ------------------------------------------------------------
    // Общие хелперы
    // ------------------------------------------------------------

    private static readonly JsonSerializerOptions StrictManifestOptions = new()
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private static async Task<(FlowManifest? Manifest, string? RawJson, string? Error)> ReadManifest(string path)
    {
        string rawContent;

        if (path == "/dev/stdin" || path == "-")
        {
            rawContent = await Console.In.ReadToEndAsync();
        }
        else
        {
            if (!File.Exists(path)) return (null, null, $"map file not found: {path}");
            rawContent = await File.ReadAllTextAsync(path);
        }

        if (string.IsNullOrWhiteSpace(rawContent))
        {
            return (null, null, "map content is empty");
        }

        try
        {
            var manifest = JsonSerializer.Deserialize<FlowManifest>(rawContent, StrictManifestOptions);
            if (manifest == null) return (null, null, "failed to parse map JSON");
            return (manifest, rawContent, null);
        }
        catch (JsonException)
        {
            string json;
            try
            {
                json = ConvertYamlToJson(rawContent);
            }
            catch (Exception yamlEx)
            {
                return (null, null, $"map is not valid JSON or YAML: {yamlEx.Message}");
            }

            try
            {
                var manifest = JsonSerializer.Deserialize<FlowManifest>(json, StrictManifestOptions);
                if (manifest == null) return (null, null, "failed to parse map YAML");
                return (manifest, json, null);
            }
            catch (JsonException jsonEx)
            {
                return (null, null, $"map YAML does not match schema, or contains unknown fields: {jsonEx.Message}");
            }
        }
    }

    private static string ConvertYamlToJson(string yamlContent)
    {
        var yamlStream = new YamlStream();
        yamlStream.Load(new StringReader(yamlContent));

        if (yamlStream.Documents.Count == 0)
            throw new InvalidOperationException("YAML document is empty");

        var node = ConvertYamlNode(yamlStream.Documents[0].RootNode);
        return node?.ToJsonString() ?? "null";
    }

    private static JsonNode? ConvertYamlNode(YamlNode node)
    {
        switch (node)
        {
            case YamlScalarNode scalar:
                return ConvertYamlScalar(scalar);

            case YamlSequenceNode sequence:
                var array = new JsonArray();
                foreach (var child in sequence.Children)
                    array.Add(ConvertYamlNode(child));
                return array;

            case YamlMappingNode mapping:
                var obj = new JsonObject();
                foreach (var (keyNode, valueNode) in mapping.Children)
                {
                    if (keyNode is not YamlScalarNode keyScalar || keyScalar.Value == null)
                        throw new InvalidOperationException("Map keys must be scalar strings");
                    obj[keyScalar.Value] = ConvertYamlNode(valueNode);
                }
                return obj;

            default:
                throw new NotSupportedException($"Unsupported YAML node type: {node.NodeType}");
        }
    }

    private static JsonNode? ConvertYamlScalar(YamlScalarNode scalar)
    {
        var value = scalar.Value;
        if (value == null) return null;

        if (scalar.Style != ScalarStyle.Plain)
            return JsonValue.Create(value);

        if (value.Length == 0 || value is "~" or "null" or "Null" or "NULL")
            return null;
        if (bool.TryParse(value, out var boolValue))
            return JsonValue.Create(boolValue);
        if (long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var longValue))
            return JsonValue.Create(longValue);
        if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var doubleValue))
            return JsonValue.Create(doubleValue);

        return JsonValue.Create(value);
    }

    private static async Task<NpgsqlConnection> OpenConnection()
    {
        var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__CourseDb")
            ?? throw new InvalidOperationException("Connection string not found");
        var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync();
        return connection;
    }

    private static int EmitFunctionResult(string? resultJson, Func<JsonElement, object> onSuccess)
    {
        using var doc = JsonDocument.Parse(resultJson ?? "{}");
        var root = doc.RootElement;
        var status = root.TryGetProperty("status", out var s) ? s.GetString() : "error";

        if (status != "ok")
        {
            var code = root.TryGetProperty("code", out var c) ? c.GetString() ?? "internal.error" : "internal.error";
            var message = root.TryGetProperty("message", out var m) ? m.GetString() ?? "" : "";
            return WriteError(code, message);
        }

        return WriteOk(onSuccess(root));
    }

    private static int WriteOk(object result)
    {
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            status = "ok",
            result,
            meta = new { contractVersion = "course-1" }
        }, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
        return 0;
    }

    private static int WriteError(string code, string message)
    {
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            status = "error",
            code,
            message,
            meta = new { contractVersion = "course-1" }
        }, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
        return 1;
    }
}