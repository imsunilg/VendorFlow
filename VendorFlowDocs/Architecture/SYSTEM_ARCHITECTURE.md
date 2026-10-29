# System architecture

```
Angular web ─┐                      ┌─ PostgreSQL  Vendor_db / schema vendorflow
Flutter app ─┼─ HTTPS/JSON ─ API ───┤   tables, fn_* functions, sp_* procedures
Vendor link ─┘   (JWT)              └─ Hangfire (schema hangfire)
```

## API layers (Clean Architecture)
- **Domain** – constants (roles, permissions, statuses), no dependencies.
- **Application** – interfaces (`IDb`, `ITenantContext`), request models, FluentValidation validators, service abstractions.
- **Infrastructure** – `Db` (Dapper/Npgsql), `DatabaseInitializer`, JWT/refresh token service, PDF, email, background jobs. Embeds `VendorFlowDB` scripts.
- **API** – thin controllers, middleware (exceptions, tenant), Swagger, health checks, Serilog.

## Request flow
Controller → validator → `IDb.Json("fn_x", params)` → PostgreSQL function (checks tenant, state, permissions of data) → jsonb → camelCase JSON response.

## Multi-tenancy
JWT contains `tenant_id`. `ITenantContext` reads it. Controllers pass it as the first argument of every function. Vendor-portal calls use a random RFQ token that resolves tenant + RFQ + vendor inside SQL.

## Security
Rate-limited login, hashed passwords, rotating refresh tokens, audit events, safe uploads (type/size whitelist, random key, tenant-scoped folder), bank details behind `vendors.bank.view` and audited.
