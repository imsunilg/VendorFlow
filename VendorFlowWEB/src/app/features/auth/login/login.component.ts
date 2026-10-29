import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
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

  busy = false;
  errorMessage = '';

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
