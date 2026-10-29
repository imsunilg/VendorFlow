import { Injectable, inject } from '@angular/core';
import { MatSnackBar } from '@angular/material/snack-bar';

/** Small messages at the bottom of the screen. */
@Injectable({ providedIn: 'root' })
export class ToastService {
  private snack = inject(MatSnackBar);

  success(message: string): void {
    this.snack.open(message, 'OK', { duration: 3500 });
  }

  // Shows the API's error text (the "detail" field) or a short fallback.
  error(err: any, fallback = 'Something went wrong.'): void {
    const message = err?.error?.detail || err?.error?.title || fallback;
    this.snack.open(message, 'Close', { duration: 6000 });
  }
}
