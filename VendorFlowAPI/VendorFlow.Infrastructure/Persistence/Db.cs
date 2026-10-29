using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Npgsql;
using NpgsqlTypes;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.Infrastructure.Persistence;

/// <summary>Calls PostgreSQL functions and procedures. No other SQL is issued by the application.</summary>
public sealed class Db(NpgsqlDataSource dataSource) : IDb
{
    public async Task<JsonNode?> JsonAsync(string function, object? args = null, CancellationToken ct = default)
    {
        var raw = await RunAsync($"select vendorflow.{function}(", args, ")", ct);
        return raw is string s ? ToCamel(JsonNode.Parse(s)) : null;
    }

    public async Task<T?> ScalarAsync<T>(string function, object? args = null, CancellationToken ct = default)
    {
        var raw = await RunAsync($"select vendorflow.{function}(", args, ")", ct);
        if (raw is null || raw is DBNull) return default;
        return (T)Convert.ChangeType(raw, Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T));
    }

    public async Task ExecuteAsync(string procedure, object? args = null, CancellationToken ct = default)
        => await RunAsync($"call vendorflow.{procedure}(", args, ")", ct);

    public async Task<JsonNode?> CallAsync(string procedure, object? args = null, CancellationToken ct = default)
    {
        var raw = await RunAsync($"call vendorflow.{procedure}(", args, ")", ct, appendResult: true);
        return raw is string s ? ToCamel(JsonNode.Parse(s)) : null;
    }

    /// <summary>Builds "prefix p_a => @p_a, p_b => @p_b suffix", runs it and returns the first column of the first row.</summary>
    private async Task<object?> RunAsync(string prefix, object? args, string suffix, CancellationToken ct, bool appendResult = false)
    {
        await using var cmd = dataSource.CreateCommand();
        var sql = new StringBuilder(prefix);
        var first = true;
        foreach (var (name, value) in ReadArgs(args))
        {
            if (!first) sql.Append(", ");
            first = false;
            sql.Append(name).Append(" => @").Append(name);
            cmd.Parameters.Add(ToParameter(name, value));
        }
        if (appendResult) sql.Append(first ? "" : ", ").Append("p_result => null::jsonb");
        sql.Append(suffix);
        cmd.CommandText = sql.ToString();
        return await cmd.ExecuteScalarAsync(ct);
    }

    private static IEnumerable<(string Name, object? Value)> ReadArgs(object? args)
    {
        if (args is null) yield break;
        foreach (var p in args.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
            yield return (p.Name, p.GetValue(args));
    }

    private static NpgsqlParameter ToParameter(string name, object? value)
    {
        switch (value)
        {
            case null: return new NpgsqlParameter(name, DBNull.Value);
            case JsonNode node: return new NpgsqlParameter(name, NpgsqlDbType.Jsonb) { Value = node.ToJsonString() };
            case JsonElement el: return new NpgsqlParameter(name, NpgsqlDbType.Jsonb) { Value = el.GetRawText() };
            default: return new NpgsqlParameter(name, value);
        }
    }

    // ---- helpers shared with callers -------------------------------------------------------

    /// <summary>Serializes a request model to snake_case json, the shape the SQL functions read.</summary>
    public static JsonNode ToSnakeJson(object model) =>
        JsonSerializer.SerializeToNode(model, SnakeOptions)!;

    private static readonly JsonSerializerOptions SnakeOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
    };

    private static JsonNode? ToCamel(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.Select(kv =>
            new KeyValuePair<string, JsonNode?>(CamelKey(kv.Key), ToCamel(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(ToCamel).ToArray()),
        null => null,
        _ => node.DeepClone()
    };

    private static string CamelKey(string key)
    {
        if (!key.Contains('_')) return key;
        var parts = key.Split('_', StringSplitOptions.RemoveEmptyEntries);
        return parts[0] + string.Concat(parts.Skip(1).Select(p => char.ToUpperInvariant(p[0]) + p[1..]));
    }
}
