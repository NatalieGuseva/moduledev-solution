using System.Text.Json;
using Dapper;
using Npgsql;
using Xunit;

namespace Api.Tests;

// Регрессионный набор на пункт фидбэка «Не хватает собственных регрессий
// состояния и сбоев»: два конкурирующих claim, устаревший finish/fail,
// и один предметный эффект после остановки между действием и подтверждением
// (crash-recovery). Тестируем ровно ту границу (workflow.claim_jobs/
// finish_job/fail_job/api.invoke), которой ограничена роль workflow_worker —
// SET ROLE workflow_worker, а не course_owner/суперпользователь, чтобы
// поймать не только логическую, но и grant-ошибку.
//
// Flow/task/step заводим напрямую INSERT'ами (не через "cli flow publish") —
// тестируем SQL-контракт claim/finish/fail, а не CLI-валидатор, у которого
// уже есть свои тесты (Cli.Tests/ManifestSchemaValidatorTests.cs).
[Collection("Postgres")]
public class WorkflowReclaimRegressionTests
{
    private readonly PostgresFixture _fixture;

    public WorkflowReclaimRegressionTests(PostgresFixture fixture)
    {
        _fixture = fixture;
    }

    private async Task<NpgsqlConnection> OpenAsWorkflowWorkerAsync()
    {
        var connection = new NpgsqlConnection(_fixture.SuperuserConnectionString);
        await connection.OpenAsync();
        await connection.ExecuteAsync("SET ROLE workflow_worker");
        return connection;
    }

    // Один READY automatic-job на training.canary (регистрируется миграцией
    // 010_insert_training_canary_action.sql), с уникальными именами на
    // каждый вызов — тесты одного класса делят Postgres-контейнер
    // (CollectionFixture), поэтому flow_name/business_key не должны
    // пересекаться между тестами.
    private static async Task<(Guid JobId, Guid ExecutionId, Guid ProcessId)> CreateReadyJobAsync(
        NpgsqlConnection superuserConnection, string suffix)
    {
        var flowName = $"reclaim-test-{suffix}";
        var taskId = Guid.NewGuid();
        var processId = Guid.NewGuid();
        var stepInstanceId = Guid.NewGuid();
        var jobId = Guid.NewGuid();

        await superuserConnection.ExecuteAsync(
            "INSERT INTO workflow.flow_definition (flow_name) VALUES (@flowName)",
            new { flowName });

        await superuserConnection.ExecuteAsync(
            @"INSERT INTO workflow.flow_version (flow_name, flow_version, status, is_active, map_definition)
              VALUES (@flowName, 1, 'PUBLISHED', true, '{}'::jsonb)",
            new { flowName });

        await superuserConnection.ExecuteAsync(
            @"INSERT INTO workflow.task_definition
                  (id, flow_name, flow_version, action_module, action_name, action_version,
                   input_mapping, input_constants, max_attempts, delays_ms)
              VALUES (@taskId, @flowName, 1, 'training', 'canary', 1,
                      '{""/value"":""/value""}'::jsonb, '{}'::jsonb, 3, '[200,400]'::jsonb)",
            new { taskId, flowName });

        await superuserConnection.ExecuteAsync(
            @"INSERT INTO workflow.step_definition
                  (flow_name, flow_version, step_key, step_type, is_start, task_definition_id)
              VALUES (@flowName, 1, 'invoke_canary', 'AUTOMATIC', true, @taskId)",
            new { flowName, taskId });

        // "done" + transition на APPLIED — без них finish_job закономерно
        // отклоняет успешный исход как workflow.unknown_outcome (нет
        // маршрута дальше), а не как ошибку lease/fencing, которую мы
        // тут тестируем.
        await superuserConnection.ExecuteAsync(
            @"INSERT INTO workflow.step_definition (flow_name, flow_version, step_key, step_type, is_start)
              VALUES (@flowName, 1, 'done', 'END', false)",
            new { flowName });

        await superuserConnection.ExecuteAsync(
            @"INSERT INTO workflow.transition_definition (flow_name, flow_version, step_key, outcome, next_step_key)
              VALUES (@flowName, 1, 'invoke_canary', 'APPLIED', 'done')",
            new { flowName });

        await superuserConnection.ExecuteAsync(
            @"INSERT INTO workflow.process_instance
                  (process_id, business_key, flow_name, flow_version, state, current_step_key, process_data)
              VALUES (@processId, @businessKey, @flowName, 1, 'RUNNING', 'invoke_canary', @data::jsonb)",
            new { processId, businessKey = $"biz-{suffix}", flowName, data = "{\"value\": 1}" });

        await superuserConnection.ExecuteAsync(
            @"INSERT INTO workflow.step_instance (step_instance_id, process_id, step_key, step_type, state)
              VALUES (@stepInstanceId, @processId, 'invoke_canary', 'AUTOMATIC', 'READY')",
            new { stepInstanceId, processId });

        var executionId = await superuserConnection.ExecuteScalarAsync<Guid>(
            @"INSERT INTO workflow.workflow_job (job_id, process_id, step_instance_id, state)
              VALUES (@jobId, @processId, @stepInstanceId, 'READY')
              RETURNING execution_id",
            new { jobId, processId, stepInstanceId });

        return (jobId, executionId, processId);
    }

    private static async Task<JsonElement> ClaimOneAsync(NpgsqlConnection connection, string owner, int leaseSeconds = 30)
    {
        var rows = (await connection.QueryAsync<string>(
                "SELECT row_to_json(c)::text FROM workflow.claim_jobs(@owner, 5, @leaseSeconds) c",
                new { owner, leaseSeconds }))
            .ToList();
        return rows.Count == 0
            ? default
            : JsonDocument.Parse(rows.Single()).RootElement.Clone();
    }

    [Fact]
    public async Task TwoWorkers_CompetingClaim_OnlyOneWins()
    {
        // "Два competing claim" из фидбэка: FOR UPDATE SKIP LOCKED должен
        // гарантировать, что READY job достаётся ровно одному из двух
        // одновременно вызвавших claim_jobs воркеров, а не обоим.
        await using var setupConnection = new NpgsqlConnection(_fixture.SuperuserConnectionString);
        await setupConnection.OpenAsync();
        var (jobId, _, _) = await CreateReadyJobAsync(setupConnection, "competing");

        await using var connectionA = await OpenAsWorkflowWorkerAsync();
        await using var connectionB = await OpenAsWorkflowWorkerAsync();

        var results = await Task.WhenAll(
            ClaimOneAsync(connectionA, "worker-a"),
            ClaimOneAsync(connectionB, "worker-b"));

        var claimed = results.Where(r => r.ValueKind != JsonValueKind.Undefined).ToList();
        Assert.Single(claimed);
        Assert.Equal(jobId, claimed[0].GetProperty("job_id").GetGuid());

        var jobRow = await setupConnection.QuerySingleAsync(
            "SELECT state, lease_owner, lease_version FROM workflow.workflow_job WHERE job_id = @jobId",
            new { jobId });
        Assert.Equal("LEASED", (string)jobRow.state);
        Assert.Equal(1L, (long)jobRow.lease_version);
    }

    [Fact]
    public async Task ExpiredLease_ReclaimedByAnotherWorker_PreservesJobAndExecutionId_NewAttempt()
    {
        // Симулируем "worker упал после claim": лизинг искусственно
        // "протухает" (это делает тест напрямую, а не сам workflow_worker —
        // у него и нет UPDATE на workflow_job), после чего второй worker
        // должен получить это же задание через claim_jobs.
        await using var admin = new NpgsqlConnection(_fixture.SuperuserConnectionString);
        await admin.OpenAsync();
        var (jobId, executionId, _) = await CreateReadyJobAsync(admin, "expired-lease");

        await using var workerA = await OpenAsWorkflowWorkerAsync();
        var first = await ClaimOneAsync(workerA, "worker-a");
        Assert.NotEqual(JsonValueKind.Undefined, first.ValueKind);
        var firstAttemptId = first.GetProperty("attempt_id").GetGuid();

        await admin.ExecuteAsync(
            "UPDATE workflow.workflow_job SET lease_until = now() - interval '1 second' WHERE job_id = @jobId",
            new { jobId });

        await using var workerB = await OpenAsWorkflowWorkerAsync();
        var second = await ClaimOneAsync(workerB, "worker-b");
        Assert.NotEqual(JsonValueKind.Undefined, second.ValueKind);

        // jobId/executionId — те же самые (идентичность задания и ключ
        // идемпотентности предметного эффекта не меняются при reclaim).
        Assert.Equal(jobId, second.GetProperty("job_id").GetGuid());
        Assert.Equal(executionId, second.GetProperty("execution_id").GetGuid());
        // attemptId — новый, lease_version вырос.
        Assert.NotEqual(firstAttemptId, second.GetProperty("attempt_id").GetGuid());
        Assert.Equal(2L, second.GetProperty("lease_version").GetInt64());

        var jobRow = await admin.QuerySingleAsync(
            "SELECT state, lease_owner, lease_version FROM workflow.workflow_job WHERE job_id = @jobId",
            new { jobId });
        Assert.Equal("LEASED", (string)jobRow.state);
        Assert.Equal("worker-b", (string)jobRow.lease_owner);
        Assert.Equal(2L, (long)jobRow.lease_version);

        var staleAttempts = await admin.QuerySingleAsync<int>(
            "SELECT count(*) FROM workflow.task_attempt WHERE attempt_id = @firstAttemptId AND status = 'STALE'",
            new { firstAttemptId });
        Assert.Equal(1, staleAttempts);
    }

    [Fact]
    public async Task StaleFinish_RejectedWithLeaseStale_DoesNotOverwriteReclaimedJob()
    {
        // "Устаревший finish" из фидбэка: worker-a "проснулся" после того,
        // как его лизинг уже был реклеймлен worker-b, и пытается
        // зафиксировать результат старым owner/leaseVersion — должен
        // получить workflow.lease_stale, не тронув состояние, которое уже
        // принадлежит worker-b.
        await using var admin = new NpgsqlConnection(_fixture.SuperuserConnectionString);
        await admin.OpenAsync();
        var (jobId, _, _) = await CreateReadyJobAsync(admin, "stale-finish");

        await using var workerA = await OpenAsWorkflowWorkerAsync();
        var first = await ClaimOneAsync(workerA, "worker-a");
        var staleOwner = "worker-a";
        var staleLeaseVersion = first.GetProperty("lease_version").GetInt64();

        await admin.ExecuteAsync(
            "UPDATE workflow.workflow_job SET lease_until = now() - interval '1 second' WHERE job_id = @jobId",
            new { jobId });

        await using var workerB = await OpenAsWorkflowWorkerAsync();
        var second = await ClaimOneAsync(workerB, "worker-b");
        var currentLeaseVersion = second.GetProperty("lease_version").GetInt64();

        // Устаревший finish от лица worker-a со старым lease_version.
        await using var staleFinishConnection = await OpenAsWorkflowWorkerAsync();
        var staleFinishResultJson = await staleFinishConnection.ExecuteScalarAsync<string>(
            "SELECT workflow.finish_job(@jobId, @owner, @leaseVersion, 'APPLIED', '{}'::jsonb)::text",
            new { jobId, owner = staleOwner, leaseVersion = staleLeaseVersion });
        var staleFinishResult = JsonDocument.Parse(staleFinishResultJson!).RootElement;

        Assert.Equal("error", staleFinishResult.GetProperty("status").GetString());
        Assert.Equal("workflow.lease_stale", staleFinishResult.GetProperty("code").GetString());

        // Состояние по-прежнему принадлежит worker-b с его lease_version —
        // отклонённый finish ничего не перезаписал.
        var jobRow = await admin.QuerySingleAsync(
            "SELECT state, lease_owner, lease_version FROM workflow.workflow_job WHERE job_id = @jobId",
            new { jobId });
        Assert.Equal("LEASED", (string)jobRow.state);
        Assert.Equal("worker-b", (string)jobRow.lease_owner);
        Assert.Equal(currentLeaseVersion, (long)jobRow.lease_version);
    }

    [Fact]
    public async Task CrashBetweenActionAndFinish_RecoveredByAnotherWorker_ExactlyOneEffect()
    {
        // "Остановка между действием и подтверждением" из фидбэка: worker-a
        // успевает вызвать action (эффект физически пишется в БД), но
        // "падает" до finish_job. Worker-b реклеймит job, тоже вызывает
        // action (тем же executionId как requestId) и уже успешно
        // завершает через finish_job. Итог должен быть: ровно один
        // предметный эффект в training.canary_log, несмотря на то что
        // api.invoke был вызван дважды.
        await using var admin = new NpgsqlConnection(_fixture.SuperuserConnectionString);
        await admin.OpenAsync();
        var (jobId, executionId, _) = await CreateReadyJobAsync(admin, "crash-recovery");

        await using var workerA = await OpenAsWorkflowWorkerAsync();
        var first = await ClaimOneAsync(workerA, "worker-a");

        // Первая попытка вызывает action и "падает" до finish_job — сам
        // effect (в отличие от production-кода worker'а) тут не в одной
        // транзакции с claim, поэтому коммитится независимо от дальнейшей
        // судьбы попытки — это и воспроизводит "успел выполнить действие,
        // не успел подтвердить".
        var context = JsonSerializer.Serialize(new
        {
            requestId = executionId.ToString(),
            principal = "workflow-worker",
            scopes = new[] { "workflow:execute" }
        });
        await workerA.ExecuteAsync(
            "SELECT api.invoke('training', 'canary', 1, @context::jsonb, '{\"value\": 111}'::jsonb)",
            new { context });

        await admin.ExecuteAsync(
            "UPDATE workflow.workflow_job SET lease_until = now() - interval '1 second' WHERE job_id = @jobId",
            new { jobId });

        await using var workerB = await OpenAsWorkflowWorkerAsync();
        var second = await ClaimOneAsync(workerB, "worker-b");
        var secondLeaseVersion = second.GetProperty("lease_version").GetInt64();

        await workerB.ExecuteAsync(
            "SELECT api.invoke('training', 'canary', 1, @context::jsonb, '{\"value\": 222}'::jsonb)",
            new { context });

        var finishResultJson = await workerB.ExecuteScalarAsync<string>(
            "SELECT workflow.finish_job(@jobId, 'worker-b', @leaseVersion, 'APPLIED', '{}'::jsonb)::text",
            new { jobId, leaseVersion = secondLeaseVersion });
        var finishResult = JsonDocument.Parse(finishResultJson!).RootElement;
        Assert.Equal("ok", finishResult.GetProperty("status").GetString());

        var effectCount = await admin.QuerySingleAsync<int>(
            "SELECT count(*) FROM training.canary_log WHERE request_id = @executionId",
            new { executionId = executionId.ToString() });
        Assert.Equal(1, effectCount);

        // Эффект должен быть от ПЕРВОГО вызова (value: 111) — ON CONFLICT
        // DO NOTHING не даёт второму вызову перезаписать уже
        // зафиксированный результат.
        var storedValue = await admin.QuerySingleAsync<int>(
            "SELECT (value #>> '{}')::int FROM training.canary_log WHERE request_id = @executionId",
            new { executionId = executionId.ToString() });
        Assert.Equal(111, storedValue);

        var jobRow = await admin.QuerySingleAsync<string>(
            "SELECT state FROM workflow.workflow_job WHERE job_id = @jobId", new { jobId });
        Assert.Equal("SUCCEEDED", jobRow);
    }
}
