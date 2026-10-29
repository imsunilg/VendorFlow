# Deployment guide

> **Verification status:** the Docker files and compose file were written but **not executed** (Docker is not installed on the development machine). The API, web build and database auto-creation were verified locally without Docker.

## Option A – Docker Compose (recommended)
```bash
cp .env.example .env          # set POSTGRES_PASSWORD and JWT_SECRET (32+ random characters), optional SMTP_*
docker compose up --build -d
```
| URL | What |
|---|---|
| http://localhost:8080 | Web app (nginx; forwards `/api` to the API) |
| http://localhost:5230/swagger | API (disable by not publishing the port in production) |

The API creates database `Vendor_db` and applies the schema/functions on start. Create the first organization at `/register` (demo data is **only** created in the Development environment).

## Option B – manual
1. PostgreSQL 16 reachable by the API. The login in the connection string needs the right to `CREATE DATABASE` for the first start (or create `Vendor_db` yourself and set `Database:AutoMigrate=true`).
2. `dotnet publish VendorFlowAPI/VendorFlow.API -c Release`; run with environment variables:
   `ConnectionStrings__VendorFlow`, `Jwt__Secret`, `Jwt__Issuer`, `Jwt__Audience`, `Cors__Origins` (web address), `App__WebUrl`, `Storage__Path` (writable folder), optional `Smtp__*`.
3. `cd VendorFlowWEB; npm ci; npx ng build --configuration production`, serve `dist/VendorFlowWEB/browser` behind a web server that proxies `/api` to the API and falls back to `index.html`.

## Configuration reference
| Key | Meaning |
|---|---|
| `ConnectionStrings:VendorFlow` | PostgreSQL connection (never commit the password) |
| `Jwt:Secret` | signing key, 32+ chars, different per environment |
| `Database:AutoMigrate` | `true` (default) creates DB/schema on start; `false` for locked-down databases (apply scripts yourself) |
| `Cors:Origins` | comma separated allowed web origins |
| `Storage:Path` | folder for uploads (back it up) |
| `Smtp:*` | optional e-mail; without it notifications stay in-app and e-mail waits in `email_outbox` |
| `Jobs:Enabled` | `false` disables Hangfire background jobs |
| `RateLimit:AuthPerMinute` | login/portal requests per minute per address (default 20) |

## Database changes (migration procedure)
- Schema lives in `VendorFlowDB`. **Table scripts** (`02_Tables`) run once and are checksummed in `vendorflow.schema_migrations`; editing an applied script is refused on purpose.
- To change a table: add a new numbered script (e.g. `02_Tables/070_add_column.sql` using `alter table`). **Functions** (`05_Functions`), indexes, triggers and seed data are `create or replace`/idempotent and re-applied on every start.
- Several API instances can start together: a PostgreSQL advisory lock lets one migrate at a time.
- Deploy: back up (see `BACKUP_AND_RESTORE.md`) → deploy the new image → check `/health` → smoke test.
- Rollback: restore the backup and redeploy the previous image (table scripts are forward-only).

## Production checklist
HTTPS in front of nginx · strong `JWT_SECRET` and DB password · restrict port 5432 · backups scheduled and restore-tested · SMTP configured · Hangfire dashboard is local-only · rotate secrets when staff leave · mobile app built with `--dart-define=API_URL=https://…` and without cleartext traffic.
