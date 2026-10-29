-- Defence in depth: an issued purchase order cannot be changed commercially, even by a bug in application code.
-- Only received_qty / invoiced_qty (goods receipts, invoices) and status/bookkeeping columns may change.

create or replace function vendorflow.trg_po_items_guard()
returns trigger language plpgsql as $$
declare
    v_po uuid;
    v_status text;
begin
    v_po := case when tg_op = 'DELETE' then old.po_id else new.po_id end;
    select status into v_status from vendorflow.purchase_orders where id = v_po;
    if v_status is null or v_status = 'Draft' then
        return case when tg_op = 'DELETE' then old else new end;
    end if;
    if tg_op = 'INSERT' or tg_op = 'DELETE' then
        raise exception 'Items of a % purchase order cannot be added or removed. Create a revision.', v_status using errcode = 'VF409';
    end if;
    if new.description is distinct from old.description or new.unit is distinct from old.unit or new.quantity <> old.quantity
       or new.rate <> old.rate or new.discount_percent <> old.discount_percent or new.tax_percent <> old.tax_percent
       or new.net_amount <> old.net_amount or new.tax_amount <> old.tax_amount or new.line_total <> old.line_total then
        raise exception 'Items of a % purchase order cannot be changed. Create a revision.', v_status using errcode = 'VF409';
    end if;
    return new;
end $$;

drop trigger if exists trg_po_items_guard on vendorflow.po_items;
create trigger trg_po_items_guard before insert or update or delete on vendorflow.po_items
    for each row execute function vendorflow.trg_po_items_guard();

create or replace function vendorflow.trg_po_header_guard()
returns trigger language plpgsql as $$
begin
    if old.status not in ('Draft', 'PendingApproval') and old.status = new.status then
        -- status-preserving updates must not touch commercial fields
        if new.vendor_id <> old.vendor_id or new.subtotal <> old.subtotal or new.discount_total <> old.discount_total
           or new.tax_total <> old.tax_total or new.shipping <> old.shipping or new.total <> old.total or new.currency <> old.currency then
            raise exception 'A % purchase order cannot be changed. Create a revision.', old.status using errcode = 'VF409';
        end if;
    end if;
    return new;
end $$;

drop trigger if exists trg_po_header_guard on vendorflow.purchase_orders;
create trigger trg_po_header_guard before update on vendorflow.purchase_orders
    for each row execute function vendorflow.trg_po_header_guard();
