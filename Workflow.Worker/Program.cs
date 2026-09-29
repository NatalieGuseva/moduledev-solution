using System.Runtime.InteropServices;
using System.Text.Json;
using Common.ActionExecution;
using Dapper;
using Microsoft.Extensions.Logging;
using Npgsql;
using Workflow.Worker;

Dapper.DefaultTypeMap.MatchNamesWithUnderscores = true;

var config = WorkerConfig.FromEnvironment();

using var loggerFactory = LoggerFactory.Create(builder => builder
    // FIX (неделя 4, "Логи — интерфейс для ИИ-агента"): один лог = один
    // JSON object. AddSimpleConsole печатал произвольный текст —
    // AddJsonConsole входит в Microsoft.Extensions.Logging.Console "из
    // коробки" (без новых пакетов) и уже даёт валидный JSON per line
    // (Category/LogLevel/Message/EventId/State). Это НЕ то же самое, что
    // кастомная схема полей python-сервисов (correlationId/event/service —
    // см. python/observability.py) — здесь только формат приведён к
    // "одна строка = один JSON", разбор структурных полей (jobId,
    // leaseVersion и т.п.) worker и раньше вкладывал в Message через
    // {JobId}-плейсхолдеры Microsoft.Extensions.Logging, они остаются
    // в JSON-поле "State".
    .AddJsonConsole(o =>
    {
        o.IncludeScopes = false;
        o.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";
        o.UseUtcTimestamp = true;
        o.JsonWriterOptions = new System.Text.Json.JsonWriterOptions { Indented = false };
    })
    .SetMinimumLevel(LogLevel.Information));

var logger = loggerFactory.CreateLogger("Workflow.Worker");
logger.LogInformation(
    "starting instance={InstanceId} testProfile={TestProfile} failpoint={Failpoint} lease={Lease}s poll={Poll}ms batch={Batch} healthPort={HealthPort}",
    config.InstanceId, config.TestProfile, config.Failpoint ?? "(none)", config.LeaseSeconds, config.PollIntervalMs, config.ClaimBatchSize, config.HealthPort);

// Minimum Pool Size держит несколько соединений всегда открытыми и
// прогретыми (аутентификация уже пройдена), чтобы claim/finish/fail
// никогда не упирались в холодное открытие нового физического
// соединения — под тестовым 2-секундным лизингом даже разовая заминка
// на establish/negotiate съедает весь бюджет попытки.
var connectionStringBuilder = new NpgsqlConnectionStringBuilder(config.ConnectionString)
{
    MinPoolSize = 4
};
await using var dataSource = NpgsqlDataSource.Create(connectionStringBuilder.ConnectionString);
var actionExecutor = new ActionExecutor(loggerFactory.CreateLogger<ActionExecutor>());
var stepRunner = new StepRunner(dataSource, actionExecutor, config, loggerFactory.CreateLogger<StepRunner>());

// Неделя 4: /health/live + /health/ready — раньше worker не слушал HTTP
// вообще ни на чём. Порт независим от failpoint/PollInterval и не
// участвует в лизинге; см. WorkerHealthServer.cs.
await using var healthServer = new WorkerHealthServer(dataSource, loggerFactory.CreateLogger("Workflow.Worker.Health"), config.HealthPort);
healthServer.Start();

using var cts = new CancellationTokenSource();

// Graceful shutdown: SIGTERM (docker stop) и Ctrl+C. Обычную остановку
// (без failpoint) должны пережить и claim_jobs, и уже идущий RunAsync —
// он либо успеет закоммититься, либо откатится и job просто дождётся
// следующего claim (своего или другого worker'а).
PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx => { ctx.Cancel = true; cts.Cancel(); });
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

try
{
    await RunLoop(cts.Token);
}
catch (OperationCanceledException)
{
    // ожидаемо при штатной остановке
}

logger.LogInformation("stopped instance={InstanceId}", config.InstanceId);

// ---------------------------------------------------------------------------
// Неделя 4: детерминированные failpoints.
//
// Точка активна только при COURSE_TEST_PROFILE=1 и COURSE_FAILPOINT=<name>.
// Компонент печатает одну JSON-строку в stdout:
//   {"event":"failpoint.reached","name":"<name>","instanceId":"<id>"}
// и блокируется до остановки контейнера. recovery-tests.sh находит эту
// строку через `docker compose logs` и затем делает `docker compose stop`.
// ---------------------------------------------------------------------------
void ReachFailpoint(WorkerConfig cfg, string name)
{
    if (!cfg.TestProfile) return;
    if (!string.Equals(cfg.Failpoint, name, StringComparison.Ordinal)) return;

    var payload = JsonSerializer.Serialize(new Dictionary<string, object?>
    {
        ["event"] = "failpoint.reached",
        ["name"] = name,
        ["instanceId"] = cfg.InstanceId,
    });

    // Пишем напрямую в stdout, минуя logger — recovery-tests.sh ищет
    // ровно эту строку как есть, без обёрток вида {"Message": "..."}.
    Console.WriteLine(payload);
    Console.Out.Flush();

    // Блокируемся до остановки контейнера. В случае SIGTERM поток
    // прервётся, и мы просто вернёмся наверх, где сработает graceful
    // shutdown. Это соответствует ТЗ: failpoint "блокируется до остановки".
    try
    {
        Thread.Sleep(Timeout.Infinite);
    }
    catch (ThreadInterruptedException)
    {
        // Ожидаемо при остановке.
    }
}

async Task RunLoop(CancellationToken cancellationToken)
{
    while (!cancellationToken.IsCancellationRequested)
    {
        List<ClaimedJob> claimed;
        try
        {
            await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
            var rows = await connection.QueryAsync<ClaimedJob>(
                "SELECT * FROM workflow.claim_jobs(@owner, @limit, @leaseSeconds)",
                new { owner = config.InstanceId, limit = config.ClaimBatchSize, leaseSeconds = config.LeaseSeconds });
            claimed = rows.AsList();
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "claim_jobs failed, will retry after poll interval");
            claimed = new List<ClaimedJob>();
        }

        if (claimed.Count == 0)
        {
            await Task.Delay(config.PollIntervalMs, cancellationToken);
            continue;
        }

        // Неделя 4: after_job_claim — после успешного claim, до выполнения
        // шага. Контейнер будет остановлен checker'ом/recovery-tests.sh,
        // лизинг истечёт, и job переподхватит другой worker по reclaim.
        ReachFailpoint(config, "after_job_claim");

        foreach (var job in claimed)
        {
            if (cancellationToken.IsCancellationRequested) break;

            try
            {
                await stepRunner.RunAsync(job, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                // Не должно случаться — StepRunner сам ловит свои сбои и переводит их
                // в fail_job. Если что-то всё же протекло сюда, не роняем весь worker
                // из-за одного job'а: лизинг истечёт, и job переподхватят по reclaim.
                logger.LogError(ex, "unhandled error while running job {JobId}, leaving it to lease expiry", job.JobId);
            }
        }
    }
}