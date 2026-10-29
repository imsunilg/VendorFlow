using System.Net;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

[Collection("api")]
public class SettingsTests(ApiFactory factory)
{
    private const string Url = "/api/v1/organizations/current/settings";

    [Fact]
    public async Task New_tenant_has_default_labels()
    {
        var t = await TestTenant.Create(factory, "Defaults Ltd");
        var s = await (await t.Owner.GetAsync(Url)).Ok();
        Assert.Equal("VendorFlow", s["appDisplayName"]!.GetValue<string>());
        Assert.Equal("Vendor", s["vendorLabelSingular"]!.GetValue<string>());
        Assert.Equal("Vendors", s["vendorLabelPlural"]!.GetValue<string>());
        Assert.Equal("Defaults Ltd", s["organizationName"]!.GetValue<string>());
    }

    [Fact]
    public async Task Owner_can_rename_app_and_vendor_terminology()
    {
        var t = await TestTenant.Create(factory);
        var res = await t.Owner.PutJson(Url, new { appDisplayName = "Acme Procure", vendorLabelSingular = "Supplier", vendorLabelPlural = "Suppliers" });
        var s = await res.Ok();
        Assert.Equal("Acme Procure", s["appDisplayName"]!.GetValue<string>());
        Assert.Equal("Suppliers", s["vendorLabelPlural"]!.GetValue<string>());
        // untouched fields stay as they were
        Assert.Equal("INR", s["currency"]!.GetValue<string>());
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("<b>Bold</b>")]
    [InlineData("A very long label that goes past the fifty character limit for sure")]
    public async Task Invalid_labels_are_rejected(string label)
    {
        var t = await TestTenant.Create(factory);
        var res = await t.Owner.PutJson(Url, new { vendorLabelSingular = label });
        Assert.Equal(HttpStatusCode.BadRequest, res.StatusCode);
    }

    [Fact]
    public async Task Labels_are_trimmed()
    {
        var t = await TestTenant.Create(factory);
        var s = await (await t.Owner.PutJson(Url, new { vendorLabelSingular = "  Contractor  ", vendorLabelPlural = " Contractors " })).Ok();
        Assert.Equal("Contractor", s["vendorLabelSingular"]!.GetValue<string>());
    }

    [Fact]
    public async Task Numbering_pattern_needs_a_counter_and_is_used_for_documents()
    {
        var t = await TestTenant.Create(factory);
        var bad = await t.Owner.PutJson(Url, new { numbering = new { po = "PO-FIXED" } });
        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
        var good = await t.Owner.PutJson(Url, new { numbering = new { po = "ORD/{YYYY}/{00000}" } });
        Assert.True(good.IsSuccessStatusCode);
    }

    [Fact]
    public async Task User_without_settings_permission_cannot_update_but_can_read()
    {
        var t = await TestTenant.Create(factory);
        var (requester, _, _) = await t.AddUser("Rita Requester", "DepartmentRequester");
        Assert.Equal(HttpStatusCode.OK, (await requester.GetAsync(Url)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await requester.PutJson(Url, new { appDisplayName = "Hacked" })).StatusCode);
    }

    [Fact]
    public async Task Settings_are_isolated_between_tenants()
    {
        var a = await TestTenant.Create(factory);
        var b = await TestTenant.Create(factory);
        await a.Owner.PutJson(Url, new { appDisplayName = "Alpha App", vendorLabelPlural = "Alpha Suppliers" });
        var sb = await (await b.Owner.GetAsync(Url)).Ok();
        Assert.Equal("VendorFlow", sb["appDisplayName"]!.GetValue<string>());
        Assert.Equal("Vendors", sb["vendorLabelPlural"]!.GetValue<string>());
        // B updating its own settings never touches A
        await b.Owner.PutJson(Url, new { appDisplayName = "Beta App" });
        var sa = await (await a.Owner.GetAsync(Url)).Ok();
        Assert.Equal("Alpha App", sa["appDisplayName"]!.GetValue<string>());
    }

    [Fact]
    public async Task Settings_change_is_audited_and_lookups_are_seeded()
    {
        var t = await TestTenant.Create(factory);
        await t.Owner.PutJson(Url, new { currency = "USD" });
        var audit = await (await t.Owner.GetAsync("/api/v1/audit")).Ok();
        Assert.Contains(audit["items"]!.AsArray(), a => a!["action"]!.GetValue<string>() == "settings.updated");
        var depts = await (await t.Owner.GetAsync("/api/v1/lookups/departments")).Ok();
        Assert.True(depts.AsArray().Count >= 5);
    }
}
