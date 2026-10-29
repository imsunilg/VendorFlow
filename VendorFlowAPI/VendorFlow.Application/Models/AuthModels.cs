using FluentValidation;

namespace VendorFlow.Application.Models;

public record LoginRequest(string Email, string Password);
public record RefreshRequest(string RefreshToken);
public record RegisterOrganizationRequest(string OrganizationName, string FullName, string Email, string Password);
public record ForgotPasswordRequest(string Email);
public record ResetPasswordRequest(string Token, string NewPassword);

public class LoginRequestValidator : AbstractValidator<LoginRequest>
{
    public LoginRequestValidator()
    {
        RuleFor(x => x.Email).NotEmpty().EmailAddress();
        RuleFor(x => x.Password).NotEmpty();
    }
}

public class RegisterOrganizationRequestValidator : AbstractValidator<RegisterOrganizationRequest>
{
    public RegisterOrganizationRequestValidator()
    {
        RuleFor(x => x.OrganizationName).NotEmpty().MaximumLength(100);
        RuleFor(x => x.FullName).NotEmpty().MaximumLength(100);
        RuleFor(x => x.Email).NotEmpty().EmailAddress();
        RuleFor(x => x.Password).PasswordRules();
    }
}

public class ResetPasswordRequestValidator : AbstractValidator<ResetPasswordRequest>
{
    public ResetPasswordRequestValidator()
    {
        RuleFor(x => x.Token).NotEmpty();
        RuleFor(x => x.NewPassword).PasswordRules();
    }
}

public static class ValidationExtensions
{
    /// <summary>Password policy: at least 8 chars with upper, lower and a digit.</summary>
    public static IRuleBuilderOptions<T, string> PasswordRules<T>(this IRuleBuilder<T, string> rule) =>
        rule.NotEmpty().MinimumLength(8).MaximumLength(100)
            .Matches("[A-Z]").WithMessage("Password needs an uppercase letter.")
            .Matches("[a-z]").WithMessage("Password needs a lowercase letter.")
            .Matches("[0-9]").WithMessage("Password needs a digit.");
}
