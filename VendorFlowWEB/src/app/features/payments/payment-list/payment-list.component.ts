import { ChangeDetectionStrategy, Component, OnInit, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute } from '@angular/router';
import { AuthService } from '../../../core/services/auth.service';
import { InvoiceService, PaymentService } from '../../../core/services/data.services';
import { ToastService } from '../../../core/services/toast.service';
import { newKey } from '../../../core/services/download.util';
import { TableColumn } from '../../../core/models/models';
import { MoneyPipe } from '../../../core/pipes/money.pipe';
import { DataTableComponent } from '../../../shared/data-table/data-table.component';
import { PageHeaderComponent } from '../../../shared/page-header/page-header.component';

@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-payment-list',
  imports: [ReactiveFormsModule, MoneyPipe, DataTableComponent, PageHeaderComponent],
  templateUrl: './payment-list.component.html',
  styleUrl: './payment-list.component.css'
})
export class PaymentListComponent implements OnInit {
  auth = inject(AuthService);
  private payments = inject(PaymentService);
  private invoices = inject(InvoiceService);
  private fb = inject(FormBuilder);
  private toast = inject(ToastService);
  private route = inject(ActivatedRoute);

  paymentColumns: TableColumn[] = [
    { key: 'number', label: 'Payment' },
    { key: 'invoiceNumber', label: 'Invoice', type: 'link' },
    { key: 'vendorName', label: 'Vendor' },
    { key: 'amount', label: 'Amount paid', type: 'money', align: 'right' },
    { key: 'balance', label: 'Balance', type: 'money', align: 'right' },
    { key: 'method', label: 'Method' },
    { key: 'reference', label: 'Reference' },
    { key: 'status', label: 'Status', type: 'status' }
  ];
  invoiceColumns: TableColumn[] = [
    { key: 'invoiceNumber', label: 'Invoice', type: 'link' },
    { key: 'vendorName', label: 'Vendor' },
    { key: 'dueDate', label: 'Due', type: 'date' },
    { key: 'daysOverdue', label: 'Days overdue', type: 'number' },
    { key: 'total', label: 'Total', type: 'money', align: 'right' },
    { key: 'balance', label: 'Balance', type: 'money', align: 'right' },
    { key: 'status', label: 'Status', type: 'status' }
  ];

  tab: 'payments' | 'outstanding' | 'overdue' = 'payments';
  summary: any = {};
  rows: any[] = [];
  total = 0;
  page = 1;
  loading = true;
  outstanding: any[] = [];        // invoices that can be paid (for the form)

  // One idempotency key per form submission: a double click or a retry can never post twice.
  key = newKey();
  busy = false;
  form = this.fb.nonNullable.group({
    invoiceId: ['', Validators.required],
    amount: [0, [Validators.required, Validators.min(0.01)]],
    method: ['NEFT', Validators.required],
    reference: [''],
    paidOn: [new Date().toISOString().substring(0, 10), Validators.required]
  });

  get selected(): any { return this.outstanding.find(i => i.id === this.form.value.invoiceId); }

  ngOnInit(): void {
    this.loadSummary();
    this.loadOutstanding();
    this.load();
  }

  loadSummary(): void { this.payments.summary().subscribe(s => this.summary = s); }

  // The form lists invoices that are reconciled and not fully paid.
  loadOutstanding(): void {
    this.invoices.list({ tab: 'outstanding', pageSize: 100, sortBy: 'due_date', sortDir: 'asc' }).subscribe(r => {
      this.outstanding = r.items;
      const wanted = this.route.snapshot.queryParamMap.get('invoiceId');
      if (wanted) this.pickInvoice(wanted);
    });
  }

  load(): void {
    this.loading = true;
    const call = this.tab === 'payments'
      ? this.payments.list({ page: this.page, pageSize: 10 })
      : this.invoices.list({ tab: this.tab, page: this.page, pageSize: 10, sortBy: 'due_date', sortDir: 'asc' });
    call.subscribe({
      next: r => { this.rows = r.items; this.total = r.totalCount; this.loading = false; },
      error: e => { this.loading = false; this.toast.error(e); }
    });
  }

  setTab(tab: 'payments' | 'outstanding' | 'overdue'): void { this.tab = tab; this.page = 1; this.load(); }
  onPage(p: number): void { this.page = p; this.load(); }

  // Choosing an invoice proposes its full balance as the amount.
  pickInvoice(id: string): void {
    this.form.patchValue({ invoiceId: id });
    const inv = this.outstanding.find(i => i.id === id);
    if (inv) this.form.patchValue({ amount: inv.balance });
  }

  record(): void {
    if (this.form.invalid) { this.form.markAllAsTouched(); return; }
    this.busy = true;
    this.payments.record(this.form.getRawValue(), this.key).subscribe({
      next: p => {
        this.busy = false;
        this.toast.success(`${p.number} recorded` + (p.replayed ? ' (already recorded)' : ''));
        this.key = newKey();                      // a new payment needs a new key
        this.form.patchValue({ invoiceId: '', amount: 0, reference: '' });
        this.loadSummary(); this.loadOutstanding(); this.load();
      },
      error: e => { this.busy = false; this.toast.error(e); }
    });
  }
}
