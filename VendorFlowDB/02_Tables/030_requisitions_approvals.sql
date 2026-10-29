-- Requisitions and approval workflow.

create table vendorflow.requisitions (
    id               uuid primary key default gen_random_uuid(),
    tenant_id        uuid not null references vendorflow.tenants(id) on delete cascade,
    number           text not null,
    title            text not null,
    department_id    uuid references vendorflow.departments(id),
    cost_centre_id   uuid references vendorflow.cost_centres(id),
    required_date    date,
    justification    text,
    priority         text not null default 'Medium' check (priority in ('Low','Medium','High')),
    status           text not null default 'Draft'
                     check (status in ('Draft','PendingApproval','Approved','ConvertedToPO','Rejected','ReturnedForModification','Cancelled')),
    total_amount     numeric(18,2) not null default 0,
    requester_id     uuid not null,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now(),
    row_version      int not null default 1,
    unique (tenant_id, number)
);
create unique index ux_requisitions_tenant_id on vendorflow.requisitions (tenant_id, id);
create index ix_requisitions_status on vendorflow.requisitions (tenant_id, status);

create table vendorflow.requisition_items (
    id              uuid primary key default gen_random_uuid(),
    tenant_id       uuid not null,
    requisition_id  uuid not null references vendorflow.requisitions(id) on delete cascade,
    line_no         int not null,
    description     text not null,
    unit            text not null default 'Nos',
    quantity        numeric(18,3) not null check (quantity > 0),
    est_unit_price  numeric(18,2) not null check (est_unit_price >= 0),
    line_total      numeric(18,2) not null,
    unique (requisition_id, line_no)
);

create table vendorflow.approval_rules (
    id             uuid primary key default gen_random_uuid(),
    tenant_id      uuid not null references vendorflow.tenants(id) on delete cascade,
    name           text not null,
    entity_type    text not null check (entity_type in ('requisition','purchase_order')),
    min_amount     numeric(18,2) not null default 0,
    max_amount     numeric(18,2),                    -- null = no upper limit
    department_id  uuid references vendorflow.departments(id),
    priority       int not null default 0,           -- higher wins when several rules match
    active         boolean not null default true
);
create index ix_approval_rules_tenant on vendorflow.approval_rules (tenant_id, entity_type, active);

create table vendorflow.approval_rule_steps (
    id        uuid primary key default gen_random_uuid(),
    rule_id   uuid not null references vendorflow.approval_rules(id) on delete cascade,
    step_no   int not null,
    name      text not null,
    role_code text not null,
    unique (rule_id, step_no)
);

create table vendorflow.approval_requests (
    id            uuid primary key default gen_random_uuid(),
    tenant_id     uuid not null references vendorflow.tenants(id) on delete cascade,
    entity_type   text not null,
    entity_id     uuid not null,
    title         text not null,
    amount        numeric(18,2) not null,
    requested_by  uuid not null,
    department_id uuid,
    status        text not null default 'Pending' check (status in ('Pending','Approved','Rejected','Returned','Cancelled')),
    current_step  int not null default 1,
    total_steps   int not null,
    row_version   int not null default 1,        -- concurrency token (double-click protection)
    created_at    timestamptz not null default now(),
    completed_at  timestamptz
);
create index ix_approval_requests_entity on vendorflow.approval_requests (tenant_id, entity_type, entity_id);
create index ix_approval_requests_status on vendorflow.approval_requests (tenant_id, status);

create table vendorflow.approval_steps (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null,
    request_id  uuid not null references vendorflow.approval_requests(id) on delete cascade,
    step_no     int not null,
    name        text not null,
    role_code   text not null,
    status      text not null default 'Waiting' check (status in ('Waiting','Pending','Approved','Rejected','Returned','Skipped')),
    decided_by  uuid,
    acting_for  uuid,
    decided_at  timestamptz,
    comment     text,
    unique (request_id, step_no)
);

create table vendorflow.delegations (
    id           uuid primary key default gen_random_uuid(),
    tenant_id    uuid not null references vendorflow.tenants(id) on delete cascade,
    from_user_id uuid not null references vendorflow.users(id),
    to_user_id   uuid not null references vendorflow.users(id),
    start_date   date not null,
    end_date     date not null,
    reason       text,
    active       boolean not null default true,
    check (end_date >= start_date),
    check (from_user_id <> to_user_id)
);
