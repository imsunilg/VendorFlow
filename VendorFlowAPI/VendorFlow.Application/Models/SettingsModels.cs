using FluentValidation;

namespace VendorFlow.Application.Models;

/// <summary>Every field is optional; only the fields sent are changed.</summary>
public record UpdateSettingsRequest(
    string? AppDisplayName,
    string? OrganizationName,
    string? VendorLabelSingular,
    string? VendorLabelPlural,
    string? Currency,
    string? TimeZone,
    decimal? InvoiceTolerancePct,
    bool? AllowSelfApproval,
    Dictionary<string, string>? Numbering,
    Dictionary<string, object>? TaxSettings,
    Dictionary<string, object>? NotificationPrefs,
    Dictionary<string, decimal>? PerformanceWeights);

public class UpdateSettingsRequestValidator : AbstractValidator<UpdateSettingsRequest>
{
    public UpdateSettingsRequestValidator()
    {
        RuleFor(x => x.AppDisplayName).Must(Label).When(x => x.AppDisplayName is not null).WithMessage("Use 1 to 50 characters, no HTML.");
        RuleFor(x => x.VendorLabelSingular).Must(Label).When(x => x.VendorLabelSingular is not null).WithMessage("Use 1 to 50 characters, no HTML.");
        RuleFor(x => x.VendorLabelPlural).Must(Label).When(x => x.VendorLabelPlural is not null).WithMessage("Use 1 to 50 characters, no HTML.");
        RuleFor(x => x.OrganizationName).Must(v => !string.IsNullOrWhiteSpace(v) && v.Trim().Length <= 100 && !v.Contains('<') && !v.Contains('>'))
            .When(x => x.OrganizationName is not null).WithMessage("Use 1 to 100 characters, no HTML.");
        RuleFor(x => x.Currency).Matches("^[A-Z]{3}$").When(x => x.Currency is not null).WithMessage("Use a 3-letter code such as INR.");
        RuleFor(x => x.InvoiceTolerancePct).InclusiveBetween(0, 100).When(x => x.InvoiceTolerancePct is not null);
    }

    private static bool Label(string? v) =>
        !string.IsNullOrWhiteSpace(v) && v.Trim().Length <= 50 && !v.Contains('<') && !v.Contains('>');
}
