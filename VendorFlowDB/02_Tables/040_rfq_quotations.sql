-- RFQ, vendor quotations, clarifications, recommendation.

create table vendorflow.rfqs (
    id             uuid primary key default gen_random_uuid(),
    tenant_id      uuid not null references vendorflow.tenants(id) on delete cascade,
    number         text not null,
    title          text not null,
    requisition_id uuid references vendorflow.requisitions(id),
    description    text,
    status         text not null default 'Draft' check (status in ('Draft','Open','Closed','Awarded','Cancelled')),
    deadline       timestamptz,
    created_by     uuid not null,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    unique (tenant_id, number)
);
create unique index ux_rfqs_tenant_id on vendorflow.rfqs (tenant_id, id);

create table vendorflow.rfq_items (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    rfq_id      uuid not null references vendorflow.rfqs(id) on delete cascade,
    line_no     int not null,
    description text not null,
    unit        text not null default 'Nos',
    quantity    numeric(18,3) not null check (quantity > 0),
    unique (rfq_id, line_no)
);

create table vendorflow.rfq_vendors (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    rfq_id      uuid not null references vendorflow.rfqs(id) on delete cascade,
    vendor_id   uuid not null references vendorflow.vendors(id),
    token_hash  text unique,                 -- sha256 of the secret link token
    status      text not null default 'Invited' check (status in ('Invited','Viewed','Submitted','Declined')),
    invited_at  timestamptz not null default now(),
    viewed_at   timestamptz,
    unique (rfq_id, vendor_id)
);

create table vendorflow.quotations (
    id               uuid primary key default gen_random_uuid(),
    tenant_id        uuid not null,
    rfq_id           uuid not null references vendorflow.rfqs(id) on delete cascade,
    vendor_id        uuid not null references vendorflow.vendors(id),
    shipping         numeric(18,2) not null default 0 check (shipping >= 0),
    delivery_days    int,
    payment_terms    text,
    warranty_months  int,
    notes            text,
    subtotal         numeric(18,2) not null default 0,   -- sum of (qty*price - discount)
    discount_total   numeric(18,2) not null default 0,
    tax_total        numeric(18,2) not null default 0,
    total_landed     numeric(18,2) not null default 0,   -- subtotal + tax + shipping
    submitted_at     timestamptz not null default now(),
    unique (rfq_id, vendor_id)
);

create table vendorflow.quotation_items (
    id               uuid primary key default gen_random_uuid(),
    tenant_id        uuid not null,
    quotation_id     uuid not null references vendorflow.quotations(id) on delete cascade,
    rfq_item_id      uuid not null references vendorflow.rfq_items(id),
    unit_price       numeric(18,2) not null check (unit_price >= 0),
    discount_percent numeric(9,4) not null default 0 check (discount_percent between 0 and 100),
    tax_percent      numeric(9,4) not null default 0 check (tax_percent between 0 and 100),
    net_amount       numeric(18,2) not null,
    tax_amount       numeric(18,2) not null,
    line_total       numeric(18,2) not null,
    unique (quotation_id, rfq_item_id)
);

create table vendorflow.rfq_clarifications (
    id           uuid primary key default gen_random_uuid(),
    tenant_id    uuid not null,
    rfq_id       uuid not null references vendorflow.rfqs(id) on delete cascade,
    vendor_id    uuid not null references vendorflow.vendors(id),
    question     text not null,
    answer       text,
    asked_at     timestamptz not null default now(),
    answered_by  uuid,
    answered_at  timestamptz
);

create table vendorflow.quotation_recommendations (
    id                   uuid primary key default gen_random_uuid(),
    tenant_id            uuid not null,
    rfq_id               uuid not null unique references vendorflow.rfqs(id) on delete cascade,
    vendor_id            uuid not null references vendorflow.vendors(id),
    justification        text not null,
    lowest_vendor_id     uuid,
    recommended_by       uuid not null,
    created_at           timestamptz not null default now()
);
