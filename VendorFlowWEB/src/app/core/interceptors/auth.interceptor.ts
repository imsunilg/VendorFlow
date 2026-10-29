import { HttpErrorResponse, HttpInterceptorFn, HttpRequest } from '@angular/common/http';
import { inject } from '@angular/core';
import { catchError, switchMap, throwError } from 'rxjs';
import { AuthService } from '../services/auth.service';

// Adds the token to API calls. On a 401 it tries one refresh and repeats the call; if that fails the user is signed out.
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const auth = inject(AuthService);
  const isAuthCall = req.url.includes('/auth/login') || req.url.includes('/auth/refresh') || req.url.includes('/portal/');

  const withToken = (r: HttpRequest<unknown>) =>
    auth.accessToken && !isAuthCall ? r.clone({ setHeaders: { Authorization: `Bearer ${auth.accessToken}` } }) : r;

  return next(withToken(req)).pipe(
    catchError((error: HttpErrorResponse) => {
      if (error.status !== 401 || isAuthCall || !auth.refreshToken) return throwError(() => error);
      return auth.refresh().pipe(
        switchMap(() => next(withToken(req))),
        catchError(refreshError => {
          auth.logout(false);
          return throwError(() => refreshError);
        })
      );
    })
  );
};
