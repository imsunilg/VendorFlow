-- Vendors (display label is configurable per tenant; the table name is fixed).

create table vendorflow.vendors (
    id                  uuid primary key default gen_random_uuid(),
    tenant_id           uuid not null references vendorflow.tenants(id) on delete cascade,
    code                text not null,
    name                text not null,
    legal_name          text,
    category            text,
    products_services   text,
    status              text not null default 'Draft'
                        check (status in ('Draft','PendingApproval','Approved','Rejected','Suspended')),
    risk                text not null default 'Low' check (risk in ('Low','Medium','High')),
    rating              numeric(3,1) not null default 0,
    gstin               text,
    pan                 text,
    msme_number         text,
    payment_terms_days  int  not null default 30,
    currency            text not null default 'INR',
    email               text,
    phone               text,
    city                text,
    state               text,
    onboarded_at        date,
    created_by          uuid,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    row_version         int not null default 1,
    unique (tenant_id, code)
);
create unique index ux_vendors_tenant_name on vendorflow.vendors (tenant_id, lower(name));
create unique index ux_vendors_tenant_gstin on vendorflow.vendors (tenant_id, upper(gstin)) where gstin is not null and gstin <> '';
create unique index ux_vendors_tenant_id on vendorflow.vendors (tenant_id, id);
create index ix_vendors_status on vendorflow.vendors (tenant_id, status);

alter table vendorflow.users
    add constraint fk_users_vendor foreign key (vendor_id) references vendorflow.vendors(id);

create table vendorflow.vendor_contacts (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    vendor_id   uuid not null references vendorflow.vendors(id) on delete cascade,
    name        text not null,
    designation text,
    email       text,
    phone       text,
    is_primary  boolean not null default false
);
create index ix_vendor_contacts_vendor on vendorflow.vendor_contacts (tenant_id, vendor_id);

create table vendorflow.vendor_addresses (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    vendor_id   uuid not null references vendorflow.vendors(id) on delete cascade,
    address_type text not null default 'Registered',
    line1       text not null,
    line2       text,
    city        text,
    state       text,
    postal_code text,
    country     text not null default 'India'
);
create index ix_vendor_addresses_vendor on vendorflow.vendor_addresses (tenant_id, vendor_id);

create table vendorflow.vendor_documents (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    vendor_id   uuid not null references vendorflow.vendors(id) on delete cascade,
    doc_type    text not null,
    doc_number  text,
    expiry_date date,
    file_name   text,
    storage_key text,
    created_at  timestamptz not null default now()
);
create index ix_vendor_documents_vendor on vendorflow.vendor_documents (tenant_id, vendor_id);
create index ix_vendor_documents_expiry on vendorflow.vendor_documents (tenant_id, expiry_date);

-- Sensitive: only readable through fn_vendor_bank_get (needs vendors.bank.view, audited).
create table vendorflow.vendor_bank_details (
    vendor_id      uuid primary key references vendorflow.vendors(id) on delete cascade,
    tenant_id      uuid not null,
    account_name   text not null,
    account_number text not null,
    ifsc           text not null,
    bank_name      text,
    branch         text,
    updated_at     timestamptz not null default now()
);

create table vendorflow.vendor_performance_events (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    vendor_id   uuid not null references vendorflow.vendors(id) on delete cascade,
    metric      text not null,        -- e.g. rfq_response_hours
    value       numeric(18,4) not null,
    created_at  timestamptz not null default now()
);
create index ix_vendor_perf_vendor on vendorflow.vendor_performance_events (tenant_id, vendor_id, metric);
