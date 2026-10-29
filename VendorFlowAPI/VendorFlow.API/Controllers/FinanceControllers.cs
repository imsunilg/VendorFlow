using System.Text;
using Microsoft.AspNetCore.Mvc;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Domain;
using VendorFlow.Infrastructure.Persistence;

namespace VendorFlow.API.Controllers;

[ApiController]
[Route("api/v1/invoices")]
public class InvoicesController(IDb db, ICurrentUser me) : ControllerBase
{
    private object Ctx(Guid id) => new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id };

    /// <summary>tab = all | outstanding | overdue.</summary>
    [RequirePermission(Permissions.InvoicesView), HttpGet]
    public async Task<IActionResult> List([FromQuery] string? tab, [FromQuery] string? status, [FromQuery] Guid? vendorId, [FromQuery] string? search,
        [FromQuery] string? sortBy, [FromQuery] string? sortDir, [FromQuery] int page = 1, [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_invoice_list", new
        {
            p_tenant_id = me.TenantId, p_tab = tab ?? "all", p_status = status, p_vendor_id = vendorId, p_search = search,
            p_sort_by = sortBy, p_sort_dir = sortDir, p_page = page, p_page_size = pageSize
        }, ct));

    [RequirePermission(Permissions.InvoicesView), HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] string? tab, [FromQuery] string? status, CancellationToken ct)
    {
        var res = await db.JsonAsync("fn_invoice_list", new
        {
            p_tenant_id = me.TenantId, p_tab = tab ?? "all", p_status = status, p_vendor_id = (Guid?)null, p_search = (string?)null,
            p_sort_by = "invoice_date", p_sort_dir = "desc", p_page = 1, p_page_size = 200
        }, ct);
        var csv = CsvExport.FromItems(res!["items"]!.AsArray(), [("Invoice", "invoiceNumber"), ("Vendor", "vendorName"), ("PO", "poNumber"),
            ("Invoice date", "invoiceDate"), ("Due date", "dueDate"), ("Status", "status"), ("Total", "total"), ("Paid", "paidAmount"), ("Balance", "balance")]);
        return File(Encoding.UTF8.GetBytes(csv), "text/csv", "invoices.csv");
    }

    [RequirePermission(Permissions.InvoicesView), HttpGet("{id:guid}")]
    public async Task<IActionResult> Get(Guid id, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_invoice_get", new { p_tenant_id = me.TenantId, p_id = id }, ct));

    [RequirePermission(Permissions.InvoicesCreate), HttpPost]
    public async Task<IActionResult> Register(InvoiceRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_invoice_register", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.InvoicesCreate), HttpPut("{id:guid}")]
    public async Task<IActionResult> Update(Guid id, InvoiceRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_invoice_update", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_data = Db.ToSnakeJson(req) }, ct));

    [RequirePermission(Permissions.InvoicesReconcile), HttpPost("{id:guid}/rematch")]
    public async Task<IActionResult> Rematch(Guid id, CancellationToken ct) => Ok(await db.JsonAsync("fn_invoice_rematch", Ctx(id), ct));

    [RequirePermission(Permissions.InvoicesReconcile), HttpPost("{id:guid}/discrepancies")]
    public async Task<IActionResult> Dispute(Guid id, CommentRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_invoice_dispute", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_message = req.Comment }, ct));

    [RequirePermission(Permissions.InvoicesReconcile), HttpPost("{id:guid}/reconcile")]
    public async Task<IActionResult> Reconcile(Guid id, CommentRequest? req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_invoice_reconcile", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_comment = req?.Comment }, ct));

    [RequirePermission(Permissions.InvoicesCreate), HttpPost("{id:guid}/cancel")]
    public async Task<IActionResult> Cancel(Guid id, CommentRequest req, CancellationToken ct) =>
        Ok(await db.JsonAsync("fn_invoice_cancel", new { p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_id = id, p_comment = req.Comment }, ct));
}

[ApiController]
[Route("api/v1/payments")]
public class PaymentsController(IDb db, ICurrentUser me) : ControllerBase
{
    [RequirePermission(Permissions.PaymentsView), HttpGet]
    public async Task<IActionResult> List([FromQuery] Guid? invoiceId, [FromQuery] Guid? vendorId, [FromQuery] string? search,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 20, CancellationToken ct = default) =>
        Ok(await db.JsonAsync("fn_payment_list", new
        {
            p_tenant_id = me.TenantId, p_invoice_id = invoiceId, p_vendor_id = vendorId, p_search = search, p_page = page, p_page_size = pageSize
        }, ct));

    [RequirePermission(Permissions.PaymentsView), HttpGet("summary")]
    public async Task<IActionResult> Summary(CancellationToken ct) => Ok(await db.JsonAsync("fn_payment_summary", new { p_tenant_id = me.TenantId }, ct));

    /// <summary>
    /// Records a payment (no real bank transfer happens). The Idempotency-Key header is required: sending the same key again
    /// returns the original payment instead of posting twice.
    /// </summary>
    [RequirePermission(Permissions.PaymentsRecord), HttpPost]
    public async Task<IActionResult> Record(PaymentRequest req, [FromHeader(Name = "Idempotency-Key")] string? key, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(key) || key.Length > 100)
            return BadRequest(ApiError.Body(400, "Idempotency key required", "Send a unique Idempotency-Key header (max 100 characters)."));
        var result = await db.CallAsync("sp_payment_record", new
        {
            p_tenant_id = me.TenantId, p_actor_id = me.UserId, p_invoice_id = req.InvoiceId, p_amount = req.Amount, p_method = req.Method,
            p_reference = req.Reference, p_paid_on = req.PaidOn, p_idempotency_key = key, p_notes = req.Notes
        }, ct);
        return result!["replayed"]!.GetValue<bool>() ? Ok(result) : StatusCode(201, result);
    }
}
