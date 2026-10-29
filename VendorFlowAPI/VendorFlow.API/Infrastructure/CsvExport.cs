using System.Text;
using System.Text.Json.Nodes;

namespace VendorFlow.API.Infrastructure;

/// <summary>Turns a list of json objects (from a SQL function) into CSV text. Guards against spreadsheet formula injection.</summary>
public static class CsvExport
{
    public static string FromItems(JsonArray items, (string Header, string Key)[] columns)
    {
        var sb = new StringBuilder();
        sb.AppendLine(string.Join(',', columns.Select(c => Escape(c.Header))));
        foreach (var item in items)
            sb.AppendLine(string.Join(',', columns.Select(c => Escape(Read(item, c.Key)))));
        return sb.ToString();
    }

    private static string Read(JsonNode? item, string key) =>
        item?[key] is JsonValue v ? v.ToString() : "";

    private static string Escape(string value)
    {
        // Cells that start with = + - @ would be run as formulas by Excel; prefix them with an apostrophe.
        if (value.Length > 0 && "=+-@".Contains(value[0]) && !decimal.TryParse(value, out _)) value = "'" + value;
        return value.Contains(',') || value.Contains('"') || value.Contains('\n') ? "\"" + value.Replace("\"", "\"\"") + "\"" : value;
    }
}
