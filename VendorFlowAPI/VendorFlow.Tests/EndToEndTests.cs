using System.Net;
using System.Net.Http.Json;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

/// <summary>
/// One story through the whole product, through the real HTTP API and database:
/// tenant → settings → vendors → requisition → approval → RFQ → vendor quotes → compare → recommendation → PO → approval → issue
/// → partial goods receipt → invoice → reconcile → partial payment → balances → dashboard / report / audit / performance.
/// </summary>
[Collection("api")]
public class EndToEndTests(ApiFactory factory)
{
    [Fact]
    public async Task Full_procurement_cycle_from_requisition_to_partial_payment()
    {
        // ---- 1. organization and settings (renamed terminology)
        var t = await TestTenant.Create(factory, "Acme Constructions");
        var settings = await (await t.Owner.PutJson("/api/v1/organizations/current/settings",
            new { appDisplayName = "Acme Procure", vendorLabelSingular = "Supplier", vendorLabelPlural = "Suppliers" })).Ok();
        Assert.Equal("Suppliers", settings.Str("vendorLabelPlural"));

        var (requester, _, _) = await t.AddUser("Rita Requester", "DepartmentRequester");
        var (deptMgr, _, _) = await t.AddUser("Dev Manager", "DepartmentManager");
        var (finance, _, _) = await t.AddUser("Fay Finance", "FinanceManager");
        var (proc, _, _) = await t.AddUser("Pat Procurement", "ProcurementManager");
        var (warehouse, _, _) = await t.AddUser("Wally Warehouse", "WarehouseManager");
        var owner = t.Owner;

        // ---- 2. vendors: draft -> submitted -> approved, with bank details protected
        var vendorIds = new List<Guid>();
        foreach (var name in new[] { "Sona Tech", "NextGen Networks", "Delta Industrial" })
            vendorIds.Add(await Fixtures.ApprovedVendor(owner, name + " " + Guid.NewGuid().ToString("N")[..4]));
        await (await finance.PutJson($"/api/v1/vendors/{vendorIds[0]}/bank", new { accountName = "Sona", accountNumber = "123456789", ifsc = "HDFC0001234" })).Ok();

        // ---- 3. requisition for 8 switches (2,40,000) goes through manager and finance
        var depts = await (await owner.GetAsync("/api/v1/lookups/departments")).Ok();
        var ccs = await (await owner.GetAsync("/api/v1/lookups/cost-centres")).Ok();
        var req = await (await requester.PostJson("/api/v1/requisitions", new
        {
            title = "Network switches", departmentId = depts.AsArray().First(d => d!.Str("name") == "IT")!.Id(),
            costCentreId = ccs.AsArray().First(c => c!.Str("code") == "CC-IT-01")!.Id(),
            requiredDate = DateOnly.FromDateTime(DateTime.Today.AddDays(20)).ToString("yyyy-MM-dd"),
            items = new[] { new { description = "24-port PoE switch", unit = "Nos", quantity = 8, estUnitPrice = 30000 } }
        })).Ok();
        var submitted = await (await requester.PostJson($"/api/v1/requisitions/{req.Id()}/submit")).Ok();
        Assert.Equal(2, submitted["approval"]!["totalSteps"]!.GetValue<int>());
        var approvalId = submitted["approval"]!.Id();
        await (await deptMgr.PostJson($"/api/v1/approvals/{approvalId}/approve", new { comment = "ok" })).Ok();
        await (await finance.PostJson($"/api/v1/approvals/{approvalId}/approve", new { comment = "budget ok" })).Ok();
        Assert.Equal("Approved", (await (await requester.GetAsync($"/api/v1/requisitions/{req.Id()}")).Ok()).Str("status"));

        // ---- 4. RFQ to three suppliers; each quotes through its private link
        var rfq = await (await proc.PostJson("/api/v1/rfqs", new
        {
            title = "Network switches", requisitionId = req.Id(), deadline = DateTimeOffset.UtcNow.AddDays(7).ToString("o"), vendorIds
        })).Ok();
        var opened = await (await proc.PostJson($"/api/v1/rfqs/{rfq.Id()}/open")).Ok();
        var itemId = opened["rfq"]!["items"]![0]!.Id();
        string TokenOf(Guid v) => RfqSetup.TokenFromLink(opened["invitations"]!.AsArray().First(i => i!.Str("vendorId") == v.ToString())!.Str("link"));
        var prices = new[] { (26000m, 10, "Net 30"), (24500m, 21, "Advance 50%"), (27200m, 7, "Net 45") };
        for (var i = 0; i < 3; i++)
        {
            var res = await factory.CreateClient().PostJson($"/api/v1/portal/rfq/{TokenOf(vendorIds[i])}/quotation", new
            {
                shipping = 0, deliveryDays = prices[i].Item2, paymentTerms = prices[i].Item3, warrantyMonths = 24,
                items = new[] { new { rfqItemId = itemId, unitPrice = prices[i].Item1, discountPercent = 0, taxPercent = 18 } }
            });
            Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        }

        // ---- 5. comparison never picks a winner; the buyer recommends the fastest, not the cheapest, with a reason
        var cmp = await (await proc.GetAsync($"/api/v1/rfqs/{rfq.Id()}/compare")).Ok();
        Assert.Null(cmp["recommendation"]);
        Assert.Equal(vendorIds[1].ToString(), cmp.Str("lowestVendorId"));
        await (await proc.PostJson($"/api/v1/rfqs/{rfq.Id()}/recommendation", new { vendorId = vendorIds[0], justification = "Best support and 10-day delivery" })).Ok();

        // ---- 6. purchase order from the recommendation: approval, issue
        var po = await (await proc.PostJson($"/api/v1/purchase-orders/from-rfq/{rfq.Id()}", new { })).Ok();
        Assert.Equal(vendorIds[0].ToString(), po.Str("vendorId"));
        Assert.Equal(8m * 26000m * 1.18m, po.Dec("total"));                         // 2,45,440.00
        var poSubmitted = await (await proc.PostJson($"/api/v1/purchase-orders/{po.Id()}/submit")).Ok();
        await (await owner.PostJson($"/api/v1/approvals/{poSubmitted["approval"]!.Id()}/approve", new { })).Ok();
        var issued = await (await proc.PostJson($"/api/v1/purchase-orders/{po.Id()}/issue")).Ok();
        Assert.Equal("Issued", issued.Str("status"));
        Assert.Equal("ConvertedToPO", (await (await requester.GetAsync($"/api/v1/requisitions/{req.Id()}")).Ok()).Str("status"));
        Assert.Equal("Awarded", (await (await proc.GetAsync($"/api/v1/rfqs/{rfq.Id()}")).Ok()).Str("status"));

        // ---- 7. partial goods receipt: 5 of 8 arrive, 1 rejected
        var poItem = issued["items"]![0]!.Id();
        var grn = await (await warehouse.PostJson($"/api/v1/purchase-orders/{po.Id()}/receipts", new
        {
            deliveryChallan = "DC-E2E-1", items = new[] { new { poItemId = poItem, receivedQty = 5, acceptedQty = 4, rejectedQty = 1, damagedQty = 1 } }
        })).Ok();
        Assert.StartsWith("GRN-", grn.Str("number"));
        var afterGrn = await (await proc.GetAsync($"/api/v1/purchase-orders/{po.Id()}")).Ok();
        Assert.Equal("PartiallyReceived", afterGrn.Str("status"));
        Assert.Equal(4m, afterGrn["items"]![0].Dec("receivedQty"));
        // over-receipt is blocked
        Assert.Equal(HttpStatusCode.Conflict, (await warehouse.PostJson($"/api/v1/purchase-orders/{po.Id()}/receipts", new
        {
            deliveryChallan = "DC-E2E-2", items = new[] { new { poItemId = poItem, receivedQty = 5, acceptedQty = 5, rejectedQty = 0 } }
        })).StatusCode);

        // ---- 8. invoice: billing 5 when only 4 were accepted is caught; the corrected invoice matches and is reconciled
        var number = "INV-E2E-" + Guid.NewGuid().ToString("N")[..5];
        var wrong = await (await finance.PostJson("/api/v1/invoices", new
        {
            poId = po.Id(), invoiceNumber = number, invoiceDate = DateOnly.FromDateTime(DateTime.Today).ToString("yyyy-MM-dd"),
            items = new[] { new { poItemId = poItem, quantity = 5 } }
        })).Ok();
        Assert.Equal("NeedsReview", wrong.Str("status"));
        Assert.Equal(HttpStatusCode.Conflict, (await finance.PostJson($"/api/v1/invoices/{wrong.Id()}/reconcile", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await finance.PostJson("/api/v1/invoices", new
        {
            poId = po.Id(), invoiceNumber = number.ToLowerInvariant(), invoiceDate = DateOnly.FromDateTime(DateTime.Today).ToString("yyyy-MM-dd"),
            items = new[] { new { poItemId = poItem, quantity = 4 } }
        })).StatusCode);                                                                // duplicate invoice number

        var fixedInvoice = await (await finance.PutJson($"/api/v1/invoices/{wrong.Id()}", new { items = new[] { new { poItemId = poItem, quantity = 4 } } })).Ok();
        Assert.Equal("Matched", fixedInvoice.Str("status"));
        Assert.Equal(4m * 26000m * 1.18m, fixedInvoice.Dec("total"));                 // 1,22,720.00
        var reconciled = await (await finance.PostJson($"/api/v1/invoices/{wrong.Id()}/reconcile", new { })).Ok();
        Assert.Equal("Approved", reconciled.Str("status"));

        // ---- 9. partial payment with idempotency
        var key = Guid.NewGuid().ToString();
        HttpRequestMessage Pay(decimal amount) => new(HttpMethod.Post, "/api/v1/payments")
        {
            Content = JsonContent.Create(new { invoiceId = wrong.Id(), amount, method = "NEFT", reference = "UTR-E2E" }, options: Http.Json),
            Headers = { { "Idempotency-Key", key } }
        };
        var pay1 = await (await finance.SendAsync(Pay(50000))).Content.ReadAsStringAsync();
        var pay2 = await (await finance.SendAsync(Pay(50000))).Content.ReadAsStringAsync();      // replay: same key
        Assert.Contains("\"replayed\":true", pay2);
        var invoiceNow = await (await finance.GetAsync($"/api/v1/invoices/{wrong.Id()}")).Ok();
        Assert.Equal(50000m, invoiceNow.Dec("paidAmount"));
        Assert.Equal(72720m, invoiceNow.Dec("balance"));
        Assert.Equal("PartiallyPaid", invoiceNow.Str("status"));
        Assert.NotNull(pay1);

        // ---- 10. what the rest of the system now shows
        var dashboard = await (await owner.GetAsync("/api/v1/dashboard")).Ok();
        Assert.Equal(245440m, dashboard["kpis"]!["totalProcurement"]!.Dec("value"));
        Assert.Equal("IT", dashboard["spendByDepartment"]![0]!.Str("name"));
        Assert.Equal(72720m, dashboard["kpis"]!["outstandingPayments"]!.Dec("amount"));

        var expenditure = await (await owner.GetAsync("/api/v1/reports/expenditure?groupBy=vendor")).Ok();
        Assert.Equal(245440m, expenditure["rows"]![0]!.Dec("amount"));

        var performance = await (await owner.GetAsync($"/api/v1/vendors/{vendorIds[0]}/performance")).Ok();
        Assert.NotNull(performance["score"]);
        var metrics = performance["metrics"]!.AsArray();
        Assert.Equal(80m, metrics.First(m => m!.Str("key") == "acceptedQty")!.Dec("value"));       // 4 of 5 accepted
        Assert.Equal(100m, metrics.First(m => m!.Str("key") == "responsiveness")!.Dec("value"));   // answered the RFQ

        var audit = await (await owner.GetAsync("/api/v1/audit?pageSize=200")).Ok();
        var actions = audit["items"]!.AsArray().Select(a => a!.Str("action")).ToHashSet();
        foreach (var expected in new[] { "tenant.registered", "settings.updated", "vendor.approve", "vendor.bank_changed", "requisition.submitted", "approval.approve", "rfq.opened",
                                         "quotation.recommended", "po.created", "po.issued", "grn.posted", "invoice.registered", "invoice.reconciled", "payment.recorded" })
            Assert.Contains(expected, actions);

        // ---- 11. tenant isolation at the end: a second organization sees none of it
        var other = await TestTenant.Create(factory);
        Assert.Equal(0, (await (await other.Owner.GetAsync("/api/v1/purchase-orders")).Ok())["totalCount"]!.GetValue<int>());
        Assert.Equal(0, (await (await other.Owner.GetAsync("/api/v1/invoices")).Ok())["totalCount"]!.GetValue<int>());
        Assert.Equal(HttpStatusCode.NotFound, (await other.Owner.GetAsync($"/api/v1/purchase-orders/{po.Id()}")).StatusCode);
        Assert.Equal(0m, (await (await other.Owner.GetAsync("/api/v1/dashboard")).Ok())["kpis"]!["totalProcurement"]!.Dec("value"));
        var otherSettings = await (await other.Owner.GetAsync("/api/v1/organizations/current/settings")).Ok();
        Assert.Equal("Vendors", otherSettings.Str("vendorLabelPlural"));
    }
}
