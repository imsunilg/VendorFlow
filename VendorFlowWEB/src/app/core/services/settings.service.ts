import { Injectable, inject } from '@angular/core';
import { Title } from '@angular/platform-browser';
import { BehaviorSubject, Observable, tap } from 'rxjs';
import { ApiService } from './api.service';
import { Settings } from '../models/models';

const DEFAULTS: Settings = {
  appDisplayName: 'VendorFlow', organizationName: '', vendorLabelSingular: 'Vendor', vendorLabelPlural: 'Vendors', logoUrl: null,
  currency: 'INR', timeZone: 'Asia/Kolkata', taxSettings: {}, numbering: {}, notificationPrefs: {}, performanceWeights: {},
  invoiceTolerancePct: 2, allowSelfApproval: false
};

/**
 * Holds the organization's display name and vendor terminology.
 * Every page reads labels from here, so a change in Organization Settings shows up everywhere at once.
 */
@Injectable({ providedIn: 'root' })
export class SettingsService {
  private api = inject(ApiService);
  private title = inject(Title);

  private subject = new BehaviorSubject<Settings>(DEFAULTS);
  settings$ = this.subject.asObservable();

  get settings(): Settings { return this.subject.value; }
  get appName(): string { return this.settings.appDisplayName; }
  get vendor(): string { return this.settings.vendorLabelSingular; }
  get vendors(): string { return this.settings.vendorLabelPlural; }
  get currency(): string { return this.settings.currency; }

  // Loads the settings after login and sets the browser tab title.
  load(): Observable<Settings> {
    return this.api.get<Settings>('/organizations/current/settings').pipe(tap(s => this.apply(s)));
  }

  save(changes: Partial<Settings>): Observable<Settings> {
    return this.api.put<Settings>('/organizations/current/settings', changes).pipe(tap(s => this.apply(s)));
  }

  // Shows a preview before saving (the live preview in the settings page).
  preview(changes: Partial<Settings>): void {
    this.subject.next({ ...this.settings, ...changes });
  }

  reset(): void {
    this.subject.next(DEFAULTS);
    this.title.setTitle('VendorFlow');
  }

  private apply(s: Settings): void {
    this.subject.next(s);
    this.title.setTitle(s.appDisplayName);
  }
}
