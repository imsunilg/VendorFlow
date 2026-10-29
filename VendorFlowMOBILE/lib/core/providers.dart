import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'api_client.dart';
import 'token_store.dart';

/// The signed-in user (null = signed out). Built from the JSON the API sends at login.
class AuthUser {
  AuthUser(this.id, this.tenantId, this.email, this.fullName, this.roles, this.permissions);

  final String id;
  final String tenantId;
  final String email;
  final String fullName;
  final List<String> roles;
  final List<String> permissions;

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        json['userId'] as String,
        json['tenantId'] as String,
        json['email'] as String,
        json['fullName'] as String,
        List<String>.from(json['roles'] as List),
        List<String>.from(json['permissions'] as List),
      );

  bool has(String permission) => permissions.contains(permission);

  String get firstName => fullName.split(' ').first;
  String get initials => fullName.split(' ').take(2).map((p) => p.isEmpty ? '' : p[0]).join().toUpperCase();
  String get roleText => roles.map((r) => r.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')).join(', ');
}

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final apiProvider = Provider<ApiClient>((ref) {
  return ApiClient(ref.watch(tokenStoreProvider), onSessionExpired: () => ref.read(authProvider.notifier).expire());
});

/// Holds the current user and offers login / logout.
class AuthNotifier extends AsyncNotifier<AuthUser?> {
  @override
  Future<AuthUser?> build() async {
    final stored = await ref.read(tokenStoreProvider).readUser();
    return stored == null ? null : AuthUser.fromJson(stored);
  }

  Future<void> login(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final body = await ref.read(apiProvider).login(email, password);
      return AuthUser.fromJson(Map<String, dynamic>.from(body['user'] as Map));
    });
  }

  Future<void> logout() async {
    await ref.read(apiProvider).logout();
    state = const AsyncData(null);
  }

  // Called when the refresh token no longer works.
  void expire() => state = const AsyncData(null);
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthUser?>(AuthNotifier.new);

/// Words that depend on the organization (display name, "Vendor" terminology).
class AppLabels {
  const AppLabels({this.appName = 'VendorFlow', this.vendor = 'Vendor', this.vendors = 'Vendors', this.organization = ''});

  final String appName;
  final String vendor;
  final String vendors;
  final String organization;

  /// Replaces the word Vendor / Vendors in a text, keeping the letter case.
  String t(String text) => text
      .replaceAll('Vendors', vendors)
      .replaceAll('vendors', vendors.toLowerCase())
      .replaceAll('Vendor', vendor)
      .replaceAll('vendor', vendor.toLowerCase());
}

/// Settings of the organization; loaded again whenever the user signs in or out.
final settingsProvider = FutureProvider<AppLabels>((ref) async {
  final user = ref.watch(authProvider).value;
  if (user == null) return const AppLabels();
  final s = await ref.read(apiProvider).get('/organizations/current/settings') as Map<String, dynamic>;
  return AppLabels(
    appName: s['appDisplayName'] as String,
    vendor: s['vendorLabelSingular'] as String,
    vendors: s['vendorLabelPlural'] as String,
    organization: s['organizationName'] as String,
  );
});

/// Shortcut for widgets: the labels, or the defaults while loading.
final labelsProvider = Provider<AppLabels>((ref) => ref.watch(settingsProvider).value ?? const AppLabels());
