using System.Net;
using System.Text.Json.Nodes;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

public sealed class RfqSetup
{
    public required ApprovalOrg Org { get; init; }
    public required HttpClient Buyer { get; init; }
    public required Guid[] Vendors { get; init; }
    public required Guid RfqId { get; init; }
    public required Guid ItemId { get; init; }
    public required string[] Tokens { get; init; }          // portal tokens, same order as Vendors
    public required JsonNode Rfq { get; init; }

    public static string TokenFromLink(string link) => link[(link.LastIndexOf("/portal/rfq/", StringComparison.Ordinal) + "/portal/rfq/".Length)..];

    /// <summary>An open RFQ for 8 switches with n invited approved vendors.</summary>
    public static async Task<RfqSetup> Open(ApiFactory f, int vendorCount = 3, ApprovalOrg? org = null, DateTimeOffset? deadline = null, TimeSpan? deadlineIn = null)
    {
        org ??= await ApprovalOrg.Create(f);
        var buyer = org.Tenant.Owner;
        var vendors = new List<Guid>();
        for (var i = 0; i < vendorCount; i++) vendors.Add(await Fixtures.ApprovedVendor(buyer, $"Quote Vendor {i}-{Guid.NewGuid().ToString("N")[..4]}"));

        var rfq = await (await buyer.PostJson("/api/v1/rfqs", new
        {
            title = "Network switches", description = "24-port PoE",
            deadline = (deadlineIn is null ? deadline ?? DateTimeOffset.UtcNow.AddDays(5) : DateTimeOffset.UtcNow + deadlineIn.Value).ToString("o"),
            items = new[] { new { description = "24-port PoE switch", unit = "Nos", quantity = 8 } },
            vendorIds = vendors
        })).Ok();
        var opened = await (await buyer.PostJson($"/api/v1/rfqs/{rfq.Id()}/open")).Ok();
        var links = opened["invitations"]!.AsArray();
        var tokens = vendors.Select(v => TokenFromLink(links.First(l => l!.Str("vendorId") == v.ToString())!.Str("link"))).ToArray();
        return new RfqSetup
        {
            Org = org, Buyer = buyer, Vendors = vendors.ToArray(), RfqId = rfq.Id(), Tokens = tokens,
            ItemId = rfq["items"]![0]!.Id(), Rfq = opened["rfq"]!
        };
    }

    public object Quote(decimal price, decimal discount = 0, decimal tax = 18, decimal shipping = 0, int days = 10, int warranty = 12, string terms = "Net 30") => new
    {
        shipping, deliveryDays = days, paymentTerms = terms, warrantyMonths = warranty,
        items = new[] { new { rfqItemId = ItemId, unitPrice = price, discountPercent = discount, taxPercent = tax } }
    };

    public Task<HttpResponseMessage> Submit(ApiFactory f, int vendorIndex, object quote) =>
        f.CreateClient().PostJson($"/api/v1/portal/rfq/{Tokens[vendorIndex]}/quotation", quote);
}

[Collection("api")]
public class RfqQuotationTests(ApiFactory factory)
{
    // ------------------------------------------------------------------ RFQ lifecycle

    [Fact]
    public async Task Rfq_from_approved_requisition_copies_items_and_unapproved_is_refused()
    {
        var o = await ApprovalOrg.Create(factory);
        var vendor = await Fixtures.ApprovedVendor(o.Tenant.Owner);
        var req = await o.Submitted(10_000);
        var body = new { title = "From req", requisitionId = req.Id(), deadline = DateTimeOffset.UtcNow.AddDays(3).ToString("o"), vendorIds = new[] { vendor } };

        Assert.Equal(HttpStatusCode.Conflict, (await o.Tenant.Owner.PostJson("/api/v1/rfqs", body)).StatusCode);

        await (await o.DeptManager.PostJson($"/api/v1/approvals/{ApprovalOrg.RequestId(req)}/approve", new { })).Ok();
        var rfq = await (await o.Tenant.Owner.PostJson("/api/v1/rfqs", body)).Ok();
        Assert.Equal("Draft", rfq.Str("status"));
        Assert.StartsWith("RFQ-", rfq.Str("number"));
        Assert.Single(rfq["items"]!.AsArray());
        Assert.Equal(req.Str("number"), rfq.Str("requisitionNumber"));
    }

    [Fact]
    public async Task Only_approved_vendors_of_the_same_tenant_can_be_invited()
    {
        var a = await ApprovalOrg.Create(factory);
        var b = await ApprovalOrg.Create(factory);
        var draftVendor = (await (await a.Tenant.Owner.PostJson("/api/v1/vendors", new { name = "Draft only" })).Ok()).Id();
        var foreign = await Fixtures.ApprovedVendor(b.Tenant.Owner);
        object Body(Guid v) => new { title = "T", items = new[] { new { description = "x", quantity = 1 } }, vendorIds = new[] { v } };
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Tenant.Owner.PostJson("/api/v1/rfqs", Body(draftVendor))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Tenant.Owner.PostJson("/api/v1/rfqs", Body(foreign))).StatusCode);
    }

    [Fact]
    public async Task Open_needs_items_vendors_and_a_future_deadline()
    {
        var o = await ApprovalOrg.Create(factory);
        var buyer = o.Tenant.Owner;
        var v = await Fixtures.ApprovedVendor(buyer);
        var noDeadline = await (await buyer.PostJson("/api/v1/rfqs", new { title = "A", items = new[] { new { description = "x", quantity = 1 } }, vendorIds = new[] { v } })).Ok();
        Assert.Equal(HttpStatusCode.BadRequest, (await buyer.PostJson($"/api/v1/rfqs/{noDeadline.Id()}/open")).StatusCode);
        var noVendors = await (await buyer.PostJson("/api/v1/rfqs", new { title = "B", deadline = DateTimeOffset.UtcNow.AddDays(1).ToString("o"), items = new[] { new { description = "x", quantity = 1 } } })).Ok();
        Assert.Equal(HttpStatusCode.BadRequest, (await buyer.PostJson($"/api/v1/rfqs/{noVendors.Id()}/open")).StatusCode);
    }

    [Fact]
    public async Task Close_cancel_reopen_follow_the_state_machine()
    {
        var s = await RfqSetup.Open(factory, 1);
        var buyer = s.Buyer;
        Assert.Equal(HttpStatusCode.Conflict, (await buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/open")).StatusCode);       // already open
        Assert.Equal(HttpStatusCode.Conflict, (await buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/reopen", new { deadline = DateTimeOffset.UtcNow.AddDays(2).ToString("o") })).StatusCode);
        Assert.Equal("Closed", (await (await buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/close")).Ok()).Str("status"));
        Assert.Equal("Open", (await (await buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/reopen", new { deadline = DateTimeOffset.UtcNow.AddDays(2).ToString("o") })).Ok()).Str("status"));
        Assert.Equal(HttpStatusCode.BadRequest, (await buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/cancel", new { })).StatusCode);
        Assert.Equal("Cancelled", (await (await buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/cancel", new { comment = "No longer needed" })).Ok()).Str("status"));
        Assert.Equal(HttpStatusCode.Conflict, (await buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/close")).StatusCode);
    }

    [Fact]
    public async Task List_returns_counts_and_filters()
    {
        var s = await RfqSetup.Open(factory, 2);
        var list = await (await s.Buyer.GetAsync("/api/v1/rfqs?status=Open")).Ok();
        Assert.Equal(1, list["totalCount"]!.GetValue<int>());
        Assert.Equal(2, list["items"]![0]!["vendorsInvited"]!.GetValue<int>());
        Assert.Equal(1, list["statusCounts"]!["Open"]!.GetValue<int>());
    }

    // ------------------------------------------------------------------ vendor portal

    [Fact]
    public async Task Portal_shows_only_the_rfq_and_the_vendors_own_data_and_tracks_views()
    {
        var s = await RfqSetup.Open(factory, 2);
        Assert.Equal(HttpStatusCode.NotFound, (await factory.CreateClient().GetAsync("/api/v1/portal/rfq/not-a-real-token")).StatusCode);

        var view = await (await factory.CreateClient().GetAsync($"/api/v1/portal/rfq/{s.Tokens[0]}")).Ok();
        Assert.Equal("Network switches", view["rfq"]!.Str("title"));
        Assert.True(view["rfq"]!["accepting"]!.GetValue<bool>());
        Assert.Equal(1, view["items"]!.AsArray().Count);

        var rfq = await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok();
        var seen = rfq["vendors"]!.AsArray().First(v => v!.Str("vendorId") == s.Vendors[0].ToString())!;
        Assert.Equal("Viewed", seen.Str("status"));
        var unseen = rfq["vendors"]!.AsArray().First(v => v!.Str("vendorId") == s.Vendors[1].ToString())!;
        Assert.Equal("Invited", unseen.Str("status"));
    }

    [Fact]
    public async Task Quotation_math_follows_the_documented_rounding_rule()
    {
        var s = await RfqSetup.Open(factory, 1);
        // qty 8 x 26000 = 208000; 5% discount = 10400; net 197600; GST 18% = 35568; line 233168; + shipping 2500
        var res = await (await s.Submit(factory, 0, s.Quote(26000, discount: 5, tax: 18, shipping: 2500, days: 10, warranty: 36))).Ok();
        var q = res["quotation"]!;
        Assert.Equal(197600m, q.Dec("subtotal"));
        Assert.Equal(35568m, q.Dec("taxTotal"));
        Assert.Equal(235668m, q.Dec("totalLanded"));
        Assert.Equal(233168m, q["items"]![0]!.Dec("lineTotal"));
    }

    [Fact]
    public async Task Rounding_is_half_up_per_line()
    {
        var s = await RfqSetup.Open(factory, 1);
        // unit price 1.005 -> 1.01 (half up); x 8 = 8.08; 18% tax = 1.4544 -> 1.45; line 9.53
        var q = (await (await s.Submit(factory, 0, s.Quote(1.005m))).Ok())["quotation"]!;
        Assert.Equal(1.01m, q["items"]![0]!.Dec("unitPrice"));
        Assert.Equal(8.08m, q.Dec("subtotal"));
        Assert.Equal(1.45m, q.Dec("taxTotal"));
        Assert.Equal(9.53m, q.Dec("totalLanded"));
    }

    [Fact]
    public async Task Resubmission_replaces_the_previous_quotation_and_bad_data_is_refused()
    {
        var s = await RfqSetup.Open(factory, 1);
        await (await s.Submit(factory, 0, s.Quote(1000, tax: 0))).Ok();
        var second = await (await s.Submit(factory, 0, s.Quote(900, tax: 0))).Ok();
        Assert.Equal(7200m, second["quotation"]!.Dec("totalLanded"));
        Assert.Equal(1, (await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok())["quotationsCount"]!.GetValue<int>());

        Assert.Equal(HttpStatusCode.BadRequest, (await s.Submit(factory, 0, s.Quote(-5))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Submit(factory, 0, s.Quote(100, discount: 150))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Submit(factory, 0, s.Quote(100, shipping: -1))).StatusCode);
        // price for an unknown item id
        var bogus = new { items = new[] { new { rfqItemId = Guid.NewGuid(), unitPrice = 10 } } };
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Submit(factory, 0, bogus)).StatusCode);
    }

    [Fact]
    public async Task A_vendor_can_never_see_another_vendors_quotation_or_identity()
    {
        var s = await RfqSetup.Open(factory, 2);
        await (await s.Submit(factory, 0, s.Quote(24500, tax: 0))).Ok();
        await (await s.Submit(factory, 1, s.Quote(99999, tax: 0))).Ok();

        var viewB = await (await factory.CreateClient().GetAsync($"/api/v1/portal/rfq/{s.Tokens[1]}")).Ok();
        var text = viewB.ToJsonString();
        Assert.Contains("99999", text);
        Assert.DoesNotContain("196000", text);                       // 24500 x 8, vendor A's total
        Assert.DoesNotContain(s.Vendors[0].ToString(), text);
        Assert.Null(viewB["vendors"]);

        // a token of one tenant's RFQ cannot be used with a changed path or by staff routes
        Assert.Equal(HttpStatusCode.Unauthorized, (await factory.CreateClient().GetAsync($"/api/v1/rfqs/{s.RfqId}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await factory.CreateClient().GetAsync($"/api/v1/portal/rfq/{s.Tokens[1]}x")).StatusCode);
    }

    [Fact]
    public async Task Deadline_close_and_reopen_control_submission()
    {
        var s = await RfqSetup.Open(factory, 1, deadlineIn: TimeSpan.FromSeconds(3));
        Assert.Equal(HttpStatusCode.OK, (await s.Submit(factory, 0, s.Quote(100))).StatusCode);
        await Task.Delay(3500);
        Assert.Equal(HttpStatusCode.Conflict, (await s.Submit(factory, 0, s.Quote(90))).StatusCode);      // deadline passed
        var view = await (await factory.CreateClient().GetAsync($"/api/v1/portal/rfq/{s.Tokens[0]}")).Ok();
        Assert.False(view["rfq"]!["accepting"]!.GetValue<bool>());

        await (await s.Buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/close")).Ok();
        Assert.Equal(HttpStatusCode.Conflict, (await s.Submit(factory, 0, s.Quote(80))).StatusCode);
        await (await s.Buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/reopen", new { deadline = DateTimeOffset.UtcNow.AddDays(1).ToString("o") })).Ok();
        Assert.Equal(HttpStatusCode.OK, (await s.Submit(factory, 0, s.Quote(80))).StatusCode);
    }

    [Fact]
    public async Task Suspended_vendor_link_stops_working_and_regenerating_replaces_the_old_link()
    {
        var s = await RfqSetup.Open(factory, 2);
        await (await s.Buyer.PostJson($"/api/v1/vendors/{s.Vendors[0]}/suspend", new { comment = "quality" })).Ok();
        Assert.Equal(HttpStatusCode.NotFound, (await factory.CreateClient().GetAsync($"/api/v1/portal/rfq/{s.Tokens[0]}")).StatusCode);

        var fresh = await (await s.Buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/vendors/{s.Vendors[1]}/invite")).Ok();
        var newToken = RfqSetup.TokenFromLink(fresh.Str("link"));
        Assert.Equal(HttpStatusCode.NotFound, (await factory.CreateClient().GetAsync($"/api/v1/portal/rfq/{s.Tokens[1]}")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await factory.CreateClient().GetAsync($"/api/v1/portal/rfq/{newToken}")).StatusCode);
    }

    [Fact]
    public async Task Clarifications_are_private_to_the_asking_vendor()
    {
        var s = await RfqSetup.Open(factory, 2);
        var c = factory.CreateClient();
        Assert.Equal(HttpStatusCode.BadRequest, (await c.PostJson($"/api/v1/portal/rfq/{s.Tokens[0]}/clarifications", new { question = "" })).StatusCode);
        var asked = await (await c.PostJson($"/api/v1/portal/rfq/{s.Tokens[0]}/clarifications", new { question = "Is PoE required on all 24 ports?" })).Ok();
        Assert.Single(asked["clarifications"]!.AsArray());

        var rfq = await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok();
        var cid = rfq["clarifications"]![0]!.Id();
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Buyer.PostJson($"/api/v1/rfqs/clarifications/{cid}/answer", new { answer = "" })).StatusCode);
        await (await s.Buyer.PostJson($"/api/v1/rfqs/clarifications/{cid}/answer", new { answer = "Yes, 802.3at on every port." })).Ok();

        var a = await (await c.GetAsync($"/api/v1/portal/rfq/{s.Tokens[0]}")).Ok();
        Assert.Equal("Yes, 802.3at on every port.", a["clarifications"]![0]!.Str("answer"));
        var b = await (await c.GetAsync($"/api/v1/portal/rfq/{s.Tokens[1]}")).Ok();
        Assert.Empty(b["clarifications"]!.AsArray());

        var notes = await (await s.Buyer.GetAsync("/api/v1/notifications")).Ok();
        Assert.Contains(notes["items"]!.AsArray(), n => n!.Str("type") == "rfq_clarification");
    }

    [Fact]
    public async Task Decline_is_recorded_and_not_allowed_after_a_quotation()
    {
        var s = await RfqSetup.Open(factory, 2);
        var c = factory.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await c.PostAsync($"/api/v1/portal/rfq/{s.Tokens[0]}/decline", null)).StatusCode);
        await s.Submit(factory, 1, s.Quote(100));
        Assert.Equal(HttpStatusCode.Conflict, (await c.PostAsync($"/api/v1/portal/rfq/{s.Tokens[1]}/decline", null)).StatusCode);
        var rfq = await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok();
        Assert.Contains(rfq["vendors"]!.AsArray(), v => v!.Str("status") == "Declined");
    }

    [Fact]
    public async Task Staff_can_enter_a_quotation_for_a_vendor_and_send_reminders()
    {
        var s = await RfqSetup.Open(factory, 2);
        var res = await s.Buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/vendors/{s.Vendors[0]}/quotation", s.Quote(500, tax: 0));
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        var rfq = await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok();
        Assert.Equal(4000m, rfq["vendors"]!.AsArray().First(v => v!.Str("vendorId") == s.Vendors[0].ToString())!.Dec("totalLanded"));
        // vendor 1 has not answered and has an email address -> one reminder queued
        var rem = await (await s.Buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/reminders")).Ok();
        Assert.Equal(1, rem["queued"]!.GetValue<int>());
        var again = await (await s.Buyer.PostJson($"/api/v1/rfqs/{s.RfqId}/reminders")).Ok();
        Assert.Equal(0, again["queued"]!.GetValue<int>());           // idempotent per day
    }

    // ------------------------------------------------------------------ comparison

    [Fact]
    public async Task Comparison_flags_best_values_but_never_picks_a_winner()
    {
        var s = await RfqSetup.Open(factory, 3);
        await (await s.Submit(factory, 0, s.Quote(26000, discount: 5, shipping: 2500, days: 10, warranty: 36, terms: "Net 30"))).Ok();
        await (await s.Submit(factory, 1, s.Quote(24500, discount: 3, shipping: 4800, days: 21, warranty: 12, terms: "Advance 50%"))).Ok();
        await (await s.Submit(factory, 2, s.Quote(27200, discount: 8, shipping: 0, days: 7, warranty: 36, terms: "Net 45"))).Ok();

        var cmp = await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}/compare")).Ok();
        var quotes = cmp["quotes"]!.AsArray();
        Assert.Equal(3, quotes.Count);
        // ordered by landed cost; the cheapest is flagged, others are not
        Assert.True(quotes[0]!["isLowestPrice"]!.GetValue<bool>());
        Assert.Equal(1, quotes.Count(q => q!["isLowestPrice"]!.GetValue<bool>()));
        Assert.True(quotes.Single(q => q!["isFastest"]!.GetValue<bool>()).Str("vendorId") == s.Vendors[2].ToString());
        Assert.True(quotes.Single(q => q!["isLowestShipping"]!.GetValue<bool>()).Str("vendorId") == s.Vendors[2].ToString());
        Assert.Equal(2, quotes.Count(q => q!["isBestWarranty"]!.GetValue<bool>()));
        Assert.Equal(cmp.Str("lowestVendorId"), quotes[0]!.Str("vendorId"));
        Assert.Null(cmp["recommendation"]);                          // nothing is auto-selected
        Assert.Equal("No documents", quotes[0]!.Str("compliance"));
    }

    [Fact]
    public async Task Recommendation_always_needs_a_justification_and_flags_when_not_lowest_price()
    {
        var s = await RfqSetup.Open(factory, 2);
        await s.Submit(factory, 0, s.Quote(1000, tax: 0));
        await s.Submit(factory, 1, s.Quote(2000, tax: 0, days: 3));
        var url = $"/api/v1/rfqs/{s.RfqId}/recommendation";

        Assert.Equal(HttpStatusCode.BadRequest, (await s.Buyer.PostJson(url, new { vendorId = s.Vendors[1], justification = "" })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Buyer.PostJson(url, new { vendorId = s.Vendors[1], justification = "short" })).StatusCode);
        // vendor that never quoted
        var none = await Fixtures.ApprovedVendor(s.Buyer);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Buyer.PostJson(url, new { vendorId = none, justification = "Because reasons given here" })).StatusCode);

        var res = await (await s.Buyer.PostJson(url, new { vendorId = s.Vendors[1], justification = "Fastest delivery needed for go-live" })).Ok();
        Assert.Equal(s.Vendors[1].ToString(), res["recommendation"]!.Str("vendorId"));
        Assert.False(res["recommendation"]!["isLowestPrice"]!.GetValue<bool>());

        var rfq = await (await s.Buyer.GetAsync($"/api/v1/rfqs/{s.RfqId}")).Ok();
        Assert.Contains(rfq["history"]!.AsArray(), h => h!.Str("action") == "recommendation_recorded");
        var audit = await (await s.Buyer.GetAsync("/api/v1/audit?pageSize=200")).Ok();
        Assert.Contains(audit["items"]!.AsArray(), a => a!.Str("action") == "quotation.recommended");
    }

    [Fact]
    public async Task Requester_cannot_compare_or_manage_rfqs()
    {
        var s = await RfqSetup.Open(factory, 1);
        var other = s.Org.Requester;
        Assert.Equal(HttpStatusCode.Forbidden, (await other.GetAsync($"/api/v1/rfqs/{s.RfqId}/compare")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await other.PostJson("/api/v1/rfqs", new { title = "x" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await other.PostJson($"/api/v1/rfqs/{s.RfqId}/recommendation", new { vendorId = s.Vendors[0], justification = "twelve chars+" })).StatusCode);
    }

    // ------------------------------------------------------------------ tenant isolation

    [Fact]
    public async Task Other_tenant_cannot_read_compare_close_or_invite_on_an_rfq()
    {
        var s = await RfqSetup.Open(factory, 1);
        await s.Submit(factory, 0, s.Quote(100));
        var b = await ApprovalOrg.Create(factory);
        var bClient = b.Tenant.Owner;
        var bVendor = await Fixtures.ApprovedVendor(bClient);

        Assert.Equal(HttpStatusCode.NotFound, (await bClient.GetAsync($"/api/v1/rfqs/{s.RfqId}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await bClient.GetAsync($"/api/v1/rfqs/{s.RfqId}/compare")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await bClient.PostJson($"/api/v1/rfqs/{s.RfqId}/close")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await bClient.PostJson($"/api/v1/rfqs/{s.RfqId}/vendors/{bVendor}/invite")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await bClient.PostJson($"/api/v1/rfqs/{s.RfqId}/vendors/{s.Vendors[0]}/quotation", s.Quote(1))).StatusCode);
        Assert.Equal(0, (await (await bClient.GetAsync("/api/v1/rfqs")).Ok())["totalCount"]!.GetValue<int>());
    }
}
