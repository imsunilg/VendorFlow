import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { PurchaseOrderService, RfqService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { LabelsPipe } from '../../../core/pipes/labels.pipe';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { saveBlob } from '../../../core/services/download.util';

/** Side-by-side comparison of all quotations of an RFQ with the best value in each row highlighted. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-quotation-compare',
  imports: [FormsModule, RouterLink, MoneyPipe, LabelsPipe, PageHeaderComponent, LoadingSpinnerComponent],
  templateUrl: './quotation-compare.component.html',
  styleUrl: './quotation-compare.component.css'
})
export class QuotationCompareComponent implements OnInit {
  auth = inject(AuthService);
  private rfqs = inject(RfqService);
  private pos = inject(PurchaseOrderService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);

  rfqId = this.route.snapshot.paramMap.get('rfqId')!;
  data: any = null;
  loading = true;
  vendorId = '';
  justification = '';

  get quotes(): any[] { return this.data?.quotes ?? []; }
  get lowest(): any { return this.quotes.find((q: any) => q.isLowestPrice); }
  get recommended(): any { return this.data?.recommendation; }

  ngOnInit(): void { this.load(); }

  load(): void {
    this.rfqs.compare(this.rfqId).subscribe({
      next: d => { this.data = d; this.loading = false; this.vendorId = d.recommendation?.vendorId ?? ''; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  // Price, discount and tax of one RFQ item for one vendor.
  itemOf(quote: any, itemId: string): any { return quote.items.find((i: any) => i.rfqItemId === itemId); }

  recommend(): void {
    if (!this.vendorId) { this.toast.error({ error: { detail: 'Choose the vendor you recommend.' } }); return; }
    if (this.justification.trim().length < 10) { this.toast.error({ error: { detail: 'Explain your recommendation (at least 10 characters).' } }); return; }
    this.rfqs.recommend(this.rfqId, this.vendorId, this.justification).subscribe({
      next: d => { this.data = d; this.toast.success('Recommendation recorded'); },
      error: e => this.toast.error(e)
    });
  }

  createPo(): void {
    this.pos.fromRfq(this.rfqId).subscribe({ next: po => this.router.navigate(['/purchase-orders', po.id]), error: e => this.toast.error(e) });
  }

  // Exports the comparison as a CSV file.
  exportCsv(): void {
    const header = ['Criteria', ...this.quotes.map((q: any) => q.vendorName)];
    const rows = [
      ['Total landed cost', ...this.quotes.map((q: any) => q.totalLanded)],
      ['Delivery days', ...this.quotes.map((q: any) => q.deliveryDays ?? '')],
      ['Payment terms', ...this.quotes.map((q: any) => q.paymentTerms ?? '')],
      ['Warranty months', ...this.quotes.map((q: any) => q.warrantyMonths ?? '')]
    ];
    const csv = [header, ...rows].map(r => r.map(c => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\n');
    saveBlob(new Blob([csv], { type: 'text/csv' }), 'quotation-comparison.csv');
  }
}
