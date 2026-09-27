using Microsoft.AspNetCore.Mvc;

namespace Gateway.Controllers
{
    [ApiController]
    [Route("health")]
    public class HealthController : ControllerBase
    {
        // Неделя 4: observability-контракт фиксирует тело {"status":"live"} —
        // раньше отдавали пустой 200 (Ok()). gateway живой независимо от
        // того, жив ли api (см. комментарий в Gateway/Program.cs про
        // literal route против YARP catch-all).
        [HttpGet("live")]
        public IActionResult GetHealthLive()
        {
            return Ok(new { status = "live" });
        }
    }
}
