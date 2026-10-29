import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormArray, FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { RequisitionService, RfqService, VendorService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { LabelsPipe } from '../../../core/pipes/labels.pipe';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-rfq-form',
  imports: [ReactiveFormsModule, RouterLink, LabelsPipe, PageHeaderComponent],
  templateUrl: './rfq-form.component.html',
  styleUrl: './rfq-form.component.css'
})
export class RfqFormComponent implements OnInit {
  private fb = inject(FormBuilder);
  private rfqs = inject(RfqService);
  private vendorService = inject(VendorService);
  private requisitions = inject(RequisitionService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private toast = inject(ToastService);

  vendors: any[] = [];                 // approved vendors that can be invited
  approvedRequisitions: any[] = [];
  selectedVendors = new Set<string>();
  saving = false;

  form = this.fb.nonNullable.group({
    title: ['', [Validators.required, Validators.maxLength(200)]],
    requisitionId: [''],
    description: [''],
    deadline: ['', Validators.required],
    items: this.fb.array([this.newItem()])
  });

  get items(): FormArray { return this.form.controls.items; }

  newItem(item?: any) {
    return this.fb.nonNullable.group({
      description: [item?.description ?? '', Validators.required],
      unit: [item?.unit ?? 'Nos'],
      quantity: [item?.quantity ?? 1, [Validators.required, Validators.min(0.001)]]
    });
  }

  ngOnInit(): void {
    this.vendorService.list({ status: 'Approved', pageSize: 200, sortBy: 'name' }).subscribe(r => this.vendors = r.items);
    this.requisitions.list({ status: 'Approved', pageSize: 100 }).subscribe(r => this.approvedRequisitions = r.items);
    const requisitionId = this.route.snapshot.queryParamMap.get('requisitionId');
    if (requisitionId) { this.form.patchValue({ requisitionId }); this.loadRequisition(requisitionId); }
  }

  // Copies the title and items of the chosen requisition into the form.
  loadRequisition(id: string): void {
    if (!id) return;
    this.requisitions.get(id).subscribe(r => {
      this.form.patchValue({ title: r.title });
      this.items.clear();
      for (const item of r.items) this.items.push(this.newItem(item));
    });
  }

  onRequisitionChange(id: string): void { this.form.patchValue({ requisitionId: id }); this.loadRequisition(id); }
  addLine(): void { this.items.push(this.newItem()); }
  removeLine(i: number): void { if (this.items.length > 1) this.items.removeAt(i); }

  toggleVendor(id: string, checked: boolean): void { if (checked) this.selectedVendors.add(id); else this.selectedVendors.delete(id); }

  // Saves the RFQ as a draft; it is opened (invitations are created) from its detail page.
  save(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    if (this.selectedVendors.size === 0) { this.toast.error({ error: { detail: 'Choose at least one vendor to invite.' } }); return; }
    this.saving = true;
    const value = this.form.getRawValue();
    const body = {
      title: value.title, description: value.description, requisitionId: value.requisitionId || null,
      deadline: new Date(value.deadline).toISOString(), items: value.items, vendorIds: [...this.selectedVendors]
    };
    this.rfqs.create(body).subscribe({
      next: r => { this.toast.success('RFQ saved as draft'); this.router.navigate(['/rfqs', r.id]); },
      error: e => { this.saving = false; this.toast.error(e); }
    });
  }

  invalid(name: string): boolean { const c = this.form.get(name); return !!c && c.touched && c.invalid; }
}
