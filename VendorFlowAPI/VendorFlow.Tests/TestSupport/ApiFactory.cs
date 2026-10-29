using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;

namespace VendorFlow.Tests.TestSupport;

/// <summary>
/// Starts the real API against a throw-away database "Vendor_db_test" (re-created on every test run).
/// The password is taken from the git-ignored appsettings.Development.json of the API project.
/// </summary>
public sealed class ApiFactory : WebApplicationFactory<Program>
{
    // Read by Program.cs while the builder is created (in-memory overrides below would arrive too late for it).
    static ApiFactory() => Environment.SetEnvironmentVariable("Jobs__Enabled", "false");

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Development");
        builder.ConfigureAppConfiguration((_, cfg) =>
        {
            var dev = cfg.Build().GetConnectionString("VendorFlow")
                      ?? throw new InvalidOperationException("Dev connection string not found.");
            var testCs = Regex.Replace(dev, "Database=[^;]+", "Database=Vendor_db_test", RegexOptions.IgnoreCase);
            cfg.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:VendorFlow"] = testCs,
                ["Database:ResetTestDb"] = "true",
                ["Seed:DemoData"] = "false",
                ["Jobs:Enabled"] = "false",
                ["RateLimit:AuthPerMinute"] = "100000",
                ["Storage:Path"] = Path.Combine(Path.GetTempPath(), "vendorflow-test-storage")
            });
        });
    }
}

[CollectionDefinition("api")]
public class ApiCollection : ICollectionFixture<ApiFactory>;

/// <summary>Small helpers so tests read like a story.</summary>
public static class Http
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static async Task<JsonNode> Body(this HttpResponseMessage r)
    {
        var text = await r.Content.ReadAsStringAsync();
        return JsonNode.Parse(text) ?? throw new InvalidOperationException("Empty body");
    }

    public static async Task<JsonNode> Ok(this HttpResponseMessage r)
    {
        var text = await r.Content.ReadAsStringAsync();
        if (!r.IsSuccessStatusCode) throw new Xunit.Sdk.XunitException($"{(int)r.StatusCode} {r.RequestMessage?.RequestUri?.AbsolutePath}: {text}");
        return JsonNode.Parse(text)!;
    }

    public static HttpClient As(this ApiFactory f, string token)
    {
        var c = f.CreateClient();
        c.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return c;
    }

    public static Task<HttpResponseMessage> PostJson(this HttpClient c, string url, object? body = null) =>
        c.PostAsJsonAsync(url, body ?? new { }, Json);

    public static Task<HttpResponseMessage> PutJson(this HttpClient c, string url, object body) =>
        c.PutAsJsonAsync(url, body, Json);
}
