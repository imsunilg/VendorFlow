using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Domain;

namespace VendorFlow.API.Controllers;

/// <summary>Optional AI extraction. Returns suggestions only; nothing is saved and nothing is approved automatically.</summary>
[ApiController]
[Route("api/v1/documents")]
public class DocumentExtractionController(IDocumentExtractionProvider provider, ICurrentUser me) : ControllerBase
{
    [RequirePermission(Permissions.InvoicesCreate), HttpGet("extraction/status")]
    public IActionResult Status() => Ok(new { enabled = provider.IsEnabled, provider = provider.Name, manualEntryAvailable = true });

    /// <param name="documentType">invoice | quotation</param>
    [RequirePermission(Permissions.InvoicesCreate), HttpPost("extract/{documentType}")]
    public async Task<IActionResult> Extract(string documentType, IFormFile file, CancellationToken ct)
    {
        if (!provider.IsEnabled)
            return StatusCode(501, ApiError.Body(501, "AI extraction is off", "No extraction provider is configured. Enter the data manually."));
        if (documentType is not ("invoice" or "quotation")) return BadRequest(ApiError.Body(400, "Bad request", "documentType must be invoice or quotation."));

        await using var stream = file.OpenReadStream();
        var result = await provider.ExtractAsync(documentType, stream, file.FileName, ct);
        return Ok(new { requiresConfirmation = true, tenantId = me.TenantId, result.DocumentType, result.Fields });
    }
}
