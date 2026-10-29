using System.Net;
using System.Text;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

[Collection("api")]
public class VendorTests(ApiFactory factory)
{
    [Fact]
    public async Task Create_vendor_starts_as_draft_with_generated_code()
    {
        var t = await TestTenant.Create(factory);
        var v = await (await t.Owner.PostJson("/api/v1/vendors", new { name = "Sona Tech", gstin = Fixtures.Gstin(), email = "a@b.co" })).Ok();
        Assert.Equal("Draft", v.Str("status"));
        Assert.StartsWith("VND-", v.Str("code"));
    }

    [Theory]
    [InlineData("gstin", "BADGSTIN")]
    [InlineData("pan", "123")]
    [InlineData("email", "not-an-email")]
    [InlineData("risk", "Extreme")]
    public async Task Invalid_fields_return_400(string field, string value)
    {
        var t = await TestTenant.Create(factory);
        var body = new Dictionary<string, object> { ["name"] = "X Vendor", [field] = value };
        Assert.Equal(HttpStatusCode.BadRequest, (await t.Owner.PostJson("/api/v1/vendors", body)).StatusCode);
    }

    [Fact]
    public async Task Duplicate_name_or_gstin_in_same_tenant_returns_409_but_other_tenant_may_reuse()
    {
        var a = await TestTenant.Create(factory);
        var b = await TestTenant.Create(factory);
        var gstin = Fixtures.Gstin();
        await (await a.Owner.PostJson("/api/v1/vendors", new { name = "Same Name", gstin })).Ok();
        Assert.Equal(HttpStatusCode.Conflict, (await a.Owner.PostJson("/api/v1/vendors", new { name = "same name" })).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await a.Owner.PostJson("/api/v1/vendors", new { name = "Other", gstin })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await b.Owner.PostJson("/api/v1/vendors", new { name = "Same Name", gstin })).StatusCode);
    }

    [Fact]
    public async Task Workflow_submit_approve_suspend_reactivate_and_invalid_transitions()
    {
        var t = await TestTenant.Create(factory);
        var v = await (await t.Owner.PostJson("/api/v1/vendors", new { name = "Flow Vendor", email = "f@v.co" })).Ok();
        var id = v.Id();

        // cannot approve a draft
        Assert.Equal(HttpStatusCode.Conflict, (await t.Owner.PostJson($"/api/v1/vendors/{id}/approve", new { })).StatusCode);
        Assert.Equal("PendingApproval", (await (await t.Owner.PostJson($"/api/v1/vendors/{id}/submit")).Ok()).Str("status"));
        // a pending vendor cannot be edited
        Assert.Equal(HttpStatusCode.Conflict, (await t.Owner.PutJson($"/api/v1/vendors/{id}", new { city = "Pune" })).StatusCode);
        // rejection needs a reason
        Assert.Equal(HttpStatusCode.BadRequest, (await t.Owner.PostJson($"/api/v1/vendors/{id}/reject", new { comment = "" })).StatusCode);
        Assert.Equal("Approved", (await (await t.Owner.PostJson($"/api/v1/vendors/{id}/approve", new { })).Ok()).Str("status"));
        // suspend needs a reason
        Assert.Equal(HttpStatusCode.BadRequest, (await t.Owner.PostJson($"/api/v1/vendors/{id}/suspend", new { comment = " " })).StatusCode);
        Assert.Equal("Suspended", (await (await t.Owner.PostJson($"/api/v1/vendors/{id}/suspend", new { comment = "quality" })).Ok()).Str("status"));
        Assert.Equal("Approved", (await (await t.Owner.PostJson($"/api/v1/vendors/{id}/reactivate", new { })).Ok()).Str("status"));

        var history = await (await t.Owner.GetAsync($"/api/v1/vendors/{id}/history")).Ok();
        Assert.True(history.AsArray().Count >= 5);
    }

    [Fact]
    public async Task Submit_without_any_contact_information_is_rejected()
    {
        var t = await TestTenant.Create(factory);
        var v = await (await t.Owner.PostJson("/api/v1/vendors", new { name = "No Contact" })).Ok();
        Assert.Equal(HttpStatusCode.BadRequest, (await t.Owner.PostJson($"/api/v1/vendors/{v.Id()}/submit")).StatusCode);
    }

    [Fact]
    public async Task Stale_row_version_returns_409()
    {
        var t = await TestTenant.Create(factory);
        var v = await (await t.Owner.PostJson("/api/v1/vendors", new { name = "Versioned" })).Ok();
        var id = v.Id();
        var v2 = await (await t.Owner.PutJson($"/api/v1/vendors/{id}", new { city = "Pune", rowVersion = v["rowVersion"]!.GetValue<int>() })).Ok();
        Assert.Equal(HttpStatusCode.Conflict, (await t.Owner.PutJson($"/api/v1/vendors/{id}", new { city = "Delhi", rowVersion = v["rowVersion"]!.GetValue<int>() })).StatusCode);
        Assert.Equal("Pune", v2.Str("city"));
    }

    [Fact]
    public async Task List_supports_search_status_filter_sorting_paging_and_status_counts()
    {
        var t = await TestTenant.Create(factory);
        await Fixtures.ApprovedVendor(t.Owner, "Alpha Metals");
        await Fixtures.ApprovedVendor(t.Owner, "Beta Metals");
        await t.Owner.PostJson("/api/v1/vendors", new { name = "Gamma Draft" });

        var all = await (await t.Owner.GetAsync("/api/v1/vendors?sortBy=name&sortDir=desc")).Ok();
        Assert.Equal(3, all["totalCount"]!.GetValue<int>());
        Assert.Equal("Gamma Draft", all["items"]![0]!.Str("name"));
        Assert.Equal(3, all["statusCounts"]!["All"]!.GetValue<int>());
        Assert.Equal(2, all["statusCounts"]!["Approved"]!.GetValue<int>());

        var approved = await (await t.Owner.GetAsync("/api/v1/vendors?status=Approved&search=metals")).Ok();
        Assert.Equal(2, approved["totalCount"]!.GetValue<int>());

        var paged = await (await t.Owner.GetAsync("/api/v1/vendors?pageSize=1&page=2&sortBy=name")).Ok();
        Assert.Single(paged["items"]!.AsArray());
        Assert.Equal("Beta Metals", paged["items"]![0]!.Str("name"));

        // sort column outside the whitelist is ignored, not injected
        Assert.Equal(HttpStatusCode.OK, (await t.Owner.GetAsync("/api/v1/vendors?sortBy=name;drop table vendorflow.vendors")).StatusCode);
    }

    [Fact]
    public async Task Document_status_is_computed_from_expiry_date()
    {
        var t = await TestTenant.Create(factory);
        var id = (await (await t.Owner.PostJson("/api/v1/vendors", new { name = "Docs Vendor" })).Ok()).Id();

        async Task<string> Add(string type, DateOnly? expiry)
        {
            var form = new MultipartFormDataContent { { new StringContent(type), "DocType" } };
            if (expiry is not null) form.Add(new StringContent(expiry.Value.ToString("yyyy-MM-dd")), "ExpiryDate");
            var v = await (await t.Owner.PostAsync($"/api/v1/vendors/{id}/documents", form)).Ok();
            return v["documents"]!.AsArray().First(d => d!.Str("docType") == type)!.Str("status");
        }

        Assert.Equal("Expired", await Add("Old cert", DateOnly.FromDateTime(DateTime.Today.AddDays(-1))));
        Assert.Equal("Expiring", await Add("Soon cert", DateOnly.FromDateTime(DateTime.Today.AddDays(12))));
        Assert.Equal("Valid", await Add("Far cert", DateOnly.FromDateTime(DateTime.Today.AddDays(200))));
        Assert.Equal("Valid", await Add("No expiry", null));
    }

    [Fact]
    public async Task Document_upload_accepts_pdf_and_rejects_executables()
    {
        var t = await TestTenant.Create(factory);
        var id = (await (await t.Owner.PostJson("/api/v1/vendors", new { name = "Upload Vendor" })).Ok()).Id();

        MultipartFormDataContent Form(string fileName)
        {
            var f = new MultipartFormDataContent { { new StringContent("GST"), "DocType" } };
            f.Add(new ByteArrayContent(Encoding.UTF8.GetBytes("%PDF-1.4 test")), "File", fileName);
            return f;
        }

        var ok = await (await t.Owner.PostAsync($"/api/v1/vendors/{id}/documents", Form("../../evil name.pdf"))).Ok();
        var doc = ok["documents"]![0]!;
        Assert.Equal("evil name.pdf", doc.Str("fileName"));   // path parts are stripped

        var download = await t.Owner.GetAsync($"/api/v1/vendors/{id}/documents/{doc.Id()}/file");
        Assert.Equal(HttpStatusCode.OK, download.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await t.Owner.PostAsync($"/api/v1/vendors/{id}/documents", Form("run.exe"))).StatusCode);
    }

    [Fact]
    public async Task Bank_details_need_the_bank_permission_and_every_view_is_audited()
    {
        var t = await TestTenant.Create(factory);
        var id = await Fixtures.ApprovedVendor(t.Owner);
        var bank = new { accountName = "Sona Tech", accountNumber = "123456789012", ifsc = "HDFC0001234", bankName = "HDFC" };

        Assert.Equal(HttpStatusCode.BadRequest, (await t.Owner.PutJson($"/api/v1/vendors/{id}/bank", new { accountName = "x", accountNumber = "12", ifsc = "bad" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await t.Owner.PutJson($"/api/v1/vendors/{id}/bank", bank)).StatusCode);

        var (procMgr, _, _) = await t.AddUser("Pat Procurement", "ProcurementManager");
        Assert.Equal(HttpStatusCode.Forbidden, (await procMgr.GetAsync($"/api/v1/vendors/{id}/bank")).StatusCode);
        // vendor profile never leaks bank numbers
        var profile = await (await procMgr.GetAsync($"/api/v1/vendors/{id}")).Ok();
        Assert.True(profile["hasBankDetails"]!.GetValue<bool>());
        Assert.DoesNotContain("123456789012", profile.ToJsonString());

        var (finance, _, _) = await t.AddUser("Fin Manager", "FinanceManager");
        var read = await (await finance.GetAsync($"/api/v1/vendors/{id}/bank")).Ok();
        Assert.Equal("123456789012", read.Str("accountNumber"));

        var audit = await (await t.Owner.GetAsync("/api/v1/audit?pageSize=200")).Ok();
        Assert.Contains(audit["items"]!.AsArray(), a => a!.Str("action") == "vendor.bank_viewed");
        Assert.Contains(audit["items"]!.AsArray(), a => a!.Str("action") == "vendor.bank_changed");
    }

    [Fact]
    public async Task Tenant_cannot_read_change_or_transition_another_tenants_vendor()
    {
        var a = await TestTenant.Create(factory);
        var b = await TestTenant.Create(factory);
        var id = await Fixtures.ApprovedVendor(a.Owner, "A Private Vendor");
        await a.Owner.PutJson($"/api/v1/vendors/{id}/bank", new { accountName = "A", accountNumber = "999999999", ifsc = "HDFC0001234" });

        Assert.Equal(HttpStatusCode.NotFound, (await b.Owner.GetAsync($"/api/v1/vendors/{id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Owner.PutJson($"/api/v1/vendors/{id}", new { name = "Hijacked" })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Owner.PostJson($"/api/v1/vendors/{id}/suspend", new { comment = "x" })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Owner.GetAsync($"/api/v1/vendors/{id}/bank")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Owner.GetAsync($"/api/v1/vendors/{id}/performance")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Owner.PostJson($"/api/v1/vendors/{id}/contacts", new { name = "Spy" })).StatusCode);

        var list = await (await b.Owner.GetAsync("/api/v1/vendors")).Ok();
        Assert.Equal(0, list["totalCount"]!.GetValue<int>());
        Assert.Equal("A Private Vendor", (await (await a.Owner.GetAsync($"/api/v1/vendors/{id}")).Ok()).Str("name"));
    }

    [Fact]
    public async Task Performance_without_data_has_no_score_instead_of_fake_numbers()
    {
        var t = await TestTenant.Create(factory);
        var id = await Fixtures.ApprovedVendor(t.Owner);
        var perf = await (await t.Owner.GetAsync($"/api/v1/vendors/{id}/performance")).Ok();
        Assert.Null(perf["score"]);
        Assert.Equal(5, perf["metrics"]!.AsArray().Count);
    }

    [Fact]
    public async Task Requester_can_view_but_not_create_vendors_and_csv_export_works()
    {
        var t = await TestTenant.Create(factory);
        await Fixtures.ApprovedVendor(t.Owner, "=cmd|evil");
        var (requester, _, _) = await t.AddUser("Rita Requester", "DepartmentRequester");
        Assert.Equal(HttpStatusCode.OK, (await requester.GetAsync("/api/v1/vendors")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await requester.PostJson("/api/v1/vendors", new { name = "Nope" })).StatusCode);

        var csv = await (await t.Owner.GetAsync("/api/v1/vendors/export")).Content.ReadAsStringAsync();
        Assert.StartsWith("Code,Name", csv);
        Assert.Contains("'=cmd|evil", csv);   // formula injection neutralised
    }
}
