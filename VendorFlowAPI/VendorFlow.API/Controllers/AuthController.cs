using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1/auth")]
[EnableRateLimiting("auth")]
public class AuthController(IDb db, ITokenService tokens, IPasswordService passwords, IEmailSender mail,
    IConfiguration config, ICurrentUser me) : ControllerBase
{
    private const int RefreshDays = 14;

    /// <summary>Creates a new organization (tenant) and its Organization Owner, then signs the owner in.</summary>
    [HttpPost("register-organization")]
    public async Task<IActionResult> Register(RegisterOrganizationRequest req, CancellationToken ct)
    {
        var created = await db.JsonAsync("fn_register_organization", new
        {
            p_org_name = req.OrganizationName, p_full_name = req.FullName, p_email = req.Email,
            p_password_hash = passwords.Hash(req.Password)
        }, ct);
        var userId = Guid.Parse(created!["userId"]!.GetValue<string>());
        return Ok(await IssueTokens(userId, ct));
    }

    /// <summary>Signs in with e-mail and password. Failures never say which of the two was wrong.</summary>
    [HttpPost("login")]
    public async Task<IActionResult> Login(LoginRequest req, CancellationToken ct)
    {
        var login = await db.JsonAsync("fn_auth_get_login", new { p_email = req.Email }, ct);
        if (login is null) return Unauthorized();

        var userId = Guid.Parse(login["userId"]!.GetValue<string>());
        var usable = login["status"]!.GetValue<string>() == "Active" && !login["locked"]!.GetValue<bool>();
        var correct = passwords.Verify(login["passwordHash"]!.GetValue<string>(), req.Password);
        if (!usable || !correct)
        {
            if (usable) await db.ExecuteAsync("sp_auth_login_result", new { p_user_id = userId, p_success = false }, ct);
            return Unauthorized(new { title = "Invalid credentials", status = 401, detail = "Email or password is wrong, or the account is locked." });
        }

        await db.ExecuteAsync("sp_auth_login_result", new { p_user_id = userId, p_success = true }, ct);
        return Ok(await IssueTokens(userId, ct));
    }

    /// <summary>Exchanges a refresh token for a new token pair (the old refresh token stops working).</summary>
    [HttpPost("refresh")]
    public async Task<IActionResult> Refresh(RefreshRequest req, CancellationToken ct)
    {
        var newRefresh = tokens.NewRandomToken();
        var ctx = await db.JsonAsync("fn_auth_rotate_refresh", new
        {
            p_old_hash = tokens.HashToken(req.RefreshToken),
            p_new_hash = tokens.HashToken(newRefresh),
            p_expires = DateTime.UtcNow.AddDays(RefreshDays)
        }, ct);
        if (ctx is null) return Unauthorized();

        var pair = tokens.Create(ctx);
        return Ok(Envelope(pair with { RefreshToken = newRefresh }, ctx));
    }

    /// <summary>Revokes every refresh token of the signed-in user.</summary>
    [Authorize, HttpPost("logout")]
    public async Task<IActionResult> Logout(CancellationToken ct)
    {
        await db.ExecuteAsync("sp_auth_revoke_all", new { p_user_id = me.UserId }, ct);
        return NoContent();
    }

    /// <summary>Returns the current user (roles and permissions).</summary>
    [Authorize, HttpGet("me")]
    public async Task<IActionResult> Me(CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_auth_user_context", new { p_user_id = me.UserId }, ct));

    /// <summary>Starts a password reset. Always answers 202 so e-mail addresses cannot be probed.</summary>
    [HttpPost("forgot-password")]
    public async Task<IActionResult> Forgot(ForgotPasswordRequest req, CancellationToken ct)
    {
        var token = tokens.NewRandomToken();
        var user = await db.JsonAsync("fn_auth_create_reset", new
        {
            p_email = req.Email, p_token_hash = tokens.HashToken(token), p_expires = DateTime.UtcNow.AddHours(1)
        }, ct);

        if (user is not null && mail.IsConfigured)
        {
            var link = $"{config["App:WebUrl"] ?? "http://localhost:4230"}/reset-password?token={token}";
            await mail.SendAsync(user["email"]!.GetValue<string>(), "Reset your password", $"Use this link within one hour: {link}", ct);
        }
        // In Development the token is returned so the flow can be tested without an SMTP server.
        var dev = HttpContext.RequestServices.GetRequiredService<IWebHostEnvironment>().IsDevelopment() && user is not null;
        return Accepted(dev ? new { resetToken = token } : new { });
    }

    [HttpPost("reset-password")]
    public async Task<IActionResult> Reset(ResetPasswordRequest req, CancellationToken ct)
    {
        var ok = await db.ScalarAsync<bool>("fn_auth_reset_password", new
        {
            p_token_hash = tokens.HashToken(req.Token), p_new_hash = passwords.Hash(req.NewPassword)
        }, ct);
        return ok ? NoContent() : BadRequest(new { title = "Invalid or expired token", status = 400 });
    }

    private async Task<object> IssueTokens(Guid userId, CancellationToken ct)
    {
        var ctx = await db.JsonAsync("fn_auth_user_context", new { p_user_id = userId }, ct) ?? throw new UnauthorizedAccessException();
        var pair = tokens.Create(ctx);
        await db.ExecuteAsync("sp_auth_store_refresh", new
        {
            p_user_id = userId, p_token_hash = tokens.HashToken(pair.RefreshToken), p_expires = DateTime.UtcNow.AddDays(RefreshDays)
        }, ct);
        return Envelope(pair, ctx);
    }

    private static object Envelope(TokenPair pair, JsonNode ctx) => new
    {
        accessToken = pair.AccessToken, refreshToken = pair.RefreshToken, expiresAt = pair.AccessExpiresAt, user = ctx
    };
}
