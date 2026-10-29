import { ChangeDetectionStrategy, Component } from '@angular/core';

/** A small spinner shown while a page loads data. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-loading-spinner',
  templateUrl: './loading-spinner.component.html',
  styleUrl: './loading-spinner.component.css'
})
export class LoadingSpinnerComponent {}
