import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormArray, FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { PurchaseOrderService, RequisitionService, VendorService } from '../../../core/services/data.services';
import { SettingsService } from '../../../core/services/settings.service';
import { ToastService } from '../../../core/services/toast.service';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { LabelsPipe } from '../../../core/pipes/labels.pipe';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';

/** Create a PO (direct or from an approved requisition) or edit a draft PO. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-po-form',
  imports: [ReactiveFormsModule, RouterLink, MoneyPipe, LabelsPipe, PageHeaderComponent, LoadingSpinnerComponent],
  templateUrl: './po-form.component.html',
  styleUrl: './po-form.component.css'
})
export class PoFormComponent implements OnInit {
  private fb = inject(FormBuilder);
  private pos = inject(PurchaseOrderService);
  private vendorService = inject(VendorService);
  private requisitions = inject(RequisitionService);
  private settings = inject(SettingsService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);

  id = this.route.snapshot.paramMap.get('id');
  requisitionId = this.route.snapshot.queryParamMap.get('requisitionId');
  requisition: any = null;
  vendors: any[] = [];
  rowVersion: number | null = null;
  loading = false;
  saving = false;

  form = this.fb.nonNullable.group({
    vendorId: ['', Validators.required],
    expectedDelivery: [''],
    shipping: [0, Validators.min(0)],
    notes: [''],
    items: this.fb.array([this.newItem()])
  });

  get items(): FormArray { return this.form.controls.items; }
  get fromRequisition(): boolean { return !!this.requisitionId && !this.id; }

  newItem(item?: any) {
    return this.fb.nonNullable.group({
      id: [item?.id ?? ''],
      description: [item?.description ?? '', Validators.required],
      unit: [item?.unit ?? 'Nos'],
      quantity: [item?.quantity ?? 1, [Validators.required, Validators.min(0.001)]],
      rate: [item?.rate ?? 0, [Validators.required, Validators.min(0)]],
      discountPercent: [item?.discountPercent ?? 0, [Validators.min(0), Validators.max(100)]],
      taxPercent: [item?.taxPercent ?? Number(this.settings.settings.taxSettings?.defaultTaxPercent ?? 18), [Validators.min(0), Validators.max(100)]]
    });
  }

  private round(x: number): number { return Math.round((x + Number.EPSILON) * 100) / 100; }

  // Same rule as the API: gross, discount, net, tax, total per line.
  line(index: number): { net: number; tax: number; total: number } {
    const r: any = this.items.at(index).value;
    const gross = this.round((r.quantity || 0) * this.round(r.rate || 0));
    const net = gross - this.round(gross * (r.discountPercent || 0) / 100);
    const tax = this.round(net * (r.taxPercent || 0) / 100);
    return { net, tax, total: net + tax };
  }

  get subtotal(): number { return this.items.controls.reduce((s, _c, i) => s + this.line(i).net, 0); }
  get taxTotal(): number { return this.items.controls.reduce((s, _c, i) => s + this.line(i).tax, 0); }
  get grandTotal(): number { return this.subtotal + this.taxTotal + (Number(this.form.value.shipping) || 0); }

  ngOnInit(): void {
    this.vendorService.list({ status: 'Approved', pageSize: 200, sortBy: 'name' }).subscribe(r => this.vendors = r.items);
    if (this.id) {
      this.loading = true;
      this.pos.get(this.id).subscribe({
        next: po => {
          this.rowVersion = po.rowVersion;
          this.form.patchValue({ vendorId: po.vendorId, expectedDelivery: (po.expectedDelivery ?? '').substring(0, 10), shipping: po.shipping, notes: po.notes ?? '' });
          this.items.clear();
          for (const i of po.items) this.items.push(this.newItem(i));
          this.loading = false;
        },
        error: e => { this.loading = false; this.toast.error(e); }
      });
    } else if (this.requisitionId) {
      this.requisitions.get(this.requisitionId).subscribe(r => {
        this.requisition = r;
        this.items.clear();
        for (const i of r.items) this.items.push(this.newItem({ description: i.description, unit: i.unit, quantity: i.quantity, rate: i.estUnitPrice }));
        this.form.patchValue({ expectedDelivery: (r.requiredDate ?? '').substring(0, 10) });
      });
    }
  }

  addLine(): void { this.items.push(this.newItem()); }
  removeLine(i: number): void { if (this.items.length > 1) this.items.removeAt(i); }

  save(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    this.saving = true;
    const v = this.form.getRawValue();
    const items = v.items.map((i: any) => ({ ...i, id: i.id || undefined }));
    let call;
    if (this.id) call = this.pos.update(this.id, { ...v, items, rowVersion: this.rowVersion ?? undefined, expectedDelivery: v.expectedDelivery || undefined });
    else if (this.requisitionId) call = this.pos.fromRequisition(this.requisitionId, { vendorId: v.vendorId, expectedDelivery: v.expectedDelivery || undefined, shipping: v.shipping, notes: v.notes });
    else call = this.pos.create({ ...v, items, expectedDelivery: v.expectedDelivery || undefined });
    call.subscribe({
      next: po => { this.toast.success('Purchase order saved'); this.router.navigate(['/purchase-orders', po.id]); },
      error: e => { this.saving = false; this.toast.error(e); }
    });
  }

  invalid(name: string): boolean { const c = this.form.get(name); return !!c && c.touched && c.invalid; }
}
