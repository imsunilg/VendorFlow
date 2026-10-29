import { Routes } from '@angular/router';
import { authGuard } from './core/guards/auth.guard';
import { permissionGuard } from './core/guards/permission.guard';

// Every page is lazy loaded. "permission" in route data hides pages the user may not open (the API enforces it anyway).
export const routes: Routes = [
  // ---- public pages
  { path: 'login', loadComponent: () => import('./features/auth/login/login.component').then(m => m.LoginComponent) },
  { path: 'register', loadComponent: () => import('./features/auth/register/register.component').then(m => m.RegisterComponent) },
  { path: 'forgot-password', loadComponent: () => import('./features/auth/forgot-password/forgot-password.component').then(m => m.ForgotPasswordComponent) },
  { path: 'reset-password', loadComponent: () => import('./features/auth/reset-password/reset-password.component').then(m => m.ResetPasswordComponent) },
  { path: 'portal/rfq/:token', loadComponent: () => import('./features/rfqs/vendor-portal/vendor-portal.component').then(m => m.VendorPortalComponent) },

  // ---- signed-in pages inside the shell
  {
    path: '',
    canActivate: [authGuard],
    loadComponent: () => import('./features/layout/shell/shell.component').then(m => m.ShellComponent),
    children: [
      { path: '', pathMatch: 'full', loadComponent: () => import('./features/dashboard/dashboard.component').then(m => m.DashboardComponent), data: { breadcrumb: 'Dashboard' } },

      { path: 'vendors', canActivate: [permissionGuard], data: { permission: 'vendors.view', breadcrumb: 'Vendors' }, loadComponent: () => import('./features/vendors/vendor-list/vendor-list.component').then(m => m.VendorListComponent) },
      { path: 'vendors/new', canActivate: [permissionGuard], data: { permission: 'vendors.create', breadcrumb: 'Vendors / New' }, loadComponent: () => import('./features/vendors/vendor-form/vendor-form.component').then(m => m.VendorFormComponent) },
      { path: 'vendors/:id', canActivate: [permissionGuard], data: { permission: 'vendors.view', breadcrumb: 'Vendors / Details' }, loadComponent: () => import('./features/vendors/vendor-detail/vendor-detail.component').then(m => m.VendorDetailComponent) },
      { path: 'vendors/:id/edit', canActivate: [permissionGuard], data: { permission: 'vendors.edit', breadcrumb: 'Vendors / Edit' }, loadComponent: () => import('./features/vendors/vendor-form/vendor-form.component').then(m => m.VendorFormComponent) },

      { path: 'requisitions', canActivate: [permissionGuard], data: { permission: 'requisitions.view', breadcrumb: 'Requisitions' }, loadComponent: () => import('./features/requisitions/requisition-list/requisition-list.component').then(m => m.RequisitionListComponent) },
      { path: 'requisitions/new', canActivate: [permissionGuard], data: { permission: 'requisitions.create', breadcrumb: 'Requisitions / New' }, loadComponent: () => import('./features/requisitions/requisition-form/requisition-form.component').then(m => m.RequisitionFormComponent) },
      { path: 'requisitions/:id', canActivate: [permissionGuard], data: { permission: 'requisitions.view', breadcrumb: 'Requisitions / Details' }, loadComponent: () => import('./features/requisitions/requisition-detail/requisition-detail.component').then(m => m.RequisitionDetailComponent) },
      { path: 'requisitions/:id/edit', canActivate: [permissionGuard], data: { permission: 'requisitions.create', breadcrumb: 'Requisitions / Edit' }, loadComponent: () => import('./features/requisitions/requisition-form/requisition-form.component').then(m => m.RequisitionFormComponent) },

      { path: 'approvals', canActivate: [permissionGuard], data: { permission: 'approvals.view', breadcrumb: 'Approvals' }, loadComponent: () => import('./features/approvals/approval-inbox/approval-inbox.component').then(m => m.ApprovalInboxComponent) },

      { path: 'rfqs', canActivate: [permissionGuard], data: { permission: 'rfqs.view', breadcrumb: 'RFQs' }, loadComponent: () => import('./features/rfqs/rfq-list/rfq-list.component').then(m => m.RfqListComponent) },
      { path: 'rfqs/new', canActivate: [permissionGuard], data: { permission: 'rfqs.manage', breadcrumb: 'RFQs / New' }, loadComponent: () => import('./features/rfqs/rfq-form/rfq-form.component').then(m => m.RfqFormComponent) },
      { path: 'rfqs/:id', canActivate: [permissionGuard], data: { permission: 'rfqs.view', breadcrumb: 'RFQs / Details' }, loadComponent: () => import('./features/rfqs/rfq-detail/rfq-detail.component').then(m => m.RfqDetailComponent) },
      { path: 'rfqs/:id/quote/:vendorId', canActivate: [permissionGuard], data: { permission: 'rfqs.manage', breadcrumb: 'RFQs / Enter quotation' }, loadComponent: () => import('./features/rfqs/quotation-entry/quotation-entry.component').then(m => m.QuotationEntryComponent) },
      { path: 'quotations', canActivate: [permissionGuard], data: { permission: 'quotations.view', breadcrumb: 'Quotations' }, loadComponent: () => import('./features/quotations/quotation-picker/quotation-picker.component').then(m => m.QuotationPickerComponent) },
      { path: 'quotations/:rfqId', canActivate: [permissionGuard], data: { permission: 'quotations.view', breadcrumb: 'Quotations / Compare' }, loadComponent: () => import('./features/quotations/quotation-compare/quotation-compare.component').then(m => m.QuotationCompareComponent) },

      { path: 'purchase-orders', canActivate: [permissionGuard], data: { permission: 'po.view', breadcrumb: 'Purchase Orders' }, loadComponent: () => import('./features/purchase-orders/po-list/po-list.component').then(m => m.PoListComponent) },
      { path: 'purchase-orders/new', canActivate: [permissionGuard], data: { permission: 'po.create', breadcrumb: 'Purchase Orders / New' }, loadComponent: () => import('./features/purchase-orders/po-form/po-form.component').then(m => m.PoFormComponent) },
      { path: 'purchase-orders/:id', canActivate: [permissionGuard], data: { permission: 'po.view', breadcrumb: 'Purchase Orders / Details' }, loadComponent: () => import('./features/purchase-orders/po-detail/po-detail.component').then(m => m.PoDetailComponent) },
      { path: 'purchase-orders/:id/edit', canActivate: [permissionGuard], data: { permission: 'po.create', breadcrumb: 'Purchase Orders / Edit' }, loadComponent: () => import('./features/purchase-orders/po-form/po-form.component').then(m => m.PoFormComponent) },

      { path: 'goods-receipts', canActivate: [permissionGuard], data: { permission: 'grn.view', breadcrumb: 'Goods Receipts' }, loadComponent: () => import('./features/goods-receipts/grn-list/grn-list.component').then(m => m.GrnListComponent) },
      { path: 'goods-receipts/new/:poId', canActivate: [permissionGuard], data: { permission: 'grn.record', breadcrumb: 'Goods Receipts / New' }, loadComponent: () => import('./features/goods-receipts/grn-form/grn-form.component').then(m => m.GrnFormComponent) },
      { path: 'goods-receipts/:id', canActivate: [permissionGuard], data: { permission: 'grn.view', breadcrumb: 'Goods Receipts / Details' }, loadComponent: () => import('./features/goods-receipts/grn-detail/grn-detail.component').then(m => m.GrnDetailComponent) },

      { path: 'invoices', canActivate: [permissionGuard], data: { permission: 'invoices.view', breadcrumb: 'Invoices' }, loadComponent: () => import('./features/invoices/invoice-list/invoice-list.component').then(m => m.InvoiceListComponent) },
      { path: 'invoices/new', canActivate: [permissionGuard], data: { permission: 'invoices.create', breadcrumb: 'Invoices / New' }, loadComponent: () => import('./features/invoices/invoice-form/invoice-form.component').then(m => m.InvoiceFormComponent) },
      { path: 'invoices/:id/edit', canActivate: [permissionGuard], data: { permission: 'invoices.create', breadcrumb: 'Invoices / Correct' }, loadComponent: () => import('./features/invoices/invoice-form/invoice-form.component').then(m => m.InvoiceFormComponent) },
      { path: 'invoices/:id', canActivate: [permissionGuard], data: { permission: 'invoices.view', breadcrumb: 'Invoices / Match' }, loadComponent: () => import('./features/invoices/invoice-detail/invoice-detail.component').then(m => m.InvoiceDetailComponent) },

      { path: 'payments', canActivate: [permissionGuard], data: { permission: 'payments.view', breadcrumb: 'Payments' }, loadComponent: () => import('./features/payments/payment-list/payment-list.component').then(m => m.PaymentListComponent) },
      { path: 'reports', canActivate: [permissionGuard], data: { permission: 'reports.view', breadcrumb: 'Reports' }, loadComponent: () => import('./features/reports/report-viewer/report-viewer.component').then(m => m.ReportViewerComponent) },
      { path: 'users', canActivate: [permissionGuard], data: { permission: 'users.manage', breadcrumb: 'Users & Roles' }, loadComponent: () => import('./features/users-roles/users-roles.component').then(m => m.UsersRolesComponent) },
      { path: 'settings', canActivate: [permissionGuard], data: { permission: 'settings.manage', breadcrumb: 'Organization Settings' }, loadComponent: () => import('./features/settings/settings.component').then(m => m.SettingsComponent) },
      { path: 'notifications', loadComponent: () => import('./features/notifications/notifications.component').then(m => m.NotificationsComponent), data: { breadcrumb: 'Notifications' } }
    ]
  },
  { path: '**', redirectTo: '' }
];
