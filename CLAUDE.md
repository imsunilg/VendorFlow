# VendorFlow – instructions for Claude

Multi-tenant procurement platform. One repo: `VendorFlowAPI` (.NET), `VendorFlowWEB` (Angular), `VendorFlowMOBILE` (Flutter), `VendorFlowDB` (SQL scripts), `VendorFlowDocs`.

## Rules
- **All database access goes through PostgreSQL functions/procedures** (schema `vendorflow`, scripts in `VendorFlowDB/`). No inline SQL in C# except the single `select/call fn_*` statement. See `ARCHITECTURE_DECISIONS.md`.
- The SQL scripts are the only schema authority; the API creates database `Vendor_db` and applies scripts on startup (`DatabaseInitializer`). Scripts in `02_Tables` are run once (tracked in `schema_migrations`); `05_Functions` and `08_SeedData` are idempotent and re-applied.
- Every tenant-owned function takes `p_tenant_id` and filters by it. Tenant comes from the JWT claim only.
- Never commit `appsettings.Development.json`, secrets, or the dev DB password. Use `scripts/Save-Phase.ps1` for local commits. Never push unless asked.
- Angular: each component is 3 files (`.html/.ts/.css`), simple readable code, labels through `SettingsService` (vendor terminology is configurable).
- Money `numeric(18,2)`, rounding half-up per line then total, UTC timestamps.
- Progress tracker: `VendorFlowDocs/Development/DEVELOPMENT_PROGRESS.md`.

## Commands
- API: `dotnet run --project VendorFlowAPI/VendorFlow.API` (Swagger at /swagger)
- Tests: `dotnet test VendorFlowAPI`
- Web: `cd VendorFlowWEB; npm start` / `npm run build`
- Mobile: `cd VendorFlowMOBILE; flutter analyze; flutter test`
