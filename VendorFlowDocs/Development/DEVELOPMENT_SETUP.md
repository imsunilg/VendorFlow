# Development setup (Windows)

## Prerequisites
.NET SDK 9, Node 20+ with Angular CLI, Flutter 3.x, PostgreSQL 16 running on `localhost:5432` (Docker is optional). Run `./scripts/Validate-Environment.ps1`.

## 1. API and database
```powershell
./scripts/Setup-Development.ps1 -DbPassword <postgres password>   # creates the git-ignored appsettings.Development.json
dotnet run --project VendorFlowAPI/VendorFlow.API                  # http://localhost:5230
```
On start the API **creates database `Vendor_db` if it is missing**, applies the schema and functions from `VendorFlowDB`, and (Development only) creates demo data. Nothing needs to be run by hand. The password stays in `appsettings.Development.json`, which is git-ignored.

## 2. Web
```powershell
cd VendorFlowWEB; npm install; npm start        # http://localhost:4230  (API URL in src/environments)
```

## 3. Mobile
```powershell
cd VendorFlowMOBILE; flutter pub get; flutter run   # Android emulator reaches the API at http://10.0.2.2:5230
```

## Demo logins (Development demo data only)
Password for all: `Demo@12345`

| User | Email | Roles |
|---|---|---|
| Priya Menon | priya.menon@democompany.in | Organization Owner, Procurement Manager |
| Mark Williams | mark.w@democompany.in | Procurement Manager (approves POs) |
| Rahul Deshmukh | rahul.d@democompany.in | Department Manager, Approver |
| Sneha Iyer | sneha.i@democompany.in | Finance Manager |
| Anita Rao | anita.rao@democompany.in | Department Requester |
| Suresh Jadhav | suresh.j@democompany.in | Warehouse Manager |

## Tests
`dotnet test VendorFlowAPI` runs 148 integration tests against a throw-away database `Vendor_db_test` (dropped and re-created each run; takes ~4 minutes). `cd VendorFlowWEB; npm test`, `cd VendorFlowMOBILE; flutter test`.

## Useful
- Reset the dev database: drop `Vendor_db` in pgAdmin/psql and start the API again.
- Table scripts (`VendorFlowDB/02_Tables`) are run once and checksummed: add a **new numbered script** instead of editing an applied one.
- Optional SMTP: set `Smtp:Host`, `Smtp:Port`, `Smtp:User`, `Smtp:Password`, `Smtp:From`. Without it e-mail stays queued in `email_outbox`.
- Hangfire dashboard (local requests only): `http://localhost:5230/hangfire`.
