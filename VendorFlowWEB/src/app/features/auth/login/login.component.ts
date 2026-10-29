import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { environment } from '../../../../environments/environment';
import { SettingsService } from '../../../core/services/settings.service';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-login',
  imports: [ReactiveFormsModule, RouterLink],
  templateUrl: './login.component.html',
  styleUrl: './login.component.css'
})
export class LoginComponent {
  private fb = inject(FormBuilder);
  private auth = inject(AuthService);
  private settings = inject(SettingsService);
  private router = inject(Router);

  form = this.fb.nonNullable.group({
    email: [localStorage.getItem('vf_remember') ?? '', [Validators.required, Validators.email]],
    password: ['', Validators.required],
    remember: [!!localStorage.getItem('vf_remember')]
  });

  // Demo logins (development only): one per role. All share the same demo password.
  showDemo = !environment.production;
  demoPassword = 'Demo@12345';
  demoAccounts = [
    { role: 'Organization Owner', email: 'priya.menon@democompany.in' },
    { role: 'Organization Administrator', email: 'admin@democompany.in' },
    { role: 'Procurement Manager', email: 'mark.w@democompany.in' },
    { role: 'Procurement Officer', email: 'officer@democompany.in' },
    { role: 'Department Manager', email: 'rahul.d@democompany.in' },
    { role: 'Department Requester', email: 'anita.rao@democompany.in' },
    { role: 'Approver', email: 'approver@democompany.in' },
    { role: 'Finance Manager', email: 'sneha.i@democompany.in' },
    { role: 'Accounts Payable Officer', email: 'ap@democompany.in' },
    { role: 'Warehouse Manager', email: 'suresh.j@democompany.in' },
    { role: 'Auditor', email: 'auditor@democompany.in' }
  ];

  busy = false;
  errorMessage = '';

  // Fills the form with a demo account.
  useDemo(email: string): void {
    this.form.patchValue({ email, password: this.demoPassword });
  }

  // Signs in, loads the organization settings (labels) and opens the dashboard.
  submit(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    const { email, password, remember } = this.form.getRawValue();
    this.busy = true;
    this.errorMessage = '';
    this.auth.login(email, password).subscribe({
      next: () => {
        if (remember) localStorage.setItem('vf_remember', email); else localStorage.removeItem('vf_remember');
        this.settings.load().subscribe({ next: () => this.router.navigate(['/']), error: () => this.router.navigate(['/']) });
      },
      error: err => {
        this.busy = false;
        this.errorMessage = err.status === 429 ? 'Too many attempts. Please wait a minute.' : (err?.error?.detail || 'Sign in failed.');
      }
    });
  }
}
