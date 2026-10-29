using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.Infrastructure.Persistence;

/// <summary>
/// Development only: creates the "Demo Company" tenant, its users and sample documents once.
/// Everything goes through the normal SQL functions. Only demo credentials are used (never real ones).
/// </summary>
public sealed class DemoSeeder(IDb db, IPasswordService passwords, ITokenService tokens, ILogger<DemoSeeder> log)
{
    public const string OwnerEmail = "priya.menon@democompany.in";

    public async Task SeedAsync(string demoPassword, CancellationToken ct = default)
    {
        var existing = await db.JsonAsync("fn_auth_get_login", new { p_email = OwnerEmail }, ct);
        if (existing is not null) return;

        var created = await db.JsonAsync("fn_register_organization", new
        {
            p_org_name = "Demo Company", p_full_name = "Priya Menon", p_email = OwnerEmail, p_password_hash = passwords.Hash(demoPassword)
        }, ct);
        var tenant = Guid.Parse(created!["tenantId"]!.GetValue<string>());
        var priya = Guid.Parse(created["userId"]!.GetValue<string>());
        // Priya is the Procurement Manager in the demo screens and also the organization owner.
        await db.JsonAsync("fn_user_set_roles", new
        {
            p_tenant_id = tenant, p_actor_id = priya, p_user_id = priya, p_role_codes = new[] { "OrganizationOwner", "ProcurementManager" }
        }, ct);

        var users = new JsonObject { ["priya"] = priya.ToString() };
        users["mark"] = (await AddUser(tenant, priya, "mark.w@democompany.in", "Mark Williams", ["ProcurementManager"], demoPassword, ct)).ToString();
        users["rahul"] = (await AddUser(tenant, priya, "rahul.d@democompany.in", "Rahul Deshmukh", ["DepartmentManager", "Approver"], demoPassword, ct)).ToString();
        users["sneha"] = (await AddUser(tenant, priya, "sneha.i@democompany.in", "Sneha Iyer", ["FinanceManager"], demoPassword, ct)).ToString();
        users["anita"] = (await AddUser(tenant, priya, "anita.rao@democompany.in", "Anita Rao", ["DepartmentRequester"], demoPassword, ct)).ToString();
        users["suresh"] = (await AddUser(tenant, priya, "suresh.j@democompany.in", "Suresh Jadhav", ["WarehouseManager"], demoPassword, ct)).ToString();

        await db.JsonAsync("fn_seed_demo_data", new { p_tenant_id = tenant, p_users = users }, ct);
        log.LogInformation("Demo data created for tenant Demo Company ({Email})", OwnerEmail);
    }

    private async Task<Guid> AddUser(Guid tenant, Guid actor, string email, string name, string[] roles, string password, CancellationToken ct)
    {
        var invited = await db.JsonAsync("fn_user_invite", new
        {
            p_tenant_id = tenant, p_actor_id = actor, p_email = email, p_full_name = name, p_role_codes = roles,
            p_password_hash = passwords.Hash(password)
        }, ct);
        // Activate through the normal password-reset path (invited users become Active when they set a password).
        var token = tokens.NewRandomToken();
        await db.JsonAsync("fn_auth_create_reset", new { p_email = email, p_token_hash = tokens.HashToken(token), p_expires = DateTime.UtcNow.AddHours(1) }, ct);
        await db.ScalarAsync<bool>("fn_auth_reset_password", new { p_token_hash = tokens.HashToken(token), p_new_hash = passwords.Hash(password) }, ct);
        return Guid.Parse(invited!["id"]!.GetValue<string>());
    }
}
