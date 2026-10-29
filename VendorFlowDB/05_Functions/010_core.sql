-- Core helpers shared by all modules. Idempotent (create or replace).

-- Health probe used by the /health endpoint.
create or replace function vendorflow.fn_health()
returns boolean language sql stable as $$ select true; $$;

-- Builds the next document number for a tenant, e.g. PO-2026-0001, using the tenant's numbering pattern.
create or replace function vendorflow.fn_next_number(p_tenant_id uuid, p_doc_type text)
returns text language plpgsql as $$
declare
    v_pattern text;
    v_period  int;
    v_next    bigint;
    v_zeros   text;
    v_result  text;
begin
    select numbering ->> p_doc_type into v_pattern
    from vendorflow.tenant_settings where tenant_id = p_tenant_id;
    if v_pattern is null then
        raise exception 'No numbering pattern for %', p_doc_type using errcode = 'VF400';
    end if;

    v_period := case when v_pattern like '%{YYYY}%' then extract(year from now() at time zone 'utc')::int else 0 end;

    insert into vendorflow.numbering_sequences (tenant_id, doc_type, period, last_number)
    values (p_tenant_id, p_doc_type, v_period, 1)
    on conflict (tenant_id, doc_type, period)
    do update set last_number = vendorflow.numbering_sequences.last_number + 1
    returning last_number into v_next;

    v_zeros := substring(v_pattern from '\{(0+)\}');
    v_result := replace(v_pattern, '{YYYY}', v_period::text);
    if v_zeros is not null then
        v_result := replace(v_result, '{' || v_zeros || '}', lpad(v_next::text, char_length(v_zeros), '0'));
    else
        v_result := v_result || v_next::text;
    end if;
    return v_result;
end $$;

-- Writes an audit event.
create or replace procedure vendorflow.sp_audit(
    p_tenant_id uuid, p_user_id uuid, p_action text,
    p_entity_type text default null, p_entity_id uuid default null, p_details jsonb default null)
language sql as $$
    insert into vendorflow.audit_events (tenant_id, user_id, action, entity_type, entity_id, details)
    values (p_tenant_id, p_user_id, p_action, p_entity_type, p_entity_id, p_details);
$$;

-- Writes a document history row (status changes, comments).
create or replace procedure vendorflow.sp_history(
    p_tenant_id uuid, p_entity_type text, p_entity_id uuid, p_action text,
    p_from text, p_to text, p_comment text, p_user_id uuid)
language sql as $$
    insert into vendorflow.entity_history (tenant_id, entity_type, entity_id, action, from_status, to_status, comment, user_id)
    values (p_tenant_id, p_entity_type, p_entity_id, p_action, p_from, p_to, p_comment, p_user_id);
$$;

-- Lists history of one document (tenant scoped).
create or replace function vendorflow.fn_history_list(p_tenant_id uuid, p_entity_type text, p_entity_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object(
        'action', h.action, 'fromStatus', h.from_status, 'toStatus', h.to_status,
        'comment', h.comment, 'userName', u.full_name, 'createdAt', h.created_at
    ) order by h.created_at, h.id), '[]'::jsonb)
    from vendorflow.entity_history h
    left join vendorflow.users u on u.id = h.user_id
    where h.tenant_id = p_tenant_id and h.entity_type = p_entity_type and h.entity_id = p_entity_id;
$$;

-- Standard paging envelope helper: wraps items and total into {items,totalCount,page,pageSize}.
create or replace function vendorflow.fn_page(p_items jsonb, p_total bigint, p_page int, p_page_size int)
returns jsonb language sql immutable as $$
    select jsonb_build_object('items', coalesce(p_items, '[]'::jsonb), 'totalCount', p_total,
                              'page', p_page, 'pageSize', p_page_size);
$$;
