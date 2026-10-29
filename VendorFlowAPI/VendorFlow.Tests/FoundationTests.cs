using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

[Collection("api")]
public class FoundationTests(ApiFactory factory)
{
    [Fact]
    public async Task Health_endpoint_reports_healthy_database()
    {
        var response = await factory.CreateClient().GetAsync("/health");
        Assert.Equal(System.Net.HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("Healthy", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Protected_endpoint_without_token_returns_401()
    {
        var response = await factory.CreateClient().GetAsync("/api/v1/system/whoami");
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Swagger_document_is_served()
    {
        var response = await factory.CreateClient().GetAsync("/swagger/v1/swagger.json");
        Assert.True(response.IsSuccessStatusCode);
    }
}
