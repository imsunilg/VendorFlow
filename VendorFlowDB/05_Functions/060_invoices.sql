-- Invoices: registration, duplicate check, 2-way / 3-way matching with tolerance, discrepancies, reconcile (approve).
--
-- Matching (per invoice line, against the PO line and the ACCEPTED goods receipt quantity):
--   qty      : invoiced qty must not exceed available qty (3-way: accepted received; 2-way: ordered) minus qty already on other
--              matched/approved/paid invoices
--   rate     : invoice rate must equal the PO rate
--   discount : invoice discount % must equal the PO discount %
--   tax      : invoice tax must be within 1.00 of tax calculated on the invoice net with the PO tax %
--   total    : |invoice total - receipt value| / receipt value must be within the tenant tolerance %
--              (receipt value = value at PO terms of min(invoiced qty, available qty) per line, incl. tax)
-- Any discrepancy is mandatory: the invoice is NeedsReview and cannot be reconciled.

-- Writes invoice lines from the payload and refreshes header totals.
create or replace procedure vendorflow.sp_invoice_write_items(p_tenant_id uuid, p_invoice_id uuid, p_po_id uuid, p_items jsonb)
language plpgsql as $$
declare
    it jsonb;
    pi vendorflow.po_items%rowtype;
    v_qty numeric; v_rate numeric; v_dp numeric;
    v_gross numeric; v_net numeric; v_tax numeric;
    v_seen uuid[] := '{}';
begin
    if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'Add at least one invoice line.' using errcode = 'VF400';
    end if;
    delete from vendorflow.invoice_items where invoice_id = p_invoice_id;

    for it in select * from jsonb_array_elements(p_items) loop
        select * into pi from vendorflow.po_items where id = (it ->> 'po_item_id')::uuid and po_id = p_po_id and tenant_id = p_tenant_id;
        if not found then raise exception 'An invoice line does not belong to the selected purchase order.' using errcode = 'VF400'; end if;
        if pi.id = any(v_seen) then raise exception 'Purchase order line % appears twice.', pi.line_no using errcode = 'VF400'; end if;
        v_seen := v_seen || pi.id;

        v_qty := (it ->> 'quantity')::numeric;
        v_rate := coalesce((it ->> 'rate')::numeric, pi.rate);
        v_dp := coalesce((it ->> 'discount_percent')::numeric, pi.discount_percent);
        if v_qty is null or v_qty <= 0 then raise exception 'Invoice quantity must be greater than zero.' using errcode = 'VF400'; end if;
        if v_rate < 0 or v_dp < 0 or v_dp > 100 then raise exception 'Rate or discount is invalid.' using errcode = 'VF400'; end if;
        if (it ->> 'tax_amount') is not null and (it ->> 'tax_amount')::numeric < 0 then raise exception 'Tax cannot be negative.' using errcode = 'VF400'; end if;

        v_gross := round(v_qty * round(v_rate, 2), 2);
        v_net := v_gross - round(v_gross * v_dp / 100, 2);
        v_tax := coalesce((it ->> 'tax_amount')::numeric, round(v_net * pi.tax_percent / 100, 2));
        insert into vendorflow.invoice_items (tenant_id, invoice_id, po_item_id, description, quantity, rate, discount_percent, net_amount, tax_amount, line_total)
        values (p_tenant_id, p_invoice_id, pi.id, pi.description, v_qty, round(v_rate, 2), v_dp, v_net, round(v_tax, 2), v_net + round(v_tax, 2));
    end loop;

    update vendorflow.invoices i set
        subtotal = (select coalesce(sum(net_amount), 0) from vendorflow.invoice_items where invoice_id = i.id),
        tax_total = (select coalesce(sum(tax_amount), 0) from vendorflow.invoice_items where invoice_id = i.id),
        total = (select coalesce(sum(line_total), 0) from vendorflow.invoice_items where invoice_id = i.id),
        updated_at = now(), row_version = row_version + 1
    where i.id = p_invoice_id;
end $$;

-- Runs the matching rules and stores discrepancies. Sets status Matched / NeedsReview (for non-final invoices).
create or replace procedure vendorflow.sp_invoice_run_match(p_tenant_id uuid, p_invoice_id uuid)
language plpgsql as $$
declare
    inv vendorflow.invoices%rowtype;
    r record;
    v_tol numeric;
    v_prev numeric; v_avail numeric; v_elig numeric;
    v_gross numeric; v_net numeric; v_tax numeric;
    v_exp_tax numeric;
    v_receipt numeric := 0;
    v_var numeric; v_pct numeric; v_count int;
    v_basis text;
begin
    select * into inv from vendorflow.invoices where id = p_invoice_id and tenant_id = p_tenant_id;
    select invoice_tolerance_pct into v_tol from vendorflow.tenant_settings where tenant_id = p_tenant_id;
    v_basis := case when inv.match_type = 'ThreeWay' then 'accepted at receipt' else 'ordered' end;
    delete from vendorflow.invoice_discrepancies where invoice_id = inv.id and not raised_manually;

    for r in select ii.*, pi.line_no, pi.quantity as po_qty, pi.rate as po_rate, pi.discount_percent as po_disc,
                    pi.tax_percent as po_tax, pi.received_qty as grn_qty
             from vendorflow.invoice_items ii join vendorflow.po_items pi on pi.id = ii.po_item_id
             where ii.invoice_id = inv.id order by pi.line_no loop
        select coalesce(sum(ii2.quantity), 0) into v_prev
        from vendorflow.invoice_items ii2 join vendorflow.invoices i2 on i2.id = ii2.invoice_id
        where ii2.po_item_id = r.po_item_id and i2.id <> inv.id and i2.status in ('Matched', 'Approved', 'PartiallyPaid', 'Paid');
        v_avail := (case when inv.match_type = 'ThreeWay' then r.grn_qty else r.po_qty end) - v_prev;

        if r.quantity > v_avail then
            insert into vendorflow.invoice_discrepancies (tenant_id, invoice_id, po_item_id, check_name, expected, actual, message)
            values (p_tenant_id, inv.id, r.po_item_id, 'qty', greatest(v_avail, 0)::text, r.quantity::text,
                    'Line ' || r.line_no || ': invoiced ' || r.quantity::numeric(18,3)::float8 || ', only ' || greatest(v_avail, 0)::numeric(18,3)::float8 || ' ' || v_basis || ' (and not yet invoiced).');
        end if;
        if r.rate <> r.po_rate then
            insert into vendorflow.invoice_discrepancies (tenant_id, invoice_id, po_item_id, check_name, expected, actual, message)
            values (p_tenant_id, inv.id, r.po_item_id, 'rate', r.po_rate::text, r.rate::text,
                    'Line ' || r.line_no || ': rate ' || r.rate || ' differs from PO rate ' || r.po_rate || '.');
        end if;
        if abs(r.discount_percent - r.po_disc) > 0.0001 then
            insert into vendorflow.invoice_discrepancies (tenant_id, invoice_id, po_item_id, check_name, expected, actual, message)
            values (p_tenant_id, inv.id, r.po_item_id, 'discount', r.po_disc::text, r.discount_percent::text,
                    'Line ' || r.line_no || ': discount ' || r.discount_percent::float8 || '% differs from PO discount ' || r.po_disc::float8 || '%.');
        end if;
        v_exp_tax := round(r.net_amount * r.po_tax / 100, 2);
        if abs(r.tax_amount - v_exp_tax) > 1 then
            insert into vendorflow.invoice_discrepancies (tenant_id, invoice_id, po_item_id, check_name, expected, actual, message)
            values (p_tenant_id, inv.id, r.po_item_id, 'tax', v_exp_tax::text, r.tax_amount::text,
                    'Line ' || r.line_no || ': tax differs by ' || abs(r.tax_amount - v_exp_tax) || ' from the expected ' || v_exp_tax || '.');
        end if;

        v_elig := least(r.quantity, greatest(v_avail, 0));
        v_gross := round(v_elig * r.po_rate, 2);
        v_net := v_gross - round(v_gross * r.po_disc / 100, 2);
        v_tax := round(v_net * r.po_tax / 100, 2);
        v_receipt := v_receipt + v_net + v_tax;
    end loop;

    v_var := inv.total - v_receipt;
    v_pct := case when v_receipt = 0 then (case when inv.total = 0 then 0 else 100 end) else round(100 * v_var / v_receipt, 4) end;
    if abs(v_pct) > v_tol then
        insert into vendorflow.invoice_discrepancies (tenant_id, invoice_id, check_name, expected, actual, message)
        values (p_tenant_id, inv.id, 'total_variance', v_receipt::text, inv.total::text,
                'Invoice total differs from the receipt value by ' || v_var || ' (' || v_pct::numeric(9,2) || '%), tolerance is ' || v_tol::float8 || '%.');
    end if;

    select count(*) into v_count from vendorflow.invoice_discrepancies where invoice_id = inv.id;
    update vendorflow.invoices set receipt_value = v_receipt, variance_amount = v_var, variance_pct = v_pct,
        status = case when status in ('Registered', 'NeedsReview', 'Matched', 'Disputed') then (case when v_count > 0 then 'NeedsReview' else 'Matched' end) else status end,
        updated_at = now()
    where id = inv.id;
end $$;

create or replace function vendorflow.fn_invoice_get(p_tenant_id uuid, p_id uuid)
returns jsonb language plpgsql stable as $$
declare v_json jsonb;
begin
    select jsonb_build_object(
        'id', i.id, 'invoice_number', i.invoice_number, 'vendor_id', i.vendor_id, 'vendor_name', vd.name,
        'po_id', i.po_id, 'po_number', p.number, 'invoice_date', i.invoice_date, 'due_date', i.due_date, 'currency', i.currency,
        'subtotal', i.subtotal, 'tax_total', i.tax_total, 'total', i.total, 'paid_amount', i.paid_amount, 'balance', i.total - i.paid_amount,
        'status', i.status, 'match_type', i.match_type, 'receipt_value', i.receipt_value, 'variance_amount', i.variance_amount,
        'variance_pct', i.variance_pct, 'tolerance_pct', s.invoice_tolerance_pct, 'notes', i.notes, 'row_version', i.row_version,
        'is_overdue', (i.status in ('Approved', 'PartiallyPaid') and i.due_date < current_date),
        'days_overdue', case when i.status in ('Approved', 'PartiallyPaid') and i.due_date < current_date then current_date - i.due_date else 0 end,
        'created_at', i.created_at,
        'duplicate_check', jsonb_build_object('basis', 'tenant + vendor + invoice number',
            'duplicate_found', exists (select 1 from vendorflow.invoices d where d.tenant_id = i.tenant_id and d.vendor_id = i.vendor_id
                                       and lower(d.invoice_number) = lower(i.invoice_number) and d.id <> i.id and d.status <> 'Cancelled')),
        'lines', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', ii.id, 'po_item_id', ii.po_item_id, 'line_no', pi.line_no, 'description', ii.description,
                    'po_qty', pi.quantity, 'po_rate', pi.rate, 'po_discount_percent', pi.discount_percent, 'po_tax_percent', pi.tax_percent,
                    'grn_qty', pi.received_qty,
                    'previously_invoiced_qty', (select coalesce(sum(x.quantity), 0) from vendorflow.invoice_items x join vendorflow.invoices xi on xi.id = x.invoice_id
                                                where x.po_item_id = ii.po_item_id and xi.id <> i.id and xi.status in ('Matched', 'Approved', 'PartiallyPaid', 'Paid')),
                    'invoice_qty', ii.quantity, 'invoice_rate', ii.rate, 'invoice_discount_percent', ii.discount_percent,
                    'net_amount', ii.net_amount, 'invoice_tax', ii.tax_amount, 'expected_tax', round(ii.net_amount * pi.tax_percent / 100, 2),
                    'line_total', ii.line_total,
                    'qty_ok', not exists (select 1 from vendorflow.invoice_discrepancies d where d.invoice_id = i.id and d.po_item_id = ii.po_item_id and d.check_name = 'qty'),
                    'rate_ok', not exists (select 1 from vendorflow.invoice_discrepancies d where d.invoice_id = i.id and d.po_item_id = ii.po_item_id and d.check_name in ('rate', 'discount')),
                    'tax_ok', not exists (select 1 from vendorflow.invoice_discrepancies d where d.invoice_id = i.id and d.po_item_id = ii.po_item_id and d.check_name = 'tax'))
                    order by pi.line_no)
                  from vendorflow.invoice_items ii join vendorflow.po_items pi on pi.id = ii.po_item_id where ii.invoice_id = i.id), '[]'::jsonb),
        'discrepancies', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'check_name', d.check_name, 'expected', d.expected,
                    'actual', d.actual, 'message', d.message, 'mandatory', d.mandatory, 'raised_manually', d.raised_manually) order by d.created_at, d.id)
                  from vendorflow.invoice_discrepancies d where d.invoice_id = i.id), '[]'::jsonb),
        'payments', coalesce((select jsonb_agg(jsonb_build_object('id', pay.id, 'number', pay.number, 'amount', pay.amount, 'method', pay.method,
                    'reference', pay.reference, 'paid_on', pay.paid_on) order by pay.created_at)
                  from vendorflow.payments pay where pay.invoice_id = i.id), '[]'::jsonb),
        'attachments', vendorflow.fn_attachment_list(p_tenant_id, 'invoice', i.id),
        'history', vendorflow.fn_history_list(p_tenant_id, 'invoice', i.id))
    into v_json
    from vendorflow.invoices i
    join vendorflow.vendors vd on vd.id = i.vendor_id
    join vendorflow.tenant_settings s on s.tenant_id = i.tenant_id
    left join vendorflow.purchase_orders p on p.id = i.po_id
    where i.id = p_id and i.tenant_id = p_tenant_id;
    if v_json is null then raise exception 'Invoice not found.' using errcode = 'VF404'; end if;
    return v_json;
end $$;

-- Registers an invoice against a PO, checks duplicates and runs the match.
create or replace function vendorflow.fn_invoice_register(p_tenant_id uuid, p_actor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    po vendorflow.purchase_orders%rowtype;
    vd vendorflow.vendors%rowtype;
    v_no text := btrim(coalesce(p_data ->> 'invoice_number', ''));
    v_date date := nullif(p_data ->> 'invoice_date', '')::date;
    v_due date;
    v_type text := coalesce(p_data ->> 'match_type', 'ThreeWay');
    v_id uuid;
begin
    if v_no = '' then raise exception 'Invoice number is required.' using errcode = 'VF400'; end if;
    if v_date is null then raise exception 'Invoice date is required.' using errcode = 'VF400'; end if;
    if v_date > current_date then raise exception 'Invoice date cannot be in the future.' using errcode = 'VF400'; end if;
    if v_type not in ('TwoWay', 'ThreeWay') then raise exception 'match_type must be TwoWay or ThreeWay.' using errcode = 'VF400'; end if;

    select * into po from vendorflow.purchase_orders where id = (p_data ->> 'po_id')::uuid and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if po.status not in ('Issued', 'PartiallyReceived', 'FullyReceived', 'Closed', 'OnHold') then
        raise exception 'Invoices can only be registered against an issued purchase order (it is %).', po.status using errcode = 'VF409';
    end if;
    select * into vd from vendorflow.vendors where id = po.vendor_id;

    if exists (select 1 from vendorflow.invoices where tenant_id = p_tenant_id and vendor_id = po.vendor_id
               and lower(invoice_number) = lower(v_no) and status <> 'Cancelled') then
        raise exception 'Duplicate invoice: % was already registered for this vendor.', v_no using errcode = 'VF409';
    end if;
    v_due := coalesce(nullif(p_data ->> 'due_date', '')::date, v_date + vd.payment_terms_days);
    if v_due < v_date then raise exception 'Due date cannot be before the invoice date.' using errcode = 'VF400'; end if;

    insert into vendorflow.invoices (tenant_id, invoice_number, vendor_id, po_id, invoice_date, due_date, currency, total, match_type, notes, created_by)
    values (p_tenant_id, v_no, po.vendor_id, po.id, v_date, v_due, po.currency, 0, v_type, p_data ->> 'notes', p_actor_id)
    returning id into v_id;
    call vendorflow.sp_invoice_write_items(p_tenant_id, v_id, po.id, p_data -> 'items');
    call vendorflow.sp_invoice_run_match(p_tenant_id, v_id);

    call vendorflow.sp_history(p_tenant_id, 'invoice', v_id, 'registered', null, 'Registered', null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'invoice.registered', 'invoice', v_id, jsonb_build_object('po_id', po.id));
    return vendorflow.fn_invoice_get(p_tenant_id, v_id);
end $$;

-- Corrects an invoice (while it is not approved) and runs the match again.
create or replace function vendorflow.fn_invoice_update(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare inv vendorflow.invoices%rowtype;
begin
    select * into inv from vendorflow.invoices where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Invoice not found.' using errcode = 'VF404'; end if;
    if inv.status not in ('Registered', 'NeedsReview', 'Matched', 'Disputed') then
        raise exception 'An invoice that is % cannot be edited.', inv.status using errcode = 'VF409';
    end if;
    if p_data ? 'row_version' and (p_data ->> 'row_version')::int <> inv.row_version then
        raise exception 'This invoice was changed by someone else. Reload and try again.' using errcode = 'VF409';
    end if;
    perform 1 from vendorflow.purchase_orders where id = inv.po_id for update;

    update vendorflow.invoices set
        due_date = coalesce(nullif(p_data ->> 'due_date', '')::date, due_date),
        invoice_date = coalesce(nullif(p_data ->> 'invoice_date', '')::date, invoice_date),
        notes = case when p_data ? 'notes' then p_data ->> 'notes' else notes end,
        match_type = coalesce(p_data ->> 'match_type', match_type),
        status = 'Registered'
    where id = inv.id;
    if (select due_date < invoice_date from vendorflow.invoices where id = inv.id) then
        raise exception 'Due date cannot be before the invoice date.' using errcode = 'VF400';
    end if;
    delete from vendorflow.invoice_discrepancies where invoice_id = inv.id;       -- includes manual ones: the corrected invoice is re-checked from scratch
    if p_data ? 'items' then call vendorflow.sp_invoice_write_items(p_tenant_id, inv.id, inv.po_id, p_data -> 'items'); end if;
    call vendorflow.sp_invoice_run_match(p_tenant_id, inv.id);
    call vendorflow.sp_history(p_tenant_id, 'invoice', inv.id, 'updated', inv.status, null, null, p_actor_id);
    return vendorflow.fn_invoice_get(p_tenant_id, inv.id);
end $$;

-- Runs the matching again (for example after a late goods receipt was posted).
create or replace function vendorflow.fn_invoice_rematch(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
declare inv vendorflow.invoices%rowtype;
begin
    select * into inv from vendorflow.invoices where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Invoice not found.' using errcode = 'VF404'; end if;
    if inv.status not in ('Registered', 'NeedsReview', 'Matched') then
        raise exception 'An invoice that is % cannot be matched again.', inv.status using errcode = 'VF409';
    end if;
    perform 1 from vendorflow.purchase_orders where id = inv.po_id for update;
    call vendorflow.sp_invoice_run_match(p_tenant_id, inv.id);
    call vendorflow.sp_history(p_tenant_id, 'invoice', inv.id, 'rematched', inv.status, null, null, p_actor_id);
    return vendorflow.fn_invoice_get(p_tenant_id, inv.id);
end $$;

create or replace function vendorflow.fn_invoice_dispute(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_message text)
returns jsonb language plpgsql as $$
declare inv vendorflow.invoices%rowtype;
begin
    select * into inv from vendorflow.invoices where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Invoice not found.' using errcode = 'VF404'; end if;
    if inv.status not in ('Registered', 'NeedsReview', 'Matched') then
        raise exception 'A discrepancy cannot be raised on an invoice that is %.', inv.status using errcode = 'VF409';
    end if;
    if coalesce(btrim(p_message), '') = '' then raise exception 'Describe the discrepancy.' using errcode = 'VF400'; end if;
    insert into vendorflow.invoice_discrepancies (tenant_id, invoice_id, check_name, message, raised_manually)
    values (p_tenant_id, inv.id, 'manual', btrim(p_message), true);
    update vendorflow.invoices set status = 'Disputed', updated_at = now(), row_version = row_version + 1 where id = inv.id;
    call vendorflow.sp_history(p_tenant_id, 'invoice', inv.id, 'discrepancy_raised', inv.status, 'Disputed', p_message, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'invoice.disputed', 'invoice', inv.id, null);
    return vendorflow.fn_invoice_get(p_tenant_id, inv.id);
end $$;

-- Reconcile = approve for payment. Impossible while mandatory matching fails; matching is re-run under a PO lock.
create or replace function vendorflow.fn_invoice_reconcile(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_comment text)
returns jsonb language plpgsql as $$
declare
    inv vendorflow.invoices%rowtype;
    v_status text;
begin
    select * into inv from vendorflow.invoices where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Invoice not found.' using errcode = 'VF404'; end if;
    if inv.status in ('Approved', 'PartiallyPaid', 'Paid') then raise exception 'This invoice is already reconciled.' using errcode = 'VF409'; end if;
    if inv.status in ('Cancelled', 'Disputed') then raise exception 'An invoice that is % cannot be reconciled.', inv.status using errcode = 'VF409'; end if;
    perform 1 from vendorflow.purchase_orders where id = inv.po_id for update;

    call vendorflow.sp_invoice_run_match(p_tenant_id, inv.id);
    select status into v_status from vendorflow.invoices where id = inv.id;
    if v_status <> 'Matched' then
        raise exception 'Mandatory matching failed (% discrepancies). Correct the invoice or raise a discrepancy.',
            (select count(*) from vendorflow.invoice_discrepancies where invoice_id = inv.id) using errcode = 'VF409';
    end if;

    update vendorflow.invoices set status = 'Approved', updated_at = now(), row_version = row_version + 1 where id = inv.id;
    update vendorflow.po_items pi set invoiced_qty = invoiced_qty + ii.quantity from vendorflow.invoice_items ii
    where ii.invoice_id = inv.id and ii.po_item_id = pi.id;

    call vendorflow.sp_history(p_tenant_id, 'invoice', inv.id, 'reconciled', 'Matched', 'Approved', p_comment, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'invoice.reconciled', 'invoice', inv.id, null);
    return vendorflow.fn_invoice_get(p_tenant_id, inv.id);
end $$;

create or replace function vendorflow.fn_invoice_cancel(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_comment text)
returns jsonb language plpgsql as $$
declare inv vendorflow.invoices%rowtype;
begin
    select * into inv from vendorflow.invoices where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Invoice not found.' using errcode = 'VF404'; end if;
    if inv.status = 'Cancelled' then raise exception 'This invoice is already cancelled.' using errcode = 'VF409'; end if;
    if inv.paid_amount > 0 then raise exception 'An invoice with payments cannot be cancelled.' using errcode = 'VF409'; end if;
    if coalesce(btrim(p_comment), '') = '' then raise exception 'A reason is required.' using errcode = 'VF400'; end if;
    if inv.status = 'Approved' then
        update vendorflow.po_items pi set invoiced_qty = greatest(invoiced_qty - ii.quantity, 0) from vendorflow.invoice_items ii
        where ii.invoice_id = inv.id and ii.po_item_id = pi.id;
    end if;
    update vendorflow.invoices set status = 'Cancelled', updated_at = now(), row_version = row_version + 1 where id = inv.id;
    call vendorflow.sp_history(p_tenant_id, 'invoice', inv.id, 'cancelled', inv.status, 'Cancelled', p_comment, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'invoice.cancelled', 'invoice', inv.id, null);
    return vendorflow.fn_invoice_get(p_tenant_id, inv.id);
end $$;

-- p_tab: all | outstanding | overdue (status filter applies on top).
create or replace function vendorflow.fn_invoice_list(
    p_tenant_id uuid, p_tab text default 'all', p_status text default null, p_vendor_id uuid default null, p_search text default null,
    p_sort_by text default null, p_sort_dir text default null, p_page int default 1, p_page_size int default 20)
returns jsonb language plpgsql stable as $$
declare
    v_page int := greatest(coalesce(p_page, 1), 1);
    v_size int := least(greatest(coalesce(p_page_size, 20), 1), 200);
    v_order text := vendorflow.fn_sort_clause(p_sort_by, p_sort_dir, array['invoice_number','invoice_date','due_date','status','total','created_at'], 'created_at');
    v_where text := $w$ i.tenant_id = $1
        and ($2 <> 'outstanding' or i.status in ('Approved','PartiallyPaid'))
        and ($2 <> 'overdue' or (i.status in ('Approved','PartiallyPaid') and i.due_date < current_date))
        and ($3 is null or $3 = '' or i.status = $3) and ($4 is null or i.vendor_id = $4)
        and ($5 is null or $5 = '' or i.invoice_number ilike '%' || $5 || '%'
             or exists (select 1 from vendorflow.vendors v where v.id = i.vendor_id and v.name ilike '%' || $5 || '%')) $w$;
    v_total bigint; v_items jsonb; v_counts jsonb;
begin
    execute 'select count(*) from vendorflow.invoices i where ' || v_where into v_total
        using p_tenant_id, coalesce(p_tab, 'all'), p_status, p_vendor_id, p_search;
    execute format($q$
        select coalesce(jsonb_agg(x), '[]'::jsonb) from (
            select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'vendor_id', i.vendor_id,
                'vendor_name', (select name from vendorflow.vendors where id = i.vendor_id),
                'po_number', (select number from vendorflow.purchase_orders where id = i.po_id),
                'invoice_date', i.invoice_date, 'due_date', i.due_date, 'status', i.status, 'total', i.total, 'paid_amount', i.paid_amount,
                'balance', i.total - i.paid_amount, 'currency', i.currency,
                'is_overdue', (i.status in ('Approved','PartiallyPaid') and i.due_date < current_date),
                'days_overdue', case when i.status in ('Approved','PartiallyPaid') and i.due_date < current_date then current_date - i.due_date else 0 end,
                'variance_pct', i.variance_pct) as x
            from vendorflow.invoices i where %s order by %s offset %s limit %s) s$q$, v_where, v_order, (v_page - 1) * v_size, v_size)
        into v_items using p_tenant_id, coalesce(p_tab, 'all'), p_status, p_vendor_id, p_search;

    select coalesce(jsonb_object_agg(status, c), '{}'::jsonb) || jsonb_build_object('All', coalesce(sum(c), 0))
    into v_counts from (select status, count(*) c from vendorflow.invoices where tenant_id = p_tenant_id group by status) g;
    v_counts := v_counts || jsonb_build_object(
        'Outstanding', (select count(*) from vendorflow.invoices where tenant_id = p_tenant_id and status in ('Approved', 'PartiallyPaid')),
        'Overdue', (select count(*) from vendorflow.invoices where tenant_id = p_tenant_id and status in ('Approved', 'PartiallyPaid') and due_date < current_date));
    return vendorflow.fn_page(v_items, v_total, v_page, v_size) || jsonb_build_object('status_counts', v_counts);
end $$;
