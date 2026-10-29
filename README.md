# VendorFlow

Multi-tenant procurement and vendor management: vendors → requisitions → approvals → RFQ → quotation comparison → purchase orders → goods receipts → invoices (3-way match) → payments → reports. The app name and the word “Vendor” are configurable per organization.

| Folder | What |
|---|---|
| `VendorFlowAPI` | ASP.NET Core API (Clean Architecture; all data access through PostgreSQL functions/procedures) |
| `VendorFlowWEB` | Angular 22 + Material web app |
| `VendorFlowMOBILE` | Flutter app |
| `VendorFlowDB` | SQL scripts (schema, functions, triggers, seed) – applied automatically by the API, which also creates `Vendor_db` |
| `VendorFlowDocs` | PRD, architecture, database, API, setup, deployment docs and the final report |
| `scripts` | `Setup-Development.ps1`, `Save-Phase.ps1` (safe local commit), `Validate-Environment.ps1`, `Apply-Database.ps1` |

## Quick start
```powershell
./scripts/Setup-Development.ps1 -DbPassword <your postgres password>
dotnet run --project VendorFlowAPI/VendorFlow.API      # creates Vendor_db + schema + demo data; http://localhost:5230/swagger
cd VendorFlowWEB; npm install; npm start               # http://localhost:4230   (priya.menon@democompany.in / Demo@12345; the login page lists a demo account for every role)
cd VendorFlowMOBILE; flutter pub get; flutter run
```
Docs: `VendorFlowDocs/Development/DEVELOPMENT_SETUP.md` · status and limitations: `VendorFlowDocs/Development/FINAL_REPORT.md`.
