import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { AdminService, RequisitionService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { saveBlob } from '../../../core/services/download.util';
import { TableColumn } from '../../../core/models/models';
import { DataTableComponent } from '../../../shared/data-table/data-table.component';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-requisition-list',
  imports: [RouterLink, DataTableComponent, PageHeaderComponent],
  templateUrl: './requisition-list.component.html',
  styleUrl: './requisition-list.component.css'
})
export class RequisitionListComponent implements OnInit {
  auth = inject(AuthService);
  private service = inject(RequisitionService);
  private admin = inject(AdminService);
  private toast = inject(ToastService);
  private route = inject(ActivatedRoute);

  columns: TableColumn[] = [
    { key: 'number', label: 'Number', type: 'link', sortKey: 'number' },
    { key: 'title', label: 'Title', sortKey: 'title' },
    { key: 'departmentName', label: 'Department' },
    { key: 'costCentreCode', label: 'Cost centre' },
    { key: 'requiredDate', label: 'Required by', type: 'date', sortKey: 'required_date' },
    { key: 'totalAmount', label: 'Est. amount', type: 'money', align: 'right', sortKey: 'total_amount' },
    { key: 'status', label: 'Status', type: 'status', sortKey: 'status' }
  ];

  // "scope" selects the My requests tab; the others filter by status.
  tabs = [
    { label: 'All', scope: 'all', status: '', count: 'All' },
    { label: 'My requests', scope: 'mine', status: '', count: 'Mine' },
    { label: 'Draft', scope: 'all', status: 'Draft', count: 'Draft' },
    { label: 'Pending approval', scope: 'all', status: 'PendingApproval', count: 'PendingApproval' },
    { label: 'Approved', scope: 'all', status: 'Approved', count: 'Approved' },
    { label: 'Rejected', scope: 'all', status: 'Rejected', count: 'Rejected' }
  ];
  activeTab = 0;

  rows: any[] = [];
  counts: any = {};
  departments: any[] = [];
  total = 0;
  loading = true;
  query: any = { page: 1, pageSize: 10, sortBy: 'created_at', sortDir: 'desc', search: '', scope: 'all', status: '', departmentId: '', dateFrom: '', dateTo: '' };

  ngOnInit(): void {
    this.query.search = this.route.snapshot.queryParamMap.get('search') ?? '';
    this.admin.departments().subscribe(d => this.departments = d);
    this.load();
  }

  load(): void {
    this.loading = true;
    this.service.list(this.query).subscribe({
      next: r => { this.rows = r.items; this.total = r.totalCount; this.counts = r.statusCounts ?? {}; this.loading = false; },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  selectTab(index: number): void {
    this.activeTab = index;
    this.query.scope = this.tabs[index].scope;
    this.query.status = this.tabs[index].status;
    this.query.page = 1;
    this.load();
  }

  filterChanged(): void { this.query.page = 1; this.load(); }
  setField(field: string, value: string): void { this.query[field] = value; }
  onPage(p: number): void { this.query.page = p; this.load(); }
  onSort(s: { key: string; dir: 'asc' | 'desc' }): void { this.query.sortBy = s.key; this.query.sortDir = s.dir; this.load(); }
  exportCsv(): void { this.service.export(this.query).subscribe({ next: b => saveBlob(b, 'requisitions.csv'), error: e => this.toast.error(e) }); }
}
