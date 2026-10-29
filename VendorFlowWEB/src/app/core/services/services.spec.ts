import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { Router, provideRouter } from '@angular/router';
import { AuthService } from './auth.service';
import { SettingsService } from './settings.service';
import { ToastService } from './toast.service';
import { authGuard } from '../guards/auth.guard';
import { permissionGuard } from '../guards/permission.guard';
import { environment } from '../../../environments/environment';

const LOGIN = {
  accessToken: 'a', refreshToken: 'r', expiresAt: '2030-01-01',
  user: { userId: '1', tenantId: 't', email: 'x@y.z', fullName: 'Test User', roles: ['Auditor'], permissions: ['vendors.view'] }
};

describe('services and guards', () => {
  let http: HttpTestingController;

  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({ providers: [provideHttpClient(), provideHttpClientTesting(), provideRouter([])] });
    http = TestBed.inject(HttpTestingController);
  });

  it('auth service stores the session after login and checks permissions', () => {
    const auth = TestBed.inject(AuthService);
    expect(auth.isLoggedIn).toBe(false);
    auth.login('x@y.z', 'pw').subscribe();
    http.expectOne(environment.apiUrl + '/auth/login').flush(LOGIN);
    expect(auth.isLoggedIn).toBe(true);
    expect(auth.user?.fullName).toBe('Test User');
    expect(auth.has('vendors.view')).toBe(true);
    expect(auth.has('settings.manage')).toBe(false);
  });

  it('auth guard sends anonymous users to the login page', () => {
    const router = TestBed.inject(Router);
    const result = TestBed.runInInjectionContext(() => authGuard({} as any, {} as any));
    expect(router.serializeUrl(result as any)).toBe('/login');
  });

  it('permission guard allows pages without a permission and blocks missing ones', () => {
    const auth = TestBed.inject(AuthService);
    auth.login('x@y.z', 'pw').subscribe();
    http.expectOne(environment.apiUrl + '/auth/login').flush(LOGIN);
    const router = TestBed.inject(Router);
    expect(TestBed.runInInjectionContext(() => permissionGuard({ data: {} } as any, {} as any))).toBe(true);
    expect(TestBed.runInInjectionContext(() => permissionGuard({ data: { permission: 'vendors.view' } } as any, {} as any))).toBe(true);
    const blocked = TestBed.runInInjectionContext(() => permissionGuard({ data: { permission: 'users.manage' } } as any, {} as any));
    expect(router.serializeUrl(blocked as any)).toBe('/');
  });

  it('settings service loads the labels and exposes them', () => {
    const settings = TestBed.inject(SettingsService);
    expect(settings.vendors).toBe('Vendors');
    settings.load().subscribe();
    http.expectOne(environment.apiUrl + '/organizations/current/settings').flush({
      appDisplayName: 'Acme Procure', organizationName: 'Acme', vendorLabelSingular: 'Supplier', vendorLabelPlural: 'Suppliers',
      currency: 'INR', taxSettings: {}, numbering: {}, notificationPrefs: {}, performanceWeights: {}, invoiceTolerancePct: 2, allowSelfApproval: false
    });
    expect(settings.appName).toBe('Acme Procure');
    expect(settings.vendor).toBe('Supplier');
    expect(document.title).toBe('Acme Procure');
    settings.reset();
    expect(settings.vendors).toBe('Vendors');
  });

  it('toast service builds messages from API errors', () => {
    const toast = TestBed.inject(ToastService);
    expect(() => toast.error({ error: { detail: 'Duplicate invoice' } })).not.toThrow();
    expect(() => toast.error(null)).not.toThrow();
  });
});
