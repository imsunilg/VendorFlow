# VendorFlow – final report

## What was built
| Part | Result |
|---|---|
| Database | PostgreSQL `Vendor_db`, schema `vendorflow`: 47 tables, **151 functions/procedures**, triggers (PO immutability), seed of 13 roles / 32 permissions. Created **automatically** by the API on start. |
| API | .NET 9 Clean Architecture; every database access is a call to a function/procedure (`Db.JsonAsync("fn_…")`); ~150 endpoints; JWT + rotating refresh tokens; tenant isolation; Hangfire jobs; QuestPDF purchase-order PDF; optional SMTP. |
| Web | Angular 22 + Material; 45 components, each `.html/.ts/.css`; configurable app name and vendor terminology (live, no reload). |
| Mobile | Flutter 3.47 (Riverpod, GoRouter, Dio, secure storage): sign-in, home, approvals, requisitions, vendors, PO, receive goods (+photos), invoices & payments, notifications, profile. |
| Ops | Dockerfiles, docker-compose, GitHub Actions (API, web, mobile), deployment and backup guides. |

## Verified (actually run)
- `dotnet test`: **149/149** (integration tests against a real PostgreSQL test database): auth, lockout, refresh-token reuse, tenant isolation for every module, permissions, state-machine violations, rounding, duplicate invoice, over-receipt, overpayment, idempotent/parallel payments, concurrent approvals/receipts, PO immutability (also at DB level), jobs idempotency, reports, full procurement cycle.
- API started for real: database + schema + demo data created automatically; login, dashboard, vendors answered.
- Angular: production build, 14 unit tests, headless Chrome smoke test of all pages (real data, no console/HTTP errors) and of the live label rename (“Vendors” → “Suppliers”) and an approval click.
- Flutter: `flutter analyze` (no issues) and 15 tests (format helpers, labels, API client with token refresh, login widget).
- Static audit: no inline SQL in application code except `DatabaseInitializer` (CREATE DATABASE, advisory lock, script execution, migration bookkeeping) and `Db` (the function/procedure call); the DB password appears in no tracked file.

## Not verified / known limitations
1. **Docker/compose/CI YAML were not executed** (Docker not installed; workflows not run on GitHub).
2. **Mobile app was not run on an emulator or device**; `image_picker`, `url_launcher` and secure storage are untested at runtime. Android uses cleartext HTTP for development only.
3. SMTP sending was not tested against a real mail server (outbox, retries, 5-attempt rule are tested).
4. The PO PDF was generated and checked for validity/size, not visually reviewed.
5. AI document extraction is an abstraction only (disabled, returns 501); no provider is implemented.
6. “Vendor Portal User” exists as a role, but vendors quote through **secret RFQ links** (no vendor login). Documented decision.
7. EF Core and Dapper are **not used** (owner asked for functions/procedures); schema evolves through numbered SQL scripts.
8. Web tokens are in `localStorage` (convenient, exposed to XSS); a hardened deployment should add CSP headers.
9. Rate limiting is in-memory per instance; multi-instance deployments need a shared limiter.
10. Child-row tenant consistency is enforced by the functions (always reached through a tenant-checked parent), not by composite foreign keys.
11. No push notifications on mobile (pull-to-refresh only); no offline mode.
12. The web UI was smoke-tested automatically, not manually clicked through every flow; the dev database was modified by those tests (reset by dropping `Vendor_db`).
13. The full API test run takes about 4 minutes (password hashing and real database).

## How to run
See `DEVELOPMENT_SETUP.md`. Demo logins (Development only, password `Demo@12345`): priya.menon@democompany.in (owner + procurement manager), mark.w@…, rahul.d@… (department manager), sneha.i@… (finance), anita.rao@… (requester), suresh.j@… (warehouse), all `@democompany.in`.

## Commits
Listed in `DEVELOPMENT_PROGRESS.md`. All local; nothing was pushed.
