namespace Workflow.Worker;

/// <summary>
/// Конфигурация воркера из переменных окружения. Test profile переключает
/// значения по умолчанию на те, что требует 04_assignment.md ("Test profile:
/// lease 2 секунды, poll interval не более 100 ms"); production-профиль
/// консервативнее и тоже настраивается через переменные, а не хардкодится.
/// </summary>
public class WorkerConfig
{
    public required string ConnectionString { get; init; }
    public required string InstanceId { get; init; }
    public required bool TestProfile { get; init; }
    public required string? Failpoint { get; init; }
    public required int LeaseSeconds { get; init; }
    public required int PollIntervalMs { get; init; }
    public required int ClaimBatchSize { get; init; }
    public required int HealthPort { get; init; }

    public static WorkerConfig FromEnvironment()
    {
        var testProfile = Environment.GetEnvironmentVariable("COURSE_TEST_PROFILE") == "1";

        return new WorkerConfig
        {
            ConnectionString = Environment.GetEnvironmentVariable("ConnectionStrings__CourseDb")
                ?? throw new InvalidOperationException("ConnectionStrings__CourseDb is not set"),
            InstanceId = Environment.GetEnvironmentVariable("COURSE_INSTANCE_ID")
                ?? throw new InvalidOperationException("COURSE_INSTANCE_ID is not set (lease owner identity, e.g. 'worker-a')"),
            TestProfile = testProfile,
            Failpoint = Environment.GetEnvironmentVariable("COURSE_FAILPOINT"),
            LeaseSeconds = GetInt("COURSE_LEASE_SECONDS", testProfile ? 2 : 30),
            PollIntervalMs = GetInt("COURSE_POLL_INTERVAL_MS", testProfile ? 100 : 1000),
            ClaimBatchSize = GetInt("COURSE_CLAIM_BATCH_SIZE", 5),
            // Неделя 4: worker-a/worker-b в одном контейнерном namespace
            // каждый, порт не пересекается между ними; дефолт отдельный от
            // dispatcher(8090)/reconciler(8091), чтобы при желании поднять
            // всё на одном хосте без docker тоже не было конфликта.
            HealthPort = GetInt("COURSE_HEALTH_PORT", 8092)
        };
    }

    private static int GetInt(string name, int fallback)
    {
        var raw = Environment.GetEnvironmentVariable(name);
        return int.TryParse(raw, out var value) ? value : fallback;
    }
}
