namespace Cli;

/// <summary>
/// Раньше все команды cli подключались одной и той же строкой из
/// ConnectionStrings__CourseDb — фактически суперпользователем Postgres.
/// Теперь у cli две отдельные роли: course_migrator (только "migration
/// apply") и course_publisher (все "action ..."/"flow ..." команды,
/// кроме чисто локальной "action validate", которая вообще не трогает БД).
/// Обе роли создаются заранее init-скриптом postgres-init/00-bootstrap-roles.sh —
/// см. его комментарии про то, почему это не может быть частью
/// checksummed-миграций (курица и яйцо: миграции применяет cli, а
/// значит cli должен уметь подключиться ДО первой миграции).
/// </summary>
public static class ConnectionFactory
{
    public static string Build(string role, string passwordEnvVar)
    {
        var host = Environment.GetEnvironmentVariable("POSTGRES_HOST") ?? "postgres";
        var port = Environment.GetEnvironmentVariable("POSTGRES_PORT") ?? "5432";
        var database = Environment.GetEnvironmentVariable("POSTGRES_DB") ?? "course";
        var password = Environment.GetEnvironmentVariable(passwordEnvVar)
            ?? throw new InvalidOperationException($"{passwordEnvVar} is not set");

        return $"Host={host};Port={port};Database={database};Username={role};Password={password}";
    }

    public static string Migrator() => Build("course_migrator", "COURSE_MIGRATOR_PASSWORD");

    public static string Publisher() => Build("course_publisher", "COURSE_PUBLISHER_PASSWORD");
}
