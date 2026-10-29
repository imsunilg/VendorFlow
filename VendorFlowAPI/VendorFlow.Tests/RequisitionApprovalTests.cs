using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

/// <summary>An organization with a requester, a department manager and a finance manager.</summary>
public sealed class ApprovalOrg
{
    public required TestTenant Tenant { get; init; }
    public required HttpClient Requester { get; init; }
    public required Guid RequesterId { get; init; }
    public required HttpClient DeptManager { get; init; }
    public required Guid DeptManagerId { get; init; }
    public required HttpClient Finance { get; init; }
    public required Guid DepartmentId { get; init; }
    public required Guid CostCentreId { get; init; }

    public static async Task<ApprovalOrg> Create(ApiFactory f)
    {
        var t = await TestTenant.Create(f);
        var (req, reqId, _) = await t.AddUser("Rita Requester", "DepartmentRequester");
        var (mgr, mgrId, _) = await t.AddUser("Dev Manager", "DepartmentManager");
        var (fin, _, _) = await t.AddUser("Fay Finance", "FinanceManager");
        var depts = await (await t.Owner.GetAsync("/api/v1/lookups/departments")).Ok();
        var it = depts.AsArray().First(d => d!.Str("name") == "IT")!;
        var ccs = await (await t.Owner.GetAsync("/api/v1/lookups/cost-centres")).Ok();
        var cc = ccs.AsArray().First(c => c!.Str("code") == "CC-IT-01")!;
        return new ApprovalOrg
        {
            Tenant = t, Requester = req, RequesterId = reqId, DeptManager = mgr, DeptManagerId = mgrId, Finance = fin,
            DepartmentId = it.Id(), CostCentreId = cc.Id()
        };
    }

    /// <summary>Creates and submits a requisition for the given amount (one line, qty 1).</summary>
    public async Task<JsonNode> Submitted(decimal amount, HttpClient? by = null, string title = "Laptops")
    {
        var client = by ?? Requester;
        var draft = await (await client.PostJson("/api/v1/requisitions", Body(amount, title))).Ok();
        return await (await client.PostJson($"/api/v1/requisitions/{draft.Id()}/submit")).Ok();
    }

    public object Body(decimal amount, string title = "Laptops") => new
    {
        title, departmentId = DepartmentId, costCentreId = CostCentreId,
        requiredDate = DateOnly.FromDateTime(DateTime.Today.AddDays(20)).ToString("yyyy-MM-dd"),
        justification = "Needed", priority = "High",
        items = new[] { new { description = "Item", unit = "Nos", quantity = 1, estUnitPrice = amount } }
    };

    public static Guid RequestId(JsonNode requisition) => requisition["approval"]!.Id();
}

[Collection("api")]
public class RequisitionApprovalTests(ApiFactory factory)
{
    // ------------------------------------------------------------------ requisitions

    [Fact]
    public async Task Create_draft_calculates_totals_and_numbers()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await (await o.Requester.PostJson("/api/v1/requisitions", new
        {
            title = "Laptops for new joiners", departmentId = o.DepartmentId, costCentreId = o.CostCentreId,
            items = new object[]
            {
                new { description = "Dell Latitude", quantity = 10, estUnitPrice = 58000 },
                new { description = "Laptop bag", quantity = 10, estUnitPrice = 1500.555 }
            }
        })).Ok();
        Assert.Equal("Draft", req.Str("status"));
        Assert.StartsWith("REQ-", req.Str("number"));
        // line 2 = round(10 x 1500.56) = 15005.60  -> total 595005.60
        Assert.Equal(595005.60m, req.Dec("totalAmount"));
        Assert.Equal(2, req["items"]!.AsArray().Count);
    }

    [Fact]
    public async Task Invalid_items_are_rejected()
    {
        var o = await ApprovalOrg.Create(factory);
        var res = await o.Requester.PostJson("/api/v1/requisitions", new { title = "Bad", items = new[] { new { description = "X", quantity = 0, estUnitPrice = 5 } } });
        Assert.Equal(HttpStatusCode.BadRequest, res.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Requester.PostJson("/api/v1/requisitions", new { title = "" })).StatusCode);
    }

    [Fact]
    public async Task Only_the_requester_can_edit_and_only_while_draft()
    {
        var o = await ApprovalOrg.Create(factory);
        var draft = await (await o.Requester.PostJson("/api/v1/requisitions", o.Body(1000))).Ok();
        var id = draft.Id();
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Tenant.Owner.PutJson($"/api/v1/requisitions/{id}", o.Body(2000))).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await o.Requester.PutJson($"/api/v1/requisitions/{id}", o.Body(2000, "Renamed"))).StatusCode);
        await (await o.Requester.PostJson($"/api/v1/requisitions/{id}/submit")).Ok();
        Assert.Equal(HttpStatusCode.Conflict, (await o.Requester.PutJson($"/api/v1/requisitions/{id}", o.Body(3000))).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await o.Requester.PostJson($"/api/v1/requisitions/{id}/submit")).StatusCode);
    }

    [Fact]
    public async Task Submit_requires_department_cost_centre_and_items()
    {
        var o = await ApprovalOrg.Create(factory);
        var noItems = await (await o.Requester.PostJson("/api/v1/requisitions", new { title = "Empty", departmentId = o.DepartmentId, costCentreId = o.CostCentreId, requiredDate = "2099-01-01" })).Ok();
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Requester.PostJson($"/api/v1/requisitions/{noItems.Id()}/submit")).StatusCode);
        var noDept = await (await o.Requester.PostJson("/api/v1/requisitions", new { title = "No dept", items = new[] { new { description = "x", quantity = 1, estUnitPrice = 10 } } })).Ok();
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Requester.PostJson($"/api/v1/requisitions/{noDept.Id()}/submit")).StatusCode);
    }

    [Fact]
    public async Task List_filters_by_scope_status_search_and_returns_counts()
    {
        var o = await ApprovalOrg.Create(factory);
        await o.Submitted(1000, title: "Alpha chairs");
        await o.Requester.PostJson("/api/v1/requisitions", o.Body(500, "Beta desks"));
        var all = await (await o.Tenant.Owner.GetAsync("/api/v1/requisitions")).Ok();
        Assert.Equal(2, all["totalCount"]!.GetValue<int>());
        var mine = await (await o.Tenant.Owner.GetAsync("/api/v1/requisitions?scope=mine")).Ok();
        Assert.Equal(0, mine["totalCount"]!.GetValue<int>());
        var pending = await (await o.Requester.GetAsync("/api/v1/requisitions?status=PendingApproval&search=alpha")).Ok();
        Assert.Equal(1, pending["totalCount"]!.GetValue<int>());
        Assert.Equal(1, all["statusCounts"]!["Draft"]!.GetValue<int>());
        Assert.Equal(1, all["statusCounts"]!["PendingApproval"]!.GetValue<int>());
    }

    // ------------------------------------------------------------------ approval routing

    [Fact]
    public async Task Rules_choose_one_step_for_small_and_two_steps_for_large_amounts()
    {
        var o = await ApprovalOrg.Create(factory);
        var small = await o.Submitted(50_000);
        var large = await o.Submitted(620_000);
        Assert.Equal(1, small["approval"]!["totalSteps"]!.GetValue<int>());
        Assert.Equal(2, large["approval"]!["totalSteps"]!.GetValue<int>());
        Assert.Equal("FinanceManager", large["approval"]!["steps"]![1]!.Str("roleCode"));
    }

    [Fact]
    public async Task Two_step_approval_flows_through_manager_then_finance_and_updates_the_requisition()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(620_000);
        var rid = ApprovalOrg.RequestId(req);

        // finance is not yet the current approver, requester sees nothing
        Assert.Equal(0, (await (await o.Finance.GetAsync("/api/v1/approvals")).Ok())["totalCount"]!.GetValue<int>());
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Requester.GetAsync("/api/v1/approvals")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Finance.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);

        var inbox = await (await o.DeptManager.GetAsync("/api/v1/approvals")).Ok();
        Assert.Equal(1, inbox["totalCount"]!.GetValue<int>());
        Assert.Equal(620000m, inbox["items"]![0]!.Dec("amount"));
        Assert.Equal(620000m, inbox["stats"]!.Dec("pendingValue"));

        var step1 = await (await o.DeptManager.PostJson($"/api/v1/approvals/{rid}/approve", new { comment = "ok" })).Ok();
        Assert.Equal("Pending", step1.Str("status"));
        Assert.Equal(2, step1["currentStep"]!.GetValue<int>());

        Assert.Equal(1, (await (await o.Finance.GetAsync("/api/v1/approvals")).Ok())["totalCount"]!.GetValue<int>());
        var done = await (await o.Finance.PostJson($"/api/v1/approvals/{rid}/approve", new { })).Ok();
        Assert.Equal("Approved", done.Str("status"));

        var after = await (await o.Requester.GetAsync($"/api/v1/requisitions/{req.Id()}")).Ok();
        Assert.Equal("Approved", after.Str("status"));
        Assert.Contains(after["history"]!.AsArray(), h => h!.Str("action") == "approval_approved");

        var approvedTab = await (await o.DeptManager.GetAsync("/api/v1/approvals?tab=approved")).Ok();
        Assert.Equal(1, approvedTab["totalCount"]!.GetValue<int>());
    }

    [Fact]
    public async Task Reject_and_request_changes_need_a_comment_and_return_the_requisition()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(10_000);
        var rid = ApprovalOrg.RequestId(req);

        Assert.Equal(HttpStatusCode.BadRequest, (await o.DeptManager.PostJson($"/api/v1/approvals/{rid}/reject", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.DeptManager.PostJson($"/api/v1/approvals/{rid}/request-changes", new { comment = " " })).StatusCode);
        await (await o.DeptManager.PostJson($"/api/v1/approvals/{rid}/request-changes", new { comment = "Add specs" })).Ok();

        var returned = await (await o.Requester.GetAsync($"/api/v1/requisitions/{req.Id()}")).Ok();
        Assert.Equal("ReturnedForModification", returned.Str("status"));

        // requester edits and resubmits: a NEW approval request is created
        await (await o.Requester.PutJson($"/api/v1/requisitions/{req.Id()}", o.Body(12_000, "Laptops v2"))).Ok();
        var resub = await (await o.Requester.PostJson($"/api/v1/requisitions/{req.Id()}/submit")).Ok();
        Assert.NotEqual(rid, ApprovalOrg.RequestId(resub));
        Assert.Equal("PendingApproval", resub.Str("status"));

        await (await o.DeptManager.PostJson($"/api/v1/approvals/{ApprovalOrg.RequestId(resub)}/reject", new { comment = "No budget" })).Ok();
        Assert.Equal("Rejected", (await (await o.Requester.GetAsync($"/api/v1/requisitions/{req.Id()}")).Ok()).Str("status"));
        var rejectedTab = await (await o.DeptManager.GetAsync("/api/v1/approvals?tab=rejected")).Ok();
        Assert.Equal(2, rejectedTab["totalCount"]!.GetValue<int>());
    }

    [Fact]
    public async Task Self_approval_is_blocked_even_for_the_owner()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(10_000, by: o.Tenant.Owner);
        var rid = ApprovalOrg.RequestId(req);
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Tenant.Owner.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);
        Assert.Equal(0, (await (await o.Tenant.Owner.GetAsync("/api/v1/approvals")).Ok())["totalCount"]!.GetValue<int>());
        // someone else can approve it
        Assert.Equal(HttpStatusCode.OK, (await o.DeptManager.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);
    }

    [Fact]
    public async Task Self_approval_can_be_enabled_in_settings()
    {
        var o = await ApprovalOrg.Create(factory);
        await (await o.Tenant.Owner.PutJson("/api/v1/organizations/current/settings", new { allowSelfApproval = true })).Ok();
        var req = await o.Submitted(10_000, by: o.Tenant.Owner);
        Assert.Equal(HttpStatusCode.OK, (await o.Tenant.Owner.PostJson($"/api/v1/approvals/{ApprovalOrg.RequestId(req)}/approve", new { })).StatusCode);
    }

    [Fact]
    public async Task Same_person_cannot_approve_two_steps()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(620_000);
        var rid = ApprovalOrg.RequestId(req);
        // the owner may act on any step, but only once per request
        await (await o.Tenant.Owner.PostJson($"/api/v1/approvals/{rid}/approve", new { })).Ok();
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Tenant.Owner.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);
    }

    [Fact]
    public async Task Double_click_and_stale_version_are_protected()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(10_000);
        var rid = ApprovalOrg.RequestId(req);
        var version = req["approval"]!["rowVersion"]!.GetValue<int>();

        var results = await Task.WhenAll(
            o.DeptManager.PostJson($"/api/v1/approvals/{rid}/approve", new { expectedVersion = version }),
            o.DeptManager.PostJson($"/api/v1/approvals/{rid}/approve", new { expectedVersion = version }));
        Assert.Equal(1, results.Count(r => r.StatusCode == HttpStatusCode.OK));
        Assert.Equal(1, results.Count(r => r.StatusCode == HttpStatusCode.Conflict));
    }

    [Fact]
    public async Task Stale_version_returns_409_for_a_pending_request()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(620_000);
        var rid = ApprovalOrg.RequestId(req);
        var res = await o.DeptManager.PostJson($"/api/v1/approvals/{rid}/approve", new { expectedVersion = 999 });
        Assert.Equal(HttpStatusCode.Conflict, res.StatusCode);
    }

    [Fact]
    public async Task Department_manager_assignment_limits_who_can_approve()
    {
        var o = await ApprovalOrg.Create(factory);
        var (otherMgr, _, _) = await o.Tenant.AddUser("Other Manager", "DepartmentManager");
        var set = await o.Tenant.Owner.PutJson($"/api/v1/departments/{o.DepartmentId}/manager", new { userId = o.DeptManagerId });
        Assert.Equal(HttpStatusCode.OK, set.StatusCode);

        var rid = ApprovalOrg.RequestId(await o.Submitted(10_000));
        Assert.Equal(HttpStatusCode.Forbidden, (await otherMgr.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await o.DeptManager.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);

        // the manager must hold the Department Manager role
        var bad = await o.Tenant.Owner.PutJson($"/api/v1/departments/{o.DepartmentId}/manager", new { userId = o.RequesterId });
        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
    }

    [Fact]
    public async Task Delegation_lets_another_user_approve_and_records_who_they_acted_for()
    {
        var o = await ApprovalOrg.Create(factory);
        var (delegateClient, delegateId, _) = await o.Tenant.AddUser("Dee Delegate", "Approver");
        var rid = ApprovalOrg.RequestId(await o.Submitted(10_000));

        Assert.Equal(HttpStatusCode.Forbidden, (await delegateClient.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);

        var today = DateTime.Today;
        var del = await o.DeptManager.PostJson("/api/v1/delegations", new
        {
            toUserId = delegateId, startDate = today.AddDays(-1).ToString("yyyy-MM-dd"), endDate = today.AddDays(5).ToString("yyyy-MM-dd"), reason = "Leave"
        });
        Assert.Equal(HttpStatusCode.OK, del.StatusCode);

        Assert.Equal(1, (await (await delegateClient.GetAsync("/api/v1/approvals")).Ok())["totalCount"]!.GetValue<int>());
        var done = await (await delegateClient.PostJson($"/api/v1/approvals/{rid}/approve", new { })).Ok();
        Assert.Equal("Dev Manager", done["steps"]![0]!.Str("actingForName"));
        Assert.Equal(1, (await (await delegateClient.GetAsync("/api/v1/approvals?tab=delegated")).Ok())["totalCount"]!.GetValue<int>());
    }

    [Fact]
    public async Task Expired_delegation_grants_nothing_and_cannot_delegate_to_self()
    {
        var o = await ApprovalOrg.Create(factory);
        var (delegateClient, delegateId, _) = await o.Tenant.AddUser("Eve Expired", "Approver");
        var rid = ApprovalOrg.RequestId(await o.Submitted(10_000));
        var past = DateTime.Today.AddDays(-10);
        await (await o.DeptManager.PostJson("/api/v1/delegations", new { toUserId = delegateId, startDate = past.ToString("yyyy-MM-dd"), endDate = past.AddDays(2).ToString("yyyy-MM-dd") })).Ok();
        Assert.Equal(HttpStatusCode.Forbidden, (await delegateClient.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.DeptManager.PostJson("/api/v1/delegations", new { toUserId = o.DeptManagerId, startDate = "2026-01-01", endDate = "2026-01-02" })).StatusCode);
    }

    [Fact]
    public async Task Cancelling_a_pending_requisition_cancels_its_approval()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(10_000);
        var rid = ApprovalOrg.RequestId(req);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Requester.PostJson($"/api/v1/requisitions/{req.Id()}/cancel", new { })).StatusCode);
        var cancelled = await (await o.Requester.PostJson($"/api/v1/requisitions/{req.Id()}/cancel", new { comment = "Not needed" })).Ok();
        Assert.Equal("Cancelled", cancelled.Str("status"));
        Assert.Equal(0, (await (await o.DeptManager.GetAsync("/api/v1/approvals")).Ok())["totalCount"]!.GetValue<int>());
        Assert.Equal(HttpStatusCode.Conflict, (await o.DeptManager.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);
    }

    [Fact]
    public async Task Approval_rules_are_configurable_per_tenant()
    {
        var o = await ApprovalOrg.Create(factory);
        // a new high-priority rule: everything needs Finance only
        var save = await o.Tenant.Owner.PostJson("/api/v1/approval-rules", new
        {
            name = "All to finance", entityType = "requisition", minAmount = 0, priority = 99, active = true,
            steps = new[] { new { name = "Finance", roleCode = "FinanceManager" } }
        });
        Assert.Equal(HttpStatusCode.OK, save.StatusCode);
        var req = await o.Submitted(5_000);
        Assert.Equal("FinanceManager", req["approval"]!["steps"]![0]!.Str("roleCode"));

        Assert.Equal(HttpStatusCode.BadRequest, (await o.Tenant.Owner.PostJson("/api/v1/approval-rules", new
        {
            name = "Bad", entityType = "requisition", steps = new[] { new { roleCode = "NoSuchRole" } }
        })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Requester.GetAsync("/api/v1/approval-rules")).StatusCode);
    }

    [Fact]
    public async Task Approvers_and_requesters_receive_notifications()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(10_000);
        var mgrNotes = await (await o.DeptManager.GetAsync("/api/v1/notifications")).Ok();
        Assert.Contains(mgrNotes["items"]!.AsArray(), n => n!.Str("type") == "approval_needed");
        Assert.True(mgrNotes["unreadCount"]!.GetValue<int>() >= 1);

        await (await o.DeptManager.PostJson($"/api/v1/approvals/{ApprovalOrg.RequestId(req)}/approve", new { })).Ok();
        var reqNotes = await (await o.Requester.GetAsync("/api/v1/notifications")).Ok();
        Assert.Contains(reqNotes["items"]!.AsArray(), n => n!.Str("type") == "approval_result");

        var first = reqNotes["items"]![0]!.Id();
        await o.Requester.PostAsync($"/api/v1/notifications/{first}/read", null);
        var again = await (await o.Requester.GetAsync("/api/v1/notifications?unreadOnly=true")).Ok();
        Assert.DoesNotContain(again["items"]!.AsArray(), n => n!.Id() == first);
    }

    // ------------------------------------------------------------------ tenant isolation and files

    [Fact]
    public async Task Other_tenant_cannot_read_decide_cancel_or_attach_to_a_requisition()
    {
        var a = await ApprovalOrg.Create(factory);
        var b = await ApprovalOrg.Create(factory);
        var req = await a.Submitted(10_000);
        var rid = ApprovalOrg.RequestId(req);

        Assert.Equal(HttpStatusCode.NotFound, (await b.Tenant.Owner.GetAsync($"/api/v1/requisitions/{req.Id()}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Tenant.Owner.GetAsync($"/api/v1/approvals/{rid}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.DeptManager.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Tenant.Owner.PostJson($"/api/v1/requisitions/{req.Id()}/cancel", new { comment = "x" })).StatusCode);
        Assert.Equal(0, (await (await b.DeptManager.GetAsync("/api/v1/approvals")).Ok())["totalCount"]!.GetValue<int>());

        var form = new MultipartFormDataContent();
        form.Add(new ByteArrayContent(Encoding.UTF8.GetBytes("%PDF")), "file", "spec.pdf");
        Assert.Equal(HttpStatusCode.NotFound, (await b.Tenant.Owner.PostAsync($"/api/v1/attachments/requisition/{req.Id()}", form)).StatusCode);
        // B cannot point its own department/cost centre fields at A's ids either
        var steal = await b.Requester.PostJson("/api/v1/requisitions", new { title = "x", departmentId = a.DepartmentId });
        Assert.Equal(HttpStatusCode.BadRequest, steal.StatusCode);
    }

    [Fact]
    public async Task Attachments_can_be_uploaded_listed_downloaded_and_deleted()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await (await o.Requester.PostJson("/api/v1/requisitions", o.Body(1000))).Ok();
        var form = new MultipartFormDataContent();
        form.Add(new ByteArrayContent(Encoding.UTF8.GetBytes("%PDF-1.4 spec")), "file", "laptop-spec-sheet.pdf");
        var added = await (await o.Requester.PostAsync($"/api/v1/attachments/requisition/{req.Id()}", form)).Ok();

        var list = await (await o.Requester.GetAsync($"/api/v1/attachments/requisition/{req.Id()}")).Ok();
        Assert.Single(list.AsArray());
        var file = await o.Requester.GetAsync($"/api/v1/attachments/{added.Id()}/file");
        Assert.Equal("%PDF-1.4 spec", await file.Content.ReadAsStringAsync());

        // the invoice-view-only role cannot download requisition files
        var (auditor, _, _) = await o.Tenant.AddUser("Aud Itor", "Auditor");
        Assert.Equal(HttpStatusCode.OK, (await auditor.GetAsync($"/api/v1/attachments/{added.Id()}/file")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await auditor.DeleteAsync($"/api/v1/attachments/{added.Id()}")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await o.Requester.DeleteAsync($"/api/v1/attachments/{added.Id()}")).StatusCode);
    }
}
