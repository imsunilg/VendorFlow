using System.Security.Claims;
using System.Text.Json;
using FluentValidation;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Npgsql;
using VendorFlow.Application.Abstractions;

namespace VendorFlow.API.Infrastructure;

/// <summary>Reads the caller from the JWT. The tenant id comes only from the token.</summary>
public sealed class CurrentUser(IHttpContextAccessor accessor) : ICurrentUser
{
    private ClaimsPrincipal Principal => accessor.HttpContext?.User ?? new ClaimsPrincipal();
    public Guid TenantId => Guid.Parse(Principal.FindFirstValue("tid") ?? throw new UnauthorizedAccessException());
    public Guid UserId => Guid.Parse(Principal.FindFirstValue("sub") ?? throw new UnauthorizedAccessException());
    public string Email => Principal.FindFirstValue("email") ?? "";
    public Guid? VendorId => Guid.TryParse(Principal.FindFirstValue("vid"), out var v) ? v : null;
    public bool HasPermission(string permission) => Principal.Claims.Any(c => c.Type == "perm" && c.Value == permission);
}

/// <summary>Requires the signed-in user to hold a permission, e.g. [RequirePermission("vendors.view")].</summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = true)]
public sealed class RequirePermissionAttribute(string permission) : Attribute, IAuthorizationFilter
{
    public void OnAuthorization(AuthorizationFilterContext context)
    {
        var user = context.HttpContext.User;
        if (user.Identity?.IsAuthenticated != true)
        {
            context.Result = new UnauthorizedResult();
            return;
        }
        if (!user.Claims.Any(c => c.Type == "perm" && c.Value == permission))
            context.Result = new ObjectResult(ApiError.Body(403, "Forbidden", $"Missing permission {permission}."))
            { StatusCode = 403 };
    }
}

public static class ApiError
{
    public static object Body(int status, string title, string detail, IDictionary<string, string[]>? errors = null) =>
        new { type = $"https://httpstatuses.io/{status}", title, status, detail, errors };
}

/// <summary>Validates every action argument that has a FluentValidation validator.</summary>
public sealed class ValidationFilter(IServiceProvider services) : IAsyncActionFilter
{
    public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        foreach (var arg in context.ActionArguments.Values)
        {
            if (arg is null) continue;
            var validatorType = typeof(IValidator<>).MakeGenericType(arg.GetType());
            if (services.GetService(validatorType) is not IValidator validator) continue;

            var result = await validator.ValidateAsync(new ValidationContext<object>(arg));
            if (result.IsValid) continue;

            var errors = result.Errors.GroupBy(e => e.PropertyName)
                .ToDictionary(g => g.Key, g => g.Select(e => e.ErrorMessage).ToArray());
            context.Result = new BadRequestObjectResult(ApiError.Body(400, "Validation failed", "One or more fields are invalid.", errors));
            return;
        }
        await next();
    }
}

/// <summary>Turns exceptions into the standard error JSON { type, title, status, detail, errors }.</summary>
public sealed class ExceptionMiddleware(RequestDelegate next, ILogger<ExceptionMiddleware> log)
{
    public async Task Invoke(HttpContext ctx)
    {
        try { await next(ctx); }
        catch (Exception ex)
        {
            var (status, title) = Map(ex);
            if (status >= 500) log.LogError(ex, "Unhandled error on {Path}", ctx.Request.Path);
            if (ctx.Response.HasStarted) throw;
            ctx.Response.Clear();
            ctx.Response.StatusCode = status;
            ctx.Response.ContentType = "application/json";
            var detail = status >= 500 ? "An unexpected error occurred." : ex is PostgresException pg ? pg.MessageText : ex.Message;
            await ctx.Response.WriteAsync(JsonSerializer.Serialize(ApiError.Body(status, title, detail),
                new JsonSerializerOptions(JsonSerializerDefaults.Web)));
        }
    }

    private static (int, string) Map(Exception ex) => ex switch
    {
        PostgresException { SqlState: "VF400" } => (400, "Bad request"),
        PostgresException { SqlState: "VF403" } => (403, "Forbidden"),
        PostgresException { SqlState: "VF404" } => (404, "Not found"),
        PostgresException { SqlState: "VF409" } => (409, "Conflict"),
        PostgresException { SqlState: "23505" } => (409, "Duplicate value"),
        PostgresException { SqlState: "23514" or "22P02" or "22023" or "23502" } => (400, "Invalid data"),
        UnauthorizedAccessException => (401, "Unauthorized"),
        ArgumentException => (400, "Bad request"),
        _ => (500, "Server error")
    };
}
