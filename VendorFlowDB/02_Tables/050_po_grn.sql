-- Purchase orders and goods receipts.

create table vendorflow.purchase_orders (
    id                uuid primary key default gen_random_uuid(),
    tenant_id         uuid not null references vendorflow.tenants(id) on delete cascade,
    number            text not null,
    vendor_id         uuid not null references vendorflow.vendors(id),
    requisition_id    uuid references vendorflow.requisitions(id),
    rfq_id            uuid references vendorflow.rfqs(id),
    status            text not null default 'Draft'
                      check (status in ('Draft','PendingApproval','Approved','Issued','PartiallyReceived','FullyReceived','Closed','Rejected','Cancelled','OnHold')),
    revision          int not null default 0,
    order_date        date not null default current_date,
    expected_delivery date,
    currency          text not null default 'INR',
    subtotal          numeric(18,2) not null default 0,
    discount_total    numeric(18,2) not null default 0,
    tax_total         numeric(18,2) not null default 0,
    shipping          numeric(18,2) not null default 0,
    total             numeric(18,2) not null default 0,
    notes             text,
    issued_at         timestamptz,
    acknowledged_at   timestamptz,
    created_by        uuid not null,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),
    row_version       int not null default 1,
    unique (tenant_id, number)
);
create unique index ux_po_tenant_id on vendorflow.purchase_orders (tenant_id, id);
create index ix_po_status on vendorflow.purchase_orders (tenant_id, status);
create index ix_po_vendor on vendorflow.purchase_orders (tenant_id, vendor_id);

create table vendorflow.po_items (
    id               uuid primary key default gen_random_uuid(),
    tenant_id        uuid not null,
    po_id            uuid not null references vendorflow.purchase_orders(id) on delete cascade,
    line_no          int not null,
    description      text not null,
    unit             text not null default 'Nos',
    quantity         numeric(18,3) not null check (quantity > 0),
    rate             numeric(18,2) not null check (rate >= 0),
    discount_percent numeric(9,4) not null default 0,
    tax_percent      numeric(9,4) not null default 0,
    net_amount       numeric(18,2) not null,
    tax_amount       numeric(18,2) not null,
    line_total       numeric(18,2) not null,
    received_qty     numeric(18,3) not null default 0,   -- accepted quantity posted through GRNs
    invoiced_qty     numeric(18,3) not null default 0,
    unique (po_id, line_no)
);

create table vendorflow.po_revisions (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    po_id       uuid not null references vendorflow.purchase_orders(id) on delete cascade,
    revision    int not null,
    snapshot    jsonb not null,
    reason      text,
    created_by  uuid,
    created_at  timestamptz not null default now(),
    unique (po_id, revision)
);

create table vendorflow.goods_receipts (
    id                 uuid primary key default gen_random_uuid(),
    tenant_id          uuid not null references vendorflow.tenants(id) on delete cascade,
    number             text not null,
    po_id              uuid not null references vendorflow.purchase_orders(id),
    received_on        date not null default current_date,
    warehouse          text,
    delivery_challan   text,
    vehicle_no         text,
    received_by        text,
    inspection_notes   text,
    status             text not null default 'Posted' check (status in ('Posted','Cancelled')),
    created_by         uuid not null,
    created_at         timestamptz not null default now(),
    unique (tenant_id, number)
);
create unique index ux_grn_challan on vendorflow.goods_receipts (tenant_id, po_id, lower(delivery_challan))
    where delivery_challan is not null and delivery_challan <> '' and status = 'Posted';
create unique index ux_grn_tenant_id on vendorflow.goods_receipts (tenant_id, id);

create table vendorflow.grn_items (
    id            uuid primary key default gen_random_uuid(),
    tenant_id     uuid not null,
    grn_id        uuid not null references vendorflow.goods_receipts(id) on delete cascade,
    po_item_id    uuid not null references vendorflow.po_items(id),
    received_qty  numeric(18,3) not null check (received_qty >= 0),
    accepted_qty  numeric(18,3) not null check (accepted_qty >= 0),
    rejected_qty  numeric(18,3) not null check (rejected_qty >= 0),
    damaged_qty   numeric(18,3) not null default 0 check (damaged_qty >= 0),
    check (accepted_qty + rejected_qty = received_qty),
    check (damaged_qty <= rejected_qty)
);
