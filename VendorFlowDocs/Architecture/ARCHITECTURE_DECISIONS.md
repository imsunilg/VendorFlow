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
| 14 | **Dapper is not used.** Plain Npgsql runs the single function/procedure call; JSON results are camel-cased by `Db`. | Every statement is `select fn_…` / `call sp_…`, so a mapper adds nothing. |
| 15 | **Vendors quote through secret RFQ links** (random token, only its SHA-256 stored, rate limited, generic 404 on any failure). A `VendorPortalUser` role exists but no vendor login is implemented. | Simplest secure way to give each vendor access to exactly one RFQ; the spec allowed "tokenised link or vendor-portal user". |
| 16 | Issued POs are immutable **twice**: in the function layer (draft-only edits, revisions) and by database triggers on `purchase_orders` / `po_items`. | Defence in depth: a bug or manual SQL cannot silently change an issued order. |
| 17 | Payments use an **idempotency key** (header) with the invoice row locked first, so parallel requests with one key post once and different keys cannot overpay. | Verified by parallel-request tests. |
| 18 | Angular 22 makes `OnPush` the default; the app opts every component into `ChangeDetectionStrategy.Eager` (+ zone.js) to keep the code plain-property and beginner friendly. | Without it HTTP results did not re-render (found by the browser smoke test). |
| 19 | Receipts count **accepted** quantity on the PO line; rejected goods can be redelivered. Invoice matching compares against accepted quantity minus quantity already invoiced; tolerance applies to the total, quantity/rate/discount/tax mismatches are always mandatory. | Matches how receiving and 3-way match work in practice; documented in `060_invoices.sql`. |
| 20 | Vendor performance is **computed from real data only**; metrics without data are excluded and weights re-normalised (no score at all when nothing exists). | "No fake production data". |
| 21 | Postgres rule learned the hard way: `CALL` arguments cannot contain subqueries; functions use variables first. | Recorded in `CLAUDE.md`. |
