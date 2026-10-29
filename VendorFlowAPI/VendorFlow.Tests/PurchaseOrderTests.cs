using System.Net;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

/// <summary>Organization with a procurement manager (creates POs), finance manager and a ready vendor.</summary>
public sealed class PoOrg
{
    public required ApprovalOrg Org { get; init; }
    public required HttpClient Proc { get; init; }
    public required Guid VendorId { get; init; }
    public HttpClient Owner => Org.Tenant.Owner;

    public static async Task<PoOrg> Create(ApiFactory f)
    {
        var org = await ApprovalOrg.Create(f);
        var (proc, _, _) = await org.Tenant.AddUser("Pat Procurement", "ProcurementManager");
        var vendor = await Fixtures.ApprovedVendor(org.Tenant.Owner, "PO Vendor " + Guid.NewGuid().ToString("N")[..4]);
        return new PoOrg { Org = org, Proc = proc, VendorId = vendor };
    }

    public object Body(decimal rate = 24500, decimal qty = 8, decimal discount = 5, decimal tax = 18, decimal shipping = 2500) => new
    {
        vendorId = VendorId, expectedDelivery = DateOnly.FromDateTime(DateTime.Today.AddDays(14)).ToString("yyyy-MM-dd"), shipping,
        notes = "Test order",
        items = new[] { new { description = "Cisco 24-port PoE switch", unit = "Nos", quantity = qty, rate, discountPercent = discount, taxPercent = tax } }
    };

    public async Task<JsonNode> Draft(object? body = null) => await (await Proc.PostJson("/api/v1/purchase-orders", body ?? Body())).Ok();

    /// <summary>Draft → submitted → approved (owner approves step 1, finance step 2 when needed).</summary>
    public async Task<JsonNode> Approved(object? body = null)
    {
        var po = await Draft(body);
        var submitted = await (await Proc.PostJson($"/api/v1/purchase-orders/{po.Id()}/submit")).Ok();
        var rid = submitted["approval"]!.Id();
        var steps = submitted["approval"]!["totalSteps"]!.GetValue<int>();
        await (await Owner.PostJson($"/api/v1/approvals/{rid}/approve", new { })).Ok();
        if (steps > 1) await (await Org.Finance.PostJson($"/api/v1/approvals/{rid}/approve", new { })).Ok();
        return await (await Proc.GetAsync($"/api/v1/purchase-orders/{po.Id()}")).Ok();
    }

    public async Task<JsonNode> Issued(object? body = null)
    {
        var po = await Approved(body);
        return await (await Proc.PostJson($"/api/v1/purchase-orders/{po.Id()}/issue")).Ok();
    }
}

[Collection("api")]
public class PurchaseOrderTests(ApiFactory factory)
{
    private static string Url(JsonNode po, string tail = "") => $"/api/v1/purchase-orders/{po.Id()}{tail}";

    // ------------------------------------------------------------------ creation and math

    [Fact]
    public async Task Direct_po_is_numbered_and_totals_follow_the_rounding_rule()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Draft();
        Assert.Equal("Draft", po.Str("status"));
        Assert.StartsWith("PO-", po.Str("number"));
        // 8 x 24500 = 196000; 5% = 9800; net 186200; GST 18% = 33516; line 219716; + shipping 2500
        Assert.Equal(186200m, po.Dec("subtotal"));
        Assert.Equal(9800m, po.Dec("discountTotal"));
        Assert.Equal(33516m, po.Dec("taxTotal"));
        Assert.Equal(222216m, po.Dec("total"));
        Assert.Equal(219716m, po["items"]![0]!.Dec("lineTotal"));
    }

    [Fact]
    public async Task Tax_defaults_to_the_tenant_setting_and_lines_are_rounded_individually()
    {
        var o = await PoOrg.Create(factory);
        var po = await (await o.Proc.PostJson("/api/v1/purchase-orders", new
        {
            vendorId = o.VendorId,
            items = new object[]
            {
                new { description = "A", quantity = 3, rate = 0.335 },          // rate -> 0.34, gross 1.02, tax 18% = 0.18 (0.1836)
                new { description = "B", quantity = 1, rate = 10.005 }          // rate -> 10.01, tax 1.80 (1.8018)
            }
        })).Ok();
        Assert.Equal(18m, po["items"]![0]!.Dec("taxPercent"));
        Assert.Equal(1.20m, po["items"]![0]!.Dec("lineTotal"));
        Assert.Equal(11.81m, po["items"]![1]!.Dec("lineTotal"));
        Assert.Equal(11.03m, po.Dec("subtotal"));
        Assert.Equal(1.98m, po.Dec("taxTotal"));
        Assert.Equal(13.01m, po.Dec("total"));
    }

    [Fact]
    public async Task Invalid_input_is_refused()
    {
        var o = await PoOrg.Create(factory);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson("/api/v1/purchase-orders", new { items = new[] { new { description = "x", quantity = 1, rate = 1 } } })).StatusCode); // no vendor
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson("/api/v1/purchase-orders", o.Body(qty: 0))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson("/api/v1/purchase-orders", o.Body(rate: -1))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson("/api/v1/purchase-orders", o.Body(discount: 120))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson("/api/v1/purchase-orders", new { vendorId = o.VendorId, items = Array.Empty<object>() })).StatusCode);
    }

    [Fact]
    public async Task Only_approved_vendors_of_the_tenant_can_receive_a_po()
    {
        var o = await PoOrg.Create(factory);
        var draftVendor = (await (await o.Owner.PostJson("/api/v1/vendors", new { name = "Unapproved" })).Ok()).Id();
        var other = await PoOrg.Create(factory);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson("/api/v1/purchase-orders", new { vendorId = draftVendor, items = new[] { new { description = "x", quantity = 1, rate = 1 } } })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson("/api/v1/purchase-orders", new { vendorId = other.VendorId, items = new[] { new { description = "x", quantity = 1, rate = 1 } } })).StatusCode);
    }

    [Fact]
    public async Task Draft_can_be_edited_and_stale_version_is_refused()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Draft();
        var itemId = po["items"]![0]!.Id();
        var edited = await (await o.Proc.PutJson(Url(po), new
        {
            rowVersion = po["rowVersion"]!.GetValue<int>(), notes = "Changed", shipping = 0,
            items = new[] { new { id = itemId, description = "Cisco switch", unit = "Nos", quantity = 10, rate = 1000, discountPercent = 0, taxPercent = 18 } }
        })).Ok();
        Assert.Equal(11800m, edited.Dec("total"));
        Assert.Equal("Changed", edited.Str("notes"));
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PutJson(Url(po), new { rowVersion = po["rowVersion"]!.GetValue<int>(), notes = "stale" })).StatusCode);
    }

    // ------------------------------------------------------------------ approval, issue, immutability

    [Fact]
    public async Task Submit_approve_issue_flow_with_permission_and_state_checks()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Draft();
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson(Url(po, "/issue"))).StatusCode);          // draft cannot be issued
        var submitted = await (await o.Proc.PostJson(Url(po, "/submit"))).Ok();
        Assert.Equal("PendingApproval", submitted.Str("status"));
        Assert.Equal(1, submitted["approval"]!["totalSteps"]!.GetValue<int>());
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PutJson(Url(po), new { notes = "x" })).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson(Url(po, "/submit"))).StatusCode);

        // the creator cannot approve his own PO; the owner can
        var rid = submitted["approval"]!.Id();
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Proc.PostJson($"/api/v1/approvals/{rid}/approve", new { })).StatusCode);
        await (await o.Owner.PostJson($"/api/v1/approvals/{rid}/approve", new { })).Ok();

        var approved = await (await o.Proc.GetAsync(Url(po))).Ok();
        Assert.Equal("Approved", approved.Str("status"));
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Org.Requester.PostJson(Url(po, "/issue"))).StatusCode);
        var issued = await (await o.Proc.PostJson(Url(po, "/issue"))).Ok();
        Assert.Equal("Issued", issued.Str("status"));
        Assert.NotNull(issued["issuedAt"]);
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson(Url(po, "/issue"))).StatusCode);            // not twice
    }

    [Fact]
    public async Task Large_po_needs_manager_and_finance_approval()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Approved(o.Body(rate: 100000, qty: 8, discount: 0));     // well above 5,00,000
        Assert.Equal("Approved", po.Str("status"));
        Assert.Equal(2, po["approval"]!["totalSteps"]!.GetValue<int>());
    }

    [Fact]
    public async Task Rejected_po_returns_no_issue_and_returned_po_goes_back_to_draft()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Draft();
        var rid = (await (await o.Proc.PostJson(Url(po, "/submit"))).Ok())["approval"]!.Id();
        await (await o.Owner.PostJson($"/api/v1/approvals/{rid}/request-changes", new { comment = "Check rate" })).Ok();
        Assert.Equal("Draft", (await (await o.Proc.GetAsync(Url(po))).Ok()).Str("status"));
        var rid2 = (await (await o.Proc.PostJson(Url(po, "/submit"))).Ok())["approval"]!.Id();
        await (await o.Owner.PostJson($"/api/v1/approvals/{rid2}/reject", new { comment = "No" })).Ok();
        Assert.Equal("Rejected", (await (await o.Proc.GetAsync(Url(po))).Ok()).Str("status"));
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson(Url(po, "/issue"))).StatusCode);
    }

    [Fact]
    public async Task Issued_po_is_immutable_through_the_api_and_through_the_database()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Issued();
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PutJson(Url(po), new { notes = "sneaky", items = new[] { new { id = po["items"]![0]!.Id(), description = "x", quantity = 1, rate = 1 } } })).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson(Url(po, "/submit"))).StatusCode);

        // even direct SQL cannot change the commercial data of an issued PO (database trigger)
        var cs = factory.Services.GetRequiredService<IConfiguration>().GetConnectionString("VendorFlow");
        await using var conn = new NpgsqlConnection(cs);
        await conn.OpenAsync();
        var itemId = po["items"]![0]!.Id();
        var ex = await Assert.ThrowsAsync<PostgresException>(async () =>
        {
            await using var cmd = new NpgsqlCommand("update vendorflow.po_items set rate = 1 where id = @id", conn);
            cmd.Parameters.AddWithValue("id", itemId);
            await cmd.ExecuteNonQueryAsync();
        });
        Assert.Equal("VF409", ex.SqlState);
        var ex2 = await Assert.ThrowsAsync<PostgresException>(async () =>
        {
            await using var cmd = new NpgsqlCommand("update vendorflow.purchase_orders set total = 1 where id = @id", conn);
            cmd.Parameters.AddWithValue("id", po.Id());
            await cmd.ExecuteNonQueryAsync();
        });
        Assert.Equal("VF409", ex2.SqlState);
    }

    // ------------------------------------------------------------------ revisions, hold, close, cancel

    [Fact]
    public async Task Revision_snapshots_the_issued_version_and_requires_reapproval()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Issued();
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson(Url(po, "/revisions"), new { })).StatusCode);

        var rev = await (await o.Proc.PostJson(Url(po, "/revisions"), new { comment = "Quantity change requested" })).Ok();
        Assert.Equal("Draft", rev.Str("status"));
        Assert.Equal(1, rev["revision"]!.GetValue<int>());
        Assert.Single(rev["revisions"]!.AsArray());

        // edit the new revision: quantity 8 -> 10
        var edited = await (await o.Proc.PutJson(Url(po), new
        {
            items = new[] { new { id = po["items"]![0]!.Id(), description = "Cisco 24-port PoE switch", unit = "Nos", quantity = 10, rate = 24500, discountPercent = 5, taxPercent = 18 } }
        })).Ok();
        Assert.True(edited.Dec("total") > 222216m);

        var submitted = await (await o.Proc.PostJson(Url(po, "/submit"))).Ok();
        await (await o.Owner.PostJson($"/api/v1/approvals/{submitted["approval"]!.Id()}/approve", new { })).Ok();
        var reissued = await (await o.Proc.PostJson(Url(po, "/issue"))).Ok();
        Assert.Equal("Issued", reissued.Str("status"));
        Assert.Equal(1, reissued["revision"]!.GetValue<int>());
        Assert.Single(reissued["revisions"]!.AsArray());
        Assert.Contains(reissued["history"]!.AsArray(), h => h!.Str("action") == "revision_created");

        // the stored snapshot holds the original version (revision 0, 8 pieces)
        var cs = factory.Services.GetRequiredService<IConfiguration>().GetConnectionString("VendorFlow");
        await using var conn = new NpgsqlConnection(cs);
        await conn.OpenAsync();
        await using var q = new NpgsqlCommand("select snapshot::text from vendorflow.po_revisions where po_id = @id and revision = 0", conn);
        q.Parameters.AddWithValue("id", po.Id());
        var snap = JsonNode.Parse((string)(await q.ExecuteScalarAsync())!)!;
        Assert.Equal(8m, snap["items"]![0]!["quantity"]!.GetValue<decimal>());
    }

    [Fact]
    public async Task Hold_resume_close_and_cancel_rules()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Issued();
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson(Url(po, "/hold"), new { })).StatusCode);
        Assert.Equal("OnHold", (await (await o.Proc.PostJson(Url(po, "/hold"), new { comment = "Vendor audit" })).Ok()).Str("status"));
        Assert.Equal("Issued", (await (await o.Proc.PostJson(Url(po, "/resume"))).Ok()).Str("status"));
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson(Url(po, "/close"), new { })).StatusCode);     // nothing received yet
        Assert.Equal(HttpStatusCode.BadRequest, (await o.Proc.PostJson(Url(po, "/cancel"), new { })).StatusCode);
        Assert.Equal("Cancelled", (await (await o.Proc.PostJson(Url(po, "/cancel"), new { comment = "Not needed" })).Ok()).Str("status"));
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson(Url(po, "/issue"))).StatusCode);
    }

    [Fact]
    public async Task Acknowledgement_is_recorded_once()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Issued();
        var ack = await (await o.Proc.PostJson(Url(po, "/acknowledge"))).Ok();
        Assert.NotNull(ack["acknowledgedAt"]);
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson(Url(po, "/acknowledge"))).StatusCode);
    }

    // ------------------------------------------------------------------ conversion from requisition and RFQ

    [Fact]
    public async Task Requisition_converts_to_a_po_once_and_cancelling_the_po_frees_it_again()
    {
        var o = await PoOrg.Create(factory);
        var notApproved = await o.Org.Submitted(10_000);
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson($"/api/v1/purchase-orders/from-requisition/{notApproved.Id()}", new { vendorId = o.VendorId })).StatusCode);

        await (await o.Org.DeptManager.PostJson($"/api/v1/approvals/{ApprovalOrg.RequestId(notApproved)}/approve", new { })).Ok();
        var po = await (await o.Proc.PostJson($"/api/v1/purchase-orders/from-requisition/{notApproved.Id()}", new { vendorId = o.VendorId, shipping = 100 })).Ok();
        Assert.Equal(notApproved.Str("number"), po.Str("requisitionNumber"));
        Assert.Equal("ConvertedToPO", (await (await o.Owner.GetAsync($"/api/v1/requisitions/{notApproved.Id()}")).Ok()).Str("status"));
        Assert.Equal(HttpStatusCode.Conflict, (await o.Proc.PostJson($"/api/v1/purchase-orders/from-requisition/{notApproved.Id()}", new { vendorId = o.VendorId })).StatusCode);

        await (await o.Proc.PostJson(Url(po, "/cancel"), new { comment = "Wrong vendor" })).Ok();
        Assert.Equal("Approved", (await (await o.Owner.GetAsync($"/api/v1/requisitions/{notApproved.Id()}")).Ok()).Str("status"));
    }

    [Fact]
    public async Task Po_from_rfq_needs_a_recommendation_and_uses_the_recommended_quotation()
    {
        var org = await ApprovalOrg.Create(factory);
        var s = await RfqSetup.Open(factory, 2, org);
        var (proc, _, _) = await org.Tenant.AddUser("Pat Procurement", "ProcurementManager");
        await s.Submit(factory, 0, s.Quote(1000, discount: 0, tax: 18, shipping: 50, days: 9));
        await s.Submit(factory, 1, s.Quote(900, discount: 0, tax: 18, shipping: 70, days: 4));

        var url = $"/api/v1/purchase-orders/from-rfq/{s.RfqId}";
        Assert.Equal(HttpStatusCode.Conflict, (await proc.PostJson(url, new { })).StatusCode);       // no recommendation yet

        await (await s.Buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/recommendation", new { vendorId = s.Vendors[0], justification = "Better support history" })).Ok();
        var po = await (await proc.PostJson(url, new { })).Ok();
        Assert.Equal(s.Vendors[0].ToString(), po.Str("vendorId"));                                   // recommended, not cheapest
        Assert.Equal(1000m, po["items"]![0]!.Dec("rate"));
        Assert.Equal(8m, po["items"]![0]!.Dec("quantity"));
        Assert.Equal(50m, po.Dec("shipping"));
        Assert.Equal(9490m, po.Dec("total"));                                                        // 8 x 1000 + 18% GST + 50 shipping
        Assert.Equal("Awarded", (await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok()).Str("status"));
        Assert.Equal(HttpStatusCode.Conflict, (await proc.PostJson(url, new { })).StatusCode);       // awarded RFQ cannot create a second PO

        await (await proc.PostJson(Url(po, "/cancel"), new { comment = "Re-tender" })).Ok();
        Assert.Equal("Closed", (await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok()).Str("status"));
    }

    // ------------------------------------------------------------------ list, pdf, isolation

    [Fact]
    public async Task List_filters_stats_and_csv_export()
    {
        var o = await PoOrg.Create(factory);
        await o.Draft();
        var issued = await o.Issued();
        var list = await (await o.Proc.GetAsync("/api/v1/purchase-orders")).Ok();
        Assert.Equal(2, list["totalCount"]!.GetValue<int>());
        Assert.Equal(1, list["stats"]!["draft"]!["count"]!.GetValue<int>());
        Assert.Equal(1, list["stats"]!["awaitingReceipt"]!["count"]!.GetValue<int>());
        Assert.Equal(222216m, list["stats"]!["awaitingReceipt"]!.Dec("amount"));
        Assert.Equal(1, (await (await o.Proc.GetAsync("/api/v1/purchase-orders?status=Issued")).Ok())["totalCount"]!.GetValue<int>());
        Assert.Equal(1, (await (await o.Proc.GetAsync($"/api/v1/purchase-orders?search={issued.Str("number")}")).Ok())["totalCount"]!.GetValue<int>());
        var csv = await (await o.Proc.GetAsync("/api/v1/purchase-orders/export")).Content.ReadAsStringAsync();
        Assert.StartsWith("PO number,Vendor", csv);
    }

    [Fact]
    public async Task Pdf_is_generated_with_the_configured_display_name_and_download_is_audited()
    {
        var o = await PoOrg.Create(factory);
        await o.Owner.PutJson("/api/v1/organizations/current/settings", new { appDisplayName = "Acme Procure" });
        var po = await o.Issued();
        var res = await o.Proc.GetAsync(Url(po, "/pdf"));
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        Assert.Equal("application/pdf", res.Content.Headers.ContentType!.MediaType);
        var bytes = await res.Content.ReadAsByteArrayAsync();
        Assert.StartsWith("%PDF", System.Text.Encoding.ASCII.GetString(bytes, 0, 4));
        Assert.True(bytes.Length > 1000);

        var audit = await (await o.Owner.GetAsync("/api/v1/audit?pageSize=200")).Ok();
        Assert.Contains(audit["items"]!.AsArray(), a => a!.Str("action") == "po.pdf_downloaded");
        // the data given to the PDF builder carries the tenant's display name
        var cs = factory.Services.GetRequiredService<IConfiguration>().GetConnectionString("VendorFlow");
        await using var conn = new NpgsqlConnection(cs);
        await conn.OpenAsync();
        await using var q = new NpgsqlCommand("select (vendorflow.fn_po_pdf_data(@t, @p) -> 'organization' ->> 'app_display_name')", conn);
        q.Parameters.AddWithValue("t", o.Org.Tenant.TenantId);
        q.Parameters.AddWithValue("p", po.Id());
        Assert.Equal("Acme Procure", (string)(await q.ExecuteScalarAsync())!);
    }

    [Fact]
    public async Task Other_tenant_cannot_read_issue_cancel_or_download_a_po()
    {
        var a = await PoOrg.Create(factory);
        var b = await PoOrg.Create(factory);
        var po = await a.Issued();
        Assert.Equal(HttpStatusCode.NotFound, (await b.Proc.GetAsync(Url(po))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Proc.GetAsync(Url(po, "/pdf"))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Proc.PostJson(Url(po, "/cancel"), new { comment = "x" })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Proc.PostJson(Url(po, "/revisions"), new { comment = "x" })).StatusCode);
        Assert.Equal(0, (await (await b.Proc.GetAsync("/api/v1/purchase-orders")).Ok())["totalCount"]!.GetValue<int>());
    }

    [Fact]
    public async Task Auditor_can_view_but_not_change_purchase_orders()
    {
        var o = await PoOrg.Create(factory);
        var po = await o.Issued();
        var (auditor, _, _) = await o.Org.Tenant.AddUser("Aud Itor", "Auditor");
        Assert.Equal(HttpStatusCode.OK, (await auditor.GetAsync(Url(po))).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await auditor.PostJson("/api/v1/purchase-orders", o.Body())).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await auditor.PostJson(Url(po, "/cancel"), new { comment = "x" })).StatusCode);
    }
}
