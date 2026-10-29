import { ChangeDetectionStrategy, Component, EventEmitter, Input, OnChanges, Output, inject } from '@angular/core';
import { FormArray, FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { MoneyPipe } from '../../../core/pipes/money.pipe';

/**
 * Price entry for one vendor: a price, discount % and tax % per RFQ item plus shipping, delivery, terms and warranty.
 * Used by buyers (typing in a quotation received by phone) and by vendors in the portal.
 * The totals shown here follow the same rounding rule as the API, which recalculates them on save.
 */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-quotation-form',
  imports: [ReactiveFormsModule, MoneyPipe],
  templateUrl: './quotation-form.component.html',
  styleUrl: './quotation-form.component.css'
})
export class QuotationFormComponent implements OnChanges {
  private fb = inject(FormBuilder);

  @Input() items: any[] = [];              // RFQ items {id, lineNo, description, unit, quantity}
  @Input() initial: any = null;            // an existing quotation to edit
  @Input() busy = false;
  @Input() submitText = 'Submit quotation';
  @Output() submitQuote = new EventEmitter<any>();

  form = this.fb.nonNullable.group({
    shipping: [0, [Validators.min(0)]],
    deliveryDays: [7, [Validators.min(0)]],
    paymentTerms: [''],
    warrantyMonths: [12, [Validators.min(0)]],
    notes: [''],
    lines: this.fb.array([])
  });

  get lines(): FormArray { return this.form.controls.lines; }

  // Builds one row per RFQ item (and fills it from an earlier quotation if there is one).
  ngOnChanges(): void {
    this.lines.clear();
    for (const item of this.items) {
      const old = this.initial?.items?.find((x: any) => x.rfqItemId === item.id);
      this.lines.push(this.fb.nonNullable.group({
        rfqItemId: [item.id],
        unitPrice: [old?.unitPrice ?? 0, [Validators.required, Validators.min(0)]],
        discountPercent: [old?.discountPercent ?? 0, [Validators.min(0), Validators.max(100)]],
        taxPercent: [old?.taxPercent ?? 18, [Validators.min(0), Validators.max(100)]]
      }));
    }
    if (this.initial) {
      this.form.patchValue({
        shipping: this.initial.shipping ?? 0, deliveryDays: this.initial.deliveryDays ?? 0, paymentTerms: this.initial.paymentTerms ?? '',
        warrantyMonths: this.initial.warrantyMonths ?? 0, notes: this.initial.notes ?? ''
      });
    }
  }

  private round(x: number): number { return Math.round((x + Number.EPSILON) * 100) / 100; }

  // gross = qty x price; discount; net; tax; line total (same steps as the API).
  calc(index: number): { net: number; tax: number; total: number } {
    const row: any = this.lines.at(index).value;
    const qty = Number(this.items[index]?.quantity ?? 0);
    const gross = this.round(qty * this.round(Number(row.unitPrice) || 0));
    const net = gross - this.round(gross * (Number(row.discountPercent) || 0) / 100);
    const tax = this.round(net * (Number(row.taxPercent) || 0) / 100);
    return { net, tax, total: net + tax };
  }

  get landed(): number {
    let sum = Number(this.form.value.shipping) || 0;
    for (let i = 0; i < this.lines.length; i++) sum += this.calc(i).total;
    return this.round(sum);
  }

  send(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    const v = this.form.getRawValue();
    this.submitQuote.emit({
      shipping: v.shipping, deliveryDays: v.deliveryDays, paymentTerms: v.paymentTerms, warrantyMonths: v.warrantyMonths, notes: v.notes,
      items: v.lines
    });
  }
}
