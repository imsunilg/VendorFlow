using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1/notifications")]
[Authorize]
public class NotificationsController(IDb db, ICurrentUser me) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> List([FromQuery] bool unreadOnly = false, [FromQuery] int page = 1, [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_notification_list", new
        {
            p_tenant_id = me.TenantId, p_user_id = me.UserId, p_unread_only = unreadOnly, p_page = page, p_page_size = pageSize
        }, ct));

    [HttpPost("{id:guid}/read")]
    public async Task<IActionResult> MarkRead(Guid id, CancellationToken ct)
    {
        await db.ExecuteAsync("sp_notification_mark_read", new { p_tenant_id = me.TenantId, p_user_id = me.UserId, p_id = id }, ct);
        return NoContent();
    }

    [HttpPost("read-all")]
    public async Task<IActionResult> MarkAllRead(CancellationToken ct)
    {
        await db.ExecuteAsync("sp_notification_mark_read", new { p_tenant_id = me.TenantId, p_user_id = me.UserId, p_id = (Guid?)null }, ct);
        return NoContent();
    }
}
