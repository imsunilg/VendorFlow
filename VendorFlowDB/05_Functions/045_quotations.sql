-- Quotations: validation + calculation, staff entry, side-by-side comparison, recommendation.
--
-- Rounding rule (documented): for every line
--   gross    = round(quantity * unit_price, 2)
--   discount = round(gross * discount% / 100, 2)
--   net      = gross - discount
--   tax      = round(net * tax% / 100, 2)
--   total    = net + tax
-- quotation subtotal = sum(net), tax_total = sum(tax), total_landed = subtotal + tax_total + shipping.
-- round() on numeric rounds half away from zero (= half-up for positive money).

-- Validates and stores one vendor's quotation for an open RFQ (re-submission replaces the old one until the deadline).
create or replace function vendorflow.fn_quotation_upsert(p_tenant_id uuid, p_rfq_id uuid, p_vendor_id uuid, p_data jsonb, p_actor_id uuid)
returns uuid language plpgsql as $$
declare
    r vendorflow.rfqs%rowtype;
    ri record;
    v_item jsonb;
    v_q uuid;
    v_ship numeric := coalesce((p_data ->> 'shipping')::numeric, 0);
    v_price numeric; v_dp numeric; v_tp numeric;
    v_gross numeric; v_disc numeric; v_net numeric; v_tax numeric;
    v_sub numeric := 0; v_dtot numeric := 0; v_ttot numeric := 0;
    v_count int; v_total_rfqs int; v_received int; v_vname text;
begin
    select * into r from vendorflow.rfqs where id = p_rfq_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status <> 'Open' then raise exception 'This RFQ is not open for quotations.' using errcode = 'VF409'; end if;
    if r.deadline is not null and r.deadline < now() then raise exception 'The deadline for this RFQ has passed.' using errcode = 'VF409'; end if;
    if not exists (select 1 from vendorflow.rfq_vendors where rfq_id = p_rfq_id and vendor_id = p_vendor_id and tenant_id = p_tenant_id) then
        raise exception 'This vendor was not invited.' using errcode = 'VF403';
    end if;
    if v_ship < 0 then raise exception 'Shipping cannot be negative.' using errcode = 'VF400'; end if;
    if coalesce((p_data ->> 'delivery_days')::int, 0) < 0 or coalesce((p_data ->> 'warranty_months')::int, 0) < 0 then
        raise exception 'Delivery days and warranty cannot be negative.' using errcode = 'VF400';
    end if;
    if jsonb_typeof(p_data -> 'items') is distinct from 'array' then raise exception 'Prices for all items are required.' using errcode = 'VF400'; end if;

    insert into vendorflow.quotations (tenant_id, rfq_id, vendor_id, shipping, delivery_days, payment_terms, warranty_months, notes)
    values (p_tenant_id, p_rfq_id, p_vendor_id, v_ship, nullif(p_data ->> 'delivery_days', '')::int, p_data ->> 'payment_terms',
            nullif(p_data ->> 'warranty_months', '')::int, p_data ->> 'notes')
    on conflict (rfq_id, vendor_id) do update set shipping = excluded.shipping, delivery_days = excluded.delivery_days,
        payment_terms = excluded.payment_terms, warranty_months = excluded.warranty_months, notes = excluded.notes, submitted_at = now()
    returning id into v_q;
    delete from vendorflow.quotation_items where quotation_id = v_q;

    for ri in select * from vendorflow.rfq_items where rfq_id = p_rfq_id order by line_no loop
        select val into v_item from jsonb_array_elements(p_data -> 'items') as t(val) where val ->> 'rfq_item_id' = ri.id::text limit 1;
        if v_item is null then raise exception 'A price is required for item %.', ri.line_no using errcode = 'VF400'; end if;
        v_price := (v_item ->> 'unit_price')::numeric;
        v_dp := coalesce((v_item ->> 'discount_percent')::numeric, 0);
        v_tp := coalesce((v_item ->> 'tax_percent')::numeric, 0);
        if v_price is null or v_price < 0 then raise exception 'Unit price for item % is invalid.', ri.line_no using errcode = 'VF400'; end if;
        if v_dp < 0 or v_dp > 100 or v_tp < 0 or v_tp > 100 then raise exception 'Discount and tax must be between 0 and 100.' using errcode = 'VF400'; end if;

        v_gross := round(ri.quantity * round(v_price, 2), 2);
        v_disc := round(v_gross * v_dp / 100, 2);
        v_net := v_gross - v_disc;
        v_tax := round(v_net * v_tp / 100, 2);
        insert into vendorflow.quotation_items (tenant_id, quotation_id, rfq_item_id, unit_price, discount_percent, tax_percent, net_amount, tax_amount, line_total)
        values (p_tenant_id, v_q, ri.id, round(v_price, 2), v_dp, v_tp, v_net, v_tax, v_net + v_tax);
        v_sub := v_sub + v_net; v_dtot := v_dtot + v_disc; v_ttot := v_ttot + v_tax;
    end loop;

    update vendorflow.quotations set subtotal = v_sub, discount_total = v_dtot, tax_total = v_ttot, total_landed = v_sub + v_ttot + v_ship
    where id = v_q;
    update vendorflow.rfq_vendors set status = 'Submitted' where rfq_id = p_rfq_id and vendor_id = p_vendor_id;

    select count(*) into v_total_rfqs from vendorflow.rfq_vendors where rfq_id = p_rfq_id;
    select count(*) into v_received from vendorflow.quotations where rfq_id = p_rfq_id;
    call vendorflow.sp_notify_user(p_tenant_id, r.created_by, 'quotation_received', 'Quotation received',
        r.number || ' · ' || v_received || ' of ' || v_total_rfqs || ' responded', 'rfq', r.id,
        'quote:' || v_q || ':' || extract(epoch from clock_timestamp())::bigint);
    select name into v_vname from vendorflow.vendors where id = p_vendor_id;
    call vendorflow.sp_history(p_tenant_id, 'rfq', p_rfq_id, 'quotation_submitted', r.status, r.status, v_vname, p_actor_id);
    return v_q;
end $$;

-- Staff enter a quotation on behalf of a vendor (for example received by phone or paper).
create or replace function vendorflow.fn_rfq_enter_quotation(p_tenant_id uuid, p_actor_id uuid, p_rfq_id uuid, p_vendor_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
begin
    perform vendorflow.fn_quotation_upsert(p_tenant_id, p_rfq_id, p_vendor_id, p_data, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'quotation.entered_by_staff', 'rfq', p_rfq_id, jsonb_build_object('vendor_id', p_vendor_id));
    return vendorflow.fn_rfq_get(p_tenant_id, p_rfq_id);
end $$;

-- Side-by-side comparison. Highlights are computed here; the system never auto-selects a winner.
create or replace function vendorflow.fn_quotation_compare(p_tenant_id uuid, p_rfq_id uuid)
returns jsonb language plpgsql stable as $$
declare
    r vendorflow.rfqs%rowtype;
    v_quotes jsonb;
    v_lowest uuid;
begin
    select * into r from vendorflow.rfqs where id = p_rfq_id and tenant_id = p_tenant_id;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;

    with q as (
        select qu.*, vd.name as vendor_name,
               nullif(vendorflow.fn_vendor_performance(p_tenant_id, qu.vendor_id) ->> 'score', '')::numeric as score,
               (select count(*) from vendorflow.vendor_documents d where d.vendor_id = qu.vendor_id and d.expiry_date < current_date) as docs_expired,
               (select count(*) from vendorflow.vendor_documents d where d.vendor_id = qu.vendor_id and d.expiry_date between current_date and current_date + 30) as docs_expiring,
               (select count(*) from vendorflow.vendor_documents d where d.vendor_id = qu.vendor_id) as docs_total
        from vendorflow.quotations qu join vendorflow.vendors vd on vd.id = qu.vendor_id
        where qu.rfq_id = p_rfq_id and qu.tenant_id = p_tenant_id
    ), f as (
        select q.*,
            q.total_landed = min(q.total_landed) over () as is_lowest,
            (q.delivery_days is not null and q.delivery_days = min(q.delivery_days) over ()) as is_fastest,
            (q.score is not null and q.score = max(q.score) over ()) as is_best_score,
            (q.warranty_months is not null and q.warranty_months = max(q.warranty_months) over ()) as is_best_warranty,
            (q.shipping = min(q.shipping) over ()) as is_lowest_shipping
        from q
    )
    select coalesce(jsonb_agg(jsonb_build_object(
            'vendor_id', f.vendor_id, 'vendor_name', f.vendor_name, 'shipping', f.shipping, 'delivery_days', f.delivery_days,
            'payment_terms', f.payment_terms, 'warranty_months', f.warranty_months, 'notes', f.notes,
            'subtotal', f.subtotal, 'discount_total', f.discount_total, 'tax_total', f.tax_total, 'total_landed', f.total_landed,
            'vendor_score', f.score,
            'compliance', case when f.docs_expired > 0 then f.docs_expired || ' expired'
                               when f.docs_expiring > 0 then f.docs_expiring || ' expiring'
                               when f.docs_total = 0 then 'No documents' else 'All valid' end,
            'is_lowest_price', f.is_lowest, 'is_fastest', f.is_fastest, 'is_best_score', f.is_best_score,
            'is_best_warranty', f.is_best_warranty, 'is_lowest_shipping', f.is_lowest_shipping,
            'items', (select jsonb_agg(jsonb_build_object('rfq_item_id', qi.rfq_item_id, 'unit_price', qi.unit_price,
                        'discount_percent', qi.discount_percent, 'tax_percent', qi.tax_percent, 'net_amount', qi.net_amount,
                        'tax_amount', qi.tax_amount, 'line_total', qi.line_total) order by ri.line_no)
                      from vendorflow.quotation_items qi join vendorflow.rfq_items ri on ri.id = qi.rfq_item_id where qi.quotation_id = f.id)
        ) order by f.total_landed), '[]'::jsonb),
        (select vendor_id from f where is_lowest order by vendor_name limit 1)
    into v_quotes, v_lowest from f;

    return jsonb_build_object(
        'rfq', jsonb_build_object('id', r.id, 'number', r.number, 'title', r.title, 'status', r.status),
        'items', (select jsonb_agg(jsonb_build_object('id', i.id, 'line_no', i.line_no, 'description', i.description,
                    'unit', i.unit, 'quantity', i.quantity) order by i.line_no) from vendorflow.rfq_items i where i.rfq_id = r.id),
        'quotes', v_quotes,
        'lowest_vendor_id', v_lowest,
        'recommendation', (select jsonb_build_object('vendor_id', rc.vendor_id, 'vendor_name', vd.name, 'justification', rc.justification,
                    'is_lowest_price', rc.vendor_id = rc.lowest_vendor_id, 'created_at', rc.created_at)
                    from vendorflow.quotation_recommendations rc join vendorflow.vendors vd on vd.id = rc.vendor_id where rc.rfq_id = r.id),
        'note', 'The system never auto-selects the cheapest quote; a recommendation with justification is required.');
end $$;

-- Records the buyer's recommendation. A written justification is always required (also when the lowest price is chosen).
create or replace function vendorflow.fn_quotation_recommend(p_tenant_id uuid, p_actor_id uuid, p_rfq_id uuid, p_vendor_id uuid, p_justification text)
returns jsonb language plpgsql as $$
declare
    r vendorflow.rfqs%rowtype;
    v_lowest uuid;
begin
    select * into r from vendorflow.rfqs where id = p_rfq_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'RFQ not found.' using errcode = 'VF404'; end if;
    if r.status not in ('Open', 'Closed') then raise exception 'An RFQ that is % cannot take a recommendation.', r.status using errcode = 'VF409'; end if;
    if not exists (select 1 from vendorflow.quotations where rfq_id = p_rfq_id and vendor_id = p_vendor_id and tenant_id = p_tenant_id) then
        raise exception 'That vendor has not submitted a quotation.' using errcode = 'VF400';
    end if;
    if char_length(coalesce(btrim(p_justification), '')) < 10 then
        raise exception 'A justification of at least 10 characters is required.' using errcode = 'VF400';
    end if;

    select vendor_id into v_lowest from vendorflow.quotations where rfq_id = p_rfq_id order by total_landed, submitted_at limit 1;
    insert into vendorflow.quotation_recommendations (tenant_id, rfq_id, vendor_id, justification, lowest_vendor_id, recommended_by)
    values (p_tenant_id, p_rfq_id, p_vendor_id, btrim(p_justification), v_lowest, p_actor_id)
    on conflict (rfq_id) do update set vendor_id = excluded.vendor_id, justification = excluded.justification,
        lowest_vendor_id = excluded.lowest_vendor_id, recommended_by = excluded.recommended_by, created_at = now();

    call vendorflow.sp_history(p_tenant_id, 'rfq', p_rfq_id, 'recommendation_recorded', r.status, r.status, btrim(p_justification), p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'quotation.recommended', 'rfq', p_rfq_id,
        jsonb_build_object('vendor_id', p_vendor_id, 'lowest_vendor_id', v_lowest, 'is_lowest', p_vendor_id = v_lowest));
    return vendorflow.fn_quotation_compare(p_tenant_id, p_rfq_id);
end $$;
