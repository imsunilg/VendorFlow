-- Goods receipts (GRN). Posting is one transaction that locks the PO row, so two clerks cannot over-receive in parallel.
--
-- Quantities: received = accepted + rejected; damaged is a subset of rejected.
-- po_items.received_qty counts ACCEPTED quantity only, so rejected goods can be re-delivered.
-- Over-receipt rule: received (this GRN) must not exceed the pending quantity (ordered - accepted so far).

create or replace function vendorflow.fn_grn_get(p_tenant_id uuid, p_id uuid)
returns jsonb language plpgsql stable as $$
declare v_json jsonb;
begin
    select jsonb_build_object(
        'id', g.id, 'number', g.number, 'po_id', g.po_id, 'po_number', p.number, 'vendor_id', p.vendor_id, 'vendor_name', vd.name,
        'received_on', g.received_on, 'warehouse', g.warehouse, 'delivery_challan', g.delivery_challan, 'vehicle_no', g.vehicle_no,
        'received_by', g.received_by, 'inspection_notes', g.inspection_notes, 'status', g.status, 'created_at', g.created_at,
        'created_by_name', u.full_name,
        'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'po_item_id', i.po_item_id, 'line_no', pi.line_no,
                    'description', pi.description, 'ordered_qty', pi.quantity, 'received_qty', i.received_qty,
                    'accepted_qty', i.accepted_qty, 'rejected_qty', i.rejected_qty, 'damaged_qty', i.damaged_qty) order by pi.line_no)
                  from vendorflow.grn_items i join vendorflow.po_items pi on pi.id = i.po_item_id where i.grn_id = g.id), '[]'::jsonb),
        'attachments', vendorflow.fn_attachment_list(p_tenant_id, 'goods_receipt', g.id),
        'history', vendorflow.fn_history_list(p_tenant_id, 'goods_receipt', g.id))
    into v_json
    from vendorflow.goods_receipts g
    join vendorflow.purchase_orders p on p.id = g.po_id
    join vendorflow.vendors vd on vd.id = p.vendor_id
    join vendorflow.users u on u.id = g.created_by
    where g.id = p_id and g.tenant_id = p_tenant_id;
    if v_json is null then raise exception 'Goods receipt not found.' using errcode = 'VF404'; end if;
    return v_json;
end $$;

create or replace function vendorflow.fn_grn_list(
    p_tenant_id uuid, p_po_id uuid default null, p_search text default null, p_page int default 1, p_page_size int default 20)
returns jsonb language plpgsql stable as $$
declare
    v_page int := greatest(coalesce(p_page, 1), 1);
    v_size int := least(greatest(coalesce(p_page_size, 20), 1), 200);
    v_total bigint; v_items jsonb;
begin
    select count(*) into v_total from vendorflow.goods_receipts g join vendorflow.purchase_orders p on p.id = g.po_id
    where g.tenant_id = p_tenant_id and (p_po_id is null or g.po_id = p_po_id)
      and (coalesce(p_search, '') = '' or g.number ilike '%' || p_search || '%' or p.number ilike '%' || p_search || '%');
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_items from (
        select jsonb_build_object('id', g.id, 'number', g.number, 'po_id', g.po_id, 'po_number', p.number, 'vendor_name', vd.name,
            'received_on', g.received_on, 'warehouse', g.warehouse, 'delivery_challan', g.delivery_challan, 'status', g.status,
            'accepted_qty', (select coalesce(sum(accepted_qty), 0) from vendorflow.grn_items where grn_id = g.id),
            'rejected_qty', (select coalesce(sum(rejected_qty), 0) from vendorflow.grn_items where grn_id = g.id)) as x
        from vendorflow.goods_receipts g join vendorflow.purchase_orders p on p.id = g.po_id join vendorflow.vendors vd on vd.id = p.vendor_id
        where g.tenant_id = p_tenant_id and (p_po_id is null or g.po_id = p_po_id)
          and (coalesce(p_search, '') = '' or g.number ilike '%' || p_search || '%' or p.number ilike '%' || p_search || '%')
        order by g.received_on desc, g.number desc offset (v_page - 1) * v_size limit v_size) s;
    return vendorflow.fn_page(v_items, v_total, v_page, v_size);
end $$;

-- Posts a goods receipt against an issued / partially received PO.
create or replace function vendorflow.fn_grn_post(p_tenant_id uuid, p_actor_id uuid, p_po_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
    po vendorflow.purchase_orders%rowtype;
    it jsonb;
    pi vendorflow.po_items%rowtype;
    v_grn uuid;
    v_recv numeric; v_acc numeric; v_rej numeric; v_dam numeric;
    v_any boolean := false;
    v_challan text := nullif(btrim(p_data ->> 'delivery_challan'), '');
    v_seen uuid[] := '{}';
    v_new_status text;
begin
    -- lock the PO: receipts for one PO are processed one after another
    select * into po from vendorflow.purchase_orders where id = p_po_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Purchase order not found.' using errcode = 'VF404'; end if;
    if po.status not in ('Issued', 'PartiallyReceived') then
        raise exception 'Goods can only be received against an issued purchase order (it is %).', po.status using errcode = 'VF409';
    end if;
    if jsonb_typeof(p_data -> 'items') is distinct from 'array' or jsonb_array_length(p_data -> 'items') = 0 then
        raise exception 'Enter the received quantities.' using errcode = 'VF400';
    end if;
    if v_challan is not null and exists (
        select 1 from vendorflow.goods_receipts where tenant_id = p_tenant_id and po_id = po.id and lower(delivery_challan) = lower(v_challan) and status = 'Posted') then
        raise exception 'A receipt with delivery challan % already exists for this purchase order.', v_challan using errcode = 'VF409';
    end if;
    if nullif(p_data ->> 'received_on', '')::date > current_date then
        raise exception 'Received date cannot be in the future.' using errcode = 'VF400';
    end if;

    insert into vendorflow.goods_receipts (tenant_id, number, po_id, received_on, warehouse, delivery_challan, vehicle_no, received_by, inspection_notes, created_by)
    values (p_tenant_id, vendorflow.fn_next_number(p_tenant_id, 'grn'), po.id, coalesce(nullif(p_data ->> 'received_on', '')::date, current_date),
            p_data ->> 'warehouse', v_challan, p_data ->> 'vehicle_no', p_data ->> 'received_by', p_data ->> 'inspection_notes', p_actor_id)
    returning id into v_grn;

    for it in select * from jsonb_array_elements(p_data -> 'items') loop
        select * into pi from vendorflow.po_items where id = (it ->> 'po_item_id')::uuid and po_id = po.id and tenant_id = p_tenant_id for update;
        if not found then raise exception 'A line does not belong to this purchase order.' using errcode = 'VF400'; end if;
        if pi.id = any(v_seen) then raise exception 'Line % appears twice.', pi.line_no using errcode = 'VF400'; end if;
        v_seen := v_seen || pi.id;

        v_recv := coalesce((it ->> 'received_qty')::numeric, 0);
        v_acc := coalesce((it ->> 'accepted_qty')::numeric, 0);
        v_rej := coalesce((it ->> 'rejected_qty')::numeric, 0);
        v_dam := coalesce((it ->> 'damaged_qty')::numeric, 0);
        if v_recv < 0 or v_acc < 0 or v_rej < 0 or v_dam < 0 then raise exception 'Quantities cannot be negative.' using errcode = 'VF400'; end if;
        if v_recv = 0 and v_acc = 0 and v_rej = 0 then continue; end if;
        if v_acc + v_rej <> v_recv then
            raise exception 'Line %: accepted + rejected must equal received.', pi.line_no using errcode = 'VF400';
        end if;
        if v_dam > v_rej then raise exception 'Line %: damaged cannot exceed rejected.', pi.line_no using errcode = 'VF400'; end if;
        if v_recv > greatest(pi.quantity - pi.received_qty, 0) then
            raise exception 'Line %: receiving % exceeds the pending quantity %.', pi.line_no, v_recv, greatest(pi.quantity - pi.received_qty, 0) using errcode = 'VF409';
        end if;

        insert into vendorflow.grn_items (tenant_id, grn_id, po_item_id, received_qty, accepted_qty, rejected_qty, damaged_qty)
        values (p_tenant_id, v_grn, pi.id, v_recv, v_acc, v_rej, v_dam);
        update vendorflow.po_items set received_qty = received_qty + v_acc where id = pi.id;
        v_any := true;
    end loop;
    if not v_any then raise exception 'Receive a quantity on at least one line.' using errcode = 'VF400'; end if;

    v_new_status := vendorflow.fn_po_receipt_status(po.id);
    update vendorflow.purchase_orders set status = v_new_status, updated_at = now(), row_version = row_version + 1 where id = po.id;

    call vendorflow.sp_history(p_tenant_id, 'goods_receipt', v_grn, 'posted', null, 'Posted', null, p_actor_id);
    call vendorflow.sp_history(p_tenant_id, 'purchase_order', po.id, 'goods_received', po.status, v_new_status, null, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'grn.posted', 'goods_receipt', v_grn, jsonb_build_object('po_id', po.id));
    call vendorflow.sp_notify_user(p_tenant_id, po.created_by, 'goods_received', 'Goods received', po.number, 'purchase_order', po.id, 'grn:' || v_grn);
    return vendorflow.fn_grn_get(p_tenant_id, v_grn);
end $$;

-- Cancels a posted receipt (reverses accepted quantities). Not possible when the goods are already invoiced.
create or replace function vendorflow.fn_grn_cancel(p_tenant_id uuid, p_actor_id uuid, p_id uuid, p_comment text)
returns jsonb language plpgsql as $$
declare
    g vendorflow.goods_receipts%rowtype;
    po vendorflow.purchase_orders%rowtype;
    i record;
    v_new text;
begin
    select * into g from vendorflow.goods_receipts where id = p_id and tenant_id = p_tenant_id for update;
    if not found then raise exception 'Goods receipt not found.' using errcode = 'VF404'; end if;
    if g.status <> 'Posted' then raise exception 'This goods receipt is already cancelled.' using errcode = 'VF409'; end if;
    if coalesce(btrim(p_comment), '') = '' then raise exception 'A reason is required.' using errcode = 'VF400'; end if;
    select * into po from vendorflow.purchase_orders where id = g.po_id for update;
    if po.status not in ('Issued', 'PartiallyReceived', 'FullyReceived', 'OnHold') then
        raise exception 'The purchase order is % and its receipts can no longer be cancelled.', po.status using errcode = 'VF409';
    end if;

    for i in select gi.po_item_id, gi.accepted_qty, pi.received_qty, pi.invoiced_qty from vendorflow.grn_items gi
             join vendorflow.po_items pi on pi.id = gi.po_item_id where gi.grn_id = g.id loop
        if i.received_qty - i.accepted_qty < i.invoiced_qty then
            raise exception 'Some of these goods are already invoiced; cancel the invoice first.' using errcode = 'VF409';
        end if;
        update vendorflow.po_items set received_qty = received_qty - i.accepted_qty where id = i.po_item_id;
    end loop;

    update vendorflow.goods_receipts set status = 'Cancelled' where id = g.id;
    if po.status <> 'OnHold' then
        v_new := vendorflow.fn_po_receipt_status(po.id);
        update vendorflow.purchase_orders set status = v_new, updated_at = now(), row_version = row_version + 1 where id = po.id;
    end if;
    call vendorflow.sp_history(p_tenant_id, 'goods_receipt', g.id, 'cancelled', 'Posted', 'Cancelled', p_comment, p_actor_id);
    call vendorflow.sp_audit(p_tenant_id, p_actor_id, 'grn.cancelled', 'goods_receipt', g.id, null);
    return vendorflow.fn_grn_get(p_tenant_id, g.id);
end $$;
