using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;
using VendorFlow.Infrastructure.Persistence;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1")]
public class ApprovalsController(IDb db, ICurrentUser me) : ControllerBase
{
    /// <summary>Approval inbox. tab = pending | approved | rejected | delegated.</summary>
    [RequirePermission(Permissions.ApprovalsView), HttpGet("approvals")]
    public async Task<IActionResult> Inbox([FromQuery] string? tab, [FromQuery] string? sort, [FromQuery] int page = 1,
        [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_approval_inbox", new
        {
            p_tenant_id = me.TenantId, p_user_id = me.UserId, p_tab = tab ?? "pending", p_sort = sort ?? "oldest",
            p_page = page, p_page_size = pageSize
        }, ct));

    [Authorize, HttpGet("approvals/pending-count")]
    public async Task<IActionResult> PendingCount(CancellationToken ct) =>
        Ok(new { count = await db.ScalarAsync<int>("fn_approval_pending_count", new { p_tenant_id = me.TenantId, p_user_id = me.UserId }, ct) });

    [RequirePermission(Permissions.ApprovalsView), HttpGet("approvals/{id:guid}")]
    public async Task<IActionResult> Get(Guid id, CancellationToken ct) =>
        await db.JsonAsync("fn_approval_get", new { p_tenant_id = me.TenantId, p_request_id = id }, ct) is { } found ? Ok(found) : NotFound();

    [RequirePermission(Permissions.ApprovalsDecide), HttpPost("approvals/{id:guid}/approve")]
    public Task<IActionResult> Approve(Guid id, DecisionRequest req, CancellationToken ct) => Decide(id, "approve", req, ct);

    [RequirePermission(Permissions.ApprovalsDecide), HttpPost("approvals/{id:guid}/reject")]
    public Task<IActionResult> Reject(Guid id, DecisionRequest req, CancellationToken ct) => Decide(id, "reject", req, ct);

    [RequirePermission(Permissions.ApprovalsDecide), HttpPost("approvals/{id:guid}/request-changes")]
    public Task<IActionResult> RequestChanges(Guid id, DecisionRequest req, CancellationToken ct) => Decide(id, "return", req, ct);

    private async Task<IActionResult> Decide(Guid id, string decision, DecisionRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_approval_decide", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_request_id = id, p_decision = decision,
            p_comment = req.Comment, p_expected_version = req.ExpectedVersion
        }, ct));

    // ---- rules --------------------------------------------------------------------------------

    [RequirePermission(Permissions.ApprovalsManage), HttpGet("approval-rules")]
    public async Task<IActionResult> Rules(CancellationToken ct) => Ok(await db.JsonAsync("fn_approval_rule_list", new { p_tenant_id = me.TenantId }, ct));

    [RequirePermission(Permissions.ApprovalsManage), HttpPost("approval-rules")]
    public async Task<IActionResult> SaveRule(ApprovalRuleRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_approval_rule_save", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.ApprovalsManage), HttpDelete("approval-rules/{id:guid}")]
    public async Task<IActionResult> DeleteRule(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_approval_rule_delete", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id }, ct));

    // ---- delegation and department managers --------------------------------------------------------

    [RequirePermission(Permissions.ApprovalsDecide), HttpGet("delegations")]
    public async Task<IActionResult> Delegations(CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_delegation_list", new { p_tenant_id = me.TenantId, p_user_id = me.UserId }, ct));

    [RequirePermission(Permissions.ApprovalsDecide), HttpPost("delegations")]
    public async Task<IActionResult> CreateDelegation(DelegationRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_delegation_save", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.ApprovalsDecide), HttpDelete("delegations/{id:guid}")]
    public async Task<IActionResult> CancelDelegation(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_delegation_cancel", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id }, ct));

    [RequirePermission(Permissions.ApprovalsManage), HttpGet("departments")]
    public async Task<IActionResult> Departments(CancellationToken ct) => Ok(await db.JsonAsync("fn_department_list", new { p_tenant_id = me.TenantId }, ct));

    [RequirePermission(Permissions.ApprovalsManage), HttpPut("departments/{id:guid}/manager")]
    public async Task<IActionResult> SetManager(Guid id, SetManagerRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_department_set_manager", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_department_id = id, p_user_id = req.UserId }, ct));
}
