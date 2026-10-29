-- Dashboard and reports. Read only, tenant scoped.

-- Start of the current fiscal year (April by default, configurable via tax_settings.fiscalYearStartMonth).
create or replace function vendorflow.fn_fy_start(p_tenant_id uuid, p_on date default current_date)
returns date language sql stable as $$
    select make_date(extract(year from p_on)::int - case when extract(month from p_on)::int < m then 1 else 0 end, m, 1)
    from (select coalesce((select (tax_settings ->> 'fiscalYearStartMonth')::int from vendorflow.tenant_settings where tenant_id = p_tenant_id), 4) as m) x;
$$;

-- POs that count as procurement spend.
create or replace function vendorflow.fn_spend_statuses()
returns text[] language sql immutable as $$ select array['Approved','Issued','PartiallyReceived','FullyReceived','Closed','OnHold']; $$;

create or replace function vendorflow.fn_dashboard(p_tenant_id uuid, p_user_id uuid)
returns jsonb language plpgsql stable as $$
declare
    v_start date := vendorflow.fn_fy_start(p_tenant_id);
    v_end date := (vendorflow.fn_fy_start(p_tenant_id) + interval '1 year')::date;
    v_total numeric; v_prev numeric; v_change numeric;
    v_trend jsonb; v_dept jsonb; v_attention jsonb; v_docs jsonb; v_kpi jsonb;
    v_spend text[] := vendorflow.fn_spend_statuses();
    v_pending int; v_old int;
begin
    select coalesce(sum(total), 0) into v_total from vendorflow.purchase_orders
    where tenant_id = p_tenant_id and status = any(v_spend) and order_date >= v_start and order_date < v_end;
    select coalesce(sum(total), 0) into v_prev from vendorflow.purchase_orders
    where tenant_id = p_tenant_id and status = any(v_spend) and order_date >= (v_start - interval '1 year') and order_date < v_start;
    v_change := case when v_prev > 0 then round(100 * (v_total - v_prev) / v_prev, 1) else null end;

    select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'Mon'), 'year', extract(year from m)::int,
        'amount', coalesce((select sum(total) from vendorflow.purchase_orders po where po.tenant_id = p_tenant_id and po.status = any(v_spend)
                            and date_trunc('month', po.order_date) = m), 0)) order by m), '[]'::jsonb)
    into v_trend from generate_series(v_start::timestamp, least(date_trunc('month', current_date), (v_end - 1)::timestamp), interval '1 month') m;

    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'amount', amount,
        'pct', case when total_amt = 0 then 0 else round(100 * amount / total_amt) end) order by amount desc), '[]'::jsonb)
    into v_dept from (
        select coalesce(d.name, 'Unassigned') as name, sum(po.total) as amount, sum(sum(po.total)) over () as total_amt
        from vendorflow.purchase_orders po
        left join vendorflow.requisitions rq on rq.id = po.requisition_id
        left join vendorflow.departments d on d.id = rq.department_id
        where po.tenant_id = p_tenant_id and po.status = any(v_spend) and po.order_date >= v_start and po.order_date < v_end
        group by d.name) s;

    v_pending := (vendorflow.fn_approval_inbox(p_tenant_id, p_user_id, 'pending', 'oldest', 1, 1) -> 'counts' ->> 'pending')::int;
    select count(*) into v_old from vendorflow.approval_requests ar
    where ar.tenant_id = p_tenant_id and ar.status = 'Pending' and ar.created_at < now() - interval '2 days'
      and vendorflow.fn_step_eligibility(p_tenant_id, p_user_id, ar.id) is not null;

    v_kpi := jsonb_build_object(
        'total_procurement', jsonb_build_object('value', v_total, 'change_pct', v_change),
        'pending_approvals', jsonb_build_object('count', coalesce(v_pending, 0), 'older_than_2_days', v_old),
        'open_rfqs', jsonb_build_object('count', (select count(*) from vendorflow.rfqs where tenant_id = p_tenant_id and status = 'Open'),
            'new_this_week', (select count(*) from vendorflow.rfqs where tenant_id = p_tenant_id and status = 'Open' and created_at > now() - interval '7 days')),
        'outstanding_payments', jsonb_build_object(
            'amount', (select coalesce(sum(total - paid_amount), 0) from vendorflow.invoices where tenant_id = p_tenant_id and status in ('Approved', 'PartiallyPaid')),
            'overdue_count', (select count(*) from vendorflow.invoices where tenant_id = p_tenant_id and status in ('Approved', 'PartiallyPaid') and due_date < current_date)),
        'expiring_documents', (select count(*) from vendorflow.vendor_documents where tenant_id = p_tenant_id and expiry_date <= current_date + 30));

    select coalesce(jsonb_agg(x order by sort_at), '[]'::jsonb) into v_attention from (
        select jsonb_build_object('document', q.number, 'description', q.title, 'department', d.name, 'amount', q.total_amount,
               'status', 'Pending', 'entity_type', 'requisition', 'entity_id', q.id) as x, q.created_at as sort_at
        from vendorflow.requisitions q left join vendorflow.departments d on d.id = q.department_id
        where q.tenant_id = p_tenant_id and q.status = 'PendingApproval'
        union all
        select jsonb_build_object('document', po.number, 'description', 'Purchase order · ' || v.name, 'department', null, 'amount', po.total,
               'status', case when po.status = 'PendingApproval' then 'Pending' else 'Approved' end, 'entity_type', 'purchase_order', 'entity_id', po.id), po.created_at
        from vendorflow.purchase_orders po join vendorflow.vendors v on v.id = po.vendor_id
        where po.tenant_id = p_tenant_id and po.status in ('PendingApproval', 'Approved')
        union all
        select jsonb_build_object('document', i.invoice_number, 'description', 'Vendor bill – ' || v.name, 'department', 'Finance', 'amount', i.total - i.paid_amount,
               'status', 'Overdue', 'entity_type', 'invoice', 'entity_id', i.id), i.due_date::timestamptz
        from vendorflow.invoices i join vendorflow.vendors v on v.id = i.vendor_id
        where i.tenant_id = p_tenant_id and i.status in ('Approved', 'PartiallyPaid') and i.due_date < current_date
        order by sort_at limit 6) a;

    select coalesce(jsonb_agg(jsonb_build_object('vendor_name', v.name, 'doc_type', d.doc_type, 'expiry_date', d.expiry_date,
        'status', vendorflow.fn_doc_status(d.expiry_date), 'days_left', d.expiry_date - current_date) order by d.expiry_date), '[]'::jsonb)
    into v_docs from (select * from vendorflow.vendor_documents where tenant_id = p_tenant_id and expiry_date is not null
                      order by expiry_date limit 5) d join vendorflow.vendors v on v.id = d.vendor_id;

    return jsonb_build_object('fiscal_year', 'FY ' || extract(year from v_start)::int || '-' || to_char(v_end, 'YY'),
        'kpis', v_kpi, 'monthly_trend', v_trend, 'spend_by_department', v_dept, 'attention', v_attention, 'expiring_documents', v_docs);
end $$;

-- ---------------------------------------------------------------- reports

create or replace function vendorflow.fn_report_catalog()
returns jsonb language sql immutable as $$
    select jsonb_build_array(
        jsonb_build_object('key', 'expenditure', 'title', 'Procurement expenditure', 'description', 'Total spend by month, category, department or vendor', 'params', jsonb_build_array('from', 'to', 'groupBy')),
        jsonb_build_object('key', 'vendor-performance', 'title', 'Vendor performance', 'description', 'On-time delivery, quality, invoice accuracy', 'params', jsonb_build_array('from', 'to')),
        jsonb_build_object('key', 'po-status', 'title', 'Purchase order status', 'description', 'Open, partially received, closed', 'params', jsonb_build_array('from', 'to')),
        jsonb_build_object('key', 'invoice-exceptions', 'title', 'Invoice exceptions', 'description', 'Mismatches, tolerance breaches', 'params', jsonb_build_array('from', 'to')),
        jsonb_build_object('key', 'outstanding-payments', 'title', 'Outstanding payments', 'description', 'Aging buckets 0-30 / 31-60 / 60+', 'params', jsonb_build_array()),
        jsonb_build_object('key', 'expiring-documents', 'title', 'Expiring documents', 'description', 'Vendor certificates expiring soon', 'params', jsonb_build_array('days')));
$$;

create or replace function vendorflow.fn_report_run(p_tenant_id uuid, p_report text, p_from date, p_to date, p_group_by text default null, p_days int default 60)
returns jsonb language plpgsql stable as $$
declare
    v_from date := coalesce(p_from, vendorflow.fn_fy_start(p_tenant_id));
    v_to date := coalesce(p_to, current_date);
    v_spend text[] := vendorflow.fn_spend_statuses();
    v_group text := coalesce(p_group_by, 'month');
    v_rows jsonb; v_cols jsonb; v_title text;
begin
    if v_to < v_from then raise exception 'The end date must be on or after the start date.' using errcode = 'VF400'; end if;

    if p_report = 'expenditure' then
        if v_group not in ('month', 'category', 'department', 'vendor') then raise exception 'groupBy must be month, category, department or vendor.' using errcode = 'VF400'; end if;
        v_title := 'Procurement expenditure by ' || v_group;
        v_cols := jsonb_build_array(jsonb_build_object('key', 'label', 'label', initcap(v_group)), jsonb_build_object('key', 'poCount', 'label', 'POs', 'type', 'number'),
                                    jsonb_build_object('key', 'amount', 'label', 'Amount', 'type', 'money'));
select coalesce(jsonb_agg(jsonb_build_object('label', label, 'poCount', c, 'amount', amt)
            order by case when v_group = 'month' then label_sort end, amt desc), '[]'::jsonb) into v_rows from (
            select label, min(label_sort) as label_sort, count(*) as c, sum(total) as amt from (
            select case v_group when 'month' then to_char(date_trunc('month', po.order_date), 'Mon YYYY')
            when 'category' then coalesce(v.category, 'Uncategorised')
            when 'department' then coalesce(d.name, 'Unassigned')
            else v.name end as label,
            to_char(date_trunc('month', po.order_date), 'YYYY-MM') as label_sort, po.total
            from vendorflow.purchase_orders po join vendorflow.vendors v on v.id = po.vendor_id
            left join vendorflow.requisitions rq on rq.id = po.requisition_id left join vendorflow.departments d on d.id = rq.department_id
            where po.tenant_id = p_tenant_id and po.status = any(v_spend) and po.order_date between v_from and v_to) x
            group by label) s;

    elsif p_report = 'vendor-performance' then
        v_title := 'Vendor performance — top vendors by spend';
        v_cols := jsonb_build_array(jsonb_build_object('key', 'vendor', 'label', 'Vendor'), jsonb_build_object('key', 'poCount', 'label', 'POs', 'type', 'number'),
            jsonb_build_object('key', 'spend', 'label', 'Spend', 'type', 'money'), jsonb_build_object('key', 'onTime', 'label', 'On-time %', 'type', 'percent'),
            jsonb_build_object('key', 'acceptedQty', 'label', 'Accepted qty %', 'type', 'percent'), jsonb_build_object('key', 'score', 'label', 'Score', 'type', 'number'));
        select coalesce(jsonb_agg(r order by (r ->> 'spend')::numeric desc), '[]'::jsonb) into v_rows from (
            select jsonb_build_object('vendor', v.name, 'poCount', count(*), 'spend', sum(po.total),
                'onTime', (vendorflow.fn_vendor_performance(p_tenant_id, v.id) -> 'metrics' -> 0 ->> 'value')::numeric,
                'acceptedQty', (vendorflow.fn_vendor_performance(p_tenant_id, v.id) -> 'metrics' -> 1 ->> 'value')::numeric,
                'score', (vendorflow.fn_vendor_performance(p_tenant_id, v.id) ->> 'score')::numeric) as r
            from vendorflow.purchase_orders po join vendorflow.vendors v on v.id = po.vendor_id
            where po.tenant_id = p_tenant_id and po.status = any(v_spend) and po.order_date between v_from and v_to
            group by v.id, v.name order by sum(po.total) desc limit 20) s;

    elsif p_report = 'po-status' then
        v_title := 'Purchase order status';
        v_cols := jsonb_build_array(jsonb_build_object('key', 'status', 'label', 'Status'), jsonb_build_object('key', 'poCount', 'label', 'POs', 'type', 'number'),
                                    jsonb_build_object('key', 'amount', 'label', 'Amount', 'type', 'money'));
        select coalesce(jsonb_agg(jsonb_build_object('status', status, 'poCount', c, 'amount', amt) order by status), '[]'::jsonb) into v_rows from (
            select status, count(*) c, sum(total) amt from vendorflow.purchase_orders
            where tenant_id = p_tenant_id and order_date between v_from and v_to group by status) s;

    elsif p_report = 'invoice-exceptions' then
        v_title := 'Invoice exceptions';
        v_cols := jsonb_build_array(jsonb_build_object('key', 'invoiceNumber', 'label', 'Invoice'), jsonb_build_object('key', 'vendor', 'label', 'Vendor'),
            jsonb_build_object('key', 'poNumber', 'label', 'PO'), jsonb_build_object('key', 'status', 'label', 'Status'),
            jsonb_build_object('key', 'total', 'label', 'Total', 'type', 'money'), jsonb_build_object('key', 'varianceAmount', 'label', 'Variance', 'type', 'money'),
            jsonb_build_object('key', 'variancePct', 'label', 'Variance %', 'type', 'percent'), jsonb_build_object('key', 'discrepancies', 'label', 'Discrepancies', 'type', 'number'));
        select coalesce(jsonb_agg(jsonb_build_object('invoiceNumber', i.invoice_number, 'vendor', v.name, 'poNumber', po.number, 'status', i.status,
            'total', i.total, 'varianceAmount', i.variance_amount, 'variancePct', i.variance_pct,
            'discrepancies', (select count(*) from vendorflow.invoice_discrepancies d where d.invoice_id = i.id)) order by i.invoice_date desc), '[]'::jsonb) into v_rows
        from vendorflow.invoices i join vendorflow.vendors v on v.id = i.vendor_id left join vendorflow.purchase_orders po on po.id = i.po_id
        where i.tenant_id = p_tenant_id and i.status in ('NeedsReview', 'Disputed') and i.invoice_date between v_from and v_to;

    elsif p_report = 'outstanding-payments' then
        v_title := 'Outstanding payments by age (days since invoice date)';
        v_cols := jsonb_build_array(jsonb_build_object('key', 'bucket', 'label', 'Age bucket'), jsonb_build_object('key', 'invoiceCount', 'label', 'Invoices', 'type', 'number'),
                                    jsonb_build_object('key', 'balance', 'label', 'Balance', 'type', 'money'));
        select coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'invoiceCount', c, 'balance', amt) order by b), '[]'::jsonb) into v_rows from (
            select case when current_date - invoice_date <= 30 then '0-30 days' when current_date - invoice_date <= 60 then '31-60 days' else '60+ days' end as b,
                   count(*) c, sum(total - paid_amount) amt
            from vendorflow.invoices where tenant_id = p_tenant_id and status in ('Approved', 'PartiallyPaid') group by 1) s;

    elsif p_report = 'expiring-documents' then
        v_title := 'Vendor documents expiring within ' || p_days || ' days';
        v_cols := jsonb_build_array(jsonb_build_object('key', 'vendor', 'label', 'Vendor'), jsonb_build_object('key', 'docType', 'label', 'Document'),
            jsonb_build_object('key', 'docNumber', 'label', 'Number'), jsonb_build_object('key', 'expiryDate', 'label', 'Expiry'),
            jsonb_build_object('key', 'daysLeft', 'label', 'Days left', 'type', 'number'), jsonb_build_object('key', 'status', 'label', 'Status'));
        select coalesce(jsonb_agg(jsonb_build_object('vendor', v.name, 'docType', d.doc_type, 'docNumber', d.doc_number, 'expiryDate', d.expiry_date,
            'daysLeft', d.expiry_date - current_date, 'status', vendorflow.fn_doc_status(d.expiry_date)) order by d.expiry_date), '[]'::jsonb) into v_rows
        from vendorflow.vendor_documents d join vendorflow.vendors v on v.id = d.vendor_id
        where d.tenant_id = p_tenant_id and d.expiry_date is not null and d.expiry_date <= current_date + greatest(coalesce(p_days, 60), 1);
    else
        raise exception 'Unknown report.' using errcode = 'VF404';
    end if;

    return jsonb_build_object('report', p_report, 'title', v_title, 'from', v_from, 'to', v_to, 'columns', v_cols, 'rows', v_rows);
end $$;
