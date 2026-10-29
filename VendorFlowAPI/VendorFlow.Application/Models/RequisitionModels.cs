using FluentValidation;

namespace VendorFlow.Application.Models;

public record RequisitionItemRequest(string Description, string? Unit, decimal Quantity, decimal EstUnitPrice);

public record RequisitionRequest(
    string Title, Guid? DepartmentId, Guid? CostCentreId, DateOnly? RequiredDate, string? Justification,
    string? Priority, int? RowVersion, List<RequisitionItemRequest>? Items);

/// <summary>Used by approve / reject / request-changes. ExpectedVersion protects against double clicks.</summary>
public record DecisionRequest(string? Comment, int? ExpectedVersion);

public record ApprovalRuleStepRequest(string? Name, string RoleCode);
public record ApprovalRuleRequest(Guid? Id, string Name, string EntityType, decimal? MinAmount, decimal? MaxAmount,
    Guid? DepartmentId, int? Priority, bool? Active, List<ApprovalRuleStepRequest> Steps);
public record DelegationRequest(Guid ToUserId, DateOnly StartDate, DateOnly EndDate, string? Reason);
public record SetManagerRequest(Guid? UserId);

public class RequisitionRequestValidator : AbstractValidator<RequisitionRequest>
{
    public RequisitionRequestValidator()
    {
        RuleFor(x => x.Title).NotEmpty().MaximumLength(200);
        RuleFor(x => x.Priority).Must(p => p is "Low" or "Medium" or "High").When(x => x.Priority is not null);
        RuleForEach(x => x.Items).ChildRules(i =>
        {
            i.RuleFor(x => x.Description).NotEmpty().MaximumLength(300);
            i.RuleFor(x => x.Quantity).GreaterThan(0);
            i.RuleFor(x => x.EstUnitPrice).GreaterThanOrEqualTo(0);
        });
    }
}

public class ApprovalRuleRequestValidator : AbstractValidator<ApprovalRuleRequest>
{
    public ApprovalRuleRequestValidator()
    {
        RuleFor(x => x.Name).NotEmpty().MaximumLength(100);
        RuleFor(x => x.EntityType).Must(t => t is "requisition" or "purchase_order");
        RuleFor(x => x.Steps).NotEmpty().WithMessage("Add at least one approval step.");
        RuleFor(x => x.MinAmount).GreaterThanOrEqualTo(0).When(x => x.MinAmount is not null);
    }
}

public class DelegationRequestValidator : AbstractValidator<DelegationRequest>
{
    public DelegationRequestValidator() =>
        RuleFor(x => x.EndDate).GreaterThanOrEqualTo(x => x.StartDate).WithMessage("End date must be on or after the start date.");
}
