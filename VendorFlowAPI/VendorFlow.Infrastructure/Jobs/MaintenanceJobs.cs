using Hangfire;
using Microsoft.Extensions.Logging;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.Infrastructure.Jobs;

/// <summary>
/// Hangfire job bodies. The real work is done by PostgreSQL functions (fn_job_*), which are idempotent through dedupe keys,
/// so a retried or doubled run never creates duplicate notifications.
/// </summary>
public class MaintenanceJobs(IDb db, IEmailSender mail, ILogger<MaintenanceJobs> log)
{
    /// <summary>Document expiry, invoice due, delivery due, RFQ deadlines and approval reminders for all tenants.</summary>
    [AutomaticRetry(Attempts = 3, DelaysInSeconds = [60, 300, 900])]
    public async Task RunChecksAsync()
    {
        var result = await db.JsonAsync("fn_job_run_all", new { p_tenant_id = (Guid?)null });
        log.LogInformation("Background checks created notifications: {Result}", result?.ToJsonString());
    }

    /// <summary>Sends queued e-mails. Does nothing while SMTP is not configured; failures are stored and retried (max 5 attempts).</summary>
    [AutomaticRetry(Attempts = 2)]
    public async Task DispatchEmailsAsync()
    {
        if (!mail.IsConfigured) return;
        var batch = await db.JsonAsync("fn_email_outbox_claim", new { p_limit = 50 });
        foreach (var item in batch!.AsArray())
        {
            var id = Guid.Parse(item!["id"]!.GetValue<string>());
            try
            {
                await mail.SendAsync(item["toEmail"]!.GetValue<string>(), item["subject"]!.GetValue<string>(), item["body"]!.GetValue<string>(), CancellationToken.None);
                await db.ExecuteAsync("sp_email_outbox_result", new { p_id = id, p_success = true, p_error = (string?)null });
            }
            catch (Exception ex)
            {
                log.LogWarning("E-mail {Id} failed: {Message}", id, ex.Message);
                await db.ExecuteAsync("sp_email_outbox_result", new { p_id = id, p_success = false, p_error = ex.Message });
            }
        }
    }
}
