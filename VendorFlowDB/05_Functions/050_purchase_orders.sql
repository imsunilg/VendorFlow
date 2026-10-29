-- Purchase orders: create (direct / from requisition / from quotation), approval, issue, revision, hold, close, cancel.
--
-- Same rounding rule as quotations: per line gross=round(qty*round(rate,2),2), discount=round(gross*d%/100,2),
-- net=gross-discount, tax=round(net*t%/100,2), line=net+tax. Totals are sums of rounded lines (+ shipping).

-- Writes the line items of a PO and refreshes the header totals. Lines with an "id" are updated, others inserted,
-- missing lines are removed (only possible while nothing refers to them). Quantity can never go below what was received.
create or replace procedure vendorflow.sp_po_write_items(p_tenant_id uuid, p_po_id uuid, p_items jsonb, p_shipping numeric)
language plpgsql as $$
declare
    it jsonb;
    v_id uuid;
    v_default_tax numeric;
    v_qty numeric; v_rate numeric; v_dp numeric; v_tp numeric;
    v_gross numeric; v_disc numeric; v_net numeric; v_tax numeric;
    v_line int;
    v_recv numeric;
begin
    if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'Add at least one line item.' using errcode = 'VF400';
    end if;
    select coalesce((tax_settings ->> 'defaultTaxPercent')::numeric, 0) into v_default_tax
    from vendorflow.tenant_settings where tenant_id = p_tenant_id;

    delete from vendorflow.po_items pi
    where pi.po_id = p_po_id and not exists (select 1 from jsonb_array_elements(p_items) e where e ->> 'id' = pi.id::text);

    for it in select * from jsonb_array_elements(p_items) loop
        if coalesce(btrim(it ->> 'description'), '') = '' then raise exception 'Every line needs a description.' using errcode = 'VF400'; end if;
        v_qty := (it ->> 'quantity')::numeric;
        v_rate := (it ->> 'rate')::numeric;
        v_dp := coalesce((it ->> 'discount_percent')::numeric, 0);
        v_tp := coalesce((it ->> 'tax_percent')::numeric, v_default_tax);
        if v_qty is null or v_qty <= 0 then raise exception 'Quantity must be greater than zero.' using errcode = 'VF400'; end if;
        if v_rate is null or v_rate < 0 then raise exception 'Rate cannot be negative.' using errcode = 'VF400'; end if;
        if v_dp < 0 or v_dp > 100 or v_tp < 0 or v_tp > 100 then raise exception 'Discount and tax must be between 0 and 100.' using errcode = 'VF400'; end if;

        v_gross := round(v_qty * round(v_rate, 2), 2);
        v_disc := round(v_gross * v_dp / 100, 2);
        v_net := v_gross - v_disc;
        v_tax := round(v_net * v_tp / 100, 2);

        v_id := nullif(it ->> 'id', '')::uuid;
        if v_id is not null then
            select received_qty into v_recv from vendorflow.po_items where id = v_id and po_id = p_po_id and tenant_id = p_tenant_id;
            if not found then raise exception 'Line item not found on this purchase order.' using errcode = 'VF404'; end if;
            if v_qty < v_recv then raise exception 'Quantity cannot be lower than the % already received.', v_recv using errcode = 'VF409'; end if;
            update vendorflow.po_items set description = btrim(it ->> 'description'), unit = coalesce(nullif(it ->> 'unit', ''), unit),
                quantity = v_qty, rate = round(v_rate, 2), discount_percent = v_dp, tax_percent = v_tp,
                net_amount = v_net, tax_amount = v_tax, line_total = v_net + v_tax
            where id = v_id;
        else
            select coalesce(max(line_no), 0) + 1 into v_line from vendorflow.po_items where po_id = p_po_id;
            insert into vendorflow.po_items (tenant_id, po_id, line_no, description, unit, quantity, rate, discount_percent, tax_percent, net_amount, tax_amount, line_total)
            values (p_tenant_id, p_po_id, v_line, btrim(it ->> 'description'), coalesce(nullif(it ->> 'unit', ''), 'Nos'), v_qty,
                    round(v_rate, 2), v_dp, v_tp, v_net, v_tax, v_net + v_tax);
        end if;
    end loop;

    update vendorflow.purchase_orders p set
        subtotal = (select coalesce(sum(net_amount), 0) from vendorflow.po_items where po_id = p.id),
        discount_total = (select coalesce(sum(round(quantity * rate, 2) - net_amount), 0) from vendorflow.po_items where po_id = p.id),
        tax_total = (select coalesce(sum(tax_amount), 0) from vendorflow.po_items where po_id = p.id),
        shipping = coalesce(p_shipping, p.shipping)
    where p.id = p_po_id;
    update vendorflow.purchase_orders set total = subtotal + tax_total + shipping where id = p_po_id;
end $$;

-- Receipt status derived from quantities: Issued (nothing), PartiallyReceived, FullyReceived.
create or replace function vendorflow.fn_po_receipt_status(p_po_id uuid)
returns text language sql stable as $$
    select case when coalesce(sum(received_qty), 0) = 0 then 'Issued'
                when bool_and(received_qty >= quantity) then 'FullyReceived'
                else 'PartiallyReceived' end
    from vendorflow.po_items where po_id = p_po_id;
$$;

create or replace function vendorflow.fn_po_get(p_tenant_id uuid, p_id uuid)
returns jsonb language plpgsql stable as $$
declare v_json jsonb;
begin
    select jsonb_build_object(
        'id', p.id, 'number', p.number, 'vendor_id', p.vendor_id, 'vendor_name', vd.name, 'vendor_gstin', vd.gstin,
        'requisition_id', p.requisition_id, 'requisition_number', rq.number, 'rfq_id', p.rfq_id, 'rfq_number', rf.number,
        'status', p.status, 'revision', p.revision, 'order_date', p.order_date, 'expected_delivery', p.expected_delivery,
        'currency', p.currency, 'subtotal', p.subtotal, 'discount_total', p.discount_total, 'tax_total', p.tax_total,
        'shipping', p.shipping, 'total', p.total, 'notes', p.notes, 'issued_at', p.issued_at, 'acknowledged_at', p.acknowledged_at,
        'row_version', p.row_version, 'created_by_name', u.full_name, 'created_at', p.created_at,
        'receipt_pct', (select case when sum(quantity) = 0 then 0 else round(100 * sum(least(received_qty, quantity)) / sum(quantity)) end
                        from vendorflow.po_items where po_id = p.id),
        'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'line_no', i.line_no, 'description', i.description, 'unit', i.unit,
                    'quantity', i.quantity, 'rate', i.rate, 'discount_percent', i.discount_percent, 'tax_percent', i.tax_percent,
                    'net_amount', i.net_amount, 'tax_amount', i.tax_amount, 'line_total', i.line_total,
                    'received_qty', i.received_qty, 'pending_qty', greatest(i.quantity - i.received_qty, 0), 'invoiced_qty', i.invoiced_qty)
                    order by i.line_no) from vendorflow.po_items i where i.po_id = p.id), '[]'::jsonb),
        'revisions', coalesce((select jsonb_agg(jsonb_build_object('revision', r.revision, 'reason', r.reason, 'created_at', r.created_at,
                    'created_by_name', ru.full_name) order by r.revision desc)
                    from vendorflow.po_revisions r left join vendorflow.users ru on ru.id = r.created_by where r.po_id = p.id), '[]'::jsonb),
        'approval', (select vendorflow.fn_approval_get(p_tenant_id, ar.id) from vendorflow.approval_requests ar
                     where ar.tenant_id = p_tenant_id and ar.entity_type = 'purchase_order' and ar.entity_id = p.id
                     order by ar.created_at desc limit 1),
        'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'number', g.number, 'received_on', g.received_on)
                    order by g.received_on, g.number) from vendorflow.goods_receipts g where g.po_id = p.id and g.status = 'Posted'), '[]'::jsonb),
        'attachments', vendorflow.fn_attachment_list(p_tenant_id, 'purchase_order', p.id),
        'history', vendorflow.fn_history_list(p_tenant_id, 'purchase_order', p.id))
    into v_json
    from vendorflow.purchase_orders p
    join vendorflow.vendors vd on vd.id = p.vendor_id
    join vendorflow.users u on u.id = p.created_by
    left join vendorflow.requisitions rq on rq.id = p.requisition_id
    left join vendorflow.rfqs rf on rf.id = p.rfq_id
    where p.id = p_id and p.tenant_id = p_tenant_id;

    if v_json is null then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    return v_json;
end $$;

create or replace function vendorflow.fn_po_list(
    p_tenant_id uuid, p_status text default null, p_vendor_id uuid default null, p_search text default null,
    p_sort_by text default null, p_sort_dir text default null, p_page int default 1, p_page_size int default 20)
returns jsonb language plpgsql stable as $$
declare
    v_page int := greatest(coalesce(p_page, 1), 1);
    v_size int := least(greatest(coalesce(p_page_size, 20), 1), 200);
    v_order text := vendorflow.fn_sort_clause(p_sort_by, p_sort_dir, array['number','order_date','expected_delivery','status','total','created_at'], 'created_at');
    v_where text := $w$ p.tenant_id = $1 and ($2 is null or $2 = '' or p.status = $2) and ($3 is null or p.vendor_id = $3)
        and ($4 is null or $4 = '' or p.number ilike '%' || $4 || '%' or exists (select 1 from vendorflow.vendors v where v.id = p.vendor_id and v.name ilike '%' || $4 || '%')) $w$;
    v_total bigint; v_items jsonb; v_counts jsonb; v_stats jsonb;
begin
    execute 'select count(*) from vendorflow.purchase_orders p where ' || v_where into v_total using p_tenant_id, p_status, p_vendor_id, p_search;
    execute format($q$
        select coalesce(jsonb_agg(x), '[]'::jsonb) from (
            select jsonb_build_object('id', p.id, 'number', p.number, 'vendor_id', p.vendor_id,
                'vendor_name', (select name from vendorflow.vendors where id = p.vendor_id),
                'order_date', p.order_date, 'expected_delivery', p.expected_delivery, 'status', p.status, 'revision', p.revision,
                'total', p.total, 'currency', p.currency,
                'receipt_pct', (select case when sum(quantity) = 0 then 0 else round(100 * sum(least(received_qty, quantity)) / sum(quantity)) end
                                from vendorflow.po_items where po_id = p.id)) as x
            from vendorflow.purchase_orders p where %s order by %s offset %s limit %s) s$q$, v_where, v_order, (v_page - 1) * v_size, v_size)
        into v_items using p_tenant_id, p_status, p_vendor_id, p_search;

    select coalesce(jsonb_object_agg(status, c), '{}'::jsonb) || jsonb_build_object('All', coalesce(sum(c), 0))
    into v_counts from (select status, count(*) c from vendorflow.purchase_orders where tenant_id = p_tenant_id group by status) g;

    select jsonb_build_object(
        'open', jsonb_build_object('amount', coalesce(sum(total) filter (where status in ('Approved','Issued','PartiallyReceived','OnHold')), 0),
                                   'count', count(*) filter (where status in ('Approved','Issued','PartiallyReceived','OnHold'))),
        'awaiting_receipt', jsonb_build_object('amount', coalesce(sum(total) filter (where status in ('Issued','PartiallyReceived')), 0),
                                   'count', count(*) filter (where status in ('Issued','PartiallyReceived'))),
        'ready_to_invoice', jsonb_build_object('amount', coalesce(sum(total) filter (where status = 'FullyReceived'), 0),
                                   'count', count(*) filter (where status = 'FullyReceived')),
        'draft', jsonb_build_object('amount', coalesce(sum(total) filter (where status = 'Draft'), 0),
                                   'count', count(*) filter (where status = 'Draft')))
    into v_stats from vendorflow.purchase_orders where tenant_id = p_tenant_id;

    return vendorflow.fn_page(v_items, v_total, v_page, v_size) || jsonb_build_object('status_counts', v_counts, 'stats', v_stats);
end $$;

-- Checks that a vendor can receive orders (approved, same tenant).
create or replace procedure vendorflow.sp_po_check_vendor(p_tenant_id uuid, p_vendor_id uuid)
language plpgsql as $$
begin
    if not exists (select 1 from vendorflow.vendors where id = p_vendor_id and tenant_id = p_tenant_id and status = 'Approved') then
        raise exception 'Purchase orders can only be raised to approved vendors of your organization.' using errcode = 'VF400';
    end if;
end $$;

-- Direct PO (no requisition / RFQ).
create or replace function vendorflow.fn_po_create(p_tenant_id uuid, p_actor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    v_vendor uuid := (p_data ->> 'vendor_id')::uuid;
    v_id uuid;
    v_cur text;
begin
    if v_vendor is null then raise exception 'Vendor is required.' using errcode = 'VF400'; end if;
    call vendorflow.sp_po_check_vendor(p_tenant_id, v_vendor);
    select currency into v_cur from vendorflow.tenant_settings where tenant_id = p_tenant_id;
    insert into vendorflow.purchase_orders (tenant_id, number, vendor_id, order_date, expected_delivery, currency, notes, created_by)
    values (p_tenant_id, vendorflow.fn_next_number(p_tenant_id, 'po'), v_vendor, coalesce(nullif(p_data ->> 'order_date', '')::date, current_date),
            nullif(p_data ->> 'expected_delivery', '')::date, v_cur, p_data ->> 'notes', p_actor_id)
    returning id into v_id;
    call vendorflow.sp_po_write_items(p_tenant_id, v_id, p_data -> 'items', coalesce((p_data ->> 'shipping')::numeric, 0));
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', v_id, 'created', null, 'Draft', null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'po.created', 'purchase_order', v_id, null);
    return vendorflow.fn_po_get(p_tenant_id, v_id);
end $$;

-- PO from an approved requisition; the requisition becomes ConvertedToPO.
create or replace function vendorflow.fn_po_create_from_requisition(p_tenant_id uuid, p_actor_id uuid, p_requisition_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    rq vendorflow.requisitions%rowtype;
    v_vendor uuid := (p_data ->> 'vendor_id')::uuid;
    v_id uuid;
    v_cur text;
    v_items jsonb;
begin
    select * into rq from vendorflow.requisitions where id = p_requisition_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Requisition not found.' using errcode = 'VF404'; end if;
    if rq.status <> 'Approved' then raise exception 'Only an approved requisition can be converted (it is %).', rq.status using errcode = 'VF409'; end if;
    if v_vendor is null then raise exception 'Vendor is required.' using errcode = 'VF400'; end if;
    call vendorflow.sp_po_check_vendor(p_tenant_id, v_vendor);

    select jsonb_agg(jsonb_build_object('description', i.description, 'unit', i.unit, 'quantity', i.quantity, 'rate', i.est_unit_price) order by i.line_no)
    into v_items from vendorflow.requisition_items i where i.requisition_id = rq.id;

    select currency into v_cur from vendorflow.tenant_settings where tenant_id = p_tenant_id;
    insert into vendorflow.purchase_orders (tenant_id, number, vendor_id, requisition_id, order_date, expected_delivery, currency, notes, created_by)
    values (p_tenant_id, vendorflow.fn_next_number(p_tenant_id, 'po'), v_vendor, rq.id, current_date,
            coalesce(nullif(p_data ->> 'expected_delivery', '')::date, rq.required_date), v_cur, p_data ->> 'notes', p_actor_id)
    returning id into v_id;
    call vendorflow.sp_po_write_items(p_tenant_id, v_id, v_items, coalesce((p_data ->> 'shipping')::numeric, 0));

    update vendorflow.requisitions set status = 'ConvertedToPO', updated_at = now(), row_version = row_version + 1 where id = rq.id;
    call vendorflow.sp_history(p_tenant_id, 'requisition', rq.id, 'converted_to_po', 'Approved', 'ConvertedToPO', null, p_actor_id);
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', v_id, 'created', null, 'Draft', 'From ' || rq.number, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'po.created', 'purchase_order', v_id, jsonb_build_object('requisition_id', rq.id));
    return vendorflow.fn_po_get(p_tenant_id, v_id);
end $$;

-- PO from the RFQ's RECOMMENDED quotation. Without a recorded recommendation no PO can be created.
create or replace function vendorflow.fn_po_create_from_rfq(p_tenant_id uuid, p_actor_id uuid, p_rfq_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    r vendorflow.rfqs%rowtype;
    rc vendorflow.quotation_recommendations%rowtype;
    qu vendorflow.quotations%rowtype;
    v_id uuid;
    v_cur text;
    v_items jsonb;
begin
    select * into r from vendorflow.rfqs where id = p_rfq_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status not in ('Open', 'Closed') then raise exception 'A PO cannot be created from an RFQ that is %.', r.status using errcode = 'VF409'; end if;
    select * into rc from vendorflow.quotation_recommendations where rfq_id = r.id;
    if not found then raise exception 'Record a recommendation with justification before creating the PO.' using errcode = 'VF409'; end if;
    select * into qu from vendorflow.quotations where rfq_id = r.id and vendor_id = rc.vendor_id;
    call vendorflow.sp_po_check_vendor(p_tenant_id, rc.vendor_id);

    select jsonb_agg(jsonb_build_object('description', ri.description, 'unit', ri.unit, 'quantity', ri.quantity,
        'rate', qi.unit_price, 'discount_percent', qi.discount_percent, 'tax_percent', qi.tax_percent) order by ri.line_no)
    into v_items from vendorflow.quotation_items qi join vendorflow.rfq_items ri on ri.id = qi.rfq_item_id where qi.quotation_id = qu.id;

    select currency into v_cur from vendorflow.tenant_settings where tenant_id = p_tenant_id;
    insert into vendorflow.purchase_orders (tenant_id, number, vendor_id, requisition_id, rfq_id, order_date, expected_delivery, currency, notes, created_by)
    values (p_tenant_id, vendorflow.fn_next_number(p_tenant_id, 'po'), rc.vendor_id, r.requisition_id, r.id, current_date,
            coalesce(nullif(p_data ->> 'expected_delivery', '')::date, current_date + coalesce(qu.delivery_days, 0)),
            v_cur, coalesce(p_data ->> 'notes', 'Payment terms: ' || coalesce(qu.payment_terms, '-') || '. Warranty: ' || coalesce(qu.warranty_months::text, '-') || ' months.'),
            p_actor_id)
    returning id into v_id;
    call vendorflow.sp_po_write_items(p_tenant_id, v_id, v_items, qu.shipping);

    update vendorflow.rfqs set status = 'Awarded', updated_at = now() where id = r.id;
    call vendorflow.sp_history(p_tenant_id, 'rfq', r.id, 'awarded', r.status, 'Awarded', null, p_actor_id);
    if r.requisition_id is not null then
        update vendorflow.requisitions set status = 'ConvertedToPO', updated_at = now(), row_version = row_version + 1
        where id = r.requisition_id and tenant_id = p_tenant_id and status = 'Approved';
    end if;
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', v_id, 'created', null, 'Draft', 'From ' || r.number, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'po.created', 'purchase_order', v_id, jsonb_build_object('rfq_id', r.id));
    return vendorflow.fn_po_get(p_tenant_id, v_id);
end $$;

-- Edits a draft PO (an issued PO is immutable; use a revision).
create or replace function vendorflow.fn_po_update(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare cur vendorflow.purchase_orders%rowtype;
begin
    select * into cur from vendorflow.purchase_orders where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if cur.status <> 'Draft' then raise exception 'A purchase order that is % cannot be edited. Create a revision instead.', cur.status using errcode = 'VF409'; end if;
    if p_data ? 'row_version' and (p_data ->> 'row_version')::int <> cur.row_version then
        raise exception 'This purchase order was changed by someone else. Reload and try again.' using errcode = 'VF409';
    end if;
    if p_data ? 'vendor_id' and (p_data ->> 'vendor_id')::uuid <> cur.vendor_id then
        if cur.revision > 0 then raise exception 'The vendor of a revised purchase order cannot be changed.' using errcode = 'VF409'; end if;
        call vendorflow.sp_po_check_vendor(p_tenant_id, (p_data ->> 'vendor_id')::uuid);
    end if;

    update vendorflow.purchase_orders set
        vendor_id = coalesce((p_data ->> 'vendor_id')::uuid, vendor_id),
        expected_delivery = case when p_data ? 'expected_delivery' then nullif(p_data ->> 'expected_delivery', '')::date else expected_delivery end,
        notes = case when p_data ? 'notes' then p_data ->> 'notes' else notes end,
        updated_at = now(), row_version = row_version + 1
    where id = p_id;
    if p_data ? 'items' then
        call vendorflow.sp_po_write_items(p_tenant_id, p_id, p_data -> 'items', coalesce((p_data ->> 'shipping')::numeric, cur.shipping));
    elsif p_data ? 'shipping' then
        update vendorflow.purchase_orders set shipping = (p_data ->> 'shipping')::numeric, total = subtotal + tax_total + (p_data ->> 'shipping')::numeric where id = p_id;
    end if;
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', p_id, 'updated', 'Draft', 'Draft', null, p_actor_id);
    return vendorflow.fn_po_get(p_tenant_id, p_id);
end $$;

create or replace function vendorflow.fn_po_submit(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
declare
    cur vendorflow.purchase_orders%rowtype;
    v_req uuid;
begin
    select * into cur from vendorflow.purchase_orders where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if cur.status <> 'Draft' then raise exception 'A purchase order that is % cannot be submitted.', cur.status using errcode = 'VF409'; end if;
    if cur.total <= 0 or not exists (select 1 from vendorflow.po_items where po_id = cur.id) then
        raise exception 'Add priced line items before submitting.' using errcode = 'VF400';
    end if;
    call vendorflow.sp_po_check_vendor(p_tenant_id, cur.vendor_id);

    update vendorflow.purchase_orders set status = 'PendingApproval', updated_at = now(), row_version = row_version + 1 where id = cur.id;
    v_req := vendorflow.fn_approval_start(p_tenant_id, 'purchase_order', cur.id, cur.number || ' · ' || (select name from vendorflow.vendors where id = cur.vendor_id),
                                          cur.total, p_actor_id, null);
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', cur.id, 'submitted', 'Draft', 'PendingApproval', null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'po.submitted', 'purchase_order', cur.id, jsonb_build_object('approval_request_id', v_req));
    return vendorflow.fn_po_get(p_tenant_id, cur.id);
end $$;

-- Issues an approved PO to the vendor: from now on it is immutable.
create or replace function vendorflow.fn_po_issue(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
declare
    cur vendorflow.purchase_orders%rowtype;
    v_to text;
begin
    select * into cur from vendorflow.purchase_orders where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if cur.status <> 'Approved' then raise exception 'Only an approved purchase order can be issued (it is %).', cur.status using errcode = 'VF409'; end if;
    call vendorflow.sp_po_check_vendor(p_tenant_id, cur.vendor_id);

    v_to := vendorflow.fn_po_receipt_status(cur.id);
    update vendorflow.purchase_orders set status = v_to, issued_at = now(), acknowledged_at = null, updated_at = now(), row_version = row_version + 1 where id = cur.id;
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', cur.id, 'issued', 'Approved', v_to, 'Revision ' || cur.revision, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'po.issued', 'purchase_order', cur.id, jsonb_build_object('revision', cur.revision));
    call vendorflow.sp_notify_user(p_tenant_id, cur.created_by, 'po_issued', 'PO issued', cur.number, 'purchase_order', cur.id,
        'po-issued:' || cur.id || ':' || cur.revision);
    return vendorflow.fn_po_get(p_tenant_id, cur.id);
end $$;

create or replace function vendorflow.fn_po_acknowledge(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
begin
    update vendorflow.purchase_orders set acknowledged_at = now(), row_version = row_version + 1
    where id = p_id and tenant_id = p_tenant_id and status in ('Issued', 'PartiallyReceived') and acknowledged_at is null;
    if not found then raise exception 'Only an issued, unacknowledged purchase order can be acknowledged.' using errcode = 'VF409'; end if;
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', p_id, 'acknowledged', null, null, null, p_actor_id);
    return vendorflow.fn_po_get(p_tenant_id, p_id);
end $$;

-- Creates a controlled revision: snapshot of the current version is stored, the PO returns to Draft with revision + 1
-- and must go through approval and issue again. Received quantities are kept.
create or replace function vendorflow.fn_po_create_revision(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_reason text)
returns jsonb language plpgsql as $$
declare cur vendorflow.purchase_orders%rowtype;
begin
    select * into cur from vendorflow.purchase_orders where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if cur.status not in ('Approved', 'Issued', 'PartiallyReceived', 'OnHold') then
        raise exception 'A purchase order that is % cannot be revised.', cur.status using errcode = 'VF409';
    end if;
    if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason for the revision is required.' using errcode = 'VF400'; end if;

    insert into vendorflow.po_revisions (tenant_id, po_id, revision, snapshot, reason, created_by)
    values (p_tenant_id, cur.id, cur.revision, vendorflow.fn_po_get(p_tenant_id, cur.id) - 'history' - 'revisions' - 'approval', btrim(p_reason), p_actor_id);

    update vendorflow.purchase_orders set status = 'Draft', revision = revision + 1, issued_at = null, acknowledged_at = null,
        updated_at = now(), row_version = row_version + 1 where id = cur.id;
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', cur.id, 'revision_created', cur.status, 'Draft', p_reason, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'po.revision_created', 'purchase_order', cur.id, jsonb_build_object('revision', cur.revision + 1));
    return vendorflow.fn_po_get(p_tenant_id, cur.id);
end $$;

create or replace function vendorflow.fn_po_hold(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_comment text)
returns jsonb language plpgsql as $$
declare cur vendorflow.purchase_orders%rowtype;
begin
    select * into cur from vendorflow.purchase_orders where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if cur.status not in ('Issued', 'PartiallyReceived') then raise exception 'A purchase order that is % cannot be put on hold.', cur.status using errcode = 'VF409'; end if;
    if coalesce(btrim(p_comment), '') = '' then raise exception 'A reason is required.' using errcode = 'VF400'; end if;
    update vendorflow.purchase_orders set status = 'OnHold', updated_at = now(), row_version = row_version + 1 where id = cur.id;
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', cur.id, 'hold', cur.status, 'OnHold', p_comment, p_actor_id);
    return vendorflow.fn_po_get(p_tenant_id, cur.id);
end $$;

create or replace function vendorflow.fn_po_resume(p_tenant_id uuid, p_actor_id uuid, p_id uuid)
returns jsonb language plpgsql as $$
declare
    cur vendorflow.purchase_orders%rowtype;
    v_to text;
begin
    select * into cur from vendorflow.purchase_orders where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if cur.status <> 'OnHold' then raise exception 'Only a purchase order on hold can be resumed.' using errcode = 'VF409'; end if;
    v_to := vendorflow.fn_po_receipt_status(cur.id);
    update vendorflow.purchase_orders set status = v_to, updated_at = now(), row_version = row_version + 1 where id = cur.id;
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', cur.id, 'resume', 'OnHold', v_to, null, p_actor_id);
    return vendorflow.fn_po_get(p_tenant_id, cur.id);
end $$;

-- Closes a fully received PO. A partly received PO can be short-closed with a reason.
create or replace function vendorflow.fn_po_close(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_comment text)
returns jsonb language plpgsql as $$
declare cur vendorflow.purchase_orders%rowtype;
begin
    select * into cur from vendorflow.purchase_orders where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if cur.status not in ('FullyReceived', 'PartiallyReceived') then raise exception 'A purchase order that is % cannot be closed.', cur.status using errcode = 'VF409'; end if;
    if cur.status = 'PartiallyReceived' and coalesce(btrim(p_comment), '') = '' then
        raise exception 'A reason is required to close a partially received purchase order.' using errcode = 'VF400';
    end if;
    update vendorflow.purchase_orders set status = 'Closed', updated_at = now(), row_version = row_version + 1 where id = cur.id;
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', cur.id, 'closed', cur.status, 'Closed', p_comment, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'po.closed', 'purchase_order', cur.id, null);
    return vendorflow.fn_po_get(p_tenant_id, cur.id);
end $$;

-- Cancels a PO that has not received anything. The linked requisition / RFQ become available again.
create or replace function vendorflow.fn_po_cancel(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_comment text)
returns jsonb language plpgsql as $$
declare cur vendorflow.purchase_orders%rowtype;
begin
    select * into cur from vendorflow.purchase_orders where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if cur.status not in ('Draft', 'PendingApproval', 'Approved', 'Issued', 'OnHold') then
        raise exception 'A purchase order that is % cannot be cancelled.', cur.status using errcode = 'VF409';
    end if;
    if exists (select 1 from vendorflow.po_items where po_id = cur.id and received_qty > 0) then
        raise exception 'Goods were already received against this purchase order. Close it instead.' using errcode = 'VF409';
    end if;
    if coalesce(btrim(p_comment), '') = '' then raise exception 'A reason is required.' using errcode = 'VF400'; end if;

    update vendorflow.purchase_orders set status = 'Cancelled', updated_at = now(), row_version = row_version + 1 where id = cur.id;
    update vendorflow.approval_requests set status = 'Cancelled', completed_at = now(), row_version = row_version + 1
    where tenant_id = p_tenant_id and entity_type = 'purchase_order' and entity_id = cur.id and status = 'Pending';

    if cur.requisition_id is not null and not exists (
        select 1 from vendorflow.purchase_orders where requisition_id = cur.requisition_id and id <> cur.id and status not in ('Cancelled', 'Rejected')) then
        update vendorflow.requisitions set status = 'Approved', updated_at = now(), row_version = row_version + 1
        where id = cur.requisition_id and status = 'ConvertedToPO';
    end if;
    if cur.rfq_id is not null and not exists (
        select 1 from vendorflow.purchase_orders where rfq_id = cur.rfq_id and id <> cur.id and status not in ('Cancelled', 'Rejected')) then
        update vendorflow.rfqs set status = 'Closed', updated_at = now() where id = cur.rfq_id and status = 'Awarded';
    end if;

    call vendorflow.sp_history(p_tenant_id, 'purchase_order', cur.id, 'cancelled', cur.status, 'Cancelled', p_comment, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'po.cancelled', 'purchase_order', cur.id, null);
    return vendorflow.fn_po_get(p_tenant_id, cur.id);
end $$;

-- Data for the PDF (the header uses the tenant's configured display name).
create or replace function vendorflow.fn_po_pdf_data(p_tenant_id uuid, p_id uuid)
returns jsonb language plpgsql stable as $$
declare
    v_po jsonb;
    v_org jsonb;
    v_vendor jsonb;
begin
    v_po := vendorflow.fn_po_get(p_tenant_id, p_id);
    select jsonb_build_object('app_display_name', app_display_name, 'organization_name', organization_name, 'currency', currency)
    into v_org from vendorflow.tenant_settings where tenant_id = p_tenant_id;
    select jsonb_build_object('name', v.name, 'gstin', v.gstin, 'email', v.email, 'phone', v.phone, 'city', v.city, 'state', v.state,
        'address', (select a.line1 || coalesce(', ' || a.line2, '') || coalesce(', ' || a.city, '') || coalesce(' ' || a.postal_code, '')
                    from vendorflow.vendor_addresses a where a.vendor_id = v.id order by a.address_type limit 1))
    into v_vendor from vendorflow.vendors v where v.id = (v_po ->> 'vendor_id')::uuid;
    return jsonb_build_object('po', v_po - 'history' - 'approval' - 'attachments', 'organization', v_org, 'vendor', v_vendor);
end $$;
