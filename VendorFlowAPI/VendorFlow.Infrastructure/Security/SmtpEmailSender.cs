using System.Net;
using System.Net.Mail;
using Microsoft.Extensions.Configuration;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.Infrastructure.Security;

/// <summary>SMTP e-mail, switched off unless Smtp:Host is configured.</summary>
public sealed class SmtpEmailSender(IConfiguration config) : IEmailSender
{
    public bool IsConfigured => !string.IsNullOrWhiteSpace(config["Smtp:Host"]);

    public async Task SendAsync(string to, string subject, string body, CancellationToken ct)
    {
        if (!IsConfigured) throw new InvalidOperationException("SMTP is not configured.");
        using var client = new SmtpClient(config["Smtp:Host"], int.Parse(config["Smtp:Port"] ?? "587"))
        {
            EnableSsl = bool.Parse(config["Smtp:Ssl"] ?? "true"),
            Credentials = string.IsNullOrEmpty(config["Smtp:User"]) ? null
                : new NetworkCredential(config["Smtp:User"], config["Smtp:Password"])
        };
        using var msg = new MailMessage(config["Smtp:From"] ?? "noreply@vendorflow.local", to, subject, body);
        await client.SendMailAsync(msg, ct);
    }
}
