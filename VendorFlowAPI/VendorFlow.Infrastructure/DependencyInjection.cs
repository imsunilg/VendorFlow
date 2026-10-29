using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using VendorFlow.Application.Abstractions;
using VendorFlow.Infrastructure.Persistence;
using VendorFlow.Infrastructure.Security;

namespace VendorFlow.Infrastructure;

public static class DependencyInjection
{
    /// <summary>Registers database access, security and file/e-mail services.</summary>
    public static IServiceCollection AddInfrastructure(this IServiceCollection services, IConfiguration config)
    {
        // Resolved lazily so test/host configuration overrides apply.
        services.AddSingleton(sp => NpgsqlDataSource.Create(sp.GetRequiredService<IConfiguration>().GetConnectionString("VendorFlow")
            ?? throw new InvalidOperationException("ConnectionStrings:VendorFlow is not configured.")));
        services.AddSingleton<IDb, Db>();
        services.AddSingleton<DatabaseInitializer>();
        services.AddSingleton<IPasswordService, PasswordService>();
        services.AddSingleton<ITokenService, TokenService>();
        services.AddSingleton<IFileStorage, LocalFileStorage>();
        services.AddSingleton<IEmailSender, SmtpEmailSender>();
        return services;
    }
}
