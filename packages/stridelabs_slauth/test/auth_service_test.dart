import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/src/auth_service.dart';
import 'package:stridelabs_slauth/src/slauth_config.dart';
import 'package:stridelabs_slauth/src/token_store.dart';

const _config = SlauthConfig(
  baseUrl: 'https://auth.test',
  clientId: 'slaudio-mobile',
  audience: 'slaudio',
  redirectUri: 'slaudio://auth/callback',
  postLogoutUri: 'slaudio://auth/logout',
);

String _makeJwt(String sub) {
  const header = 'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0';
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","email":"t@t"}'))
      .replaceAll('=', '');
  return '$header.$payload.';
}

/// TokenStore that records the ORDER of writes so the rotation-safe ordering
/// (refresh token written before access token) is assertable.
class _RecordingStore implements TokenStore {
  final Map<String, String> data = {};
  final List<String> writeOrder = [];

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    writeOrder.add(key);
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

/// TokenStore with per-op hooks: fire a callback on each write (to simulate a
/// logout landing mid-write), record every delete attempt, and optionally throw
/// on a chosen delete (to prove all four deletions are still attempted).
class _HookStore implements TokenStore {
  final Map<String, String> data = {};
  final List<String> deleteAttempts = [];
  void Function(String key)? onWrite;
  bool Function(String key)? failDelete;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    onWrite?.call(key);
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteAttempts.add(key);
    if (failDelete?.call(key) ?? false) {
      throw Exception('delete failed for $key');
    }
    data.remove(key);
  }
}

/// Dio adapter that answers `/oauth2/token` from a programmable responder and
/// counts hits (to prove refresh dedup).
class _TokenAdapter implements HttpClientAdapter {
  _TokenAdapter(this.responder);

  final Future<ResponseBody> Function(RequestOptions options) responder;
  int tokenHits = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.uri.path == '/oauth2/token') {
      tokenHits++;
      return responder(options);
    }
    return Future.value(ResponseBody.fromString('{}', 404));
  }
}

ResponseBody _tokenJson(String refresh) => ResponseBody.fromString(
  jsonEncode({
    'access_token': _makeJwt('user-1'),
    'refresh_token': refresh,
    'id_token': _makeJwt('user-1'),
    'expires_in': 900,
  }),
  200,
  headers: {
    'content-type': ['application/json'],
  },
);

AuthService _service({
  required HttpClientAdapter adapter,
  required TokenStore store,
}) {
  final dio = Dio(BaseOptions(baseUrl: _config.baseUrl))
    ..httpClientAdapter = adapter;
  return AuthService(config: _config, store: store, dio: dio);
}

void main() {
  group('restore + logout', () {
    test(
      'restoreFromStorage round-trip and logout clears everything',
      () async {
        final store = _RecordingStore()
          ..data['slauth_access_token'] = _makeJwt('abc-123')
          ..data['slauth_refresh_token'] = 'r0'
          ..data['slauth_expires_at'] = DateTime.now()
              .add(const Duration(hours: 1))
              .toIso8601String();
        final svc = _service(
          adapter: _TokenAdapter((_) async => _tokenJson('r1')),
          store: store,
        );

        expect(await svc.restoreFromStorage(), isTrue);
        expect(svc.isAuthenticated, isTrue);
        expect(svc.isTokenExpired, isFalse);
        expect(svc.userId, 'abc-123');

        await svc.logout();
        expect(svc.isAuthenticated, isFalse);
        expect(svc.hasRefreshToken, isFalse);
        expect(store.data['slauth_access_token'], isNull);
        expect(store.data['slauth_refresh_token'], isNull);
        svc.dispose();
      },
    );
  });

  group('refresh', () {
    test('dedups concurrent refreshes into a single token request', () async {
      final adapter = _TokenAdapter((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _tokenJson('r1');
      });
      final store = _RecordingStore()..data['slauth_refresh_token'] = 'r0';
      final svc = _service(adapter: adapter, store: store);
      await svc
          .restoreFromStorage(); // load refresh token (access missing → false, but sets nothing)
      // restoreFromStorage returns false without access token; set via storeTokens.
      await svc.storeTokens({
        'access_token': _makeJwt('user-1'),
        'refresh_token': 'r0',
        'expires_in': 900,
      });

      final results = await Future.wait([
        svc.refreshAccessToken(),
        svc.refreshAccessToken(),
      ]);

      expect(results, [true, true]);
      expect(
        adapter.tokenHits,
        1,
        reason: 'the second refresh must reuse the in-flight one',
      );
      svc.dispose();
    });

    test('writes rotated refresh token BEFORE the access token', () async {
      final store = _RecordingStore();
      final svc = _service(
        adapter: _TokenAdapter((_) async => _tokenJson('r1')),
        store: store,
      );
      await svc.storeTokens({
        'access_token': _makeJwt('user-1'),
        'refresh_token': 'r0',
        'expires_in': 900,
      });
      store.writeOrder.clear();

      final ok = await svc.refreshAccessToken();
      expect(ok, isTrue);
      expect(store.data['slauth_refresh_token'], 'r1');

      final refreshIdx = store.writeOrder.indexOf('slauth_refresh_token');
      final accessIdx = store.writeOrder.indexOf('slauth_access_token');
      expect(refreshIdx, greaterThanOrEqualTo(0));
      expect(
        accessIdx,
        greaterThan(refreshIdx),
        reason: 'refresh token must be persisted before the access token',
      );
      svc.dispose();
    });

    test(
      'refresh completing AFTER logout is discarded — memory AND disk',
      () async {
        final store = _RecordingStore();
        // The token endpoint responds slowly, so logout() can win the race and
        // the refresh result must be dropped when it finally arrives.
        final adapter = _TokenAdapter((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return _tokenJson('r-new');
        });
        final svc = _service(adapter: adapter, store: store);
        await svc.storeTokens({
          'access_token': _makeJwt('user-1'),
          'refresh_token': 'r0',
          'expires_in': 900,
        });

        // Kick off the refresh, then log out before its response lands.
        final refreshFuture = svc.refreshAccessToken();
        await svc.logout();
        await refreshFuture;

        // The HTTP call may report success, but the RESULT must be discarded:
        // Memory: still signed out, not silently re-authenticated.
        expect(svc.isAuthenticated, isFalse);
        expect(svc.hasRefreshToken, isFalse);
        // Disk: the rotated token never landed — nothing to resurrect on launch.
        expect(store.data['slauth_access_token'], isNull);
        expect(store.data['slauth_refresh_token'], isNull);
        svc.dispose();
      },
    );

    test(
      'logout landing MID-WRITE leaves no complete token pair on disk',
      () async {
        final store = _HookStore();
        late final AuthService svc;
        svc = _service(
          adapter: _TokenAdapter((_) async => _tokenJson('r-new')),
          store: store,
        );
        await svc.storeTokens({
          'access_token': _makeJwt('user-1'),
          'refresh_token': 'r0',
          'expires_in': 900,
        });

        // Trigger logout precisely while the refresh is persisting the new
        // access token — after the pre-write generation check has passed.
        var loggedOut = false;
        store.onWrite = (key) {
          if (key == 'slauth_access_token' && !loggedOut) {
            loggedOut = true;
            svc.logout(); // bumps generation synchronously
          }
        };

        final refreshOk = await svc.refreshAccessToken();
        // Let logout's own deletions and the mid-write undo settle.
        await Future<void>.delayed(Duration.zero);

        expect(refreshOk, isTrue, reason: 'the HTTP refresh itself succeeded');
        // The tokens written mid-flight were undone; no usable pair survives.
        expect(store.data['slauth_access_token'], isNull);
        expect(store.data['slauth_refresh_token'], isNull);
        // Memory was never adopted — the user stays signed out.
        expect(svc.isAuthenticated, isFalse);
        expect(svc.hasRefreshToken, isFalse);
        svc.dispose();
      },
    );

    test('logout attempts all four deletions even when one fails', () async {
      final store = _HookStore()
        ..data['slauth_access_token'] = 'a'
        ..data['slauth_refresh_token'] = 'r'
        ..data['slauth_id_token'] = 'i'
        ..data['slauth_expires_at'] = 'e'
        // The refresh-token deletion throws; the other three must still run.
        ..failDelete = ((key) => key == 'slauth_refresh_token');
      final svc = _service(
        adapter: _TokenAdapter((_) async => _tokenJson('r1')),
        store: store,
      );

      await svc.logout();

      expect(
        store.deleteAttempts.toSet(),
        {
          'slauth_access_token',
          'slauth_refresh_token',
          'slauth_id_token',
          'slauth_expires_at',
        },
        reason: 'all four keys must be attempted despite the failure',
      );
      // The keys whose delete did not throw are actually gone.
      expect(store.data['slauth_access_token'], isNull);
      expect(store.data['slauth_id_token'], isNull);
      expect(store.data['slauth_expires_at'], isNull);
      svc.dispose();
    });

    test('400 on refresh forces logout (via fake_async)', () {
      fakeAsync((async) {
        final adapter = _TokenAdapter(
          (_) async =>
              ResponseBody.fromString('{"error":"invalid_grant"}', 400),
        );
        final store = _RecordingStore()
          ..data['slauth_access_token'] = _makeJwt('user-1')
          ..data['slauth_refresh_token'] = 'r0'
          ..data['slauth_expires_at'] = DateTime.now()
              .add(const Duration(hours: 1))
              .toIso8601String();
        final svc = _service(adapter: adapter, store: store);

        var forced = false;
        svc.onForceLogout = () => forced = true;

        svc.restoreFromStorage();
        async.flushMicrotasks();

        bool? result;
        svc.refreshAccessToken().then((r) => result = r);
        async.elapse(const Duration(seconds: 1));

        expect(result, isFalse);
        expect(forced, isTrue, reason: '400 invalid_grant must force logout');
        expect(svc.hasRefreshToken, isFalse);
        svc.dispose();
      });
    });
  });
}
