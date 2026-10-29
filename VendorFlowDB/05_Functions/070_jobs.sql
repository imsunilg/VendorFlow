-- Background job bodies. Every function is idempotent: notifications use dedupe keys, so running a job twice creates nothing new.
-- p_tenant_id = null processes all tenants (used by Hangfire); a tenant id restricts it (used by "Run checks now").

-- Notifies people who hold one of the given roles in a tenant.
create or replace procedure vendorflow.sp_notify_roles(
    p_tenant_id uuid, p_roles text[], p_type text, p_title text, p_body text, p_entity_type text, p_entity_id uuid, p_dedupe_key text)
language plpgsql as $$
declare r text;
begin
    foreach r in array p_roles loop
        call vendorflow.sp_notify_role(p_tenant_id, r, p_type, p_title, p_body, p_entity_type, p_entity_id, p_dedupe_key);
    end loop;
end $$;

-- Vendor documents that expire within 30 days (and expired ones): one notification per document per threshold.
create or replace function vendorflow.fn_job_vendor_doc_expiry(p_tenant_id uuid default null)
returns int language plpgsql as $$
declare
    d record;
    v_bucket text;
    v_before bigint; v_after bigint;
begin
    select count(*) into v_before from vendorflow.notifications where type = 'document_expiring' and (p_tenant_id is null or tenant_id = p_tenant_id);
    for d in select vd.id, vd.tenant_id, vd.doc_type, vd.expiry_date, v.name as vendor_name
             from vendorflow.vendor_documents vd join vendorflow.vendors v on v.id = vd.vendor_id
             where vd.expiry_date is not null and vd.expiry_date <= current_date + 30 and v.status in ('Approved', 'Suspended')
               and (p_tenant_id is null or vd.tenant_id = p_tenant_id) loop
        v_bucket := case when d.expiry_date < current_date then 'expired' when d.expiry_date <= current_date + 7 then '7' else '30' end;
        call vendorflow.sp_notify_roles(d.tenant_id, array['ProcurementManager', 'OrganizationOwner'], 'document_expiring',
            case when v_bucket = 'expired' then 'Vendor document expired' else 'Vendor document expiring' end,
            d.doc_type || ' — ' || d.vendor_name || ' (' || d.expiry_date || ')', 'vendor', null,
            'doc:' || d.id || ':' || v_bucket);
    end loop;
    select count(*) into v_after from vendorflow.notifications where type = 'document_expiring' and (p_tenant_id is null or tenant_id = p_tenant_id);
    return (v_after - v_before)::int;
end $$;

-- Approved invoices due within 3 days or overdue.
create or replace function vendorflow.fn_job_invoice_due(p_tenant_id uuid default null)
returns int language plpgsql as $$
declare
    i record;
    v_before bigint; v_after bigint;
begin
    select count(*) into v_before from vendorflow.notifications where type in ('invoice_due', 'invoice_overdue') and (p_tenant_id is null or tenant_id = p_tenant_id);
    for i in select inv.id, inv.tenant_id, inv.invoice_number, inv.due_date, inv.total - inv.paid_amount as balance, v.name as vendor_name
             from vendorflow.invoices inv join vendorflow.vendors v on v.id = inv.vendor_id
             where inv.status in ('Approved', 'PartiallyPaid') and inv.due_date <= current_date + 3
               and (p_tenant_id is null or inv.tenant_id = p_tenant_id) loop
        if i.due_date < current_date then
            call vendorflow.sp_notify_roles(i.tenant_id, array['FinanceManager', 'AccountsPayableOfficer'], 'invoice_overdue', 'Invoice overdue',
                i.invoice_number || ' · ' || i.vendor_name, 'invoice', i.id, 'inv-overdue:' || i.id || ':' || i.due_date);
        else
            call vendorflow.sp_notify_roles(i.tenant_id, array['FinanceManager', 'AccountsPayableOfficer'], 'invoice_due', 'Invoice due soon',
                i.invoice_number || ' · ' || i.vendor_name || ' · due ' || i.due_date, 'invoice', i.id, 'inv-due:' || i.id || ':' || i.due_date);
        end if;
    end loop;
    select count(*) into v_after from vendorflow.notifications where type in ('invoice_due', 'invoice_overdue') and (p_tenant_id is null or tenant_id = p_tenant_id);
    return (v_after - v_before)::int;
end $$;

-- Issued POs whose delivery is due within 2 days or overdue: told to the PO creator.
create or replace function vendorflow.fn_job_delivery_due(p_tenant_id uuid default null)
returns int language plpgsql as $$
declare
    p record;
    v_before bigint; v_after bigint;
begin
    select count(*) into v_before from vendorflow.notifications where type in ('delivery_due', 'delivery_overdue') and (p_tenant_id is null or tenant_id = p_tenant_id);
    for p in select po.id, po.tenant_id, po.number, po.created_by, po.expected_delivery, v.name as vendor_name
             from vendorflow.purchase_orders po join vendorflow.vendors v on v.id = po.vendor_id
             where po.status in ('Issued', 'PartiallyReceived') and po.expected_delivery is not null and po.expected_delivery <= current_date + 2
               and (p_tenant_id is null or po.tenant_id = p_tenant_id) loop
        call vendorflow.sp_notify_user(p.tenant_id, p.created_by,
            case when p.expected_delivery < current_date then 'delivery_overdue' else 'delivery_due' end,
            case when p.expected_delivery < current_date then 'Delivery overdue' else 'Delivery due soon' end,
            p.number || ' · ' || p.vendor_name || ' · expected ' || p.expected_delivery, 'purchase_order', p.id,
            'po-due:' || p.id || ':' || p.expected_delivery);
    end loop;
    select count(*) into v_after from vendorflow.notifications where type in ('delivery_due', 'delivery_overdue') and (p_tenant_id is null or tenant_id = p_tenant_id);
    return (v_after - v_before)::int;
end $$;

-- Closes expired RFQs and warns the owner about RFQs closing within 24 hours.
create or replace function vendorflow.fn_job_rfq_deadlines(p_tenant_id uuid default null)
returns int language plpgsql as $$
declare
    r record;
    v_closed int := 0;
    v_before bigint; v_after bigint;
begin
    select count(*) into v_before from vendorflow.notifications where type in ('rfq_closing', 'rfq_closed') and (p_tenant_id is null or tenant_id = p_tenant_id);
    for r in select id, tenant_id, number, created_by, deadline from vendorflow.rfqs
             where status = 'Open' and deadline < now() and (p_tenant_id is null or tenant_id = p_tenant_id) for update skip locked loop
        update vendorflow.rfqs set status = 'Closed', updated_at = now() where id = r.id;
        call vendorflow.sp_history(r.tenant_id, 'rfq', r.id, 'closed', 'Open', 'Closed', 'Deadline passed', null);
        call vendorflow.sp_notify_user(r.tenant_id, r.created_by, 'rfq_closed', 'RFQ closed', r.number || ' reached its deadline', 'rfq', r.id, 'rfq-closed:' || r.id);
        v_closed := v_closed + 1;
    end loop;
    for r in select id, tenant_id, number, created_by, deadline from vendorflow.rfqs
             where status = 'Open' and deadline between now() and now() + interval '24 hours' and (p_tenant_id is null or tenant_id = p_tenant_id) loop
        call vendorflow.sp_notify_user(r.tenant_id, r.created_by, 'rfq_closing', 'RFQ closes within 24 hours', r.number, 'rfq', r.id, 'rfq-closing:' || r.id);
    end loop;
    select count(*) into v_after from vendorflow.notifications where type in ('rfq_closing', 'rfq_closed') and (p_tenant_id is null or tenant_id = p_tenant_id);
    return (v_after - v_before)::int + 0 * v_closed;
end $$;

-- Reminds approvers about requests waiting more than 2 days (one reminder per request, step and day).
create or replace function vendorflow.fn_job_approval_reminders(p_tenant_id uuid default null)
returns int language plpgsql as $$
declare
    r record;
    v_before bigint; v_after bigint;
begin
    select count(*) into v_before from vendorflow.notifications where type = 'approval_reminder' and (p_tenant_id is null or tenant_id = p_tenant_id);
    for r in select ar.id, ar.tenant_id, ar.title, ar.current_step, s.role_code, ar.entity_type, ar.entity_id
             from vendorflow.approval_requests ar join vendorflow.approval_steps s on s.request_id = ar.id and s.step_no = ar.current_step
             where ar.status = 'Pending' and ar.created_at < now() - interval '2 days' and (p_tenant_id is null or ar.tenant_id = p_tenant_id) loop
        call vendorflow.sp_notify_role(r.tenant_id, r.role_code, 'approval_reminder', 'Approval waiting for more than 2 days', r.title,
            r.entity_type, r.entity_id, 'approval-reminder:' || r.id || ':' || r.current_step || ':' || current_date);
    end loop;
    select count(*) into v_after from vendorflow.notifications where type = 'approval_reminder' and (p_tenant_id is null or tenant_id = p_tenant_id);
    return (v_after - v_before)::int;
end $$;

-- Runs every check. Returns the number of NEW notifications per check.
create or replace function vendorflow.fn_job_run_all(p_tenant_id uuid default null)
returns jsonb language plpgsql as $$
begin
    return jsonb_build_object(
        'document_expiry', vendorflow.fn_job_vendor_doc_expiry(p_tenant_id),
        'invoice_due', vendorflow.fn_job_invoice_due(p_tenant_id),
        'delivery_due', vendorflow.fn_job_delivery_due(p_tenant_id),
        'rfq_deadlines', vendorflow.fn_job_rfq_deadlines(p_tenant_id),
        'approval_reminders', vendorflow.fn_job_approval_reminders(p_tenant_id));
end $$;

-- ---------------------------------------------------------------- e-mail outbox (worker)

-- Claims pending e-mails for sending (each claim counts as an attempt; max 5 attempts).
create or replace function vendorflow.fn_email_outbox_claim(p_limit int)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
    with c as (
        select id from vendorflow.email_outbox where status = 'Pending' and attempts < 5
        order by created_at limit greatest(p_limit, 1) for update skip locked
    ), u as (
        update vendorflow.email_outbox o set attempts = attempts + 1 from c where o.id = c.id
        returning o.id, o.to_email, o.subject, o.body, o.attempts
    )
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'to_email', to_email, 'subject', subject, 'body', body, 'attempts', attempts)), '[]'::jsonb) into v from u;
    return v;
end $$;

create or replace procedure vendorflow.sp_email_outbox_result(p_id uuid, p_success boolean, p_error text)
language sql as $$
    update vendorflow.email_outbox set
        status = case when p_success then 'Sent' when attempts >= 5 then 'Failed' else 'Pending' end,
        sent_at = case when p_success then now() else sent_at end,
        last_error = case when p_success then null else left(p_error, 500) end
    where id = p_id;
$$;
