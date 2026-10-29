using System.Net;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

[Collection("api")]
public class AuthTests(ApiFactory factory)
{
    [Fact]
    public async Task Register_then_login_returns_token_with_tenant_and_owner_permissions()
    {
        var t = await TestTenant.Create(factory);
        var me = await (await t.Owner.GetAsync("/api/v1/auth/me")).Ok();
        Assert.Equal(t.TenantId.ToString(), me["tenantId"]!.GetValue<string>());
        Assert.Contains("OrganizationOwner", me["roles"]!.AsArray().Select(x => x!.GetValue<string>()));
        Assert.Contains("settings.manage", me["permissions"]!.AsArray().Select(x => x!.GetValue<string>()));

        var login = await factory.CreateClient().PostJson("/api/v1/auth/login", new { email = t.OwnerEmail, password = TestTenant.Password });
        Assert.Equal(HttpStatusCode.OK, login.StatusCode);
    }

    [Fact]
    public async Task Wrong_password_returns_401_and_five_failures_lock_the_account()
    {
        var t = await TestTenant.Create(factory);
        var c = factory.CreateClient();
        for (var i = 0; i < 5; i++)
            Assert.Equal(HttpStatusCode.Unauthorized, (await c.PostJson("/api/v1/auth/login", new { email = t.OwnerEmail, password = "Wrong@123" })).StatusCode);
        // Even the right password is refused while locked.
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.PostJson("/api/v1/auth/login", new { email = t.OwnerEmail, password = TestTenant.Password })).StatusCode);
    }

    [Fact]
    public async Task Weak_password_is_rejected_with_error_details()
    {
        var res = await factory.CreateClient().PostJson("/api/v1/auth/register-organization",
            new { organizationName = "X", fullName = "Y", email = "weak@test.local", password = "short" });
        Assert.Equal(HttpStatusCode.BadRequest, res.StatusCode);
        var body = await res.Body();
        Assert.Equal(400, body["status"]!.GetValue<int>());
        Assert.NotNull(body["errors"]!["Password"]);
    }

    [Fact]
    public async Task Duplicate_email_returns_409()
    {
        var t = await TestTenant.Create(factory);
        var res = await factory.CreateClient().PostJson("/api/v1/auth/register-organization",
            new { organizationName = "Other", fullName = "Dup", email = t.OwnerEmail, password = TestTenant.Password });
        Assert.Equal(HttpStatusCode.Conflict, res.StatusCode);
    }

    [Fact]
    public async Task Refresh_token_rotates_and_reuse_revokes_the_family()
    {
        var t = await TestTenant.Create(factory);
        var login = await (await factory.CreateClient().PostJson("/api/v1/auth/login", new { email = t.OwnerEmail, password = TestTenant.Password })).Ok();
        var first = login["refreshToken"]!.GetValue<string>();

        var second = await (await factory.CreateClient().PostJson("/api/v1/auth/refresh", new { refreshToken = first })).Ok();
        var secondToken = second["refreshToken"]!.GetValue<string>();
        Assert.NotEqual(first, secondToken);

        // Re-using the old token fails AND kills the newer one.
        Assert.Equal(HttpStatusCode.Unauthorized, (await factory.CreateClient().PostJson("/api/v1/auth/refresh", new { refreshToken = first })).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await factory.CreateClient().PostJson("/api/v1/auth/refresh", new { refreshToken = secondToken })).StatusCode);
    }

    [Fact]
    public async Task User_without_permission_gets_403()
    {
        var t = await TestTenant.Create(factory);
        var (requester, _, _) = await t.AddUser("Rita Requester", "DepartmentRequester");
        Assert.Equal(HttpStatusCode.Forbidden, (await requester.GetAsync("/api/v1/users")).StatusCode);
    }

    [Fact]
    public async Task Tenant_cannot_see_or_change_users_of_another_tenant()
    {
        var a = await TestTenant.Create(factory);
        var b = await TestTenant.Create(factory);
        var (_, userA, _) = await a.AddUser("Alice Alpha", "DepartmentRequester");

        // B's list never contains A's users.
        var list = await (await b.Owner.GetAsync("/api/v1/users?pageSize=200")).Ok();
        Assert.DoesNotContain(list["items"]!.AsArray(), u => u!["id"]!.GetValue<string>() == userA.ToString());

        // B cannot change A's user.
        var res = await b.Owner.PutJson($"/api/v1/users/{userA}/roles", new { roles = new[] { "OrganizationOwner" } });
        Assert.Equal(HttpStatusCode.NotFound, res.StatusCode);
        var res2 = await b.Owner.PutJson($"/api/v1/users/{userA}/status", new { status = "Disabled" });
        Assert.Equal(HttpStatusCode.NotFound, res2.StatusCode);
    }

    [Fact]
    public async Task Last_owner_cannot_lose_the_owner_role_and_platform_admin_cannot_be_assigned()
    {
        var t = await TestTenant.Create(factory);
        var res = await t.Owner.PutJson($"/api/v1/users/{t.OwnerId}/roles", new { roles = new[] { "Auditor" } });
        Assert.Equal(HttpStatusCode.Conflict, res.StatusCode);
        var res2 = await t.Owner.PutJson($"/api/v1/users/{t.OwnerId}/roles", new { roles = new[] { "OrganizationOwner", "PlatformAdministrator" } });
        Assert.Equal(HttpStatusCode.BadRequest, res2.StatusCode);
    }

    [Fact]
    public async Task Login_is_audited()
    {
        var t = await TestTenant.Create(factory);
        await factory.CreateClient().PostJson("/api/v1/auth/login", new { email = t.OwnerEmail, password = TestTenant.Password });
        var audit = await (await t.Owner.GetAsync("/api/v1/audit")).Ok();
        Assert.Contains(audit["items"]!.AsArray(), a => a!["action"]!.GetValue<string>() == "auth.login");
    }
}
