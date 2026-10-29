import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { GoodsReceiptService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';
import { StatusBadgeComponent } from '../../../shared/status-badge/status-badge.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { AttachmentsPanelComponent } from '../../../shared/attachments-panel/attachments-panel.component';
import { ConfirmService } from '../../../shared/confirm-dialog/confirm-dialog.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-grn-detail',
  imports: [RouterLink, DateFormatPipe, StatusBadgeComponent, LoadingSpinnerComponent, AttachmentsPanelComponent],
  templateUrl: './grn-detail.component.html',
  styleUrl: './grn-detail.component.css'
})
export class GrnDetailComponent implements OnInit {
  auth = inject(AuthService);
  private service = inject(GoodsReceiptService);
  private route = inject(ActivatedRoute);
  private toast = inject(ToastService);
  private confirm = inject(ConfirmService);

  id = this.route.snapshot.paramMap.get('id')!;
  grn: any = null;
  loading = true;

  ngOnInit(): void {
    this.service.get(this.id).subscribe({
      next: g => { this.grn = g; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  cancel(): void {
    this.confirm.ask({ title: 'Cancel receipt', message: 'The accepted quantities are removed from the purchase order again.', commentLabel: 'Reason', commentRequired: true, confirmText: 'Cancel receipt', danger: true })
      .subscribe(comment => this.service.cancel(this.id, comment).subscribe({ next: g => { this.grn = g; this.toast.success('Receipt cancelled'); }, error: e => this.toast.error(e) }));
  }
}
