-- Payments: record only (no real bank transfer). Idempotency key, no overpayment, partial payments.

-- Records a payment against a reconciled invoice. INOUT p_result receives the payment (replayed = true when the key was seen before).
create or replace procedure vendorflow.sp_payment_record(
    p_tenant_id uuid, p_actor_id uuid, p_invoice_id uuid, p_amount numeric, p_method text, p_reference text,
    p_paid_on date, p_idempotency_key text, p_notes text, inout p_result jsonb default null)
language plpgsql as $$
declare
    inv vendorflow.invoices%rowtype;
    ex vendorflow.payments%rowtype;
    v_id uuid;
    v_number text;
    v_new_paid numeric;
    v_new_status text;
begin
    if coalesce(btrim(p_idempotency_key), '') = '' then raise exception 'An idempotency key is required.' using errcode = 'VF400'; end if;

    -- lock the invoice first: concurrent requests with the same key then see each other's result
    select * into inv from vendorflow.invoices where id = p_invoice_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Invoice not found.' using errcode = 'VF404'; end if;

    select * into ex from vendorflow.payments where tenant_id = p_tenant_id and idempotency_key = btrim(p_idempotency_key);
    if found then
        if ex.invoice_id <> p_invoice_id or ex.amount <> p_amount then
            raise exception 'This idempotency key was already used for a different payment.' using errcode = 'VF409';
        end if;
        p_result := jsonb_build_object('id', ex.id, 'number', ex.number, 'invoice_id', ex.invoice_id, 'amount', ex.amount,
            'method', ex.method, 'reference', ex.reference, 'paid_on', ex.paid_on, 'replayed', true,
            'invoice_status', inv.status, 'balance', inv.total - inv.paid_amount);
        return;
    end if;

    if inv.status not in ('Approved', 'PartiallyPaid') then
        raise exception 'Payments can only be recorded for a reconciled invoice (it is %).', inv.status using errcode = 'VF409';
    end if;
    if p_amount is null or p_amount <= 0 then raise exception 'Amount must be greater than zero.' using errcode = 'VF400'; end if;
    if p_amount <> round(p_amount, 2) then raise exception 'Amount can have at most 2 decimals.' using errcode = 'VF400'; end if;
    if p_amount > inv.total - inv.paid_amount then
        raise exception 'Overpayment: balance is % but % was entered.', inv.total - inv.paid_amount, p_amount using errcode = 'VF409';
    end if;
    if p_method not in ('NEFT', 'RTGS', 'UPI', 'IMPS', 'Cheque', 'Cash', 'Other') then
        raise exception 'Unknown payment method.' using errcode = 'VF400';
    end if;
    if coalesce(p_paid_on, current_date) > current_date then raise exception 'Payment date cannot be in the future.' using errcode = 'VF400'; end if;

    v_number := vendorflow.fn_next_number(p_tenant_id, 'payment');
    insert into vendorflow.payments (tenant_id, number, invoice_id, vendor_id, amount, method, reference, paid_on, idempotency_key, notes, created_by)
    values (p_tenant_id, v_number, inv.id, inv.vendor_id, p_amount, p_method, nullif(btrim(p_reference), ''), coalesce(p_paid_on, current_date),
            btrim(p_idempotency_key), p_notes, p_actor_id)
    returning id into v_id;

    v_new_paid := inv.paid_amount + p_amount;
    v_new_status := case when v_new_paid >= inv.total then 'Paid' else 'PartiallyPaid' end;
    update vendorflow.invoices set paid_amount = v_new_paid, status = v_new_status, updated_at = now(), row_version = row_version + 1 where id = inv.id;

    call vendorflow.sp_history(p_tenant_id, 'invoice', inv.id, 'payment_recorded', inv.status, v_new_status, v_number || ' · ' || p_amount, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'payment.recorded', 'invoice', inv.id, jsonb_build_object('payment_id', v_id, 'amount', p_amount));
    p_result := jsonb_build_object('id', v_id, 'number', v_number, 'invoice_id', inv.id, 'amount', p_amount, 'method', p_method,
        'reference', p_reference, 'paid_on', coalesce(p_paid_on, current_date), 'replayed', false,
        'invoice_status', v_new_status, 'balance', inv.total - v_new_paid);
end $$;

create or replace function vendorflow.fn_payment_list(
    p_tenant_id uuid, p_invoice_id uuid default null, p_vendor_id uuid default null, p_search text default null,
    p_page int default 1, p_page_size int default 20)
returns jsonb language plpgsql stable as $$
declare
    v_page int := greatest(coalesce(p_page, 1), 1);
    v_size int := least(greatest(coalesce(p_page_size, 20), 1), 200);
    v_total bigint; v_items jsonb;
begin
    select count(*) into v_total from vendorflow.payments p join vendorflow.invoices i on i.id = p.invoice_id
    where p.tenant_id = p_tenant_id and (p_invoice_id is null or p.invoice_id = p_invoice_id) and (p_vendor_id is null or p.vendor_id = p_vendor_id)
      and (coalesce(p_search, '') = '' or p.number ilike '%' || p_search || '%' or i.invoice_number ilike '%' || p_search || '%' or p.reference ilike '%' || p_search || '%');
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_items from (
        select jsonb_build_object('id', p.id, 'number', p.number, 'invoice_id', p.invoice_id, 'invoice_number', i.invoice_number,
            'vendor_name', v.name, 'amount', p.amount, 'balance', i.total - i.paid_amount, 'method', p.method, 'reference', p.reference,
            'paid_on', p.paid_on, 'status', case when i.total - i.paid_amount > 0 then 'Partial' else 'Paid' end, 'created_at', p.created_at) as x
        from vendorflow.payments p join vendorflow.invoices i on i.id = p.invoice_id join vendorflow.vendors v on v.id = p.vendor_id
        where p.tenant_id = p_tenant_id and (p_invoice_id is null or p.invoice_id = p_invoice_id) and (p_vendor_id is null or p.vendor_id = p_vendor_id)
          and (coalesce(p_search, '') = '' or p.number ilike '%' || p_search || '%' or i.invoice_number ilike '%' || p_search || '%' or p.reference ilike '%' || p_search || '%')
        order by p.created_at desc offset (v_page - 1) * v_size limit v_size) s;
    return vendorflow.fn_page(v_items, v_total, v_page, v_size);
end $$;

-- KPI cards for the payments page.
create or replace function vendorflow.fn_payment_summary(p_tenant_id uuid)
returns jsonb language sql stable as $$
    select jsonb_build_object(
        'paid_this_month', (select coalesce(sum(amount), 0) from vendorflow.payments
                            where tenant_id = p_tenant_id and date_trunc('month', paid_on) = date_trunc('month', current_date)),
        'outstanding', coalesce(sum(total - paid_amount) filter (where status in ('Approved', 'PartiallyPaid')), 0),
        'outstanding_count', count(*) filter (where status in ('Approved', 'PartiallyPaid')),
        'overdue_count', count(*) filter (where status in ('Approved', 'PartiallyPaid') and due_date < current_date),
        'overdue_amount', coalesce(sum(total - paid_amount) filter (where status in ('Approved', 'PartiallyPaid') and due_date < current_date), 0),
        'due_in_7_days', count(*) filter (where status in ('Approved', 'PartiallyPaid') and due_date between current_date and current_date + 7))
    from vendorflow.invoices where tenant_id = p_tenant_id;
$$;
