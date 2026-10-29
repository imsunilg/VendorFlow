import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the session is kept. The real app uses the phone's secure storage (Keystore / Keychain).
abstract class TokenStore {
  Future<String?> readAccess();
  Future<String?> readRefresh();
  Future<Map<String, dynamic>?> readUser();
  Future<void> save({required String access, required String refresh, required Map<String, dynamic> user});
  Future<void> clear();
}

class SecureTokenStore implements TokenStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<String?> readAccess() => _storage.read(key: 'access');

  @override
  Future<String?> readRefresh() => _storage.read(key: 'refresh');

  @override
  Future<Map<String, dynamic>?> readUser() async {
    final text = await _storage.read(key: 'user');
    return text == null ? null : jsonDecode(text) as Map<String, dynamic>;
  }

  @override
  Future<void> save({required String access, required String refresh, required Map<String, dynamic> user}) async {
    await _storage.write(key: 'access', value: access);
    await _storage.write(key: 'refresh', value: refresh);
    await _storage.write(key: 'user', value: jsonEncode(user));
  }

  @override
  Future<void> clear() => _storage.deleteAll();
}

/// Used by tests: keeps everything in memory.
class MemoryTokenStore implements TokenStore {
  String? access;
  String? refresh;
  Map<String, dynamic>? user;

  @override
  Future<String?> readAccess() async => access;

  @override
  Future<String?> readRefresh() async => refresh;

  @override
  Future<Map<String, dynamic>?> readUser() async => user;

  @override
  Future<void> save({required String access, required String refresh, required Map<String, dynamic> user}) async {
    this.access = access;
    this.refresh = refresh;
    this.user = user;
  }

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
    user = null;
  }
}
