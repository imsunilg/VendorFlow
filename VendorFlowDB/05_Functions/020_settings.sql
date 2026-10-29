-- Organization settings: display name, vendor terminology, currency, numbering, tax, notifications, weights.

create or replace function vendorflow.fn_settings_get(p_tenant_id uuid)
returns jsonb language sql stable as $$
    select jsonb_build_object(
        'app_display_name', s.app_display_name, 'organization_name', s.organization_name,
        'vendor_label_singular', s.vendor_label_singular, 'vendor_label_plural', s.vendor_label_plural,
        'logo_url', s.logo_url, 'currency', s.currency, 'time_zone', s.time_zone,
        'tax_settings', s.tax_settings, 'numbering', s.numbering, 'notification_prefs', s.notification_prefs,
        'performance_weights', s.performance_weights, 'invoice_tolerance_pct', s.invoice_tolerance_pct,
        'allow_self_approval', s.allow_self_approval)
    from vendorflow.tenant_settings s where s.tenant_id = p_tenant_id;
$$;

-- Updates only the keys present in p_data. Text labels are trimmed, 1-50 chars, no HTML.
create or replace function vendorflow.fn_settings_update(p_tenant_id uuid, p_actor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    v_label text;
    k text;
    v_numbering jsonb;
    v_weights jsonb;
    v_total numeric;
begin
    if not exists (select 1 from vendorflow.tenant_settings where tenant_id = p_tenant_id) then
        raise exception 'Settings not found.' using errcode = 'VF404';
    end if;

    foreach k in array array['app_display_name', 'vendor_label_singular', 'vendor_label_plural'] loop
        if p_data ? k then
            v_label := btrim(coalesce(p_data ->> k, ''));
            if char_length(v_label) < 1 or char_length(v_label) > 50 then
                raise exception '% must be 1 to 50 characters.', k using errcode = 'VF400';
            end if;
            if v_label ~ '[<>]' then
                raise exception '% must not contain HTML.', k using errcode = 'VF400';
            end if;
        end if;
    end loop;

    if p_data ? 'organization_name' and (char_length(btrim(coalesce(p_data ->> 'organization_name', ''))) not between 1 and 100
        or (p_data ->> 'organization_name') ~ '[<>]') then
        raise exception 'organization_name must be 1 to 100 characters without HTML.' using errcode = 'VF400';
    end if;
    if p_data ? 'currency' and (p_data ->> 'currency') !~ '^[A-Z]{3}$' then
        raise exception 'currency must be a 3-letter code such as INR.' using errcode = 'VF400';
    end if;
    if p_data ? 'time_zone' and not exists (select 1 from pg_timezone_names where name = p_data ->> 'time_zone') then
        raise exception 'Unknown time zone.' using errcode = 'VF400';
    end if;
    if p_data ? 'invoice_tolerance_pct' and not ((p_data ->> 'invoice_tolerance_pct')::numeric between 0 and 100) then
        raise exception 'Tolerance must be between 0 and 100.' using errcode = 'VF400';
    end if;

    if p_data ? 'numbering' then
        v_numbering := (select numbering from vendorflow.tenant_settings where tenant_id = p_tenant_id) || (p_data -> 'numbering');
        for k in select jsonb_object_keys(p_data -> 'numbering') loop
            if (v_numbering ->> k) !~ '\{0+\}' or (v_numbering ->> k) ~ '[<>]' then
                raise exception 'Numbering pattern for % must contain a counter such as {0000}.', k using errcode = 'VF400';
            end if;
        end loop;
    end if;

    if p_data ? 'performance_weights' then
        v_weights := p_data -> 'performance_weights';
        select sum(value::numeric) into v_total from jsonb_each_text(v_weights);
        if v_total is null or v_total <= 0 then
            raise exception 'Performance weights must add up to more than zero.' using errcode = 'VF400';
        end if;
    end if;

    update vendorflow.tenant_settings s set
        app_display_name      = coalesce(btrim(p_data ->> 'app_display_name'), s.app_display_name),
        organization_name     = coalesce(btrim(p_data ->> 'organization_name'), s.organization_name),
        vendor_label_singular = coalesce(btrim(p_data ->> 'vendor_label_singular'), s.vendor_label_singular),
        vendor_label_plural   = coalesce(btrim(p_data ->> 'vendor_label_plural'), s.vendor_label_plural),
        currency              = coalesce(p_data ->> 'currency', s.currency),
        time_zone             = coalesce(p_data ->> 'time_zone', s.time_zone),
        tax_settings          = case when p_data ? 'tax_settings' then s.tax_settings || (p_data -> 'tax_settings') else s.tax_settings end,
        numbering             = coalesce(v_numbering, s.numbering),
        notification_prefs    = case when p_data ? 'notification_prefs' then s.notification_prefs || (p_data -> 'notification_prefs') else s.notification_prefs end,
        performance_weights   = case when p_data ? 'performance_weights' then s.performance_weights || v_weights else s.performance_weights end,
        invoice_tolerance_pct = coalesce((p_data ->> 'invoice_tolerance_pct')::numeric, s.invoice_tolerance_pct),
        allow_self_approval   = coalesce((p_data ->> 'allow_self_approval')::boolean, s.allow_self_approval),
        updated_at            = now()
    where s.tenant_id = p_tenant_id;

    if p_data ? 'organization_name' then
        update vendorflow.tenants set name = btrim(p_data ->> 'organization_name') where id = p_tenant_id;
    end if;

    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'settings.updated', 'tenant', p_tenant_id, p_data);
    return vendorflow.fn_settings_get(p_tenant_id);
end $$;

create or replace procedure vendorflow.sp_settings_set_logo(p_tenant_id uuid, p_actor_id uuid, p_storage_key text)
language plpgsql as $$
begin
    update vendorflow.tenant_settings set logo_url = p_storage_key, updated_at = now() where tenant_id = p_tenant_id;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'settings.logo_changed', 'tenant', p_tenant_id, null);
end $$;

-- Departments and cost centres for form drop-downs.
create or replace function vendorflow.fn_lookup_departments(p_tenant_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name) order by d.name), '[]'::jsonb)
    from vendorflow.departments d where d.tenant_id = p_tenant_id;
$$;

create or replace function vendorflow.fn_lookup_cost_centres(p_tenant_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'department_id', c.department_id)
        order by c.code), '[]'::jsonb)
    from vendorflow.cost_centres c where c.tenant_id = p_tenant_id;
$$;

-- Active colleagues for pickers (delegation, department manager). Tenant scoped; no sensitive data.
create or replace function vendorflow.fn_lookup_users(p_tenant_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'full_name', u.full_name,
        'roles', coalesce((select jsonb_agg(r.code order by r.code) from vendorflow.user_roles ur join vendorflow.roles r on r.id = ur.role_id
                           where ur.user_id = u.id), '[]'::jsonb)) order by u.full_name), '[]'::jsonb)
    from vendorflow.users u where u.tenant_id = p_tenant_id and u.status = 'Active';
$$;
