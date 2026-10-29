import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ReportService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { saveBlob } from '../../../core/services/download.util';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';
import { LabelsPipe } from '../../../core/pipes/labels.pipe';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';
import { EmptyStateComponent } from '../../../shared/empty-state/empty-state.component';
import { StatusBadgeComponent } from '../../../shared/status-badge/status-badge.component';

/** Report picker (cards) + result table + CSV export. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-report-viewer',
  imports: [FormsModule, MoneyPipe, DateFormatPipe, LabelsPipe, PageHeaderComponent, LoadingSpinnerComponent, EmptyStateComponent, StatusBadgeComponent],
  templateUrl: './report-viewer.component.html',
  styleUrl: './report-viewer.component.css'
})
export class ReportViewerComponent implements OnInit {
  private reports = inject(ReportService);
  private toast = inject(ToastService);

  catalog: any[] = [];
  selected: any = null;
  result: any = null;
  loading = false;

  // Filters
  from = '';
  to = '';
  groupBy = 'month';
  days = 60;

  ngOnInit(): void {
    this.reports.catalog().subscribe(c => { this.catalog = c; if (c.length) this.select(c[0]); });
  }

  select(report: any): void { this.selected = report; this.run(); }
  uses(param: string): boolean { return !!this.selected?.params.includes(param); }

  private query(): any { return { from: this.from, to: this.to, groupBy: this.uses('groupBy') ? this.groupBy : '', days: this.uses('days') ? this.days : '' }; }

  run(): void {
    if (!this.selected) return;
    this.loading = true;
    this.reports.run(this.selected.key, this.query()).subscribe({
      next: r => { this.result = r; this.loading = false; },
      error: e => { this.loading = false; this.result = null; this.toast.error(e); }
    });
  }

  exportCsv(): void {
    this.reports.export(this.selected.key, this.query()).subscribe({ next: b => saveBlob(b, this.selected.key + '.csv'), error: e => this.toast.error(e) });
  }

  // The API tells the type of each column so money, percent and status are shown nicely.
  isStatus(col: any): boolean { return col.key === 'status'; }
}
