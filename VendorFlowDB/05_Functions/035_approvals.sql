-- Approval workflow engine: rules, requests, decisions, delegation, inbox.

-- Can this user act on a step with the given role? (owner = universal; DepartmentManager is limited to the department's manager when one is set)
create or replace function vendorflow.fn_step_direct_ok(p_tenant_id uuid, p_user_id uuid, p_role_code text, p_department_id uuid)
returns boolean language plpgsql stable as $$
declare v_mgr uuid;
begin
    if not exists (select 1 from vendorflow.users where id = p_user_id and tenant_id = p_tenant_id and status = 'Active') then
        return false;
    end if;
    if exists (select 1 from vendorflow.user_roles ur join vendorflow.roles r on r.id = ur.role_id
               where ur.user_id = p_user_id and r.code = 'OrganizationOwner') then
        return true;
    end if;
    if not exists (select 1 from vendorflow.user_roles ur join vendorflow.roles r on r.id = ur.role_id
                   where ur.user_id = p_user_id and r.code = p_role_code) then
        return false;
    end if;
    if p_role_code = 'DepartmentManager' and p_department_id is not null then
        select manager_user_id into v_mgr from vendorflow.departments where id = p_department_id and tenant_id = p_tenant_id;
        if v_mgr is not null and v_mgr <> p_user_id then return false; end if;
    end if;
    return true;
end $$;

-- Returns the user the actor acts for: the actor itself (direct), the delegator (delegated), or null (not allowed).
create or replace function vendorflow.fn_step_eligibility(p_tenant_id uuid, p_user_id uuid, p_request_id uuid)
returns uuid language plpgsql stable as $$
declare
    r vendorflow.approval_requests%rowtype;
    s vendorflow.approval_steps%rowtype;
    v_from uuid;
begin
    select * into r from vendorflow.approval_requests where id = p_request_id and tenant_id = p_tenant_id and status = 'Pending';
    if not found then return null; end if;
    select * into s from vendorflow.approval_steps where request_id = r.id and step_no = r.current_step and status = 'Pending';
    if not found then return null; end if;

    if vendorflow.fn_step_direct_ok(p_tenant_id, p_user_id, s.role_code, r.department_id) then return p_user_id; end if;

    select d.from_user_id into v_from from vendorflow.delegations d
    where d.tenant_id = p_tenant_id and d.to_user_id = p_user_id and d.active
      and current_date between d.start_date and d.end_date
      and vendorflow.fn_step_direct_ok(p_tenant_id, d.from_user_id, s.role_code, r.department_id)
    limit 1;
    return v_from;
end $$;

-- Tells the approvers of the request's current step that something is waiting.
create or replace procedure vendorflow.sp_approval_notify_step(p_request_id uuid)
language plpgsql as $$
declare
    r vendorflow.approval_requests%rowtype;
    s vendorflow.approval_steps%rowtype;
    v_mgr uuid;
    u record;
begin
    select * into r from vendorflow.approval_requests where id = p_request_id;
    select * into s from vendorflow.approval_steps where request_id = r.id and step_no = r.current_step;
    if r.department_id is not null and s.role_code = 'DepartmentManager' then
        select manager_user_id into v_mgr from vendorflow.departments where id = r.department_id;
    end if;
    if v_mgr is not null then
        call vendorflow.sp_notify_user(r.tenant_id, v_mgr, 'approval_needed', 'Approval needed', r.title, r.entity_type, r.entity_id,
            'approval:' || r.id || ':' || r.current_step || ':' || r.row_version);
    else
        for u in select distinct us.id from vendorflow.users us
                 join vendorflow.user_roles ur on ur.user_id = us.id join vendorflow.roles ro on ro.id = ur.role_id
                 where us.tenant_id = r.tenant_id and us.status = 'Active' and ro.code = s.role_code and us.id <> r.requested_by
        loop
            call vendorflow.sp_notify_user(r.tenant_id, u.id, 'approval_needed', 'Approval needed', r.title, r.entity_type, r.entity_id,
                'approval:' || r.id || ':' || r.current_step || ':' || r.row_version);
        end loop;
    end if;
end $$;

-- Starts an approval request using the best matching tenant rule. Without a rule a single Dept Manager step is used.
create or replace function vendorflow.fn_approval_start(
    p_tenant_id uuid, p_entity_type text, p_entity_id uuid, p_title text, p_amount numeric,
    p_requested_by uuid, p_department_id uuid)
returns uuid language plpgsql as $$
declare
    v_rule uuid;
    v_req uuid;
    v_steps int;
begin
    select ar.id into v_rule from vendorflow.approval_rules ar
    where ar.tenant_id = p_tenant_id and ar.entity_type = p_entity_type and ar.active
      and p_amount >= ar.min_amount and (ar.max_amount is null or p_amount <= ar.max_amount)
      and (ar.department_id is null or ar.department_id = p_department_id)
    order by (ar.department_id is not null) desc, ar.priority desc, ar.min_amount desc limit 1;

    if v_rule is not null then
        select count(*) into v_steps from vendorflow.approval_rule_steps where rule_id = v_rule;
    end if;
    if v_rule is null or coalesce(v_steps, 0) = 0 then v_steps := 1; end if;

    insert into vendorflow.approval_requests (tenant_id, entity_type, entity_id, title, amount, requested_by, department_id, total_steps)
    values (p_tenant_id, p_entity_type, p_entity_id, p_title, p_amount, p_requested_by, p_department_id, v_steps)
    returning id into v_req;

    if v_rule is not null and exists (select 1 from vendorflow.approval_rule_steps where rule_id = v_rule) then
        insert into vendorflow.approval_steps (tenant_id, request_id, step_no, name, role_code, status)
        select p_tenant_id, v_req, s.step_no, s.name, s.role_code, case when s.step_no = 1 then 'Pending' else 'Waiting' end
        from vendorflow.approval_rule_steps s where s.rule_id = v_rule order by s.step_no;
        -- renumber from 1 in case rule steps were not contiguous
        update vendorflow.approval_steps t set step_no = x.rn
        from (select id, row_number() over (order by step_no) rn from vendorflow.approval_steps where request_id = v_req) x
        where t.id = x.id and t.step_no <> x.rn;
    else
        insert into vendorflow.approval_steps (tenant_id, request_id, step_no, name, role_code, status)
        values (p_tenant_id, v_req, 1, 'Dept Manager', 'DepartmentManager', 'Pending');
    end if;

    call vendorflow.sp_approval_notify_step(v_req);
    return v_req;
end $$;

create or replace function vendorflow.fn_approval_get(p_tenant_id uuid, p_request_id uuid)
returns jsonb language sql stable as $$
    select jsonb_build_object('id', r.id, 'entity_type', r.entity_type, 'entity_id', r.entity_id, 'title', r.title,
        'amount', r.amount, 'status', r.status, 'current_step', r.current_step, 'total_steps', r.total_steps,
        'row_version', r.row_version, 'created_at', r.created_at, 'completed_at', r.completed_at,
        'requested_by_name', u.full_name,
        'steps', coalesce((select jsonb_agg(jsonb_build_object('step_no', s.step_no, 'name', s.name, 'role_code', s.role_code,
                    'status', s.status, 'decided_by_name', d.full_name, 'acting_for_name', a.full_name,
                    'decided_at', s.decided_at, 'comment', s.comment) order by s.step_no)
                  from vendorflow.approval_steps s
                  left join vendorflow.users d on d.id = s.decided_by
                  left join vendorflow.users a on a.id = s.acting_for
                  where s.request_id = r.id), '[]'::jsonb))
    from vendorflow.approval_requests r join vendorflow.users u on u.id = r.requested_by
    where r.id = p_request_id and r.tenant_id = p_tenant_id;
$$;

-- Applies the final result of an approval to the document it belongs to.
create or replace procedure vendorflow.sp_approval_apply_result(
    p_tenant_id uuid, p_entity_type text, p_entity_id uuid, p_result text, p_actor_id uuid, p_comment text)
language plpgsql as $$
declare
    v_new text;
    v_old text;
    v_owner uuid;
    v_label text;
begin
    if p_entity_type = 'requisition' then
        v_new := case p_result when 'Approved' then 'Approved' when 'Rejected' then 'Rejected' else 'ReturnedForModification' end;
        select status, requester_id, number into v_old, v_owner, v_label from vendorflow.requisitions
        where id = p_entity_id and tenant_id = p_tenant_id for update;
        update vendorflow.requisitions set status = v_new, updated_at = now(), row_version = row_version + 1 where id = p_entity_id;
    elsif p_entity_type = 'purchase_order' then
        v_new := case p_result when 'Approved' then 'Approved' when 'Rejected' then 'Rejected' else 'Draft' end;
        select status, created_by, number into v_old, v_owner, v_label from vendorflow.purchase_orders
        where id = p_entity_id and tenant_id = p_tenant_id for update;
        update vendorflow.purchase_orders set status = v_new, updated_at = now(), row_version = row_version + 1 where id = p_entity_id;
    else
        raise exception 'Unknown approval entity %', p_entity_type using errcode = 'VF400';
    end if;

    call vendorflow.sp_history(p_tenant_id, p_entity_type, p_entity_id, 'approval_' || lower(p_result), v_old, v_new, p_comment, p_actor_id);
    call vendorflow.sp_notify_user(p_tenant_id, v_owner, 'approval_result', v_label || ' ' || lower(p_result), p_comment,
        p_entity_type, p_entity_id, 'result:' || p_entity_id || ':' || v_new || ':' || extract(epoch from now())::bigint);
end $$;

-- Approve / reject / return the current step. Protects against double clicks (row_version) and self approval.
create or replace function vendorflow.fn_approval_decide(
    p_tenant_id uuid, p_actor_id uuid, p_request_id uuid, p_decision text, p_comment text, p_expected_version int)
returns jsonb language plpgsql as $$
declare
    r vendorflow.approval_requests%rowtype;
    v_allow_self boolean;
    v_for uuid;
    v_step_status text;
begin
    if p_decision not in ('approve', 'reject', 'return') then
        raise exception 'Decision must be approve, reject or return.' using errcode = 'VF400';
    end if;

    select * into r from vendorflow.approval_requests where id = p_request_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Approval request not found.' using errcode = 'VF404'; end if;
    if r.status <> 'Pending' then raise exception 'This request has already been decided.' using errcode = 'VF409'; end if;
    if p_expected_version is not null and p_expected_version <> r.row_version then
        raise exception 'This request changed since you opened it. Reload and try again.' using errcode = 'VF409';
    end if;
    if p_decision in ('reject', 'return') and coalesce(btrim(p_comment), '') = '' then
        raise exception 'A comment is required.' using errcode = 'VF400';
    end if;

    select allow_self_approval into v_allow_self from vendorflow.tenant_settings where tenant_id = p_tenant_id;
    if r.requested_by = p_actor_id and not coalesce(v_allow_self, false) then
        raise exception 'You cannot decide your own request.' using errcode = 'VF403';
    end if;

    v_for := vendorflow.fn_step_eligibility(p_tenant_id, p_actor_id, p_request_id);
    if v_for is null then raise exception 'You are not an approver for this step.' using errcode = 'VF403'; end if;
    if v_for = r.requested_by and not coalesce(v_allow_self, false) then
        raise exception 'You cannot decide your own request.' using errcode = 'VF403';
    end if;
    if not coalesce(v_allow_self, false) and exists (
        select 1 from vendorflow.approval_steps where request_id = r.id and decided_by = p_actor_id and status = 'Approved') then
        raise exception 'The same person cannot approve two steps of one request.' using errcode = 'VF403';
    end if;

    v_step_status := case p_decision when 'approve' then 'Approved' when 'reject' then 'Rejected' else 'Returned' end;
    update vendorflow.approval_steps set status = v_step_status, decided_by = p_actor_id, decided_at = now(),
        comment = p_comment, acting_for = case when v_for <> p_actor_id then v_for end
    where request_id = r.id and step_no = r.current_step;

    if p_decision = 'approve' and r.current_step < r.total_steps then
        update vendorflow.approval_steps set status = 'Pending' where request_id = r.id and step_no = r.current_step + 1;
        update vendorflow.approval_requests set current_step = current_step + 1, row_version = row_version + 1 where id = r.id;
        call vendorflow.sp_approval_notify_step(r.id);
    else
        update vendorflow.approval_requests set
            status = case p_decision when 'approve' then 'Approved' when 'reject' then 'Rejected' else 'Returned' end,
            completed_at = now(), row_version = row_version + 1
        where id = r.id;
        call vendorflow.sp_approval_apply_result(p_tenant_id, r.entity_type, r.entity_id,
            case p_decision when 'approve' then 'Approved' when 'reject' then 'Rejected' else 'Returned' end, p_actor_id, p_comment);
    end if;

    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'approval.' || p_decision, r.entity_type, r.entity_id,
        jsonb_build_object('request_id', r.id, 'step', r.current_step, 'acting_for', case when v_for <> p_actor_id then v_for end));
    return vendorflow.fn_approval_get(p_tenant_id, r.id);
end $$;

-- Approval inbox for a user. p_tab: pending | approved | rejected | delegated.
create or replace function vendorflow.fn_approval_inbox(
    p_tenant_id uuid, p_user_id uuid, p_tab text default 'pending', p_sort text default 'oldest', p_page int default 1, p_page_size int default 20)
returns jsonb language plpgsql stable as $$
declare
    v_page int := greatest(coalesce(p_page, 1), 1);
    v_size int := least(greatest(coalesce(p_page_size, 20), 1), 100);
    v_allow_self boolean;
    v_ids uuid[];
    v_pending_ids uuid[];
    v_total bigint;
    v_items jsonb;
    v_counts jsonb;
    v_stats jsonb;
begin
    select allow_self_approval into v_allow_self from vendorflow.tenant_settings where tenant_id = p_tenant_id;

    -- Pending requests this user can act on (directly or through delegation); own requests are hidden unless self approval is allowed.
    select coalesce(array_agg(r.id), '{}') into v_pending_ids from vendorflow.approval_requests r
    where r.tenant_id = p_tenant_id and r.status = 'Pending'
      and (coalesce(v_allow_self, false) or r.requested_by <> p_user_id)
      and vendorflow.fn_step_eligibility(p_tenant_id, p_user_id, r.id) is not null;

    v_ids := case coalesce(p_tab, 'pending')
        when 'approved' then (select coalesce(array_agg(distinct s.request_id), '{}') from vendorflow.approval_steps s
                              where s.tenant_id = p_tenant_id and s.decided_by = p_user_id and s.status = 'Approved')
        when 'rejected' then (select coalesce(array_agg(distinct s.request_id), '{}') from vendorflow.approval_steps s
                              where s.tenant_id = p_tenant_id and s.decided_by = p_user_id and s.status in ('Rejected', 'Returned'))
        when 'delegated' then (select coalesce(array_agg(distinct s.request_id), '{}') from vendorflow.approval_steps s
                               where s.tenant_id = p_tenant_id and s.decided_by = p_user_id and s.acting_for is not null)
        else v_pending_ids end;

    v_total := coalesce(array_length(v_ids, 1), 0);

    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_items from (
        select jsonb_build_object(
            'id', r.id, 'entity_type', r.entity_type, 'entity_id', r.entity_id,
            'number', case r.entity_type
                        when 'requisition' then (select q.number from vendorflow.requisitions q where q.id = r.entity_id)
                        else (select po.number from vendorflow.purchase_orders po where po.id = r.entity_id) end,
            'title', r.title, 'amount', r.amount, 'status', r.status,
            'requested_by_name', u.full_name, 'department_name', d.name,
            'priority', coalesce((select q.priority from vendorflow.requisitions q where q.id = r.entity_id and r.entity_type = 'requisition'), 'Medium'),
            'waiting_days', floor(extract(epoch from now() - coalesce(
                (select max(s.decided_at) from vendorflow.approval_steps s where s.request_id = r.id and s.status = 'Approved'), r.created_at)) / 86400),
            'current_step', r.current_step, 'total_steps', r.total_steps, 'row_version', r.row_version, 'created_at', r.created_at,
            'steps', (select jsonb_agg(jsonb_build_object('step_no', s.step_no, 'name', s.name, 'status', s.status,
                          'decided_by_name', du.full_name) order by s.step_no)
                      from vendorflow.approval_steps s left join vendorflow.users du on du.id = s.decided_by where s.request_id = r.id)
        ) as x
        from vendorflow.approval_requests r
        join vendorflow.users u on u.id = r.requested_by
        left join vendorflow.departments d on d.id = r.department_id
        where r.id = any(v_ids) and r.tenant_id = p_tenant_id
        order by case when p_sort = 'amount' then r.amount end desc nulls last,
                 case when p_sort = 'newest' then r.created_at end desc nulls last,
                 r.created_at asc
        offset (v_page - 1) * v_size limit v_size) q;

    v_counts := jsonb_build_object(
        'pending', coalesce(array_length(v_pending_ids, 1), 0),
        'approved', (select count(distinct s.request_id) from vendorflow.approval_steps s where s.tenant_id = p_tenant_id and s.decided_by = p_user_id and s.status = 'Approved'),
        'rejected', (select count(distinct s.request_id) from vendorflow.approval_steps s where s.tenant_id = p_tenant_id and s.decided_by = p_user_id and s.status in ('Rejected', 'Returned')),
        'delegated', (select count(distinct s.request_id) from vendorflow.approval_steps s where s.tenant_id = p_tenant_id and s.decided_by = p_user_id and s.acting_for is not null));

    v_stats := jsonb_build_object(
        'pending_value', coalesce((select sum(r.amount) from vendorflow.approval_requests r where r.id = any(v_pending_ids)), 0),
        'average_wait_days', coalesce((select round(avg(extract(epoch from now() - r.created_at) / 86400)::numeric, 1)
                                       from vendorflow.approval_requests r where r.id = any(v_pending_ids)), 0),
        'decided_this_week', (select count(*) from vendorflow.approval_steps s
                              where s.tenant_id = p_tenant_id and s.decided_by = p_user_id and s.decided_at > now() - interval '7 days'));

    return vendorflow.fn_page(v_items, v_total, v_page, v_size) || jsonb_build_object('counts', v_counts, 'stats', v_stats);
end $$;

create or replace function vendorflow.fn_approval_pending_count(p_tenant_id uuid, p_user_id uuid)
returns int language sql stable as $$
    select (vendorflow.fn_approval_inbox(p_tenant_id, p_user_id, 'pending', 'oldest', 1, 1) -> 'counts' ->> 'pending')::int;
$$;

-- ---------------------------------------------------------------- rules

create or replace function vendorflow.fn_approval_rule_list(p_tenant_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'entity_type', r.entity_type,
        'min_amount', r.min_amount, 'max_amount', r.max_amount, 'department_id', r.department_id, 'department_name', d.name,
        'priority', r.priority, 'active', r.active,
        'steps', coalesce((select jsonb_agg(jsonb_build_object('step_no', s.step_no, 'name', s.name, 'role_code', s.role_code) order by s.step_no)
                           from vendorflow.approval_rule_steps s where s.rule_id = r.id), '[]'::jsonb))
        order by r.entity_type, r.min_amount), '[]'::jsonb)
    from vendorflow.approval_rules r left join vendorflow.departments d on d.id = r.department_id
    where r.tenant_id = p_tenant_id;
$$;

create or replace function vendorflow.fn_approval_rule_save(p_tenant_id uuid, p_actor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    v_id uuid := nullif(p_data ->> 'id', '')::uuid;
    v_step jsonb;
    v_no int := 0;
begin
    if coalesce(btrim(p_data ->> 'name'), '') = '' then raise exception 'Rule name is required.' using errcode = 'VF400'; end if;
    if (p_data ->> 'entity_type') not in ('requisition', 'purchase_order') then
        raise exception 'entity_type must be requisition or purchase_order.' using errcode = 'VF400';
    end if;
    if coalesce((p_data ->> 'min_amount')::numeric, 0) < 0
       or (nullif(p_data ->> 'max_amount', '') is not null and (p_data ->> 'max_amount')::numeric < coalesce((p_data ->> 'min_amount')::numeric, 0)) then
        raise exception 'Amount range is invalid.' using errcode = 'VF400';
    end if;
    if jsonb_typeof(p_data -> 'steps') is distinct from 'array' or jsonb_array_length(p_data -> 'steps') = 0 then
        raise exception 'At least one approval step is required.' using errcode = 'VF400';
    end if;
    for v_step in select * from jsonb_array_elements(p_data -> 'steps') loop
        if not exists (select 1 from vendorflow.roles where code = v_step ->> 'role_code'
                       and code not in ('PlatformAdministrator', 'VendorPortalUser')) then
            raise exception 'Unknown role in approval step.' using errcode = 'VF400';
        end if;
    end loop;
    if nullif(p_data ->> 'department_id', '') is not null and not exists (
        select 1 from vendorflow.departments where id = (p_data ->> 'department_id')::uuid and tenant_id = p_tenant_id) then
        raise exception 'Department not found.' using errcode = 'VF400';
    end if;

    if v_id is null then
        insert into vendorflow.approval_rules (tenant_id, name, entity_type, min_amount, max_amount, department_id, priority, active)
        values (p_tenant_id, btrim(p_data ->> 'name'), p_data ->> 'entity_type', coalesce((p_data ->> 'min_amount')::numeric, 0),
                nullif(p_data ->> 'max_amount', '')::numeric, nullif(p_data ->> 'department_id', '')::uuid,
                coalesce((p_data ->> 'priority')::int, 0), coalesce((p_data ->> 'active')::boolean, true))
        returning id into v_id;
    else
        update vendorflow.approval_rules set name = btrim(p_data ->> 'name'), entity_type = p_data ->> 'entity_type',
            min_amount = coalesce((p_data ->> 'min_amount')::numeric, 0), max_amount = nullif(p_data ->> 'max_amount', '')::numeric,
            department_id = nullif(p_data ->> 'department_id', '')::uuid, priority = coalesce((p_data ->> 'priority')::int, 0),
            active = coalesce((p_data ->> 'active')::boolean, true)
        where id = v_id and tenant_id = p_tenant_id;
        if not found then raise exception 'Rule not found.' using errcode = 'VF404'; end if;
        delete from vendorflow.approval_rule_steps where rule_id = v_id;
    end if;

    for v_step in select * from jsonb_array_elements(p_data -> 'steps') loop
        v_no := v_no + 1;
        insert into vendorflow.approval_rule_steps (rule_id, step_no, name, role_code)
        values (v_id, v_no, coalesce(nullif(btrim(v_step ->> 'name'), ''), v_step ->> 'role_code'), v_step ->> 'role_code');
    end loop;

    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'approval_rule.saved', 'approval_rule', v_id, null);
    return vendorflow.fn_approval_rule_list(p_tenant_id);
end $$;

create or replace function vendorflow.fn_approval_rule_delete(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
begin
    delete from vendorflow.approval_rules where id = p_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Rule not found.' using errcode = 'VF404'; end if;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'approval_rule.deleted', 'approval_rule', p_id, null);
    return vendorflow.fn_approval_rule_list(p_tenant_id);
end $$;

-- ---------------------------------------------------------------- delegation and department managers

create or replace function vendorflow.fn_delegation_list(p_tenant_id uuid, p_user_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'from_user_id', d.from_user_id, 'from_name', f.full_name,
        'to_user_id', d.to_user_id, 'to_name', t.full_name, 'start_date', d.start_date, 'end_date', d.end_date,
        'reason', d.reason, 'active', d.active, 'direction', case when d.from_user_id = p_user_id then 'outgoing' else 'incoming' end)
        order by d.start_date desc), '[]'::jsonb)
    from vendorflow.delegations d
    join vendorflow.users f on f.id = d.from_user_id join vendorflow.users t on t.id = d.to_user_id
    where d.tenant_id = p_tenant_id and (d.from_user_id = p_user_id or d.to_user_id = p_user_id);
$$;

create or replace function vendorflow.fn_delegation_save(p_tenant_id uuid, p_actor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare v_to uuid := (p_data ->> 'to_user_id')::uuid;
begin
    if v_to = p_actor_id then raise exception 'You cannot delegate to yourself.' using errcode = 'VF400'; end if;
    if not exists (select 1 from vendorflow.users where id = v_to and tenant_id = p_tenant_id and status = 'Active') then
        raise exception 'Delegate user not found.' using errcode = 'VF404';
    end if;
    if (p_data ->> 'end_date')::date < (p_data ->> 'start_date')::date then
        raise exception 'End date must be on or after the start date.' using errcode = 'VF400';
    end if;
    insert into vendorflow.delegations (tenant_id, from_user_id, to_user_id, start_date, end_date, reason)
    values (p_tenant_id, p_actor_id, v_to, (p_data ->> 'start_date')::date, (p_data ->> 'end_date')::date, p_data ->> 'reason');
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'delegation.created', 'user', v_to, p_data);
    return vendorflow.fn_delegation_list(p_tenant_id, p_actor_id);
end $$;

create or replace function vendorflow.fn_delegation_cancel(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
begin
    update vendorflow.delegations set active = false where id = p_id and tenant_id = p_tenant_id and from_user_id = p_actor_id;
    if not found then raise exception 'Delegation not found.' using errcode = 'VF404'; end if;
    return vendorflow.fn_delegation_list(p_tenant_id, p_actor_id);
end $$;

create or replace function vendorflow.fn_department_list(p_tenant_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'manager_user_id', d.manager_user_id,
        'manager_name', u.full_name) order by d.name), '[]'::jsonb)
    from vendorflow.departments d left join vendorflow.users u on u.id = d.manager_user_id where d.tenant_id = p_tenant_id;
$$;

create or replace function vendorflow.fn_department_set_manager(p_tenant_id uuid, p_actor_id uuid, p_department_id uuid, p_user_id uuid)
returns jsonb language plpgsql as $$
begin
    if p_user_id is not null and not exists (
        select 1 from vendorflow.users u join vendorflow.user_roles ur on ur.user_id = u.id join vendorflow.roles r on r.id = ur.role_id
        where u.id = p_user_id and u.tenant_id = p_tenant_id and r.code = 'DepartmentManager') then
        raise exception 'The manager must be an active user with the Department Manager role.' using errcode = 'VF400';
    end if;
    update vendorflow.departments set manager_user_id = p_user_id where id = p_department_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Department not found.' using errcode = 'VF404'; end if;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'department.manager_set', 'department', p_department_id, jsonb_build_object('user_id', p_user_id));
    return vendorflow.fn_department_list(p_tenant_id);
end $$;
