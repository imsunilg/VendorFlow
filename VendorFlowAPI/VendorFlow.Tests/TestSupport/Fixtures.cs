using System.Text.Json.Nodes;

namespace VendorFlow.Tests.TestSupport;

/// <summary>Shortcuts that build common documents through the real API.</summary>
public static class Fixtures
{
    private static int _gstSeed = 1000;

    /// <summary>A valid, unique GSTIN-shaped number.</summary>
    public static string Gstin() => $"27AABCS{Interlocked.Increment(ref _gstSeed)}F1Z5";

    public static async Task<Guid> ApprovedVendor(HttpClient owner, string? name = null, string? email = null)
    {
        var tag = Guid.NewGuid().ToString("N")[..6];
        var vendor = await (await owner.PostJson("/api/v1/vendors", new
        {
            name = name ?? $"Vendor {tag}", category = "Electronics", city = "Pune", state = "MH",
            email = email ?? $"v{tag}@vendor.test", gstin = Gstin(), paymentTermsDays = 30
        })).Ok();
        var id = Guid.Parse(vendor["id"]!.GetValue<string>());
        await (await owner.PostJson($"/api/v1/vendors/{id}/submit")).Ok();
        await (await owner.PostJson($"/api/v1/vendors/{id}/approve", new { comment = "ok" })).Ok();
        return id;
    }

    public static Guid Id(this JsonNode node, string key = "id") => Guid.Parse(node[key]!.GetValue<string>());
    public static string Str(this JsonNode node, string key) => node[key]!.GetValue<string>();
    public static decimal Dec(this JsonNode node, string key) => node[key]!.GetValue<decimal>();
}
