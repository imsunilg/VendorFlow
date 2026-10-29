import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { RouterLink } from '@angular/router';
import { AuthService } from '../../core/services/auth.service';
import { ReportService } from '../../core/services/data.services';
import { ToastService } from '../../core/services/toast.service';
import { entityRoute } from '../../core/services/entity-route';
import { MoneyPipe, MoneyShortPipe } from '../../core/pipes/money.pipe';
import { LabelsPipe } from '../../core/pipes/labels.pipe';
import { StatusBadgeComponent } from '../../shared/status-badge/status-badge.component';
import { LoadingSpinnerComponent } from '../../shared/loading-spinner/loading-spinner.component';
import { EmptyStateComponent } from '../../shared/empty-state/empty-state.component';
import { PageHeaderComponent } from '../../shared/page-header/page-header.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-dashboard',
  imports: [RouterLink, MoneyPipe, MoneyShortPipe, LabelsPipe, StatusBadgeComponent, LoadingSpinnerComponent, EmptyStateComponent, PageHeaderComponent],
  templateUrl: './dashboard.component.html',
  styleUrl: './dashboard.component.css'
})
export class DashboardComponent implements OnInit {
  auth = inject(AuthService);
  private reports = inject(ReportService);
  private toast = inject(ToastService);

  data: any = null;
  loading = true;
  canSeeReports = this.auth.has('reports.view');
  barColors = ['#3b4fe0', '#12a05c', '#d98a06', '#2b8be0', '#9b5cf6'];

  get firstName(): string { return (this.auth.user?.fullName ?? '').split(' ')[0]; }
  get greeting(): string {
    const hour = new Date().getHours();
    return hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
  }

  // Height of one bar relative to the biggest month (minimum 4% so empty months stay visible).
  barHeight(amount: number): number {
    const max = Math.max(...(this.data?.monthlyTrend ?? []).map((m: any) => m.amount), 1);
    return Math.max(4, Math.round((amount / max) * 100));
  }

  ngOnInit(): void {
    if (!this.canSeeReports) { this.loading = false; return; }
    this.reports.dashboard().subscribe({
      next: d => { this.data = d; this.loading = false; },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  open(item: any): string[] { return entityRoute(item.entityType, item.entityId); }
}
