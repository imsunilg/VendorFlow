import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { SettingsService } from '../../../core/services/settings.service';
import { VendorService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { saveBlob } from '../../../core/services/download.util';
import { TableColumn } from '../../../core/models/models';
import { LabelsPipe } from '../../../core/pipes/labels.pipe';
import { DataTableComponent } from '../../../shared/data-table/data-table.component';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-vendor-list',
  imports: [RouterLink, LabelsPipe, DataTableComponent, PageHeaderComponent],
  templateUrl: './vendor-list.component.html',
  styleUrl: './vendor-list.component.css'
})
export class VendorListComponent implements OnInit {
  auth = inject(AuthService);
  settings = inject(SettingsService);
  private vendorService = inject(VendorService);
  private toast = inject(ToastService);
  private route = inject(ActivatedRoute);

  columns: TableColumn[] = [
    { key: 'name', label: 'Vendor', type: 'link', sortKey: 'name' },
    { key: 'gstin', label: 'GSTIN' },
    { key: 'category', label: 'Category', sortKey: 'category' },
    { key: 'location', label: 'Location', sortKey: 'city' },
    { key: 'risk', label: 'Risk', type: 'status', sortKey: 'risk' },
    { key: 'ratingText', label: 'Rating', sortKey: 'rating' },
    { key: 'status', label: 'Status', type: 'status', sortKey: 'status' }
  ];

  tabs = [
    { key: '', label: 'All', countKey: 'All' },
    { key: 'Approved', label: 'Approved', countKey: 'Approved' },
    { key: 'PendingApproval', label: 'Pending approval', countKey: 'PendingApproval' },
    { key: 'Suspended', label: 'Suspended', countKey: 'Suspended' },
    { key: 'Draft', label: 'Draft', countKey: 'Draft' }
  ];

  rows: any[] = [];
  counts: any = {};
  categories: string[] = [];
  total = 0;
  loading = true;

  query = { page: 1, pageSize: 10, sortBy: 'name', sortDir: 'asc' as 'asc' | 'desc', search: '', status: '', category: '', risk: '' };

  ngOnInit(): void {
    this.query.search = this.route.snapshot.queryParamMap.get('search') ?? '';
    this.vendorService.categories().subscribe(c => this.categories = c);
    this.load();
  }

  // Loads one page from the API with the current filters.
  load(): void {
    this.loading = true;
    this.vendorService.list(this.query).subscribe({
      next: r => {
        this.rows = r.items.map(v => ({ ...v, location: [v.city, v.state].filter(Boolean).join(', ') || '—', ratingText: '★ ' + v.rating }));
        this.total = r.totalCount;
        this.counts = r.statusCounts ?? {};
        this.loading = false;
      },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  setTab(status: string): void { this.query.status = status; this.query.page = 1; this.load(); }
  onFilterChange(): void { this.query.page = 1; this.load(); }
  onPage(page: number): void { this.query.page = page; this.load(); }
  onSort(s: { key: string; dir: 'asc' | 'desc' }): void { this.query.sortBy = s.key; this.query.sortDir = s.dir; this.load(); }

  exportCsv(): void {
    this.vendorService.export(this.query).subscribe({ next: b => saveBlob(b, 'vendors.csv'), error: e => this.toast.error(e) });
  }

  // Text inputs update the query without reloading on every key press; Enter or the button reloads.
  setText(field: 'search', value: string): void { this.query[field] = value; }
  setSelect(field: 'category' | 'risk' | 'status', value: string): void { this.query[field] = value; this.onFilterChange(); }
}
