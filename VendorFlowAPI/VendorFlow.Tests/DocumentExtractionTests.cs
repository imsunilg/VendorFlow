using System.Net;
using System.Text;
using VendorFlow.Tests.TestSupport;

namespace VendorFlow.Tests;

[Collection("api")]
public class DocumentExtractionTests(ApiFactory factory)
{
    [Fact]
    public async Task Extraction_is_disabled_by_default_and_manual_entry_still_works()
    {
        var s = await InvSetup.Create(factory);
        var status = await (await s.Finance.GetAsync("/api/v1/documents/extraction/status")).Ok();
        Assert.False(status["enabled"]!.GetValue<bool>());
        Assert.True(status["manualEntryAvailable"]!.GetValue<bool>());

        var form = new MultipartFormDataContent();
        form.Add(new ByteArrayContent(Encoding.UTF8.GetBytes("%PDF")), "file", "bill.pdf");
        Assert.Equal(HttpStatusCode.NotImplemented, (await s.Finance.PostAsync("/api/v1/documents/extract/invoice", form)).StatusCode);

        // the normal manual flow is unaffected
        Assert.Equal(HttpStatusCode.OK, (await s.Finance.PostJson("/api/v1/invoices", s.Invoice(InvSetup.Num()))).StatusCode);
    }

    [Fact]
    public async Task Extraction_endpoint_needs_a_permission()
    {
        var o = await ApprovalOrg.Create(factory);
        Assert.Equal(HttpStatusCode.Forbidden, (await o.Requester.GetAsync("/api/v1/documents/extraction/status")).StatusCode);
    }
}
