import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { Router } from '@angular/router';
import { AdminService } from '../../core/services/data.services';
import { ToastService } from '../../core/services/toast.service';
import { entityRoute } from '../../core/services/entity-route';
import { DateFormatPipe } from '../../core/pipes/date-format.pipe';
import { PageHeaderComponent } from '../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../shared/loading-spinner/loading-spinner.component';
import { EmptyStateComponent } from '../../shared/empty-state/empty-state.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-notifications',
  imports: [DateFormatPipe, PageHeaderComponent, LoadingSpinnerComponent, EmptyStateComponent],
  templateUrl: './notifications.component.html',
  styleUrl: './notifications.component.css'
})
export class NotificationsComponent implements OnInit {
  private admin = inject(AdminService);
  private router = inject(Router);
  private toast = inject(ToastService);

  items: any[] = [];
  unread = 0;
  loading = true;
  onlyUnread = false;

  ngOnInit(): void { this.load(); }

  load(): void {
    this.loading = true;
    this.admin.notifications({ unreadOnly: this.onlyUnread, pageSize: 50 }).subscribe({
      next: r => { this.items = r.items; this.unread = r.unreadCount; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  toggleUnread(): void { this.onlyUnread = !this.onlyUnread; this.load(); }
  readAll(): void { this.admin.markAllRead().subscribe(() => this.load()); }

  open(n: any): void {
    this.admin.markRead(n.id).subscribe(() => this.router.navigate(entityRoute(n.entityType, n.entityId)));
  }

  // Icon colour by notification type.
  tone(type: string): string {
    if (type.includes('overdue') || type.includes('expired')) return 'red';
    if (type.includes('needed') || type.includes('expiring') || type.includes('due') || type.includes('reminder') || type.includes('closing')) return 'amber';
    return 'green';
  }
}
