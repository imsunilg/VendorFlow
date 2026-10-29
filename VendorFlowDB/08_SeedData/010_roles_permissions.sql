-- System permissions, roles and role/permission mapping (idempotent, re-applied on every start).

insert into vendorflow.permissions (code, description) values
 ('vendors.view','View vendors'),('vendors.create','Create vendors'),('vendors.edit','Edit vendors'),
 ('vendors.approve','Approve or reject vendors'),('vendors.suspend','Suspend or reactivate vendors'),
 ('vendors.bank.view','View vendor bank details'),('vendors.bank.manage','Edit vendor bank details'),
 ('requisitions.view','View requisitions'),('requisitions.create','Create and submit requisitions'),
 ('approvals.view','View approval inbox'),('approvals.decide','Approve, reject or request changes'),
 ('approvals.manage','Manage approval rules and delegations'),
 ('rfqs.view','View RFQs'),('rfqs.manage','Create and manage RFQs'),
 ('quotations.view','View and compare quotations'),('quotations.recommend','Record a quotation recommendation'),
 ('po.view','View purchase orders'),('po.create','Create purchase orders'),('po.approve','Submit PO for approval'),('po.issue','Issue purchase orders'),
 ('grn.view','View goods receipts'),('grn.record','Record goods receipts'),
 ('invoices.view','View invoices'),('invoices.create','Register invoices'),('invoices.reconcile','Reconcile and approve invoices'),
 ('payments.view','View payments'),('payments.record','Record payments'),
 ('reports.view','View reports and dashboards'),
 ('settings.manage','Manage organization settings'),('users.manage','Manage users and roles'),
 ('audit.view','View audit trail'),('portal.quote','Submit quotations as a vendor')
on conflict (code) do update set description = excluded.description;

insert into vendorflow.roles (code, name, description) values
 ('PlatformAdministrator','Platform Administrator','Operates the platform'),
 ('OrganizationOwner','Organization Owner','Owner of the organization'),
 ('OrganizationAdministrator','Organization Administrator','Administers the organization'),
 ('ProcurementManager','Procurement Manager','Runs procurement'),
 ('ProcurementOfficer','Procurement Officer','Day-to-day procurement'),
 ('DepartmentRequester','Department Requester','Raises requisitions'),
 ('DepartmentManager','Department Manager','Approves department requests'),
 ('Approver','Approver','General approver'),
 ('FinanceManager','Finance Manager','Finance approvals and payments'),
 ('AccountsPayableOfficer','Accounts Payable Officer','Invoices and payments'),
 ('WarehouseManager','Warehouse Manager','Receives goods'),
 ('Auditor','Auditor','Read-only access'),
 ('VendorPortalUser','Vendor Portal User','External vendor user')
on conflict (code) do update set name = excluded.name, description = excluded.description;

-- Rebuild the mapping so permission changes in this file always take effect.
delete from vendorflow.role_permissions;

with map(role_code, perms) as (values
 ('ProcurementManager', array['vendors.view','vendors.create','vendors.edit','vendors.approve','vendors.suspend',
    'requisitions.view','requisitions.create','approvals.view','approvals.decide','rfqs.view','rfqs.manage',
    'quotations.view','quotations.recommend','po.view','po.create','po.approve','po.issue','grn.view',
    'invoices.view','payments.view','reports.view']),
 ('ProcurementOfficer', array['vendors.view','vendors.create','vendors.edit','requisitions.view','requisitions.create',
    'rfqs.view','rfqs.manage','quotations.view','po.view','po.create','grn.view','invoices.view','reports.view']),
 ('DepartmentRequester', array['vendors.view','requisitions.view','requisitions.create']),
 ('DepartmentManager', array['vendors.view','requisitions.view','requisitions.create','approvals.view','approvals.decide','reports.view']),
 ('Approver', array['vendors.view','requisitions.view','approvals.view','approvals.decide','po.view']),
 ('FinanceManager', array['vendors.view','vendors.bank.view','vendors.bank.manage','requisitions.view','approvals.view',
    'approvals.decide','po.view','grn.view','invoices.view','invoices.create','invoices.reconcile',
    'payments.view','payments.record','reports.view']),
 ('AccountsPayableOfficer', array['vendors.view','po.view','grn.view','invoices.view','invoices.create',
    'invoices.reconcile','payments.view','payments.record','reports.view']),
 ('WarehouseManager', array['vendors.view','po.view','grn.view','grn.record']),
 ('Auditor', array['vendors.view','requisitions.view','approvals.view','rfqs.view','quotations.view','po.view',
    'grn.view','invoices.view','payments.view','reports.view','audit.view']),
 ('VendorPortalUser', array['portal.quote'])
)
insert into vendorflow.role_permissions (role_id, permission_code)
select r.id, p from map m
join vendorflow.roles r on r.code = m.role_code
cross join lateral unnest(m.perms) as p;

-- Platform admin, owner and org admin get everything.
insert into vendorflow.role_permissions (role_id, permission_code)
select r.id, p.code
from vendorflow.roles r cross join vendorflow.permissions p
where r.code in ('PlatformAdministrator','OrganizationOwner','OrganizationAdministrator') and p.code <> 'portal.quote';
