import { ChangeDetectionStrategy, Component, EventEmitter, Input, Output } from '@angular/core';
import { RouterLink } from '@angular/router';
import { TableColumn } from '../../core/models/models';
import { StatusBadgeComponent } from '../status-badge/status-badge.component';
import { MoneyPipe } from '../../core/pipes/money.pipe';
import { DateFormatPipe } from '../../core/pipes/date-format.pipe';
import { LabelsPipe } from '../../core/pipes/labels.pipe';
import { LoadingSpinnerComponent } from '../loading-spinner/loading-spinner.component';
import { EmptyStateComponent } from '../empty-state/empty-state.component';

/**
 * Reusable list table with server-side sorting and paging.
 * The parent loads the rows and listens to (pageChange) and (sortChange).
 * A column of type "link" opens `linkTemplate` where ":id" is replaced by the row's id, e.g. "/vendors/:id".
 */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-data-table',
  imports: [RouterLink, StatusBadgeComponent, MoneyPipe, DateFormatPipe, LabelsPipe, LoadingSpinnerComponent, EmptyStateComponent],
  templateUrl: './data-table.component.html',
  styleUrl: './data-table.component.css'
})
export class DataTableComponent {
  @Input() columns: TableColumn[] = [];
  @Input() rows: any[] = [];
  @Input() totalCount = 0;
  @Input() page = 1;
  @Input() pageSize = 20;
  @Input() loading = false;
  @Input() sortKey = '';
  @Input() sortDir: 'asc' | 'desc' = 'asc';
  @Input() linkTemplate = '';
  @Input() emptyText = 'Nothing to show yet.';
  @Input() showPager = true;

  @Output() pageChange = new EventEmitter<number>();
  @Output() sortChange = new EventEmitter<{ key: string; dir: 'asc' | 'desc' }>();
  @Output() rowClick = new EventEmitter<any>();

  get pageCount(): number { return Math.max(1, Math.ceil(this.totalCount / this.pageSize)); }

  // Page numbers around the current page (max 5 buttons).
  get pages(): number[] {
    const start = Math.max(1, Math.min(this.page - 2, this.pageCount - 4));
    const end = Math.min(this.pageCount, start + 4);
    return Array.from({ length: end - start + 1 }, (_, i) => start + i);
  }

  get from(): number { return this.totalCount === 0 ? 0 : (this.page - 1) * this.pageSize + 1; }
  get to(): number { return Math.min(this.page * this.pageSize, this.totalCount); }

  link(row: any): string { return this.linkTemplate.replace(':id', row.id); }

  // Clicking a sortable header toggles asc/desc.
  sortBy(col: TableColumn): void {
    if (!col.sortKey) return;
    const dir = this.sortKey === col.sortKey && this.sortDir === 'asc' ? 'desc' : 'asc';
    this.sortChange.emit({ key: col.sortKey, dir });
  }

  goTo(page: number): void {
    if (page >= 1 && page <= this.pageCount && page !== this.page) this.pageChange.emit(page);
  }
}
