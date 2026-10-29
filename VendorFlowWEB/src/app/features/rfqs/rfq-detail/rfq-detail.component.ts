import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { RfqService, PurchaseOrderService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { LabelsPipe } from '../../../core/pipes/labels.pipe';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';
import { StatusBadgeComponent } from '../../../shared/status-badge/status-badge.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { AttachmentsPanelComponent } from '../../../shared/attachments-panel/attachments-panel.component';
import { ConfirmService } from '../../../shared/confirm-dialog/confirm-dialog.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-rfq-detail',
  imports: [FormsModule, RouterLink, MoneyPipe, LabelsPipe, DateFormatPipe, StatusBadgeComponent, LoadingSpinnerComponent, AttachmentsPanelComponent],
  templateUrl: './rfq-detail.component.html',
  styleUrl: './rfq-detail.component.css'
})
export class RfqDetailComponent implements OnInit {
  auth = inject(AuthService);
  private rfqs = inject(RfqService);
  private pos = inject(PurchaseOrderService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);
  private confirm = inject(ConfirmService);

  id = this.route.snapshot.paramMap.get('id')!;
  rfq: any = null;
  loading = true;
  links: { vendorName: string; link: string }[] = [];      // invitation links, shown once after opening
  answers: Record<string, string> = {};
  newDeadline = '';

  get canManage(): boolean { return this.auth.has('rfqs.manage'); }

  ngOnInit(): void { this.reload(); }

  reload(): void {
    this.rfqs.get(this.id).subscribe({
      next: r => { this.rfq = r; this.loading = false; },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  // Opening creates a private link per vendor. The links are shown only now (only their hashes are stored).
  open(): void {
    this.rfqs.open(this.id).subscribe({
      next: r => { this.rfq = r.rfq; this.links = r.invitations; this.toast.success('RFQ opened'); },
      error: e => this.toast.error(e)
    });
  }

  invite(vendorId: string, name: string): void {
    this.rfqs.invite(this.id, vendorId).subscribe({
      next: r => { this.rfq = r.rfq; this.links = [{ vendorName: name, link: r.link }]; this.toast.success('New link created'); },
      error: e => this.toast.error(e)
    });
  }

  copy(link: string): void { navigator.clipboard?.writeText(link); this.toast.success('Link copied'); }

  close(): void { this.run(this.rfqs.close(this.id), 'RFQ closed'); }
  reopen(): void {
    if (!this.newDeadline) { this.toast.error({ error: { detail: 'Choose a new deadline first.' } }); return; }
    this.run(this.rfqs.reopen(this.id, new Date(this.newDeadline).toISOString()), 'RFQ re-opened');
  }
  remind(): void { this.rfqs.reminders(this.id).subscribe({ next: r => this.toast.success(r.queued + ' reminder(s) queued'), error: e => this.toast.error(e) }); }

  cancel(): void {
    this.confirm.ask({ title: 'Cancel RFQ', commentLabel: 'Reason', commentRequired: true, confirmText: 'Cancel RFQ', danger: true })
      .subscribe(comment => this.run(this.rfqs.cancel(this.id, comment), 'RFQ cancelled'));
  }

  answer(c: any): void {
    const text = (this.answers[c.id] ?? '').trim();
    if (!text) return;
    this.run(this.rfqs.answer(c.id, text), 'Answer sent');
  }

  createPo(): void {
    this.pos.fromRfq(this.id).subscribe({ next: po => { this.toast.success('Purchase order created'); this.router.navigate(['/purchase-orders', po.id]); }, error: e => this.toast.error(e) });
  }

  private run(call: any, message: string): void {
    call.subscribe({ next: (r: any) => { this.rfq = r; this.toast.success(message); }, error: (e: any) => this.toast.error(e) });
  }
}
