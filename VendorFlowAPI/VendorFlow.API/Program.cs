using System.Text;
using System.Threading.RateLimiting;
using FluentValidation;
using Hangfire;
using Hangfire.PostgreSql;
using VendorFlow.Infrastructure.Jobs;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using Serilog;
using VendorFlow.API.Infrastructure;
using VendorFlow.Application.Abstractions;
using VendorFlow.Application.Models;
using VendorFlow.Infrastructure;
using VendorFlow.Infrastructure.Persistence;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseSerilog((ctx, cfg) => cfg
    .ReadFrom.Configuration(ctx.Configuration)
    .Enrich.FromLogContext()
    .WriteTo.Console()
    .WriteTo.File("logs/vendorflow-.log", rollingInterval: RollingInterval.Day));

builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<ICurrentUser, CurrentUser>();
builder.Services.AddInfrastructure(builder.Configuration);
builder.Services.AddValidatorsFromAssemblyContaining<LoginRequestValidator>();
builder.Services.AddControllers(o => o.Filters.Add<ValidationFilter>());
builder.Services.Configure<Microsoft.AspNetCore.Mvc.ApiBehaviorOptions>(o => o.SuppressModelStateInvalidFilter = true);

// JWT bearer authentication. Claims keep their short names (sub, tid, perm ...).
var jwtSecret = builder.Configuration["Jwt:Secret"] ?? throw new InvalidOperationException("Jwt:Secret is not configured.");
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(o =>
{
    o.MapInboundClaims = false;
    o.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true, ValidIssuer = builder.Configuration["Jwt:Issuer"],
        ValidateAudience = true, ValidAudience = builder.Configuration["Jwt:Audience"],
        ValidateIssuerSigningKey = true, IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtSecret)),
        ValidateLifetime = true, ClockSkew = TimeSpan.FromSeconds(30),
        NameClaimType = "name", RoleClaimType = "role"
    };
});
builder.Services.AddAuthorization();

// Login and token endpoints are rate limited per client address.
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = 429;
    o.AddPolicy("auth", http => RateLimitPartition.GetFixedWindowLimiter(
        http.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = builder.Configuration.GetValue("RateLimit:AuthPerMinute", 20),
            Window = TimeSpan.FromMinutes(1)
        }));
});

builder.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .WithOrigins((builder.Configuration["Cors:Origins"] ?? "http://localhost:4200").Split(',', StringSplitOptions.RemoveEmptyEntries))
    .AllowAnyHeader().AllowAnyMethod()));

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo { Title = "VendorFlow API", Version = "v1" });
    c.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.Http, Scheme = "bearer", BearerFormat = "JWT", In = ParameterLocation.Header
    });
    c.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        { new OpenApiSecurityScheme { Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "Bearer" } }, [] }
    });
});

builder.Services.AddHealthChecks().AddCheck<DatabaseHealthCheck>("database");

// Background jobs (Hangfire with PostgreSQL storage). Disabled with Jobs:Enabled = false (used by the tests).
var jobsEnabled = builder.Configuration.GetValue("Jobs:Enabled", true);
builder.Services.AddScoped<MaintenanceJobs>();
if (jobsEnabled)
{
    builder.Services.AddHangfire(c => c
        .SetDataCompatibilityLevel(CompatibilityLevel.Version_180)
        .UseSimpleAssemblyNameTypeSerializer()
        .UseRecommendedSerializerSettings()
        .UsePostgreSqlStorage(o => o.UseNpgsqlConnection(builder.Configuration.GetConnectionString("VendorFlow")!)));
    builder.Services.AddHangfireServer();
}

var app = builder.Build();

// Create the database + schema automatically (Database:AutoMigrate = false disables it).
if (app.Configuration.GetValue("Database:AutoMigrate", true))
{
    var cs = app.Configuration.GetConnectionString("VendorFlow")!;
    await app.Services.GetRequiredService<DatabaseInitializer>()
        .InitializeAsync(cs, app.Configuration.GetValue("Database:ResetTestDb", false));
}

// Development demo data (Demo Company with sample documents); never runs outside Development.
if (app.Environment.IsDevelopment() && app.Configuration.GetValue("Seed:DemoData", false) && app.Configuration.GetValue("Database:AutoMigrate", true))
{
    using var scope = app.Services.CreateScope();
    await new DemoSeeder(scope.ServiceProvider.GetRequiredService<IDb>(), scope.ServiceProvider.GetRequiredService<IPasswordService>(),
        scope.ServiceProvider.GetRequiredService<ITokenService>(), scope.ServiceProvider.GetRequiredService<ILogger<DemoSeeder>>())
        .SeedAsync(app.Configuration["Seed:DemoPassword"] ?? "Demo@12345");
}

app.UseMiddleware<ExceptionMiddleware>();
app.UseSerilogRequestLogging();
app.UseCors();
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
app.UseSwagger();
app.UseSwaggerUI();
app.MapControllers();
app.MapHealthChecks("/health");

if (jobsEnabled)
{
    // Hangfire dashboard: local requests only (default filter).
    app.UseHangfireDashboard("/hangfire");
    RecurringJob.AddOrUpdate<MaintenanceJobs>("daily-checks", j => j.RunChecksAsync(), "0 6 * * *");
    RecurringJob.AddOrUpdate<MaintenanceJobs>("hourly-deadline-checks", j => j.RunChecksAsync(), Cron.Hourly());
    RecurringJob.AddOrUpdate<MaintenanceJobs>("email-dispatch", j => j.DispatchEmailsAsync(), "*/5 * * * *");
}

app.Run();

/// <summary>Health check that runs the fn_health() function.</summary>
public sealed class DatabaseHealthCheck(IDb db) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken ct = default)
    {
        try
        {
            return await db.ScalarAsync<bool>("fn_health", null, ct) ? HealthCheckResult.Healthy() : HealthCheckResult.Unhealthy();
        }
        catch (Exception ex) { return HealthCheckResult.Unhealthy("Database unreachable", ex); }
    }
}

public partial class Program;
