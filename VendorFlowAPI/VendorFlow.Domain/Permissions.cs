namespace VendorFlow.Domain;

/// <summary>Permission codes. They are also rows in vendorflow.permissions (see VendorFlowDB/08_SeedData).</summary>
public static class Permissions
{
    public const string VendorsView = "vendors.view";
    public const string VendorsCreate = "vendors.create";
    public const string VendorsEdit = "vendors.edit";
    public const string VendorsApprove = "vendors.approve";
    public const string VendorsSuspend = "vendors.suspend";
    public const string VendorsBankView = "vendors.bank.view";
    public const string VendorsBankManage = "vendors.bank.manage";
    public const string RequisitionsView = "requisitions.view";
    public const string RequisitionsCreate = "requisitions.create";
    public const string ApprovalsView = "approvals.view";
    public const string ApprovalsDecide = "approvals.decide";
    public const string ApprovalsManage = "approvals.manage";
    public const string RfqsView = "rfqs.view";
    public const string RfqsManage = "rfqs.manage";
    public const string QuotationsView = "quotations.view";
    public const string QuotationsRecommend = "quotations.recommend";
    public const string PoView = "po.view";
    public const string PoCreate = "po.create";
    public const string PoApprove = "po.approve";
    public const string PoIssue = "po.issue";
    public const string GrnView = "grn.view";
    public const string GrnRecord = "grn.record";
    public const string InvoicesView = "invoices.view";
    public const string InvoicesCreate = "invoices.create";
    public const string InvoicesReconcile = "invoices.reconcile";
    public const string PaymentsView = "payments.view";
    public const string PaymentsRecord = "payments.record";
    public const string ReportsView = "reports.view";
    public const string SettingsManage = "settings.manage";
    public const string UsersManage = "users.manage";
    public const string AuditView = "audit.view";
    public const string PortalQuote = "portal.quote";
}

public static class Roles
{
    public const string OrganizationOwner = "OrganizationOwner";
    public const string ProcurementManager = "ProcurementManager";
    public const string DepartmentRequester = "DepartmentRequester";
    public const string DepartmentManager = "DepartmentManager";
    public const string FinanceManager = "FinanceManager";
    public const string WarehouseManager = "WarehouseManager";
    public const string VendorPortalUser = "VendorPortalUser";
}
