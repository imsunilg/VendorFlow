import { ChangeDetectionStrategy, Component, Injectable, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialog, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { Observable, filter, map } from 'rxjs';

export interface ConfirmOptions {
  title: string;
  message?: string;
  confirmText?: string;
  danger?: boolean;
  commentLabel?: string;        // when set, a text box is shown
  commentRequired?: boolean;
}

/** Yes/No dialog, optionally with a comment box (used for reject / cancel reasons). */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-confirm-dialog',
  imports: [MatDialogModule, FormsModule],
  templateUrl: './confirm-dialog.component.html',
  styleUrl: './confirm-dialog.component.css'
})
export class ConfirmDialogComponent {
  data = inject<ConfirmOptions>(MAT_DIALOG_DATA);
  private ref = inject(MatDialogRef<ConfirmDialogComponent>);
  comment = '';

  get canConfirm(): boolean { return !this.data.commentRequired || this.comment.trim().length > 0; }

  confirm(): void { this.ref.close({ comment: this.comment.trim() }); }
  cancel(): void { this.ref.close(null); }
}

/** Opens the dialog and gives back the typed comment (empty string when none) only if the user confirmed. */
@Injectable({ providedIn: 'root' })
export class ConfirmService {
  private dialog = inject(MatDialog);

  ask(options: ConfirmOptions): Observable<string> {
    return this.dialog.open(ConfirmDialogComponent, { data: options, width: '440px' }).afterClosed().pipe(
      filter(result => !!result),
      map(result => result.comment as string)
    );
  }
}
