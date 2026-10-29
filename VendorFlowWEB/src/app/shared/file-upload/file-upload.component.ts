import { ChangeDetectionStrategy, Component, EventEmitter, Input, Output } from '@angular/core';

/** Drag & drop (or browse) box. It only hands the chosen file to the parent, which decides where to upload it. */
@Component({
  changeDetection: ChangeDetectionStrategy.Eager,
  selector: 'app-file-upload',
  templateUrl: './file-upload.component.html',
  styleUrl: './file-upload.component.css'
})
export class FileUploadComponent {
  @Input() hint = 'PDF, JPG, PNG, XLSX · max 10 MB';
  @Input() accept = '.pdf,.jpg,.jpeg,.png,.xlsx,.csv';
  @Output() fileSelected = new EventEmitter<File>();

  dragging = false;
  error = '';

  onDrop(event: DragEvent): void {
    event.preventDefault();
    this.dragging = false;
    this.pick(event.dataTransfer?.files?.[0]);
  }

  onBrowse(event: Event): void {
    const input = event.target as HTMLInputElement;
    this.pick(input.files?.[0]);
    input.value = '';
  }

  // Checks the size here so the user gets a quick message; the API validates type and size again.
  private pick(file: File | undefined): void {
    this.error = '';
    if (!file) return;
    if (file.size > 10 * 1024 * 1024) { this.error = 'File is larger than 10 MB.'; return; }
    this.fileSelected.emit(file);
  }
}
