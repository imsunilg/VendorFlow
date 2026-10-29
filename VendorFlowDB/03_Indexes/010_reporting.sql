-- Extra indexes for dashboards, reports and background jobs (idempotent).
create index if not exists ix_po_tenant_order_date on vendorflow.purchase_orders (tenant_id, order_date);
create index if not exists ix_po_tenant_expected on vendorflow.purchase_orders (tenant_id, expected_delivery) where status in ('Issued', 'PartiallyReceived');
create index if not exists ix_payments_paid_on on vendorflow.payments (tenant_id, paid_on);
create index if not exists ix_rfqs_open_deadline on vendorflow.rfqs (tenant_id, deadline) where status = 'Open';
create index if not exists ix_approval_requests_pending on vendorflow.approval_requests (tenant_id, created_at) where status = 'Pending';
create index if not exists ix_email_outbox_pending on vendorflow.email_outbox (created_at) where status = 'Pending';
create index if not exists ix_grn_po on vendorflow.goods_receipts (tenant_id, po_id);
create index if not exists ix_invoice_items_po_item on vendorflow.invoice_items (po_item_id);
create index if not exists ix_audit_action on vendorflow.audit_events (tenant_id, action);
