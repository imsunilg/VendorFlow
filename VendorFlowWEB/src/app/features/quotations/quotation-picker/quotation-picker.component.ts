import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { RfqService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { TableColumn } from '../../../core/models/models';
import { DataTableComponent } from '../../../shared/data-table/data-table.component';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';

/** Lists the RFQs that have quotations so one can be opened in the comparison screen. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-quotation-picker',
  imports: [DataTableComponent, PageHeaderComponent],
  templateUrl: './quotation-picker.component.html',
  styleUrl: './quotation-picker.component.css'
})
export class QuotationPickerComponent implements OnInit {
  private rfqs = inject(RfqService);
  private toast = inject(ToastService);

  columns: TableColumn[] = [
    { key: 'number', label: 'RFQ', type: 'link' },
    { key: 'title', label: 'Title' },
    { key: 'quotationsReceived', label: 'Quotations received', type: 'number' },
    { key: 'deadline', label: 'Deadline', type: 'date' },
    { key: 'status', label: 'Status', type: 'status' }
  ];
  rows: any[] = [];
  total = 0;
  loading = true;
  page = 1;

  ngOnInit(): void { this.load(); }

  load(): void {
    this.loading = true;
    this.rfqs.list({ page: this.page, pageSize: 10, sortBy: 'created_at', sortDir: 'desc' }).subscribe({
      next: r => { this.rows = r.items.filter((x: any) => x.quotationsReceived > 0); this.total = r.totalCount; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  onPage(p: number): void { this.page = p; this.load(); }
}
