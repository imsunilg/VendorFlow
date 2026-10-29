using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

/// <summary>An issued PO with three lines (8 switches, 8 rack kits, 50 cables) and a warehouse user.</summary>
public sealed class GrnSetup
{
    public required PoOrg Org { get; init; }
    public required JsonNode Po { get; init; }
    public required HttpClient Warehouse { get; init; }

    public Guid Switch => Po["items"]![0]!.Id();
    public Guid Rack => Po["items"]![1]!.Id();
    public Guid Cable => Po["items"]![2]!.Id();
    public string PoUrl => $"/api/v1/purchase-orders/{Po.Id()}";

    public static async Task<GrnSetup> Create(ApiFactory f, DateOnly? expectedDelivery = null)
    {
        var org = await PoOrg.Create(f);
        var (wh, _, _) = await org.Org.Tenant.AddUser("Suresh Jadhav", "WarehouseManager");
        var po = await org.Issued(new
        {
            vendorId = org.VendorId,
            expectedDelivery = (expectedDelivery ?? DateOnly.FromDateTime(DateTime.Today.AddDays(10))).ToString("yyyy-MM-dd"),
            shipping = 2500,
            items = new object[]
            {
                new { description = "Cisco 24-port PoE switch", unit = "Nos", quantity = 8, rate = 24500, discountPercent = 5, taxPercent = 18 },
                new { description = "Rack mount kit", unit = "Nos", quantity = 8, rate = 1200, discountPercent = 0, taxPercent = 18 },
                new { description = "Cat6 patch cables (3 m)", unit = "Nos", quantity = 50, rate = 180, discountPercent = 0, taxPercent = 18 }
            }
        });
        return new GrnSetup { Org = org, Po = po, Warehouse = wh };
    }

    public object Line(Guid item, decimal received, decimal accepted, decimal rejected, decimal damaged = 0) =>
        new { poItemId = item, receivedQty = received, acceptedQty = accepted, rejectedQty = rejected, damagedQty = damaged };

    public Task<HttpResponseMessage> Receive(object[] lines, string? challan = null, HttpClient? by = null, string? receivedOn = null) =>
        (by ?? Warehouse).PostJson($"{PoUrl}/receipts", new
        {
            warehouse = "Navi Mumbai WH-1", deliveryChallan = challan, vehicleNo = "MH 43 AB 4521", receivedBy = "Suresh Jadhav",
            inspectionNotes = "ok", receivedOn, items = lines
        });

    public async Task<JsonNode> Po_() => await (await Org.Proc.GetAsync(PoUrl)).Ok();
}

[Collection("api")]
public class GoodsReceiptTests(ApiFactory factory)
{
    [Fact]
    public async Task Partial_then_full_receipt_moves_the_po_through_its_states()
    {
        var s = await GrnSetup.Create(factory);
        var first = await (await s.Receive([s.Line(s.Switch, 5, 5, 0), s.Line(s.Rack, 8, 8, 0)], "DC-1")).Ok();
        Assert.StartsWith("GRN-", first.Str("number"));
        var po = await s.Po_();
        Assert.Equal("PartiallyReceived", po.Str("status"));
        Assert.Equal(5m, po["items"]![0]!.Dec("receivedQty"));
        Assert.Equal(3m, po["items"]![0]!.Dec("pendingQty"));
        Assert.True(po["receiptPct"]!.GetValue<int>() is > 0 and < 100);

        await (await s.Receive([s.Line(s.Switch, 3, 3, 0), s.Line(s.Cable, 50, 50, 0)], "DC-2")).Ok();
        po = await s.Po_();
        Assert.Equal("FullyReceived", po.Str("status"));
        Assert.Equal(100, po["receiptPct"]!.GetValue<int>());
        Assert.Equal(2, po["receipts"]!.AsArray().Count);
        Assert.Contains(po["history"]!.AsArray(), h => h!.Str("action") == "goods_received");

        // a fully received PO takes no more goods, but can be closed
        Assert.Equal(HttpStatusCode.Conflict, (await s.Receive([s.Line(s.Switch, 1, 1, 0)], "DC-3")).StatusCode);
        Assert.Equal("Closed", (await (await s.Org.Proc.PostJson($"{s.PoUrl}/close", new { })).Ok()).Str("status"));
    }

    [Fact]
    public async Task Only_accepted_quantity_counts_so_rejected_goods_can_be_redelivered()
    {
        var s = await GrnSetup.Create(factory);
        // 4 arrive: 3 accepted, 1 rejected (damaged)
        var grn = await (await s.Receive([s.Line(s.Rack, 4, 3, 1, damaged: 1)], "DC-R1")).Ok();
        var item = grn["items"]![0]!;
        Assert.Equal(3m, item.Dec("acceptedQty"));
        Assert.Equal(1m, item.Dec("damagedQty"));
        var po = await s.Po_();
        Assert.Equal(3m, po["items"]![1]!.Dec("receivedQty"));
        Assert.Equal(5m, po["items"]![1]!.Dec("pendingQty"));
        // the vendor replaces the damaged one and delivers the remaining 5 + 1 = 6
        Assert.Equal(HttpStatusCode.OK, (await s.Receive([s.Line(s.Rack, 5, 5, 0)], "DC-R2")).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await s.Receive([s.Line(s.Rack, 1, 1, 0)], "DC-R3")).StatusCode);   // rack is complete: 8 accepted
    }

    [Fact]
    public async Task Over_receipt_is_blocked()
    {
        var s = await GrnSetup.Create(factory);
        Assert.Equal(HttpStatusCode.Conflict, (await s.Receive([s.Line(s.Switch, 9, 9, 0)], "DC-O1")).StatusCode);
        await (await s.Receive([s.Line(s.Switch, 5, 5, 0)], "DC-O2")).Ok();
        Assert.Equal(HttpStatusCode.Conflict, (await s.Receive([s.Line(s.Switch, 4, 4, 0)], "DC-O3")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await s.Receive([s.Line(s.Switch, 3, 3, 0)], "DC-O4")).StatusCode);
        // nothing from the refused attempts was kept
        var po = await s.Po_();
        Assert.Equal(8m, po["items"]![0]!.Dec("receivedQty"));
        Assert.Equal(2, po["receipts"]!.AsArray().Count);
    }

    [Fact]
    public async Task Quantity_rules_are_validated()
    {
        var s = await GrnSetup.Create(factory);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Receive([s.Line(s.Switch, 5, 3, 1)])).StatusCode);                 // 3+1 != 5
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Receive([s.Line(s.Switch, 5, 4, 1, damaged: 2)])).StatusCode);   // damaged > rejected
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Receive([s.Line(s.Switch, -1, -1, 0)])).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Receive([s.Line(s.Switch, 0, 0, 0)])).StatusCode);                // nothing received
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Receive([s.Line(Guid.NewGuid(), 1, 1, 0)])).StatusCode);          // unknown line
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Receive([s.Line(s.Switch, 1, 1, 0), s.Line(s.Switch, 1, 1, 0)])).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Receive([s.Line(s.Switch, 1, 1, 0)], receivedOn: DateOnly.FromDateTime(DateTime.Today.AddDays(3)).ToString("yyyy-MM-dd"))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Receive([])).StatusCode);
    }

    [Fact]
    public async Task Duplicate_delivery_challan_is_rejected_for_the_same_po()
    {
        var s = await GrnSetup.Create(factory);
        await (await s.Receive([s.Line(s.Switch, 1, 1, 0)], "DC-777")).Ok();
        Assert.Equal(HttpStatusCode.Conflict, (await s.Receive([s.Line(s.Switch, 1, 1, 0)], "dc-777")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await s.Receive([s.Line(s.Switch, 1, 1, 0)], "DC-778")).StatusCode);
    }

    [Fact]
    public async Task Receipts_need_an_issued_po()
    {
        var o = await PoOrg.Create(factory);
        var (wh, _, _) = await o.Org.Tenant.AddUser("Wally Warehouse", "WarehouseManager");
        var draft = await o.Draft();
        var line = new[] { new { poItemId = draft["items"]![0]!.Id(), receivedQty = 1, acceptedQty = 1, rejectedQty = 0 } };
        Assert.Equal(HttpStatusCode.Conflict, (await wh.PostJson($"/api/v1/purchase-orders/{draft.Id()}/receipts", new { items = line })).StatusCode);

        var s = await GrnSetup.Create(factory);
        await (await s.Org.Proc.PostJson($"{s.PoUrl}/hold", new { comment = "audit" })).Ok();
        Assert.Equal(HttpStatusCode.Conflict, (await s.Receive([s.Line(s.Switch, 1, 1, 0)])).StatusCode);
        await (await s.Org.Proc.PostJson($"{s.PoUrl}/resume")).Ok();
        Assert.Equal(HttpStatusCode.OK, (await s.Receive([s.Line(s.Switch, 1, 1, 0)])).StatusCode);
    }

    [Fact]
    public async Task Parallel_receipts_cannot_over_receive()
    {
        var s = await GrnSetup.Create(factory);
        var results = await Task.WhenAll(
            s.Receive([s.Line(s.Switch, 5, 5, 0)], "DC-P1"),
            s.Receive([s.Line(s.Switch, 5, 5, 0)], "DC-P2"));
        Assert.Equal(1, results.Count(r => r.StatusCode == HttpStatusCode.OK));
        Assert.Equal(1, results.Count(r => r.StatusCode == HttpStatusCode.Conflict));
        Assert.Equal(5m, (await s.Po_())["items"]![0]!.Dec("receivedQty"));
    }

    [Fact]
    public async Task Cancelling_a_receipt_reverses_the_quantities_and_status()
    {
        var s = await GrnSetup.Create(factory);
        var grn = await (await s.Receive([s.Line(s.Switch, 8, 8, 0)], "DC-C1")).Ok();
        Assert.Equal(HttpStatusCode.BadRequest, (await s.Warehouse.PostJson($"/api/v1/goods-receipts/{grn.Id()}/cancel", new { })).StatusCode);
        var cancelled = await (await s.Warehouse.PostJson($"/api/v1/goods-receipts/{grn.Id()}/cancel", new { comment = "Wrong PO" })).Ok();
        Assert.Equal("Cancelled", cancelled.Str("status"));
        var po = await s.Po_();
        Assert.Equal("Issued", po.Str("status"));
        Assert.Equal(0m, po["items"]![0]!.Dec("receivedQty"));
        Assert.Equal(HttpStatusCode.Conflict, (await s.Warehouse.PostJson($"/api/v1/goods-receipts/{grn.Id()}/cancel", new { comment = "again" })).StatusCode);
        // the challan can be used again after cancellation
        Assert.Equal(HttpStatusCode.OK, (await s.Receive([s.Line(s.Switch, 8, 8, 0)], "DC-C1")).StatusCode);
    }

    [Fact]
    public async Task Permissions_and_attachments()
    {
        var s = await GrnSetup.Create(factory);
        Assert.Equal(HttpStatusCode.Forbidden, (await s.Receive([s.Line(s.Switch, 1, 1, 0)], by: s.Org.Org.Requester)).StatusCode);
        var (auditor, _, _) = await s.Org.Org.Tenant.AddUser("Aud Itor", "Auditor");
        Assert.Equal(HttpStatusCode.Forbidden, (await s.Receive([s.Line(s.Switch, 1, 1, 0)], by: auditor)).StatusCode);

        var grn = await (await s.Receive([s.Line(s.Switch, 2, 2, 0)], "DC-A1")).Ok();
        Assert.Equal(HttpStatusCode.OK, (await auditor.GetAsync($"/api/v1/goods-receipts/{grn.Id()}")).StatusCode);

        var form = new MultipartFormDataContent();
        form.Add(new ByteArrayContent(Encoding.UTF8.GetBytes("fake image")), "file", "damage.png");
        var up = await s.Warehouse.PostAsync($"/api/v1/attachments/goods_receipt/{grn.Id()}", form);
        Assert.Equal(HttpStatusCode.OK, up.StatusCode);
        Assert.Single((await (await s.Warehouse.GetAsync($"/api/v1/goods-receipts/{grn.Id()}")).Ok())["attachments"]!.AsArray());

        var list = await (await auditor.GetAsync($"/api/v1/goods-receipts?poId={s.Po.Id()}")).Ok();
        Assert.Equal(1, list["totalCount"]!.GetValue<int>());
    }

    [Fact]
    public async Task Other_tenant_cannot_receive_read_or_cancel()
    {
        var a = await GrnSetup.Create(factory);
        var b = await GrnSetup.Create(factory);
        var grn = await (await a.Receive([a.Line(a.Switch, 2, 2, 0)], "DC-X")).Ok();
        Assert.Equal(HttpStatusCode.NotFound, (await b.Warehouse.PostJson($"{a.PoUrl}/receipts", new { items = new[] { a.Line(a.Switch, 1, 1, 0) } })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Warehouse.GetAsync($"/api/v1/goods-receipts/{grn.Id()}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Warehouse.PostJson($"/api/v1/goods-receipts/{grn.Id()}/cancel", new { comment = "x" })).StatusCode);
        Assert.Equal(0, (await (await b.Warehouse.GetAsync("/api/v1/goods-receipts")).Ok())["totalCount"]!.GetValue<int>());
    }

    [Fact]
    public async Task Vendor_performance_is_computed_from_real_receipts()
    {
        var s = await GrnSetup.Create(factory);
        var vendorUrl = $"/api/v1/vendors/{s.Org.VendorId}/performance";
        Assert.Null((await (await s.Org.Owner.GetAsync(vendorUrl)).Ok())["score"]);        // no receipts yet

        // 4 arrive on time: 3 accepted, 1 rejected -> on-time 100%, accepted 75%
        await (await s.Receive([s.Line(s.Rack, 4, 3, 1, damaged: 1)], "DC-V1")).Ok();
        var perf = await (await s.Org.Owner.GetAsync(vendorUrl)).Ok();
        var metrics = perf["metrics"]!.AsArray();
        Assert.Equal(100m, metrics.First(m => m!.Str("key") == "onTime")!.Dec("value"));
        Assert.Equal(75m, metrics.First(m => m!.Str("key") == "acceptedQty")!.Dec("value"));
        Assert.NotNull(perf["score"]);
        // weights 30/25 + document compliance has no data -> score = (100*30 + 75*25) / 55 = 88.6 -> 89
        Assert.Equal(89m, perf.Dec("score"));
    }

    [Fact]
    public async Task Late_delivery_lowers_the_on_time_metric()
    {
        var s = await GrnSetup.Create(factory, expectedDelivery: DateOnly.FromDateTime(DateTime.Today.AddDays(-2)));
        await (await s.Receive([s.Line(s.Rack, 2, 2, 0)], "DC-L1")).Ok();
        var perf = await (await s.Org.Owner.GetAsync($"/api/v1/vendors/{s.Org.VendorId}/performance")).Ok();
        Assert.Equal(0m, perf["metrics"]!.AsArray().First(m => m!.Str("key") == "onTime")!.Dec("value"));
    }
}
