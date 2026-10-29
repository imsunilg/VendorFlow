import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { RfqService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { QuotationFormComponent } from '../quotation-form/quotation-form.component';

/** Buyer types in a quotation on behalf of a vendor (received by phone or on paper). */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-quotation-entry',
  imports: [RouterLink, PageHeaderComponent, LoadingSpinnerComponent, QuotationFormComponent],
  templateUrl: './quotation-entry.component.html',
  styleUrl: './quotation-entry.component.css'
})
export class QuotationEntryComponent implements OnInit {
  private rfqs = inject(RfqService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);

  rfqId = this.route.snapshot.paramMap.get('id')!;
  vendorId = this.route.snapshot.paramMap.get('vendorId')!;
  rfq: any = null;
  vendorName = '';
  saving = false;

  ngOnInit(): void {
    this.rfqs.get(this.rfqId).subscribe({
      next: r => { this.rfq = r; this.vendorName = r.vendors.find((v: any) => v.vendorId === this.vendorId)?.vendorName ?? ''; },
      error: e => this.toast.error(e)
    });
  }

  save(quote: any): void {
    this.saving = true;
    this.rfqs.enterQuotation(this.rfqId, this.vendorId, quote).subscribe({
      next: () => { this.toast.success('Quotation saved'); this.router.navigate(['/rfqs', this.rfqId]); },
      error: e => { this.saving = false; this.toast.error(e); }
    });
  }
}
