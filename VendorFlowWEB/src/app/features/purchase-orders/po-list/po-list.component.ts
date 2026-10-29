import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { PurchaseOrderService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { saveBlob } from '../../../core/services/download.util';
import { TableColumn } from '../../../core/models/models';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { DataTableComponent } from '../../../shared/data-table/data-table.component';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-po-list',
  imports: [RouterLink, MoneyPipe, DataTableComponent, PageHeaderComponent],
  templateUrl: './po-list.component.html',
  styleUrl: './po-list.component.css'
})
export class PoListComponent implements OnInit {
  auth = inject(AuthService);
  private service = inject(PurchaseOrderService);
  private toast = inject(ToastService);
  private route = inject(ActivatedRoute);

  columns: TableColumn[] = [
    { key: 'number', label: 'PO no', type: 'link', sortKey: 'number' },
    { key: 'vendorName', label: 'Vendor' },
    { key: 'orderDate', label: 'Order date', type: 'date', sortKey: 'order_date' },
    { key: 'expectedDelivery', label: 'Expected delivery', type: 'date', sortKey: 'expected_delivery' },
    { key: 'status', label: 'Status', type: 'status', sortKey: 'status' },
    { key: 'receiptPct', label: 'Receipt', type: 'progress' },
    { key: 'total', label: 'Amount', type: 'money', align: 'right', sortKey: 'total' }
  ];
  tabs = [
    { key: '', label: 'All' }, { key: 'Draft', label: 'Draft' }, { key: 'PendingApproval', label: 'Pending approval' },
    { key: 'Issued', label: 'Issued' }, { key: 'PartiallyReceived', label: 'Receiving' }, { key: 'Closed', label: 'Closed' }
  ];

  rows: any[] = [];
  stats: any = {};
  total = 0;
  loading = true;
  query: any = { page: 1, pageSize: 10, sortBy: 'created_at', sortDir: 'desc', search: '', status: '' };

  ngOnInit(): void {
    this.query.search = this.route.snapshot.queryParamMap.get('search') ?? '';
    this.load();
  }

  load(): void {
    this.loading = true;
    this.service.list(this.query).subscribe({
      next: r => { this.rows = r.items; this.total = r.totalCount; this.stats = r.stats ?? {}; this.loading = false; },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  setTab(status: string): void { this.query.status = status; this.query.page = 1; this.load(); }
  setSearch(value: string): void { this.query.search = value; }
  search(): void { this.query.page = 1; this.load(); }
  onPage(p: number): void { this.query.page = p; this.load(); }
  onSort(s: { key: string; dir: 'asc' | 'desc' }): void { this.query.sortBy = s.key; this.query.sortDir = s.dir; this.load(); }
  exportCsv(): void { this.service.export(this.query).subscribe({ next: b => saveBlob(b, 'purchase-orders.csv'), error: e => this.toast.error(e) }); }
}
