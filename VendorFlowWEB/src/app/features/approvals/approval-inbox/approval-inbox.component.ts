import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { ApprovalService, AdminService } from '../../../core/services/data.services';
import { AuthService } from '../../../core/services/auth.service';
import { ToastService } from '../../../core/services/toast.service';
import { entityRoute } from '../../../core/services/entity-route';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { StatusBadgeComponent } from '../../../shared/status-badge/status-badge.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { EmptyStateComponent } from '../../../shared/empty-state/empty-state.component';
import { ApprovalTimelineComponent } from '../../../shared/approval-timeline/approval-timeline.component';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { ConfirmService } from '../../../shared/confirm-dialog/confirm-dialog.component';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-approval-inbox',
  imports: [ReactiveFormsModule, RouterLink, MoneyPipe, DateFormatPipe, StatusBadgeComponent, LoadingSpinnerComponent, EmptyStateComponent, ApprovalTimelineComponent, PageHeaderComponent],
  templateUrl: './approval-inbox.component.html',
  styleUrl: './approval-inbox.component.css'
})
export class ApprovalInboxComponent implements OnInit {
  private approvals = inject(ApprovalService);
  private admin = inject(AdminService);
  private fb = inject(FormBuilder);
  private toast = inject(ToastService);
  private confirm = inject(ConfirmService);
  auth = inject(AuthService);

  tabs = [
    { key: 'pending', label: 'Pending' }, { key: 'approved', label: 'Approved' },
    { key: 'rejected', label: 'Rejected' }, { key: 'delegated', label: 'Delegated' }
  ];
  tab = 'pending';
  sort = 'oldest';
  items: any[] = [];
  counts: any = {};
  stats: any = {};
  loading = true;
  busyId = '';

  // Delegation panel
  showDelegate = false;
  users: any[] = [];
  delegations: any[] = [];
  delegateForm = this.fb.nonNullable.group({ toUserId: ['', Validators.required], startDate: ['', Validators.required], endDate: ['', Validators.required], reason: [''] });

  ngOnInit(): void { this.load(); }

  load(): void {
    this.loading = true;
    this.approvals.inbox({ tab: this.tab, sort: this.sort, pageSize: 50 }).subscribe({
      next: r => { this.items = r.items; this.counts = r.counts; this.stats = r.stats; this.loading = false; },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  setTab(key: string): void { this.tab = key; this.load(); }
  setSort(value: string): void { this.sort = value; this.load(); }
  open(item: any): string[] { return entityRoute(item.entityType, item.entityId); }

  // Approve needs no comment; reject and request changes ask for a reason first.
  approve(item: any): void {
    this.busyId = item.id;
    this.approvals.decide(item.id, 'approve', '', item.rowVersion).subscribe({
      next: () => { this.busyId = ''; this.toast.success('Approved'); this.load(); },
      error: e => { this.busyId = ''; this.toast.error(e); this.load(); }
    });
  }

  askReason(item: any, action: 'reject' | 'request-changes'): void {
    const reject = action === 'reject';
    this.confirm.ask({
      title: reject ? 'Reject request' : 'Request changes', message: item.title, commentLabel: reject ? 'Reason for rejection' : 'What should change?',
      commentRequired: true, confirmText: reject ? 'Reject' : 'Request changes', danger: reject
    }).subscribe(comment => this.approvals.decide(item.id, action, comment, item.rowVersion).subscribe({
      next: () => { this.toast.success(reject ? 'Rejected' : 'Sent back for changes'); this.load(); },
      error: e => { this.toast.error(e); this.load(); }
    }));
  }

  // ---- delegation
  toggleDelegate(): void {
    this.showDelegate = !this.showDelegate;
    if (!this.showDelegate) return;
    this.admin.userLookup().subscribe({ next: list => this.users = list.filter((u: any) => u.id !== this.auth.user?.userId), error: () => {} });
    this.approvals.delegations().subscribe(d => this.delegations = d);
  }

  saveDelegation(): void {
    if (this.delegateForm.invalid) { this.delegateForm.markAllAsTouched(); return; }
    this.approvals.createDelegation(this.delegateForm.getRawValue()).subscribe({
      next: d => { this.delegations = d; this.toast.success('Delegation created'); this.delegateForm.reset(); },
      error: e => this.toast.error(e)
    });
  }

  cancelDelegation(d: any): void { this.approvals.cancelDelegation(d.id).subscribe({ next: list => this.delegations = list, error: e => this.toast.error(e) }); }
}
