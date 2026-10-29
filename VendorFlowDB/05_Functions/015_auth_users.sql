-- Tenant onboarding, authentication and user management functions.

-- Creates default departments, cost centres and approval rules for a new tenant.
create or replace procedure vendorflow.sp_seed_tenant_defaults(p_tenant_id uuid)
language plpgsql as $$
declare
    v_rule uuid;
begin
    insert into vendorflow.departments (tenant_id, name) values
        (p_tenant_id, 'IT'), (p_tenant_id, 'Operations'), (p_tenant_id, 'Admin'), (p_tenant_id, 'Marketing'),
        (p_tenant_id, 'HR'), (p_tenant_id, 'Finance'), (p_tenant_id, 'Site Operations');

    insert into vendorflow.cost_centres (tenant_id, code, name, department_id)
    select p_tenant_id, c.code, c.name, d.id
    from (values ('CC-IT-01','IT general','IT'), ('CC-OPS-01','Operations general','Operations'),
                 ('CC-OPS-04','Site safety','Site Operations'), ('CC-ADM-01','Admin AMC','Admin'),
                 ('CC-ADM-02','Admin consumables','Admin'), ('CC-MKT-01','Marketing','Marketing'),
                 ('CC-HR-01','HR','HR'), ('CC-FIN-01','Finance','Finance')) as c(code, name, dept)
    join vendorflow.departments d on d.tenant_id = p_tenant_id and d.name = c.dept;

    -- Requisition rules (example thresholds, editable per tenant).
    insert into vendorflow.approval_rules (tenant_id, name, entity_type, min_amount, max_amount, priority)
    values (p_tenant_id, 'Requisition up to 1,00,000', 'requisition', 0, 100000, 10) returning id into v_rule;
    insert into vendorflow.approval_rule_steps (rule_id, step_no, name, role_code)
    values (v_rule, 1, 'Dept Manager', 'DepartmentManager');

    insert into vendorflow.approval_rules (tenant_id, name, entity_type, min_amount, max_amount, priority)
    values (p_tenant_id, 'Requisition above 1,00,000', 'requisition', 100000.01, null, 10) returning id into v_rule;
    insert into vendorflow.approval_rule_steps (rule_id, step_no, name, role_code)
    values (v_rule, 1, 'Dept Manager', 'DepartmentManager'), (v_rule, 2, 'Finance', 'FinanceManager');

    -- Purchase order rules.
    insert into vendorflow.approval_rules (tenant_id, name, entity_type, min_amount, max_amount, priority)
    values (p_tenant_id, 'PO up to 5,00,000', 'purchase_order', 0, 500000, 10) returning id into v_rule;
    insert into vendorflow.approval_rule_steps (rule_id, step_no, name, role_code)
    values (v_rule, 1, 'Procurement Manager', 'ProcurementManager');

    insert into vendorflow.approval_rules (tenant_id, name, entity_type, min_amount, max_amount, priority)
    values (p_tenant_id, 'PO above 5,00,000', 'purchase_order', 500000.01, null, 10) returning id into v_rule;
    insert into vendorflow.approval_rule_steps (rule_id, step_no, name, role_code)
    values (v_rule, 1, 'Procurement Manager', 'ProcurementManager'), (v_rule, 2, 'Finance', 'FinanceManager');
end $$;

-- Registers a new organization with its first user (Organization Owner).
create or replace function vendorflow.fn_register_organization(
    p_org_name text, p_full_name text, p_email text, p_password_hash text)
returns jsonb language plpgsql as $$
declare
    v_tenant uuid;
    v_user   uuid;
begin
    if coalesce(btrim(p_org_name), '') = '' or coalesce(btrim(p_full_name), '') = '' or coalesce(btrim(p_email), '') = '' then
        raise exception 'Organization name, full name and email are required.' using errcode = 'VF400';
    end if;
    if exists (select 1 from vendorflow.users where lower(email) = lower(btrim(p_email))) then
        raise exception 'This email is already registered.' using errcode = 'VF409';
    end if;

    insert into vendorflow.tenants (name) values (btrim(p_org_name)) returning id into v_tenant;
    insert into vendorflow.tenant_settings (tenant_id, organization_name) values (v_tenant, btrim(p_org_name));
    call vendorflow.sp_seed_tenant_defaults(v_tenant);

    insert into vendorflow.users (tenant_id, email, full_name, password_hash)
    values (v_tenant, lower(btrim(p_email)), btrim(p_full_name), p_password_hash) returning id into v_user;
    insert into vendorflow.user_roles (user_id, role_id)
    select v_user, id from vendorflow.roles where code = 'OrganizationOwner';

    call vendorflow.sp_audit(v_tenant, v_user, 'tenant.registered', 'tenant', v_tenant, null);
    return jsonb_build_object('tenant_id', v_tenant, 'user_id', v_user);
end $$;

-- Everything the API needs to put into a token. Returns null for unknown, disabled or suspended accounts.
create or replace function vendorflow.fn_auth_user_context(p_user_id uuid)
returns jsonb language sql stable as $$
    select jsonb_build_object(
        'user_id', u.id, 'tenant_id', u.tenant_id, 'email', u.email, 'full_name', u.full_name, 'vendor_id', u.vendor_id,
        'roles', coalesce((select jsonb_agg(r.code order by r.code)
                           from vendorflow.user_roles ur join vendorflow.roles r on r.id = ur.role_id
                           where ur.user_id = u.id), '[]'::jsonb),
        'permissions', coalesce((select jsonb_agg(distinct rp.permission_code)
                                 from vendorflow.user_roles ur join vendorflow.role_permissions rp on rp.role_id = ur.role_id
                                 where ur.user_id = u.id), '[]'::jsonb))
    from vendorflow.users u
    join vendorflow.tenants t on t.id = u.tenant_id
    where u.id = p_user_id and u.status = 'Active' and t.status = 'Active';
$$;

-- Login lookup (includes the password hash; never returned to clients).
create or replace function vendorflow.fn_auth_get_login(p_email text)
returns jsonb language sql stable as $$
    select jsonb_build_object('user_id', u.id, 'password_hash', u.password_hash, 'status', u.status,
        'locked', coalesce(u.locked_until > now(), false))
    from vendorflow.users u where lower(u.email) = lower(btrim(p_email));
$$;

-- Records a login attempt: resets the counter on success, locks the account for 15 min after 5 failures.
create or replace procedure vendorflow.sp_auth_login_result(p_user_id uuid, p_success boolean)
language plpgsql as $$
declare
    v_tenant uuid;
    v_fails  int;
begin
    select tenant_id into v_tenant from vendorflow.users where id = p_user_id;
    if p_success then
        update vendorflow.users set failed_attempts = 0, locked_until = null, last_login_at = now() where id = p_user_id;
        call vendorflow.sp_audit(v_tenant, p_user_id, 'auth.login', 'user', p_user_id, null);
    else
        update vendorflow.users
        set failed_attempts = failed_attempts + 1,
            locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else locked_until end
        where id = p_user_id returning failed_attempts into v_fails;
        call vendorflow.sp_audit(v_tenant, p_user_id, 'auth.login_failed', 'user', p_user_id, jsonb_build_object('attempts', v_fails));
    end if;
end $$;

create or replace procedure vendorflow.sp_auth_store_refresh(p_user_id uuid, p_token_hash text, p_expires timestamptz)
language sql as $$
    insert into vendorflow.refresh_tokens (user_id, token_hash, expires_at) values (p_user_id, p_token_hash, p_expires);
$$;

-- Rotates a refresh token. Returns the user context, or null when invalid/expired.
-- Re-use of an already rotated token revokes every token of that user (stolen-token protection).
create or replace function vendorflow.fn_auth_rotate_refresh(p_old_hash text, p_new_hash text, p_expires timestamptz)
returns jsonb language plpgsql as $$
declare
    t   vendorflow.refresh_tokens%rowtype;
    ctx jsonb;
begin
    select * into t from vendorflow.refresh_tokens where token_hash = p_old_hash for update;
    if not found then return null; end if;
    if t.revoked_at is not null then
        update vendorflow.refresh_tokens set revoked_at = now() where user_id = t.user_id and revoked_at is null;
        return null;
    end if;
    if t.expires_at < now() then return null; end if;

    ctx := vendorflow.fn_auth_user_context(t.user_id);
    if ctx is null then return null; end if;

    update vendorflow.refresh_tokens set revoked_at = now(), replaced_by = p_new_hash where id = t.id;
    insert into vendorflow.refresh_tokens (user_id, token_hash, expires_at) values (t.user_id, p_new_hash, p_expires);
    return ctx;
end $$;

create or replace procedure vendorflow.sp_auth_revoke_all(p_user_id uuid)
language sql as $$
    update vendorflow.refresh_tokens set revoked_at = now() where user_id = p_user_id and revoked_at is null;
$$;

-- Creates a password-reset token for an e-mail address; returns {email, full_name, user_id} or null when unknown.
create or replace function vendorflow.fn_auth_create_reset(p_email text, p_token_hash text, p_expires timestamptz)
returns jsonb language plpgsql as $$
declare u vendorflow.users%rowtype;
begin
    select * into u from vendorflow.users where lower(email) = lower(btrim(p_email)) and status in ('Active','Invited');
    if not found then return null; end if;
    insert into vendorflow.password_resets (user_id, token_hash, expires_at) values (u.id, p_token_hash, p_expires);
    return jsonb_build_object('user_id', u.id, 'email', u.email, 'full_name', u.full_name, 'tenant_id', u.tenant_id);
end $$;

-- Sets a new password using a reset token. Returns true when the token was valid.
create or replace function vendorflow.fn_auth_reset_password(p_token_hash text, p_new_hash text)
returns boolean language plpgsql as $$
declare r vendorflow.password_resets%rowtype; v_tenant uuid;
begin
    select * into r from vendorflow.password_resets
    where token_hash = p_token_hash and used_at is null and expires_at > now() for update;
    if not found then return false; end if;
    update vendorflow.password_resets set used_at = now() where id = r.id;
    update vendorflow.users set password_hash = p_new_hash, failed_attempts = 0, locked_until = null,
        status = case when status = 'Invited' then 'Active' else status end where id = r.user_id;
    update vendorflow.refresh_tokens set revoked_at = now() where user_id = r.user_id and revoked_at is null;
    select tenant_id into v_tenant from vendorflow.users where id = r.user_id;
    call vendorflow.sp_audit(v_tenant, r.user_id, 'auth.password_reset', 'user', r.user_id, null);
    return true;
end $$;

-- ---------------------------------------------------------------- user management (tenant scoped)

create or replace function vendorflow.fn_user_list(p_tenant_id uuid, p_search text, p_page int, p_page_size int)
returns jsonb language plpgsql stable as $$
declare
    v_total bigint;
    v_items jsonb;
    v_page  int := greatest(coalesce(p_page, 1), 1);
    v_size  int := least(greatest(coalesce(p_page_size, 20), 1), 200);
begin
    select count(*) into v_total from vendorflow.users u
    where u.tenant_id = p_tenant_id
      and (coalesce(p_search, '') = '' or u.full_name ilike '%' || p_search || '%' or u.email ilike '%' || p_search || '%');

    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_items from (
        select jsonb_build_object('id', u.id, 'email', u.email, 'full_name', u.full_name, 'status', u.status,
            'last_login_at', u.last_login_at,
            'roles', coalesce((select jsonb_agg(r.code order by r.code) from vendorflow.user_roles ur
                               join vendorflow.roles r on r.id = ur.role_id where ur.user_id = u.id), '[]'::jsonb)) as x
        from vendorflow.users u
        where u.tenant_id = p_tenant_id
          and (coalesce(p_search, '') = '' or u.full_name ilike '%' || p_search || '%' or u.email ilike '%' || p_search || '%')
        order by u.full_name
        offset (v_page - 1) * v_size limit v_size) s;

    return vendorflow.fn_page(v_items, v_total, v_page, v_size);
end $$;

-- Lists roles with their permission codes (roles are global; users are tenant scoped).
create or replace function vendorflow.fn_role_list()
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'description', r.description,
        'permissions', coalesce((select jsonb_agg(rp.permission_code order by rp.permission_code)
                                 from vendorflow.role_permissions rp where rp.role_id = r.id), '[]'::jsonb))
        order by r.name), '[]'::jsonb)
    from vendorflow.roles r where r.code not in ('PlatformAdministrator','VendorPortalUser');
$$;

-- Creates an invited user (password is set later through a reset token).
create or replace function vendorflow.fn_user_invite(
    p_tenant_id uuid, p_actor_id uuid, p_email text, p_full_name text, p_role_codes text[], p_password_hash text)
returns jsonb language plpgsql as $$
declare v_user uuid;
begin
    if coalesce(btrim(p_email), '') = '' or coalesce(btrim(p_full_name), '') = '' then
        raise exception 'Email and full name are required.' using errcode = 'VF400';
    end if;
    if exists (select 1 from vendorflow.users where lower(email) = lower(btrim(p_email))) then
        raise exception 'A user with this email already exists.' using errcode = 'VF409';
    end if;
    if exists (select 1 from unnest(p_role_codes) c where c in ('PlatformAdministrator','VendorPortalUser'))
       or (select count(*) from vendorflow.roles where code = any(p_role_codes)) <> coalesce(array_length(p_role_codes, 1), 0) then
        raise exception 'One or more roles are invalid.' using errcode = 'VF400';
    end if;

    insert into vendorflow.users (tenant_id, email, full_name, password_hash, status)
    values (p_tenant_id, lower(btrim(p_email)), btrim(p_full_name), p_password_hash, 'Invited') returning id into v_user;
    insert into vendorflow.user_roles (user_id, role_id)
    select v_user, id from vendorflow.roles where code = any(p_role_codes);

    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'user.invited', 'user', v_user, jsonb_build_object('roles', p_role_codes));
    return jsonb_build_object('id', v_user, 'email', lower(btrim(p_email)));
end $$;

create or replace function vendorflow.fn_user_set_roles(p_tenant_id uuid, p_actor_id uuid, p_user_id uuid, p_role_codes text[])
returns jsonb language plpgsql as $$
begin
    if not exists (select 1 from vendorflow.users where id = p_user_id and tenant_id = p_tenant_id) then
        raise exception 'User not found.' using errcode = 'VF404';
    end if;
    if exists (select 1 from unnest(p_role_codes) c where c in ('PlatformAdministrator','VendorPortalUser'))
       or (select count(*) from vendorflow.roles where code = any(p_role_codes)) <> coalesce(array_length(p_role_codes, 1), 0) then
        raise exception 'One or more roles are invalid.' using errcode = 'VF400';
    end if;
    -- The organization must always keep at least one owner.
    if not ('OrganizationOwner' = any(p_role_codes)) and exists (
        select 1 from vendorflow.user_roles ur join vendorflow.roles r on r.id = ur.role_id
        where ur.user_id = p_user_id and r.code = 'OrganizationOwner')
       and (select count(*) from vendorflow.user_roles ur join vendorflow.roles r on r.id = ur.role_id
            join vendorflow.users u on u.id = ur.user_id
            where r.code = 'OrganizationOwner' and u.tenant_id = p_tenant_id and u.status <> 'Disabled') <= 1 then
        raise exception 'The organization needs at least one Organization Owner.' using errcode = 'VF409';
    end if;

    delete from vendorflow.user_roles where user_id = p_user_id;
    insert into vendorflow.user_roles (user_id, role_id) select p_user_id, id from vendorflow.roles where code = any(p_role_codes);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'user.roles_changed', 'user', p_user_id, jsonb_build_object('roles', p_role_codes));
    return jsonb_build_object('id', p_user_id, 'roles', to_jsonb(p_role_codes));
end $$;

create or replace function vendorflow.fn_user_set_status(p_tenant_id uuid, p_actor_id uuid, p_user_id uuid, p_status text)
returns jsonb language plpgsql as $$
begin
    if p_status not in ('Active', 'Disabled') then
        raise exception 'Status must be Active or Disabled.' using errcode = 'VF400';
    end if;
    if p_user_id = p_actor_id and p_status = 'Disabled' then
        raise exception 'You cannot disable your own account.' using errcode = 'VF409';
    end if;
    update vendorflow.users set status = p_status where id = p_user_id and tenant_id = p_tenant_id;
    if not found then raise exception 'User not found.' using errcode = 'VF404'; end if;
    if p_status = 'Disabled' then
        update vendorflow.refresh_tokens set revoked_at = now() where user_id = p_user_id and revoked_at is null;
    end if;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'user.status_changed', 'user', p_user_id, jsonb_build_object('status', p_status));
    return jsonb_build_object('id', p_user_id, 'status', p_status);
end $$;

-- Audit trail (tenant scoped, newest first).
create or replace function vendorflow.fn_audit_list(p_tenant_id uuid, p_page int, p_page_size int)
returns jsonb language plpgsql stable as $$
declare
    v_page int := greatest(coalesce(p_page, 1), 1);
    v_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
    v_total bigint;
    v_items jsonb;
begin
    select count(*) into v_total from vendorflow.audit_events where tenant_id = p_tenant_id;
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_items from (
        select jsonb_build_object('id', a.id, 'action', a.action, 'entity_type', a.entity_type, 'entity_id', a.entity_id,
            'details', a.details, 'user_name', u.full_name, 'created_at', a.created_at) as x
        from vendorflow.audit_events a left join vendorflow.users u on u.id = a.user_id
        where a.tenant_id = p_tenant_id order by a.id desc offset (v_page - 1) * v_size limit v_size) s;
    return vendorflow.fn_page(v_items, v_total, v_page, v_size);
end $$;
