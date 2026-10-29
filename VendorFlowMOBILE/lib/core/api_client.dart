import 'package:dio/dio.dart';
import 'config.dart';
import 'token_store.dart';

/// Talks to the VendorFlow API. Adds the access token to every call and, when the server answers 401,
/// tries one refresh and repeats the call. If the refresh fails the session is cleared (onSessionExpired).
class ApiClient {
  ApiClient(this._store, {this.onSessionExpired, Dio? dio, String? baseUrl})
      : _dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl ?? apiBase, connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 30))) {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: _addToken, onError: _refreshOn401));
  }

  final TokenStore _store;
  final Dio _dio;
  final void Function()? onSessionExpired;

  Future<void> _addToken(RequestOptions options, RequestInterceptorHandler handler) async {
    final token = await _store.readAccess();
    if (token != null && options.extra['skipAuth'] != true) options.headers['Authorization'] = 'Bearer $token';
    handler.next(options);
  }

  Future<void> _refreshOn401(DioException error, ErrorInterceptorHandler handler) async {
    final request = error.requestOptions;
    final refresh = await _store.readRefresh();
    if (error.response?.statusCode != 401 || request.extra['skipAuth'] == true || request.extra['retried'] == true || refresh == null) {
      return handler.next(error);
    }
    try {
      final res = await _dio.post('/auth/refresh', data: {'refreshToken': refresh}, options: Options(extra: {'skipAuth': true}));
      await _saveSession(res.data as Map<String, dynamic>);
      request.extra['retried'] = true;
      request.headers['Authorization'] = 'Bearer ${await _store.readAccess()}';
      handler.resolve(await _dio.fetch(request));
    } catch (_) {
      await _store.clear();
      onSessionExpired?.call();
      handler.next(error);
    }
  }

  Future<void> _saveSession(Map<String, dynamic> body) => _store.save(
      access: body['accessToken'] as String, refresh: body['refreshToken'] as String, user: Map<String, dynamic>.from(body['user'] as Map));

  // ---- authentication

  Future<Map<String, dynamic>> login(String email, String password) async {
    final res = await _dio.post('/auth/login', data: {'email': email, 'password': password}, options: Options(extra: {'skipAuth': true}));
    final body = res.data as Map<String, dynamic>;
    await _saveSession(body);
    return body;
  }

  Future<void> logout() async {
    try {
      await _dio.post('/auth/logout');
    } catch (_) {/* the local session is cleared anyway */}
    await _store.clear();
  }

  // ---- generic calls (the API answers with JSON objects or lists)

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async => (await _dio.get(path, queryParameters: query)).data;

  Future<dynamic> post(String path, {Object? body, Map<String, String>? headers}) async =>
      (await _dio.post(path, data: body ?? <String, dynamic>{}, options: Options(headers: headers))).data;

  Future<dynamic> upload(String path, FormData form) async => (await _dio.post(path, data: form)).data;
}

/// Turns a failed call into text for the user (the API sends a "detail" message).
String apiMessage(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && (data['detail'] ?? data['title']) != null) return (data['detail'] ?? data['title']).toString();
    if (error.type == DioExceptionType.connectionError || error.type == DioExceptionType.connectionTimeout) {
      return 'Cannot reach the server. Check your connection.';
    }
    if (error.response?.statusCode == 401) return 'Email or password is wrong.';
  }
  return 'Something went wrong. Please try again.';
}
