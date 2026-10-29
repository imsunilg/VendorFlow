import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { VendorService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { openBlob, saveBlob } from '../../../core/services/download.util';
import { LabelsPipe } from '../../../core/pipes/labels.pipe';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';
import { StatusBadgeComponent } from '../../../shared/status-badge/status-badge.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { ConfirmService } from '../../../shared/confirm-dialog/confirm-dialog.component';
import { FileUploadComponent } from '../../../shared/file-upload/file-upload.component';
import { EmptyStateComponent } from '../../../shared/empty-state/empty-state.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-vendor-detail',
  imports: [ReactiveFormsModule, RouterLink, LabelsPipe, DateFormatPipe, StatusBadgeComponent, LoadingSpinnerComponent, FileUploadComponent, EmptyStateComponent],
  templateUrl: './vendor-detail.component.html',
  styleUrl: './vendor-detail.component.css'
})
export class VendorDetailComponent implements OnInit {
  auth = inject(AuthService);
  private vendors = inject(VendorService);
  private route = inject(ActivatedRoute);
  private fb = inject(FormBuilder);
  private toast = inject(ToastService);
  private confirm = inject(ConfirmService);

  id = this.route.snapshot.paramMap.get('id')!;
  vendor: any = null;
  loading = true;
  tab = 'profile';

  performance: any = null;
  history: any[] = [];
  bank: any = null;
  bankLoaded = false;
  newFile: File | null = null;

  contactForm = this.fb.nonNullable.group({ name: ['', Validators.required], designation: [''], email: ['', Validators.email], phone: [''], isPrimary: [false] });
  addressForm = this.fb.nonNullable.group({ addressType: ['Registered'], line1: ['', Validators.required], line2: [''], city: [''], state: [''], postalCode: [''] });
  documentForm = this.fb.nonNullable.group({ docType: ['', Validators.required], docNumber: [''], expiryDate: [''] });
  bankForm = this.fb.nonNullable.group({
    accountName: ['', Validators.required],
    accountNumber: ['', [Validators.required, Validators.pattern(/^[0-9]{6,20}$/)]],
    ifsc: ['', [Validators.required, Validators.pattern(/^[A-Za-z]{4}0[A-Za-z0-9]{6}$/)]],
    bankName: [''], branch: ['']
  });

  get editable(): boolean { return this.vendor && this.vendor.status !== 'PendingApproval' && this.auth.has('vendors.edit'); }
  get primaryContact(): any { return this.vendor?.contacts?.[0]; }
  get initials(): string { return (this.vendor?.name ?? '').split(' ').map((w: string) => w[0]).slice(0, 2).join('').toUpperCase(); }

  ngOnInit(): void { this.reload(); }

  reload(): void {
    this.vendors.get(this.id).subscribe({
      next: v => { this.vendor = v; this.loading = false; },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  // Opens a tab; heavier tabs load their data the first time they are shown.
  open(tab: string): void {
    this.tab = tab;
    if (tab === 'performance' && !this.performance) this.vendors.performance(this.id).subscribe(p => this.performance = p);
    if (tab === 'history') this.vendors.history(this.id).subscribe(h => this.history = h);
  }

  // ---- status actions (submit, approve, reject, suspend, reactivate)
  act(action: string, title: string, needsReason: boolean): void {
    if (!needsReason && action !== 'approve') {
      this.vendors.transition(this.id, action).subscribe({ next: v => { this.vendor = v; this.toast.success('Done'); }, error: e => this.toast.error(e) });
      return;
    }
    this.confirm.ask({ title, commentLabel: needsReason ? 'Reason' : 'Comment (optional)', commentRequired: needsReason, confirmText: title, danger: needsReason })
      .subscribe(comment => this.vendors.transition(this.id, action, comment).subscribe({
        next: v => { this.vendor = v; this.toast.success('Done'); },
        error: e => this.toast.error(e)
      }));
  }

  // ---- contacts and addresses
  addContact(): void {
    if (this.contactForm.invalid) { this.contactForm.markAllAsTouched(); return; }
    this.vendors.saveContact(this.id, this.contactForm.getRawValue()).subscribe({
      next: v => { this.vendor = v; this.contactForm.reset({ isPrimary: false }); },
      error: e => this.toast.error(e)
    });
  }
  removeContact(c: any): void { this.vendors.deleteContact(this.id, c.id).subscribe({ next: v => this.vendor = v, error: e => this.toast.error(e) }); }

  addAddress(): void {
    if (this.addressForm.invalid) { this.addressForm.markAllAsTouched(); return; }
    this.vendors.saveAddress(this.id, this.addressForm.getRawValue()).subscribe({
      next: v => { this.vendor = v; this.addressForm.reset({ addressType: 'Registered' }); },
      error: e => this.toast.error(e)
    });
  }
  removeAddress(a: any): void { this.vendors.deleteAddress(this.id, a.id).subscribe({ next: v => this.vendor = v, error: e => this.toast.error(e) }); }

  // ---- documents (multipart upload, file optional)
  addDocument(): void {
    if (this.documentForm.invalid) { this.documentForm.markAllAsTouched(); return; }
    const value = this.documentForm.getRawValue();
    const form = new FormData();
    form.append('DocType', value.docType);
    if (value.docNumber) form.append('DocNumber', value.docNumber);
    if (value.expiryDate) form.append('ExpiryDate', value.expiryDate);
    if (this.newFile) form.append('File', this.newFile);
    this.vendors.saveDocument(this.id, form).subscribe({
      next: v => { this.vendor = v; this.documentForm.reset(); this.newFile = null; this.toast.success('Document saved'); },
      error: e => this.toast.error(e)
    });
  }
  removeDocument(d: any): void { this.vendors.deleteDocument(this.id, d.id).subscribe({ next: v => this.vendor = v, error: e => this.toast.error(e) }); }
  viewDocument(d: any): void { this.vendors.documentFile(this.id, d.id).subscribe({ next: b => openBlob(b), error: e => this.toast.error(e) }); }

  // ---- bank details: reading is audited, so they are loaded only when the user asks
  revealBank(): void {
    this.vendors.bank(this.id).subscribe({
      next: b => {
        this.bank = b; this.bankLoaded = true;
        if (b) this.bankForm.patchValue({ accountName: b.accountName, accountNumber: b.accountNumber, ifsc: b.ifsc, bankName: b.bankName ?? '', branch: b.branch ?? '' });
      },
      error: e => this.toast.error(e)
    });
  }
  saveBank(): void {
    if (this.bankForm.invalid) { this.bankForm.markAllAsTouched(); return; }
    this.vendors.saveBank(this.id, this.bankForm.getRawValue()).subscribe({
      next: () => { this.toast.success('Bank details saved'); this.revealBank(); this.reload(); },
      error: e => this.toast.error(e)
    });
  }

  masked(n: string): string { return n ? '•••• ' + n.slice(-4) : ''; }
  money(value: number | null): string { return value === null || value === undefined ? '—' : value + '%'; }
}
