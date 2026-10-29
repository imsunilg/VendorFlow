-- Core: tenants, settings, identity, permissions, audit, numbering, notifications, files.

create table vendorflow.tenants (
    id          uuid primary key default gen_random_uuid(),
    name        text        not null,
    status      text        not null default 'Active' check (status in ('Active','Suspended')),
    created_at  timestamptz not null default now()
);

create table vendorflow.tenant_settings (
    tenant_id               uuid primary key references vendorflow.tenants(id) on delete cascade,
    app_display_name        text not null default 'VendorFlow' check (char_length(app_display_name) between 1 and 50),
    organization_name       text not null check (char_length(organization_name) between 1 and 100),
    vendor_label_singular   text not null default 'Vendor'  check (char_length(vendor_label_singular) between 1 and 50),
    vendor_label_plural     text not null default 'Vendors' check (char_length(vendor_label_plural) between 1 and 50),
    logo_url                text,
    currency                text not null default 'INR',
    time_zone               text not null default 'Asia/Kolkata',
    tax_settings            jsonb not null default '{"defaultTaxPercent":18,"taxName":"GST"}',
    numbering               jsonb not null default '{"requisition":"REQ-{YYYY}-{0000}","rfq":"RFQ-{YYYY}-{0000}","po":"PO-{YYYY}-{0000}","grn":"GRN-{YYYY}-{0000}","payment":"PAY-{YYYY}-{0000}","vendor":"VND-{0000}"}',
    notification_prefs      jsonb not null default '{"email":false,"inApp":true}',
    performance_weights     jsonb not null default '{"onTime":30,"acceptedQty":25,"invoiceAccuracy":20,"responsiveness":10,"documentCompliance":15}',
    invoice_tolerance_pct   numeric(9,4) not null default 2,
    allow_self_approval     boolean not null default false,
    updated_at              timestamptz not null default now()
);

create table vendorflow.permissions (
    code        text primary key,
    description text not null
);

create table vendorflow.roles (
    id          uuid primary key default gen_random_uuid(),
    code        text unique not null,
    name        text not null,
    description text
);

create table vendorflow.role_permissions (
    role_id         uuid not null references vendorflow.roles(id) on delete cascade,
    permission_code text not null references vendorflow.permissions(code) on delete cascade,
    primary key (role_id, permission_code)
);

create table vendorflow.users (
    id               uuid primary key default gen_random_uuid(),
    tenant_id        uuid not null references vendorflow.tenants(id) on delete cascade,
    email            text not null,
    full_name        text not null,
    password_hash    text not null,
    status           text not null default 'Active' check (status in ('Active','Invited','Disabled')),
    failed_attempts  int  not null default 0,
    locked_until     timestamptz,
    vendor_id        uuid,                      -- set for Vendor Portal users
    last_login_at    timestamptz,
    created_at       timestamptz not null default now()
);
create unique index ux_users_email on vendorflow.users (lower(email));
create unique index ux_users_tenant_id on vendorflow.users (tenant_id, id);

create table vendorflow.user_roles (
    user_id uuid not null references vendorflow.users(id) on delete cascade,
    role_id uuid not null references vendorflow.roles(id) on delete cascade,
    primary key (user_id, role_id)
);

create table vendorflow.refresh_tokens (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references vendorflow.users(id) on delete cascade,
    token_hash  text not null unique,
    expires_at  timestamptz not null,
    revoked_at  timestamptz,
    replaced_by text,
    created_at  timestamptz not null default now()
);

create table vendorflow.password_resets (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references vendorflow.users(id) on delete cascade,
    token_hash  text not null unique,
    expires_at  timestamptz not null,
    used_at     timestamptz
);

create table vendorflow.departments (
    id        uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references vendorflow.tenants(id) on delete cascade,
    name      text not null,
    manager_user_id uuid,
    unique (tenant_id, name)
);

create table vendorflow.cost_centres (
    id            uuid primary key default gen_random_uuid(),
    tenant_id     uuid not null references vendorflow.tenants(id) on delete cascade,
    code          text not null,
    name          text not null,
    department_id uuid references vendorflow.departments(id),
    unique (tenant_id, code)
);

create table vendorflow.numbering_sequences (
    tenant_id   uuid not null references vendorflow.tenants(id) on delete cascade,
    doc_type    text not null,
    period      int  not null,            -- year; 0 when the pattern has no {YYYY}
    last_number bigint not null default 0,
    primary key (tenant_id, doc_type, period)
);

create table vendorflow.audit_events (
    id          bigint generated always as identity primary key,
    tenant_id   uuid,
    user_id     uuid,
    action      text not null,
    entity_type text,
    entity_id   uuid,
    details     jsonb,
    created_at  timestamptz not null default now()
);
create index ix_audit_tenant_time on vendorflow.audit_events (tenant_id, created_at desc);

-- One generic history table for every document type (vendor, requisition, PO, ...).
create table vendorflow.entity_history (
    id          bigint generated always as identity primary key,
    tenant_id   uuid not null,
    entity_type text not null,
    entity_id   uuid not null,
    action      text not null,
    from_status text,
    to_status   text,
    comment     text,
    user_id     uuid,
    created_at  timestamptz not null default now()
);
create index ix_history_entity on vendorflow.entity_history (tenant_id, entity_type, entity_id, created_at);

create table vendorflow.attachments (
    id           uuid primary key default gen_random_uuid(),
    tenant_id    uuid not null references vendorflow.tenants(id) on delete cascade,
    entity_type  text not null,
    entity_id    uuid not null,
    file_name    text not null,
    content_type text not null,
    size_bytes   bigint not null,
    storage_key  text not null unique,   -- random key, never the user-supplied name
    uploaded_by  uuid,
    created_at   timestamptz not null default now()
);
create index ix_attachments_entity on vendorflow.attachments (tenant_id, entity_type, entity_id);

create table vendorflow.notifications (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null references vendorflow.tenants(id) on delete cascade,
    user_id     uuid not null references vendorflow.users(id) on delete cascade,
    type        text not null,
    title       text not null,
    body        text,
    entity_type text,
    entity_id   uuid,
    dedupe_key  text not null,
    read_at     timestamptz,
    created_at  timestamptz not null default now(),
    unique (user_id, dedupe_key)
);
create index ix_notifications_user on vendorflow.notifications (tenant_id, user_id, read_at, created_at desc);

create table vendorflow.email_outbox (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    to_email    text not null,
    subject     text not null,
    body        text not null,
    status      text not null default 'Pending' check (status in ('Pending','Sent','Failed')),
    attempts    int  not null default 0,
    last_error  text,
    dedupe_key  text not null,
    created_at  timestamptz not null default now(),
    sent_at     timestamptz,
    unique (tenant_id, dedupe_key)
);
