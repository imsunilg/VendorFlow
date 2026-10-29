import { CanActivateFn, Router } from '@angular/router';
import { inject } from '@angular/core';
import { AuthService } from '../services/auth.service';

// Opens a page only when the user holds the permission named in the route data (the API checks it again).
export const permissionGuard: CanActivateFn = (route) => {
  const auth = inject(AuthService);
  const router = inject(Router);
  const permission = route.data['permission'] as string | undefined;
  return !permission || auth.has(permission) ? true : router.createUrlTree(['/']);
};
