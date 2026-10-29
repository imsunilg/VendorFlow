using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;
using VendorFlow.Infrastructure.Persistence;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1")]
public class SettingsController(IDb db, ICurrentUser me, IFileStorage files) : ControllerBase
{
    /// <summary>Settings of the signed-in user's organization (labels, currency, ...). Any signed-in user may read them.</summary>
    [Authorize, HttpGet("organizations/current/settings")]
    public async Task<IActionResult> Get(CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_settings_get", new { p_tenant_id = me.TenantId }, ct));

    [RequirePermission(Permissions.SettingsManage), HttpPut("organizations/current/settings")]
    public async Task<IActionResult> Update(UpdateSettingsRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_settings_update", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_data = Db.ToSnakeJson(req)
        }, ct));

    [RequirePermission(Permissions.SettingsManage), HttpPost("organizations/current/logo")]
    public async Task<IActionResult> UploadLogo(IFormFile file, CancellationToken ct)
    {
        if (file.ContentType is not ("image/png" or "image/jpeg")) return BadRequest(ApiError.Body(400, "Bad request", "Logo must be PNG or JPG."));
        await using var stream = file.OpenReadStream();
        var saved = await files.SaveAsync(me.TenantId, stream, file.FileName, file.ContentType, ct);
        await db.ExecuteAsync("sp_settings_set_logo", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_storage_key = saved.StorageKey }, ct);
        return Ok(new { logoUrl = saved.StorageKey });
    }

    [Authorize, HttpGet("organizations/current/logo")]
    public async Task<IActionResult> Logo(CancellationToken ct)
    {
        var settings = await db.JsonAsync("fn_settings_get", new { p_tenant_id = me.TenantId }, ct);
        var key = settings?["logoUrl"]?.GetValue<string>();
        if (key is null) return NotFound();
        var file = await files.OpenAsync(me.TenantId, key, ct);
        return file is null ? NotFound() : File(file.Value.Stream, file.Value.ContentType);
    }

    [Authorize, HttpGet("lookups/departments")]
    public async Task<IActionResult> Departments(CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_lookup_departments", new { p_tenant_id = me.TenantId }, ct));

    [Authorize, HttpGet("lookups/cost-centres")]
    public async Task<IActionResult> CostCentres(CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_lookup_cost_centres", new { p_tenant_id = me.TenantId }, ct));
}
