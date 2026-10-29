import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { PurchaseOrderService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { openBlob, saveBlob } from '../../../core/services/download.util';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';
import { StatusBadgeComponent } from '../../../shared/status-badge/status-badge.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { ApprovalTimelineComponent } from '../../../shared/approval-timeline/approval-timeline.component';
import { AttachmentsPanelComponent } from '../../../shared/attachments-panel/attachments-panel.component';
import { ConfirmService } from '../../../shared/confirm-dialog/confirm-dialog.component';

// The steps shown in the status bar at the top of the page.
const STEPS = ['Draft', 'Approved', 'Issued', 'PartiallyReceived', 'FullyReceived', 'Closed'];

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-po-detail',
  imports: [RouterLink, MoneyPipe, DateFormatPipe, StatusBadgeComponent, LoadingSpinnerComponent, ApprovalTimelineComponent, AttachmentsPanelComponent],
  templateUrl: './po-detail.component.html',
  styleUrl: './po-detail.component.css'
})
export class PoDetailComponent implements OnInit {
  auth = inject(AuthService);
  private service = inject(PurchaseOrderService);
  private route = inject(ActivatedRoute);
  private toast = inject(ToastService);
  private confirm = inject(ConfirmService);

  id = this.route.snapshot.paramMap.get('id')!;
  po: any = null;
  loading = true;
  steps = STEPS;

  get status(): string { return this.po?.status; }
  get anyReceived(): boolean { return (this.po?.items ?? []).some((i: any) => i.receivedQty > 0); }

  // Position of the current status in the status bar (OnHold/Cancelled/Rejected stay at their last position).
  stepState(step: string): string {
    const current = STEPS.indexOf(this.status === 'PendingApproval' || this.status === 'Rejected' ? 'Draft' : this.status);
    const index = STEPS.indexOf(step);
    return index < current ? 'done' : index === current ? 'current' : 'waiting';
  }

  stepLabel(step: string): string {
    return { PartiallyReceived: 'Partially received', FullyReceived: 'Fully received' }[step] ?? step;
  }

  ngOnInit(): void { this.reload(); }

  reload(): void {
    this.service.get(this.id).subscribe({
      next: p => { this.po = p; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  // Runs a status action (submit, issue, hold, ...) that needs no reason.
  act(action: string, message: string): void {
    this.service.action(this.id, action).subscribe({ next: p => { this.po = p; this.toast.success(message); }, error: e => this.toast.error(e) });
  }

  // Actions that need a reason (hold, cancel, close a partly received PO).
  actWithReason(action: string, title: string, danger = false): void {
    this.confirm.ask({ title, commentLabel: 'Reason', commentRequired: true, confirmText: title, danger })
      .subscribe(comment => this.service.action(this.id, action, comment).subscribe({ next: p => { this.po = p; this.toast.success('Done'); }, error: e => this.toast.error(e) }));
  }

  revise(): void {
    this.confirm.ask({ title: 'Create a revision', message: 'The PO goes back to draft, must be approved again and issued as a new revision. Quantities already received are kept.',
      commentLabel: 'Reason for the revision', commentRequired: true, confirmText: 'Create revision' })
      .subscribe(reason => this.service.revise(this.id, reason).subscribe({ next: p => { this.po = p; this.toast.success('Revision created'); }, error: e => this.toast.error(e) }));
  }

  downloadPdf(): void {
    this.service.pdf(this.id).subscribe({ next: b => saveBlob(b, this.po.number + '.pdf'), error: e => this.toast.error(e) });
  }
  viewPdf(): void { this.service.pdf(this.id).subscribe({ next: b => openBlob(b), error: e => this.toast.error(e) }); }
}
