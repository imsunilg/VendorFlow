// Saves a Blob returned by the API (CSV, PDF, uploaded file) through the browser's download.
export function saveBlob(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = fileName;
  link.click();
  URL.revokeObjectURL(url);
}

// Opens a Blob (PDF or image) in a new browser tab.
export function openBlob(blob: Blob): void {
  const url = URL.createObjectURL(blob);
  window.open(url, '_blank');
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

// Makes a unique key for idempotent requests (payments).
export function newKey(): string {
  return crypto.randomUUID();
}
