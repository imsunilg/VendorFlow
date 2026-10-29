import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute } from '@angular/router';
import { RfqService } from '../../../core/services/data.services';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';
import { ToastService } from '../../../core/services/toast.service';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { QuotationFormComponent } from '../quotation-form/quotation-form.component';

/**
 * Public page opened from the private link sent to a vendor. No login: the secret token in the address is the credential.
 * The vendor sees only this RFQ, its own quotation and its own questions.
 */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-vendor-portal',
  imports: [FormsModule, MoneyPipe, DateFormatPipe, LoadingSpinnerComponent, QuotationFormComponent],
  templateUrl: './vendor-portal.component.html',
  styleUrl: './vendor-portal.component.css'
})
export class VendorPortalComponent implements OnInit {
  private rfqs = inject(RfqService);
  private route = inject(ActivatedRoute);
  private toast = inject(ToastService);

  token = this.route.snapshot.paramMap.get('token')!;
  data: any = null;
  loading = true;
  invalidLink = false;
  saving = false;
  question = '';
  editing = false;

  ngOnInit(): void { this.load(); }

  load(): void {
    this.rfqs.portal(this.token).subscribe({
      next: d => { this.data = d; this.loading = false; this.editing = !d.quotation; },
      error: () => { this.loading = false; this.invalidLink = true; }
    });
  }

  submit(quote: any): void {
    this.saving = true;
    this.rfqs.portalQuote(this.token, quote).subscribe({
      next: d => { this.data = d; this.saving = false; this.editing = false; this.toast.success('Quotation submitted. You can update it until the deadline.'); },
      error: e => { this.saving = false; this.toast.error(e); }
    });
  }

  ask(): void {
    if (!this.question.trim()) return;
    this.rfqs.portalAsk(this.token, this.question).subscribe({
      next: d => { this.data = d; this.question = ''; this.toast.success('Question sent'); },
      error: e => this.toast.error(e)
    });
  }

  decline(): void {
    this.rfqs.portalDecline(this.token).subscribe({ next: d => { this.data = d; this.toast.success('You declined this request.'); }, error: e => this.toast.error(e) });
  }
}
