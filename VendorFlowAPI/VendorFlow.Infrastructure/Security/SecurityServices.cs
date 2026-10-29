using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Configuration;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.Infrastructure.Security;

public sealed class PasswordService : IPasswordService
{
    private static readonly PasswordHasher<object> Hasher = new();
    public string Hash(string password) => Hasher.HashPassword(new object(), password);
    public bool Verify(string hash, string password) =>
        Hasher.VerifyHashedPassword(new object(), hash, password) != PasswordVerificationResult.Failed;
}

/// <summary>Creates JWT access tokens (15 minutes) and opaque refresh tokens (stored only as SHA-256 hashes).</summary>
public sealed class TokenService(IConfiguration config) : ITokenService
{
    public const int AccessMinutes = 15;

    public TokenPair Create(JsonNode ctx)
    {
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(config["Jwt:Secret"]
            ?? throw new InvalidOperationException("Jwt:Secret is not configured.")));
        var claims = new List<Claim>
        {
            new("sub", ctx["userId"]!.GetValue<string>()),
            new("tid", ctx["tenantId"]!.GetValue<string>()),
            new("email", ctx["email"]!.GetValue<string>()),
            new("name", ctx["fullName"]!.GetValue<string>())
        };
        if (ctx["vendorId"] is JsonValue v) claims.Add(new Claim("vid", v.GetValue<string>()));
        foreach (var r in ctx["roles"]!.AsArray()) claims.Add(new Claim("role", r!.GetValue<string>()));
        foreach (var p in ctx["permissions"]!.AsArray()) claims.Add(new Claim("perm", p!.GetValue<string>()));

        var expires = DateTime.UtcNow.AddMinutes(AccessMinutes);
        var descriptor = new SecurityTokenDescriptor
        {
            Subject = new ClaimsIdentity(claims),
            Issuer = config["Jwt:Issuer"],
            Audience = config["Jwt:Audience"],
            Expires = expires,
            SigningCredentials = new SigningCredentials(key, SecurityAlgorithms.HmacSha256)
        };
        var access = new JsonWebTokenHandler().CreateToken(descriptor);
        return new TokenPair(access, NewRandomToken(), expires);
    }

    public string NewRandomToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(48))
        .Replace('+', '-').Replace('/', '_').TrimEnd('=');

    public string HashToken(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
}
