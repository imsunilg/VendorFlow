-- Invoices, matching results and payments.

create table vendorflow.invoices (
    id              uuid primary key default gen_random_uuid(),
    tenant_id       uuid not null references vendorflow.tenants(id) on delete cascade,
    invoice_number  text not null,
    vendor_id       uuid not null references vendorflow.vendors(id),
    po_id           uuid references vendorflow.purchase_orders(id),
    invoice_date    date not null,
    due_date        date not null,
    currency        text not null default 'INR',
    subtotal        numeric(18,2) not null default 0,
    tax_total       numeric(18,2) not null default 0,
    total           numeric(18,2) not null,
    paid_amount     numeric(18,2) not null default 0,
    status          text not null default 'Registered'
                    check (status in ('Registered','NeedsReview','Matched','Approved','PartiallyPaid','Paid','Disputed','Cancelled')),
    match_type      text not null default 'ThreeWay' check (match_type in ('TwoWay','ThreeWay')),
    receipt_value   numeric(18,2),
    variance_amount numeric(18,2),
    variance_pct    numeric(9,4),
    storage_key     text,
    notes           text,
    created_by      uuid not null,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    row_version     int not null default 1,
    check (paid_amount >= 0 and paid_amount <= total)
);
create unique index ux_invoices_dupe on vendorflow.invoices (tenant_id, vendor_id, lower(invoice_number)) where status <> 'Cancelled';
create unique index ux_invoices_tenant_id on vendorflow.invoices (tenant_id, id);
create index ix_invoices_status on vendorflow.invoices (tenant_id, status);
create index ix_invoices_due on vendorflow.invoices (tenant_id, due_date);

create table vendorflow.invoice_items (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    invoice_id  uuid not null references vendorflow.invoices(id) on delete cascade,
    po_item_id  uuid references vendorflow.po_items(id),
    description text not null,
    quantity    numeric(18,3) not null check (quantity > 0),
    rate        numeric(18,2) not null check (rate >= 0),
    discount_percent numeric(9,4) not null default 0,
    net_amount  numeric(18,2) not null default 0,
    tax_amount  numeric(18,2) not null default 0,
    line_total  numeric(18,2) not null
);

create table vendorflow.invoice_discrepancies (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    invoice_id  uuid not null references vendorflow.invoices(id) on delete cascade,
    po_item_id  uuid,
    check_name  text not null,
    expected    text,
    actual      text,
    message     text not null,
    mandatory   boolean not null default true,
    raised_manually boolean not null default false,
    created_at  timestamptz not null default now()
);

create table vendorflow.payments (
    id               uuid primary key default gen_random_uuid(),
    tenant_id        uuid not null references vendorflow.tenants(id) on delete cascade,
    number           text not null,
    invoice_id       uuid not null references vendorflow.invoices(id),
    vendor_id        uuid not null references vendorflow.vendors(id),
    amount           numeric(18,2) not null check (amount > 0),
    method           text not null check (method in ('NEFT','RTGS','UPI','IMPS','Cheque','Cash','Other')),
    reference        text,
    paid_on          date not null default current_date,
    idempotency_key  text not null,
    notes            text,
    created_by       uuid not null,
    created_at       timestamptz not null default now(),
    unique (tenant_id, number),
    unique (tenant_id, idempotency_key)
);
create index ix_payments_invoice on vendorflow.payments (tenant_id, invoice_id);
