using System.Globalization;
using System.Text.Json.Nodes;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.Infrastructure.Documents;

/// <summary>Builds the purchase order PDF. The header shows the tenant's configured display name (not a fixed product name).</summary>
public sealed class PoPdfGenerator : IPoPdfGenerator
{
    private static readonly CultureInfo Indian = new("en-IN");

    static PoPdfGenerator() => QuestPDF.Settings.License = LicenseType.Community;

    public byte[] Generate(JsonNode data)
    {
        var po = data["po"]!;
        var org = data["organization"]!;
        var vendor = data["vendor"]!;
        var currency = po["currency"]?.GetValue<string>() ?? "INR";
        string Money(JsonNode? n) => currency + " " + (n?.GetValue<decimal>() ?? 0).ToString("N2", Indian);

        return Document.Create(doc => doc.Page(page =>
        {
            page.Size(PageSizes.A4);
            page.Margin(30);
            page.DefaultTextStyle(t => t.FontSize(10));

            page.Header().Column(col =>
            {
                col.Item().Text(org["appDisplayName"]!.GetValue<string>()).FontSize(18).Bold();
                col.Item().Text(org["organizationName"]!.GetValue<string>()).FontColor(Colors.Grey.Darken2);
                col.Item().PaddingTop(6).Row(row =>
                {
                    row.RelativeItem().Text($"PURCHASE ORDER  {po["number"]}").FontSize(14).Bold();
                    row.RelativeItem().AlignRight().Text($"Revision {po["revision"]} · {po["status"]}");
                });
                col.Item().PaddingBottom(6).LineHorizontal(1);
            });

            page.Content().Column(col =>
            {
                col.Spacing(8);
                col.Item().Row(row =>
                {
                    row.RelativeItem().Column(c =>
                    {
                        c.Item().Text("Vendor").Bold();
                        c.Item().Text(vendor["name"]!.GetValue<string>());
                        if (vendor["gstin"] is JsonValue g) c.Item().Text("GSTIN: " + g);
                        if (vendor["address"] is JsonValue a) c.Item().Text(a.ToString());
                    });
                    row.RelativeItem().Column(c =>
                    {
                        c.Item().Text("Order date: " + po["orderDate"]);
                        c.Item().Text("Expected delivery: " + (po["expectedDelivery"]?.ToString() ?? "-"));
                        c.Item().Text("Currency: " + currency);
                    });
                });

                col.Item().Table(t =>
                {
                    t.ColumnsDefinition(c =>
                    {
                        c.ConstantColumn(24); c.RelativeColumn(4); c.ConstantColumn(60); c.ConstantColumn(70);
                        c.ConstantColumn(40); c.ConstantColumn(40); c.ConstantColumn(80);
                    });
                    t.Header(h =>
                    {
                        foreach (var title in new[] { "#", "Description", "Qty", "Rate", "Disc %", "Tax %", "Total" })
                            h.Cell().Background(Colors.Grey.Lighten3).Padding(3).Text(title).Bold();
                    });
                    foreach (var i in po["items"]!.AsArray())
                    {
                        t.Cell().Padding(3).Text(i!["lineNo"]!.ToString());
                        t.Cell().Padding(3).Text(i["description"]!.GetValue<string>());
                        t.Cell().Padding(3).Text($"{i["quantity"]} {i["unit"]}");
                        t.Cell().Padding(3).AlignRight().Text(i["rate"]!.GetValue<decimal>().ToString("N2", Indian));
                        t.Cell().Padding(3).AlignRight().Text(i["discountPercent"]!.GetValue<decimal>().ToString("0.##"));
                        t.Cell().Padding(3).AlignRight().Text(i["taxPercent"]!.GetValue<decimal>().ToString("0.##"));
                        t.Cell().Padding(3).AlignRight().Text(i["lineTotal"]!.GetValue<decimal>().ToString("N2", Indian));
                    }
                });

                col.Item().AlignRight().Column(c =>
                {
                    c.Item().Text("Sub-total: " + Money(po["subtotal"]));
                    c.Item().Text("Tax: " + Money(po["taxTotal"]));
                    c.Item().Text("Shipping: " + Money(po["shipping"]));
                    c.Item().Text("Total: " + Money(po["total"])).Bold().FontSize(12);
                });

                if (po["notes"] is JsonValue notes) col.Item().Text("Notes: " + notes);
            });

            page.Footer().AlignCenter().Text(x =>
            {
                x.Span("Issued purchase orders are locked; changes require a new revision.  Page ");
                x.CurrentPageNumber();
            });
        })).GeneratePdf();
    }
}
