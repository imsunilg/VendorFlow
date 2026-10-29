using System.Text.Json.Nodes;

namespace VendorFlow.Application.Abstractions;

/// <summary>
/// The only door to the database. Every call runs ONE PostgreSQL function (fn_*) or procedure (sp_*)
/// in schema "vendorflow". Arguments are passed by name (an anonymous object whose property names match the SQL parameter names).
/// </summary>
public interface IDb
{
    /// <summary>select vendorflow.fn(...) where the function returns jsonb. Keys come back in camelCase.</summary>
    Task<JsonNode?> JsonAsync(string function, object? args = null, CancellationToken ct = default);

    /// <summary>select vendorflow.fn(...) for functions returning a simple value (text, bool, int, uuid).</summary>
    Task<T?> ScalarAsync<T>(string function, object? args = null, CancellationToken ct = default);

    /// <summary>call vendorflow.sp(...) for a procedure without output.</summary>
    Task ExecuteAsync(string procedure, object? args = null, CancellationToken ct = default);

    /// <summary>call vendorflow.sp(..., p_result =&gt; null) for a procedure with an INOUT p_result jsonb.</summary>
    Task<JsonNode?> CallAsync(string procedure, object? args = null, CancellationToken ct = default);
}
