# VendorFlow – Product Requirements

## 1. Vision
A multi-tenant SaaS that lets small and medium businesses run the whole purchasing cycle in one place:
vendor onboarding → requisition → approval → RFQ → quotation comparison → purchase order → goods receipt → invoice matching → payment tracking → reports.

Each organization (tenant) can rename the product and the word "Vendor" (Supplier, Contractor, …) without code changes.

## 2. Personas
| Persona | Goal |
|---|---|
| Procurement Manager (Priya) | Onboard vendors, run RFQs, compare quotes, issue POs |
| Department Requester (Anita) | Raise requisitions and track them |
| Department Manager / Approver (Rahul) | Approve or reject requests |
| Finance Manager (Sneha) | Final approvals, reconcile invoices, record payments |
| Warehouse Manager (Suresh) | Record goods receipts |
| Auditor | Read-only view of everything and the audit trail |
| Vendor Portal User | Submit a quotation for an RFQ (own data only) |
| Organization Owner / Admin | Users, roles, settings |
| Platform Administrator | Operates the platform |

## 3. Roles & permissions
13 roles (see §5 of the master prompt). Permissions are strings such as `vendors.view`, `vendors.approve`, `vendors.bank.view`, `requisitions.create`, `approvals.decide`, `rfqs.manage`, `po.approve`, `grn.record`, `invoices.reconcile`, `payments.record`, `settings.manage`, `users.manage`, `reports.view`. The API enforces them; the UI only hides buttons.

## 4. Workflows and state machines
**Vendor:** `Draft → PendingApproval → Approved ⇄ Suspended`, `PendingApproval → Rejected → Draft`.

**Requisition:** `Draft → PendingApproval → Approved → ConvertedToPO`; also `Rejected`, `ReturnedForModification → PendingApproval`, `Cancelled`. (`Submitted` is the instant a draft enters approval.)

**Approval:** sequential levels chosen from tenant rules (amount threshold, department). Actions: approve, reject (comment required), request changes (comment required). Self-approval is blocked. Delegation lets a user act for another within a date range.

**RFQ:** `Draft → Open → Closed → Awarded/Cancelled`. Vendors submit through a tokenised link; a vendor sees only its own quote.

**Purchase order:** `Draft → PendingApproval → Approved → Issued → PartiallyReceived → FullyReceived → Closed`; `Rejected`, `Cancelled`, `OnHold`. Issued POs are immutable; changes require a revision.

**Goods receipt:** posted against an issued PO; received = accepted + rejected; over-receipt blocked.

**Invoice:** `Registered → NeedsReview | Matched → Approved → PartiallyPaid → Paid` (`Disputed`). 3-way match (PO · GRN · invoice) with a tolerance %.

**Payment:** recorded only (no real bank transfer), partial allowed, idempotency key, overpayment blocked.

## 5. MVP vs later
MVP: everything in the phase table, in-app notifications, optional email, CSV export, PDF PO.
Later: vendor self-registration portal, e-signature, ERP/bank integrations, multi-currency conversion, AI extraction (stub only, disabled).

## 6. Risks
Tenant data leakage (mitigated: tenant id in every function + negative tests); duplicate posting (idempotency keys, row locks); money rounding (documented rule); scope size (phased delivery).

## 7. Acceptance criteria (summary)
1. A tenant can never read or change another tenant's data (tested).
2. Display name and vendor label changes are visible app-wide without reload.
3. Invalid state transitions are rejected by the server.
4. Over-receipt, overpayment, duplicate invoice, duplicate payment are rejected.
5. Full flow tenant → … → partial payment passes in an automated end-to-end test.
6. `dotnet test`, `ng build --configuration production`, `flutter analyze` pass (or are documented as not run).
