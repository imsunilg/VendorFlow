import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import { ApiService } from './api.service';
import { PagedResult } from '../models/models';

// One small service per area. Each method is a single API call; list methods take the same query object
// (page, pageSize, sortBy, sortDir, search + filters) and return { items, totalCount, ... }.

@Injectable({ providedIn: 'root' })
export class VendorService {
  private api = inject(ApiService);
  list(q: any): Observable<PagedResult> { return this.api.get('/vendors', q); }
  get(id: string): Observable<any> { return this.api.get(`/vendors/${id}`); }
  categories(): Observable<string[]> { return this.api.get('/vendors/categories'); }
  create(body: any): Observable<any> { return this.api.post('/vendors', body); }
  update(id: string, body: any): Observable<any> { return this.api.put(`/vendors/${id}`, body); }
  transition(id: string, action: string, comment?: string): Observable<any> { return this.api.post(`/vendors/${id}/${action}`, { comment }); }
  saveContact(id: string, body: any): Observable<any> { return this.api.post(`/vendors/${id}/contacts`, body); }
  deleteContact(id: string, contactId: string): Observable<any> { return this.api.delete(`/vendors/${id}/contacts/${contactId}`); }
  saveAddress(id: string, body: any): Observable<any> { return this.api.post(`/vendors/${id}/addresses`, body); }
  deleteAddress(id: string, addressId: string): Observable<any> { return this.api.delete(`/vendors/${id}/addresses/${addressId}`); }
  saveDocument(id: string, form: FormData): Observable<any> { return this.api.upload(`/vendors/${id}/documents`, form); }
  deleteDocument(id: string, docId: string): Observable<any> { return this.api.delete(`/vendors/${id}/documents/${docId}`); }
  documentFile(id: string, docId: string): Observable<Blob> { return this.api.blob(`/vendors/${id}/documents/${docId}/file`); }
  bank(id: string): Observable<any> { return this.api.get(`/vendors/${id}/bank`); }
  saveBank(id: string, body: any): Observable<any> { return this.api.put(`/vendors/${id}/bank`, body); }
  performance(id: string): Observable<any> { return this.api.get(`/vendors/${id}/performance`); }
  history(id: string): Observable<any[]> { return this.api.get(`/vendors/${id}/history`); }
  export(q: any): Observable<Blob> { return this.api.blob('/vendors/export', q); }
}

@Injectable({ providedIn: 'root' })
export class RequisitionService {
  private api = inject(ApiService);
  list(q: any): Observable<PagedResult> { return this.api.get('/requisitions', q); }
  get(id: string): Observable<any> { return this.api.get(`/requisitions/${id}`); }
  create(body: any): Observable<any> { return this.api.post('/requisitions', body); }
  update(id: string, body: any): Observable<any> { return this.api.put(`/requisitions/${id}`, body); }
  submit(id: string): Observable<any> { return this.api.post(`/requisitions/${id}/submit`); }
  cancel(id: string, comment: string): Observable<any> { return this.api.post(`/requisitions/${id}/cancel`, { comment }); }
  export(q: any): Observable<Blob> { return this.api.blob('/requisitions/export', q); }
}

@Injectable({ providedIn: 'root' })
export class ApprovalService {
  private api = inject(ApiService);
  inbox(q: any): Observable<PagedResult> { return this.api.get('/approvals', q); }
  pendingCount(): Observable<{ count: number }> { return this.api.get('/approvals/pending-count'); }
  decide(id: string, action: 'approve' | 'reject' | 'request-changes', comment: string, expectedVersion?: number): Observable<any> {
    return this.api.post(`/approvals/${id}/${action}`, { comment, expectedVersion });
  }
  rules(): Observable<any[]> { return this.api.get('/approval-rules'); }
  saveRule(body: any): Observable<any[]> { return this.api.post('/approval-rules', body); }
  deleteRule(id: string): Observable<any[]> { return this.api.delete(`/approval-rules/${id}`); }
  delegations(): Observable<any[]> { return this.api.get('/delegations'); }
  createDelegation(body: any): Observable<any[]> { return this.api.post('/delegations', body); }
  cancelDelegation(id: string): Observable<any[]> { return this.api.delete(`/delegations/${id}`); }
  departments(): Observable<any[]> { return this.api.get('/departments'); }
  setManager(departmentId: string, userId: string | null): Observable<any[]> { return this.api.put(`/departments/${departmentId}/manager`, { userId }); }
}

@Injectable({ providedIn: 'root' })
export class RfqService {
  private api = inject(ApiService);
  list(q: any): Observable<PagedResult> { return this.api.get('/rfqs', q); }
  get(id: string): Observable<any> { return this.api.get(`/rfqs/${id}`); }
  create(body: any): Observable<any> { return this.api.post('/rfqs', body); }
  update(id: string, body: any): Observable<any> { return this.api.put(`/rfqs/${id}`, body); }
  open(id: string): Observable<any> { return this.api.post(`/rfqs/${id}/open`); }
  close(id: string): Observable<any> { return this.api.post(`/rfqs/${id}/close`); }
  cancel(id: string, comment: string): Observable<any> { return this.api.post(`/rfqs/${id}/cancel`, { comment }); }
  reopen(id: string, deadline: string): Observable<any> { return this.api.post(`/rfqs/${id}/reopen`, { deadline }); }
  reminders(id: string): Observable<any> { return this.api.post(`/rfqs/${id}/reminders`); }
  invite(id: string, vendorId: string): Observable<any> { return this.api.post(`/rfqs/${id}/vendors/${vendorId}/invite`); }
  enterQuotation(id: string, vendorId: string, body: any): Observable<any> { return this.api.post(`/rfqs/${id}/vendors/${vendorId}/quotation`, body); }
  answer(clarificationId: string, answer: string): Observable<any> { return this.api.post(`/rfqs/clarifications/${clarificationId}/answer`, { answer }); }
  compare(id: string): Observable<any> { return this.api.get(`/rfqs/${id}/compare`); }
  recommend(id: string, vendorId: string, justification: string): Observable<any> { return this.api.post(`/rfqs/${id}/recommendation`, { vendorId, justification }); }
  // Vendor portal (no login, secret token in the link)
  portal(token: string): Observable<any> { return this.api.get(`/portal/rfq/${token}`); }
  portalQuote(token: string, body: any): Observable<any> { return this.api.post(`/portal/rfq/${token}/quotation`, body); }
  portalAsk(token: string, question: string): Observable<any> { return this.api.post(`/portal/rfq/${token}/clarifications`, { question }); }
  portalDecline(token: string): Observable<any> { return this.api.post(`/portal/rfq/${token}/decline`); }
}

@Injectable({ providedIn: 'root' })
export class PurchaseOrderService {
  private api = inject(ApiService);
  list(q: any): Observable<PagedResult> { return this.api.get('/purchase-orders', q); }
  get(id: string): Observable<any> { return this.api.get(`/purchase-orders/${id}`); }
  create(body: any): Observable<any> { return this.api.post('/purchase-orders', body); }
  fromRequisition(requisitionId: string, body: any): Observable<any> { return this.api.post(`/purchase-orders/from-requisition/${requisitionId}`, body); }
  fromRfq(rfqId: string, body: any = {}): Observable<any> { return this.api.post(`/purchase-orders/from-rfq/${rfqId}`, body); }
  update(id: string, body: any): Observable<any> { return this.api.put(`/purchase-orders/${id}`, body); }
  action(id: string, action: string, comment?: string): Observable<any> { return this.api.post(`/purchase-orders/${id}/${action}`, { comment }); }
  revise(id: string, reason: string): Observable<any> { return this.api.post(`/purchase-orders/${id}/revisions`, { comment: reason }); }
  pdf(id: string): Observable<Blob> { return this.api.blob(`/purchase-orders/${id}/pdf`); }
  export(q: any): Observable<Blob> { return this.api.blob('/purchase-orders/export', q); }
}

@Injectable({ providedIn: 'root' })
export class GoodsReceiptService {
  private api = inject(ApiService);
  list(q: any): Observable<PagedResult> { return this.api.get('/goods-receipts', q); }
  get(id: string): Observable<any> { return this.api.get(`/goods-receipts/${id}`); }
  post(poId: string, body: any): Observable<any> { return this.api.post(`/purchase-orders/${poId}/receipts`, body); }
  cancel(id: string, comment: string): Observable<any> { return this.api.post(`/goods-receipts/${id}/cancel`, { comment }); }
}

@Injectable({ providedIn: 'root' })
export class InvoiceService {
  private api = inject(ApiService);
  list(q: any): Observable<PagedResult> { return this.api.get('/invoices', q); }
  get(id: string): Observable<any> { return this.api.get(`/invoices/${id}`); }
  register(body: any): Observable<any> { return this.api.post('/invoices', body); }
  update(id: string, body: any): Observable<any> { return this.api.put(`/invoices/${id}`, body); }
  rematch(id: string): Observable<any> { return this.api.post(`/invoices/${id}/rematch`); }
  dispute(id: string, message: string): Observable<any> { return this.api.post(`/invoices/${id}/discrepancies`, { comment: message }); }
  reconcile(id: string, comment?: string): Observable<any> { return this.api.post(`/invoices/${id}/reconcile`, { comment }); }
  cancel(id: string, comment: string): Observable<any> { return this.api.post(`/invoices/${id}/cancel`, { comment }); }
  export(q: any): Observable<Blob> { return this.api.blob('/invoices/export', q); }
}

@Injectable({ providedIn: 'root' })
export class PaymentService {
  private api = inject(ApiService);
  list(q: any): Observable<PagedResult> { return this.api.get('/payments', q); }
  summary(): Observable<any> { return this.api.get('/payments/summary'); }
  // The idempotency key makes a double click or a retry safe: the same key never posts twice.
  record(body: any, idempotencyKey: string): Observable<any> { return this.api.post('/payments', body, { 'Idempotency-Key': idempotencyKey }); }
}

@Injectable({ providedIn: 'root' })
export class ReportService {
  private api = inject(ApiService);
  dashboard(): Observable<any> { return this.api.get('/dashboard'); }
  catalog(): Observable<any[]> { return this.api.get('/reports'); }
  run(name: string, q: any): Observable<any> { return this.api.get(`/reports/${name}`, q); }
  export(name: string, q: any): Observable<Blob> { return this.api.blob(`/reports/${name}/export`, q); }
}

@Injectable({ providedIn: 'root' })
export class AdminService {
  private api = inject(ApiService);
  users(q: any): Observable<PagedResult> { return this.api.get('/users', q); }
  roles(): Observable<any[]> { return this.api.get('/roles'); }
  invite(body: any): Observable<any> { return this.api.post('/users/invite', body); }
  setRoles(id: string, roles: string[]): Observable<any> { return this.api.put(`/users/${id}/roles`, { roles }); }
  setStatus(id: string, status: string): Observable<any> { return this.api.put(`/users/${id}/status`, { status }); }
  audit(q: any): Observable<PagedResult> { return this.api.get('/audit', q); }
  departments(): Observable<any[]> { return this.api.get('/lookups/departments'); }
  costCentres(): Observable<any[]> { return this.api.get('/lookups/cost-centres'); }
  userLookup(): Observable<any[]> { return this.api.get('/lookups/users'); }
  notifications(q: any): Observable<any> { return this.api.get('/notifications', q); }
  markRead(id: string): Observable<any> { return this.api.post(`/notifications/${id}/read`); }
  markAllRead(): Observable<any> { return this.api.post('/notifications/read-all'); }
  runChecks(): Observable<any> { return this.api.post('/notifications/run-checks'); }
  attachments(entityType: string, id: string): Observable<any[]> { return this.api.get(`/attachments/${entityType}/${id}`); }
  upload(entityType: string, id: string, file: File): Observable<any> {
    const form = new FormData();
    form.append('file', file);
    return this.api.upload(`/attachments/${entityType}/${id}`, form);
  }
  attachmentFile(id: string): Observable<Blob> { return this.api.blob(`/attachments/${id}/file`); }
  deleteAttachment(id: string): Observable<any> { return this.api.delete(`/attachments/${id}`); }
}
