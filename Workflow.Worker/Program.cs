using System.Runtime.InteropServices;
using Common.ActionExecution;
using Dapper;
using Microsoft.Extensions.Logging;
using Npgsql;
using Workflow.Worker;

Dapper.DefaultTypeMap.MatchNamesWithUnderscores = true;

var config = WorkerConfig.FromEnvironment();

using var loggerFactory = LoggerFactory.Create(builder => builder
    .AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss "; })
    .SetMinimumLevel(LogLevel.Information));

var logger = loggerFactory.CreateLogger("Workflow.Worker");
logger.LogInformation(
    "starting instance={InstanceId} testProfile={TestProfile} failpoint={Failpoint} lease={Lease}s poll={Poll}ms batch={Batch}",
    config.InstanceId, config.TestProfile, config.Failpoint ?? "(none)", config.LeaseSeconds, config.PollIntervalMs, config.ClaimBatchSize);

await using var dataSource = NpgsqlDataSource.Create(config.ConnectionString);
var actionExecutor = new ActionExecutor(loggerFactory.CreateLogger<ActionExecutor>());
var stepRunner = new StepRunner(dataSource, actionExecutor, config, loggerFactory.CreateLogger<StepRunner>());

using var cts = new CancellationTokenSource();

//Граceful shutdown: SIGTERM (docker stop) и Ctrl+C. Обычную остановку
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
