import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { SettingsService } from '../../../core/services/settings.service';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-register',
  imports: [ReactiveFormsModule, RouterLink],
  templateUrl: './register.component.html',
  styleUrl: './register.component.css'
})
export class RegisterComponent {
  private fb = inject(FormBuilder);
  private auth = inject(AuthService);
  private settings = inject(SettingsService);
  private router = inject(Router);

  form = this.fb.nonNullable.group({
    organizationName: ['', [Validators.required, Validators.maxLength(100)]],
    fullName: ['', [Validators.required, Validators.maxLength(100)]],
    email: ['', [Validators.required, Validators.email]],
    password: ['', [Validators.required, Validators.minLength(8), Validators.pattern(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$/)]]
  });

  busy = false;
  errorMessage = '';

  // Creates the organization and its owner account, then signs the owner in.
  submit(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    this.busy = true;
    this.errorMessage = '';
    this.auth.registerOrganization(this.form.getRawValue()).subscribe({
      next: () => this.settings.load().subscribe({ next: () => this.router.navigate(['/']), error: () => this.router.navigate(['/']) }),
      error: err => {
        this.busy = false;
        this.errorMessage = err?.error?.detail || 'Registration failed.';
      }
    });
  }
}
