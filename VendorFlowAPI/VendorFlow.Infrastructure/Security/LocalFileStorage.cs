using Microsoft.Extensions.Configuration;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.Infrastructure.Security;

/// <summary>Stores uploads on disk under storage/{tenant}/{random key}. File names from users are never used as paths.</summary>
public sealed class LocalFileStorage(IConfiguration config) : IFileStorage
{
    private const long MaxBytes = 10 * 1024 * 1024;
    private static readonly Dictionary<string, string> Allowed = new(StringComparer.OrdinalIgnoreCase)
    {
        [".pdf"] = "application/pdf", [".jpg"] = "image/jpeg", [".jpeg"] = "image/jpeg", [".png"] = "image/png",
        [".xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", [".csv"] = "text/csv"
    };

    private string Root => Path.GetFullPath(config["Storage:Path"] ?? "storage");

    public async Task<StoredFile> SaveAsync(Guid tenantId, Stream content, string fileName, string contentType, CancellationToken ct)
    {
        var ext = Path.GetExtension(fileName);
        if (!Allowed.TryGetValue(ext, out var mime))
            throw new ArgumentException("File type not allowed. Use PDF, JPG, PNG, XLSX or CSV.");

        var folder = Path.Combine(Root, tenantId.ToString("N"));
        Directory.CreateDirectory(folder);
        var key = Guid.NewGuid().ToString("N") + ext.ToLowerInvariant();
        var path = Path.Combine(folder, key);

        long size = 0;
        await using (var fs = File.Create(path))
        {
            var buffer = new byte[81920];
            int read;
            while ((read = await content.ReadAsync(buffer, ct)) > 0)
            {
                size += read;
                if (size > MaxBytes)
                {
                    fs.Close();
                    File.Delete(path);
                    throw new ArgumentException("File is larger than 10 MB.");
                }
                await fs.WriteAsync(buffer.AsMemory(0, read), ct);
            }
        }
        return new StoredFile($"{tenantId:N}/{key}", Path.GetFileName(fileName), mime, size);
    }

    public Task<(Stream Stream, string ContentType)?> OpenAsync(Guid tenantId, string storageKey, CancellationToken ct)
    {
        // The key must belong to the caller's tenant folder and contain no path tricks.
        var parts = storageKey.Split('/');
        if (parts.Length != 2 || parts[0] != tenantId.ToString("N") || parts[1].Contains("..") || parts[1].Contains('\\'))
            return Task.FromResult<(Stream, string)?>(null);
        var path = Path.Combine(Root, parts[0], parts[1]);
        if (!File.Exists(path)) return Task.FromResult<(Stream, string)?>(null);
        var mime = Allowed.GetValueOrDefault(Path.GetExtension(path), "application/octet-stream");
        return Task.FromResult<(Stream, string)?>((File.OpenRead(path), mime));
    }
}
