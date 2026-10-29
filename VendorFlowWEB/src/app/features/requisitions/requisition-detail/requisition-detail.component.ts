import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { RequisitionService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';
import { StatusBadgeComponent } from '../../../shared/status-badge/status-badge.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { ApprovalTimelineComponent } from '../../../shared/approval-timeline/approval-timeline.component';
import { AttachmentsPanelComponent } from '../../../shared/attachments-panel/attachments-panel.component';
import { ConfirmService } from '../../../shared/confirm-dialog/confirm-dialog.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-requisition-detail',
  imports: [RouterLink, MoneyPipe, DateFormatPipe, StatusBadgeComponent, LoadingSpinnerComponent, ApprovalTimelineComponent, AttachmentsPanelComponent],
  templateUrl: './requisition-detail.component.html',
  styleUrl: './requisition-detail.component.css'
})
export class RequisitionDetailComponent implements OnInit {
  auth = inject(AuthService);
  private service = inject(RequisitionService);
  private route = inject(ActivatedRoute);
  private toast = inject(ToastService);
  private confirm = inject(ConfirmService);

  id = this.route.snapshot.paramMap.get('id')!;
  req: any = null;
  loading = true;

  get isRequester(): boolean { return this.req?.requesterId === this.auth.user?.userId; }
  get editable(): boolean { return this.isRequester && ['Draft', 'ReturnedForModification'].includes(this.req?.status); }

  ngOnInit(): void { this.reload(); }

  reload(): void {
    this.service.get(this.id).subscribe({
      next: r => { this.req = r; this.loading = false; },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  submit(): void {
    this.service.submit(this.id).subscribe({ next: r => { this.req = r; this.toast.success('Submitted for approval'); }, error: e => this.toast.error(e) });
  }

  cancel(): void {
    this.confirm.ask({ title: 'Cancel requisition', message: 'This cannot be undone.', commentLabel: 'Reason', commentRequired: true, confirmText: 'Cancel requisition', danger: true })
      .subscribe(comment => this.service.cancel(this.id, comment).subscribe({ next: r => { this.req = r; this.toast.success('Cancelled'); }, error: e => this.toast.error(e) }));
  }
}
