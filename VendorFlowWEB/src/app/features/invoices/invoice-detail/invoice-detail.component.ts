import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { InvoiceService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';
import { StatusBadgeComponent } from '../../../shared/status-badge/status-badge.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { AttachmentsPanelComponent } from '../../../shared/attachments-panel/attachments-panel.component';
import { ConfirmService } from '../../../shared/confirm-dialog/confirm-dialog.component';

/** The match screen: invoice against purchase order and goods receipt, with discrepancies and the actions to resolve them. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-invoice-detail',
  imports: [RouterLink, MoneyPipe, DateFormatPipe, StatusBadgeComponent, LoadingSpinnerComponent, AttachmentsPanelComponent],
  templateUrl: './invoice-detail.component.html',
  styleUrl: './invoice-detail.component.css'
})
export class InvoiceDetailComponent implements OnInit {
  auth = inject(AuthService);
  private service = inject(InvoiceService);
  private route = inject(ActivatedRoute);
  private toast = inject(ToastService);
  private confirm = inject(ConfirmService);

  id = this.route.snapshot.paramMap.get('id')!;
  inv: any = null;
  loading = true;

  get editable(): boolean { return this.inv && ['Registered', 'NeedsReview', 'Matched', 'Disputed'].includes(this.inv.status); }
  get absVariance(): number { return Math.abs(this.inv?.varianceAmount ?? 0); }
  round2(value: number | null): string { return value === null ? '—' : (Math.round(value * 100) / 100).toString(); }
  get overTolerance(): boolean { return Math.abs(this.inv?.variancePct ?? 0) > (this.inv?.tolerancePct ?? 0); }

  ngOnInit(): void { this.reload(); }

  reload(): void {
    this.service.get(this.id).subscribe({
      next: i => { this.inv = i; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  private run(call: any, message: string): void {
    call.subscribe({ next: (i: any) => { this.inv = i; this.toast.success(message); }, error: (e: any) => { this.toast.error(e); this.reload(); } });
  }

  rematch(): void { this.run(this.service.rematch(this.id), 'Matched again'); }
  reconcile(): void { this.run(this.service.reconcile(this.id), 'Invoice reconciled and approved for payment'); }

  dispute(): void {
    this.confirm.ask({ title: 'Raise discrepancy', commentLabel: 'Describe the problem', commentRequired: true, confirmText: 'Raise discrepancy', danger: true })
      .subscribe(msg => this.run(this.service.dispute(this.id, msg), 'Discrepancy raised'));
  }

  cancel(): void {
    this.confirm.ask({ title: 'Cancel invoice', commentLabel: 'Reason', commentRequired: true, confirmText: 'Cancel invoice', danger: true })
      .subscribe(c => this.run(this.service.cancel(this.id, c), 'Invoice cancelled'));
  }
}
