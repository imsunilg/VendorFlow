using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

/// <summary>
/// Issued PO with line A (10 x 1000, GST 18%) and line B (5 x 200, GST 18%).
/// Goods received: A 10 accepted, B 4 accepted + 1 rejected.  -> receipt value 11,800 + 944 = 12,744.
/// </summary>
public sealed class InvSetup
{
    public required PoOrg Org { get; init; }
    public required JsonNode Po { get; init; }
    public required HttpClient Warehouse { get; init; }
    public required HttpClient Finance { get; init; }
    public Guid A => Po["items"]![0]!.Id();
    public Guid B => Po["items"]![1]!.Id();
    public string PoUrl => $"/api/v1/purchase-orders/{Po.Id()}";

    public static async Task<InvSetup> Create(ApiFactory f, bool receive = true)
    {
        var org = await PoOrg.Create(f);
        var (wh, _, _) = await org.Org.Tenant.AddUser("Wally Warehouse", "WarehouseManager");
        var po = await org.Issued(new
        {
            vendorId = org.VendorId, shipping = 0,
            items = new object[]
            {
                new { description = "Item A", unit = "Nos", quantity = 10, rate = 1000, discountPercent = 0, taxPercent = 18 },
                new { description = "Item B", unit = "Nos", quantity = 5, rate = 200, discountPercent = 0, taxPercent = 18 }
            }
        });
        var s = new InvSetup { Org = org, Po = po, Warehouse = wh, Finance = org.Org.Finance };
        if (receive)
        {
            await (await wh.PostJson($"{s.PoUrl}/receipts", new
            {
                deliveryChallan = "DC-" + Guid.NewGuid().ToString("N")[..6],
                items = new object[]
                {
                    new { poItemId = s.A, receivedQty = 10, acceptedQty = 10, rejectedQty = 0 },
                    new { poItemId = s.B, receivedQty = 5, acceptedQty = 4, rejectedQty = 1, damagedQty = 1 }
                }
            })).Ok();
        }
        return s;
    }

    public object Invoice(string number, decimal qtyA = 10, decimal qtyB = 4, decimal? rateA = null, decimal? taxA = null,
        decimal? discountA = null, string? matchType = null, DateOnly? date = null, DateOnly? due = null) => new
    {
        poId = Po.Id(), invoiceNumber = number, matchType,
        invoiceDate = (date ?? DateOnly.FromDateTime(DateTime.Today)).ToString("yyyy-MM-dd"),
        dueDate = due?.ToString("yyyy-MM-dd"),
        items = new object[]
        {
            new { poItemId = A, quantity = qtyA, rate = rateA, taxAmount = taxA, discountPercent = discountA },
            new { poItemId = B, quantity = qtyB }
        }
    };

    public async Task<JsonNode> Register(string number, object? body = null) =>
        await (await Finance.PostJson("/api/v1/invoices", body ?? Invoice(number))).Ok();

    public async Task<JsonNode> Approved(string number)
    {
        var inv = await Register(number);
        return await (await Finance.PostJson($"/api/v1/invoices/{inv.Id()}/reconcile", new { comment = "ok" })).Ok();
    }

    public static string Num() => "INV-" + Guid.NewGuid().ToString("N")[..8].ToUpperInvariant();
    public static string[] Checks(JsonNode inv) => inv["discrepancies"]!.AsArray().Select(d => d!.Str("checkName")).ToArray();
}

[Collection("api")]
public class InvoiceTests(ApiFactory factory)
{
    [Fact]
    public async Task Perfect_three_way_match_is_matched_with_zero_variance()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Register(InvSetup.Num());
        Assert.Equal("Matched", inv.Str("status"));
        Assert.Equal(12744m, inv.Dec("total"));
        Assert.Equal(12744m, inv.Dec("receiptValue"));
        Assert.Equal(0m, inv.Dec("varianceAmount"));
        Assert.Empty(inv["discrepancies"]!.AsArray());
        Assert.False(inv["duplicateCheck"]!["duplicateFound"]!.GetValue<bool>());
        Assert.All(inv["lines"]!.AsArray(), l => Assert.True(l!["qtyOk"]!.GetValue<bool>() && l["rateOk"]!.GetValue<bool>() && l["taxOk"]!.GetValue<bool>()));
        Assert.Equal(inv.Dec("total") - inv.Dec("subtotal"), inv.Dec("taxTotal"));
    }

    [Fact]
    public async Task Invoicing_more_than_was_accepted_is_a_mandatory_mismatch_even_inside_the_tolerance()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Register("X1", s.Invoice("X1", qtyB: 5));            // only 4 B accepted
        Assert.Equal("NeedsReview", inv.Str("status"));
        Assert.Contains("qty", InvSetup.Checks(inv));
        Assert.DoesNotContain("total_variance", InvSetup.Checks(inv));          // 1.85% is inside the default 2% tolerance
        Assert.False(inv["lines"]![1]!["qtyOk"]!.GetValue<bool>());
        Assert.Equal(1180m + 11800m, inv.Dec("total"));
        Assert.Equal(236m, inv.Dec("varianceAmount"));
        Assert.Equal(HttpStatusCode.Conflict, (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/reconcile", new { })).StatusCode);
    }

    [Fact]
    public async Task Rate_discount_and_tax_differences_are_detected()
    {
        var s = await InvSetup.Create(factory);
        Assert.Contains("rate", InvSetup.Checks(await s.Register("R1", s.Invoice("R1", rateA: 1010))));
        Assert.Contains("discount", InvSetup.Checks(await s.Register("D1", s.Invoice("D1", discountA: 10))));
        var tax = await s.Register("T1", s.Invoice("T1", taxA: 1000));          // expected 1800
        Assert.Contains("tax", InvSetup.Checks(tax));
        Assert.False(tax["lines"]![0]!["taxOk"]!.GetValue<bool>());
        // a one-rupee rounding difference in tax is tolerated
        Assert.Equal("Matched", (await s.Register("T2", s.Invoice("T2", taxA: 1800.80m))).Str("status"));
    }

    [Fact]
    public async Task Total_variance_beyond_the_configured_tolerance_blocks_reconciliation()
    {
        var s = await InvSetup.Create(factory);
        await (await s.Org.Owner.PutJson("/api/v1/organizations/current/settings", new { invoiceTolerancePct = 0 })).Ok();
        var inv = await s.Register("V1", s.Invoice("V1", qtyB: 5));
        Assert.Contains("total_variance", InvSetup.Checks(inv));

        // widen the tolerance and match again: the quantity mismatch still blocks
        await (await s.Org.Owner.PutJson("/api/v1/organizations/current/settings", new { invoiceTolerancePct = 10 })).Ok();
        var again = await (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/rematch")).Ok();
        Assert.DoesNotContain("total_variance", InvSetup.Checks(again));
        Assert.Contains("qty", InvSetup.Checks(again));
        Assert.Equal("NeedsReview", again.Str("status"));
    }

    [Fact]
    public async Task Two_way_match_checks_against_the_po_and_ignores_receipts()
    {
        var s = await InvSetup.Create(factory, receive: false);
        Assert.Equal("NeedsReview", (await s.Register("W3", s.Invoice("W3", qtyB: 5))).Str("status"));          // nothing received -> 3-way fails
        var two = await s.Register("W2", s.Invoice("W2", qtyB: 5, matchType: "TwoWay"));
        Assert.Equal("Matched", two.Str("status"));
        Assert.Equal("TwoWay", two.Str("matchType"));
        // 2-way still blocks billing above the ordered quantity
        Assert.Contains("qty", InvSetup.Checks(await s.Register("W4", s.Invoice("W4", qtyA: 11, matchType: "TwoWay"))));
    }

    [Fact]
    public async Task Duplicate_invoice_numbers_are_rejected_per_vendor_until_cancelled()
    {
        var s = await InvSetup.Create(factory);
        var first = await s.Register("DUP-1");
        Assert.Equal(HttpStatusCode.Conflict, (await s.Finance.PostJson("/api/v1/invoices", s.Invoice("dup-1"))).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await s.Finance.PostJson("/api/v1/invoices", s.Invoice("  DUP-1 "))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Finance.PostJson($"/api/v1/invoices/{first.Id()}/cancel", new { })).StatusCode);
        await (await s.Finance.PostJson($"/api/v1/invoices/{first.Id()}/cancel", new { comment = "Entered twice" })).Ok();
        Assert.Equal(HttpStatusCode.OK, (await s.Finance.PostJson("/api/v1/invoices", s.Invoice("DUP-1"))).StatusCode);
    }

    [Fact]
    public async Task Reconcile_approves_and_the_same_goods_cannot_be_invoiced_twice()
    {
        var s = await InvSetup.Create(factory);
        var approved = await s.Approved(InvSetup.Num());
        Assert.Equal("Approved", approved.Str("status"));
        Assert.Equal(10m, (await (await s.Org.Proc.GetAsync(s.PoUrl)).Ok())["items"]![0]!.Dec("invoicedQty"));
        Assert.Equal(HttpStatusCode.Conflict, (await s.Finance.PostJson($"/api/v1/invoices/{approved.Id()}/reconcile", new { })).StatusCode);

        var second = await s.Register(InvSetup.Num());
        Assert.Equal("NeedsReview", second.Str("status"));
        Assert.Contains("qty", InvSetup.Checks(second));
        Assert.Equal(0m, second["lines"]![0]!.Dec("grnQty") - second["lines"]![0]!.Dec("previouslyInvoicedQty"));
    }

    [Fact]
    public async Task Dispute_and_correction_flow()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Register("DS-1", s.Invoice("DS-1", qtyB: 5));
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/discrepancies", new { })).StatusCode);
        var disputed = await (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/discrepancies", new { comment = "Vendor billed a rejected item" })).Ok();
        Assert.Equal("Disputed", disputed.Str("status"));
        Assert.Contains("manual", InvSetup.Checks(disputed));
        Assert.Equal(HttpStatusCode.Conflict, (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/reconcile", new { })).StatusCode);

        // the vendor sends a corrected bill: update -> matched again
        var fixedInv = await (await s.Finance.PutJson($"/api/v1/invoices/{inv.Id()}", new
        {
            items = new object[] { new { poItemId = s.A, quantity = 10 }, new { poItemId = s.B, quantity = 4 } }
        })).Ok();
        Assert.Equal("Matched", fixedInv.Str("status"));
        Assert.Empty(fixedInv["discrepancies"]!.AsArray());
        Assert.Equal("Approved", (await (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/reconcile", new { })).Ok()).Str("status"));
        Assert.Equal(HttpStatusCode.Conflict, (await s.Finance.PutJson($"/api/v1/invoices/{inv.Id()}", new { notes = "late" })).StatusCode);
    }

    [Fact]
    public async Task A_late_goods_receipt_can_fix_the_match_through_rematch()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Register("LATE-1", s.Invoice("LATE-1", qtyB: 5));
        Assert.Equal("NeedsReview", inv.Str("status"));
        await (await s.Warehouse.PostJson($"{s.PoUrl}/receipts", new
        {
            deliveryChallan = "DC-LATE", items = new object[] { new { poItemId = s.B, receivedQty = 1, acceptedQty = 1, rejectedQty = 0 } }
        })).Ok();
        Assert.Equal("Matched", (await (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/rematch")).Ok()).Str("status"));
    }

    [Fact]
    public async Task Registration_validation()
    {
        var s = await InvSetup.Create(factory);
        var tomorrow = DateOnly.FromDateTime(DateTime.Today.AddDays(1));
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Finance.PostJson("/api/v1/invoices", s.Invoice("", qtyB: 1))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Finance.PostJson("/api/v1/invoices", s.Invoice("F1", date: tomorrow))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Finance.PostJson("/api/v1/invoices", s.Invoice("F2", due: DateOnly.FromDateTime(DateTime.Today.AddDays(-5))))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Finance.PostJson("/api/v1/invoices", new { poId = s.Po.Id(), invoiceNumber = "F3", invoiceDate = "2026-01-01", items = Array.Empty<object>() })).StatusCode);
        // a line of another PO
        var other = await InvSetup.Create(factory, receive: false);
        var body = new { poId = s.Po.Id(), invoiceNumber = "F4", invoiceDate = "2026-01-01", items = new[] { new { poItemId = other.A, quantity = 1 } } };
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Finance.PostJson("/api/v1/invoices", body)).StatusCode);
        // a draft PO cannot be invoiced
        var draft = await s.Org.Draft();
        var draftBody = new { poId = draft.Id(), invoiceNumber = "F5", invoiceDate = "2026-01-01", items = new[] { new { poItemId = draft["items"]![0]!.Id(), quantity = 1 } } };
        Assert.Equal(HttpStatusCode.Conflict, (await s.Finance.PostJson("/api/v1/invoices", draftBody)).StatusCode);
    }

    [Fact]
    public async Task Due_date_defaults_to_vendor_payment_terms_and_overdue_invoices_are_listed()
    {
        var s = await InvSetup.Create(factory);
        var old = DateOnly.FromDateTime(DateTime.Today.AddDays(-60));
        var inv = await (await s.Finance.PostJson("/api/v1/invoices", s.Invoice(InvSetup.Num(), date: old))).Ok();
        Assert.Equal(old.AddDays(30).ToString("yyyy-MM-dd"), inv.Str("dueDate"));
        await (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/reconcile", new { })).Ok();

        var overdue = await (await s.Finance.GetAsync("/api/v1/invoices?tab=overdue")).Ok();
        Assert.Equal(1, overdue["totalCount"]!.GetValue<int>());
        Assert.Equal(30, overdue["items"]![0]!["daysOverdue"]!.GetValue<int>());
        Assert.Equal(1, overdue["statusCounts"]!["Overdue"]!.GetValue<int>());
        Assert.Equal(1, (await (await s.Finance.GetAsync("/api/v1/invoices?tab=outstanding")).Ok())["totalCount"]!.GetValue<int>());
        var csv = await (await s.Finance.GetAsync("/api/v1/invoices/export")).Content.ReadAsStringAsync();
        Assert.StartsWith("Invoice,Vendor", csv);
    }

    [Fact]
    public async Task Permissions_for_invoices()
    {
        var s = await InvSetup.Create(factory);
        Assert.Equal(HttpStatusCode.Forbidden, (await s.Warehouse.PostJson("/api/v1/invoices", s.Invoice("P1"))).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await s.Org.Org.Requester.GetAsync("/api/v1/invoices")).StatusCode);
        var (ap, _, _) = await s.Org.Org.Tenant.AddUser("Ann Payable", "AccountsPayableOfficer");
        var inv = await (await ap.PostJson("/api/v1/invoices", s.Invoice("P2"))).Ok();
        Assert.Equal(HttpStatusCode.OK, (await ap.PostJson($"/api/v1/invoices/{inv.Id()}/reconcile", new { })).StatusCode);
        var (proc, _, _) = await s.Org.Org.Tenant.AddUser("Pia Proc", "ProcurementOfficer");
        Assert.Equal(HttpStatusCode.OK, (await proc.GetAsync($"/api/v1/invoices/{inv.Id()}")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await proc.PostJson($"/api/v1/invoices/{inv.Id()}/reconcile", new { })).StatusCode);
    }

    [Fact]
    public async Task Other_tenant_cannot_register_read_or_reconcile()
    {
        var a = await InvSetup.Create(factory);
        var b = await InvSetup.Create(factory);
        var inv = await a.Register(InvSetup.Num());
        Assert.Equal(HttpStatusCode.NotFound, (await b.Finance.GetAsync($"/api/v1/invoices/{inv.Id()}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/reconcile", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Finance.PostJson("/api/v1/invoices", a.Invoice("STEAL"))).StatusCode);   // A's PO id
        Assert.Equal(0, (await (await b.Finance.GetAsync("/api/v1/invoices?search=INV")).Ok())["totalCount"]!.GetValue<int>());
    }
}

[Collection("api")]
public class PaymentTests(ApiFactory factory)
{
    private static Task<HttpResponseMessage> Pay(HttpClient c, Guid invoice, decimal amount, string? key = null, string method = "NEFT", string? paidOn = null)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, "/api/v1/payments")
        {
            Content = JsonContent.Create(new { invoiceId = invoice, amount, method, reference = "UTR882310", paidOn }, options: Http.Json)
        };
        if (key is not null) req.Headers.Add("Idempotency-Key", key);
        return c.SendAsync(req);
    }

    private static string Key() => Guid.NewGuid().ToString();

    [Fact]
    public async Task Partial_then_final_payment_updates_balance_and_status()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Approved(InvSetup.Num());                       // total 12,744
        var p1 = await Pay(s.Finance, inv.Id(), 5000, Key());
        Assert.Equal(HttpStatusCode.Created, p1.StatusCode);
        var b1 = await p1.Ok();
        Assert.StartsWith("PAY-", b1.Str("number"));
        Assert.Equal(7744m, b1.Dec("balance"));
        Assert.Equal("PartiallyPaid", b1.Str("invoiceStatus"));

        var p2 = await (await Pay(s.Finance, inv.Id(), 7744, Key())).Ok();
        Assert.Equal("Paid", p2.Str("invoiceStatus"));
        var final = await (await s.Finance.GetAsync($"/api/v1/invoices/{inv.Id()}")).Ok();
        Assert.Equal(12744m, final.Dec("paidAmount"));
        Assert.Equal(0m, final.Dec("balance"));
        Assert.Equal(2, final["payments"]!.AsArray().Count);
        Assert.Equal(HttpStatusCode.Conflict, (await Pay(s.Finance, inv.Id(), 1, Key())).StatusCode);        // fully paid
    }

    [Fact]
    public async Task Overpayment_and_invalid_payments_are_blocked()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Approved(InvSetup.Num());
        Assert.Equal(HttpStatusCode.Conflict, (await Pay(s.Finance, inv.Id(), 12744.01m, Key())).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Pay(s.Finance, inv.Id(), 0, Key())).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Pay(s.Finance, inv.Id(), -5, Key())).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Pay(s.Finance, inv.Id(), 10.005m, Key())).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Pay(s.Finance, inv.Id(), 100, Key(), method: "Bitcoin")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Pay(s.Finance, inv.Id(), 100, key: null)).StatusCode);                    // key required
        Assert.Equal(HttpStatusCode.BadRequest, (await Pay(s.Finance, inv.Id(), 100, Key(), paidOn: DateOnly.FromDateTime(DateTime.Today.AddDays(2)).ToString("yyyy-MM-dd"))).StatusCode);
        Assert.Equal(0m, (await (await s.Finance.GetAsync($"/api/v1/invoices/{inv.Id()}")).Ok()).Dec("paidAmount"));
    }

    [Fact]
    public async Task Only_a_reconciled_invoice_can_be_paid()
    {
        var s = await InvSetup.Create(factory);
        var matched = await s.Register(InvSetup.Num());                    // Matched but not reconciled
        Assert.Equal(HttpStatusCode.Conflict, (await Pay(s.Finance, matched.Id(), 100, Key())).StatusCode);
        var review = await s.Register(InvSetup.Num(), s.Invoice(InvSetup.Num(), qtyB: 5));
        Assert.Equal(HttpStatusCode.Conflict, (await Pay(s.Finance, review.Id(), 100, Key())).StatusCode);
    }

    [Fact]
    public async Task Same_idempotency_key_returns_the_original_payment_and_posts_once()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Approved(InvSetup.Num());
        var key = Key();
        var first = await Pay(s.Finance, inv.Id(), 1000, key);
        var second = await Pay(s.Finance, inv.Id(), 1000, key);
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);
        Assert.Equal(HttpStatusCode.OK, second.StatusCode);
        var a = await first.Body(); var b = await second.Body();
        Assert.Equal(a.Str("id"), b.Str("id"));
        Assert.True(b["replayed"]!.GetValue<bool>());
        Assert.Equal(1000m, (await (await s.Finance.GetAsync($"/api/v1/invoices/{inv.Id()}")).Ok()).Dec("paidAmount"));

        // the key cannot be reused for a different amount or invoice
        Assert.Equal(HttpStatusCode.Conflict, (await Pay(s.Finance, inv.Id(), 2000, key)).StatusCode);
    }

    [Fact]
    public async Task Parallel_requests_with_one_key_post_exactly_one_payment()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Approved(InvSetup.Num());
        var key = Key();
        var results = await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => Pay(s.Finance, inv.Id(), 500, key)));
        Assert.All(results, r => Assert.True(r.IsSuccessStatusCode));
        Assert.Equal(1, results.Count(r => r.StatusCode == HttpStatusCode.Created));
        Assert.Equal(500m, (await (await s.Finance.GetAsync($"/api/v1/invoices/{inv.Id()}")).Ok()).Dec("paidAmount"));
    }

    [Fact]
    public async Task Parallel_payments_with_different_keys_cannot_overpay()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Approved(InvSetup.Num());                         // balance 12,744
        var results = await Task.WhenAll(Pay(s.Finance, inv.Id(), 8000, Key()), Pay(s.Finance, inv.Id(), 8000, Key()));
        Assert.Equal(1, results.Count(r => r.StatusCode == HttpStatusCode.Created));
        Assert.Equal(1, results.Count(r => r.StatusCode == HttpStatusCode.Conflict));
        Assert.Equal(8000m, (await (await s.Finance.GetAsync($"/api/v1/invoices/{inv.Id()}")).Ok()).Dec("paidAmount"));
    }

    [Fact]
    public async Task Invoice_with_payments_cannot_be_cancelled()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Approved(InvSetup.Num());
        await (await Pay(s.Finance, inv.Id(), 100, Key())).Ok();
        Assert.Equal(HttpStatusCode.Conflict, (await s.Finance.PostJson($"/api/v1/invoices/{inv.Id()}/cancel", new { comment = "oops" })).StatusCode);
    }

    [Fact]
    public async Task Payment_list_summary_and_audit()
    {
        var s = await InvSetup.Create(factory);
        var inv = await s.Approved(InvSetup.Num());
        await (await Pay(s.Finance, inv.Id(), 4744, Key())).Ok();
        var list = await (await s.Finance.GetAsync("/api/v1/payments")).Ok();
        Assert.Equal(1, list["totalCount"]!.GetValue<int>());
        Assert.Equal("Partial", list["items"]![0]!.Str("status"));
        Assert.Equal(8000m, list["items"]![0]!.Dec("balance"));

        var sum = await (await s.Finance.GetAsync("/api/v1/payments/summary")).Ok();
        Assert.Equal(4744m, sum.Dec("paidThisMonth"));
        Assert.Equal(8000m, sum.Dec("outstanding"));
        Assert.Equal(1, sum["outstandingCount"]!.GetValue<int>());
        Assert.Equal(0, sum["overdueCount"]!.GetValue<int>());
        Assert.Equal(0, sum["dueIn7Days"]!.GetValue<int>());                  // due date is 30 days away
        var audit = await (await s.Org.Owner.GetAsync("/api/v1/audit?pageSize=200")).Ok();
        Assert.Contains(audit["items"]!.AsArray(), a => a!.Str("action") == "payment.recorded");
    }

    [Fact]
    public async Task Payment_permissions_and_tenant_isolation()
    {
        var a = await InvSetup.Create(factory);
        var b = await InvSetup.Create(factory);
        var inv = await a.Approved(InvSetup.Num());
        Assert.Equal(HttpStatusCode.Forbidden, (await Pay(a.Org.Proc, inv.Id(), 100, Key())).StatusCode);          // procurement can view only
        Assert.Equal(HttpStatusCode.OK, (await a.Org.Proc.GetAsync("/api/v1/payments")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await Pay(b.Finance, inv.Id(), 100, Key())).StatusCode);
        // an idempotency key used by tenant A does not leak into tenant B
        var key = Key();
        await (await Pay(a.Finance, inv.Id(), 100, key)).Ok();
        var invB = await b.Approved(InvSetup.Num());
        Assert.Equal(HttpStatusCode.Created, (await Pay(b.Finance, invB.Id(), 100, key)).StatusCode);
        Assert.Equal(0, (await (await b.Finance.GetAsync($"/api/v1/payments?invoiceId={inv.Id()}")).Ok())["totalCount"]!.GetValue<int>());
    }
}
