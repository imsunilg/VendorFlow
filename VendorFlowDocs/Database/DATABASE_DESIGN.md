# Database design

PostgreSQL 16 · database `Vendor_db` · schema `vendorflow` · snake_case · UUID keys · `timestamptz` UTC · money `numeric(18,2)` · rates/percent `numeric(9,4)`.

## Automatic creation
`DatabaseInitializer` (API start-up): connects to `postgres`, runs `CREATE DATABASE "Vendor_db"` if missing, then applies `VendorFlowDB` scripts in folder order:

| Folder | Behaviour |
|---|---|
| `01_Schemas` | always run (idempotent) – schema + `schema_migrations` + `fn_migration_checksum`/`sp_record_migration` |
| `02_Tables` | **run once**, tracked with checksum in `schema_migrations`; a changed script is rejected (add a new numbered script instead) |
| `03_Indexes`, `04_Sequences`, `05_Functions`, `06_Views`, `07_Triggers`, `08_SeedData` | idempotent, re-applied every start |

`scripts/Apply-Database.ps1` does the same with psql for inspection.

## Table groups
- **Core:** `tenants`, `tenant_settings` (display name, vendor labels, currency, numbering, tolerance, weights), `users`, `roles`, `permissions`, `role_permissions`, `user_roles`, `refresh_tokens`, `password_resets`, `departments`, `cost_centres`, `numbering_sequences`, `audit_events`, `entity_history`, `attachments`, `notifications`, `email_outbox`.
- **Vendors:** `vendors`, `vendor_contacts`, `vendor_addresses`, `vendor_documents` (expiry), `vendor_bank_details` (restricted), `vendor_performance_events`.
- **Requisitions & approvals:** `requisitions`, `requisition_items`, `approval_rules`, `approval_rule_steps`, `approval_requests`, `approval_steps`, `delegations`.
- **RFQ:** `rfqs`, `rfq_items`, `rfq_vendors` (hashed token), `quotations`, `quotation_items`, `rfq_clarifications`, `quotation_recommendations`.
- **PO/GRN:** `purchase_orders`, `po_items`, `po_revisions`, `goods_receipts`, `grn_items`.
- **Finance:** `invoices`, `invoice_items`, `invoice_discrepancies`, `payments`.

## Tenant isolation
Every tenant-owned table has `tenant_id`; business keys are unique per tenant (`unique(tenant_id, number)`, vendor name/GSTIN, `(tenant_id, vendor_id, invoice_number)`, payment idempotency key). Every function takes `p_tenant_id` first and filters on it; child rows are reached only through a tenant-checked parent.

## Integrity guards in the schema
`grn_items`: accepted + rejected = received; damaged ≤ rejected. `invoices`: 0 ≤ paid ≤ total, unique per tenant+vendor+number. `payments`: unique idempotency key. `numbering_sequences`: atomic upsert counter.

## Function conventions
`fn_*` returns data (`jsonb` objects/lists or scalars); `sp_*` procedures perform writes without a return value (or `INOUT p_result jsonb`). Errors use SQLSTATE `VF400` (validation), `VF403` (forbidden), `VF404` (not found), `VF409` (conflict/state).

## Seed plan
`08_SeedData` seeds permissions, 13 roles and mappings. Default departments, cost centres and approval rules are created per tenant by `fn_register_organization`. Demo data is created only in Development by `fn_seed_demo_data`.
