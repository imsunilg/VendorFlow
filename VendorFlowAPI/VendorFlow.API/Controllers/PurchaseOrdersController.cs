using System.Text;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;
using VendorFlow.Infrastructure.Persistence;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1/purchase-orders")]
public class PurchaseOrdersController(IDb db, ICurrentUser me, IPoPdfGenerator pdf) : ControllerBase
{
    private object Ctx(Guid id) => new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id };

    [RequirePermission(Permissions.PoView), HttpGet]
    public async Task<IActionResult> List([FromQuery] string? status, [FromQuery] Guid? vendorId, [FromQuery] string? search,
        [FromQuery] string? sortBy, [FromQuery] string? sortDir, [FromQuery] int page = 1, [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_po_list", new
        {
            p_tenant_id = me.TenantId, p_status = status, p_vendor_id = vendorId, p_search = search, p_sort_by = sortBy,
            p_sort_dir = sortDir, p_page = page, p_page_size = pageSize
        }, ct));

    [RequirePermission(Permissions.PoView), HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] string? status, [FromQuery] string? search, CancellationToken ct)
    {
        var res = await db.JsonAsync("fn_po_list", new
        {
            p_tenant_id = me.TenantId, p_status = status, p_vendor_id = (Guid?)null, p_search = search, p_sort_by = "number",
            p_sort_dir = "asc", p_page = 1, p_page_size = 200
        }, ct);
        var csv = CsvExport.FromItems(res!["items"]!.AsArray(), [("PO number", "number"), ("Vendor", "vendorName"), ("Order date", "orderDate"),
            ("Expected delivery", "expectedDelivery"), ("Status", "status"), ("Receipt %", "receiptPct"), ("Total", "total")]);
        return File(Encoding.UTF8.GetBytes(csv), "text/csv", "purchase-orders.csv");
    }

    [RequirePermission(Permissions.PoView), HttpGet("{id:guid}")]
    public async Task<IActionResult> Get(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_get", new { p_tenant_id = me.TenantId, p_id = id }, ct));

    [RequirePermission(Permissions.PoView), HttpGet("{id:guid}/pdf")]
    public async Task<IActionResult> Pdf(Guid id, CancellationToken ct)
    {
        var data = await db.JsonAsync("fn_po_pdf_data", new { p_tenant_id = me.TenantId, p_id = id }, ct);
        await db.ExecuteAsync("sp_audit", new
        {
            p_tenant_id = me.TenantId, p_user_id = me.UserId, p_action = "po.pdf_downloaded", p_entity_type = "purchase_order",
            p_entity_id = id, p_details = (System.Text.Json.Nodes.JsonNode?)null
        }, ct);
        return File(pdf.Generate(data!), "application/pdf", $"{data!["po"]!["number"]}.pdf");
    }

    [RequirePermission(Permissions.PoCreate), HttpPost]
    public async Task<IActionResult> Create(PoRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_create", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.PoCreate), HttpPost("from-requisition/{requisitionId:guid}")]
    public async Task<IActionResult> FromRequisition(Guid requisitionId, PoFromRequisitionRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_create_from_requisition", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_requisition_id = requisitionId, p_data = Db.ToSnakeJson(req)
        }, ct));

    [RequirePermission(Permissions.PoCreate), HttpPost("from-rfq/{rfqId:guid}")]
    public async Task<IActionResult> FromRfq(Guid rfqId, PoFromRfqRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_create_from_rfq", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_rfq_id = rfqId, p_data = Db.ToSnakeJson(req)
        }, ct));

    [RequirePermission(Permissions.PoCreate), HttpPut("{id:guid}")]
    public async Task<IActionResult> Update(Guid id, PoRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_update", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.PoApprove), HttpPost("{id:guid}/submit")]
    public async Task<IActionResult> Submit(Guid id, CancellationToken ct) => Ok(await db.JsonAsync("fn_po_submit", Ctx(id), ct));

    [RequirePermission(Permissions.PoIssue), HttpPost("{id:guid}/issue")]
    public async Task<IActionResult> Issue(Guid id, CancellationToken ct) => Ok(await db.JsonAsync("fn_po_issue", Ctx(id), ct));

    [RequirePermission(Permissions.PoIssue), HttpPost("{id:guid}/acknowledge")]
    public async Task<IActionResult> Acknowledge(Guid id, CancellationToken ct) => Ok(await db.JsonAsync("fn_po_acknowledge", Ctx(id), ct));

    [RequirePermission(Permissions.PoCreate), HttpPost("{id:guid}/revisions")]
    public async Task<IActionResult> Revise(Guid id, CommentRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_create_revision", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_reason = req.Comment }, ct));

    [RequirePermission(Permissions.PoIssue), HttpPost("{id:guid}/hold")]
    public async Task<IActionResult> Hold(Guid id, CommentRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_hold", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_comment = req.Comment }, ct));

    [RequirePermission(Permissions.PoIssue), HttpPost("{id:guid}/resume")]
    public async Task<IActionResult> Resume(Guid id, CancellationToken ct) => Ok(await db.JsonAsync("fn_po_resume", Ctx(id), ct));

    [RequirePermission(Permissions.PoIssue), HttpPost("{id:guid}/close")]
    public async Task<IActionResult> Close(Guid id, CommentRequest? req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_close", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_comment = req?.Comment }, ct));

    [RequirePermission(Permissions.PoCreate), HttpPost("{id:guid}/cancel")]
    public async Task<IActionResult> Cancel(Guid id, CommentRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_po_cancel", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_comment = req.Comment }, ct));
}
