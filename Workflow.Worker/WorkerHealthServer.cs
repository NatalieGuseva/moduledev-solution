using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace Workflow.Worker;

/// <summary>
/// Неделя 4: WorkerHealthServer обслуживает три маршрута —
/// /health/live, /health/ready (healthchecks контейнера) и /metrics
/// (OpenMetrics, требование observability-contracts.md).
/// System.Net.HttpListener достаточно для трёх простых GET-роутов и
/// не тянет за собой ASP.NET Core hosting в консольный проект.
/// </summary>
public sealed class WorkerHealthServer : IAsyncDisposable
{
    private readonly HttpListener _listener = new();
    private readonly NpgsqlDataSource _dataSource;
    private readonly ILogger _logger;
    private readonly CancellationTokenSource _cts = new();
    private Task? _loopTask;

    public WorkerHealthServer(NpgsqlDataSource dataSource, ILogger logger, int port)
    {
        _dataSource = dataSource;
        _logger = logger;
        _listener.Prefixes.Add($"http://+:{port}/");
    }

    public void Start()
    {
        _listener.Start();
        _loopTask = Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            HttpListenerContext context;
            try
            {
                context = await _listener.GetContextAsync().WaitAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (ObjectDisposedException)
            {
                return;
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "health listener accept failed");
                continue;
            }

            _ = HandleAsync(context, cancellationToken);
        }
    }

    private async Task HandleAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        try
        {
            var path = context.Request.Url?.AbsolutePath ?? "";

            if (path == "/health/live")
            {
                await WriteJsonAsync(context, 200, new { status = "live" }, cancellationToken);
                return;
            }

            if (path == "/health/ready")
            {
                var ready = await CheckReadyAsync(cancellationToken);
                if (ready)
                {
                    await WriteJsonAsync(context, 200, new { status = "ready" }, cancellationToken);
                }
                else
                {
                    await WriteJsonAsync(context, 503, new { status = "not_ready", code = "dependency.unavailable" }, cancellationToken);
                }
                return;
            }

            // observability-contracts.md: /metrics каждого проверяемого
            // процесса возвращает HTTP 200, media type
            // application/openmetrics-text и document с завершающим # EOF.
            // Шесть обязательных серий публикует только api; worker'у
            // достаточно корректного документа с собственными метриками.
            if (path == "/metrics")
            {
                await WriteOpenMetricsAsync(context, cancellationToken);
                return;
            }

            context.Response.StatusCode = 404;
            context.Response.Close();
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "health request handling failed");
            try { context.Response.Abort(); } catch { /* уже закрыт клиентом */ }
        }
    }

    private async Task<bool> CheckReadyAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(TimeSpan.FromSeconds(3));
            await using var connection = await _dataSource.OpenConnectionAsync(cts.Token);
            await using var cmd = new NpgsqlCommand("SELECT 1", connection);
            var result = await cmd.ExecuteScalarAsync(cts.Token);
            return result is int or long;
        }
        catch
        {
            return false;
        }
    }

    private static async Task WriteJsonAsync(HttpListenerContext context, int statusCode, object body, CancellationToken cancellationToken)
    {
        var json = JsonSerializer.Serialize(body);
        var bytes = Encoding.UTF8.GetBytes(json);
        context.Response.StatusCode = statusCode;
        context.Response.ContentType = "application/json";
        context.Response.ContentLength64 = bytes.Length;
        await context.Response.OutputStream.WriteAsync(bytes, cancellationToken);
        context.Response.Close();
    }

    private static async Task WriteOpenMetricsAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        // Минимальный валидный OpenMetrics-документ. Counter объявляется
        // по имени семейства (без _total), sample — с _total. Завершаем
        // документ строкой "# EOF" — это требование контракта.
        var body = new StringBuilder()
            .Append("# HELP workflow_worker_up Worker process is running.\n")
            .Append("# TYPE workflow_worker_up gauge\n")
            .Append("workflow_worker_up 1\n")
            .Append("# EOF\n")
            .ToString();

        var bytes = Encoding.UTF8.GetBytes(body);
        context.Response.StatusCode = 200;
        context.Response.ContentType = "application/openmetrics-text; version=1.0.0; charset=utf-8";
        context.Response.ContentLength64 = bytes.Length;
        await context.Response.OutputStream.WriteAsync(bytes, cancellationToken);
        context.Response.Close();
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        _listener.Stop();
        if (_loopTask is not null)
        {
            try { await _loopTask; } catch { /* уже отменено */ }
        }
        _listener.Close();
        _cts.Dispose();
    }
}