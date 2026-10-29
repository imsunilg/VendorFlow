import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormArray, FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { InvoiceService, PurchaseOrderService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';

/** Register an invoice against a purchase order (or correct one that failed matching). */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-invoice-form',
  imports: [ReactiveFormsModule, RouterLink, PageHeaderComponent, LoadingSpinnerComponent],
  templateUrl: './invoice-form.component.html',
  styleUrl: './invoice-form.component.css'
})
export class InvoiceFormComponent implements OnInit {
  private fb = inject(FormBuilder);
  private invoices = inject(InvoiceService);
  private pos = inject(PurchaseOrderService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);

  id = this.route.snapshot.paramMap.get('id');
  poOptions: any[] = [];
  po: any = null;
  rowVersion: number | null = null;
  loading = false;
  saving = false;
  today = new Date().toISOString().substring(0, 10);

  form = this.fb.nonNullable.group({
    poId: ['', Validators.required],
    invoiceNumber: ['', [Validators.required, Validators.maxLength(60)]],
    invoiceDate: [this.today, Validators.required],
    dueDate: [''],
    matchType: ['ThreeWay'],
    notes: [''],
    lines: this.fb.array([])
  });

  get lines(): FormArray { return this.form.controls.lines; }

  ngOnInit(): void {
    this.pos.list({ pageSize: 100, sortBy: 'created_at', sortDir: 'desc' }).subscribe(r =>
      this.poOptions = r.items.filter((p: any) => ['Issued', 'PartiallyReceived', 'FullyReceived', 'Closed', 'OnHold'].includes(p.status)));

    if (this.id) {
      this.loading = true;
      this.invoices.get(this.id).subscribe({
        next: inv => {
          this.rowVersion = inv.rowVersion;
          this.form.patchValue({ poId: inv.poId, invoiceNumber: inv.invoiceNumber, invoiceDate: inv.invoiceDate.substring(0, 10), dueDate: inv.dueDate.substring(0, 10), matchType: inv.matchType, notes: inv.notes ?? '' });
          this.form.controls.poId.disable();
          this.loadPo(inv.poId, inv.lines);
        },
        error: e => { this.loading = false; this.toast.error(e); }
      });
    } else {
      const poId = this.route.snapshot.queryParamMap.get('poId');
      if (poId) { this.form.patchValue({ poId }); this.loadPo(poId); }
    }
  }

  onPoChange(poId: string): void { this.form.patchValue({ poId }); this.loadPo(poId); }

  // Builds one row per PO line. By default the quantity to invoice is what was received and not yet invoiced.
  loadPo(poId: string, existing?: any[]): void {
    if (!poId) { this.po = null; this.lines.clear(); return; }
    this.pos.get(poId).subscribe({
      next: po => {
        this.po = po;
        this.lines.clear();
        for (const item of po.items) {
          const old = existing?.find(l => l.poItemId === item.id);
          const suggested = Math.max(item.receivedQty - item.invoicedQty, 0);
          this.lines.push(this.fb.nonNullable.group({
            poItemId: [item.id],
            include: [old ? true : suggested > 0],
            quantity: [old?.invoiceQty ?? suggested, Validators.min(0)],
            rate: [old?.invoiceRate ?? item.rate],
            discountPercent: [old?.invoiceDiscountPercent ?? item.discountPercent],
            taxAmount: [old?.invoiceTax ?? null as number | null]
          }));
        }
        this.loading = false;
      },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  save(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    const v = this.form.getRawValue();
    const items = v.lines.filter((l: any) => l.include && Number(l.quantity) > 0).map((l: any) => ({
      poItemId: l.poItemId, quantity: Number(l.quantity), rate: Number(l.rate), discountPercent: Number(l.discountPercent),
      taxAmount: l.taxAmount === null || l.taxAmount === '' ? undefined : Number(l.taxAmount)
    }));
    if (items.length === 0) { this.toast.error({ error: { detail: 'Select at least one line with a quantity.' } }); return; }

    this.saving = true;
    const body: any = { poId: this.id ? this.po.id : v.poId, invoiceNumber: v.invoiceNumber, invoiceDate: v.invoiceDate, dueDate: v.dueDate || undefined,
      matchType: v.matchType, notes: v.notes, items, rowVersion: this.rowVersion ?? undefined };
    const call = this.id ? this.invoices.update(this.id, body) : this.invoices.register(body);
    call.subscribe({
      next: inv => { this.toast.success(inv.status === 'Matched' ? 'Invoice matched' : 'Invoice needs review'); this.router.navigate(['/invoices', inv.id]); },
      error: e => { this.saving = false; this.toast.error(e); }
    });
  }

  invalid(name: string): boolean { const c = this.form.get(name); return !!c && c.touched && c.invalid; }
}
