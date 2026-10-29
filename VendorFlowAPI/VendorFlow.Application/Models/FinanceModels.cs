using FluentValidation;

namespace VendorFlow.Application.Models;

public record InvoiceItemRequest(Guid PoItemId, decimal Quantity, decimal? Rate, decimal? DiscountPercent, decimal? TaxAmount);

public record InvoiceRequest(Guid? PoId, string? InvoiceNumber, DateOnly? InvoiceDate, DateOnly? DueDate, string? MatchType,
    string? Notes, int? RowVersion, List<InvoiceItemRequest>? Items);

public record PaymentRequest(Guid InvoiceId, decimal Amount, string Method, string? Reference, DateOnly? PaidOn, string? Notes);

public class InvoiceRequestValidator : AbstractValidator<InvoiceRequest>
{
    public InvoiceRequestValidator()
    {
        RuleFor(x => x.InvoiceNumber).MaximumLength(60);
        RuleFor(x => x.MatchType).Must(m => m is "TwoWay" or "ThreeWay").When(x => x.MatchType is not null);
        RuleForEach(x => x.Items).ChildRules(i =>
        {
            i.RuleFor(x => x.Quantity).GreaterThan(0);
            i.RuleFor(x => x.Rate).GreaterThanOrEqualTo(0).When(x => x.Rate is not null);
            i.RuleFor(x => x.DiscountPercent).InclusiveBetween(0, 100).When(x => x.DiscountPercent is not null);
            i.RuleFor(x => x.TaxAmount).GreaterThanOrEqualTo(0).When(x => x.TaxAmount is not null);
        });
    }
}

public class PaymentRequestValidator : AbstractValidator<PaymentRequest>
{
    public PaymentRequestValidator()
    {
        RuleFor(x => x.Amount).GreaterThan(0).PrecisionScale(18, 2, false).WithMessage("Amount must be positive with at most 2 decimals.");
        RuleFor(x => x.Method).Must(m => m is "NEFT" or "RTGS" or "UPI" or "IMPS" or "Cheque" or "Cash" or "Other");
        RuleFor(x => x.Reference).MaximumLength(100);
    }
}
