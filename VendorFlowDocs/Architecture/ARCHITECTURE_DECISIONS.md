# Architecture decisions

| # | Decision | Why |
|---|---|---|
| 1 | **Data access = PostgreSQL functions and procedures only** (requested by the owner). C# calls `select * from vendorflow.fn_*(...)` / `call vendorflow.sp_*(...)` through Dapper. No ad-hoc inline SQL, no EF Core LINQ queries. | Business rules and tenant filtering live next to the data; one audited call per use case. |
| 2 | **EF Core migrations are replaced by versioned SQL scripts** in `VendorFlowDB/`, applied by `DatabaseInitializer` at API start (creates `Vendor_db` if missing, then the `vendorflow` schema). Tables run once (tracked in `vendorflow.schema_migrations` with checksum); functions/seed scripts are `CREATE OR REPLACE`/idempotent and re-applied. | Owner asked for automatic DB + schema creation and function-based access; EF migrations would conflict. |
| 3 | Dapper + Npgsql in Infrastructure. Functions return `jsonb` (single object, or `{items,totalCount,page,pageSize}` for lists); keys are snake_case in SQL and converted to camelCase by one helper. Request payloads are validated by FluentValidation in the Application layer and passed to functions as `jsonb`. | Keeps C# thin; JSON shape is the DTO; entities are never exposed. |
| 4 | **Tenant isolation:** every tenant-owned function takes `p_tenant_id` (from the JWT claim) and filters on it; all unique constraints are `(tenant_id, …)`. | EF global filters do not exist without EF. Verified with cross-tenant negative tests. |
| 5 | Errors raised in SQL use custom SQLSTATEs (`VF400` validation, `VF403`, `VF404`, `VF409` conflict) mapped to HTTP status by the exception middleware as `{type,title,status,detail,errors}`. | Single place for rule violations. |
| 6 | Identity: `Microsoft.AspNetCore.Identity.PasswordHasher` for hashing only; users/roles/permissions are our own tables. JWT access token (15 min) + rotating refresh token (stored as SHA-256 hash). | No EF Identity store is needed. |
| 7 | Permissions are rows in `permissions`/`role_permissions` and are copied into the JWT as `perm` claims; controllers use `[RequirePermission("x")]`. | Simple and testable. |
| 8 | Rounding: `numeric(18,2)`, `round(x,2)` (half away from zero = half-up for positive money) per line, then totals are sums of rounded lines. | Documented rule from the spec. |
| 9 | Hangfire (PostgreSQL storage, schema `hangfire`) for notification/expiry jobs; job bodies call SQL functions. | Retry + dashboard. |
| 10 | PO PDF via QuestPDF (Community licence). | Pure .NET, no native deps. |
| 11 | Angular standalone components, 3 files each, Angular Material, `SettingsService` with `BehaviorSubject` for labels. | Beginner-readable code requested. |
| 12 | Docker is not installed on the dev machine: Docker files are written but **not executed**; documented as unverified. | Honest reporting. |
| 13 | Test database `Vendor_db_test` is created automatically by the same initializer and reset per test run. | Safe integration tests that never touch dev data. |
