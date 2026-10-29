import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { ApiService } from '../../../core/services/api.service';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-forgot-password',
  imports: [ReactiveFormsModule, RouterLink],
  templateUrl: './forgot-password.component.html',
  styleUrl: './forgot-password.component.css'
})
export class ForgotPasswordComponent {
  private fb = inject(FormBuilder);
  private api = inject(ApiService);

  form = this.fb.nonNullable.group({ email: ['', [Validators.required, Validators.email]] });
  busy = false;
  sent = false;
  devToken = '';      // only returned by the API in Development, so the flow can be tested without e-mail

  // The API always answers "accepted", whether or not the address exists.
  submit(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    this.busy = true;
    this.api.post('/auth/forgot-password', this.form.getRawValue()).subscribe({
      next: (r: any) => { this.busy = false; this.sent = true; this.devToken = r?.resetToken ?? ''; },
      error: () => { this.busy = false; this.sent = true; }
    });
  }
}
