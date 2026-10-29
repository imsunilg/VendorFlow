import { ChangeDetectionStrategy, Component, Input } from '@angular/core';
import { LabelsPipe } from '../../core/pipes/labels.pipe';

/** Page title, a short description and action buttons (placed inside the tag). */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-page-header',
  imports: [LabelsPipe],
  templateUrl: './page-header.component.html',
  styleUrl: './page-header.component.css'
})
export class PageHeaderComponent {
  @Input() title = '';
  @Input() subtitle = '';
}
