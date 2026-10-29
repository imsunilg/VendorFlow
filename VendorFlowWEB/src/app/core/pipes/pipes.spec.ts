import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { LabelsPipe } from './labels.pipe';
import { MoneyPipe, MoneyShortPipe } from './money.pipe';
import { DateFormatPipe } from './date-format.pipe';
import { SettingsService } from '../services/settings.service';

describe('pipes', () => {
  let settings: SettingsService;

  beforeEach(() => {
    TestBed.configureTestingModule({ providers: [provideHttpClient()] });
    settings = TestBed.inject(SettingsService);
  });

  it('labels pipe keeps "Vendor" by default', () => {
    const pipe = TestBed.runInInjectionContext(() => new LabelsPipe());
    expect(pipe.transform('Add Vendor')).toBe('Add Vendor');
    expect(pipe.transform('Vendors')).toBe('Vendors');
  });

  it('labels pipe uses the organization terminology and keeps the letter case', () => {
    settings.preview({ vendorLabelSingular: 'Supplier', vendorLabelPlural: 'Suppliers' });
    const pipe = TestBed.runInInjectionContext(() => new LabelsPipe());
    expect(pipe.transform('Add Vendor')).toBe('Add Supplier');
    expect(pipe.transform('Onboard your vendors.')).toBe('Onboard your suppliers.');
    expect(pipe.transform('Search vendors, POs')).toBe('Search suppliers, POs');
    expect(pipe.transform('')).toBe('');
    expect(pipe.transform(null)).toBe('');
  });

  it('money pipe formats Indian digit grouping for INR', () => {
    const pipe = TestBed.runInInjectionContext(() => new MoneyPipe());
    expect(pipe.transform(620000)).toContain('6,20,000.00');
    expect(pipe.transform(null)).toBe('—');
    expect(pipe.transform(1234.5, 0)).toContain('1,235');
  });

  it('moneyShort pipe shows Cr and L', () => {
    const pipe = TestBed.runInInjectionContext(() => new MoneyShortPipe());
    expect(pipe.transform(48200000)).toBe('₹4.82 Cr');
    expect(pipe.transform(3840000)).toBe('₹38.4 L');
    expect(pipe.transform(84000)).toContain('84,000');
  });

  it('date pipe formats dates and handles empty values', () => {
    const pipe = new DateFormatPipe();
    expect(pipe.transform('2026-11-10')).toMatch(/10 Nov 2026/);
    expect(pipe.transform(null)).toBe('—');
    expect(pipe.transform('not a date')).toBe('not a date');
  });
});
