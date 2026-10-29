import { ChangeDetectionStrategy, Component, OnDestroy, OnInit, inject } from '@angular/core';
import { FormArray, FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Subscription } from 'rxjs';
import { AdminService, ApprovalService } from '../../core/services/data.services';
import { SettingsService } from '../../core/services/settings.service';
import { ToastService } from '../../core/services/toast.service';
import { LabelsPipe } from '../../core/pipes/labels.pipe';
import { MoneyPipe } from '../../core/pipes/money.pipe';
import { PageHeaderComponent } from '../../shared/page-header/page-header.component';
import { FileUploadComponent } from '../../shared/file-upload/file-upload.component';
import { ConfirmService } from '../../shared/confirm-dialog/confirm-dialog.component';
import { ApiService } from '../../core/services/api.service';

const NUMBERING_LABELS: Record<string, string> = {
  requisition: 'Requisition', rfq: 'RFQ', po: 'Purchase order', grn: 'Goods receipt', payment: 'Payment', vendor: 'Vendor code'
};

/** Organization settings. Changing the app name or vendor words updates the whole app immediately (live preview). */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-settings',
  imports: [ReactiveFormsModule, LabelsPipe, MoneyPipe, PageHeaderComponent, FileUploadComponent],
  templateUrl: './settings.component.html',
  styleUrl: './settings.component.css'
})
export class SettingsComponent implements OnInit, OnDestroy {
  private fb = inject(FormBuilder);
  settings = inject(SettingsService);
  private admin = inject(AdminService);
  private approvals = inject(ApprovalService);
  private api = inject(ApiService);
  private toast = inject(ToastService);
  private confirm = inject(ConfirmService);

  tabs = [
    { key: 'branding', label: 'Branding & terminology' }, { key: 'numbering', label: 'Numbering' }, { key: 'tax', label: 'Tax & currency' },
    { key: 'approvals', label: 'Approval rules' }, { key: 'notifications', label: 'Notifications' }
  ];
  tab = 'branding';
  quickPicks = ['Vendor', 'Supplier', 'Contractor', 'Service Provider', 'Partner'];
  saved = true;
  private sub?: Subscription;

  form = this.fb.nonNullable.group({
    appDisplayName: ['', [Validators.required, Validators.maxLength(50)]],
    organizationName: ['', [Validators.required, Validators.maxLength(100)]],
    vendorLabelSingular: ['', [Validators.required, Validators.maxLength(50)]],
    vendorLabelPlural: ['', [Validators.required, Validators.maxLength(50)]],
    currency: ['INR', [Validators.required, Validators.pattern(/^[A-Z]{3}$/)]],
    timeZone: ['Asia/Kolkata', Validators.required],
    defaultTaxPercent: [18, [Validators.min(0), Validators.max(100)]],
    invoiceTolerancePct: [2, [Validators.min(0), Validators.max(100)]],
    allowSelfApproval: [false],
    emailNotifications: [false],
    numbering: this.fb.nonNullable.group({ requisition: [''], rfq: [''], po: [''], grn: [''], payment: [''], vendor: [''] })
  });

  // Approval rules
  rules: any[] = [];
  departments: any[] = [];
  deptManagers: any[] = [];
  users: any[] = [];
  roles: any[] = [];
  ruleForm = this.fb.nonNullable.group({
    id: [''], name: ['', Validators.required], entityType: ['requisition'], minAmount: [0], maxAmount: [null as number | null],
    departmentId: [''], priority: [0], steps: this.fb.array([this.newStep()])
  });
  showRule = false;

  get steps(): FormArray { return this.ruleForm.controls.steps; }
  get numberingKeys(): string[] { return Object.keys(NUMBERING_LABELS); }
  numberingLabel(key: string): string { return NUMBERING_LABELS[key]; }
  get sample(): string { return (this.form.value.numbering as any)?.po?.replace('{YYYY}', String(new Date().getFullYear())).replace(/\{0+\}/, '0001') ?? ''; }

  newStep(step?: any) { return this.fb.nonNullable.group({ name: [step?.name ?? ''], roleCode: [step?.roleCode ?? 'DepartmentManager', Validators.required] }); }

  ngOnInit(): void {
    const s = this.settings.settings;
    this.fillForm(s);
    // Every key press in the label fields updates the sidebar and pages instantly (not saved yet).
    this.sub = this.form.valueChanges.subscribe(v => {
      this.saved = false;
      this.settings.preview({ appDisplayName: v.appDisplayName || 'VendorFlow', vendorLabelSingular: v.vendorLabelSingular || 'Vendor', vendorLabelPlural: v.vendorLabelPlural || 'Vendors',
        organizationName: v.organizationName ?? '' });
    });
    this.settings.load().subscribe(fresh => { this.fillForm(fresh); this.saved = true; });
    this.admin.roles().subscribe(r => this.roles = r);
    this.admin.userLookup().subscribe(u => this.users = u.filter((x: any) => x.roles.includes('DepartmentManager')));
    this.loadRules();
  }

  // If the user leaves without saving, the saved labels come back.
  ngOnDestroy(): void {
    this.sub?.unsubscribe();
    if (!this.saved) this.settings.load().subscribe();
  }

  private fillForm(s: any): void {
    this.form.patchValue({
      appDisplayName: s.appDisplayName, organizationName: s.organizationName, vendorLabelSingular: s.vendorLabelSingular, vendorLabelPlural: s.vendorLabelPlural,
      currency: s.currency, timeZone: s.timeZone, defaultTaxPercent: Number(s.taxSettings?.defaultTaxPercent ?? 18), invoiceTolerancePct: Number(s.invoiceTolerancePct),
      allowSelfApproval: s.allowSelfApproval, emailNotifications: !!s.notificationPrefs?.email,
      numbering: { requisition: s.numbering?.requisition ?? '', rfq: s.numbering?.rfq ?? '', po: s.numbering?.po ?? '', grn: s.numbering?.grn ?? '', payment: s.numbering?.payment ?? '', vendor: s.numbering?.vendor ?? '' }
    }, { emitEvent: false });
  }

  pick(word: string): void {
    const plural = word === 'Vendor' ? 'Vendors' : word === 'Supplier' ? 'Suppliers' : word === 'Contractor' ? 'Contractors' : word === 'Service Provider' ? 'Service Providers' : 'Partners';
    this.form.patchValue({ vendorLabelSingular: word, vendorLabelPlural: plural });
  }

  save(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); this.toast.error({ error: { detail: 'Please correct the highlighted fields.' } }); return; }
    const v = this.form.getRawValue();
    this.settings.save({
      appDisplayName: v.appDisplayName, organizationName: v.organizationName, vendorLabelSingular: v.vendorLabelSingular, vendorLabelPlural: v.vendorLabelPlural,
      currency: v.currency, timeZone: v.timeZone, invoiceTolerancePct: v.invoiceTolerancePct, allowSelfApproval: v.allowSelfApproval,
      numbering: v.numbering, taxSettings: { defaultTaxPercent: v.defaultTaxPercent }, notificationPrefs: { email: v.emailNotifications }
    } as any).subscribe({
      next: () => { this.saved = true; this.toast.success('Settings saved'); },
      error: e => this.toast.error(e)
    });
  }

  uploadLogo(file: File): void {
    const form = new FormData();
    form.append('file', file);
    this.api.upload('/organizations/current/logo', form).subscribe({ next: () => this.toast.success('Logo uploaded'), error: e => this.toast.error(e) });
  }

  runChecks(): void {
    this.admin.runChecks().subscribe({ next: r => this.toast.success('Checks done. New notifications: ' + Object.values(r).reduce((a: any, b: any) => a + b, 0)), error: e => this.toast.error(e) });
  }

  // ---- approval rules and department managers
  loadRules(): void {
    this.approvals.rules().subscribe({ next: r => this.rules = r, error: () => {} });
    this.approvals.departments().subscribe({ next: d => this.deptManagers = d, error: () => {} });
    this.admin.departments().subscribe(d => this.departments = d);
  }

  newRule(): void {
    this.showRule = true;
    this.ruleForm.reset({ id: '', name: '', entityType: 'requisition', minAmount: 0, maxAmount: null, departmentId: '', priority: 0 });
    this.steps.clear(); this.steps.push(this.newStep());
  }

  editRule(rule: any): void {
    this.showRule = true;
    this.ruleForm.patchValue({ id: rule.id, name: rule.name, entityType: rule.entityType, minAmount: rule.minAmount, maxAmount: rule.maxAmount, departmentId: rule.departmentId ?? '', priority: rule.priority });
    this.steps.clear();
    for (const s of rule.steps) this.steps.push(this.newStep(s));
  }

  addStep(): void { this.steps.push(this.newStep()); }
  removeStep(i: number): void { if (this.steps.length > 1) this.steps.removeAt(i); }

  saveRule(): void {
    if (this.ruleForm.invalid) { this.ruleForm.markAllAsTouched(); return; }
    const v = this.ruleForm.getRawValue();
    this.approvals.saveRule({ ...v, id: v.id || undefined, departmentId: v.departmentId || undefined, maxAmount: v.maxAmount === null || (v.maxAmount as any) === '' ? undefined : v.maxAmount, active: true }).subscribe({
      next: list => { this.rules = list; this.showRule = false; this.toast.success('Rule saved'); },
      error: e => this.toast.error(e)
    });
  }

  deleteRule(rule: any): void {
    this.confirm.ask({ title: 'Delete rule', message: rule.name, confirmText: 'Delete', danger: true })
      .subscribe(() => this.approvals.deleteRule(rule.id).subscribe({ next: list => this.rules = list, error: e => this.toast.error(e) }));
  }

  setManager(departmentId: string, userId: string): void {
    this.approvals.setManager(departmentId, userId || null).subscribe({ next: d => { this.deptManagers = d; this.toast.success('Manager updated'); }, error: e => this.toast.error(e) });
  }

  roleName(code: string): string { return code.replace(/([a-z])([A-Z])/g, '$1 $2'); }
}
