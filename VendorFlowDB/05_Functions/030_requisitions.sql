-- Purchase requisitions: header + line items, submit into the approval engine.

create or replace function vendorflow.fn_requisition_get(p_tenant_id uuid, p_id uuid)
returns jsonb language plpgsql stable as $$
declare v jsonb;
begin
    select jsonb_build_object(
        'id', q.id, 'number', q.number, 'title', q.title, 'department_id', q.department_id, 'department_name', d.name,
        'cost_centre_id', q.cost_centre_id, 'cost_centre_code', c.code, 'required_date', q.required_date,
        'justification', q.justification, 'priority', q.priority, 'status', q.status, 'total_amount', q.total_amount,
        'requester_id', q.requester_id, 'requester_name', u.full_name, 'created_at', q.created_at, 'row_version', q.row_version,
        'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'line_no', i.line_no, 'description', i.description,
                    'unit', i.unit, 'quantity', i.quantity, 'est_unit_price', i.est_unit_price, 'line_total', i.line_total)
                    order by i.line_no) from vendorflow.requisition_items i where i.requisition_id = q.id), '[]'::jsonb),
        'attachments', vendorflow.fn_attachment_list(p_tenant_id, 'requisition', q.id),
        'approval', (select vendorflow.fn_approval_get(p_tenant_id, ar.id) from vendorflow.approval_requests ar
                     where ar.tenant_id = p_tenant_id and ar.entity_type = 'requisition' and ar.entity_id = q.id
                     order by ar.created_at desc limit 1),
        'history', vendorflow.fn_history_list(p_tenant_id, 'requisition', q.id))
    into v
    from vendorflow.requisitions q
    join vendorflow.users u on u.id = q.requester_id
    left join vendorflow.departments d on d.id = q.department_id
    left join vendorflow.cost_centres c on c.id = q.cost_centre_id
    where q.id = p_id and q.tenant_id = p_tenant_id;

    if v is null then raise exception 'Requisition not found.' using errcode = 'VF404'; end if;
    return v;
end $$;

create or replace function vendorflow.fn_requisition_list(
    p_tenant_id uuid, p_actor_id uuid, p_scope text default 'all', p_status text default null, p_search text default null,
    p_department_id uuid default null, p_date_from date default null, p_date_to date default null,
    p_sort_by text default null, p_sort_dir text default null, p_page int default 1, p_page_size int default 20)
returns jsonb language plpgsql stable as $$
declare
    v_page  int := greatest(coalesce(p_page, 1), 1);
    v_size  int := least(greatest(coalesce(p_page_size, 20), 1), 200);
    v_order text := vendorflow.fn_sort_clause(p_sort_by, p_sort_dir, array['number','title','required_date','total_amount','status','created_at'], 'created_at');
    v_where text := $w$ q.tenant_id = $1
        and ($2 <> 'mine' or q.requester_id = $3)
        and ($4 is null or $4 = '' or q.status = $4)
        and ($5 is null or $5 = '' or q.number ilike '%' || $5 || '%' or q.title ilike '%' || $5 || '%'
             or exists (select 1 from vendorflow.requisition_items i where i.requisition_id = q.id and i.description ilike '%' || $5 || '%'))
        and ($6 is null or q.department_id = $6)
        and ($7 is null or q.required_date >= $7) and ($8 is null or q.required_date <= $8) $w$;
    v_total bigint; v_items jsonb; v_counts jsonb;
begin
    execute 'select count(*) from vendorflow.requisitions q where ' || v_where into v_total
        using p_tenant_id, coalesce(p_scope, 'all'), p_actor_id, p_status, p_search, p_department_id, p_date_from, p_date_to;

    execute format($q$
        select coalesce(jsonb_agg(x), '[]'::jsonb) from (
            select jsonb_build_object('id', q.id, 'number', q.number, 'title', q.title,
                'department_name', (select name from vendorflow.departments where id = q.department_id),
                'cost_centre_code', (select code from vendorflow.cost_centres where id = q.cost_centre_id),
                'required_date', q.required_date, 'total_amount', q.total_amount, 'status', q.status, 'priority', q.priority,
                'requester_name', (select full_name from vendorflow.users where id = q.requester_id), 'created_at', q.created_at) as x
            from vendorflow.requisitions q where %s order by %s offset %s limit %s) s$q$,
        v_where, v_order, (v_page - 1) * v_size, v_size)
        into v_items using p_tenant_id, coalesce(p_scope, 'all'), p_actor_id, p_status, p_search, p_department_id, p_date_from, p_date_to;

    select coalesce(jsonb_object_agg(status, c), '{}'::jsonb) || jsonb_build_object('All', coalesce(sum(c), 0),
        'Mine', (select count(*) from vendorflow.requisitions where tenant_id = p_tenant_id and requester_id = p_actor_id))
    into v_counts from (select status, count(*) c from vendorflow.requisitions where tenant_id = p_tenant_id group by status) g;

    return vendorflow.fn_page(v_items, v_total, v_page, v_size) || jsonb_build_object('status_counts', v_counts);
end $$;

-- Creates (p_id null) or updates a requisition. Only the requester can edit, and only while Draft or ReturnedForModification.
create or replace function vendorflow.fn_requisition_save(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    cur vendorflow.requisitions%rowtype;
    v_id uuid := p_id;
    it jsonb;
    n int := 0;
    v_line numeric;
    v_total numeric := 0;
    v_dept uuid := nullif(p_data ->> 'department_id', '')::uuid;
    v_cc uuid := nullif(p_data ->> 'cost_centre_id', '')::uuid;
begin
    if coalesce(btrim(p_data ->> 'title'), '') = '' then raise exception 'Title is required.' using errcode = 'VF400'; end if;
    if v_dept is not null and not exists (select 1 from vendorflow.departments where id = v_dept and tenant_id = p_tenant_id) then
        raise exception 'Department not found.' using errcode = 'VF400';
    end if;
    if v_cc is not null and not exists (select 1 from vendorflow.cost_centres where id = v_cc and tenant_id = p_tenant_id) then
        raise exception 'Cost centre not found.' using errcode = 'VF400';
    end if;
    if p_data ? 'priority' and (p_data ->> 'priority') not in ('Low', 'Medium', 'High') then
        raise exception 'Priority must be Low, Medium or High.' using errcode = 'VF400';
    end if;

    if v_id is null then
        insert into vendorflow.requisitions (tenant_id, number, title, department_id, cost_centre_id, required_date, justification, priority, requester_id)
        values (p_tenant_id, vendorflow.fn_next_number(p_tenant_id, 'requisition'), btrim(p_data ->> 'title'), v_dept, v_cc,
                nullif(p_data ->> 'required_date', '')::date, p_data ->> 'justification', coalesce(p_data ->> 'priority', 'Medium'), p_actor_id)
        returning id into v_id;
        call vendorflow.sp_history(p_tenant_id, 'requisition', v_id, 'created', null, 'Draft', null, p_actor_id);
    else
        select * into cur from vendorflow.requisitions where id = v_id and tenant_id = p_tenant_id for update;
        if not found then raise exception 'Requisition not found.' using errcode = 'VF404'; end if;
        if cur.requester_id <> p_actor_id then raise exception 'Only the requester can edit this requisition.' using errcode = 'VF403'; end if;
        if cur.status not in ('Draft', 'ReturnedForModification') then
            raise exception 'A requisition that is % cannot be edited.', cur.status using errcode = 'VF409';
        end if;
        if p_data ? 'row_version' and (p_data ->> 'row_version')::int <> cur.row_version then
            raise exception 'This requisition was changed by someone else. Reload and try again.' using errcode = 'VF409';
        end if;
        update vendorflow.requisitions set title = btrim(p_data ->> 'title'), department_id = v_dept, cost_centre_id = v_cc,
            required_date = nullif(p_data ->> 'required_date', '')::date, justification = p_data ->> 'justification',
            priority = coalesce(p_data ->> 'priority', priority), updated_at = now(), row_version = row_version + 1
        where id = v_id;
        call vendorflow.sp_history(p_tenant_id, 'requisition', v_id, 'updated', cur.status, cur.status, null, p_actor_id);
    end if;

    if p_data ? 'items' then
        delete from vendorflow.requisition_items where requisition_id = v_id;
        for it in select * from jsonb_array_elements(p_data -> 'items') loop
            if coalesce(btrim(it ->> 'description'), '') = '' then raise exception 'Every item needs a description.' using errcode = 'VF400'; end if;
            if coalesce((it ->> 'quantity')::numeric, 0) <= 0 then raise exception 'Quantity must be greater than zero.' using errcode = 'VF400'; end if;
            if coalesce((it ->> 'est_unit_price')::numeric, -1) < 0 then raise exception 'Unit price cannot be negative.' using errcode = 'VF400'; end if;
            n := n + 1;
            v_line := round((it ->> 'quantity')::numeric * round((it ->> 'est_unit_price')::numeric, 2), 2);
            v_total := v_total + v_line;
            insert into vendorflow.requisition_items (tenant_id, requisition_id, line_no, description, unit, quantity, est_unit_price, line_total)
            values (p_tenant_id, v_id, n, btrim(it ->> 'description'), coalesce(nullif(it ->> 'unit', ''), 'Nos'),
                    (it ->> 'quantity')::numeric, round((it ->> 'est_unit_price')::numeric, 2), v_line);
        end loop;
        update vendorflow.requisitions set total_amount = v_total where id = v_id;
    end if;

    return vendorflow.fn_requisition_get(p_tenant_id, v_id);
end $$;

-- Submits a draft for approval: validates it and starts an approval request from the tenant's rules.
create or replace function vendorflow.fn_requisition_submit(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
declare
    cur vendorflow.requisitions%rowtype;
    v_req uuid;
begin
    select * into cur from vendorflow.requisitions where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Requisition not found.' using errcode = 'VF404'; end if;
    if cur.requester_id <> p_actor_id then raise exception 'Only the requester can submit this requisition.' using errcode = 'VF403'; end if;
    if cur.status not in ('Draft', 'ReturnedForModification') then
        raise exception 'A requisition that is % cannot be submitted.', cur.status using errcode = 'VF409';
    end if;
    if cur.department_id is null or cur.cost_centre_id is null or cur.required_date is null then
        raise exception 'Department, cost centre and required date are required before submitting.' using errcode = 'VF400';
    end if;
    if cur.required_date < current_date then raise exception 'Required date cannot be in the past.' using errcode = 'VF400'; end if;
    if not exists (select 1 from vendorflow.requisition_items where requisition_id = cur.id) or cur.total_amount <= 0 then
        raise exception 'Add at least one line item with a price before submitting.' using errcode = 'VF400';
    end if;

    update vendorflow.requisitions set status = 'PendingApproval', updated_at = now(), row_version = row_version + 1 where id = cur.id;
    v_req := vendorflow.fn_approval_start(p_tenant_id, 'requisition', cur.id, cur.number || ' · ' || cur.title,
                                          cur.total_amount, p_actor_id, cur.department_id);
    call vendorflow.sp_history(p_tenant_id, 'requisition', cur.id, 'submitted', cur.status, 'PendingApproval', null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'requisition.submitted', 'requisition', cur.id, jsonb_build_object('approval_request_id', v_req));
    return vendorflow.fn_requisition_get(p_tenant_id, cur.id);
end $$;

-- Cancels a requisition (requester, or someone allowed to manage approvals). Not possible once converted to a PO.
create or replace function vendorflow.fn_requisition_cancel(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_comment text, p_override boolean)
returns jsonb language plpgsql as $$
declare cur vendorflow.requisitions%rowtype;
begin
    select * into cur from vendorflow.requisitions where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Requisition not found.' using errcode = 'VF404'; end if;
    if cur.requester_id <> p_actor_id and not coalesce(p_override, false) then
        raise exception 'Only the requester can cancel this requisition.' using errcode = 'VF403';
    end if;
    if cur.status in ('ConvertedToPO', 'Cancelled', 'Rejected') then
        raise exception 'A requisition that is % cannot be cancelled.', cur.status using errcode = 'VF409';
    end if;
    if coalesce(btrim(p_comment), '') = '' then raise exception 'A reason is required.' using errcode = 'VF400'; end if;

    update vendorflow.requisitions set status = 'Cancelled', updated_at = now(), row_version = row_version + 1 where id = cur.id;
    update vendorflow.approval_requests set status = 'Cancelled', completed_at = now(), row_version = row_version + 1
    where tenant_id = p_tenant_id and entity_type = 'requisition' and entity_id = cur.id and status = 'Pending';
    call vendorflow.sp_history(p_tenant_id, 'requisition', cur.id, 'cancelled', cur.status, 'Cancelled', p_comment, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'requisition.cancelled', 'requisition', cur.id, null);
    return vendorflow.fn_requisition_get(p_tenant_id, cur.id);
end $$;
