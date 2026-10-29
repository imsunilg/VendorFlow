import { ChangeDetectionStrategy, Component, OnDestroy, OnInit, inject } from '@angular/core';
import { ActivatedRoute, NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { MatMenuModule } from '@angular/material/menu';
import { Subscription, filter, interval, startWith, switchMap, catchError, of } from 'rxjs';
import { AuthService } from '../../../core/services/auth.service';
import { SettingsService } from '../../../core/services/settings.service';
import { AdminService, ApprovalService } from '../../../core/services/data.services';
import { entityRoute } from '../../../core/services/entity-route';
import { LabelsPipe } from '../../../core/pipes/labels.pipe';
import { DateFormatPipe } from '../../../core/pipes/date-format.pipe';

interface NavItem { label: string; icon: string; route: string; permission?: string; badge?: boolean; }

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-shell',
  imports: [RouterOutlet, RouterLink, RouterLinkActive, MatMenuModule, LabelsPipe, DateFormatPipe],
  templateUrl: './shell.component.html',
  styleUrl: './shell.component.css'
})
export class ShellComponent implements OnInit, OnDestroy {
  auth = inject(AuthService);
  settings = inject(SettingsService);
  private admin = inject(AdminService);
  private approvals = inject(ApprovalService);
  private router = inject(Router);
  private route = inject(ActivatedRoute);

  // The words "Vendors" in this list are replaced by the labels pipe in the template.
  mainMenu: NavItem[] = [
    { label: 'Dashboard', icon: 'dashboard', route: '/' },
    { label: 'Vendors', icon: 'storefront', route: '/vendors', permission: 'vendors.view' },
    { label: 'Requisitions', icon: 'description', route: '/requisitions', permission: 'requisitions.view' },
    { label: 'Approvals', icon: 'task_alt', route: '/approvals', permission: 'approvals.view', badge: true },
    { label: 'RFQs', icon: 'forum', route: '/rfqs', permission: 'rfqs.view' },
    { label: 'Quotations', icon: 'insights', route: '/quotations', permission: 'quotations.view' },
    { label: 'Purchase Orders', icon: 'shopping_cart', route: '/purchase-orders', permission: 'po.view' },
    { label: 'Goods Receipts', icon: 'inventory_2', route: '/goods-receipts', permission: 'grn.view' },
    { label: 'Invoices', icon: 'receipt_long', route: '/invoices', permission: 'invoices.view' },
    { label: 'Payments', icon: 'payments', route: '/payments', permission: 'payments.view' },
    { label: 'Reports', icon: 'bar_chart', route: '/reports', permission: 'reports.view' }
  ];
  adminMenu: NavItem[] = [
    { label: 'Users & Roles', icon: 'group', route: '/users', permission: 'users.manage' },
    { label: 'Organization Settings', icon: 'settings', route: '/settings', permission: 'settings.manage' }
  ];

  sidebarOpen = false;
  breadcrumb = 'Dashboard';
  pendingApprovals = 0;
  unread = 0;
  notes: any[] = [];
  searchText = '';
  private timer?: Subscription;
  private navSub?: Subscription;

  get roleText(): string { return (this.auth.user?.roles ?? []).map(r => r.replace(/([a-z])([A-Z])/g, '$1 $2')).join(', '); }
  get initials(): string { return (this.auth.user?.fullName ?? '?').split(' ').map(p => p[0]).slice(0, 2).join('').toUpperCase(); }

  visible(items: NavItem[]): NavItem[] { return items.filter(i => !i.permission || this.auth.has(i.permission)); }

  ngOnInit(): void {
    this.settings.load().subscribe({ error: () => {} });
    this.updateBreadcrumb();
    this.navSub = this.router.events.pipe(filter(e => e instanceof NavigationEnd)).subscribe(() => { this.sidebarOpen = false; this.updateBreadcrumb(); });
    // Badge counts are refreshed every minute.
    this.timer = interval(60000).pipe(startWith(0), switchMap(() => this.loadCounts())).subscribe();
  }

  ngOnDestroy(): void {
    this.timer?.unsubscribe();
    this.navSub?.unsubscribe();
  }

  private loadCounts() {
    if (this.auth.has('approvals.view')) {
      this.approvals.pendingCount().pipe(catchError(() => of({ count: 0 }))).subscribe(r => this.pendingApprovals = r.count);
    }
    return this.admin.notifications({ unreadOnly: true, pageSize: 5 }).pipe(catchError(() => of(null)), switchMap(r => {
      if (r) { this.unread = r.unreadCount; this.notes = r.items; }
      return of(r);
    }));
  }

  // The breadcrumb text comes from the "breadcrumb" value of the deepest active route.
  private updateBreadcrumb(): void {
    let current = this.route;
    while (current.firstChild) current = current.firstChild;
    this.breadcrumb = (current.snapshot.data['breadcrumb'] as string) ?? '';
  }

  // Quick search: the prefix of the text decides which list opens.
  search(): void {
    const text = this.searchText.trim();
    if (!text) return;
    const target = text.toUpperCase().startsWith('PO-') ? '/purchase-orders' : text.toUpperCase().startsWith('INV') ? '/invoices'
      : text.toUpperCase().startsWith('REQ') ? '/requisitions' : text.toUpperCase().startsWith('RFQ') ? '/rfqs' : '/vendors';
    this.router.navigate([target], { queryParams: { search: text } });
    this.searchText = '';
  }

  openNote(n: any): void {
    this.admin.markRead(n.id).subscribe(() => this.unread = Math.max(0, this.unread - 1));
    this.router.navigate(entityRoute(n.entityType, n.entityId));
  }

  logout(): void {
    this.settings.reset();
    this.auth.logout();
  }
}
