import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormArray, FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { AdminService, RequisitionService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';
import { LoadingSpinnerComponent } from '../../../shared/loading-spinner/loading-spinner.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-requisition-form',
  imports: [ReactiveFormsModule, RouterLink, MoneyPipe, PageHeaderComponent, LoadingSpinnerComponent],
  templateUrl: './requisition-form.component.html',
  styleUrl: './requisition-form.component.css'
})
export class RequisitionFormComponent implements OnInit {
  private fb = inject(FormBuilder);
  private service = inject(RequisitionService);
  private admin = inject(AdminService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);

  id = this.route.snapshot.paramMap.get('id');
  rowVersion: number | null = null;
  departments: any[] = [];
  costCentres: any[] = [];
  loading = false;
  saving = false;

  form = this.fb.nonNullable.group({
    title: ['', [Validators.required, Validators.maxLength(200)]],
    departmentId: ['', Validators.required],
    costCentreId: ['', Validators.required],
    requiredDate: ['', Validators.required],
    priority: ['Medium'],
    justification: [''],
    items: this.fb.array([this.newItem()])
  });

  get items(): FormArray { return this.form.controls.items; }

  // Cost centres of the selected department (or all when the department has none).
  get costCentreOptions(): any[] {
    const dept = this.form.controls.departmentId.value;
    const own = this.costCentres.filter(c => c.departmentId === dept);
    return own.length ? own : this.costCentres;
  }

  get total(): number {
    return this.items.controls.reduce((sum, row) => sum + this.lineTotal(row.value), 0);
  }

  newItem(item?: any) {
    return this.fb.nonNullable.group({
      description: [item?.description ?? '', Validators.required],
      unit: [item?.unit ?? 'Nos'],
      quantity: [item?.quantity ?? 1, [Validators.required, Validators.min(0.001)]],
      estUnitPrice: [item?.estUnitPrice ?? 0, [Validators.required, Validators.min(0)]]
    });
  }

  // Same rule as the API: round the price to 2 decimals first, then the line total.
  lineTotal(row: any): number {
    return Math.round((row.quantity || 0) * (Math.round((row.estUnitPrice || 0) * 100) / 100) * 100) / 100;
  }

  addLine(): void { this.items.push(this.newItem()); }
  removeLine(i: number): void { if (this.items.length > 1) this.items.removeAt(i); }

  ngOnInit(): void {
    this.admin.departments().subscribe(d => this.departments = d);
    this.admin.costCentres().subscribe(c => this.costCentres = c);
    if (!this.id) return;
    this.loading = true;
    this.service.get(this.id).subscribe({
      next: r => {
        this.rowVersion = r.rowVersion;
        this.form.patchValue({ title: r.title, departmentId: r.departmentId ?? '', costCentreId: r.costCentreId ?? '', requiredDate: (r.requiredDate ?? '').substring(0, 10),
          priority: r.priority, justification: r.justification ?? '' });
        this.items.clear();
        for (const item of r.items) this.items.push(this.newItem(item));
        if (r.items.length === 0) this.items.push(this.newItem());
        this.loading = false;
      },
      error: err => { this.loading = false; this.toast.error(err); }
    });
  }

  private body(): any { return { ...this.form.getRawValue(), rowVersion: this.rowVersion ?? undefined }; }

  // Saves the draft; with submit = true it also sends it for approval.
  save(submit: boolean): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); this.toast.error({ error: { detail: 'Please fill in the required fields.' } }); return; }
    this.saving = true;
    const call = this.id ? this.service.update(this.id, this.body()) : this.service.create(this.body());
    call.subscribe({
      next: r => {
        if (!submit) { this.toast.success('Draft saved'); this.router.navigate(['/requisitions', r.id]); return; }
        this.service.submit(r.id).subscribe({
          next: () => { this.toast.success('Submitted for approval'); this.router.navigate(['/requisitions', r.id]); },
          error: e => { this.saving = false; this.toast.error(e); this.router.navigate(['/requisitions', r.id]); }
        });
      },
      error: err => { this.saving = false; this.toast.error(err); }
    });
  }

  invalid(name: string): boolean { const c = this.form.get(name); return !!c && c.touched && c.invalid; }
}
