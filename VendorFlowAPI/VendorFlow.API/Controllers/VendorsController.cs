using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;
using VendorFlow.Infrastructure.Persistence;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1/vendors")]
public class VendorsController(IDb db, ICurrentUser me, IFileStorage files) : ControllerBase
{
    private object T => new { p_tenant_id = me.TenantId };

    [RequirePermission(Permissions.VendorsView), HttpGet]
    public async Task<IActionResult> List([FromQuery] string? search, [FromQuery] string? status, [FromQuery] string? category,
        [FromQuery] string? risk, [FromQuery] string? sortBy, [FromQuery] string? sortDir,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_vendor_list", new
        {
            p_tenant_id = me.TenantId, p_search = search, p_status = status, p_category = category, p_risk = risk,
            p_sort_by = sortBy, p_sort_dir = sortDir, p_page = page, p_page_size = pageSize
        }, ct));

    /// <summary>CSV export of the vendors matching the same filters as the list.</summary>
    [RequirePermission(Permissions.VendorsView), HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] string? search, [FromQuery] string? status, [FromQuery] string? category,
        [FromQuery] string? risk, CancellationToken ct = default)
    {
        var all = new JsonArray();
        for (var page = 1; page <= 50; page++)
        {
            var res = await db.JsonAsync("fn_vendor_list", new
            {
                p_tenant_id = me.TenantId, p_search = search, p_status = status, p_category = category, p_risk = risk,
                p_sort_by = "name", p_sort_dir = "asc", p_page = page, p_page_size = 200
            }, ct);
            var items = res!["items"]!.AsArray();
            foreach (var i in items.ToList()) { items.Remove(i); all.Add(i); }
            if (items.Count == 0 || all.Count >= res["totalCount"]!.GetValue<int>()) break;
        }
        var csv = CsvExport.FromItems(all, [("Code", "code"), ("Name", "name"), ("Category", "category"), ("City", "city"),
            ("State", "state"), ("Risk", "risk"), ("Rating", "rating"), ("Status", "status"), ("GSTIN", "gstin"), ("Email", "email")]);
        return File(Encoding.UTF8.GetBytes(csv), "text/csv", "vendors.csv");
    }

    [RequirePermission(Permissions.VendorsView), HttpGet("categories")]
    public async Task<IActionResult> Categories(CancellationToken ct) => Ok(await db.JsonAsync("fn_vendor_categories", T, ct));

    [RequirePermission(Permissions.VendorsView), HttpGet("{id:guid}")]
    public async Task<IActionResult> Get(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_get", new { p_tenant_id = me.TenantId, p_id = id }, ct));

    [RequirePermission(Permissions.VendorsCreate), HttpPost]
    public async Task<IActionResult> Create(VendorRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_create", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.VendorsEdit), HttpPut("{id:guid}")]
    public async Task<IActionResult> Update(Guid id, VendorRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_update", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_data = Db.ToSnakeJson(req) }, ct));

    // ---- workflow -------------------------------------------------------------------------

    [RequirePermission(Permissions.VendorsEdit), HttpPost("{id:guid}/submit")]
    public Task<IActionResult> Submit(Guid id, CancellationToken ct) => Transition(id, "submit", null, ct);

    [RequirePermission(Permissions.VendorsApprove), HttpPost("{id:guid}/approve")]
    public Task<IActionResult> Approve(Guid id, CommentRequest? req, CancellationToken ct) => Transition(id, "approve", req?.Comment, ct);

    [RequirePermission(Permissions.VendorsApprove), HttpPost("{id:guid}/reject")]
    public Task<IActionResult> Reject(Guid id, CommentRequest req, CancellationToken ct) => Transition(id, "reject", req.Comment, ct);

    [RequirePermission(Permissions.VendorsSuspend), HttpPost("{id:guid}/suspend")]
    public Task<IActionResult> Suspend(Guid id, CommentRequest req, CancellationToken ct) => Transition(id, "suspend", req.Comment, ct);

    [RequirePermission(Permissions.VendorsSuspend), HttpPost("{id:guid}/reactivate")]
    public Task<IActionResult> Reactivate(Guid id, CommentRequest? req, CancellationToken ct) => Transition(id, "reactivate", req?.Comment, ct);

    private async Task<IActionResult> Transition(Guid id, string action, string? comment, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_transition", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_action = action, p_comment = comment
        }, ct));

    // ---- contacts, addresses, documents -----------------------------------------------------

    [RequirePermission(Permissions.VendorsEdit), HttpPost("{id:guid}/contacts")]
    public async Task<IActionResult> SaveContact(Guid id, VendorContactRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_contact_save", Args(id, Db.ToSnakeJson(req)), ct));

    [RequirePermission(Permissions.VendorsEdit), HttpDelete("{id:guid}/contacts/{contactId:guid}")]
    public async Task<IActionResult> DeleteContact(Guid id, Guid contactId, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_contact_delete", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_vendor_id = id, p_id = contactId }, ct));

    [RequirePermission(Permissions.VendorsEdit), HttpPost("{id:guid}/addresses")]
    public async Task<IActionResult> SaveAddress(Guid id, VendorAddressRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_address_save", Args(id, Db.ToSnakeJson(req)), ct));

    [RequirePermission(Permissions.VendorsEdit), HttpDelete("{id:guid}/addresses/{addressId:guid}")]
    public async Task<IActionResult> DeleteAddress(Guid id, Guid addressId, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_address_delete", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_vendor_id = id, p_id = addressId }, ct));

    /// <summary>Adds or updates a vendor document (multipart form, file optional).</summary>
    [RequirePermission(Permissions.VendorsEdit), HttpPost("{id:guid}/documents")]
    public async Task<IActionResult> SaveDocument(Guid id, [FromForm] VendorDocumentForm form, CancellationToken ct)
    {
        var data = new JsonObject
        {
            ["id"] = form.Id?.ToString(), ["doc_type"] = form.DocType, ["doc_number"] = form.DocNumber,
            ["expiry_date"] = form.ExpiryDate?.ToString("yyyy-MM-dd")
        };
        if (form.File is not null)
        {
            await using var stream = form.File.OpenReadStream();
            var saved = await files.SaveAsync(me.TenantId, stream, form.File.FileName, form.File.ContentType, ct);
            data["file_name"] = saved.FileName;
            data["storage_key"] = saved.StorageKey;
        }
        return Ok(await db.JsonAsync("fn_vendor_document_save", Args(id, data), ct));
    }

    [RequirePermission(Permissions.VendorsEdit), HttpDelete("{id:guid}/documents/{docId:guid}")]
    public async Task<IActionResult> DeleteDocument(Guid id, Guid docId, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_document_delete", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_vendor_id = id, p_id = docId }, ct));

    [RequirePermission(Permissions.VendorsView), HttpGet("{id:guid}/documents/{docId:guid}/file")]
    public async Task<IActionResult> DocumentFile(Guid id, Guid docId, CancellationToken ct)
    {
        var info = await db.JsonAsync("fn_vendor_document_file", new { p_tenant_id = me.TenantId, p_vendor_id = id, p_id = docId }, ct);
        if (info is null) return NotFound();
        var file = await files.OpenAsync(me.TenantId, info["storageKey"]!.GetValue<string>(), ct);
        return file is null ? NotFound() : File(file.Value.Stream, file.Value.ContentType, info["fileName"]?.GetValue<string>());
    }

    // ---- bank details (restricted) ---------------------------------------------------------

    [RequirePermission(Permissions.VendorsBankView), HttpGet("{id:guid}/bank")]
    public async Task<IActionResult> GetBank(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_bank_get", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_vendor_id = id }, ct));

    [RequirePermission(Permissions.VendorsBankManage), HttpPut("{id:guid}/bank")]
    public async Task<IActionResult> SaveBank(Guid id, VendorBankRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_bank_save", Args(id, Db.ToSnakeJson(req)), ct));

    // ---- performance and history -----------------------------------------------------------

    [RequirePermission(Permissions.VendorsView), HttpGet("{id:guid}/performance")]
    public async Task<IActionResult> Performance(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_performance", new { p_tenant_id = me.TenantId, p_vendor_id = id }, ct));

    [RequirePermission(Permissions.VendorsView), HttpGet("{id:guid}/history")]
    public async Task<IActionResult> History(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_vendor_history", new { p_tenant_id = me.TenantId, p_vendor_id = id }, ct));

    private object Args(Guid vendorId, JsonNode data) =>
        new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_vendor_id = vendorId, p_data = data };
}
