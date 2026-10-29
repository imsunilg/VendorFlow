-- Vendor management. All functions are tenant scoped (p_tenant_id first).

-- Builds a safe ORDER BY fragment from a whitelist (prevents SQL injection through sort parameters).
create or replace function vendorflow.fn_sort_clause(p_sort_by text, p_sort_dir text, p_allowed text[], p_default text)
returns text language sql immutable as $$
    select (case when p_sort_by = any(p_allowed) then p_sort_by else p_default end)
           || case when lower(coalesce(p_sort_dir, 'asc')) = 'desc' then ' desc' else ' asc' end
           || ', id';
$$;

-- Status of a vendor document from its expiry date.
create or replace function vendorflow.fn_doc_status(p_expiry date)
returns text language sql immutable as $$
    select case when p_expiry is null then 'Valid'
                when p_expiry < current_date then 'Expired'
                when p_expiry <= current_date + 30 then 'Expiring'
                else 'Valid' end;
$$;

create or replace function vendorflow.fn_vendor_list(
    p_tenant_id uuid, p_search text default null, p_status text default null, p_category text default null,
    p_risk text default null, p_sort_by text default null, p_sort_dir text default null,
    p_page int default 1, p_page_size int default 20)
returns jsonb language plpgsql stable as $$
declare
    v_page   int := greatest(coalesce(p_page, 1), 1);
    v_size   int := least(greatest(coalesce(p_page_size, 20), 1), 200);
    v_order  text := vendorflow.fn_sort_clause(p_sort_by, p_sort_dir,
                     array['name','category','city','risk','rating','status','created_at'], 'name');
    v_where  text := $w$ v.tenant_id = $1
        and ($2 is null or $2 = '' or v.name ilike '%' || $2 || '%' or v.gstin ilike '%' || $2 || '%'
             or v.category ilike '%' || $2 || '%' or v.city ilike '%' || $2 || '%' or v.code ilike '%' || $2 || '%')
        and ($3 is null or $3 = '' or v.status = $3)
        and ($4 is null or $4 = '' or v.category = $4)
        and ($5 is null or $5 = '' or v.risk = $5) $w$;
    v_total  bigint;
    v_items  jsonb;
    v_counts jsonb;
begin
    execute 'select count(*) from vendorflow.vendors v where ' || v_where into v_total
        using p_tenant_id, p_search, p_status, p_category, p_risk;

    execute format($q$
        select coalesce(jsonb_agg(x), '[]'::jsonb) from (
            select jsonb_build_object('id', v.id, 'code', v.code, 'name', v.name, 'category', v.category,
                'city', v.city, 'state', v.state, 'risk', v.risk, 'rating', v.rating, 'status', v.status,
                'gstin', v.gstin, 'email', v.email, 'phone', v.phone) as x
            from vendorflow.vendors v where %s order by %s offset %s limit %s) s$q$,
        v_where, v_order, (v_page - 1) * v_size, v_size)
        into v_items using p_tenant_id, p_search, p_status, p_category, p_risk;

    select coalesce(jsonb_object_agg(status, c), '{}'::jsonb) || jsonb_build_object('All', coalesce(sum(c), 0))
    into v_counts
    from (select status, count(*) c from vendorflow.vendors where tenant_id = p_tenant_id group by status) g;

    return vendorflow.fn_page(v_items, v_total, v_page, v_size) || jsonb_build_object('status_counts', v_counts);
end $$;

create or replace function vendorflow.fn_vendor_categories(p_tenant_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(distinct category order by category), '[]'::jsonb)
    from vendorflow.vendors where tenant_id = p_tenant_id and category is not null and category <> '';
$$;

-- Full vendor profile (contacts, addresses, documents with status). Bank details are NOT included.
create or replace function vendorflow.fn_vendor_get(p_tenant_id uuid, p_id uuid)
returns jsonb language plpgsql stable as $$
declare v jsonb;
begin
    select jsonb_build_object(
        'id', x.id, 'code', x.code, 'name', x.name, 'legal_name', x.legal_name, 'category', x.category,
        'products_services', x.products_services, 'status', x.status, 'risk', x.risk, 'rating', x.rating,
        'gstin', x.gstin, 'pan', x.pan, 'msme_number', x.msme_number, 'payment_terms_days', x.payment_terms_days,
        'currency', x.currency, 'email', x.email, 'phone', x.phone, 'city', x.city, 'state', x.state,
        'onboarded_at', x.onboarded_at, 'row_version', x.row_version, 'created_at', x.created_at,
        'has_bank_details', exists (select 1 from vendorflow.vendor_bank_details b where b.vendor_id = x.id),
        'contacts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'designation', c.designation,
                    'email', c.email, 'phone', c.phone, 'is_primary', c.is_primary) order by c.is_primary desc, c.name)
                    from vendorflow.vendor_contacts c where c.vendor_id = x.id and c.tenant_id = p_tenant_id), '[]'::jsonb),
        'addresses', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'address_type', a.address_type, 'line1', a.line1,
                    'line2', a.line2, 'city', a.city, 'state', a.state, 'postal_code', a.postal_code, 'country', a.country)
                    order by a.address_type) from vendorflow.vendor_addresses a where a.vendor_id = x.id and a.tenant_id = p_tenant_id), '[]'::jsonb),
        'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type, 'doc_number', d.doc_number,
                    'expiry_date', d.expiry_date, 'file_name', d.file_name, 'status', vendorflow.fn_doc_status(d.expiry_date),
                    'days_left', case when d.expiry_date is null then null else d.expiry_date - current_date end)
                    order by d.doc_type) from vendorflow.vendor_documents d where d.vendor_id = x.id and d.tenant_id = p_tenant_id), '[]'::jsonb))
    into v
    from vendorflow.vendors x where x.id = p_id and x.tenant_id = p_tenant_id;

    if v is null then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;
    return v;
end $$;

-- Validates vendor fields shared by create and update.
create or replace procedure vendorflow.sp_vendor_validate(p_data jsonb)
language plpgsql as $$
begin
    if p_data ? 'name' and char_length(btrim(coalesce(p_data ->> 'name', ''))) not between 1 and 150 then
        raise exception 'Name is required (max 150 characters).' using errcode = 'VF400';
    end if;
    if coalesce(p_data ->> 'gstin', '') <> '' and upper(p_data ->> 'gstin') !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
        raise exception 'GSTIN format is invalid.' using errcode = 'VF400';
    end if;
    if coalesce(p_data ->> 'pan', '') <> '' and upper(p_data ->> 'pan') !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' then
        raise exception 'PAN format is invalid.' using errcode = 'VF400';
    end if;
    if coalesce(p_data ->> 'email', '') <> '' and (p_data ->> 'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
        raise exception 'Email is invalid.' using errcode = 'VF400';
    end if;
    if p_data ? 'risk' and (p_data ->> 'risk') not in ('Low', 'Medium', 'High') then
        raise exception 'Risk must be Low, Medium or High.' using errcode = 'VF400';
    end if;
    if p_data ? 'rating' and not ((p_data ->> 'rating')::numeric between 0 and 5) then
        raise exception 'Rating must be between 0 and 5.' using errcode = 'VF400';
    end if;
    if p_data ? 'payment_terms_days' and not ((p_data ->> 'payment_terms_days')::int between 0 and 365) then
        raise exception 'Payment terms must be between 0 and 365 days.' using errcode = 'VF400';
    end if;
end $$;

create or replace function vendorflow.fn_vendor_create(p_tenant_id uuid, p_actor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare v_id uuid;
begin
    if coalesce(btrim(p_data ->> 'name'), '') = '' then
        raise exception 'Name is required.' using errcode = 'VF400';
    end if;
    call vendorflow.sp_vendor_validate(p_data);

    insert into vendorflow.vendors (tenant_id, code, name, legal_name, category, products_services, risk, rating, gstin, pan,
        msme_number, payment_terms_days, currency, email, phone, city, state, created_by)
    values (p_tenant_id, vendorflow.fn_next_number(p_tenant_id, 'vendor'), btrim(p_data ->> 'name'),
        nullif(btrim(p_data ->> 'legal_name'), ''), nullif(btrim(p_data ->> 'category'), ''),
        nullif(btrim(p_data ->> 'products_services'), ''), coalesce(p_data ->> 'risk', 'Low'),
        coalesce((p_data ->> 'rating')::numeric, 0), nullif(upper(btrim(p_data ->> 'gstin')), ''),
        nullif(upper(btrim(p_data ->> 'pan')), ''), nullif(btrim(p_data ->> 'msme_number'), ''),
        coalesce((p_data ->> 'payment_terms_days')::int, 30), coalesce(p_data ->> 'currency', 'INR'),
        nullif(btrim(p_data ->> 'email'), ''), nullif(btrim(p_data ->> 'phone'), ''),
        nullif(btrim(p_data ->> 'city'), ''), nullif(btrim(p_data ->> 'state'), ''), p_actor_id)
    returning id into v_id;

    call vendorflow.sp_history(p_tenant_id, 'vendor', v_id, 'created', null, 'Draft', null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'vendor.created', 'vendor', v_id, null);
    return vendorflow.fn_vendor_get(p_tenant_id, v_id);
end $$;

-- Updates a vendor. If p_data has "row_version" it must match (optimistic concurrency).
create or replace function vendorflow.fn_vendor_update(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare cur vendorflow.vendors%rowtype;
begin
    select * into cur from vendorflow.vendors where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;
    if p_data ? 'row_version' and (p_data ->> 'row_version')::int <> cur.row_version then
        raise exception 'This vendor was changed by someone else. Reload and try again.' using errcode = 'VF409';
    end if;
    if cur.status = 'PendingApproval' then
        raise exception 'A vendor waiting for approval cannot be edited.' using errcode = 'VF409';
    end if;
    call vendorflow.sp_vendor_validate(p_data);

    update vendorflow.vendors set
        name = coalesce(nullif(btrim(p_data ->> 'name'), ''), name),
        legal_name = case when p_data ? 'legal_name' then nullif(btrim(p_data ->> 'legal_name'), '') else legal_name end,
        category = case when p_data ? 'category' then nullif(btrim(p_data ->> 'category'), '') else category end,
        products_services = case when p_data ? 'products_services' then nullif(btrim(p_data ->> 'products_services'), '') else products_services end,
        risk = coalesce(p_data ->> 'risk', risk),
        rating = coalesce((p_data ->> 'rating')::numeric, rating),
        gstin = case when p_data ? 'gstin' then nullif(upper(btrim(p_data ->> 'gstin')), '') else gstin end,
        pan = case when p_data ? 'pan' then nullif(upper(btrim(p_data ->> 'pan')), '') else pan end,
        msme_number = case when p_data ? 'msme_number' then nullif(btrim(p_data ->> 'msme_number'), '') else msme_number end,
        payment_terms_days = coalesce((p_data ->> 'payment_terms_days')::int, payment_terms_days),
        currency = coalesce(p_data ->> 'currency', currency),
        email = case when p_data ? 'email' then nullif(btrim(p_data ->> 'email'), '') else email end,
        phone = case when p_data ? 'phone' then nullif(btrim(p_data ->> 'phone'), '') else phone end,
        city = case when p_data ? 'city' then nullif(btrim(p_data ->> 'city'), '') else city end,
        state = case when p_data ? 'state' then nullif(btrim(p_data ->> 'state'), '') else state end,
        updated_at = now(), row_version = row_version + 1
    where id = p_id;

    call vendorflow.sp_history(p_tenant_id, 'vendor', p_id, 'updated', cur.status, cur.status, null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'vendor.updated', 'vendor', p_id, null);
    return vendorflow.fn_vendor_get(p_tenant_id, p_id);
end $$;

-- Workflow: submit | approve | reject | suspend | reactivate.
create or replace function vendorflow.fn_vendor_transition(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_action text, p_comment text)
returns jsonb language plpgsql as $$
declare
    cur vendorflow.vendors%rowtype;
    v_to text;
begin
    select * into cur from vendorflow.vendors where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;

    v_to := case
        when p_action = 'submit'     and cur.status in ('Draft', 'Rejected') then 'PendingApproval'
        when p_action = 'approve'    and cur.status = 'PendingApproval' then 'Approved'
        when p_action = 'reject'     and cur.status = 'PendingApproval' then 'Rejected'
        when p_action = 'suspend'    and cur.status = 'Approved' then 'Suspended'
        when p_action = 'reactivate' and cur.status = 'Suspended' then 'Approved'
        else null end;
    if v_to is null then
        raise exception 'Cannot % a vendor that is %.', p_action, cur.status using errcode = 'VF409';
    end if;
    if p_action in ('reject', 'suspend') and coalesce(btrim(p_comment), '') = '' then
        raise exception 'A reason is required.' using errcode = 'VF400';
    end if;
    if p_action = 'submit' and coalesce(cur.email, '') = '' and not exists (
        select 1 from vendorflow.vendor_contacts c where c.vendor_id = cur.id) then
        raise exception 'Add an email or at least one contact before submitting.' using errcode = 'VF400';
    end if;

    update vendorflow.vendors set status = v_to, updated_at = now(), row_version = row_version + 1,
        onboarded_at = case when v_to = 'Approved' and onboarded_at is null then current_date else onboarded_at end
    where id = p_id;

    call vendorflow.sp_history(p_tenant_id, 'vendor', p_id, p_action, cur.status, v_to, p_comment, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'vendor.' || p_action, 'vendor', p_id, jsonb_build_object('comment', p_comment));
    return vendorflow.fn_vendor_get(p_tenant_id, p_id);
end $$;

-- ---------------------------------------------------------------- contacts / addresses / documents

create or replace function vendorflow.fn_vendor_contact_save(p_tenant_id uuid, p_actor_id uuid, p_vendor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare v_id uuid := nullif(p_data ->> 'id', '')::uuid;
begin
    perform 1 from vendorflow.vendors where id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;
    if coalesce(btrim(p_data ->> 'name'), '') = '' then raise exception 'Contact name is required.' using errcode = 'VF400'; end if;

    if coalesce((p_data ->> 'is_primary')::boolean, false) then
        update vendorflow.vendor_contacts set is_primary = false where vendor_id = p_vendor_id and tenant_id = p_tenant_id;
    end if;
    if v_id is null then
        insert into vendorflow.vendor_contacts (tenant_id, vendor_id, name, designation, email, phone, is_primary)
        values (p_tenant_id, p_vendor_id, btrim(p_data ->> 'name'), p_data ->> 'designation', p_data ->> 'email',
                p_data ->> 'phone', coalesce((p_data ->> 'is_primary')::boolean, false));
    else
        update vendorflow.vendor_contacts set name = btrim(p_data ->> 'name'), designation = p_data ->> 'designation',
            email = p_data ->> 'email', phone = p_data ->> 'phone',
            is_primary = coalesce((p_data ->> 'is_primary')::boolean, is_primary)
        where id = v_id and vendor_id = p_vendor_id and tenant_id = p_tenant_id;
        if not found then raise exception 'Contact not found.' using errcode = 'VF404'; end if;
    end if;
    return vendorflow.fn_vendor_get(p_tenant_id, p_vendor_id);
end $$;

create or replace function vendorflow.fn_vendor_contact_delete(p_tenant_id uuid, p_actor_id uuid, p_vendor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
begin
    delete from vendorflow.vendor_contacts where id = p_id and vendor_id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Contact not found.' using errcode = 'VF404'; end if;
    return vendorflow.fn_vendor_get(p_tenant_id, p_vendor_id);
end $$;

create or replace function vendorflow.fn_vendor_address_save(p_tenant_id uuid, p_actor_id uuid, p_vendor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare v_id uuid := nullif(p_data ->> 'id', '')::uuid;
begin
    perform 1 from vendorflow.vendors where id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;
    if coalesce(btrim(p_data ->> 'line1'), '') = '' then raise exception 'Address line 1 is required.' using errcode = 'VF400'; end if;

    if v_id is null then
        insert into vendorflow.vendor_addresses (tenant_id, vendor_id, address_type, line1, line2, city, state, postal_code, country)
        values (p_tenant_id, p_vendor_id, coalesce(p_data ->> 'address_type', 'Registered'), btrim(p_data ->> 'line1'),
                p_data ->> 'line2', p_data ->> 'city', p_data ->> 'state', p_data ->> 'postal_code', coalesce(p_data ->> 'country', 'India'));
    else
        update vendorflow.vendor_addresses set address_type = coalesce(p_data ->> 'address_type', address_type),
            line1 = btrim(p_data ->> 'line1'), line2 = p_data ->> 'line2', city = p_data ->> 'city', state = p_data ->> 'state',
            postal_code = p_data ->> 'postal_code', country = coalesce(p_data ->> 'country', country)
        where id = v_id and vendor_id = p_vendor_id and tenant_id = p_tenant_id;
        if not found then raise exception 'Address not found.' using errcode = 'VF404'; end if;
    end if;
    return vendorflow.fn_vendor_get(p_tenant_id, p_vendor_id);
end $$;

create or replace function vendorflow.fn_vendor_address_delete(p_tenant_id uuid, p_actor_id uuid, p_vendor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
begin
    delete from vendorflow.vendor_addresses where id = p_id and vendor_id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Address not found.' using errcode = 'VF404'; end if;
    return vendorflow.fn_vendor_get(p_tenant_id, p_vendor_id);
end $$;

create or replace function vendorflow.fn_vendor_document_save(p_tenant_id uuid, p_actor_id uuid, p_vendor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare v_id uuid := nullif(p_data ->> 'id', '')::uuid;
begin
    perform 1 from vendorflow.vendors where id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;
    if coalesce(btrim(p_data ->> 'doc_type'), '') = '' then raise exception 'Document type is required.' using errcode = 'VF400'; end if;

    if v_id is null then
        insert into vendorflow.vendor_documents (tenant_id, vendor_id, doc_type, doc_number, expiry_date, file_name, storage_key)
        values (p_tenant_id, p_vendor_id, btrim(p_data ->> 'doc_type'), p_data ->> 'doc_number',
                nullif(p_data ->> 'expiry_date', '')::date, p_data ->> 'file_name', p_data ->> 'storage_key');
    else
        update vendorflow.vendor_documents set doc_type = btrim(p_data ->> 'doc_type'), doc_number = p_data ->> 'doc_number',
            expiry_date = nullif(p_data ->> 'expiry_date', '')::date,
            file_name = coalesce(p_data ->> 'file_name', file_name), storage_key = coalesce(p_data ->> 'storage_key', storage_key)
        where id = v_id and vendor_id = p_vendor_id and tenant_id = p_tenant_id;
        if not found then raise exception 'Document not found.' using errcode = 'VF404'; end if;
    end if;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'vendor.document_saved', 'vendor', p_vendor_id, jsonb_build_object('doc_type', p_data ->> 'doc_type'));
    return vendorflow.fn_vendor_get(p_tenant_id, p_vendor_id);
end $$;

create or replace function vendorflow.fn_vendor_document_delete(p_tenant_id uuid, p_actor_id uuid, p_vendor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
begin
    delete from vendorflow.vendor_documents where id = p_id and vendor_id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Document not found.' using errcode = 'VF404'; end if;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'vendor.document_deleted', 'vendor', p_vendor_id, null);
    return vendorflow.fn_vendor_get(p_tenant_id, p_vendor_id);
end $$;

-- Document needed by the download endpoint (storage key belongs to the tenant and vendor).
create or replace function vendorflow.fn_vendor_document_file(p_tenant_id uuid, p_vendor_id uuid, p_id uuid)
returns jsonb language sql stable as $$
    select jsonb_build_object('storage_key', d.storage_key, 'file_name', d.file_name)
    from vendorflow.vendor_documents d where d.id = p_id and d.vendor_id = p_vendor_id and d.tenant_id = p_tenant_id and d.storage_key is not null;
$$;

-- ---------------------------------------------------------------- bank details (restricted + audited)

-- Returns bank details. Every call is audited because this data is sensitive.
create or replace function vendorflow.fn_vendor_bank_get(p_tenant_id uuid, p_actor_id uuid, p_vendor_id uuid)
returns jsonb language plpgsql as $$
declare b vendorflow.vendor_bank_details%rowtype;
begin
    perform 1 from vendorflow.vendors where id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;
    select * into b from vendorflow.vendor_bank_details where vendor_id = p_vendor_id and tenant_id = p_tenant_id;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'vendor.bank_viewed', 'vendor', p_vendor_id, null);
    if not found then return null; end if;
    return jsonb_build_object('account_name', b.account_name, 'account_number', b.account_number, 'ifsc', b.ifsc,
        'bank_name', b.bank_name, 'branch', b.branch, 'updated_at', b.updated_at);
end $$;

create or replace function vendorflow.fn_vendor_bank_save(p_tenant_id uuid, p_actor_id uuid, p_vendor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
begin
    perform 1 from vendorflow.vendors where id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;
    if coalesce(btrim(p_data ->> 'account_name'), '') = '' or coalesce(btrim(p_data ->> 'account_number'), '') = '' then
        raise exception 'Account name and number are required.' using errcode = 'VF400';
    end if;
    if upper(coalesce(p_data ->> 'ifsc', '')) !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then
        raise exception 'IFSC code is invalid.' using errcode = 'VF400';
    end if;
    if (p_data ->> 'account_number') !~ '^[0-9]{6,20}$' then
        raise exception 'Account number must be 6 to 20 digits.' using errcode = 'VF400';
    end if;

    insert into vendorflow.vendor_bank_details (vendor_id, tenant_id, account_name, account_number, ifsc, bank_name, branch)
    values (p_vendor_id, p_tenant_id, btrim(p_data ->> 'account_name'), p_data ->> 'account_number', upper(p_data ->> 'ifsc'),
            p_data ->> 'bank_name', p_data ->> 'branch')
    on conflict (vendor_id) do update set account_name = excluded.account_name, account_number = excluded.account_number,
        ifsc = excluded.ifsc, bank_name = excluded.bank_name, branch = excluded.branch, updated_at = now();

    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'vendor.bank_changed', 'vendor', p_vendor_id, null);
    return jsonb_build_object('saved', true);
end $$;

-- ---------------------------------------------------------------- performance (computed, never invented)

-- Computes each metric from real PO / GRN / invoice / RFQ / document data.
-- Metrics without data are null and excluded; weights of the remaining metrics are re-normalised.
create or replace function vendorflow.fn_vendor_performance(p_tenant_id uuid, p_vendor_id uuid)
returns jsonb language plpgsql stable as $$
declare
    w jsonb;
    v_on_time numeric; v_accepted numeric; v_invoice numeric; v_response numeric; v_docs numeric;
    v_sum numeric := 0; v_weights numeric := 0; v_score numeric;
    m jsonb;
begin
    perform 1 from vendorflow.vendors where id = p_vendor_id and tenant_id = p_tenant_id;
    if not found then raise exception 'Vendor not found.' using errcode = 'VF404'; end if;
    select performance_weights into w from vendorflow.tenant_settings where tenant_id = p_tenant_id;

    select round(100.0 * count(*) filter (where g.received_on <= coalesce(po.expected_delivery, g.received_on)) / nullif(count(*), 0), 1)
    into v_on_time
    from vendorflow.goods_receipts g join vendorflow.purchase_orders po on po.id = g.po_id
    where g.tenant_id = p_tenant_id and po.vendor_id = p_vendor_id and g.status = 'Posted';

    select round(100.0 * sum(i.accepted_qty) / nullif(sum(i.received_qty), 0), 1) into v_accepted
    from vendorflow.grn_items i join vendorflow.goods_receipts g on g.id = i.grn_id
    join vendorflow.purchase_orders po on po.id = g.po_id
    where g.tenant_id = p_tenant_id and po.vendor_id = p_vendor_id and g.status = 'Posted';

    select round(100.0 * count(*) filter (where not exists (select 1 from vendorflow.invoice_discrepancies d where d.invoice_id = inv.id))
                 / nullif(count(*), 0), 1) into v_invoice
    from vendorflow.invoices inv where inv.tenant_id = p_tenant_id and inv.vendor_id = p_vendor_id and inv.status <> 'Cancelled';

    select round(100.0 * count(*) filter (where rv.status = 'Submitted') / nullif(count(*), 0), 1) into v_response
    from vendorflow.rfq_vendors rv join vendorflow.rfqs r on r.id = rv.rfq_id
    where rv.tenant_id = p_tenant_id and rv.vendor_id = p_vendor_id and r.status <> 'Draft';

    select round(100.0 * count(*) filter (where d.expiry_date is null or d.expiry_date >= current_date) / nullif(count(*), 0), 1) into v_docs
    from vendorflow.vendor_documents d where d.tenant_id = p_tenant_id and d.vendor_id = p_vendor_id;

    m := jsonb_build_array(
        jsonb_build_object('key', 'onTime', 'label', 'On-time delivery', 'value', v_on_time, 'weight', (w ->> 'onTime')::numeric,
            'explanation', 'Goods receipts posted on or before the PO expected delivery date.'),
        jsonb_build_object('key', 'acceptedQty', 'label', 'Accepted quantity', 'value', v_accepted, 'weight', (w ->> 'acceptedQty')::numeric,
            'explanation', 'Accepted quantity divided by received quantity across goods receipts.'),
        jsonb_build_object('key', 'invoiceAccuracy', 'label', 'Invoice accuracy', 'value', v_invoice, 'weight', (w ->> 'invoiceAccuracy')::numeric,
            'explanation', 'Share of invoices registered without any matching discrepancy.'),
        jsonb_build_object('key', 'responsiveness', 'label', 'Responsiveness', 'value', v_response, 'weight', (w ->> 'responsiveness')::numeric,
            'explanation', 'RFQ invitations answered with a quotation.'),
        jsonb_build_object('key', 'documentCompliance', 'label', 'Document compliance', 'value', v_docs, 'weight', (w ->> 'documentCompliance')::numeric,
            'explanation', 'Documents that are not expired.'));

    select coalesce(sum((e ->> 'value')::numeric * (e ->> 'weight')::numeric), 0), coalesce(sum((e ->> 'weight')::numeric), 0)
    into v_sum, v_weights
    from jsonb_array_elements(m) e where (e ->> 'value') is not null;

    v_score := case when v_weights > 0 then round(v_sum / v_weights, 0) else null end;
    return jsonb_build_object('score', v_score, 'metrics', m,
        'note', 'Score = weighted average of the metrics that have data. Weights are set in Organization Settings.');
end $$;

create or replace function vendorflow.fn_vendor_history(p_tenant_id uuid, p_vendor_id uuid)
returns jsonb language sql stable as $$
    select vendorflow.fn_history_list(p_tenant_id, 'vendor', p_vendor_id);
$$;
