using System.Text.Json;

namespace Api;

/// <summary>
/// Закрытый failpoint-профиль недели 4 для компонента api
/// (docs/07-autocheck-outline.md, "Детерминированные failpoints"):
///   after_inbox_saved      — receipt.accept: ПОСЛЕ commit Inbox, receipt и idempotency
///                            result, ДО HTTP-ответа;
///   after_manual_decision  — workflow.manual: ПОСЛЕ выполнения action и валидации
///                            результата, ДО commit общей transaction (остановка
///                            контейнера => rollback решения, перехода и job).
/// Активен только при COURSE_TEST_PROFILE=1 и совпадении COURSE_FAILPOINT. В production
/// profile HitAsync — no-op; публичного endpoint для включения нет.
/// </summary>
public static class FailpointGate
{
    private static readonly bool TestProfile =
        Environment.GetEnvironmentVariable("COURSE_TEST_PROFILE") == "1";

    private static readonly string? Target =
        string.IsNullOrEmpty(Environment.GetEnvironmentVariable("COURSE_FAILPOINT"))
            ? null
            : Environment.GetEnvironmentVariable("COURSE_FAILPOINT");

    private static readonly string InstanceId =
        Environment.GetEnvironmentVariable("COURSE_INSTANCE_ID") ?? "api";

    public static async Task HitAsync(string name)
    {
        if (!TestProfile || Target != name) return;

        // Ровно одна JSON-строка в stdout, без обёртки логгера.
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            @event = "failpoint.reached",
            name,
            instanceId = InstanceId
        }));
        Console.Out.Flush();

        // Блокировка до принудительной остановки контейнера. Без CancellationToken запроса:
        // разрыв клиентского соединения не должен снимать блокировку до/после commit.
        await Task.Delay(Timeout.Infinite);
    }
}
