using VendorFlow.Application.Abstractions;

namespace VendorFlow.Infrastructure.Documents;

/// <summary>Default provider: AI extraction is off. Manual entry always works.</summary>
public sealed class NullDocumentExtractionProvider : IDocumentExtractionProvider
{
    public bool IsEnabled => false;
    public string Name => "none";

    public Task<ExtractionResult> ExtractAsync(string documentType, Stream content, string fileName, CancellationToken ct) =>
        throw new NotSupportedException("AI document extraction is not configured.");
}
