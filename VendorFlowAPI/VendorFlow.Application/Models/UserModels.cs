using FluentValidation;

namespace VendorFlow.Application.Models;

public record InviteUserRequest(string Email, string FullName, string[] Roles);
public record SetRolesRequest(string[] Roles);
public record SetStatusRequest(string Status);

public class InviteUserRequestValidator : AbstractValidator<InviteUserRequest>
{
    public InviteUserRequestValidator()
    {
        RuleFor(x => x.Email).NotEmpty().EmailAddress();
        RuleFor(x => x.FullName).NotEmpty().MaximumLength(100);
        RuleFor(x => x.Roles).NotEmpty().WithMessage("Choose at least one role.");
    }
}

public class SetRolesRequestValidator : AbstractValidator<SetRolesRequest>
{
    public SetRolesRequestValidator() => RuleFor(x => x.Roles).NotEmpty().WithMessage("Choose at least one role.");
}
