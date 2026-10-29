using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;
using VendorFlow.Infrastructure.Persistence;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1/rfqs")]
public class RfqsController(IDb db, ICurrentUser me, ITokenService tokens, IEmailSender mail, IConfiguration config) : ControllerBase
{
    private string PortalLink(string token) => $"{config["App:WebUrl"] ?? "http://localhost:4200"}/portal/rfq/{token}";

    [RequirePermission(Permissions.RfqsView), HttpGet]
    public async Task<IActionResult> List([FromQuery] string? status, [FromQuery] string? search, [FromQuery] string? sortBy,
        [FromQuery] string? sortDir, [FromQuery] int page = 1, [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_rfq_list", new
        {
            p_tenant_id = me.TenantId, p_status = status, p_search = search, p_sort_by = sortBy, p_sort_dir = sortDir,
            p_page = page, p_page_size = pageSize
        }, ct));

    [RequirePermission(Permissions.RfqsView), HttpGet("{id:guid}")]
    public async Task<IActionResult> Get(Guid id, CancellationToken ct) => Ok(await Load(id, ct));

    [RequirePermission(Permissions.RfqsManage), HttpPost]
    public async Task<IActionResult> Create(RfqRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_rfq_create", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.RfqsManage), HttpPut("{id:guid}")]
    public async Task<IActionResult> Update(Guid id, RfqRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_rfq_update", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_data = Db.ToSnakeJson(req) }, ct));

    /// <summary>Opens the RFQ and returns the one-time invitation links (only hashes are stored).</summary>
    [RequirePermission(Permissions.RfqsManage), HttpPost("{id:guid}/open")]
    public async Task<IActionResult> Open(Guid id, CancellationToken ct)
    {
        var draft = await Load(id, ct);
        var links = new JsonObject();
        var hashes = new JsonObject();
        foreach (var v in draft["vendors"]!.AsArray())
        {
            var token = tokens.NewRandomToken();
            var vid = v!["vendorId"]!.GetValue<string>();
            hashes[vid] = tokens.HashToken(token);
            links[vid] = PortalLink(token);
        }
        var rfq = await db.JsonAsync("fn_rfq_open", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_tokens = hashes }, ct);

        var invitations = new JsonArray();
        foreach (var v in rfq!["vendors"]!.AsArray())
        {
            var vid = v!["vendorId"]!.GetValue<string>();
            invitations.Add(new JsonObject { ["vendorId"] = vid, ["vendorName"] = v["vendorName"]!.DeepClone(), ["link"] = links[vid]!.DeepClone() });
            await TrySendInvitation(v, rfq, links[vid]!.GetValue<string>(), ct);
        }
        return Ok(new { rfq, invitations });
    }

    /// <summary>Adds a vendor to an open RFQ or issues a new link for an invited vendor.</summary>
    [RequirePermission(Permissions.RfqsManage), HttpPost("{id:guid}/vendors/{vendorId:guid}/invite")]
    public async Task<IActionResult> Invite(Guid id, Guid vendorId, CancellationToken ct)
    {
        var token = tokens.NewRandomToken();
        var rfq = await db.JsonAsync("fn_rfq_invite", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_vendor_id = vendorId, p_token_hash = tokens.HashToken(token)
        }, ct);
        var link = PortalLink(token);
        var vendor = rfq!["vendors"]!.AsArray().First(v => v!["vendorId"]!.GetValue<string>() == vendorId.ToString())!;
        await TrySendInvitation(vendor, rfq, link, ct);
        return Ok(new { rfq, link });
    }

    [RequirePermission(Permissions.RfqsManage), HttpPost("{id:guid}/close")]
    public async Task<IActionResult> Close(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_rfq_close", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id }, ct));

    [RequirePermission(Permissions.RfqsManage), HttpPost("{id:guid}/cancel")]
    public async Task<IActionResult> Cancel(Guid id, CommentRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_rfq_cancel", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_comment = req.Comment }, ct));

    [RequirePermission(Permissions.RfqsManage), HttpPost("{id:guid}/reopen")]
    public async Task<IActionResult> Reopen(Guid id, ReopenRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_rfq_reopen", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_deadline = req.Deadline }, ct));

    [RequirePermission(Permissions.RfqsManage), HttpPost("{id:guid}/reminders")]
    public async Task<IActionResult> Reminders(Guid id, CancellationToken ct) =>
        Ok(new { queued = await db.ScalarAsync<int>("fn_rfq_send_reminders", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id }, ct) });

    /// <summary>Staff enter a quotation for a vendor (phone / paper).</summary>
    [RequirePermission(Permissions.RfqsManage), HttpPost("{id:guid}/vendors/{vendorId:guid}/quotation")]
    public async Task<IActionResult> EnterQuotation(Guid id, Guid vendorId, QuotationRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_rfq_enter_quotation", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_rfq_id = id, p_vendor_id = vendorId, p_data = Db.ToSnakeJson(req)
        }, ct));

    [RequirePermission(Permissions.RfqsManage), HttpPost("clarifications/{clarificationId:guid}/answer")]
    public async Task<IActionResult> Answer(Guid clarificationId, AnswerRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_rfq_clarification_answer", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = clarificationId, p_answer = req.Answer
        }, ct));

    // ---- comparison -------------------------------------------------------------------------------

    [RequirePermission(Permissions.QuotationsView), HttpGet("{id:guid}/compare")]
    public async Task<IActionResult> Compare(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_quotation_compare", new { p_tenant_id = me.TenantId, p_rfq_id = id }, ct));

    [RequirePermission(Permissions.QuotationsRecommend), HttpPost("{id:guid}/recommendation")]
    public async Task<IActionResult> Recommend(Guid id, RecommendationRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_quotation_recommend", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_rfq_id = id, p_vendor_id = req.VendorId, p_justification = req.Justification
        }, ct));

    private Task<JsonNode?> Load(Guid id, CancellationToken ct) =>
        db.JsonAsync("fn_rfq_get", new { p_tenant_id = me.TenantId, p_id = id }, ct);

    private async Task TrySendInvitation(JsonNode vendor, JsonNode rfq, string link, CancellationToken ct)
    {
        var email = vendor["vendorEmail"]?.GetValue<string>();
        if (!mail.IsConfigured || string.IsNullOrEmpty(email)) return;
        try
        {
            await mail.SendAsync(email, $"Request for quotation {rfq["number"]}",
                $"You are invited to quote for \"{rfq["title"]}\". Submit your quotation here: {link}", ct);
        }
        catch (Exception) { /* the link is also shown to the buyer; sending is best effort */ }
    }
}

/// <summary>Anonymous endpoints used by invited vendors. The secret token in the URL is the only credential.</summary>
[ApiController]
[AllowAnonymous]
[EnableRateLimiting("auth")]
[Route("api/v1/portal/rfq/{token}")]
public class PortalController(IDb db, ITokenService tokens) : ControllerBase
{
    private string Hash(string token) => tokens.HashToken(token);

    [HttpGet]
    public async Task<IActionResult> Get(string token, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_portal_get", new { p_token_hash = Hash(token) }, ct));

    [HttpPost("quotation")]
    public async Task<IActionResult> Submit(string token, QuotationRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_portal_submit_quotation", new { p_token_hash = Hash(token), p_data = Db.ToSnakeJson(req) }, ct));

    [HttpPost("clarifications")]
    public async Task<IActionResult> Ask(string token, QuestionRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_portal_ask", new { p_token_hash = Hash(token), p_question = req.Question }, ct));

    [HttpPost("decline")]
    public async Task<IActionResult> Decline(string token, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_portal_decline", new { p_token_hash = Hash(token) }, ct));
}
