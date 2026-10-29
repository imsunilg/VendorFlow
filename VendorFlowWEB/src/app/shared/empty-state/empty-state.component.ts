import { ChangeDetectionStrategy, Component, Input } from '@angular/core';

/** Friendly message shown when a list has no rows. Buttons can be placed inside the tag. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-empty-state',
  templateUrl: './empty-state.component.html',
  styleUrl: './empty-state.component.css'
})
export class EmptyStateComponent {
  @Input() message = 'Nothing to show yet.';
  @Input() icon = 'inbox';
}
