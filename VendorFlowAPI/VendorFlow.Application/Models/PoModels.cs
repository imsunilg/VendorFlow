using FluentValidation;

namespace VendorFlow.Application.Models;

public record PoItemRequest(Guid? Id, string Description, string? Unit, decimal Quantity, decimal Rate, decimal? DiscountPercent, decimal? TaxPercent);

public record PoRequest(Guid? VendorId, DateOnly? OrderDate, DateOnly? ExpectedDelivery, string? Notes, decimal? Shipping,
    int? RowVersion, List<PoItemRequest>? Items);

/// <summary>Convert an approved requisition: choose the vendor (rates come from the requisition).</summary>
public record PoFromRequisitionRequest(Guid VendorId, DateOnly? ExpectedDelivery, decimal? Shipping, string? Notes);

public record PoFromRfqRequest(DateOnly? ExpectedDelivery, string? Notes);

public class PoRequestValidator : AbstractValidator<PoRequest>
{
    public PoRequestValidator()
    {
        RuleFor(x => x.Shipping).GreaterThanOrEqualTo(0).When(x => x.Shipping is not null);
        RuleForEach(x => x.Items).ChildRules(i =>
        {
            i.RuleFor(x => x.Description).NotEmpty().MaximumLength(300);
            i.RuleFor(x => x.Quantity).GreaterThan(0);
            i.RuleFor(x => x.Rate).GreaterThanOrEqualTo(0);
            i.RuleFor(x => x.DiscountPercent).InclusiveBetween(0, 100).When(x => x.DiscountPercent is not null);
            i.RuleFor(x => x.TaxPercent).InclusiveBetween(0, 100).When(x => x.TaxPercent is not null);
        });
    }
}
