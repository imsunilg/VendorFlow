import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { AuthService } from '../../core/services/auth.service';
import { AdminService } from '../../core/services/data.services';
import { ToastService } from '../../core/services/toast.service';
import { DateFormatPipe } from '../../core/pipes/date-format.pipe';
import { StatusBadgeComponent } from '../../shared/status-badge/status-badge.component';
import { PageHeaderComponent } from '../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../shared/loading-spinner/loading-spinner.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-users-roles',
  imports: [ReactiveFormsModule, DateFormatPipe, StatusBadgeComponent, PageHeaderComponent, LoadingSpinnerComponent],
  templateUrl: './users-roles.component.html',
  styleUrl: './users-roles.component.css'
})
export class UsersRolesComponent implements OnInit {
  auth = inject(AuthService);
  private admin = inject(AdminService);
  private fb = inject(FormBuilder);
  private toast = inject(ToastService);

  tab: 'users' | 'roles' | 'audit' = 'users';
  users: any[] = [];
  roles: any[] = [];
  audit: any[] = [];
  permissions: string[] = [];
  loading = true;
  search = '';

  editing: any = null;                 // the user whose roles are being edited
  chosenRoles = new Set<string>();
  showInvite = false;
  inviteLink = '';

  inviteForm = this.fb.nonNullable.group({ fullName: ['', Validators.required], email: ['', [Validators.required, Validators.email]] });
  inviteRoles = new Set<string>();

  ngOnInit(): void {
    this.admin.roles().subscribe(r => {
      this.roles = r;
      this.permissions = [...new Set(r.flatMap((x: any) => x.permissions as string[]))].sort();
    });
    this.loadUsers();
  }

  loadUsers(): void {
    this.loading = true;
    this.admin.users({ search: this.search, pageSize: 100 }).subscribe({
      next: r => { this.users = r.items; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  open(tab: 'users' | 'roles' | 'audit'): void {
    this.tab = tab;
    if (tab === 'audit') this.admin.audit({ pageSize: 50 }).subscribe({ next: r => this.audit = r.items, error: e => this.toast.error(e) });
  }

  roleName(code: string): string { return code.replace(/([a-z])([A-Z])/g, '$1 $2'); }
  has(role: any, permission: string): boolean { return role.permissions.includes(permission); }

  // ---- edit roles
  editRoles(user: any): void { this.editing = user; this.chosenRoles = new Set(user.roles); }
  toggle(set: Set<string>, code: string, checked: boolean): void { if (checked) set.add(code); else set.delete(code); }

  saveRoles(): void {
    this.admin.setRoles(this.editing.id, [...this.chosenRoles]).subscribe({
      next: () => { this.toast.success('Roles updated'); this.editing = null; this.loadUsers(); },
      error: e => this.toast.error(e)
    });
  }

  toggleStatus(user: any): void {
    const status = user.status === 'Disabled' ? 'Active' : 'Disabled';
    this.admin.setStatus(user.id, status).subscribe({ next: () => this.loadUsers(), error: e => this.toast.error(e) });
  }

  // ---- invite
  invite(): void {
    if (this.inviteForm.invalid || this.inviteRoles.size === 0) { this.inviteForm.markAllAsTouched(); this.toast.error({ error: { detail: 'Enter name, email and choose at least one role.' } }); return; }
    this.admin.invite({ ...this.inviteForm.getRawValue(), roles: [...this.inviteRoles] }).subscribe({
      next: r => {
        this.inviteLink = `${location.origin}/reset-password?token=${r.inviteToken}`;
        this.toast.success('User invited');
        this.inviteForm.reset(); this.inviteRoles.clear();
        this.loadUsers();
      },
      error: e => this.toast.error(e)
    });
  }

  copy(text: string): void { navigator.clipboard?.writeText(text); this.toast.success('Link copied'); }
}
