using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Domain;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1")]
public class AuditController(IDb db, ICurrentUser me) : ControllerBase
{
    /// <summary>Audit trail of the current tenant, newest first.</summary>
    [RequirePermission(Permissions.AuditView)]
    [HttpGet("audit")]
    public async Task<IActionResult> Audit([FromQuery] int page = 1, [FromQuery] int pageSize = 50, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_audit_list", new { p_tenant_id = me.TenantId, p_page = page, p_page_size = pageSize }, ct));
}
