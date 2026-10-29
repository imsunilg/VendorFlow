using System.Text.Json.Nodes;

namespace VendorFlow.Tests.TestSupport;

/// <summary>A freshly registered organization with an authorized client for its Organization Owner.</summary>
public sealed class TestTenant
{
    public const string Password = "Test@12345";

    public required ApiFactory Factory { get; init; }
    public required Guid TenantId { get; init; }
    public required Guid OwnerId { get; init; }
    public required string OwnerEmail { get; init; }
    public required HttpClient Owner { get; init; }

    public static async Task<TestTenant> Create(ApiFactory factory, string? name = null)
    {
        var tag = Guid.NewGuid().ToString("N")[..8];
        var email = $"owner-{tag}@test.local";
        var res = await factory.CreateClient().PostJson("/api/v1/auth/register-organization", new
        {
            organizationName = name ?? $"Org {tag}", fullName = "Owner " + tag, email, password = Password
        });
        var body = await res.Ok();
        var user = body["user"]!;
        return new TestTenant
        {
            Factory = factory,
            TenantId = Guid.Parse(user["tenantId"]!.GetValue<string>()),
            OwnerId = Guid.Parse(user["userId"]!.GetValue<string>()),
            OwnerEmail = email,
            Owner = factory.As(body["accessToken"]!.GetValue<string>())
        };
    }

    /// <summary>Invites a user with the given roles, activates them and returns a client signed in as that user.</summary>
    public async Task<(HttpClient Client, Guid UserId, string Email)> AddUser(string fullName, params string[] roles)
    {
        var email = $"{fullName.Replace(" ", "").ToLowerInvariant()}-{Guid.NewGuid().ToString("N")[..6]}@test.local";
        var invite = await (await Owner.PostJson("/api/v1/users/invite", new { email, fullName, roles })).Ok();
        var reset = await Factory.CreateClient().PostJson("/api/v1/auth/reset-password",
            new { token = invite["inviteToken"]!.GetValue<string>(), newPassword = Password });
        Assert.True(reset.IsSuccessStatusCode, await reset.Content.ReadAsStringAsync());
        var client = await SignIn(Factory, email);
        return (client, Guid.Parse(invite["user"]!["id"]!.GetValue<string>()), email);
    }

    public static async Task<HttpClient> SignIn(ApiFactory factory, string email, string password = Password)
    {
        var login = await (await factory.CreateClient().PostJson("/api/v1/auth/login", new { email, password })).Ok();
        return factory.As(login["accessToken"]!.GetValue<string>());
    }

    public static async Task<JsonNode> Json(Task<HttpResponseMessage> call) => await (await call).Ok();
}
