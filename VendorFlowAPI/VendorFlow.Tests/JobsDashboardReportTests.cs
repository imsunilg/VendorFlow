using System.Net;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using VendorFlow.Application.Abstractions;
using VendorFlow.Infrastructure.Jobs;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

/// <summary>Raw SQL helper for test set-up only (back-dating rows) and for calling job functions directly.</summary>
public static class TestSql
{
    public static async Task<object?> Scalar(ApiFactory f, string sql, params (string, object)[] args)
    {
        var cs = f.Services.GetRequiredService<IConfiguration>().GetConnectionString("VendorFlow");
        await using var conn = new NpgsqlConnection(cs);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(sql, conn);
        foreach (var (n, v) in args) cmd.Parameters.AddWithValue(n, v);
        return await cmd.ExecuteScalarAsync();
    }
}

[Collection("api")]
public class JobsTests(ApiFactory factory)
{
    private static async Task<JsonNode> RunChecks(TestTenant t) => await (await t.Owner.PostJson("/api/v1/notifications/run-checks")).Ok();

    private static async Task<int> CountNotes(HttpClient c, string type)
    {
        var list = await (await c.GetAsync("/api/v1/notifications?pageSize=100")).Ok();
        return list["items"]!.AsArray().Count(n => n!.Str("type") == type);
    }

    private static Task<HttpResponseMessage> AddDoc(HttpClient c, Guid vendor, string type, int daysFromNow)
    {
        var form = new MultipartFormDataContent { { new StringContent(type), "DocType" },
            { new StringContent(DateOnly.FromDateTime(DateTime.Today.AddDays(daysFromNow)).ToString("yyyy-MM-dd")), "ExpiryDate" } };
        return c.PostAsync($"/api/v1/vendors/{vendor}/documents", form);
    }

    [Fact]
    public async Task Expiring_and_expired_documents_notify_once_per_threshold()
    {
        var t = await TestTenant.Create(factory);
        var vendor = await Fixtures.ApprovedVendor(t.Owner);
        await AddDoc(t.Owner, vendor, "MSME", 20);
        await AddDoc(t.Owner, vendor, "Far", 200);

        Assert.Equal(1, (await RunChecks(t))["documentExpiry"]!.GetValue<int>());
        Assert.Equal(1, await CountNotes(t.Owner, "document_expiring"));
        Assert.Equal(0, (await RunChecks(t))["documentExpiry"]!.GetValue<int>());      // idempotent
        await AddDoc(t.Owner, vendor, "GST", -3);
        Assert.Equal(1, (await RunChecks(t))["documentExpiry"]!.GetValue<int>());
        Assert.Equal(2, await CountNotes(t.Owner, "document_expiring"));
    }

    [Fact]
    public async Task Invoice_due_soon_and_overdue_notify_finance_without_duplicates()
    {
        var s = await InvSetup.Create(factory);
        var tenant = s.Org.Org.Tenant;
        var inv = await s.Approved(InvSetup.Num());                                     // due in 30 days: no notice yet
        Assert.Equal(0, (await RunChecks(tenant))["invoiceDue"]!.GetValue<int>());

        await TestSql.Scalar(factory, "update vendorflow.invoices set due_date = current_date + 2 where id=@i returning 1", ("i", inv.Id()));
        Assert.Equal(1, (await RunChecks(tenant))["invoiceDue"]!.GetValue<int>());
        Assert.Equal(0, (await RunChecks(tenant))["invoiceDue"]!.GetValue<int>());      // idempotent
        Assert.Equal(1, await CountNotes(s.Finance, "invoice_due"));

        await TestSql.Scalar(factory, "update vendorflow.invoices set due_date = current_date - 5, invoice_date = current_date - 40 where id=@i returning 1", ("i", inv.Id()));
        Assert.Equal(1, (await RunChecks(tenant))["invoiceDue"]!.GetValue<int>());
        Assert.Equal(1, await CountNotes(s.Finance, "invoice_overdue"));
    }

    [Fact]
    public async Task Delivery_due_notifies_the_po_creator()
    {
        var o = await PoOrg.Create(factory);
        var tomorrow = DateOnly.FromDateTime(DateTime.Today.AddDays(1)).ToString("yyyy-MM-dd");
        await o.Issued(new
        {
            vendorId = o.VendorId, expectedDelivery = tomorrow, items = new[] { new { description = "x", quantity = 1, rate = 10 } }
        });
        var run = await (await o.Owner.PostJson("/api/v1/notifications/run-checks")).Ok();
        Assert.Equal(1, run["deliveryDue"]!.GetValue<int>());
        Assert.Equal(1, await CountNotes(o.Proc, "delivery_due"));
        Assert.Equal(0, (await (await o.Owner.PostJson("/api/v1/notifications/run-checks")).Ok())["deliveryDue"]!.GetValue<int>());
    }

    [Fact]
    public async Task Rfq_deadlines_close_expired_rfqs_and_warn_before_closing()
    {
        var s = await RfqSetup.Open(factory, 1, deadlineIn: TimeSpan.FromSeconds(5));
        var soon = await RfqSetup.Open(factory, 1, s.Org, deadlineIn: TimeSpan.FromHours(5));
        await Task.Delay(5500);
        var tenant = s.Org.Tenant;
        var run = await (await tenant.Owner.PostJson("/api/v1/notifications/run-checks")).Ok();
        Assert.Equal(2, run["rfqDeadlines"]!.GetValue<int>());                           // 1 closed notice + 1 closing-soon warning
        Assert.Equal("Closed", (await (await tenant.Owner.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok()).Str("status"));
        Assert.Equal("Open", (await (await tenant.Owner.GetAsync($"/api/v1/rfqs/{soon.RfqId}")).Ok()).Str("status"));
        Assert.Equal(0, (await (await tenant.Owner.PostJson("/api/v1/notifications/run-checks")).Ok())["rfqDeadlines"]!.GetValue<int>());
    }

    [Fact]
    public async Task Approvals_waiting_more_than_two_days_are_reminded_once_per_day()
    {
        var o = await ApprovalOrg.Create(factory);
        var req = await o.Submitted(10_000);
        await TestSql.Scalar(factory, "update vendorflow.approval_requests set created_at = now() - interval '3 days' where id=@i returning 1", ("i", ApprovalOrg.RequestId(req)));
        var first = await (await o.Tenant.Owner.PostJson("/api/v1/notifications/run-checks")).Ok();
        Assert.True(first["approvalReminders"]!.GetValue<int>() >= 1);
        Assert.Equal(1, await CountNotes(o.DeptManager, "approval_reminder"));
        Assert.Equal(0, (await (await o.Tenant.Owner.PostJson("/api/v1/notifications/run-checks")).Ok())["approvalReminders"]!.GetValue<int>());
    }

    [Fact]
    public async Task Checks_only_touch_the_callers_tenant_and_need_a_permission()
    {
        var a = await TestTenant.Create(factory);
        var b = await TestTenant.Create(factory);
        var vendor = await Fixtures.ApprovedVendor(a.Owner);
        await AddDoc(a.Owner, vendor, "MSME", 5);
        Assert.Equal(0, (await RunChecks(b))["documentExpiry"]!.GetValue<int>());
        Assert.Equal(0, await CountNotes(b.Owner, "document_expiring"));
        Assert.Equal(1, (await RunChecks(a))["documentExpiry"]!.GetValue<int>());
        var (requester, _, _) = await a.AddUser("Rita Requester", "DepartmentRequester");
        Assert.Equal(HttpStatusCode.Forbidden, (await requester.PostJson("/api/v1/notifications/run-checks")).StatusCode);
    }

    [Fact]
    public async Task Email_outbox_is_filled_when_enabled_and_retry_rules_end_in_failed_after_five_attempts()
    {
        var o = await ApprovalOrg.Create(factory);
        var tenant = o.Tenant.TenantId;
        Assert.Equal(0L, (long)(await TestSql.Scalar(factory, "select count(*) from vendorflow.email_outbox where tenant_id=@t", ("t", tenant)))!);   // off by default
        await (await o.Tenant.Owner.PutJson("/api/v1/organizations/current/settings", new { notificationPrefs = new { email = true } })).Ok();
        await o.Submitted(10_000);
        Assert.True((long)(await TestSql.Scalar(factory, "select count(*) from vendorflow.email_outbox where tenant_id=@t", ("t", tenant)))! >= 1);

        // claiming counts as an attempt
        Assert.True(Convert.ToInt32(await TestSql.Scalar(factory, "select jsonb_array_length(vendorflow.fn_email_outbox_claim(1000))")) >= 1);
        Assert.Equal(1, Convert.ToInt32(await TestSql.Scalar(factory, "select max(attempts) from vendorflow.email_outbox where tenant_id=@t", ("t", tenant))));

        async Task<string> Status() => (await TestSql.Scalar(factory, "select min(status) from vendorflow.email_outbox where tenant_id=@t", ("t", tenant)))!.ToString()!;
        async Task Result(bool ok) => await TestSql.Scalar(factory,
            $"do $$ declare r record; begin for r in select id from vendorflow.email_outbox where tenant_id = '{tenant}' loop call vendorflow.sp_email_outbox_result(r.id, {(ok ? "true" : "false")}, 'smtp down'); end loop; end $$; select 1");

        await Result(false);
        Assert.Equal("Pending", await Status());                                        // attempt 1 of 5 failed: will retry
        await TestSql.Scalar(factory, "update vendorflow.email_outbox set attempts = 5 where tenant_id=@t; select 1", ("t", tenant));
        await Result(false);
        Assert.Equal("Failed", await Status());                                         // the 5th failure is final
        await TestSql.Scalar(factory, "update vendorflow.email_outbox set status='Pending', attempts = 2 where tenant_id=@t; select 1", ("t", tenant));
        await Result(true);
        Assert.Equal("Sent", await Status());
    }

    [Fact]
    public async Task Dispatch_job_does_nothing_without_smtp_and_leaves_mail_pending()
    {
        var o = await ApprovalOrg.Create(factory);
        await (await o.Tenant.Owner.PutJson("/api/v1/organizations/current/settings", new { notificationPrefs = new { email = true } })).Ok();
        await o.Submitted(10_000);
        using var scope = factory.Services.CreateScope();
        var jobs = ActivatorUtilities.CreateInstance<MaintenanceJobs>(scope.ServiceProvider);
        await jobs.DispatchEmailsAsync();
        var pending = (long)(await TestSql.Scalar(factory, "select count(*) from vendorflow.email_outbox where tenant_id=@t and status='Pending' and attempts=0", ("t", o.Tenant.TenantId)))!;
        Assert.True(pending >= 1);
        Assert.False(scope.ServiceProvider.GetRequiredService<IEmailSender>().IsConfigured);
    }
}

[Collection("api")]
public class DashboardReportTests(ApiFactory factory)
{
    [Fact]
    public async Task Empty_tenant_dashboard_has_zeros_and_no_errors()
    {
        var t = await TestTenant.Create(factory);
        var d = await (await t.Owner.GetAsync("/api/v1/dashboard")).Ok();
        Assert.Equal(0m, d["kpis"]!["totalProcurement"]!.Dec("value"));
        Assert.Null(d["kpis"]!["totalProcurement"]!["changePct"]);
        Assert.Equal(0, d["kpis"]!["openRfqs"]!["count"]!.GetValue<int>());
        Assert.Empty(d["spendByDepartment"]!.AsArray());
        Assert.StartsWith("FY ", d.Str("fiscalYear"));
        Assert.True(d["monthlyTrend"]!.AsArray().Count >= 1);
    }

    [Fact]
    public async Task Dashboard_reflects_real_documents_and_is_tenant_scoped()
    {
        var o = await PoOrg.Create(factory);
        var other = await PoOrg.Create(factory);
        await other.Issued();                                                           // must not leak into o

        // requisition -> approved -> PO from it (spend is attributed to the IT department)
        var req = await o.Org.Submitted(100_000);
        await (await o.Org.DeptManager.PostJson($"/api/v1/approvals/{ApprovalOrg.RequestId(req)}/approve", new { })).Ok();
        var po = await (await o.Proc.PostJson($"/api/v1/purchase-orders/from-requisition/{req.Id()}", new { vendorId = o.VendorId })).Ok();
        var sub = await (await o.Proc.PostJson($"/api/v1/purchase-orders/{po.Id()}/submit")).Ok();
        await (await o.Owner.PostJson($"/api/v1/approvals/{sub["approval"]!.Id()}/approve", new { })).Ok();
        await (await o.Proc.PostJson($"/api/v1/purchase-orders/{po.Id()}/issue")).Ok();
        var issued = await (await o.Proc.GetAsync($"/api/v1/purchase-orders/{po.Id()}")).Ok();

        var d = await (await o.Owner.GetAsync("/api/v1/dashboard")).Ok();
        Assert.Equal(issued.Dec("total"), d["kpis"]!["totalProcurement"]!.Dec("value"));
        Assert.Equal("IT", d["spendByDepartment"]![0]!.Str("name"));
        Assert.Equal(100, d["spendByDepartment"]![0]!["pct"]!.GetValue<int>());
        Assert.Equal(issued.Dec("total"), d["monthlyTrend"]!.AsArray().Sum(m => m!.Dec("amount")));

        var vendor = await Fixtures.ApprovedVendor(o.Owner);
        var form = new MultipartFormDataContent { { new StringContent("GST Cert"), "DocType" }, { new StringContent(DateOnly.FromDateTime(DateTime.Today.AddDays(-1)).ToString("yyyy-MM-dd")), "ExpiryDate" } };
        await o.Owner.PostAsync($"/api/v1/vendors/{vendor}/documents", form);
        await o.Org.Submitted(5_000, title: "Pending item");
        var d2 = await (await o.Owner.GetAsync("/api/v1/dashboard")).Ok();
        Assert.Equal("Expired", d2["expiringDocuments"]![0]!.Str("status"));
        Assert.Equal(1, d2["kpis"]!["expiringDocuments"]!.GetValue<int>());
        Assert.Contains(d2["attention"]!.AsArray(), a => a!.Str("entityType") == "requisition");
    }

    [Fact]
    public async Task Dashboard_needs_report_permission_but_summary_works_for_everyone()
    {
        var o = await ApprovalOrg.Create(factory);
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Requester.GetAsync("/api/v1/dashboard")).StatusCode);
        var s = await (await o.Requester.GetAsync("/api/v1/dashboard/summary")).Ok();
        Assert.Equal(0, s["pendingApprovals"]!.GetValue<int>());
        await o.Submitted(10_000);
        var mgr = await (await o.DeptManager.GetAsync("/api/v1/dashboard/summary")).Ok();
        Assert.Equal(1, mgr["pendingApprovals"]!.GetValue<int>());
        var full = await (await o.Tenant.Owner.GetAsync("/api/v1/dashboard/summary")).Ok();
        Assert.NotNull(full["overdueInvoices"]);
    }

    [Fact]
    public async Task Expenditure_report_groups_by_month_category_department_and_vendor()
    {
        var o = await PoOrg.Create(factory);
        await o.Issued();
        var month = await (await o.Owner.GetAsync("/api/v1/reports/expenditure?groupBy=month")).Ok();
        Assert.Single(month["rows"]!.AsArray());
        Assert.Equal(222216m, month["rows"]![0]!.Dec("amount"));
        var cat = await (await o.Owner.GetAsync("/api/v1/reports/expenditure?groupBy=category")).Ok();
        Assert.Equal("Electronics", cat["rows"]![0]!.Str("label"));
        var dept = await (await o.Owner.GetAsync("/api/v1/reports/expenditure?groupBy=department")).Ok();
        Assert.Equal("Unassigned", dept["rows"]![0]!.Str("label"));
        var vendor = await (await o.Owner.GetAsync("/api/v1/reports/expenditure?groupBy=vendor")).Ok();
        Assert.StartsWith("PO Vendor", vendor["rows"]![0]!.Str("label"));
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Owner.GetAsync("/api/v1/reports/expenditure?groupBy=colour")).StatusCode);
        // a date range before the order date finds nothing
        var none = await (await o.Owner.GetAsync("/api/v1/reports/expenditure?from=2000-01-01&to=2000-12-31")).Ok();
        Assert.Empty(none["rows"]!.AsArray());
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Owner.GetAsync("/api/v1/reports/expenditure?from=2026-05-01&to=2026-01-01")).StatusCode);
    }

    [Fact]
    public async Task All_reports_run_and_describe_their_columns()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Register(InvSetup.Num(), s.Invoice(InvSetup.Num(), qtyB: 5));            // NeedsReview -> invoice exception
        await s.Approved(InvSetup.Num());                                                           // approved -> outstanding
        var owner = s.Org.Owner;
        var catalog = await (await owner.GetAsync("/api/v1/reports")).Ok();
        Assert.Equal(6, catalog.AsArray().Count);
        foreach (var key in catalog.AsArray().Select(c => c!.Str("key")))
        {
            var rep = await (await owner.GetAsync($"/api/v1/reports/{key}")).Ok();
            Assert.NotEmpty(rep["columns"]!.AsArray());
            Assert.NotNull(rep["rows"]);
        }
        var exceptions = await (await owner.GetAsync("/api/v1/reports/invoice-exceptions")).Ok();
        Assert.Contains(exceptions["rows"]!.AsArray(), r => r!.Str("invoiceNumber") != "" && r["discrepancies"]!.GetValue<int>() >= 1);
        var aging = await (await owner.GetAsync("/api/v1/reports/outstanding-payments")).Ok();
        Assert.Equal("0-30 days", aging["rows"]![0]!.Str("bucket"));
        Assert.Equal(12744m, aging["rows"]![0]!.Dec("balance"));
        var statusRep = await (await owner.GetAsync("/api/v1/reports/po-status")).Ok();
        Assert.Contains(statusRep["rows"]!.AsArray(), r => r!.Str("status") == "PartiallyReceived");
        var perf = await (await owner.GetAsync("/api/v1/reports/vendor-performance")).Ok();
        Assert.NotNull(perf["rows"]![0]!["score"]);
        Assert.Equal(HttpStatusCode.NotFound, (await owner.GetAsync("/api/v1/reports/nope")).StatusCode);
        _ = inv;
    }

    [Fact]
    public async Task Expiring_documents_report_lists_documents_inside_the_window()
    {
        var t = await TestTenant.Create(factory);
        var vendor = await Fixtures.ApprovedVendor(t.Owner, "Doc Vendor");
        foreach (var (type, days) in new[] { ("Soon", 20), ("Later", 90) })
        {
            var form = new MultipartFormDataContent { { new StringContent(type), "DocType" }, { new StringContent(DateOnly.FromDateTime(DateTime.Today.AddDays(days)).ToString("yyyy-MM-dd")), "ExpiryDate" } };
            await t.Owner.PostAsync($"/api/v1/vendors/{vendor}/documents", form);
        }
        var r30 = await (await t.Owner.GetAsync("/api/v1/reports/expiring-documents?days=30")).Ok();
        Assert.Single(r30["rows"]!.AsArray());
        var r120 = await (await t.Owner.GetAsync("/api/v1/reports/expiring-documents?days=120")).Ok();
        Assert.Equal(2, r120["rows"]!.AsArray().Count);
    }

    [Fact]
    public async Task Csv_export_is_permission_scoped_audited_and_tenant_isolated()
    {
        var a = await PoOrg.Create(factory);
        var b = await PoOrg.Create(factory);
        await a.Issued();
        var csv = await (await a.Owner.GetAsync("/api/v1/reports/expenditure/export?groupBy=vendor")).Content.ReadAsStringAsync();
        Assert.StartsWith("Vendor,POs,Amount", csv);
        Assert.Contains("PO Vendor", csv);
        var csvB = await (await b.Owner.GetAsync("/api/v1/reports/expenditure/export?groupBy=vendor")).Content.ReadAsStringAsync();
        Assert.DoesNotContain(a.VendorId.ToString(), csvB);
        Assert.Equal(1, csvB.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length);   // header only

        Assert.Equal(HttpStatusCode.Forbidden, (await a.Org.Requester.GetAsync("/api/v1/reports/expenditure")).StatusCode);
        var (auditor, _, _) = await a.Org.Tenant.AddUser("Aud Itor", "Auditor");
        Assert.Equal(HttpStatusCode.OK, (await auditor.GetAsync("/api/v1/reports/po-status")).StatusCode);
        var audit = await (await a.Owner.GetAsync("/api/v1/audit?pageSize=200")).Ok();
        Assert.Contains(audit["items"]!.AsArray(), x => x!.Str("action") == "report.exported");
    }
}
