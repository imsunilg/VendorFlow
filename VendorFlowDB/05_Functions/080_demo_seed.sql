-- Demo data for the Development environment ONLY (called by DemoSeeder when Seed:DemoData is true).
-- Everything is created through the normal functions, so the demo exercises the real rules (approvals, matching, ...).
-- p_users = { priya, mark, rahul, sneha, anita, suresh } user ids of the demo tenant.

create or replace function vendorflow.fn_seed_demo_data(p_tenant_id uuid, p_users jsonb)
returns jsonb language plpgsql as $$
declare
    u_priya uuid := (p_users ->> 'priya')::uuid;
    u_mark uuid := (p_users ->> 'mark')::uuid;
    u_rahul uuid := (p_users ->> 'rahul')::uuid;
    u_sneha uuid := (p_users ->> 'sneha')::uuid;
    u_anita uuid := (p_users ->> 'anita')::uuid;
    u_suresh uuid := (p_users ->> 'suresh')::uuid;
    d_it uuid; d_ops uuid; d_adm uuid;
    c_it uuid; c_ops uuid; c_adm uuid;
    v_sona uuid; v_rk uuid; v_vishwa uuid; v_next uuid; v_prism uuid; v_delta uuid; v_kumar uuid;
    r jsonb; v_rid uuid; v_req_switches uuid;
    v_rfq jsonb; v_rfq_id uuid; v_item uuid;
    v_po jsonb; v_po_id uuid; v_inv jsonb;
    toks jsonb; v_res jsonb;
begin
    if exists (select 1 from vendorflow.vendors where tenant_id = p_tenant_id) then
        return jsonb_build_object('seeded', false);
    end if;

    select id into d_it from vendorflow.departments where tenant_id = p_tenant_id and name = 'IT';
    select id into d_ops from vendorflow.departments where tenant_id = p_tenant_id and name = 'Site Operations';
    select id into d_adm from vendorflow.departments where tenant_id = p_tenant_id and name = 'Admin';
    select id into c_it from vendorflow.cost_centres where tenant_id = p_tenant_id and code = 'CC-IT-01';
    select id into c_ops from vendorflow.cost_centres where tenant_id = p_tenant_id and code = 'CC-OPS-04';
    select id into c_adm from vendorflow.cost_centres where tenant_id = p_tenant_id and code = 'CC-ADM-02';
    update vendorflow.departments set manager_user_id = u_rahul where id in (d_it, d_ops, d_adm);

    -- ---------------------------------------------------------------- vendors
    v_sona := (vendorflow.fn_vendor_create(p_tenant_id, u_priya, jsonb_build_object('name', 'Sona Tech Components', 'category', 'Electronics',
        'city', 'Pune', 'state', 'Maharashtra', 'gstin', '27AABCS1234F1Z5', 'pan', 'AABCS1234F', 'msme_number', 'UDYAM-MH-26-0012345',
        'email', 'anil@sonatech.in', 'phone', '+91 98220 12345', 'risk', 'Low', 'rating', 4.6, 'payment_terms_days', 30)) ->> 'id')::uuid;
    v_rk := (vendorflow.fn_vendor_create(p_tenant_id, u_priya, jsonb_build_object('name', 'R.K. Steel Fabricators', 'category', 'Metal & Structural',
        'city', 'Mumbai', 'state', 'Maharashtra', 'gstin', '27AAFCR5521K1ZP', 'email', 'sales@rksteel.in', 'risk', 'Low', 'rating', 4.5)) ->> 'id')::uuid;
    v_vishwa := (vendorflow.fn_vendor_create(p_tenant_id, u_priya, jsonb_build_object('name', 'Vishwa Metals & Alloys', 'category', 'Raw Materials',
        'city', 'Ahmedabad', 'state', 'Gujarat', 'gstin', '24AAGCV8890B1Z2', 'email', 'info@vishwametals.in', 'risk', 'Medium', 'rating', 4.2)) ->> 'id')::uuid;
    v_next := (vendorflow.fn_vendor_create(p_tenant_id, u_priya, jsonb_build_object('name', 'NextGen Logistics', 'category', 'Freight & Transport',
        'city', 'Delhi', 'state', 'Delhi', 'gstin', '07AADCN4410Q1Z9', 'email', 'hello@nextgen.in', 'risk', 'Low', 'rating', 4.6)) ->> 'id')::uuid;
    v_prism := (vendorflow.fn_vendor_create(p_tenant_id, u_priya, jsonb_build_object('name', 'Prism Plastics & Polymers', 'category', 'Packaging',
        'city', 'Chennai', 'state', 'Tamil Nadu', 'gstin', '33AAECP2210M1ZV', 'email', 'orders@prismplastics.in', 'risk', 'High', 'rating', 3.9)) ->> 'id')::uuid;
    v_delta := (vendorflow.fn_vendor_create(p_tenant_id, u_priya, jsonb_build_object('name', 'Delta Industrial Supplies', 'category', 'Tools & Consumables',
        'city', 'Bengaluru', 'state', 'Karnataka', 'gstin', '29AAACD7731H1Z1', 'email', 'sales@deltaindustrial.in', 'risk', 'Low', 'rating', 4.7, 'payment_terms_days', 45)) ->> 'id')::uuid;
    v_kumar := (vendorflow.fn_vendor_create(p_tenant_id, u_priya, jsonb_build_object('name', 'Kumar Stationery', 'category', 'Office Supplies',
        'city', 'Navi Mumbai', 'state', 'Maharashtra', 'gstin', '27AAHFK9912L1ZC', 'email', 'kumar@stationery.in', 'risk', 'Low', 'rating', 4.1)) ->> 'id')::uuid;

    perform vendorflow.fn_vendor_transition(p_tenant_id, u_priya, x, 'submit', null) from unnest(array[v_sona, v_rk, v_vishwa, v_next, v_prism, v_delta]) x;
    perform vendorflow.fn_vendor_transition(p_tenant_id, u_priya, x, 'approve', 'Documents verified') from unnest(array[v_sona, v_rk, v_next, v_prism, v_delta]) x;
    perform vendorflow.fn_vendor_transition(p_tenant_id, u_priya, v_prism, 'suspend', 'GST certificate expired');

    perform vendorflow.fn_vendor_contact_save(p_tenant_id, u_priya, v_sona, jsonb_build_object('name', 'Anil Kulkarni', 'designation', 'Sales Head',
        'email', 'anil@sonatech.in', 'phone', '+91 98220 12345', 'is_primary', true));
    perform vendorflow.fn_vendor_address_save(p_tenant_id, u_priya, v_sona, jsonb_build_object('line1', 'Plot 14, MIDC Bhosari', 'city', 'Pune', 'state', 'Maharashtra', 'postal_code', '411026'));
    perform vendorflow.fn_vendor_document_save(p_tenant_id, u_priya, v_sona, jsonb_build_object('doc_type', 'GST Registration', 'doc_number', '27AABCS1234F1Z5'));
    perform vendorflow.fn_vendor_document_save(p_tenant_id, u_priya, v_sona, jsonb_build_object('doc_type', 'MSME Certificate', 'doc_number', 'UDYAM-MH-26-0012345', 'expiry_date', (current_date + 28)::text));
    perform vendorflow.fn_vendor_document_save(p_tenant_id, u_priya, v_sona, jsonb_build_object('doc_type', 'ISO 9001:2015', 'doc_number', 'ISO-2291-A', 'expiry_date', (current_date + 290)::text));
    perform vendorflow.fn_vendor_document_save(p_tenant_id, u_priya, v_sona, jsonb_build_object('doc_type', 'Cancelled cheque'));
    perform vendorflow.fn_vendor_document_save(p_tenant_id, u_priya, v_rk, jsonb_build_object('doc_type', 'ISO 9001', 'expiry_date', (current_date + 12)::text));
    perform vendorflow.fn_vendor_document_save(p_tenant_id, u_priya, v_prism, jsonb_build_object('doc_type', 'GST Cert', 'expiry_date', (current_date - 4)::text));
    perform vendorflow.fn_vendor_document_save(p_tenant_id, u_priya, v_delta, jsonb_build_object('doc_type', 'PAN', 'doc_number', 'AAACD7731H'));
    perform vendorflow.fn_vendor_bank_save(p_tenant_id, u_sneha, v_sona, jsonb_build_object('account_name', 'Sona Tech Components', 'account_number', '50200012345678',
        'ifsc', 'HDFC0001234', 'bank_name', 'HDFC Bank', 'branch', 'Bhosari, Pune'));

    -- ---------------------------------------------------------------- requisitions and approvals
    -- 1. Laptops 6,20,000 -> waiting for Rahul (step 1 of 2)
    r := vendorflow.fn_requisition_save(p_tenant_id, u_anita, null, jsonb_build_object('title', 'Laptops for new joiners', 'department_id', d_it, 'cost_centre_id', c_it,
        'required_date', (current_date + 20)::text, 'priority', 'High', 'justification', 'Ten new engineers joining in November need laptops before onboarding.',
        'items', jsonb_build_array(jsonb_build_object('description', 'Dell Latitude 5440, i5, 16GB/512GB', 'quantity', 10, 'est_unit_price', 58000),
            jsonb_build_object('description', 'Laptop bag 15.6"', 'quantity', 10, 'est_unit_price', 1500),
            jsonb_build_object('description', 'Wireless mouse', 'quantity', 10, 'est_unit_price', 2500))));
    perform vendorflow.fn_requisition_submit(p_tenant_id, u_anita, (r ->> 'id')::uuid);

    -- 2. Safety helmets 84,000 -> waiting for Rahul
    r := vendorflow.fn_requisition_save(p_tenant_id, u_anita, null, jsonb_build_object('title', 'Safety helmets (200 pcs)', 'department_id', d_ops, 'cost_centre_id', c_ops,
        'required_date', (current_date + 12)::text, 'priority', 'Medium',
        'items', jsonb_build_array(jsonb_build_object('description', 'Safety helmet, ISI marked', 'quantity', 200, 'est_unit_price', 420))));
    perform vendorflow.fn_requisition_submit(p_tenant_id, u_anita, (r ->> 'id')::uuid);

    -- 3. Office chairs 1,12,500 -> fully approved (2 steps)
    r := vendorflow.fn_requisition_save(p_tenant_id, u_anita, null, jsonb_build_object('title', 'Office chairs – 25 nos', 'department_id', d_adm, 'cost_centre_id', c_adm,
        'required_date', (current_date + 30)::text,
        'items', jsonb_build_array(jsonb_build_object('description', 'Ergonomic office chair', 'quantity', 25, 'est_unit_price', 4500))));
    r := vendorflow.fn_requisition_submit(p_tenant_id, u_anita, (r ->> 'id')::uuid);
    v_rid := (r -> 'approval' ->> 'id')::uuid;
    perform vendorflow.fn_approval_decide(p_tenant_id, u_rahul, v_rid, 'approve', 'Approved', null);
    perform vendorflow.fn_approval_decide(p_tenant_id, u_sneha, v_rid, 'approve', 'Budget available', null);

    -- 4. Network switches 2,40,000 -> approved, then sent to RFQ
    r := vendorflow.fn_requisition_save(p_tenant_id, u_anita, null, jsonb_build_object('title', 'Network switches', 'department_id', d_it, 'cost_centre_id', c_it,
        'required_date', (current_date + 15)::text,
        'items', jsonb_build_array(jsonb_build_object('description', '24-port PoE switch', 'unit', 'Nos', 'quantity', 8, 'est_unit_price', 30000))));
    v_req_switches := (r ->> 'id')::uuid;
    r := vendorflow.fn_requisition_submit(p_tenant_id, u_anita, v_req_switches);
    v_rid := (r -> 'approval' ->> 'id')::uuid;
    perform vendorflow.fn_approval_decide(p_tenant_id, u_rahul, v_rid, 'approve', 'Approved', null);
    perform vendorflow.fn_approval_decide(p_tenant_id, u_sneha, v_rid, 'approve', 'Approved', null);

    -- 5. Welding consumables -> returned for modification
    r := vendorflow.fn_requisition_save(p_tenant_id, u_anita, null, jsonb_build_object('title', 'Welding consumables', 'department_id', d_ops, 'cost_centre_id', c_ops,
        'required_date', (current_date + 10)::text,
        'items', jsonb_build_array(jsonb_build_object('description', 'Welding electrodes 3.15mm', 'quantity', 120, 'est_unit_price', 390))));
    r := vendorflow.fn_requisition_submit(p_tenant_id, u_anita, (r ->> 'id')::uuid);
    perform vendorflow.fn_approval_decide(p_tenant_id, u_rahul, (r -> 'approval' ->> 'id')::uuid, 'return', 'Please add the grade and brand.', null);

    -- 6. Printer toner -> rejected
    r := vendorflow.fn_requisition_save(p_tenant_id, u_anita, null, jsonb_build_object('title', 'Printer toner cartridges', 'department_id', d_adm, 'cost_centre_id', c_adm,
        'required_date', (current_date + 8)::text,
        'items', jsonb_build_array(jsonb_build_object('description', 'Toner cartridge 12A', 'quantity', 15, 'est_unit_price', 1260))));
    r := vendorflow.fn_requisition_submit(p_tenant_id, u_anita, (r ->> 'id')::uuid);
    perform vendorflow.fn_approval_decide(p_tenant_id, u_rahul, (r -> 'approval' ->> 'id')::uuid, 'reject', 'Stock available in the store room.', null);

    -- 7. Annual AMC -> draft
    perform vendorflow.fn_requisition_save(p_tenant_id, u_anita, null, jsonb_build_object('title', 'Annual AMC – AC units', 'department_id', d_adm, 'cost_centre_id', c_adm,
        'required_date', (current_date + 40)::text,
        'items', jsonb_build_array(jsonb_build_object('description', 'AMC for 24 split ACs', 'quantity', 24, 'est_unit_price', 15000))));

    -- ---------------------------------------------------------------- RFQ with three quotations (network switches)
    v_rfq := vendorflow.fn_rfq_create(p_tenant_id, u_priya, jsonb_build_object('title', 'Network switches', 'requisition_id', v_req_switches,
        'description', '24-port PoE switch, qty 8', 'deadline', (now() + interval '6 days')::text,
        'vendor_ids', jsonb_build_array(v_sona, v_next, v_delta, v_rk)));
    v_rfq_id := (v_rfq ->> 'id')::uuid;
    v_item := (v_rfq -> 'items' -> 0 ->> 'id')::uuid;
    toks := jsonb_build_object(v_sona::text, md5(random()::text), v_next::text, md5(random()::text), v_delta::text, md5(random()::text), v_rk::text, md5(random()::text));
    perform vendorflow.fn_rfq_open(p_tenant_id, u_priya, v_rfq_id, toks);
    perform vendorflow.fn_rfq_enter_quotation(p_tenant_id, u_priya, v_rfq_id, v_sona, jsonb_build_object('shipping', 2500, 'delivery_days', 10, 'payment_terms', 'Net 30', 'warranty_months', 36,
        'items', jsonb_build_array(jsonb_build_object('rfq_item_id', v_item, 'unit_price', 26000, 'discount_percent', 5, 'tax_percent', 18))));
    perform vendorflow.fn_rfq_enter_quotation(p_tenant_id, u_priya, v_rfq_id, v_next, jsonb_build_object('shipping', 4800, 'delivery_days', 21, 'payment_terms', 'Advance 50%', 'warranty_months', 12,
        'items', jsonb_build_array(jsonb_build_object('rfq_item_id', v_item, 'unit_price', 24500, 'discount_percent', 3, 'tax_percent', 18))));
    perform vendorflow.fn_rfq_enter_quotation(p_tenant_id, u_priya, v_rfq_id, v_delta, jsonb_build_object('shipping', 0, 'delivery_days', 7, 'payment_terms', 'Net 45', 'warranty_months', 36,
        'items', jsonb_build_array(jsonb_build_object('rfq_item_id', v_item, 'unit_price', 27200, 'discount_percent', 8, 'tax_percent', 18))));

    -- ---------------------------------------------------------------- PO 1 (Sona Tech): issued, partly received, invoice needs review
    v_po := vendorflow.fn_po_create(p_tenant_id, u_priya, jsonb_build_object('vendor_id', v_sona, 'expected_delivery', (current_date + 20)::text, 'shipping', 2500,
        'items', jsonb_build_array(
            jsonb_build_object('description', 'Cisco 24-port PoE switch', 'quantity', 8, 'rate', 24500, 'discount_percent', 5, 'tax_percent', 18),
            jsonb_build_object('description', 'Rack mount kit', 'quantity', 8, 'rate', 1200, 'tax_percent', 18),
            jsonb_build_object('description', 'Cat6 patch cables (3 m)', 'quantity', 50, 'rate', 180, 'tax_percent', 18))));
    v_po_id := (v_po ->> 'id')::uuid;
    r := vendorflow.fn_po_submit(p_tenant_id, u_priya, v_po_id);
    perform vendorflow.fn_approval_decide(p_tenant_id, u_mark, (r -> 'approval' ->> 'id')::uuid, 'approve', 'Approved', null);
    perform vendorflow.fn_po_issue(p_tenant_id, u_priya, v_po_id);
    perform vendorflow.fn_grn_post(p_tenant_id, u_suresh, v_po_id, jsonb_build_object('warehouse', 'Navi Mumbai WH-1', 'delivery_challan', 'DC-88231',
        'vehicle_no', 'MH 43 AB 4521', 'received_by', 'Suresh Jadhav', 'inspection_notes', '1 rack kit damaged in transit; 2 cables failed continuity test.',
        'items', jsonb_build_array(
            jsonb_build_object('po_item_id', (select id from vendorflow.po_items where po_id = v_po_id and line_no = 1), 'received_qty', 5, 'accepted_qty', 5, 'rejected_qty', 0),
            jsonb_build_object('po_item_id', (select id from vendorflow.po_items where po_id = v_po_id and line_no = 2), 'received_qty', 5, 'accepted_qty', 4, 'rejected_qty', 1, 'damaged_qty', 1),
            jsonb_build_object('po_item_id', (select id from vendorflow.po_items where po_id = v_po_id and line_no = 3), 'received_qty', 20, 'accepted_qty', 18, 'rejected_qty', 2))));
    perform vendorflow.fn_invoice_register(p_tenant_id, u_sneha, jsonb_build_object('po_id', v_po_id, 'invoice_number', 'INV-77821', 'invoice_date', (current_date - 3)::text,
        'items', jsonb_build_array(
            jsonb_build_object('po_item_id', (select id from vendorflow.po_items where po_id = v_po_id and line_no = 1), 'quantity', 5),
            jsonb_build_object('po_item_id', (select id from vendorflow.po_items where po_id = v_po_id and line_no = 2), 'quantity', 5),
            jsonb_build_object('po_item_id', (select id from vendorflow.po_items where po_id = v_po_id and line_no = 3), 'quantity', 18, 'tax_amount', 590))));

    -- ---------------------------------------------------------------- PO 2 (Delta): fully received, invoiced, partly paid, overdue
    v_po := vendorflow.fn_po_create(p_tenant_id, u_priya, jsonb_build_object('vendor_id', v_delta, 'expected_delivery', (current_date - 30)::text,
        'items', jsonb_build_array(jsonb_build_object('description', 'Industrial consumables lot', 'quantity', 100, 'rate', 2850, 'tax_percent', 18))));
    v_po_id := (v_po ->> 'id')::uuid;
    r := vendorflow.fn_po_submit(p_tenant_id, u_priya, v_po_id);
    perform vendorflow.fn_approval_decide(p_tenant_id, u_mark, (r -> 'approval' ->> 'id')::uuid, 'approve', 'Approved', null);
    perform vendorflow.fn_po_issue(p_tenant_id, u_priya, v_po_id);
    perform vendorflow.fn_grn_post(p_tenant_id, u_suresh, v_po_id, jsonb_build_object('warehouse', 'Navi Mumbai WH-1', 'delivery_challan', 'DC-77100', 'received_on', (current_date - 40)::text,
        'items', jsonb_build_array(jsonb_build_object('po_item_id', (select id from vendorflow.po_items where po_id = v_po_id), 'received_qty', 100, 'accepted_qty', 100, 'rejected_qty', 0))));
    v_inv := vendorflow.fn_invoice_register(p_tenant_id, u_sneha, jsonb_build_object('po_id', v_po_id, 'invoice_number', 'INV-77790', 'invoice_date', (current_date - 60)::text,
        'items', jsonb_build_array(jsonb_build_object('po_item_id', (select id from vendorflow.po_items where po_id = v_po_id), 'quantity', 100))));
    perform vendorflow.fn_invoice_reconcile(p_tenant_id, u_sneha, (v_inv ->> 'id')::uuid, 'Matched');
    call vendorflow.sp_payment_record(p_tenant_id, u_sneha, (v_inv ->> 'id')::uuid, 150000, 'NEFT', 'UTR882310', current_date - 10, 'seed-payment-1', null, v_res);

    -- ---------------------------------------------------------------- PO 3 (R.K. Steel): approved, waiting to be issued; PO 4 (Delta): draft
    v_po := vendorflow.fn_po_create(p_tenant_id, u_priya, jsonb_build_object('vendor_id', v_rk, 'expected_delivery', (current_date + 25)::text,
        'items', jsonb_build_array(jsonb_build_object('description', 'MS angle 50x50x6', 'quantity', 400, 'rate', 410, 'tax_percent', 18))));
    r := vendorflow.fn_po_submit(p_tenant_id, u_priya, (v_po ->> 'id')::uuid);
    perform vendorflow.fn_approval_decide(p_tenant_id, u_mark, (r -> 'approval' ->> 'id')::uuid, 'approve', 'Approved', null);
    perform vendorflow.fn_po_create(p_tenant_id, u_priya, jsonb_build_object('vendor_id', v_delta, 'expected_delivery', (current_date + 18)::text,
        'items', jsonb_build_array(jsonb_build_object('description', 'Cutting discs 4 inch', 'quantity', 300, 'rate', 62, 'tax_percent', 18))));

    return jsonb_build_object('seeded', true);
end $$;
