using FluentValidation;
using Microsoft.AspNetCore.Http;

namespace VendorFlow.Application.Models;

/// <summary>Used for create (name required) and update (only sent fields change).</summary>
public record VendorRequest(
    string? Name, string? LegalName, string? Category, string? ProductsServices, string? Risk, decimal? Rating,
    string? Gstin, string? Pan, string? MsmeNumber, int? PaymentTermsDays, string? Currency,
    string? Email, string? Phone, string? City, string? State, int? RowVersion);

public record VendorContactRequest(Guid? Id, string Name, string? Designation, string? Email, string? Phone, bool? IsPrimary);
public record VendorAddressRequest(Guid? Id, string? AddressType, string Line1, string? Line2, string? City, string? State, string? PostalCode, string? Country);
public record CommentRequest(string? Comment);
public record VendorBankRequest(string AccountName, string AccountNumber, string Ifsc, string? BankName, string? Branch);

/// <summary>Multipart form for a vendor document (the file is optional).</summary>
public class VendorDocumentForm
{
    public Guid? Id { get; set; }
    public string DocType { get; set; } = "";
    public string? DocNumber { get; set; }
    public DateOnly? ExpiryDate { get; set; }
    public IFormFile? File { get; set; }
}

public class VendorRequestValidator : AbstractValidator<VendorRequest>
{
    public VendorRequestValidator()
    {
        RuleFor(x => x.Name).MaximumLength(150).When(x => x.Name is not null);
        RuleFor(x => x.Email).EmailAddress().When(x => !string.IsNullOrEmpty(x.Email));
        RuleFor(x => x.Gstin).Matches("^[0-9]{2}[A-Za-z]{5}[0-9]{4}[A-Za-z][1-9A-Za-z]Z[0-9A-Za-z]$").When(x => !string.IsNullOrEmpty(x.Gstin)).WithMessage("GSTIN format is invalid.");
        RuleFor(x => x.Pan).Matches("^[A-Za-z]{5}[0-9]{4}[A-Za-z]$").When(x => !string.IsNullOrEmpty(x.Pan)).WithMessage("PAN format is invalid.");
        RuleFor(x => x.Risk).Must(r => r is "Low" or "Medium" or "High").When(x => x.Risk is not null);
        RuleFor(x => x.Rating).InclusiveBetween(0, 5).When(x => x.Rating is not null);
        RuleFor(x => x.PaymentTermsDays).InclusiveBetween(0, 365).When(x => x.PaymentTermsDays is not null);
    }
}

public class VendorContactRequestValidator : AbstractValidator<VendorContactRequest>
{
    public VendorContactRequestValidator()
    {
        RuleFor(x => x.Name).NotEmpty().MaximumLength(100);
        RuleFor(x => x.Email).EmailAddress().When(x => !string.IsNullOrEmpty(x.Email));
    }
}

public class VendorAddressRequestValidator : AbstractValidator<VendorAddressRequest>
{
    public VendorAddressRequestValidator() => RuleFor(x => x.Line1).NotEmpty().MaximumLength(200);
}

public class VendorBankRequestValidator : AbstractValidator<VendorBankRequest>
{
    public VendorBankRequestValidator()
    {
        RuleFor(x => x.AccountName).NotEmpty().MaximumLength(150);
        RuleFor(x => x.AccountNumber).Matches("^[0-9]{6,20}$").WithMessage("Account number must be 6 to 20 digits.");
        RuleFor(x => x.Ifsc).Matches("^[A-Za-z]{4}0[A-Za-z0-9]{6}$").WithMessage("IFSC code is invalid.");
    }
}
