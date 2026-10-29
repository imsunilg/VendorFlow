import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { GoodsReceiptService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { TableColumn } from '../../../core/models/models';
import { DataTableComponent } from '../../../shared/data-table/data-table.component';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-grn-list',
  imports: [DataTableComponent, PageHeaderComponent],
  templateUrl: './grn-list.component.html',
  styleUrl: './grn-list.component.css'
})
export class GrnListComponent implements OnInit {
  private service = inject(GoodsReceiptService);
  private toast = inject(ToastService);

  columns: TableColumn[] = [
    { key: 'number', label: 'GRN', type: 'link' },
    { key: 'poNumber', label: 'Purchase order' },
    { key: 'vendorName', label: 'Vendor' },
    { key: 'receivedOn', label: 'Received on', type: 'date' },
    { key: 'warehouse', label: 'Warehouse' },
    { key: 'deliveryChallan', label: 'Challan' },
    { key: 'acceptedQty', label: 'Accepted', type: 'number' },
    { key: 'rejectedQty', label: 'Rejected', type: 'number' },
    { key: 'status', label: 'Status', type: 'status' }
  ];
  rows: any[] = [];
  total = 0;
  loading = true;
  query: any = { page: 1, pageSize: 10, search: '' };

  ngOnInit(): void { this.load(); }

  load(): void {
    this.loading = true;
    this.service.list(this.query).subscribe({
      next: r => { this.rows = r.items; this.total = r.totalCount; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  setSearch(v: string): void { this.query.search = v; }
  search(): void { this.query.page = 1; this.load(); }
  onPage(p: number): void { this.query.page = p; this.load(); }
}
