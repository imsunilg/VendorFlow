import { Pipe, PipeTransform, inject } from '@angular/core';
import { SettingsService } from '../services/settings.service';

/** Formats an amount in the organization's currency, e.g. ₹6,20,000.00 (Indian digit grouping for INR). */
@Pipe({ name: 'money', pure: false })
export class MoneyPipe implements PipeTransform {
  private settings = inject(SettingsService);

  transform(value: number | string | null | undefined, decimals = 2): string {
    if (value === null || value === undefined || value === '') return '—';
    const locale = this.settings.currency === 'INR' ? 'en-IN' : 'en-US';
    return new Intl.NumberFormat(locale, {
      style: 'currency', currency: this.settings.currency, minimumFractionDigits: decimals, maximumFractionDigits: decimals
    }).format(Number(value));
  }
}

/** Short amounts for KPI cards: ₹4.82 Cr, ₹38.4 L, ₹84,000. */
@Pipe({ name: 'moneyShort', pure: false })
export class MoneyShortPipe implements PipeTransform {
  private settings = inject(SettingsService);

  transform(value: number | null | undefined): string {
    const n = Number(value ?? 0);
    const symbol = this.settings.currency === 'INR' ? '₹' : this.settings.currency + ' ';
    if (this.settings.currency !== 'INR') return symbol + n.toLocaleString('en-US', { maximumFractionDigits: 0 });
    if (n >= 10000000) return `${symbol}${(n / 10000000).toFixed(2)} Cr`;
    if (n >= 100000) return `${symbol}${(n / 100000).toFixed(1)} L`;
    return symbol + n.toLocaleString('en-IN', { maximumFractionDigits: 0 });
  }
}
