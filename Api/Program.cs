using Api.Middleware;
using Common.ActionExecution;
using Npgsql;

// Dapper по умолчанию мапит колонки на свойства только по точному совпадению имени.
// В БД колонки snake_case (http_method, request_schema, ...), а модели — PascalCase,
// без этой настройки такие свойства оставались бы на значениях по умолчанию.
Dapper.DefaultTypeMap.MatchNamesWithUnderscores = true;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();

// Регистрируем Middleware
builder.Services.AddScoped<CorrelationAndErrorMiddleware>();
builder.Services.AddScoped<JwtContextMiddleware>();
builder.Services.AddScoped<JsonSchemaValidationMiddleware>();

// Общий исполнитель экшена (Common.ActionExecution) — тот же класс будет использовать
// Workflow.Worker на неделе 2, поэтому он живёт в Common, а не в Api.
builder.Services.AddSingleton<ActionExecutor>();

var connectionString = builder.Configuration.GetConnectionString("CourseDb") 
    ?? Environment.GetEnvironmentVariable("ConnectionStrings__CourseDb")
    ?? throw new InvalidOperationException("Connection string 'CourseDb' not found.");
    
builder.Services.AddNpgsqlDataSource(connectionString);

builder.WebHost.UseUrls("http://0.0.0.0:8080");

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.UseDeveloperExceptionPage();
}

// Порядок вызова Middleware критически важен!
app.UseMiddleware<CorrelationAndErrorMiddleware>();   // 1. Сборка Correlation ID и перехват всех ошибок
app.UseMiddleware<JwtContextMiddleware>();             // 2. Валидация JWT
app.UseMiddleware<JsonSchemaValidationMiddleware>();   // 3. Валидация параметров и payload

app.MapControllers();

app.Run();