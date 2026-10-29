import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { Observable } from 'rxjs';
import { environment } from '../../../environments/environment';

/** Thin wrapper around HttpClient: adds the API base url and turns an object into query parameters. */
@Injectable({ providedIn: 'root' })
export class ApiService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  // Builds query params and skips empty values.
  private toParams(params?: Record<string, any>): HttpParams {
    let result = new HttpParams();
    for (const key of Object.keys(params ?? {})) {
      const value = params![key];
      if (value !== null && value !== undefined && value !== '') result = result.set(key, String(value));
    }
    return result;
  }

  get<T = any>(path: string, params?: Record<string, any>): Observable<T> {
    return this.http.get<T>(this.base + path, { params: this.toParams(params) });
  }

  post<T = any>(path: string, body: any = {}, headers?: Record<string, string>): Observable<T> {
    return this.http.post<T>(this.base + path, body, { headers: new HttpHeaders(headers ?? {}) });
  }

  put<T = any>(path: string, body: any = {}): Observable<T> {
    return this.http.put<T>(this.base + path, body);
  }

  delete<T = any>(path: string): Observable<T> {
    return this.http.delete<T>(this.base + path);
  }

  upload<T = any>(path: string, form: FormData): Observable<T> {
    return this.http.post<T>(this.base + path, form);
  }

  blob(path: string, params?: Record<string, any>): Observable<Blob> {
    return this.http.get(this.base + path, { params: this.toParams(params), responseType: 'blob' });
  }
}
