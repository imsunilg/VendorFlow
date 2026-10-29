# API specification

Base URL `http://localhost:5080/api/v1` · Swagger UI `/swagger` · health `/health` · JSON camelCase · UTC timestamps.

**Auth:** `Authorization: Bearer <accessToken>` (15 min). `POST /auth/refresh` rotates the refresh token (14 days); re-using an old refresh token revokes all tokens of the user. The tenant comes from the token (`tid`), never from the client.

**Lists:** `page`, `pageSize` (max 200), `sortBy`, `sortDir`, `search` + filters → `{ items, totalCount, page, pageSize, statusCounts? }`.

**Errors:** `{ type, title, status, detail, errors }`. 400 validation/rule, 401, 403 (missing permission or not an approver), 404 (also for other tenants' data), 409 (state/duplicate/concurrency), 429 (rate limit), 501 (AI extraction off).

**Rounding rule:** per line `gross=round(qty×round(rate,2),2)`, `discount=round(gross×d%/100,2)`, `net=gross−discount`, `tax=round(net×t%/100,2)`, `line=net+tax`; totals are sums of rounded lines (+ shipping). Half-up on positive money.

## Endpoints (permission in brackets)
| Area | Endpoints |
|---|---|
| Auth | `POST /auth/register-organization`, `/auth/login`, `/auth/refresh`, `/auth/logout`, `/auth/forgot-password`, `/auth/reset-password`, `GET /auth/me` |
| Users | `GET /users`, `/roles`, `POST /users/invite`, `PUT /users/{id}/roles`, `/users/{id}/status` [users.manage]; `GET /audit` [audit.view] |
| Settings | `GET /organizations/current/settings` (any user), `PUT` [settings.manage], `POST/GET /organizations/current/logo`, `GET /lookups/departments`, `/lookups/cost-centres` |
| Vendors | `GET /vendors`, `/vendors/{id}`, `/export`, `/categories`, `/{id}/performance`, `/{id}/history` [vendors.view]; `POST /vendors` [create]; `PUT /{id}` [edit]; `POST /{id}/submit|approve|reject|suspend|reactivate`; contacts/addresses/documents (`POST`, `DELETE`); `GET/PUT /{id}/bank` [vendors.bank.view / .manage, audited] |
| Requisitions | `GET /requisitions` (`scope=mine`), `/{id}`, `/export`; `POST`, `PUT /{id}`, `POST /{id}/submit|cancel` [requisitions.create] |
| Approvals | `GET /approvals?tab=pending|approved|rejected|delegated`, `/approvals/{id}`, `/approvals/pending-count`; `POST /approvals/{id}/approve|reject|request-changes` (`expectedVersion` optional) [approvals.decide]; rules `GET/POST/DELETE /approval-rules` and `PUT /departments/{id}/manager` [approvals.manage]; `GET/POST/DELETE /delegations` |
| RFQ | `GET /rfqs`, `/{id}`, `/{id}/compare` ; `POST /rfqs`, `PUT`, `/{id}/open|close|cancel|reopen|reminders`, `/{id}/vendors/{vid}/invite|quotation`, `/clarifications/{cid}/answer`, `/{id}/recommendation` [rfqs.manage / quotations.recommend] |
| Vendor portal (anonymous, secret token) | `GET /portal/rfq/{token}`, `POST …/quotation`, `…/clarifications`, `…/decline` |
| Purchase orders | `GET /purchase-orders`, `/{id}`, `/{id}/pdf`, `/export`; `POST` (direct), `/from-requisition/{id}`, `/from-rfq/{id}`; `PUT /{id}` (draft only); `POST /{id}/submit` [po.approve], `/issue|acknowledge|hold|resume|close` [po.issue], `/revisions|cancel` [po.create] |
| Goods receipts | `GET /goods-receipts`, `/{id}`; `POST /purchase-orders/{poId}/receipts`, `/goods-receipts/{id}/cancel` [grn.record] |
| Invoices | `GET /invoices?tab=all|outstanding|overdue`, `/{id}`, `/export`; `POST` register, `PUT /{id}`, `/{id}/cancel` [invoices.create]; `POST /{id}/rematch|discrepancies|reconcile` [invoices.reconcile] |
| Payments | `GET /payments`, `/payments/summary`; `POST /payments` with header **Idempotency-Key** [payments.record] (201 new, 200 replay) |
| Attachments | `GET/POST /attachments/{entityType}/{entityId}`, `GET /attachments/{id}/file`, `DELETE /attachments/{id}` |
| Notifications | `GET /notifications`, `POST /notifications/{id}/read`, `/read-all`, `/run-checks` [settings.manage] |
| Dashboard & reports | `GET /dashboard` [reports.view], `/dashboard/summary`; `GET /reports`, `/reports/{name}?from&to&groupBy&days`, `/reports/{name}/export` (CSV) [reports.view] |
| AI (optional) | `GET /documents/extraction/status`, `POST /documents/extract/{invoice|quotation}` → 501 unless a provider is registered |

## Status models
Vendor `Draft→PendingApproval→Approved⇄Suspended` (`Rejected→Draft`). Requisition `Draft→PendingApproval→Approved→ConvertedToPO` (+`Rejected`, `ReturnedForModification`, `Cancelled`). RFQ `Draft→Open→Closed→Awarded` (+`Cancelled`). PO `Draft→PendingApproval→Approved→Issued→PartiallyReceived→FullyReceived→Closed` (+`Rejected`, `Cancelled`, `OnHold`). Invoice `Registered→NeedsReview|Matched→Approved→PartiallyPaid→Paid` (+`Disputed`, `Cancelled`).
