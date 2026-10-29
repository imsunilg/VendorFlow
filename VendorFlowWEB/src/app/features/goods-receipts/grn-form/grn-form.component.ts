import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormArray, FormBuilder, ReactiveFormsModule } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { GoodsReceiptService, PurchaseOrderService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';

/** Record received goods against a purchase order: received = accepted + rejected, damaged is part of rejected. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-grn-form',
  imports: [ReactiveFormsModule, RouterLink, PageHeaderComponent, LoadingSpinnerComponent],
  templateUrl: './grn-form.component.html',
  styleUrl: './grn-form.component.css'
})
export class GrnFormComponent implements OnInit {
  private fb = inject(FormBuilder);
  private pos = inject(PurchaseOrderService);
  private grns = inject(GoodsReceiptService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);

  poId = this.route.snapshot.paramMap.get('poId')!;
  po: any = null;
  loading = true;
  saving = false;
  problems: string[] = [];
  today = new Date().toISOString().substring(0, 10);

  form = this.fb.nonNullable.group({
    receivedOn: [this.today],
    warehouse: [''],
    deliveryChallan: [''],
    vehicleNo: [''],
    receivedBy: [''],
    inspectionNotes: [''],
    lines: this.fb.array([])
  });

  get lines(): FormArray { return this.form.controls.lines; }

  ngOnInit(): void {
    this.pos.get(this.poId).subscribe({
      next: po => {
        this.po = po;
        for (const item of po.items) {
          this.lines.push(this.fb.nonNullable.group({ poItemId: [item.id], receivedQty: [0], acceptedQty: [0], rejectedQty: [0], damagedQty: [0] }));
        }
        this.loading = false;
      },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  // Typing the received and rejected quantity fills the accepted quantity automatically.
  autoAccept(i: number): void {
    const g = this.lines.at(i);
    const received = Number(g.value.receivedQty) || 0;
    const rejected = Number(g.value.rejectedQty) || 0;
    g.patchValue({ acceptedQty: Math.max(received - rejected, 0) });
  }

  // Same rules as the API, so the user sees the problem before sending.
  validate(): string[] {
    const list: string[] = [];
    this.lines.controls.forEach((g, i) => {
      const v: any = g.value;
      const item = this.po.items[i];
      if (!v.receivedQty && !v.acceptedQty && !v.rejectedQty) return;
      if (Number(v.acceptedQty) + Number(v.rejectedQty) !== Number(v.receivedQty)) list.push(`Line ${item.lineNo}: accepted + rejected must equal received.`);
      if (Number(v.damagedQty) > Number(v.rejectedQty)) list.push(`Line ${item.lineNo}: damaged cannot exceed rejected.`);
      if (Number(v.receivedQty) > item.pendingQty) list.push(`Line ${item.lineNo}: receiving ${v.receivedQty} is more than the pending ${item.pendingQty}.`);
    });
    return list;
  }

  post(): void {
    this.problems = this.validate();
    const v = this.form.getRawValue();
    const items = v.lines.filter((l: any) => l.receivedQty > 0 || l.acceptedQty > 0 || l.rejectedQty > 0);
    if (items.length === 0) this.problems.push('Enter a received quantity on at least one line.');
    if (this.problems.length) return;

    this.saving = true;
    this.grns.post(this.poId, { receivedOn: v.receivedOn, warehouse: v.warehouse, deliveryChallan: v.deliveryChallan, vehicleNo: v.vehicleNo,
      receivedBy: v.receivedBy, inspectionNotes: v.inspectionNotes, items }).subscribe({
      next: g => { this.toast.success('Receipt posted'); this.router.navigate(['/goods-receipts', g.id]); },
      error: e => { this.saving = false; this.toast.error(e); }
    });
  }
}
