using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Domain;

namespace VendorFlow.API.Controllers;

/// <summary>Attachments for requisitions, RFQs, POs, goods receipts and invoices.</summary>
[ApiController]
[Route("api/v1/attachments")]
[Authorize]
public class AttachmentsController(IDb db, ICurrentUser me, IFileStorage files) : ControllerBase
{
    private static readonly Dictionary<string, (string View, string Edit)> Rules = new()
    {
        ["requisition"] = (Permissions.RequisitionsView, Permissions.RequisitionsCreate),
        ["rfq"] = (Permissions.RfqsView, Permissions.RfqsManage),
        ["purchase_order"] = (Permissions.PoView, Permissions.PoCreate),
        ["goods_receipt"] = (Permissions.GrnView, Permissions.GrnRecord),
        ["invoice"] = (Permissions.InvoicesView, Permissions.InvoicesCreate)
    };

    [HttpGet("{entityType}/{entityId:guid}")]
    public async Task<IActionResult> List(string entityType, Guid entityId, CancellationToken ct)
    {
        if (!Rules.TryGetValue(entityType, out var rule) || !me.HasPermission(rule.View)) return Forbid();
        return Ok(await db.JsonAsync("fn_attachment_list", new { p_tenant_id = me.TenantId, p_entity_type = entityType, p_entity_id = entityId }, ct));
    }

    [HttpPost("{entityType}/{entityId:guid}")]
    public async Task<IActionResult> Upload(string entityType, Guid entityId, IFormFile file, CancellationToken ct)
    {
        if (!Rules.TryGetValue(entityType, out var rule) || !me.HasPermission(rule.Edit)) return Forbid();
        await using var stream = file.OpenReadStream();
        var saved = await files.SaveAsync(me.TenantId, stream, file.FileName, file.ContentType, ct);
        return Ok(await db.JsonAsync("fn_attachment_add", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_entity_type = entityType, p_entity_id = entityId,
            p_file_name = saved.FileName, p_content_type = saved.ContentType, p_size = saved.Size, p_storage_key = saved.StorageKey
        }, ct));
    }

    [HttpGet("{id:guid}/file")]
    public async Task<IActionResult> Download(Guid id, CancellationToken ct)
    {
        var info = await db.JsonAsync("fn_attachment_file", new { p_tenant_id = me.TenantId, p_id = id }, ct);
        if (info is null) return NotFound();
        if (!Rules.TryGetValue(info["entityType"]!.GetValue<string>(), out var rule) || !me.HasPermission(rule.View)) return Forbid();
        var file = await files.OpenAsync(me.TenantId, info["storageKey"]!.GetValue<string>(), ct);
        return file is null ? NotFound() : File(file.Value.Stream, file.Value.ContentType, info["fileName"]!.GetValue<string>());
    }

    [HttpDelete("{id:guid}")]
    public async Task<IActionResult> Delete(Guid id, CancellationToken ct)
    {
        var info = await db.JsonAsync("fn_attachment_file", new { p_tenant_id = me.TenantId, p_id = id }, ct);
        if (info is null) return NotFound();
        if (!Rules.TryGetValue(info["entityType"]!.GetValue<string>(), out var rule) || !me.HasPermission(rule.Edit)) return Forbid();
        return Ok(await db.JsonAsync("fn_attachment_delete", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id }, ct));
    }
}
