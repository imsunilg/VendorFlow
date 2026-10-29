-- RFQ, invitations, vendor portal (token based), clarifications.

create or replace function vendorflow.fn_rfq_get(p_tenant_id uuid, p_id uuid)
returns jsonb language plpgsql stable as $$
declare v_json jsonb;
begin
    select jsonb_build_object(
        'id', r.id, 'number', r.number, 'title', r.title, 'description', r.description, 'status', r.status,
        'deadline', r.deadline, 'is_expired', (r.status = 'Open' and r.deadline is not null and r.deadline < now()),
        'requisition_id', r.requisition_id, 'requisition_number', rq.number, 'created_at', r.created_at, 'created_by_name', u.full_name,
        'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'line_no', i.line_no, 'description', i.description,
                    'unit', i.unit, 'quantity', i.quantity) order by i.line_no) from vendorflow.rfq_items i where i.rfq_id = r.id), '[]'::jsonb),
        'vendors', coalesce((select jsonb_agg(jsonb_build_object('vendor_id', rv.vendor_id, 'vendor_name', v.name, 'vendor_email', v.email, 'status', rv.status,
                    'invited_at', rv.invited_at, 'viewed_at', rv.viewed_at, 'has_invitation', rv.token_hash is not null,
                    'has_quotation', q.id is not null, 'total_landed', q.total_landed, 'submitted_at', q.submitted_at) order by v.name)
                  from vendorflow.rfq_vendors rv join vendorflow.vendors v on v.id = rv.vendor_id
                  left join vendorflow.quotations q on q.rfq_id = rv.rfq_id and q.vendor_id = rv.vendor_id
                  where rv.rfq_id = r.id), '[]'::jsonb),
        'quotations_count', (select count(*) from vendorflow.quotations q where q.rfq_id = r.id),
        'clarifications', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'vendor_id', c.vendor_id, 'vendor_name', cv.name,
                    'question', c.question, 'answer', c.answer, 'asked_at', c.asked_at, 'answered_at', c.answered_at) order by c.asked_at)
                  from vendorflow.rfq_clarifications c join vendorflow.vendors cv on cv.id = c.vendor_id where c.rfq_id = r.id), '[]'::jsonb),
        'recommendation', (select jsonb_build_object('vendor_id', rc.vendor_id, 'vendor_name', rv2.name, 'justification', rc.justification,
                    'created_at', rc.created_at) from vendorflow.quotation_recommendations rc join vendorflow.vendors rv2 on rv2.id = rc.vendor_id
                    where rc.rfq_id = r.id),
        'attachments', vendorflow.fn_attachment_list(p_tenant_id, 'rfq', r.id),
        'history', vendorflow.fn_history_list(p_tenant_id, 'rfq', r.id))
    into v_json
    from vendorflow.rfqs r
    join vendorflow.users u on u.id = r.created_by
    left join vendorflow.requisitions rq on rq.id = r.requisition_id
    where r.id = p_id and r.tenant_id = p_tenant_id;

    if v_json is null then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    return v_json;
end $$;

create or replace function vendorflow.fn_rfq_list(
    p_tenant_id uuid, p_status text default null, p_search text default null, p_sort_by text default null,
    p_sort_dir text default null, p_page int default 1, p_page_size int default 20)
returns jsonb language plpgsql stable as $$
declare
    v_page int := greatest(coalesce(p_page, 1), 1);
    v_size int := least(greatest(coalesce(p_page_size, 20), 1), 200);
    v_order text := vendorflow.fn_sort_clause(p_sort_by, p_sort_dir, array['number','title','status','deadline','created_at'], 'created_at');
    v_where text := $w$ r.tenant_id = $1 and ($2 is null or $2 = '' or r.status = $2)
        and ($3 is null or $3 = '' or r.number ilike '%' || $3 || '%' or r.title ilike '%' || $3 || '%') $w$;
    v_total bigint; v_items jsonb; v_counts jsonb;
begin
    execute 'select count(*) from vendorflow.rfqs r where ' || v_where into v_total using p_tenant_id, p_status, p_search;
    execute format($q$
        select coalesce(jsonb_agg(x), '[]'::jsonb) from (
            select jsonb_build_object('id', r.id, 'number', r.number, 'title', r.title, 'status', r.status, 'deadline', r.deadline,
                'vendors_invited', (select count(*) from vendorflow.rfq_vendors where rfq_id = r.id),
                'quotations_received', (select count(*) from vendorflow.quotations where rfq_id = r.id),
                'requisition_number', (select number from vendorflow.requisitions where id = r.requisition_id), 'created_at', r.created_at) as x
            from vendorflow.rfqs r where %s order by %s offset %s limit %s) s$q$, v_where, v_order, (v_page - 1) * v_size, v_size)
        into v_items using p_tenant_id, p_status, p_search;
    select coalesce(jsonb_object_agg(status, c), '{}'::jsonb) || jsonb_build_object('All', coalesce(sum(c), 0))
    into v_counts from (select status, count(*) c from vendorflow.rfqs where tenant_id = p_tenant_id group by status) g;
    return vendorflow.fn_page(v_items, v_total, v_page, v_size) || jsonb_build_object('status_counts', v_counts);
end $$;

-- Replaces items and invited vendors of a draft RFQ.
create or replace procedure vendorflow.sp_rfq_set_content(p_tenant_id uuid, p_rfq_id uuid, p_data jsonb)
language plpgsql as $$
declare
    it jsonb; n int := 0; v text;
begin
    if p_data ? 'items' then
        if jsonb_array_length(p_data -> 'items') = 0 then raise exception 'Add at least one item.' using errcode = 'VF400'; end if;
        delete from vendorflow.rfq_items where rfq_id = p_rfq_id;
        for it in select * from jsonb_array_elements(p_data -> 'items') loop
            if coalesce(btrim(it ->> 'description'), '') = '' then raise exception 'Every item needs a description.' using errcode = 'VF400'; end if;
            if coalesce((it ->> 'quantity')::numeric, 0) <= 0 then raise exception 'Quantity must be greater than zero.' using errcode = 'VF400'; end if;
            n := n + 1;
            insert into vendorflow.rfq_items (tenant_id, rfq_id, line_no, description, unit, quantity)
            values (p_tenant_id, p_rfq_id, n, btrim(it ->> 'description'), coalesce(nullif(it ->> 'unit', ''), 'Nos'), (it ->> 'quantity')::numeric);
        end loop;
    end if;
    if p_data ? 'vendor_ids' then
        for v in select * from jsonb_array_elements_text(p_data -> 'vendor_ids') loop
            if not exists (select 1 from vendorflow.vendors where id = v::uuid and tenant_id = p_tenant_id and status = 'Approved') then
                raise exception 'Only approved vendors of your organization can be invited.' using errcode = 'VF400';
            end if;
        end loop;
        delete from vendorflow.rfq_vendors where rfq_id = p_rfq_id and status = 'Invited' and token_hash is null;
        insert into vendorflow.rfq_vendors (tenant_id, rfq_id, vendor_id)
        select p_tenant_id, p_rfq_id, x::uuid from jsonb_array_elements_text(p_data -> 'vendor_ids') x
        on conflict (rfq_id, vendor_id) do nothing;
    end if;
end $$;

-- Creates a draft RFQ, optionally from an approved requisition (its items are copied when none are given).
create or replace function vendorflow.fn_rfq_create(p_tenant_id uuid, p_actor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    v_id uuid;
    v_req uuid := nullif(p_data ->> 'requisition_id', '')::uuid;
    v_data jsonb := p_data;
    rq vendorflow.requisitions%rowtype;
begin
    if coalesce(btrim(p_data ->> 'title'), '') = '' then raise exception 'Title is required.' using errcode = 'VF400'; end if;
    if v_req is not null then
        select * into rq from vendorflow.requisitions where id = v_req and tenant_id = p_tenant_id;
        if not found then raise exception 'Requisition not found.' using errcode = 'VF404'; end if;
        if rq.status <> 'Approved' then raise exception 'Only an approved requisition can be sent to RFQ.' using errcode = 'VF409'; end if;
        if not (p_data ? 'items') then
            v_data := v_data || jsonb_build_object('items', (select jsonb_agg(jsonb_build_object('description', i.description,
                'unit', i.unit, 'quantity', i.quantity) order by i.line_no) from vendorflow.requisition_items i where i.requisition_id = v_req));
        end if;
    end if;
    if not (v_data ? 'items') then raise exception 'Add at least one item.' using errcode = 'VF400'; end if;

    insert into vendorflow.rfqs (tenant_id, number, title, requisition_id, description, deadline, created_by)
    values (p_tenant_id, vendorflow.fn_next_number(p_tenant_id, 'rfq'), btrim(p_data ->> 'title'), v_req,
            p_data ->> 'description', nullif(p_data ->> 'deadline', '')::timestamptz, p_actor_id)
    returning id into v_id;
    call vendorflow.sp_rfq_set_content(p_tenant_id, v_id, v_data);
    call vendorflow.sp_history(p_tenant_id, 'rfq', v_id, 'created', null, 'Draft', null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'rfq.created', 'rfq', v_id, null);
    return vendorflow.fn_rfq_get(p_tenant_id, v_id);
end $$;

create or replace function vendorflow.fn_rfq_update(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare r vendorflow.rfqs%rowtype;
begin
    select * into r from vendorflow.rfqs where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status = 'Draft' then
        update vendorflow.rfqs set title = coalesce(nullif(btrim(p_data ->> 'title'), ''), title),
            description = case when p_data ? 'description' then p_data ->> 'description' else description end,
            deadline = case when p_data ? 'deadline' then nullif(p_data ->> 'deadline', '')::timestamptz else deadline end,
            updated_at = now() where id = p_id;
        call vendorflow.sp_rfq_set_content(p_tenant_id, p_id, p_data);
    elsif r.status = 'Open' and p_data ? 'deadline' then
        -- an open RFQ may only have its deadline extended
        if (p_data ->> 'deadline')::timestamptz <= coalesce(r.deadline, now()) then
            raise exception 'The deadline of an open RFQ can only be extended.' using errcode = 'VF409';
        end if;
        update vendorflow.rfqs set deadline = (p_data ->> 'deadline')::timestamptz, updated_at = now() where id = p_id;
        call vendorflow.sp_history(p_tenant_id, 'rfq', p_id, 'deadline_extended', 'Open', 'Open', p_data ->> 'deadline', p_actor_id);
    else
        raise exception 'An RFQ that is % cannot be edited.', r.status using errcode = 'VF409';
    end if;
    return vendorflow.fn_rfq_get(p_tenant_id, p_id);
end $$;

-- Opens a draft RFQ and stores one hashed token per invited vendor. p_tokens = { "<vendor_id>": "<sha256 hash>" }.
create or replace function vendorflow.fn_rfq_open(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_tokens jsonb)
returns jsonb language plpgsql as $$
declare
    r vendorflow.rfqs%rowtype;
    k text;
    u record;
begin
    select * into r from vendorflow.rfqs where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status <> 'Draft' then raise exception 'Only a draft RFQ can be opened.' using errcode = 'VF409'; end if;
    if not exists (select 1 from vendorflow.rfq_items where rfq_id = r.id) then raise exception 'Add at least one item.' using errcode = 'VF400'; end if;
    if not exists (select 1 from vendorflow.rfq_vendors where rfq_id = r.id) then raise exception 'Invite at least one vendor.' using errcode = 'VF400'; end if;
    if r.deadline is null or r.deadline <= now() then raise exception 'Set a deadline in the future.' using errcode = 'VF400'; end if;

    for k in select jsonb_object_keys(p_tokens) loop
        update vendorflow.rfq_vendors set token_hash = p_tokens ->> k, invited_at = now(), status = 'Invited'
        where rfq_id = r.id and vendor_id = k::uuid and tenant_id = p_tenant_id;
    end loop;
    if exists (select 1 from vendorflow.rfq_vendors where rfq_id = r.id and token_hash is null) then
        raise exception 'Every invited vendor needs an invitation token.' using errcode = 'VF400';
    end if;

    update vendorflow.rfqs set status = 'Open', updated_at = now() where id = r.id;
    call vendorflow.sp_history(p_tenant_id, 'rfq', r.id, 'opened', 'Draft', 'Open', null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'rfq.opened', 'rfq', r.id, null);
    return vendorflow.fn_rfq_get(p_tenant_id, r.id);
end $$;

-- Adds a vendor to an open RFQ, or issues a fresh link for an already invited vendor.
create or replace function vendorflow.fn_rfq_invite(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_vendor_id uuid, p_token_hash text)
returns jsonb language plpgsql as $$
declare r vendorflow.rfqs%rowtype; v_name text;
begin
    select * into r from vendorflow.rfqs where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status <> 'Open' then raise exception 'Vendors can only be invited to an open RFQ.' using errcode = 'VF409'; end if;
    if not exists (select 1 from vendorflow.vendors where id = p_vendor_id and tenant_id = p_tenant_id and status = 'Approved') then
        raise exception 'Only approved vendors can be invited.' using errcode = 'VF400';
    end if;
    insert into vendorflow.rfq_vendors (tenant_id, rfq_id, vendor_id, token_hash) values (p_tenant_id, p_id, p_vendor_id, p_token_hash)
    on conflict (rfq_id, vendor_id) do update set token_hash = excluded.token_hash, invited_at = now();
    select name into v_name from vendorflow.vendors where id = p_vendor_id;
    call vendorflow.sp_history(p_tenant_id, 'rfq', p_id, 'vendor_invited', r.status, r.status, v_name, p_actor_id);
    return vendorflow.fn_rfq_get(p_tenant_id, p_id);
end $$;

create or replace function vendorflow.fn_rfq_close(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
declare r vendorflow.rfqs%rowtype;
begin
    select * into r from vendorflow.rfqs where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status <> 'Open' then raise exception 'Only an open RFQ can be closed.' using errcode = 'VF409'; end if;
    update vendorflow.rfqs set status = 'Closed', updated_at = now() where id = r.id;
    call vendorflow.sp_history(p_tenant_id, 'rfq', r.id, 'closed', 'Open', 'Closed', null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'rfq.closed', 'rfq', r.id, null);
    return vendorflow.fn_rfq_get(p_tenant_id, r.id);
end $$;

create or replace function vendorflow.fn_rfq_cancel(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_comment text)
returns jsonb language plpgsql as $$
declare r vendorflow.rfqs%rowtype;
begin
    select * into r from vendorflow.rfqs where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status not in ('Draft', 'Open', 'Closed') then raise exception 'An RFQ that is % cannot be cancelled.', r.status using errcode = 'VF409'; end if;
    if coalesce(btrim(p_comment), '') = '' then raise exception 'A reason is required.' using errcode = 'VF400'; end if;
    update vendorflow.rfqs set status = 'Cancelled', updated_at = now() where id = r.id;
    call vendorflow.sp_history(p_tenant_id, 'rfq', r.id, 'cancelled', r.status, 'Cancelled', p_comment, p_actor_id);
    return vendorflow.fn_rfq_get(p_tenant_id, r.id);
end $$;

-- Re-opens a closed RFQ (for example to collect a late quotation) with a new deadline.
create or replace function vendorflow.fn_rfq_reopen(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_deadline timestamptz)
returns jsonb language plpgsql as $$
declare r vendorflow.rfqs%rowtype;
begin
    select * into r from vendorflow.rfqs where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status <> 'Closed' then raise exception 'Only a closed RFQ can be re-opened.' using errcode = 'VF409'; end if;
    if p_deadline is null or p_deadline <= now() then raise exception 'Set a deadline in the future.' using errcode = 'VF400'; end if;
    update vendorflow.rfqs set status = 'Open', deadline = p_deadline, updated_at = now() where id = r.id;
    call vendorflow.sp_history(p_tenant_id, 'rfq', r.id, 'reopened', 'Closed', 'Open', null, p_actor_id);
    return vendorflow.fn_rfq_get(p_tenant_id, r.id);
end $$;

-- Background job: closes open RFQs whose deadline has passed. Returns how many were closed.
create or replace function vendorflow.fn_rfq_close_expired()
returns int language plpgsql as $$
declare r record; n int := 0;
begin
    for r in select id, tenant_id from vendorflow.rfqs where status = 'Open' and deadline < now() for update skip locked loop
        update vendorflow.rfqs set status = 'Closed', updated_at = now() where id = r.id;
        call vendorflow.sp_history(r.tenant_id, 'rfq', r.id, 'closed', 'Open', 'Closed', 'Deadline passed', null);
        n := n + 1;
    end loop;
    return n;
end $$;

create or replace function vendorflow.fn_rfq_clarification_answer(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_answer text)
returns jsonb language plpgsql as $$
declare c vendorflow.rfq_clarifications%rowtype;
begin
    if coalesce(btrim(p_answer), '') = '' then raise exception 'An answer is required.' using errcode = 'VF400'; end if;
    update vendorflow.rfq_clarifications set answer = btrim(p_answer), answered_by = p_actor_id, answered_at = now()
    where id = p_id and tenant_id = p_tenant_id returning * into c;
    if not found then raise exception 'Clarification not found.' using errcode = 'VF404'; end if;
    return vendorflow.fn_rfq_get(p_tenant_id, c.rfq_id);
end $$;

-- ---------------------------------------------------------------- vendor portal (identified only by the secret token hash)

-- Resolves a token to rfq + vendor. Raises one generic error for every kind of failure (no information leak).
create or replace function vendorflow.fn_portal_resolve(p_token_hash text)
returns table (tenant_id uuid, rfq_id uuid, vendor_id uuid) language plpgsql stable as $$
begin
    return query select rv.tenant_id, rv.rfq_id, rv.vendor_id from vendorflow.rfq_vendors rv
        join vendorflow.vendors v on v.id = rv.vendor_id
        where rv.token_hash = p_token_hash and p_token_hash is not null and v.status = 'Approved';
    if not found then raise exception 'This link is invalid or has expired.' using errcode = 'VF404'; end if;
end $$;

-- What the vendor sees: this RFQ, its own quotation and its own clarifications. Nothing about other vendors.
create or replace function vendorflow.fn_portal_get(p_token_hash text)
returns jsonb language plpgsql as $$
declare
    a record;
    v jsonb;
begin
    select * into a from vendorflow.fn_portal_resolve(p_token_hash);
    update vendorflow.rfq_vendors set viewed_at = coalesce(viewed_at, now()),
        status = case when status = 'Invited' then 'Viewed' else status end
    where rfq_id = a.rfq_id and vendor_id = a.vendor_id;

    select jsonb_build_object(
        'organization', s.app_display_name, 'organization_name', s.organization_name, 'currency', s.currency,
        'rfq', jsonb_build_object('number', r.number, 'title', r.title, 'description', r.description, 'status', r.status,
            'deadline', r.deadline, 'accepting', (r.status = 'Open' and (r.deadline is null or r.deadline > now()))),
        'vendor_name', vd.name,
        'participation', (select status from vendorflow.rfq_vendors where rfq_id = a.rfq_id and vendor_id = a.vendor_id),
        'items', (select jsonb_agg(jsonb_build_object('id', i.id, 'line_no', i.line_no, 'description', i.description,
                    'unit', i.unit, 'quantity', i.quantity) order by i.line_no) from vendorflow.rfq_items i where i.rfq_id = a.rfq_id),
        'quotation', (select jsonb_build_object('shipping', q.shipping, 'delivery_days', q.delivery_days, 'payment_terms', q.payment_terms,
                    'warranty_months', q.warranty_months, 'notes', q.notes, 'subtotal', q.subtotal, 'tax_total', q.tax_total,
                    'total_landed', q.total_landed, 'submitted_at', q.submitted_at,
                    'items', (select jsonb_agg(jsonb_build_object('rfq_item_id', qi.rfq_item_id, 'unit_price', qi.unit_price,
                              'discount_percent', qi.discount_percent, 'tax_percent', qi.tax_percent, 'line_total', qi.line_total))
                              from vendorflow.quotation_items qi where qi.quotation_id = q.id))
                    from vendorflow.quotations q where q.rfq_id = a.rfq_id and q.vendor_id = a.vendor_id),
        'clarifications', coalesce((select jsonb_agg(jsonb_build_object('question', c.question, 'answer', c.answer, 'asked_at', c.asked_at)
                    order by c.asked_at) from vendorflow.rfq_clarifications c where c.rfq_id = a.rfq_id and c.vendor_id = a.vendor_id), '[]'::jsonb))
    into v
    from vendorflow.rfqs r
    join vendorflow.tenant_settings s on s.tenant_id = r.tenant_id
    join vendorflow.vendors vd on vd.id = a.vendor_id
    where r.id = a.rfq_id;
    return v;
end $$;

create or replace function vendorflow.fn_portal_submit_quotation(p_token_hash text, p_data jsonb)
returns jsonb language plpgsql as $$
declare a record;
begin
    select * into a from vendorflow.fn_portal_resolve(p_token_hash);
    perform vendorflow.fn_quotation_upsert(a.tenant_id, a.rfq_id, a.vendor_id, p_data, null);
    return vendorflow.fn_portal_get(p_token_hash);
end $$;

create or replace function vendorflow.fn_portal_ask(p_token_hash text, p_question text)
returns jsonb language plpgsql as $$
declare
    a record;
    r vendorflow.rfqs%rowtype;
begin
    select * into a from vendorflow.fn_portal_resolve(p_token_hash);
    if coalesce(btrim(p_question), '') = '' or char_length(p_question) > 1000 then
        raise exception 'Enter a question (up to 1000 characters).' using errcode = 'VF400';
    end if;
    select * into r from vendorflow.rfqs where id = a.rfq_id;
    if r.status <> 'Open' then raise exception 'This RFQ is not open.' using errcode = 'VF409'; end if;
    insert into vendorflow.rfq_clarifications (tenant_id, rfq_id, vendor_id, question) values (a.tenant_id, a.rfq_id, a.vendor_id, btrim(p_question));
    call vendorflow.sp_notify_user(a.tenant_id, r.created_by, 'rfq_clarification', 'RFQ clarification asked', r.number, 'rfq', r.id,
        'clar:' || r.id || ':' || a.vendor_id || ':' || extract(epoch from clock_timestamp())::bigint);
    return vendorflow.fn_portal_get(p_token_hash);
end $$;

create or replace function vendorflow.fn_portal_decline(p_token_hash text)
returns jsonb language plpgsql as $$
declare a record;
begin
    select * into a from vendorflow.fn_portal_resolve(p_token_hash);
    if exists (select 1 from vendorflow.quotations where rfq_id = a.rfq_id and vendor_id = a.vendor_id) then
        raise exception 'You have already submitted a quotation.' using errcode = 'VF409';
    end if;
    update vendorflow.rfq_vendors set status = 'Declined' where rfq_id = a.rfq_id and vendor_id = a.vendor_id;
    return vendorflow.fn_portal_get(p_token_hash);
end $$;

-- Queues a reminder e-mail (one per vendor per day) for invited vendors that have not answered yet. Returns how many were queued.
create or replace function vendorflow.fn_rfq_send_reminders(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns int language plpgsql as $$
declare
    r vendorflow.rfqs%rowtype;
    x record;
    n int := 0;
begin
    select * into r from vendorflow.rfqs where id = p_id and tenant_id = p_tenant_id;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status <> 'Open' then raise exception 'Reminders can only be sent for an open RFQ.' using errcode = 'VF409'; end if;

    for x in select v.id, v.name, v.email from vendorflow.rfq_vendors rv join vendorflow.vendors v on v.id = rv.vendor_id
             where rv.rfq_id = r.id and rv.status in ('Invited', 'Viewed') and coalesce(v.email, '') <> '' loop
        insert into vendorflow.email_outbox (tenant_id, to_email, subject, body, dedupe_key)
        values (p_tenant_id, x.email, 'Reminder: quotation requested for ' || r.number,
                'Dear ' || x.name || ', please submit your quotation for ' || r.title || ' before ' || coalesce(r.deadline::text, 'the deadline') || '.',
                'rfq-reminder:' || r.id || ':' || x.id || ':' || current_date)
        on conflict (tenant_id, dedupe_key) do nothing;
        if found then n := n + 1; end if;
    end loop;
    call vendorflow.sp_history(p_tenant_id, 'rfq', r.id, 'reminder_sent', r.status, r.status, n || ' vendor(s)', p_actor_id);
    return n;
end $$;
