namespace VendorFlow.Application.Abstractions;

/// <summary>Identity of the caller, read from the JWT claims. The tenant is never taken from client input.</summary>
public interface ICurrentUser
{
    Guid TenantId { get; }
    Guid UserId { get; }
    string Email { get; }
    bool HasPermission(string permission);
}

public record TokenPair(string AccessToken, string RefreshToken, DateTime AccessExpiresAt);

public interface ITokenService
{
    /// <summary>Creates a signed access token for a user-context json (from fn_auth_user_context) plus a new random refresh token.</summary>
    TokenPair Create(System.Text.Json.Nodes.JsonNode userContext);
    string HashToken(string token);
    string NewRandomToken();
}

public interface IPasswordService
{
    string Hash(string password);
    bool Verify(string hash, string password);
}

public record StoredFile(string StorageKey, string FileName, string ContentType, long Size);

public interface IFileStorage
{
    /// <summary>Validates (type and size) and saves a file under a random key inside the tenant's folder.</summary>
    Task<StoredFile> SaveAsync(Guid tenantId, Stream content, string fileName, string contentType, CancellationToken ct);
    Task<(Stream Stream, string ContentType)?> OpenAsync(Guid tenantId, string storageKey, CancellationToken ct);
}

public interface IEmailSender
{
    bool IsConfigured { get; }
    Task SendAsync(string to, string subject, string body, CancellationToken ct);
}

public interface IPoPdfGenerator
{
    /// <summary>Creates the purchase order PDF from the json returned by fn_po_pdf_data.</summary>
    byte[] Generate(System.Text.Json.Nodes.JsonNode data);
}
