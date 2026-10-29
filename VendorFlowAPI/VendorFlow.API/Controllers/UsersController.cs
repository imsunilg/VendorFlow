using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1")]
[RequirePermission(Permissions.UsersManage)]
public class UsersController(IDb db, ICurrentUser me, ITokenService tokens, IPasswordService passwords,
    IEmailSender mail, IConfiguration config) : ControllerBase
{
    [HttpGet("users")]
    public async Task<IActionResult> List([FromQuery] string? search, [FromQuery] int page = 1, [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_user_list", new { p_tenant_id = me.TenantId, p_search = search, p_page = page, p_page_size = pageSize }, ct));

    [HttpGet("roles")]
    public async Task<IActionResult> Roles(CancellationToken ct) => Ok(await db.JsonAsync("fn_role_list", null, ct));

    /// <summary>Invites a user. The invitee sets a password with the returned (and e-mailed) reset token.</summary>
    [HttpPost("users/invite")]
    public async Task<IActionResult> Invite(InviteUserRequest req, CancellationToken ct)
    {
        var created = await db.JsonAsync("fn_user_invite", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_email = req.Email, p_full_name = req.FullName,
            p_role_codes = req.Roles, p_password_hash = passwords.Hash(tokens.NewRandomToken())
        }, ct);

        var token = tokens.NewRandomToken();
        await db.JsonAsync("fn_auth_create_reset", new
        {
            p_email = req.Email, p_token_hash = tokens.HashToken(token), p_expires = DateTime.UtcNow.AddDays(7)
        }, ct);
        if (mail.IsConfigured)
            await mail.SendAsync(req.Email, "You have been invited",
                $"Set your password: {config["App:WebUrl"] ?? "http://localhost:4200"}/reset-password?token={token}", ct);

        return Ok(new { user = created, inviteToken = token });
    }

    [HttpPut("users/{id:guid}/roles")]
    public async Task<IActionResult> SetRoles(Guid id, SetRolesRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_user_set_roles", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_user_id = id, p_role_codes = req.Roles }, ct));

    [HttpPut("users/{id:guid}/status")]
    public async Task<IActionResult> SetStatus(Guid id, SetStatusRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_user_set_status", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_user_id = id, p_status = req.Status }, ct));
}
