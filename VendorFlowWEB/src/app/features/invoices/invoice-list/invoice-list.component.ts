import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { InvoiceService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { saveBlob } from '../../../core/services/download.util';
import { TableColumn } from '../../../core/models/models';
import { DataTableComponent } from '../../../shared/data-table/data-table.component';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-invoice-list',
  imports: [RouterLink, DataTableComponent, PageHeaderComponent],
  templateUrl: './invoice-list.component.html',
  styleUrl: './invoice-list.component.css'
})
export class InvoiceListComponent implements OnInit {
  auth = inject(AuthService);
  private service = inject(InvoiceService);
  private toast = inject(ToastService);
  private route = inject(ActivatedRoute);

  columns: TableColumn[] = [
    { key: 'invoiceNumber', label: 'Invoice', type: 'link', sortKey: 'invoice_number' },
    { key: 'vendorName', label: 'Vendor' },
    { key: 'poNumber', label: 'PO' },
    { key: 'invoiceDate', label: 'Invoice date', type: 'date', sortKey: 'invoice_date' },
    { key: 'dueDate', label: 'Due', type: 'date', sortKey: 'due_date' },
    { key: 'status', label: 'Status', type: 'status', sortKey: 'status' },
    { key: 'total', label: 'Total', type: 'money', align: 'right', sortKey: 'total' },
    { key: 'balance', label: 'Balance', type: 'money', align: 'right' }
  ];

  // A tab is either a "tab" (outstanding / overdue) or a status.
  tabs = [
    { label: 'All', tab: 'all', status: '', count: 'All' },
    { label: 'Needs review', tab: 'all', status: 'NeedsReview', count: 'NeedsReview' },
    { label: 'Matched', tab: 'all', status: 'Matched', count: 'Matched' },
    { label: 'Approved', tab: 'all', status: 'Approved', count: 'Approved' },
    { label: 'Partially paid', tab: 'all', status: 'PartiallyPaid', count: 'PartiallyPaid' },
    { label: 'Paid', tab: 'all', status: 'Paid', count: 'Paid' },
    { label: 'Overdue', tab: 'overdue', status: '', count: 'Overdue' }
  ];
  active = 0;

  rows: any[] = [];
  counts: any = {};
  total = 0;
  loading = true;
  query: any = { page: 1, pageSize: 10, sortBy: 'created_at', sortDir: 'desc', search: '', tab: 'all', status: '' };

  ngOnInit(): void {
    this.query.search = this.route.snapshot.queryParamMap.get('search') ?? '';
    this.load();
  }

  load(): void {
    this.loading = true;
    this.service.list(this.query).subscribe({
      next: r => { this.rows = r.items; this.total = r.totalCount; this.counts = r.statusCounts ?? {}; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  selectTab(i: number): void { this.active = i; this.query.tab = this.tabs[i].tab; this.query.status = this.tabs[i].status; this.query.page = 1; this.load(); }
  setSearch(v: string): void { this.query.search = v; }
  search(): void { this.query.page = 1; this.load(); }
  onPage(p: number): void { this.query.page = p; this.load(); }
  onSort(s: { key: string; dir: 'asc' | 'desc' }): void { this.query.sortBy = s.key; this.query.sortDir = s.dir; this.load(); }
  exportCsv(): void { this.service.export(this.query).subscribe({ next: b => saveBlob(b, 'invoices.csv'), error: e => this.toast.error(e) }); }
}
