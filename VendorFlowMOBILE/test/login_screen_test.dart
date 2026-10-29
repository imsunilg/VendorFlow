import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendorflow_mobile/core/api_client.dart';
import 'package:vendorflow_mobile/core/providers.dart';
import 'package:vendorflow_mobile/core/token_store.dart';
import 'package:vendorflow_mobile/features/auth/login_screen.dart';
import 'package:vendorflow_mobile/shared/widgets.dart';

import 'core_test.dart' show FakeAdapter, json, session;

Widget app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: LoginScreen()),
    );

ProviderContainer containerWith(ResponseBody Function(RequestOptions) server) {
  final store = MemoryTokenStore();
  final api = ApiClient(store, dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = FakeAdapter(server));
  return ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(store), apiProvider.overrideWithValue(api)]);
}

void main() {
  testWidgets('empty form shows validation messages and does not call the server', (tester) async {
    var calls = 0;
    final container = containerWith((o) { calls++; return json({}); });
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));

    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Password is required.'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('wrong password shows the message from the API', (tester) async {
    final container = containerWith((o) => ResponseBody.fromString(
        jsonEncode({'title': 'Invalid credentials', 'detail': 'Email or password is wrong, or the account is locked.'}), 401,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]}));
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));

    await tester.enterText(find.byType(TextFormField).at(0), 'priya@demo.in');
    await tester.enterText(find.byType(TextFormField).at(1), 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Email or password is wrong'), findsOneWidget);
    expect(container.read(authProvider).value, isNull);
  });

  testWidgets('correct credentials sign the user in', (tester) async {
    final container = containerWith((o) => json(session('A', 'R')));
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));

    await tester.enterText(find.byType(TextFormField).at(0), 'priya@demo.in');
    await tester.enterText(find.byType(TextFormField).at(1), 'Demo@12345');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(container.read(authProvider).value?.fullName, 'Priya Menon');
  });

  testWidgets('status chip shows readable text', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StatusChip('PendingApproval'))));
    expect(find.text('Pending approval'), findsOneWidget);
  });
}
