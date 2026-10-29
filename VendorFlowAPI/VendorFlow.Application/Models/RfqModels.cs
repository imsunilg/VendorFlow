using FluentValidation;

namespace VendorFlow.Application.Models;

public record RfqItemRequest(string Description, string? Unit, decimal Quantity);

public record RfqRequest(string? Title, Guid? RequisitionId, string? Description, DateTimeOffset? Deadline,
    List<RfqItemRequest>? Items, List<Guid>? VendorIds);

public record ReopenRequest(DateTimeOffset Deadline);
public record QuestionRequest(string Question);
public record AnswerRequest(string Answer);

public record QuotationItemRequest(Guid RfqItemId, decimal UnitPrice, decimal? DiscountPercent, decimal? TaxPercent);

public record QuotationRequest(decimal? Shipping, int? DeliveryDays, string? PaymentTerms, int? WarrantyMonths, string? Notes,
    List<QuotationItemRequest> Items);

public record RecommendationRequest(Guid VendorId, string Justification);

public class RfqRequestValidator : AbstractValidator<RfqRequest>
{
    public RfqRequestValidator()
    {
        RuleFor(x => x.Title).MaximumLength(200);
        RuleForEach(x => x.Items).ChildRules(i =>
        {
            i.RuleFor(x => x.Description).NotEmpty().MaximumLength(300);
            i.RuleFor(x => x.Quantity).GreaterThan(0);
        });
    }
}

public class QuotationRequestValidator : AbstractValidator<QuotationRequest>
{
    public QuotationRequestValidator()
    {
        RuleFor(x => x.Shipping).GreaterThanOrEqualTo(0).When(x => x.Shipping is not null);
        RuleFor(x => x.DeliveryDays).GreaterThanOrEqualTo(0).When(x => x.DeliveryDays is not null);
        RuleFor(x => x.WarrantyMonths).GreaterThanOrEqualTo(0).When(x => x.WarrantyMonths is not null);
        RuleFor(x => x.Items).NotEmpty();
        RuleForEach(x => x.Items).ChildRules(i =>
        {
            i.RuleFor(x => x.UnitPrice).GreaterThanOrEqualTo(0);
            i.RuleFor(x => x.DiscountPercent).InclusiveBetween(0, 100).When(x => x.DiscountPercent is not null);
            i.RuleFor(x => x.TaxPercent).InclusiveBetween(0, 100).When(x => x.TaxPercent is not null);
        });
    }
}

public class QuestionRequestValidator : AbstractValidator<QuestionRequest>
{
    public QuestionRequestValidator() => RuleFor(x => x.Question).NotEmpty().MaximumLength(1000);
}

public class RecommendationRequestValidator : AbstractValidator<RecommendationRequest>
{
    public RecommendationRequestValidator() =>
        RuleFor(x => x.Justification).NotEmpty().MinimumLength(10).WithMessage("Explain the recommendation in at least 10 characters.");
}
