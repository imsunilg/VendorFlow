-- Notifications (in-app + e-mail outbox) and generic attachments.

-- Creates an in-app notification for one user (idempotent through dedupe_key) and queues an e-mail when enabled.
create or replace procedure vendorflow.sp_notify_user(
    p_tenant_id uuid, p_user_id uuid, p_type text, p_title text, p_body text,
    p_entity_type text, p_entity_id uuid, p_dedupe_key text)
language plpgsql as $$
declare
    v_email text;
    v_prefs jsonb;
begin
    insert into vendorflow.notifications (tenant_id, user_id, type, title, body, entity_type, entity_id, dedupe_key)
    values (p_tenant_id, p_user_id, p_type, p_title, p_body, p_entity_type, p_entity_id, p_dedupe_key)
    on conflict (user_id, dedupe_key) do nothing;

    if found then
        select notification_prefs into v_prefs from vendorflow.tenant_settings where tenant_id = p_tenant_id;
        if coalesce((v_prefs ->> 'email')::boolean, false) then
            select email into v_email from vendorflow.users where id = p_user_id and tenant_id = p_tenant_id;
            if v_email is not null then
                insert into vendorflow.email_outbox (tenant_id, to_email, subject, body, dedupe_key)
                values (p_tenant_id, v_email, p_title, coalesce(p_body, p_title), p_user_id::text || ':' || p_dedupe_key)
                on conflict (tenant_id, dedupe_key) do nothing;
            end if;
        end if;
    end if;
end $$;

-- Notifies every active user of the tenant who holds a role (and optionally one extra permission-free filter on department manager).
create or replace procedure vendorflow.sp_notify_role(
    p_tenant_id uuid, p_role_code text, p_type text, p_title text, p_body text,
    p_entity_type text, p_entity_id uuid, p_dedupe_key text)
language plpgsql as $$
declare u record;
begin
    for u in
        select distinct us.id from vendorflow.users us
        join vendorflow.user_roles ur on ur.user_id = us.id
        join vendorflow.roles r on r.id = ur.role_id
        where us.tenant_id = p_tenant_id and us.status = 'Active' and r.code = p_role_code
    loop
        call vendorflow.sp_notify_user(p_tenant_id, u.id, p_type, p_title, p_body, p_entity_type, p_entity_id, p_dedupe_key);
    end loop;
end $$;

create or replace function vendorflow.fn_notification_list(p_tenant_id uuid, p_user_id uuid, p_unread_only boolean, p_page int, p_page_size int)
returns jsonb language plpgsql stable as $$
declare
    v_page int := greatest(coalesce(p_page, 1), 1);
    v_size int := least(greatest(coalesce(p_page_size, 20), 1), 100);
    v_total bigint; v_unread bigint; v_items jsonb;
begin
    select count(*) into v_total from vendorflow.notifications
    where tenant_id = p_tenant_id and user_id = p_user_id and (not coalesce(p_unread_only, false) or read_at is null);
    select count(*) into v_unread from vendorflow.notifications where tenant_id = p_tenant_id and user_id = p_user_id and read_at is null;
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_items from (
        select jsonb_build_object('id', n.id, 'type', n.type, 'title', n.title, 'body', n.body, 'entity_type', n.entity_type,
            'entity_id', n.entity_id, 'read', n.read_at is not null, 'created_at', n.created_at) as x
        from vendorflow.notifications n
        where n.tenant_id = p_tenant_id and n.user_id = p_user_id and (not coalesce(p_unread_only, false) or n.read_at is null)
        order by n.created_at desc offset (v_page - 1) * v_size limit v_size) s;
    return vendorflow.fn_page(v_items, v_total, v_page, v_size) || jsonb_build_object('unread_count', v_unread);
end $$;

create or replace procedure vendorflow.sp_notification_mark_read(p_tenant_id uuid, p_user_id uuid, p_id uuid)
language sql as $$
    update vendorflow.notifications set read_at = coalesce(read_at, now())
    where tenant_id = p_tenant_id and user_id = p_user_id and (p_id is null or id = p_id);
$$;

-- ---------------------------------------------------------------- attachments (generic)

-- Checks that a document of the given type exists in the tenant.
create or replace function vendorflow.fn_entity_exists(p_tenant_id uuid, p_entity_type text, p_entity_id uuid)
returns boolean language plpgsql stable as $$
begin
    return case p_entity_type
        when 'requisition'    then exists (select 1 from vendorflow.requisitions where id = p_entity_id and tenant_id = p_tenant_id)
        when 'rfq'            then exists (select 1 from vendorflow.rfqs where id = p_entity_id and tenant_id = p_tenant_id)
        when 'purchase_order' then exists (select 1 from vendorflow.purchase_orders where id = p_entity_id and tenant_id = p_tenant_id)
        when 'goods_receipt'  then exists (select 1 from vendorflow.goods_receipts where id = p_entity_id and tenant_id = p_tenant_id)
        when 'invoice'        then exists (select 1 from vendorflow.invoices where id = p_entity_id and tenant_id = p_tenant_id)
        else false end;
end $$;

create or replace function vendorflow.fn_attachment_add(
    p_tenant_id uuid, p_actor_id uuid, p_entity_type text, p_entity_id uuid,
    p_file_name text, p_content_type text, p_size bigint, p_storage_key text)
returns jsonb language plpgsql as $$
declare v_id uuid;
begin
    if not vendorflow.fn_entity_exists(p_tenant_id, p_entity_type, p_entity_id) then
        raise exception 'Document not found.' using errcode = 'VF404';
    end if;
    insert into vendorflow.attachments (tenant_id, entity_type, entity_id, file_name, content_type, size_bytes, storage_key, uploaded_by)
    values (p_tenant_id, p_entity_type, p_entity_id, p_file_name, p_content_type, p_size, p_storage_key, p_actor_id)
    returning id into v_id;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'attachment.added', p_entity_type, p_entity_id, jsonb_build_object('file', p_file_name));
    return jsonb_build_object('id', v_id, 'file_name', p_file_name, 'size_bytes', p_size);
end $$;

create or replace function vendorflow.fn_attachment_list(p_tenant_id uuid, p_entity_type text, p_entity_id uuid)
returns jsonb language sql stable as $$
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'file_name', a.file_name, 'content_type', a.content_type,
        'size_bytes', a.size_bytes, 'created_at', a.created_at) order by a.created_at), '[]'::jsonb)
    from vendorflow.attachments a where a.tenant_id = p_tenant_id and a.entity_type = p_entity_type and a.entity_id = p_entity_id;
$$;

create or replace function vendorflow.fn_attachment_file(p_tenant_id uuid, p_id uuid)
returns jsonb language sql stable as $$
    select jsonb_build_object('storage_key', a.storage_key, 'file_name', a.file_name, 'entity_type', a.entity_type)
    from vendorflow.attachments a where a.id = p_id and a.tenant_id = p_tenant_id;
$$;

create or replace function vendorflow.fn_attachment_delete(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
declare a vendorflow.attachments%rowtype;
begin
    delete from vendorflow.attachments where id = p_id and tenant_id = p_tenant_id returning * into a;
    if not found then raise exception 'Attachment not found.' using errcode = 'VF404'; end if;
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'attachment.deleted', a.entity_type, a.entity_id, jsonb_build_object('file', a.file_name));
    return jsonb_build_object('deleted', true);
end $$;
