import { ChangeDetectionStrategy, Component, Input } from '@angular/core';

// Colour for each status name used by the API.
const COLORS: Record<string, string> = {
  Approved: 'green', Active: 'green', Valid: 'green', Paid: 'green', Posted: 'green', Matched: 'green', Low: 'green', Submitted: 'green',
  FullyReceived: 'green', Received: 'green', Awarded: 'green',
  Pending: 'amber', PendingApproval: 'amber', Waiting: 'amber', Medium: 'amber', Expiring: 'amber', PartiallyPaid: 'amber', PartiallyReceived: 'amber',
  NeedsReview: 'amber', Invited: 'amber', Open: 'blue', Viewed: 'blue', Partial: 'amber',
  Rejected: 'red', Suspended: 'red', Expired: 'red', Overdue: 'red', High: 'red', Disputed: 'red', Cancelled: 'red', Failed: 'red', Declined: 'red', Mismatch: 'red',
  Issued: 'blue', Returned: 'blue', ReturnedForModification: 'blue', Registered: 'blue', Match: 'green',
  ConvertedToPO: 'indigo', Closed: 'indigo', OnHold: 'grey',
  Draft: 'grey', Disabled: 'grey'
};

/** A coloured pill for a status text such as "PendingApproval" (shown as "Pending approval"). */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-status-badge',
  templateUrl: './status-badge.component.html',
  styleUrl: './status-badge.component.css'
})
export class StatusBadgeComponent {
  @Input() status: string | null | undefined = '';
  @Input() label: string | null = null;

  get color(): string { return COLORS[this.status ?? ''] ?? 'grey'; }

  // "PendingApproval" -> "Pending approval", "ConvertedToPO" -> "Converted to PO"
  get text(): string {
    if (this.label) return this.label;
    const spaced = (this.status ?? '').replace(/([a-z])([A-Z])/g, '$1 $2').replace(/To PO/, 'to PO');
    return spaced.charAt(0) + spaced.slice(1).toLowerCase().replace(/po$/, 'PO');
  }
}
