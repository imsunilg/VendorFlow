import { Pipe, PipeTransform, inject } from '@angular/core';
import { SettingsService } from '../services/settings.service';

/**
 * Replaces the word "Vendor"/"Vendors" in a text with the organization's own terminology.
 * Usage: {{ 'Add Vendor' | labels }}  gives  "Add Supplier" when the organization calls vendors suppliers.
 * The pipe is impure on purpose so the text updates the moment the settings change.
 */
@Pipe({ name: 'labels', pure: false })
export class LabelsPipe implements PipeTransform {
  private settings = inject(SettingsService);

  transform(text: string | null | undefined): string {
    if (!text) return '';
    const singular = this.settings.vendor;
    const plural = this.settings.vendors;
    return text
      .replace(/Vendors/g, plural).replace(/vendors/g, plural.toLowerCase()).replace(/VENDORS/g, plural.toUpperCase())
      .replace(/Vendor/g, singular).replace(/vendor/g, singular.toLowerCase()).replace(/VENDOR/g, singular.toUpperCase());
  }
}
