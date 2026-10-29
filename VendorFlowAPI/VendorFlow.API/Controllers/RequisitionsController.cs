using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;
using VendorFlow.Infrastructure.Persistence;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1/requisitions")]
public class RequisitionsController(IDb db, ICurrentUser me) : ControllerBase
{
    [RequirePermission(Permissions.RequisitionsView), HttpGet]
    public async Task<IActionResult> List([FromQuery] string? scope, [FromQuery] string? status, [FromQuery] string? search,
        [FromQuery] Guid? departmentId, [FromQuery] DateOnly? dateFrom, [FromQuery] DateOnly? dateTo,
        [FromQuery] string? sortBy, [FromQuery] string? sortDir, [FromQuery] int page = 1, [FromQuery] int pageSize = 20,
        CancellationToken ct = default) =>
        Ok(await ListAsync(scope, status, search, departmentId, dateFrom, dateTo, sortBy, sortDir, page, pageSize, ct));

    [RequirePermission(Permissions.RequisitionsView), HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] string? scope, [FromQuery] string? status, [FromQuery] string? search, CancellationToken ct)
    {
        var res = await ListAsync(scope, status, search, null, null, null, "number", "asc", 1, 200, ct);
        var csv = CsvExport.FromItems(res!["items"]!.AsArray(), [("Number", "number"), ("Title", "title"), ("Department", "departmentName"),
            ("Cost centre", "costCentreCode"), ("Required by", "requiredDate"), ("Amount", "totalAmount"), ("Status", "status")]);
        return File(Encoding.UTF8.GetBytes(csv), "text/csv", "requisitions.csv");
    }

    [RequirePermission(Permissions.RequisitionsView), HttpGet("{id:guid}")]
    public async Task<IActionResult> Get(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_requisition_get", new { p_tenant_id = me.TenantId, p_id = id }, ct));

    [RequirePermission(Permissions.RequisitionsCreate), HttpPost]
    public async Task<IActionResult> Create(RequisitionRequest req, CancellationToken ct) => Ok(await Save(null, req, ct));

    [RequirePermission(Permissions.RequisitionsCreate), HttpPut("{id:guid}")]
    public async Task<IActionResult> Update(Guid id, RequisitionRequest req, CancellationToken ct) => Ok(await Save(id, req, ct));

    [RequirePermission(Permissions.RequisitionsCreate), HttpPost("{id:guid}/submit")]
    public async Task<IActionResult> Submit(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_requisition_submit", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id }, ct));

    [RequirePermission(Permissions.RequisitionsCreate), HttpPost("{id:guid}/cancel")]
    public async Task<IActionResult> Cancel(Guid id, CommentRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_requisition_cancel", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_comment = req.Comment,
            p_override = me.HasPermission(Permissions.ApprovalsManage)
        }, ct));

    private Task<JsonNode?> Save(Guid? id, RequisitionRequest req, CancellationToken ct) =>
        db.JsonAsync("fn_requisition_save", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_data = Db.ToSnakeJson(req) }, ct);

    private Task<JsonNode?> ListAsync(string? scope, string? status, string? search, Guid? departmentId, DateOnly? from, DateOnly? to,
        string? sortBy, string? sortDir, int page, int pageSize, CancellationToken ct) =>
        db.JsonAsync("fn_requisition_list", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_scope = scope ?? "all", p_status = status, p_search = search,
            p_department_id = departmentId, p_date_from = from, p_date_to = to,
            p_sort_by = sortBy, p_sort_dir = sortDir, p_page = page, p_page_size = pageSize
        }, ct);
}
