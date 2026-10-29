import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { VendorService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-vendor-form',
  imports: [ReactiveFormsModule, RouterLink, PageHeaderComponent, LoadingSpinnerComponent],
  templateUrl: './vendor-form.component.html',
  styleUrl: './vendor-form.component.css'
})
export class VendorFormComponent implements OnInit {
  private fb = inject(FormBuilder);
  private vendors = inject(VendorService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);

  id = this.route.snapshot.paramMap.get('id');       // null when creating a new vendor
  loading = false;
  saving = false;
  rowVersion: number | null = null;

  form = this.fb.nonNullable.group({
    name: ['', [Validators.required, Validators.maxLength(150)]],
    legalName: [''],
    category: [''],
    productsServices: [''],
    risk: ['Low'],
    rating: [0, [Validators.min(0), Validators.max(5)]],
    gstin: ['', Validators.pattern(/^$|^[0-9]{2}[A-Za-z]{5}[0-9]{4}[A-Za-z][1-9A-Za-z]Z[0-9A-Za-z]$/)],
    pan: ['', Validators.pattern(/^$|^[A-Za-z]{5}[0-9]{4}[A-Za-z]$/)],
    msmeNumber: [''],
    paymentTermsDays: [30, [Validators.min(0), Validators.max(365)]],
    email: ['', Validators.email],
    phone: [''],
    city: [''],
    state: ['']
  });

  ngOnInit(): void {
    if (!this.id) return;
    this.loading = true;
    this.vendors.get(this.id).subscribe({
      next: v => { this.form.patchValue(this.emptyToBlank(v)); this.rowVersion = v.rowVersion; this.loading = false; },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  // The API sends null for empty text fields; text inputs want empty strings.
  private emptyToBlank(v: any): any {
    const copy: any = {};
    for (const key of Object.keys(this.form.controls)) copy[key] = v[key] ?? '';
    copy.rating = v.rating ?? 0;
    return copy;
  }

  save(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    this.saving = true;
    const body = { ...this.form.getRawValue(), rowVersion: this.rowVersion ?? undefined };
    const call = this.id ? this.vendors.update(this.id, body) : this.vendors.create(body);
    call.subscribe({
      next: v => { this.toast.success('Saved'); this.router.navigate(['/vendors', v.id]); },
      error: err => { this.saving = false; this.toast.error(err); }
    });
  }

  // Shows a message under a field when it is touched and invalid.
  invalid(name: string): boolean {
    const c = this.form.get(name);
    return !!c && c.touched && c.invalid;
  }
}
