using FluentValidation;

namespace VendorFlow.Application.Models;

public record GrnItemRequest(Guid PoItemId, decimal ReceivedQty, decimal AcceptedQty, decimal RejectedQty, decimal? DamagedQty);

public record GrnRequest(DateOnly? ReceivedOn, string? Warehouse, string? DeliveryChallan, string? VehicleNo, string? ReceivedBy,
    string? InspectionNotes, List<GrnItemRequest> Items);

public class GrnRequestValidator : AbstractValidator<GrnRequest>
{
    public GrnRequestValidator()
    {
        RuleFor(x => x.Items).NotEmpty().WithMessage("Enter the received quantities.");
        RuleForEach(x => x.Items).ChildRules(i =>
        {
            i.RuleFor(x => x.ReceivedQty).GreaterThanOrEqualTo(0);
            i.RuleFor(x => x.AcceptedQty).GreaterThanOrEqualTo(0);
            i.RuleFor(x => x.RejectedQty).GreaterThanOrEqualTo(0);
            i.RuleFor(x => x.DamagedQty).GreaterThanOrEqualTo(0).When(x => x.DamagedQty is not null);
            i.RuleFor(x => x).Must(x => x.AcceptedQty + x.RejectedQty == x.ReceivedQty)
                .WithMessage("Accepted + rejected must equal received.");
            i.RuleFor(x => x).Must(x => (x.DamagedQty ?? 0) <= x.RejectedQty).WithMessage("Damaged cannot exceed rejected.");
        });
    }
}
