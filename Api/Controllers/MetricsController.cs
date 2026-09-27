using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace Api.Controllers;

// Неделя 4: единственный /metrics во всём контуре (диаграмма задания —
// "api:8080/metrics — проекция PostgreSQL"). Не нужен ни одному
// python-сервису и worker'у отдельно: все шесть серий читаются здесь
// через autocheck.jobs / autocheck.outbox, на которые course_runtime
// уже имеет SELECT (006_workflow_autocheck_views.sql / 011_delivery_functions.sql) —
// новых grant'ов эта миграция не требует.
[ApiController]
[Route("metrics")]
public class MetricsController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;
    private readonly ILogger<MetricsController> _logger;

    public MetricsController(NpgsqlDataSource dataSource, ILogger<MetricsController> logger)
    {
        _dataSource = dataSource;
        _logger = logger;
    }

    private const string OpenMetricsContentType = "application/openmetrics-text; version=1.0.0; charset=utf-8";

    [HttpGet]
    public async Task<IActionResult> Get(CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken);

            long jobsReady;
            double? jobOldestAgeSeconds;
            long processesWaiting;
            long outboxPending;
            double? outboxOldestAgeSeconds;
            long failuresTotal;

            await using (var cmd = new NpgsqlCommand(
                "SELECT count(*) FROM autocheck.jobs WHERE state IN ('READY', 'RETRY_WAIT')", connection))
                jobsReady = (long)(await cmd.ExecuteScalarAsync(cancellationToken))!;

            await using (var cmd = new NpgsqlCommand(
                "SELECT EXTRACT(EPOCH FROM (now() - min(created_at))) FROM autocheck.jobs WHERE state IN ('READY', 'RETRY_WAIT')", connection))
            {
                var raw = await cmd.ExecuteScalarAsync(cancellationToken);
                jobOldestAgeSeconds = raw is DBNull or null ? null : Convert.ToDouble(raw, CultureInfo.InvariantCulture);
            }

            await using (var cmd = new NpgsqlCommand(
                "SELECT count(*) FROM autocheck.processes WHERE state IN ('WAITING_SIGNAL', 'WAITING_MANUAL')", connection))
                processesWaiting = (long)(await cmd.ExecuteScalarAsync(cancellationToken))!;

            await using (var cmd = new NpgsqlCommand(
                "SELECT count(*) FROM autocheck.outbox WHERE state IN ('PENDING', 'RETRY_WAIT')", connection))
                outboxPending = (long)(await cmd.ExecuteScalarAsync(cancellationToken))!;

            await using (var cmd = new NpgsqlCommand(
                "SELECT EXTRACT(EPOCH FROM (now() - min(created_at))) FROM autocheck.outbox WHERE state IN ('PENDING', 'RETRY_WAIT')", connection))
            {
                var raw = await cmd.ExecuteScalarAsync(cancellationToken);
                outboxOldestAgeSeconds = raw is DBNull or null ? null : Convert.ToDouble(raw, CultureInfo.InvariantCulture);
            }

            await using (var cmd = new NpgsqlCommand(
                "SELECT count(*) FROM autocheck.jobs WHERE state = 'DEAD'", connection))
                failuresTotal = (long)(await cmd.ExecuteScalarAsync(cancellationToken))!;

            var sb = new StringBuilder();

            AppendGauge(sb, "workflow_jobs_ready", "Workflow jobs currently claimable (READY or RETRY_WAIT due).", jobsReady);
            AppendGaugeNullable(sb, "workflow_job_oldest_age_seconds", "Age in seconds of the oldest claimable workflow job.", jobOldestAgeSeconds);
            AppendGauge(sb, "workflow_processes_waiting", "Processes waiting on a signal or a manual decision.", processesWaiting);
            AppendGauge(sb, "outbox_pending", "Outbox rows waiting to be delivered (PENDING or RETRY_WAIT).", outboxPending);
            AppendGaugeNullable(sb, "outbox_oldest_age_seconds", "Age in seconds of the oldest pending Outbox row.", outboxOldestAgeSeconds);
            AppendCounter(sb, "workflow_failures", "Workflow jobs that reached the terminal DEAD state.", failuresTotal);

            sb.Append("# EOF\n");

            return Content(sb.ToString(), OpenMetricsContentType);
        }
        catch (Exception ex)
        {
            // /metrics не является health-эндпоинтом контракта, но не должен
            // ронять весь процесс — на недоступной БД отдаём валидный (пустой)
            // OpenMetrics документ с 503, а не 500 со стектрейсом.
            _logger.LogDebug(ex, "Failed to collect metrics");
            return StatusCode(StatusCodes.Status503ServiceUnavailable, "# EOF\n");
        }
    }

    private static void AppendGauge(StringBuilder sb, string name, string help, long value) =>
        AppendSeries(sb, name, "gauge", help, value.ToString(CultureInfo.InvariantCulture));

    private static void AppendGaugeNullable(StringBuilder sb, string name, string help, double? value) =>
        AppendSeries(sb, name, "gauge", help, value.HasValue ? value.Value.ToString("F3", CultureInfo.InvariantCulture) : "0");

    private static void AppendCounter(StringBuilder sb, string name, string help, long value) =>
        // OpenMetrics: TYPE/HELP объявляются БЕЗ суффикса _total, сам сэмпл — С ним.
        AppendCounterSeries(sb, name, help, value.ToString(CultureInfo.InvariantCulture));

    private static void AppendSeries(StringBuilder sb, string name, string type, string help, string value)
    {
        sb.Append("# HELP ").Append(name).Append(' ').Append(help).Append('\n');
        sb.Append("# TYPE ").Append(name).Append(' ').Append(type).Append('\n');
        sb.Append(name).Append(' ').Append(value).Append('\n');
    }

    private static void AppendCounterSeries(StringBuilder sb, string name, string help, string value)
    {
        sb.Append("# HELP ").Append(name).Append(' ').Append(help).Append('\n');
        sb.Append("# TYPE ").Append(name).Append(" counter\n");
        sb.Append(name).Append("_total ").Append(value).Append('\n');
    }
}
