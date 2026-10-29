using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1/system")]
public class SystemController(ICurrentUser user) : ControllerBase
{
    /// <summary>Returns who the token belongs to (used by clients to check their session).</summary>
    [Authorize, HttpGet("whoami")]
    public IActionResult WhoAmI() => Ok(new { userId = user.UserId, tenantId = user.TenantId, email = user.Email });
}
