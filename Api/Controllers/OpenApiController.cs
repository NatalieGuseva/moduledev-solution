using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Npgsql;
using Common.Contracts;

namespace Api.Controllers;

[ApiController]
[Route("/openapi")]
public class OpenApiController : ControllerBase
{
    private readonly ILogger<OpenApiController> _logger;
    private readonly NpgsqlDataSource _dataSource;

    public OpenApiController(ILogger<OpenApiController> logger, NpgsqlDataSource dataSource)
    {
        _logger = logger;
        _dataSource = dataSource;
    }

    // Тест/гейтвей ходят строго на /openapi/default.json (см. autocheck/public_check.py и
    // gateway-логи: "Proxying to http://api:8080/openapi/default.json"), а не на "/openapi".
    [HttpGet]
    [Route("default.json")]
    public async Task<IActionResult> GetOpenApiDocument()
    {
        try
        {
            var actions = await GetActionDefinitionsAsync();
            
            var paths = new Dictionary<string, object>();
            foreach (var a in actions)
            {
                var pathKey = $"/api/{a.Module}/{a.Action}";
                paths[pathKey] = new
                {
                    post = new
                    {
                        summary = $"{a.Module}.{a.Action} v{a.Version}",
                        parameters = new object[]
                        {
                            new
                            {
                                name = "Idempotency-Key",
                                @in = "header",
                                description = "Idempotency key",
                                required = a.IdempotencyMode != "none",
                                schema = new { type = "string" }
                            }
                        },
                        requestBody = new
                        {
                            required = true,
                            // ИСПРАВЛЕНО: анонимный тип с полем "application_json" сериализовался
                            // буквально как ключ "application_json" (C#-идентификаторы не могут
                            // содержать "/"), а не как требуемый OpenAPI media type "application/json".
                            // Клиенты, которые ищут ключ "application/json" в content, ничего не
                            // находили. Явный Dictionary<string, object> позволяет задать ключ с "/".
                            content = new Dictionary<string, object>
                            {
                                ["application/json"] = new
                                {
                                    schema = JsonSerializer.Deserialize<JsonElement>(a.RequestSchema)
                                }
                            }
                        },
                        responses = new
                        {
                            _200 = new
                            {
                                description = "Success",
                                content = new Dictionary<string, object>
                                {
                                    ["application/json"] = new
                                    {
                                        schema = JsonSerializer.Deserialize<JsonElement>(a.ResponseSchema)
                                    }
                                }
                            }
                        }
                    }
                };
            }

            var openApiDoc = new
            {
                openapi = "3.0.1",
                info = new
                {
                    title = "Course API",
                    version = "1.0.0"
                },
                paths = paths
            };

            return Ok(openApiDoc);
        }
        catch (Exception ex)
        {
            // 🔥 ИСПРАВЛЕНО: LogError → LogDebug
            _logger.LogDebug(ex, "Error generating OpenAPI document");
            return StatusCode(500, new ErrorEnvelope
            {
                Code = "internal.error",
                Message = "Error generating OpenAPI document",
                Retryable = false
            });
        }
    }

    // Путь должен быть /openapi/actions/{module}/{action}/{version}.json — ".json" здесь
    // литеральный суффикс последнего сегмента, это ASP.NET Core routing поддерживает штатно.
    //
    // Параметр НАРОЧНО назван actionName, а не action: имя маршрутного токена "{action}"
    // проверено эмпирически ломает выбор эндпоинта в ASP.NET Core (StatusCode 404) даже без
    // конвенционального роутинга — фреймворк использует route-value ключ "action" внутри
    // своей собственной логики отбора action-метода контроллера, и наш собственный параметр
    // с тем же именем перезаписывает это значение, из-за чего Endpoint Selector не находит
    // соответствия. У параметра "module" такой коллизии нет, но во избежание сюрпризов в
    // будущем — переименовано только то, что реально конфликтовало.
    [HttpGet]
    [Route("actions/{module}/{actionName}/{version}.json")]
    public async Task<IActionResult> GetActionOpenApiDocument(string module, string actionName, int version)
    {
        try
        {
            var actionDef = await GetActionDefinitionAsync(module, actionName, version);
            if (actionDef == null)
            {
                return NotFound(new ErrorEnvelope
                {
                    Code = "action.not_found",
                    Message = $"Action {module}.{actionName} v{version} not found",
                    Retryable = false
                });
            }

            var openApiDoc = new
            {
                openapi = "3.0.1",
                info = new
                {
                    title = $"Action {module}.{actionName} v{version}",
                    version = version.ToString()
                },
                paths = new Dictionary<string, object>
                {
                    [$"/api/{module}/{actionName}"] = new
                    {
                        post = new
                        {
                            summary = $"{module}.{actionName} v{version}",
                            parameters = new object[]
                            {
                                new
                                {
                                    name = "Idempotency-Key",
                                    @in = "header",
                                    description = "Idempotency key",
                                    required = actionDef.IdempotencyMode != "none",
                                    schema = new { type = "string" }
                                }
                            },
                            requestBody = new
                            {
                                required = true,
                                // См. комментарий в GetOpenApiDocument выше — та же самая проблема
                                // с ключом media type: должно быть "application/json", а не
                                // "application_json".
                                content = new Dictionary<string, object>
                                {
                                    ["application/json"] = new
                                    {
                                        schema = JsonSerializer.Deserialize<JsonElement>(actionDef.RequestSchema)
                                    }
                                }
                            },
                            responses = new
                            {
                                _200 = new
                                {
                                    description = "Success",
                                    content = new Dictionary<string, object>
                                    {
                                        ["application/json"] = new
                                        {
                                            schema = JsonSerializer.Deserialize<JsonElement>(actionDef.ResponseSchema)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            };

            return Ok(openApiDoc);
        }
        catch (Exception ex)
        {
            // 🔥 ИСПРАВЛЕНО: LogError → LogDebug
            _logger.LogDebug(ex, "Error generating OpenAPI document for action {module}.{action} v{version}",
                module, actionName, version);
            return StatusCode(500, new ErrorEnvelope
            {
                Code = "internal.error",
                Message = "Error generating OpenAPI document",
                Retryable = false
            });
        }
    }

    private async Task<List<ActionDefinition>> GetActionDefinitionsAsync()
    {
        var result = new List<ActionDefinition>();
        
        using var conn = await _dataSource.OpenConnectionAsync();
        using var cmd = conn.CreateCommand();
        // ИСПРАВЛЕНО: раньше здесь был только "WHERE enabled = true" — это включало
        // в default.json ВСЕ включённые версии одного и того же action (например,
        // и v1, и v2, если обе enabled), хотя default.json должен описывать ровно
        // один, действующий по умолчанию контракт на каждый module.action
        // (не-default версии документируются отдельно через
        // /openapi/actions/{module}/{action}/{version}.json). Добавлен фильтр
        // "AND is_default = true".
        cmd.CommandText = @"
            SELECT module, action, version, request_schema::text, response_schema::text, 
                   idempotency_mode
            FROM course.action_catalog
            WHERE enabled = true AND is_default = true
            ORDER BY module, action, version";
        
        using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            result.Add(new ActionDefinition
            {
                Module = reader.GetString(0),
                Action = reader.GetString(1),
                Version = reader.GetInt32(2),
                RequestSchema = reader.GetString(3),
                ResponseSchema = reader.GetString(4),
                IdempotencyMode = reader.GetString(5)
            });
        }
        
        return result;
    }

    private async Task<ActionDefinition?> GetActionDefinitionAsync(string module, string action, int version)
    {
        using var conn = await _dataSource.OpenConnectionAsync();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            SELECT module, action, version, request_schema::text, response_schema::text, 
                   idempotency_mode
            FROM course.action_catalog
            WHERE module = $1 AND action = $2 AND version = $3 AND enabled = true";
        cmd.Parameters.AddWithValue(module);
        cmd.Parameters.AddWithValue(action);
        cmd.Parameters.AddWithValue(version);
        
        using var reader = await cmd.ExecuteReaderAsync();
        if (await reader.ReadAsync())
        {
            return new ActionDefinition
            {
                Module = reader.GetString(0),
                Action = reader.GetString(1),
                Version = reader.GetInt32(2),
                RequestSchema = reader.GetString(3),
                ResponseSchema = reader.GetString(4),
                IdempotencyMode = reader.GetString(5)
            };
        }
        
        return null;
    }

    private class ActionDefinition
    {
        public string Module { get; set; } = string.Empty;
        public string Action { get; set; } = string.Empty;
        public int Version { get; set; }
        public string RequestSchema { get; set; } = string.Empty;
        public string ResponseSchema { get; set; } = string.Empty;
        public string IdempotencyMode { get; set; } = string.Empty;
    }
}
