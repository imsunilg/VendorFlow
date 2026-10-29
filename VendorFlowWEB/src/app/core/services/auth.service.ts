import { Injectable, inject } from '@angular/core';
import { Router } from '@angular/router';
import { BehaviorSubject, Observable, tap } from 'rxjs';
import { ApiService } from './api.service';
import { AuthUser, LoginResponse } from '../models/models';

const TOKEN_KEY = 'vf_tokens';
const USER_KEY = 'vf_user';

/** Keeps the signed-in user and tokens. Tokens live in localStorage so a refresh of the page keeps the session. */
@Injectable({ providedIn: 'root' })
export class AuthService {
  private api = inject(ApiService);
  private router = inject(Router);

  private userSubject = new BehaviorSubject<AuthUser | null>(this.readUser());
  user$ = this.userSubject.asObservable();

  get user(): AuthUser | null { return this.userSubject.value; }
  get isLoggedIn(): boolean { return !!this.accessToken; }
  get accessToken(): string | null { return this.readTokens()?.accessToken ?? null; }
  get refreshToken(): string | null { return this.readTokens()?.refreshToken ?? null; }

  // Checks a permission code such as "vendors.view".
  has(permission: string): boolean {
    return !!this.user?.permissions.includes(permission);
  }

  login(email: string, password: string): Observable<LoginResponse> {
    return this.api.post<LoginResponse>('/auth/login', { email, password }).pipe(tap(r => this.store(r)));
  }

  registerOrganization(body: any): Observable<LoginResponse> {
    return this.api.post<LoginResponse>('/auth/register-organization', body).pipe(tap(r => this.store(r)));
  }

  // Exchanges the refresh token for a new pair. Used by the HTTP interceptor on a 401.
  refresh(): Observable<LoginResponse> {
    return this.api.post<LoginResponse>('/auth/refresh', { refreshToken: this.refreshToken }).pipe(tap(r => this.store(r)));
  }

  logout(callApi = true): void {
    if (callApi && this.isLoggedIn) this.api.post('/auth/logout').subscribe({ error: () => {} });
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(USER_KEY);
    this.userSubject.next(null);
    this.router.navigate(['/login']);
  }

  private store(r: LoginResponse): void {
    localStorage.setItem(TOKEN_KEY, JSON.stringify({ accessToken: r.accessToken, refreshToken: r.refreshToken }));
    localStorage.setItem(USER_KEY, JSON.stringify(r.user));
    this.userSubject.next(r.user);
  }

  private readTokens(): { accessToken: string; refreshToken: string } | null {
    try { return JSON.parse(localStorage.getItem(TOKEN_KEY) ?? 'null'); } catch { return null; }
  }

  private readUser(): AuthUser | null {
    try { return JSON.parse(localStorage.getItem(USER_KEY) ?? 'null'); } catch { return null; }
  }
}
