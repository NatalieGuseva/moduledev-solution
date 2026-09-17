namespace Workflow.Worker;

/// <summary>Строка, возвращаемая workflow.claim_jobs — один в один с его RETURNS TABLE.</summary>
public class ClaimedJob
{
    public Guid JobId { get; set; }
    public Guid ExecutionId { get; set; }
    public Guid AttemptId { get; set; }
    public long LeaseVersion { get; set; }
    public Guid ProcessId { get; set; }
    public Guid StepInstanceId { get; set; }
    public string ActionModule { get; set; } = "";
    public string ActionName { get; set; } = "";
    public int ActionVersion { get; set; }
    public string InputMapping { get; set; } = "{}";   // jsonb as text
    public string InputConstants { get; set; } = "{}"; // jsonb as text
    public int MaxAttempts { get; set; }
    public string DelaysMs { get; set; } = "[]";       // jsonb as text
    public int? TimeoutMs { get; set; }
    public string ProcessData { get; set; } = "{}";    // jsonb as text
    public string RequestSchema { get; set; } = "{}";
    public string ResponseSchema { get; set; } = "{}";
    public string Outcomes { get; set; } = "[]";
    public string RequiredPolicy { get; set; } = "[]";
}
