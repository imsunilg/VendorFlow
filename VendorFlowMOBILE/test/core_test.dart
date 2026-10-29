import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:vendorflow_mobile/core/api_client.dart';
import 'package:vendorflow_mobile/core/format.dart';
import 'package:vendorflow_mobile/core/providers.dart';
import 'package:vendorflow_mobile/core/token_store.dart';

/// A fake network: the test decides what the "server" answers.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(Object body, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});

const userJson = {
  'userId': 'u1', 'tenantId': 't1', 'email': 'priya@demo.in', 'fullName': 'Priya Menon',
  'roles': ['ProcurementManager'], 'permissions': ['vendors.view', 'approvals.decide']
};

Map<String, dynamic> session(String access, String refresh) => {'accessToken': access, 'refreshToken': refresh, 'user': userJson};

void main() {
  group('format helpers', () {
    test('money uses Indian digit grouping', () {
      expect(money(620000), '₹6,20,000');
      expect(money(1234.5, decimals: 2), '₹1,234.50');
      expect(money(null), '—');
    });

    test('short money shows lakh and crore', () {
      expect(shortMoney(48200000), '₹4.82 Cr');
      expect(shortMoney(880000), '₹8.8 L');
      expect(shortMoney(84000), '₹84,000');
    });

    test('status text and colours', () {
      expect(statusText('PendingApproval'), 'Pending approval');
      expect(statusText('ConvertedToPO'), 'Converted to PO');
      expect(statusColor('Approved'), const Color(0xFF12A05C));
      expect(statusColor('Overdue'), const Color(0xFFDC2D4A));
      expect(statusColor('Draft'), const Color(0xFF6B7394));
    });

    test('date text', () {
      expect(dateText('2026-11-10'), '10 Nov 2026');
      expect(dateText(null), '—');
    });
  });

  group('labels', () {
    test('default labels keep the word Vendor', () {
      expect(const AppLabels().t('Add Vendor'), 'Add Vendor');
    });

    test('custom labels replace Vendor / Vendors and keep the case', () {
      const labels = AppLabels(vendor: 'Supplier', vendors: 'Suppliers');
      expect(labels.t('Add Vendor'), 'Add Supplier');
      expect(labels.t('Search vendors…'), 'Search suppliers…');
      expect(labels.t('Vendors'), 'Suppliers');
    });
  });

  group('AuthUser', () {
    test('reads the json and answers permission questions', () {
      final user = AuthUser.fromJson(userJson);
      expect(user.firstName, 'Priya');
      expect(user.initials, 'PM');
      expect(user.has('approvals.decide'), isTrue);
      expect(user.has('settings.manage'), isFalse);
      expect(user.roleText, 'Procurement Manager');
    });
  });

  group('ApiClient', () {
    test('login stores the session and later calls send the token', () async {
      final store = MemoryTokenStore();
      final adapter = FakeAdapter((o) => o.path == '/auth/login' ? json(session('A1', 'R1')) : json({'ok': true}));
      final api = ApiClient(store, dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = adapter);

      await api.login('priya@demo.in', 'pw');
      expect(await store.readAccess(), 'A1');
      expect((await store.readUser())!['fullName'], 'Priya Menon');
      expect(adapter.calls.first.headers['Authorization'], isNull);       // login itself is anonymous

      await api.get('/vendors');
      expect(adapter.calls.last.headers['Authorization'], 'Bearer A1');
    });

    test('a 401 triggers one refresh and the call is repeated with the new token', () async {
      final store = MemoryTokenStore()..access = 'old'..refresh = 'R1'..user = userJson;
      var vendorCalls = 0;
      final adapter = FakeAdapter((o) {
        if (o.path == '/auth/refresh') return json(session('new', 'R2'));
        vendorCalls++;
        return o.headers['Authorization'] == 'Bearer new' ? json({'items': []}) : json({'title': 'Unauthorized'}, 401);
      });
      final api = ApiClient(store, dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = adapter);

      final result = await api.get('/vendors') as Map;
      expect(result['items'], isEmpty);
      expect(vendorCalls, 2);
      expect(await store.readRefresh(), 'R2');
    });

    test('when the refresh fails the session is cleared and the app is told', () async {
      final store = MemoryTokenStore()..access = 'old'..refresh = 'bad'..user = userJson;
      var expired = false;
      final adapter = FakeAdapter((o) => json({'title': 'Unauthorized'}, 401));
      final api = ApiClient(store, onSessionExpired: () => expired = true, dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = adapter);

      await expectLater(api.get('/vendors'), throwsA(isA<DioException>()));
      expect(expired, isTrue);
      expect(await store.readAccess(), isNull);
    });

    test('apiMessage shows the server detail text', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(requestOptions: RequestOptions(path: '/x'), statusCode: 409, data: {'detail': 'Duplicate invoice', 'title': 'Conflict'}),
      );
      expect(apiMessage(error), 'Duplicate invoice');
      expect(apiMessage(Exception('boom')), 'Something went wrong. Please try again.');
      expect(apiMessage(DioException(requestOptions: RequestOptions(path: '/x'), type: DioExceptionType.connectionError)), contains('Cannot reach the server'));
    });
  });
}
