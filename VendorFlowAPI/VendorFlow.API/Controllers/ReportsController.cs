using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Domain;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1")]
public class ReportsController(IDb db, ICurrentUser me) : ControllerBase
{
    /// <summary>KPI cards, monthly trend, department spend, attention list and expiring documents.</summary>
    [RequirePermission(Permissions.ReportsView), HttpGet("dashboard")]
    public async Task<IActionResult> Dashboard(CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_dashboard", new { p_tenant_id = me.TenantId, p_user_id = me.UserId }, ct));

    /// <summary>Small summary for every signed-in user (used by the mobile home screen).</summary>
    [Authorize, HttpGet("dashboard/summary")]
    public async Task<IActionResult> Summary(CancellationToken ct)
    {
        var pending = await db.ScalarAsync<int>("fn_approval_pending_count", new { p_tenant_id = me.TenantId, p_user_id = me.UserId }, ct);
        if (!me.HasPermission(Permissions.ReportsView)) return Ok(new { pendingApprovals = pending });

        var d = await db.JsonAsync("fn_dashboard", new { p_tenant_id = me.TenantId, p_user_id = me.UserId }, ct);
        return Ok(new
        {
            pendingApprovals = pending,
            openPoAmount = (await db.JsonAsync("fn_po_list", new
            {
                p_tenant_id = me.TenantId, p_status = (string?)null, p_vendor_id = (Guid?)null, p_search = (string?)null, p_sort_by = (string?)null,
                p_sort_dir = (string?)null, p_page = 1, p_page_size = 1
            }, ct))!["stats"]!["open"]!["amount"]!.GetValue<decimal>(),
            overdueInvoices = d!["kpis"]!["outstandingPayments"]!["overdueCount"]!.GetValue<int>(),
            expiringDocuments = d["kpis"]!["expiringDocuments"]!.GetValue<int>()
        });
    }

    [RequirePermission(Permissions.ReportsView), HttpGet("reports")]
    public async Task<IActionResult> Catalog(CancellationToken ct) => Ok(await db.JsonAsync("fn_report_catalog", null, ct));

    [RequirePermission(Permissions.ReportsView), HttpGet("reports/{name}")]
    public async Task<IActionResult> Run(string name, [FromQuery] DateOnly? from, [FromQuery] DateOnly? to, [FromQuery] string? groupBy,
        [FromQuery] int? days, CancellationToken ct) => Ok(await RunAsync(name, from, to, groupBy, days, ct));

    [RequirePermission(Permissions.ReportsView), HttpGet("reports/{name}/export")]
    public async Task<IActionResult> Export(string name, [FromQuery] DateOnly? from, [FromQuery] DateOnly? to, [FromQuery] string? groupBy,
        [FromQuery] int? days, CancellationToken ct)
    {
        var report = await RunAsync(name, from, to, groupBy, days, ct);
        var columns = report!["columns"]!.AsArray().Select(c => (c!["label"]!.GetValue<string>(), c["key"]!.GetValue<string>())).ToArray();
        var csv = CsvExport.FromItems(report["rows"]!.AsArray(), columns);
        await db.ExecuteAsync("sp_audit", new
        {
            p_tenant_id = me.TenantId, p_user_id = me.UserId, p_action = "report.exported", p_entity_type = (string?)null, p_entity_id = (Guid?)null,
            p_details = (JsonNode?)new JsonObject { ["report"] = name }
        }, ct);
        return File(Encoding.UTF8.GetBytes(csv), "text/csv", $"{name}.csv");
    }

    private Task<JsonNode?> RunAsync(string name, DateOnly? from, DateOnly? to, string? groupBy, int? days, CancellationToken ct) =>
        db.JsonAsync("fn_report_run", new
        {
            p_tenant_id = me.TenantId, p_report = name, p_from = from, p_to = to, p_group_by = groupBy, p_days = days ?? 60
        }, ct);

    /// <summary>Runs the notification checks (expiry, due dates, deadlines) now, for the caller's organization only.</summary>
    [RequirePermission(Permissions.SettingsManage), HttpPost("notifications/run-checks")]
    public async Task<IActionResult> RunChecks(CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_job_run_all", new { p_tenant_id = me.TenantId }, ct));
}
