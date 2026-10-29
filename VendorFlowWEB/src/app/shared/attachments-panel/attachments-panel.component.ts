import { ChangeDetectionStrategy, Component, Input, OnChanges, inject } from '@angular/core';
import { AdminService } from '../../core/services/data.services';
import { ToastService } from '../../core/services/toast.service';
import { openBlob } from '../../core/services/download.util';
import { FileUploadComponent } from '../file-upload/file-upload.component';

/** Lists the files attached to a document and lets users with edit rights add or remove files. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-attachments-panel',
  imports: [FileUploadComponent],
  templateUrl: './attachments-panel.component.html',
  styleUrl: './attachments-panel.component.css'
})
export class AttachmentsPanelComponent implements OnChanges {
  private admin = inject(AdminService);
  private toast = inject(ToastService);

  @Input({ required: true }) entityType = '';      // requisition | rfq | purchase_order | goods_receipt | invoice
  @Input({ required: true }) entityId = '';
  @Input() canEdit = false;

  files: any[] = [];

  ngOnChanges(): void { this.load(); }

  load(): void {
    if (!this.entityId) return;
    this.admin.attachments(this.entityType, this.entityId).subscribe({ next: f => this.files = f, error: () => this.files = [] });
  }

  upload(file: File): void {
    this.admin.upload(this.entityType, this.entityId, file).subscribe({
      next: () => { this.toast.success('File attached'); this.load(); },
      error: e => this.toast.error(e)
    });
  }

  open(f: any): void { this.admin.attachmentFile(f.id).subscribe({ next: b => openBlob(b), error: e => this.toast.error(e) }); }

  remove(f: any): void { this.admin.deleteAttachment(f.id).subscribe({ next: () => this.load(), error: e => this.toast.error(e) }); }

  size(bytes: number): string { return bytes > 1024 * 1024 ? (bytes / 1024 / 1024).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB'; }
}
