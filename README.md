# VendorFlow

Multi-tenant procurement and vendor management: vendors → requisitions → approvals → RFQ → quotation comparison → purchase orders → goods receipts → invoices → payments → reports.

| Folder | What |
|---|---|
| `VendorFlowAPI` | ASP.NET Core API (Clean Architecture, Dapper, PostgreSQL functions/procedures) |
| `VendorFlowWEB` | Angular + Material web app |
| `VendorFlowMOBILE` | Flutter app |
| `VendorFlowDB` | SQL scripts (schema, functions, seed) – applied automatically by the API |
| `VendorFlowDocs` | PRD, architecture, API, deployment docs |
| `scripts` | `Setup-Development.ps1`, `Save-Phase.ps1`, `Validate-Environment.ps1` |

## Quick start
```powershell
./scripts/Setup-Development.ps1 -DbPassword <your postgres password>
dotnet run --project VendorFlowAPI/VendorFlow.API      # creates Vendor_db + schema on first run
cd VendorFlowWEB; npm install; npm start               # http://localhost:4200
```
Details: `VendorFlowDocs/Development/DEVELOPMENT_SETUP.md`. Progress: `VendorFlowDocs/Development/DEVELOPMENT_PROGRESS.md`.
