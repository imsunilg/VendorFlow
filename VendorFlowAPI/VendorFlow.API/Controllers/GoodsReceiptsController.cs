using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;
using VendorFlow.Infrastructure.Persistence;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1")]
public class GoodsReceiptsController(IDb db, ICurrentUser me) : ControllerBase
{
    [RequirePermission(Permissions.GrnView), HttpGet("goods-receipts")]
    public async Task<IActionResult> List([FromQuery] Guid? poId, [FromQuery] string? search, [FromQuery] int page = 1,
        [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_grn_list", new { p_tenant_id = me.TenantId, p_po_id = poId, p_search = search, p_page = page, p_page_size = pageSize }, ct));

    [RequirePermission(Permissions.GrnView), HttpGet("goods-receipts/{id:guid}")]
    public async Task<IActionResult> Get(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_grn_get", new { p_tenant_id = me.TenantId, p_id = id }, ct));

    /// <summary>Posts a receipt against a purchase order in one transaction.</summary>
    [RequirePermission(Permissions.GrnRecord), HttpPost("purchase-orders/{poId:guid}/receipts")]
    public async Task<IActionResult> Post(Guid poId, GrnRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_grn_post", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_po_id = poId, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.GrnRecord), HttpPost("goods-receipts/{id:guid}/cancel")]
    public async Task<IActionResult> Cancel(Guid id, CommentRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_grn_cancel", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_comment = req.Comment }, ct));
}
