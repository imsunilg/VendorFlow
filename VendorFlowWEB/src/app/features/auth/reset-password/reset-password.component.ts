import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { ApiService } from '../../../core/services/api.service';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-reset-password',
  imports: [ReactiveFormsModule, RouterLink],
  templateUrl: './reset-password.component.html',
  styleUrl: './reset-password.component.css'
})
export class ResetPasswordComponent {
  private fb = inject(FormBuilder);
  private api = inject(ApiService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);

  token = this.route.snapshot.queryParamMap.get('token') ?? '';
  form = this.fb.nonNullable.group({
    newPassword: ['', [Validators.required, Validators.minLength(8), Validators.pattern(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$/)]],
    confirm: ['', Validators.required]
  });
  busy = false;
  errorMessage = '';

  get mismatch(): boolean { return this.form.value.newPassword !== this.form.value.confirm; }

  // Saves the new password; the token comes from the link in the e-mail (or the invitation).
  submit(): void {
    if (this.form.invalid || this.mismatch) { this.form.markAllAsTouched(); return; }
    this.busy = true;
    this.errorMessage = '';
    this.api.post('/auth/reset-password', { token: this.token, newPassword: this.form.value.newPassword }).subscribe({
      next: () => this.router.navigate(['/login']),
      error: err => { this.busy = false; this.errorMessage = err?.error?.title || 'This link is invalid or has expired.'; }
    });
  }
}
