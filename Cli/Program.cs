using System.Text.Json;
using System.Text.Json.Serialization;
using Dapper;
using Npgsql;

namespace Cli;

class Program
{
    static async Task Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli <command> [args...]");
            Environment.Exit(1);
            return;
        }

        var command = args[0];
        
        try
        {
            int exitCode = command switch
            {
                "migration" => await HandleMigrationCommand(args.Skip(1).ToArray()),
                "action" => await HandleActionCommand(args.Skip(1).ToArray()),
                "flow" => await Cli.Commands.FlowCommands.Handle(args.Skip(1).ToArray()),
                _ => throw new InvalidOperationException($"Unknown command: {command}")
            };
            
            Environment.Exit(exitCode);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Error: {ex.Message}");
            Environment.Exit(1);
        }
    }

    private static async Task<int> HandleActionCommand(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli action <subcommand> [args...]");
            return 1;
        }

        var subcommand = args[0];
        var subArgs = args.Skip(1).ToArray();

        return subcommand switch
        {
            "publish" => await HandlePublish(subArgs),
            "validate" => await HandleValidate(subArgs),
            "list" => await HandleList(subArgs),
            "activate" => await HandleActivate(subArgs),
            "disable" => await HandleDisable(subArgs),
            _ => throw new InvalidOperationException($"Unknown action subcommand: {subcommand}")
        };
    }

    private static async Task<int> HandlePublish(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli action publish <manifest.json>");
            return 1;
        }

        var manifestPath = args[0];
        
        if (!File.Exists(manifestPath))
        {
            Console.Error.WriteLine($"Manifest file not found: {manifestPath}");
            return 1;
        }

        var manifestJson = await File.ReadAllTextAsync(manifestPath);
        var manifest = JsonSerializer.Deserialize<ActionManifest>(manifestJson);

        if (manifest == null)
        {
            Console.Error.WriteLine("Failed to parse manifest JSON");
            return 1;
        }

        var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__CourseDb")
            ?? throw new InvalidOperationException("Connection string not found");

        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync();

        // Используем функцию course.publish_action
        const string sql = @"
            SELECT course.publish_action(
                @module,
                @action,
                @version,
                @http_method,
                @target_schema,
                @target_function,
                @request_schema::jsonb,
                @response_schema::jsonb,
                @outcomes::jsonb,
                @required_policy::jsonb,
                @idempotency_mode,
                @idempotency_scope,
                @timeout_ms,
                @enabled
            )";

        var result = await connection.ExecuteScalarAsync<string>(sql, new
        {
            module = manifest.Module,
            action = manifest.Action,
            version = manifest.Version,
            http_method = manifest.HttpMethod ?? "POST",
            target_schema = manifest.TargetSchema,
            target_function = manifest.TargetFunction,
            request_schema = manifest.RequestSchema.HasValue ? manifest.RequestSchema.Value.GetRawText() : "{}",
            response_schema = manifest.ResponseSchema.HasValue ? manifest.ResponseSchema.Value.GetRawText() : "{}",
            outcomes = JsonSerializer.Serialize(manifest.Outcomes ?? Array.Empty<string>()),
            required_policy = JsonSerializer.Serialize(manifest.RequiredPolicy ?? Array.Empty<string>()),
            idempotency_mode = manifest.IdempotencyMode ?? "none",
            idempotency_scope = manifest.IdempotencyScope ?? "none",
            timeout_ms = manifest.TimeoutMs ?? 30000,
            enabled = manifest.Enabled
        });

        Console.WriteLine(result);

        // publish_action теперь может вернуть status=error (например, manifest.conflict
        // при попытке изменить уже опубликованную версию) — это должно быть видно
        // в exit code, иначе автопроверка не отличит успех от отказа.
        using var resultDoc = JsonDocument.Parse(result ?? "{}");
        var status = resultDoc.RootElement.TryGetProperty("status", out var statusProp)
            ? statusProp.GetString()
            : "error";

        return status == "ok" ? 0 : 1;
    }

    private static async Task<int> HandleValidate(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli action validate <manifest.json>");
            return 1;
        }

        var manifestPath = args[0];
        
        if (!File.Exists(manifestPath))
        {
            Console.Error.WriteLine($"Manifest file not found: {manifestPath}");
            return 1;
        }

        var manifestJson = await File.ReadAllTextAsync(manifestPath);
        var manifest = JsonSerializer.Deserialize<ActionManifest>(manifestJson);

        if (manifest == null)
        {
            Console.Error.WriteLine("Failed to parse manifest JSON");
            return 1;
        }

        // Базовая валидация
        if (string.IsNullOrEmpty(manifest.Module))
        {
            Console.Error.WriteLine("Validation failed: module is required");
            return 1;
        }

        if (string.IsNullOrEmpty(manifest.Action))
        {
            Console.Error.WriteLine("Validation failed: action is required");
            return 1;
        }

        if (manifest.Version <= 0)
        {
            Console.Error.WriteLine("Validation failed: version must be positive");
            return 1;
        }

        if (string.IsNullOrEmpty(manifest.TargetSchema))
        {
            Console.Error.WriteLine("Validation failed: target_schema is required");
            return 1;
        }

        if (string.IsNullOrEmpty(manifest.TargetFunction))
        {
            Console.Error.WriteLine("Validation failed: target_function is required");
            return 1;
        }

        var result = new
        {
            status = "ok",
            result = new
            {
                resource = "action",
                operation = "validated",
                key = $"{manifest.Module}.{manifest.Action}",
                version = manifest.Version
            },
            meta = new
            {
                contractVersion = "course-1"
            }
        };

        Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions 
        { 
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase 
        }));
        
        return 0;
    }

    private static async Task<int> HandleList(string[] args)
    {
        var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__CourseDb")
            ?? throw new InvalidOperationException("Connection string not found");

        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync();

        const string sql = @"
            SELECT 
                module,
                action,
                version,
                enabled,
                is_default
            FROM course.action_catalog
            ORDER BY module, action, version";

        var items = await connection.QueryAsync<ActionItem>(sql);

        var result = new
        {
            status = "ok",
            result = new
            {
                resource = "action",
                operation = "listed",
                items = items
            },
            meta = new
            {
                contractVersion = "course-1"
            }
        };

        Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions 
        { 
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase 
        }));
        
        return 0;
    }

    private static async Task<int> HandleActivate(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli action activate <key> [--version <version>]");
            return 1;
        }

        var key = args[0];
        var parts = key.Split('.');
        if (parts.Length != 2)
        {
            Console.Error.WriteLine("Invalid key format. Expected module.action");
            return 1;
        }

        var module = parts[0];
        var action = parts[1];
        var version = 0;

        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--version" && i + 1 < args.Length)
            {
                version = int.Parse(args[i + 1]);
                break;
            }
        }

        if (version == 0)
        {
            Console.Error.WriteLine("--version is required");
            return 1;
        }

        var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__CourseDb")
            ?? throw new InvalidOperationException("Connection string not found");

        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync();

        await using var transaction = await connection.BeginTransactionAsync();

        try
        {
            // Отключаем текущую default версию
            await connection.ExecuteAsync(
                "UPDATE course.action_catalog SET is_default = false WHERE module = @module AND action = @action AND is_default = true",
                new { module, action },
                transaction);

            // Включаем указанную версию
            var rows = await connection.ExecuteAsync(
                "UPDATE course.action_catalog SET is_default = true WHERE module = @module AND action = @action AND version = @version",
                new { module, action, version },
                transaction);

            await transaction.CommitAsync();

            if (rows == 0)
            {
                Console.Error.WriteLine($"Version {version} not found or already default");
                return 1;
            }

            var result = new
            {
                status = "ok",
                result = new
                {
                    resource = "action",
                    operation = "activated",
                    key = $"{module}.{action}",
                    version
                },
                meta = new
                {
                    contractVersion = "course-1"
                }
            };

            Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions 
            { 
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase 
            }));
            
            return 0;
        }
        catch
        {
            await transaction.RollbackAsync();
            throw;
        }
    }

    private static async Task<int> HandleDisable(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: cli action disable <key> --version <version> [--replacement-version <version>]");
            return 1;
        }

        var key = args[0];
        var parts = key.Split('.');
        if (parts.Length != 2)
        {
            Console.Error.WriteLine("Invalid key format. Expected module.action");
            return 1;
        }

        var module = parts[0];
        var action = parts[1];
        var version = 0;
        int? replacementVersion = null;

        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--version" && i + 1 < args.Length)
            {
                version = int.Parse(args[i + 1]);
            }
            if (args[i] == "--replacement-version" && i + 1 < args.Length)
            {
                replacementVersion = int.Parse(args[i + 1]);
            }
        }

        if (version == 0)
        {
            Console.Error.WriteLine("--version is required");
            return 1;
        }

        var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__CourseDb")
            ?? throw new InvalidOperationException("Connection string not found");

        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync();

        var rows = await connection.ExecuteAsync(
            "UPDATE course.action_catalog SET enabled = false WHERE module = @module AND action = @action AND version = @version",
            new { module, action, version });

        if (rows == 0)
        {
            Console.Error.WriteLine($"Version {version} not found or already disabled");
            return 1;
        }

        // Если версия была default, переключить на replacement
        var isDefault = await connection.ExecuteScalarAsync<bool>(
            "SELECT is_default FROM course.action_catalog WHERE module = @module AND action = @action AND version = @version",
            new { module, action, version });

        if (isDefault)
        {
            var targetVersion = replacementVersion ?? 1;
            await connection.ExecuteAsync(
                "UPDATE course.action_catalog SET is_default = true WHERE module = @module AND action = @action AND version = @targetVersion",
                new { module, action, targetVersion });
        }

        var result = new
        {
            status = "ok",
            result = new
            {
                resource = "action",
                operation = "disabled",
                key = $"{module}.{action}",
                version,
                replacementVersion = replacementVersion ?? 1
            },
            meta = new
            {
                contractVersion = "course-1"
            }
        };

        Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions 
        { 
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase 
        }));
        
        return 0;
    }

    private static async Task<int> HandleMigrationCommand(string[] args)
    {

    if (args.Length == 0)
    {
        Console.Error.WriteLine("Usage: cli migration apply <migrations_path>");
        return 1;
    }

    var subcommand = args[0];
    
    if (subcommand != "apply")
    {
        Console.Error.WriteLine($"Unknown migration subcommand: {subcommand}");
        return 1;
    }

    if (args.Length < 2)
    {
        Console.Error.WriteLine("Usage: cli migration apply <migrations_path>");
        return 1;
    }

    var migrationsPath = args[1];
    
    if (!Directory.Exists(migrationsPath))
    {
        Console.Error.WriteLine($"Migrations directory not found: {migrationsPath}");
        return 1;
    }

    var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__CourseDb")
        ?? throw new InvalidOperationException("Connection string not found");

    await using var connection = new NpgsqlConnection(connectionString);
    await connection.OpenAsync();

    // 🔥 Сначала создаём схему course, если её нет
    await connection.ExecuteAsync("CREATE SCHEMA IF NOT EXISTS course");

    // Теперь создаём таблицу истории миграций
    await connection.ExecuteAsync(@"
        CREATE TABLE IF NOT EXISTS course.migration_history (
            id SERIAL PRIMARY KEY,
            migration_name TEXT NOT NULL UNIQUE,
            checksum TEXT NOT NULL,
            applied_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        )");

    var files = Directory.GetFiles(migrationsPath, "*.sql")
        .OrderBy(f => Path.GetFileName(f))
        .ToList();

    var applied = new List<string>();
    var skipped = new List<string>();

    foreach (var file in files)
    {
        var fileName = Path.GetFileName(file);
        var content = await File.ReadAllTextAsync(file);
        var checksum = ComputeChecksum(content);

        var existing = await connection.QueryFirstOrDefaultAsync<MigrationRecord>(
            "SELECT * FROM course.migration_history WHERE migration_name = @name",
            new { name = fileName });

        if (existing != null)
        {
            if (existing.Checksum != checksum)
            {
                Console.Error.WriteLine($"Migration file changed after being applied: {fileName}");
                var error = new
                {
                    status = "error",
                    code = "manifest.conflict",
                    message = $"migration file changed after being applied: {fileName}",
                    meta = new { contractVersion = "course-1" }
                };
                Console.WriteLine(JsonSerializer.Serialize(error));
                return 1;
            }
            skipped.Add(fileName);
            continue;
        }

        // 🔥 Выполняем миграцию
        await connection.ExecuteAsync(content);
        await connection.ExecuteAsync(
            "INSERT INTO course.migration_history (migration_name, checksum) VALUES (@name, @checksum)",
            new { name = fileName, checksum });
        
        applied.Add(fileName);
        Console.Error.WriteLine($"applying {fileName}");
    }

    // workflow_worker создаётся в 005_workflow_schema.sql как NOLOGIN — под ней
    // нельзя подключиться напрямую, и все её точечные GRANT/REVOKE ничего не
    // значат, пока Workflow.Worker подключается тем же суперпользователем, что
    // Api и Cli. Здесь (а не в самой миграции, потому что миграции — статичные
    // .sql файлы без доступа к переменным окружения) даём роли реальный LOGIN
    // и пароль из окружения, если он задан. ALTER ROLE идемпотентен — повторный
    // прогон просто переустановит тот же пароль.
    var workflowWorkerPassword = Environment.GetEnvironmentVariable("COURSE_WORKFLOW_WORKER_PASSWORD");
    if (!string.IsNullOrEmpty(workflowWorkerPassword))
    {
        var escaped = workflowWorkerPassword.Replace("'", "''");
        await connection.ExecuteAsync($"ALTER ROLE workflow_worker WITH LOGIN PASSWORD '{escaped}'");
        Console.Error.WriteLine("workflow_worker role is now LOGIN-capable (password set from COURSE_WORKFLOW_WORKER_PASSWORD)");
    }

    var result = new
    {
        status = "ok",
        result = new
        {
            resource = "migration",
            operation = "applied",
            applied = applied,
            skipped = skipped
        },
        meta = new
        {
            contractVersion = "course-1"
        }
    };

    Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions 
    { 
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase 
    }));
    
    return 0;
    }

    private static string ComputeChecksum(string content)
    {
        using var sha = System.Security.Cryptography.SHA256.Create();
        var bytes = System.Text.Encoding.UTF8.GetBytes(content);
        var hash = sha.ComputeHash(bytes);
        return Convert.ToBase64String(hash);
    }

    private class ActionManifest
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

        [JsonPropertyName("enabled")]
        public bool Enabled { get; set; } = true;
    }

    private class ActionItem
    {
        public string Module { get; set; } = string.Empty;
        public string Action { get; set; } = string.Empty;
        public int Version { get; set; }
        public bool Enabled { get; set; }
        public bool IsDefault { get; set; }
    }

    private class MigrationRecord
    {
        public int Id { get; set; }
        public string MigrationName { get; set; } = string.Empty;
        public string Checksum { get; set; } = string.Empty;
        public DateTime AppliedAt { get; set; }
    }
}