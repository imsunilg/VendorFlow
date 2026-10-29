import { ChangeDetectionStrategy, Component, Input } from '@angular/core';
import { DateFormatPipe } from '../../core/pipes/date-format.pipe';

/**
 * Shows the approval steps (for example Team Lead → Dept Manager → Finance).
 * layout "row" is used on approval cards, "column" on detail pages with comments.
 */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-approval-timeline',
  imports: [DateFormatPipe],
  templateUrl: './approval-timeline.component.html',
  styleUrl: './approval-timeline.component.css'
})
export class ApprovalTimelineComponent {
  @Input() steps: any[] = [];
  @Input() layout: 'row' | 'column' = 'column';

  // A step is done when approved, current when it is the one waiting, otherwise upcoming.
  state(step: any): string {
    if (step.status === 'Approved') return 'done';
    if (step.status === 'Rejected') return 'bad';
    if (step.status === 'Returned') return 'info';
    if (step.status === 'Pending') return 'current';
    return 'waiting';
  }
}
