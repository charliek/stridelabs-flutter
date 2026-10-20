import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

import 'support/fakes.dart';

/// A service on [endpoint] with a [RecordingStore]; [forced] counts
/// onForceLogout calls.
class _Rig {
  _Rig({RefreshRetryPolicy? retry}) {
    svc = AuthService.withEndpoint(
      endpoint: endpoint,
      store: store,
      refreshRetry: retry,
    )..onForceLogout = () => forced++;
  }

  final endpoint = FakeEndpoint();
  final store = RecordingStore();
  late final AuthService svc;
  var forced = 0;
}

const _rotated = RefreshTokenPresent('r1');

/// A new process over the same [store]: a fresh service, as after a restart.
AuthService _restart(RecordingStore store, [FakeEndpoint? endpoint]) =>
    AuthService.withEndpoint(
      endpoint: endpoint ?? FakeEndpoint(),
      store: store,
    );

void main() {
  group('refresh outcome (custom endpoint)', () {
    test('unauthorized → logged out: memory and store cleared', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      rig.endpoint.onRefresh = (_) async =>
          throw const AuthUnauthorized(statusCode: 401);

      expect(await rig.svc.refreshSession(), RefreshOutcome.unauthorized);

      expect(rig.svc.isAuthenticated, isFalse);
      expect(rig.svc.hasRefreshToken, isFalse);
      expect(rig.svc.idToken, isNull);
      expect(rig.store.data, isEmpty);
      expect(rig.forced, 1, reason: 'a dead grant must force logout');
      rig.svc.dispose();
    });

    test(
      'unauthorized via refreshAccessToken → false and logged out',
      () async {
        final rig = _Rig();
        await seedSession(rig.svc, rig.store);
        rig.endpoint.onRefresh = (_) async =>
            throw const AuthUnauthorized(statusCode: 400);

        expect(await rig.svc.refreshAccessToken(), isFalse);

        expect(rig.svc.isAuthenticated, isFalse);
        expect(rig.store.data, isEmpty);
        expect(rig.forced, 1);
        rig.svc.dispose();
      },
    );

    for (final failure in <String, Object>{
      'AuthUnavailable': const AuthUnavailable(statusCode: 503),
      'an arbitrary exception': StateError('boom'),
    }.entries) {
      test(
        '${failure.key} → session kept: memory and store unchanged',
        () async {
          final rig = _Rig();
          await seedSession(rig.svc, rig.store);
          final before = Map<String, String>.of(rig.store.data);
          rig.endpoint.onRefresh = (_) async => throw failure.value;

          expect(await rig.svc.refreshSession(), RefreshOutcome.unavailable);
          expect(await rig.svc.refreshAccessToken(), isFalse);

          expect(rig.svc.isAuthenticated, isTrue);
          expect(rig.svc.accessToken, 'a0');
          expect(rig.svc.hasRefreshToken, isTrue);
          expect(rig.svc.idToken, 'id0');
          expect(rig.store.data, before);
          expect(rig.store.ops, isEmpty, reason: 'nothing may touch the store');
          expect(rig.forced, 0);
          // The kept refresh token is the one the next attempt uses.
          expect(rig.endpoint.refreshes, ['r0', 'r0']);
          rig.svc.dispose();
        },
      );
    }

    test('no refresh token → noSession, endpoint not called', () async {
      final rig = _Rig();
      expect(await rig.svc.refreshSession(), RefreshOutcome.noSession);
      expect(await rig.svc.refreshAccessToken(), isFalse);
      expect(rig.endpoint.refreshes, isEmpty);
      rig.svc.dispose();
    });
  });

  group('refresh-token rule on refresh', () {
    test('absent → the stored refresh token is kept', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      rig.endpoint.onRefresh = (_) async => tokens('a1', expiresAt: inOneDay());

      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);

      expect(rig.svc.accessToken, 'a1');
      expect(rig.svc.hasRefreshToken, isTrue);
      expect(rig.store.data[kAccess], 'a1');
      expect(rig.store.data[kRefresh], 'r0');
      expect(rig.store.ops, isNot(contains('delete:$kRefresh')));
      expect(rig.store.ops, isNot(contains('write:$kRefresh')));
      // Memory kept it too: the next refresh presents r0 again.
      await rig.svc.refreshSession();
      expect(rig.endpoint.refreshes, ['r0', 'r0']);
      rig.svc.dispose();
    });

    test('absent id_token → the current id token is kept', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: _rotated, expiresAt: inOneDay());

      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
      expect(rig.svc.idToken, 'id0');
      expect(rig.store.data[kId], 'id0');
      rig.svc.dispose();
    });

    test('rotated → replaced, refresh token written before access', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: _rotated, expiresAt: inOneDay());

      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);

      expect(rig.store.data[kRefresh], 'r1');
      expect(rig.store.data[kAccess], 'a1');
      final refreshIdx = rig.store.ops.indexOf('write:$kRefresh');
      final accessIdx = rig.store.ops.indexOf('write:$kAccess');
      expect(refreshIdx, greaterThanOrEqualTo(0));
      expect(
        accessIdx,
        greaterThan(refreshIdx),
        reason: 'the rotated refresh token must be persisted first',
      );
      // Memory rotated too: the next refresh presents r1.
      await rig.svc.refreshSession();
      expect(rig.endpoint.refreshes, ['r0', 'r1']);
      rig.svc.dispose();
    });

    for (final blank in <String, Map<String, dynamic>>{
      'null': {'access_token': 'a1', 'refresh_token': null},
      'empty string': {'access_token': 'a1', 'refresh_token': ''},
    }.entries) {
      test(
        '${blank.key} → unavailable, nothing adopted, session kept',
        () async {
          final rig = _Rig();
          await seedSession(rig.svc, rig.store);
          final before = Map<String, String>.of(rig.store.data);
          rig.endpoint.onRefresh = (_) async =>
              TokenResponse.fromJson(blank.value);

          expect(await rig.svc.refreshSession(), RefreshOutcome.unavailable);
          expect(await rig.svc.refreshAccessToken(), isFalse);

          expect(
            rig.svc.accessToken,
            'a0',
            reason: 'not even the access token',
          );
          expect(rig.svc.hasRefreshToken, isTrue);
          expect(rig.store.data, before);
          expect(rig.store.ops, isEmpty);
          expect(rig.forced, 0);
          expect(rig.endpoint.refreshes, ['r0', 'r0']);
          rig.svc.dispose();
        },
      );
    }

    test('a hand-built RefreshTokenPresent("") is treated as blank', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: const RefreshTokenPresent(''));

      expect(await rig.svc.refreshSession(), RefreshOutcome.unavailable);
      expect(rig.svc.accessToken, 'a0');
      expect(rig.store.ops, isEmpty);
      rig.svc.dispose();
    });
  });

  group('refresh-token rule on exchange (a new session)', () {
    test('passes code, verifier and redirect URI to the endpoint', () async {
      final rig = _Rig();
      rig.endpoint.onExchange = (_) async =>
          tokens('a1', refresh: _rotated, id: 'id1', expiresAt: inOneDay());

      final ok = await rig.svc.exchangeAuthorizationCode(
        'the-code',
        codeVerifier: 'the-verifier',
        redirectUri: 'app://cb',
      );

      expect(ok, isTrue);
      final req = rig.endpoint.exchanges.single;
      expect(req.code, 'the-code');
      expect(req.codeVerifier, 'the-verifier');
      expect(req.redirectUri, 'app://cb');
      expect(rig.svc.accessToken, 'a1');
      expect(rig.svc.idToken, 'id1');
      expect(rig.store.data[kRefresh], 'r1');
      expect(rig.store.data[kAccess], 'a1');
      expect(rig.store.data[kId], 'id1');
      rig.svc.dispose();
    });

    test('absent → no refresh token; the old one is deleted', () async {
      final rig = _Rig();
      // A previous session is still around (memory and store).
      await seedSession(rig.svc, rig.store, refresh: 'old-r', id: 'old-id');
      rig.endpoint.onExchange = (_) async => tokens('a1');

      final ok = await rig.svc.exchangeAuthorizationCode(
        'c',
        codeVerifier: 'v',
        redirectUri: 'app://cb',
      );

      expect(ok, isTrue);
      expect(rig.svc.accessToken, 'a1');
      expect(rig.svc.hasRefreshToken, isFalse, reason: 'memory: not inherited');
      expect(rig.store.data.containsKey(kRefresh), isFalse, reason: 'store');
      // Nor the previous session's id token / expiry.
      expect(rig.svc.idToken, isNull);
      expect(rig.store.data.containsKey(kId), isFalse);
      expect(rig.store.data.containsKey(kExpires), isFalse);
      expect(rig.store.data[kAccess], 'a1');
      rig.svc.dispose();
    });

    for (final blank in <String, Map<String, dynamic>>{
      'null': {'access_token': 'a1', 'refresh_token': null},
      'empty string': {'access_token': 'a1', 'refresh_token': ''},
    }.entries) {
      test('${blank.key} → exchange fails, nothing stored', () async {
        final rig = _Rig();
        rig.endpoint.onExchange = (_) async =>
            TokenResponse.fromJson(blank.value);

        final ok = await rig.svc.exchangeAuthorizationCode(
          'c',
          codeVerifier: 'v',
          redirectUri: 'app://cb',
        );

        expect(ok, isFalse);
        expect(rig.svc.isAuthenticated, isFalse);
        expect(rig.svc.hasRefreshToken, isFalse);
        expect(rig.store.data, isEmpty);
        expect(rig.store.ops, isEmpty);
        rig.svc.dispose();
      });

      test('storeTokens with a ${blank.key} refresh_token throws, stores '
          'nothing', () async {
        final rig = _Rig();
        await expectLater(
          rig.svc.storeTokens(blank.value),
          throwsFormatException,
        );
        expect(rig.svc.isAuthenticated, isFalse);
        expect(rig.store.ops, isEmpty);
        rig.svc.dispose();
      });
    }

    test('an exchange failure never touches an existing session', () async {
      for (final failure in <Object>[
        const AuthUnauthorized(statusCode: 400),
        const AuthUnavailable(statusCode: 503),
        StateError('boom'),
      ]) {
        final rig = _Rig();
        await seedSession(rig.svc, rig.store);
        final before = Map<String, String>.of(rig.store.data);
        rig.endpoint.onExchange = (_) async => throw failure;

        final ok = await rig.svc.exchangeAuthorizationCode(
          'c',
          codeVerifier: 'v',
          redirectUri: 'app://cb',
        );

        expect(ok, isFalse, reason: '$failure');
        expect(rig.svc.accessToken, 'a0', reason: '$failure');
        expect(rig.store.data, before, reason: '$failure');
        expect(rig.forced, 0, reason: '$failure');
        rig.svc.dispose();
      }
    });
  });

  group('concurrency and the generation rule (custom endpoint)', () {
    test(
      'concurrent refreshAccessToken/refreshSession share one call',
      () async {
        final rig = _Rig();
        await seedSession(rig.svc, rig.store);
        final gate = Completer<TokenResponse>();
        rig.endpoint.onRefresh = (_) => gate.future;

        final legacyA = rig.svc.refreshAccessToken();
        final typedA = rig.svc.refreshSession();
        final legacyB = rig.svc.refreshAccessToken();
        final typedB = rig.svc.refreshSession();
        gate.complete(tokens('a1', refresh: _rotated, expiresAt: inOneDay()));

        expect(await legacyA, isTrue);
        expect(await legacyB, isTrue);
        expect(await typedA, RefreshOutcome.refreshed);
        expect(await typedB, RefreshOutcome.refreshed);
        expect(
          rig.endpoint.refreshes,
          hasLength(1),
          reason: 'every caller must reuse the in-flight refresh',
        );
        rig.svc.dispose();
      },
    );

    test('logout during an in-flight refresh discards the result', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      final gate = Completer<TokenResponse>();
      rig.endpoint.onRefresh = (_) => gate.future;

      final outcome = rig.svc.refreshSession();
      await rig.svc.logout();
      gate.complete(tokens('a1', refresh: _rotated, expiresAt: inOneDay()));

      expect(await outcome, RefreshOutcome.discarded);
      expect(rig.svc.isAuthenticated, isFalse);
      expect(rig.svc.hasRefreshToken, isFalse);
      expect(rig.store.data, isEmpty, reason: 'nothing to resurrect on launch');
      rig.svc.dispose();
    });

    test(
      'a new session discards an in-flight refresh of the old one',
      () async {
        final rig = _Rig();
        await seedSession(rig.svc, rig.store);
        final gate = Completer<TokenResponse>();
        rig.endpoint.onRefresh = (_) => gate.future;
        rig.endpoint.onExchange = (_) async => tokens(
          'new-a',
          refresh: const RefreshTokenPresent('new-r'),
          expiresAt: inOneDay(),
        );

        final outcome = rig.svc.refreshSession();
        expect(
          await rig.svc.exchangeAuthorizationCode(
            'c',
            codeVerifier: 'v',
            redirectUri: 'app://cb',
          ),
          isTrue,
        );
        gate.complete(
          tokens(
            'old-a',
            refresh: const RefreshTokenPresent('old-r'),
            expiresAt: inOneDay(),
          ),
        );

        expect(await outcome, RefreshOutcome.discarded);
        expect(rig.svc.accessToken, 'new-a');
        expect(rig.store.data[kAccess], 'new-a');
        expect(rig.store.data[kRefresh], 'new-r');
        rig.svc.dispose();
      },
    );

    test('a dead grant landing after a new sign-in leaves the new session '
        'alone', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      final gate = Completer<TokenResponse>();
      rig.endpoint.onRefresh = (_) => gate.future;
      rig.endpoint.onExchange = (_) async => tokens(
        'new-a',
        refresh: const RefreshTokenPresent('new-r'),
        expiresAt: inOneDay(),
      );

      final outcome = rig.svc.refreshSession();
      await rig.svc.logout(notify: false);
      await rig.svc.exchangeAuthorizationCode(
        'c',
        codeVerifier: 'v',
        redirectUri: 'app://cb',
      );
      gate.completeError(const AuthUnauthorized(statusCode: 400));

      expect(await outcome, RefreshOutcome.discarded);
      expect(rig.svc.accessToken, 'new-a');
      expect(rig.svc.hasRefreshToken, isTrue);
      expect(rig.store.data[kRefresh], 'new-r');
      expect(rig.forced, 0, reason: 'the new session must not be logged out');
      rig.svc.dispose();
    });
  });

  group('opt-in retry on unavailable', () {
    test('backoff: 15 s doubling, capped at 5 min', () {
      const policy = RefreshRetryPolicy();
      expect(
        [for (var i = 0; i < 8; i++) policy.delayForAttempt(i).inSeconds],
        [15, 30, 60, 120, 240, 300, 300, 300],
      );
      expect(
        const RefreshRetryPolicy(
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
        ).delayForAttempt(3),
        const Duration(seconds: 1),
        reason: 'never a zero-delay retry loop',
      );
    });

    test('off by default: no retry is scheduled', () {
      fakeAsync((async) {
        final rig = _Rig();
        seedSession(rig.svc, rig.store);
        async.flushMicrotasks();
        rig.endpoint.onRefresh = (_) async =>
            throw const AuthUnavailable(statusCode: 503);

        RefreshOutcome? outcome;
        rig.svc.refreshSession().then((o) => outcome = o);
        async.flushMicrotasks();
        expect(outcome, RefreshOutcome.unavailable);
        expect(rig.svc.hasPendingRefreshRetry, isFalse);

        async.elapse(const Duration(hours: 1));
        expect(rig.endpoint.refreshes, hasLength(1));
        rig.svc.dispose();
      });
    });

    test('cold start: an unavailable refresh keeps the user signed in with a '
        'retry scheduled; the retry backs off and stops on success', () {
      fakeAsync((async) {
        final rig = _Rig(retry: const RefreshRetryPolicy());
        // Launch with an expired access token.
        seedSession(
          rig.svc,
          rig.store,
          expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
        );
        async.flushMicrotasks();
        expect(rig.svc.isTokenExpired, isTrue);

        var failures = 2;
        rig.endpoint.onRefresh = (_) async {
          if (failures-- > 0) throw const AuthUnavailable(statusCode: 503);
          return tokens('a1', refresh: _rotated, expiresAt: inOneDay());
        };

        RefreshOutcome? outcome;
        rig.svc.refreshSession().then((o) => outcome = o);
        async.flushMicrotasks();
        expect(outcome, RefreshOutcome.unavailable);
        expect(rig.svc.isAuthenticated, isTrue, reason: 'still signed in');
        expect(rig.svc.hasRefreshToken, isTrue);
        expect(rig.svc.hasPendingRefreshRetry, isTrue);

        // Retry 1 after 15 s (fails), retry 2 after a further 30 s (succeeds).
        async.elapse(const Duration(seconds: 14));
        expect(rig.endpoint.refreshes, hasLength(1));
        async.elapse(const Duration(seconds: 1));
        expect(rig.endpoint.refreshes, hasLength(2));
        expect(rig.svc.hasPendingRefreshRetry, isTrue);
        async.elapse(const Duration(seconds: 29));
        expect(rig.endpoint.refreshes, hasLength(2));
        async.elapse(const Duration(seconds: 1));
        expect(rig.endpoint.refreshes, hasLength(3));

        expect(rig.svc.accessToken, 'a1');
        expect(rig.svc.hasPendingRefreshRetry, isFalse);
        async.elapse(const Duration(hours: 1));
        expect(rig.endpoint.refreshes, hasLength(3), reason: 'retries stop');
        rig.svc.dispose();
      });
    });

    test('a successful refresh cancels a pending retry', () {
      fakeAsync((async) {
        final rig = _Rig(retry: const RefreshRetryPolicy());
        seedSession(rig.svc, rig.store);
        async.flushMicrotasks();
        rig.endpoint.onRefresh = (_) async =>
            throw const AuthUnavailable(statusCode: 502);
        rig.svc.refreshSession();
        async.flushMicrotasks();
        expect(rig.svc.hasPendingRefreshRetry, isTrue);

        rig.endpoint.onRefresh = (_) async =>
            tokens('a1', refresh: _rotated, expiresAt: inOneDay());
        RefreshOutcome? outcome;
        rig.svc.refreshSession().then((o) => outcome = o);
        async.flushMicrotasks();
        expect(outcome, RefreshOutcome.refreshed);
        expect(rig.svc.hasPendingRefreshRetry, isFalse);

        async.elapse(const Duration(hours: 1));
        expect(rig.endpoint.refreshes, hasLength(2));
        rig.svc.dispose();
      });
    });

    test('logout cancels a pending retry', () {
      fakeAsync((async) {
        final rig = _Rig(retry: const RefreshRetryPolicy());
        seedSession(rig.svc, rig.store);
        async.flushMicrotasks();
        rig.endpoint.onRefresh = (_) async =>
            throw const AuthUnavailable(statusCode: 503);
        rig.svc.refreshSession();
        async.flushMicrotasks();
        expect(rig.svc.hasPendingRefreshRetry, isTrue);

        rig.svc.logout();
        async.flushMicrotasks();
        expect(rig.svc.hasPendingRefreshRetry, isFalse);
        async.elapse(const Duration(hours: 1));
        expect(rig.endpoint.refreshes, hasLength(1));
        rig.svc.dispose();
      });
    });

    test('dispose cancels a pending retry', () {
      fakeAsync((async) {
        final rig = _Rig(retry: const RefreshRetryPolicy());
        seedSession(rig.svc, rig.store);
        async.flushMicrotasks();
        rig.endpoint.onRefresh = (_) async =>
            throw const AuthUnavailable(statusCode: 503);
        rig.svc.refreshSession();
        async.flushMicrotasks();
        expect(rig.svc.hasPendingRefreshRetry, isTrue);

        rig.svc.dispose();
        expect(rig.svc.hasPendingRefreshRetry, isFalse);
        async.elapse(const Duration(hours: 1));
        expect(rig.endpoint.refreshes, hasLength(1));
      });
    });

    test('a retry that hits a dead grant logs out and stops', () {
      fakeAsync((async) {
        final rig = _Rig(retry: const RefreshRetryPolicy());
        seedSession(rig.svc, rig.store);
        async.flushMicrotasks();
        var calls = 0;
        rig.endpoint.onRefresh = (_) async {
          calls++;
          if (calls == 1) throw const AuthUnavailable(statusCode: 503);
          throw const AuthUnauthorized(statusCode: 400);
        };
        rig.svc.refreshSession();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 15));

        expect(rig.endpoint.refreshes, hasLength(2));
        expect(rig.svc.isAuthenticated, isFalse);
        expect(rig.forced, 1);
        expect(rig.svc.hasPendingRefreshRetry, isFalse);
        async.elapse(const Duration(hours: 1));
        expect(rig.endpoint.refreshes, hasLength(2));
        rig.svc.dispose();
      });
    });
  });
  group('session identity: a refresh taken while a new session is being '
      'persisted', () {
    // Session A is in memory. An exchange for B claims B's generation, then
    // parks inside its first store write (memory still holds A). A refresh
    // started in that window took A's refresh token; its reply, whether it
    // lands while B is still writing or after B is adopted, must neither
    // overwrite B (success) nor log B out (unauthorized).
    for (final reply in <String, Future<TokenResponse> Function()>{
      'succeeds': () async => tokens(
        'stale-a',
        refresh: const RefreshTokenPresent('stale-r'),
        id: 'stale-id',
        expiresAt: inOneDay(),
      ),
      'is unauthorized': () async =>
          throw const AuthUnauthorized(statusCode: 400),
    }.entries) {
      for (final afterAdoption in [false, true]) {
        final lands = afterAdoption
            ? 'after B is adopted'
            : 'while B is still writing';
        test('the refresh ${reply.key}, landing $lands: B survives in '
            'memory and on disk, not logged out', () async {
          final rig = _Rig();
          await seedSession(rig.svc, rig.store); // A: a0 / r0 / id0
          final barrier = Barrier();
          rig.store.beforeWrite = barrier.call;
          rig.endpoint.onExchange = (_) async => tokens(
            'b-a',
            refresh: const RefreshTokenPresent('b-r'),
            id: 'b-id',
            expiresAt: inOneDay(),
          );
          final replyGate = Completer<void>();
          rig.endpoint.onRefresh = (_) async {
            if (afterAdoption) await replyGate.future;
            return reply.value();
          };

          final exchange = rig.svc.exchangeAuthorizationCode(
            'c',
            codeVerifier: 'v',
            redirectUri: 'app://cb',
          );
          await barrier.entered;
          expect(rig.svc.accessToken, 'a0', reason: 'memory still holds A');
          final refresh = rig.svc.refreshSession();
          await pumpEventQueue();
          expect(
            rig.endpoint.refreshes,
            ['r0'],
            reason: 'the refresh went out in the window, with A\'s token',
          );

          barrier.release();
          final exchanged = await exchange;
          if (afterAdoption) replyGate.complete();
          final outcome = await refresh;

          // The harm first: B overwritten by A's lineage, or logged out.
          expect(rig.forced, 0, reason: 'B must not be logged out');
          expect(rig.svc.accessToken, 'b-a');
          expect(rig.svc.idToken, 'b-id');
          expect(rig.svc.hasRefreshToken, isTrue);
          expect(rig.store.data[kAccess], 'b-a');
          expect(rig.store.data[kRefresh], 'b-r');
          expect(rig.store.data[kId], 'b-id');
          expect(exchanged, isTrue);
          expect(outcome, RefreshOutcome.discarded);
          // B's own next refresh presents B's token.
          rig.endpoint.onRefresh = (_) async =>
              tokens('b-a2', expiresAt: inOneDay());
          expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
          expect(rig.endpoint.refreshes.last, 'b-r');
          rig.svc.dispose();
        });
      }
    }

    test('a refresh of the new session does not join the old session\'s '
        'in-flight call', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      final oldReply = Completer<TokenResponse>();
      rig.endpoint.onRefresh = (token) async => token == 'r0'
          ? oldReply.future
          : tokens(
              'b-a2',
              refresh: const RefreshTokenPresent('b-r2'),
              expiresAt: inOneDay(),
            );
      rig.endpoint.onExchange = (_) async => tokens(
        'b-a',
        refresh: const RefreshTokenPresent('b-r'),
        expiresAt: inOneDay(),
      );

      final stale = rig.svc.refreshSession(); // A's, still in flight
      expect(
        await rig.svc.exchangeAuthorizationCode(
          'c',
          codeVerifier: 'v',
          redirectUri: 'app://cb',
        ),
        isTrue,
      );
      final fresh = rig.svc.refreshSession(); // B's
      await pumpEventQueue();
      expect(
        rig.endpoint.refreshes,
        ['r0', 'b-r'],
        reason: 'B gets its own call, not A\'s stale result',
      );
      expect(await fresh, RefreshOutcome.refreshed);
      oldReply.complete(
        tokens('stale-a', refresh: const RefreshTokenPresent('stale-r')),
      );
      expect(await stale, RefreshOutcome.discarded);
      expect(rig.svc.accessToken, 'b-a2');
      expect(rig.store.data[kRefresh], 'b-r2');
      rig.svc.dispose();
    });

    test('restoreFromStorage during a new session\'s write pass waits for '
        'it: a refresh right after the restore refreshes B, not A', () async {
      final rig = _Rig();
      // A is on disk only (a previous run), not yet restored.
      rig.store.data
        ..[kAccess] = 'a0'
        ..[kRefresh] = 'r0'
        ..[kId] = 'id0'
        ..[kExpires] = inOneDay().toIso8601String();
      final barrier = Barrier();
      rig.store.beforeWrite = barrier.call;
      rig.endpoint.onExchange = (_) async => tokens(
        'b-a',
        refresh: const RefreshTokenPresent('b-r'),
        expiresAt: inOneDay(),
      );
      rig.endpoint.onRefresh = (token) async => tokens(
        '$token-rotated-a',
        refresh: RefreshTokenPresent('$token-rotated-r'),
        expiresAt: inOneDay(),
      );

      final exchange = rig.svc.exchangeAuthorizationCode(
        'c',
        codeVerifier: 'v',
        redirectUri: 'app://cb',
      );
      await barrier.entered;
      // As an app's cold start does: restore, then refresh straight away.
      final restored = rig.svc.restoreFromStorage();
      final refreshed = restored.then((_) => rig.svc.refreshSession());
      await pumpEventQueue();
      barrier.release();

      expect(await exchange, isTrue);
      expect(await restored, isTrue);
      expect(await refreshed, RefreshOutcome.refreshed);
      expect(rig.endpoint.refreshes, ['b-r'], reason: 'never A\'s token');
      expect(rig.svc.accessToken, 'b-r-rotated-a');
      expect(rig.store.data[kRefresh], 'b-r-rotated-r');
      expect(rig.forced, 0);
      rig.svc.dispose();
    });

    test('logout while restoreFromStorage is reading: nothing is '
        'restored', () async {
      final rig = _Rig();
      rig.store.data
        ..[kAccess] = 'a0'
        ..[kRefresh] = 'r0'
        ..[kId] = 'id0'
        ..[kExpires] = inOneDay().toIso8601String();
      final barrier = Barrier();
      rig.store.beforeRead = barrier.call;

      final restored = rig.svc.restoreFromStorage();
      await barrier.entered;
      final loggedOut = rig.svc.logout(notify: false);
      barrier.release();

      expect(await restored, isFalse);
      await loggedOut;
      expect(rig.svc.isAuthenticated, isFalse);
      expect(rig.svc.hasRefreshToken, isFalse);
      expect(rig.store.data, isEmpty);
      rig.svc.dispose();
    });

    test('a session restored after a logout refreshes normally', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      await rig.svc.logout(notify: false);
      await seedSession(rig.svc, rig.store, refresh: 'r9');
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: _rotated, expiresAt: inOneDay());

      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
      expect(rig.endpoint.refreshes, ['r9']);
      expect(rig.svc.accessToken, 'a1');
      rig.svc.dispose();
    });
  });

  group('restore publishes only a session the store is known to hold', () {
    /// Seeds the store as a previous process would have left it, without
    /// restoring it into memory.
    void storeOnDisk(RecordingStore store, String access, String refresh) {
      store.data
        ..[kAccess] = access
        ..[kRefresh] = refresh
        ..[kId] = 'id-$access'
        ..[kExpires] = inOneDay().toIso8601String();
    }

    TokenResponse sessionB({bool withRefresh = true}) => tokens(
      'b-a',
      refresh: withRefresh
          ? const RefreshTokenPresent('b-r')
          : const RefreshTokenAbsent(),
      id: 'b-id',
      expiresAt: inOneDay(),
    );

    Future<bool> signInB(_Rig rig) => rig.svc.exchangeAuthorizationCode(
      'c',
      codeVerifier: 'v',
      redirectUri: 'app://cb',
    );

    test('cold start: a fresh service restores what a previous process '
        'stored', () async {
      final rig = _Rig();
      storeOnDisk(rig.store, 'a0', 'r0');
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: _rotated, expiresAt: inOneDay());

      expect(await rig.svc.restoreFromStorage(), isTrue);
      expect(rig.svc.accessToken, 'a0');
      expect(rig.svc.idToken, 'id-a0');
      expect(rig.svc.isTokenExpired, isFalse);
      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
      expect(rig.endpoint.refreshes, ['r0']);
      rig.svc.dispose();
    });

    test('B\'s store write fails while a restore waits behind it: A never '
        'comes back, B stays current, the next refresh sends B\'s '
        'token', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A: memory and store
      final barrier = Barrier();
      // Park B at its first TOKEN write (after the in-progress marker).
      rig.store.beforeWrite = (key) async {
        if (key == kRefresh) await barrier(key);
      };
      rig.endpoint.onExchange = (_) async => sessionB();
      rig.endpoint.onRefresh = (token) async => tokens(
        '$token-rotated-a',
        refresh: RefreshTokenPresent('$token-rotated-r'),
        expiresAt: inOneDay(),
      );

      final exchange = signInB(rig);
      await barrier.entered; // B claimed its generation; first write parked
      final restored = rig.svc.restoreFromStorage(); // queued behind B
      // B's parked write fails before it changes a token key (the store
      // still holds A, complete and readable).
      rig.store.writeError = StateError('disk full');
      barrier.release();
      final exchanged = await exchange;
      final restoredResult = await restored;

      expect(rig.svc.accessToken, 'b-a', reason: 'A must never come back');
      expect(rig.svc.idToken, 'b-id');
      expect(exchanged, isTrue, reason: 'B is adopted, memory-only');
      expect(restoredResult, isTrue, reason: 'a usable session is in memory');
      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
      expect(rig.endpoint.refreshes, ['b-r'], reason: 'never A\'s r0');
      expect(rig.svc.accessToken, 'b-r-rotated-a');
      expect(rig.forced, 0);
      // Nor can the next launch bring A back: the failed pass cleared the
      // token keys and left the store marked.
      expect(rig.store.data.keys, [kMarker]);
      expect(await _restart(rig.store).restoreFromStorage(), isFalse);
      rig.svc.dispose();
    });

    test('a partial write pass (first write lands, second throws) is cleared '
        'from the store; a restore keeps B', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A: a0 / r0 on disk
      rig.store.beforeWrite = (key) async {
        if (key == kAccess) throw StateError('disk full');
      };
      rig.endpoint.onExchange = (_) async => sessionB();
      rig.endpoint.onRefresh = (token) async =>
          tokens('$token-rotated-a', expiresAt: inOneDay());

      expect(await signInB(rig), isTrue);
      expect(
        rig.store.data.keys,
        [kMarker],
        reason: 'never B\'s refresh token next to A\'s access token',
      );
      expect(await rig.svc.restoreFromStorage(), isTrue);
      expect(rig.svc.accessToken, 'b-a');
      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
      expect(rig.endpoint.refreshes, ['b-r']);
      rig.svc.dispose();
    });

    test('a partial write pass whose clean-up also fails is never restored, '
        'even once the session has ended', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A: a0 / r0 on disk
      rig.store
        ..beforeWrite = (key) async {
          if (key == kAccess) throw StateError('disk full');
        }
        ..deleteError = StateError('keychain locked');
      rig.endpoint.onExchange = (_) async => sessionB();

      expect(await signInB(rig), isTrue);
      expect(rig.store.data[kRefresh], 'b-r', reason: 'precondition: torn');
      expect(rig.store.data[kAccess], 'a0', reason: 'precondition: torn');
      await rig.svc.logout(notify: false); // its deletions fail too

      expect(await rig.svc.restoreFromStorage(), isFalse);
      expect(rig.svc.isAuthenticated, isFalse);
      expect(rig.svc.hasRefreshToken, isFalse);
      rig.svc.dispose();
    });

    test('a logout landing mid-write whose deletions fail is not undone by '
        'a restore', () async {
      final rig = _Rig();
      final barrier = Barrier();
      rig.store.beforeWrite = barrier.call;
      rig.endpoint.onExchange = (_) async => sessionB();

      final exchange = signInB(rig);
      await barrier.entered;
      rig.store.deleteError = StateError('keychain locked');
      final loggedOut = rig.svc.logout(notify: false);
      barrier.release();
      expect(await exchange, isFalse);
      await loggedOut;
      expect(rig.store.data[kAccess], 'b-a', reason: 'precondition: B on disk');

      expect(
        await rig.svc.restoreFromStorage(),
        isFalse,
        reason: 'the user signed out of B',
      );
      expect(rig.svc.isAuthenticated, isFalse);
      rig.svc.dispose();
    });

    test('once the store has failed, restore never trusts it again in this '
        'process', () async {
      final rig = _Rig();
      rig.store.writeError = StateError('disk full');
      rig.endpoint.onExchange = (_) async => sessionB();
      expect(await signInB(rig), isTrue); // memory-only
      await rig.svc.logout(notify: false); // its deletions succeed
      // Whatever the store now holds was not written by this process.
      storeOnDisk(rig.store, 'x-a', 'x-r');

      expect(await rig.svc.restoreFromStorage(), isFalse);
      expect(rig.svc.isAuthenticated, isFalse);
      rig.svc.dispose();
    });

    for (final withRefresh in [true, false]) {
      test('a session already in memory (${withRefresh ? 'with' : 'without'} '
          'a refresh token) is never replaced; restore returns '
          '$withRefresh', () async {
        final rig = _Rig();
        rig.endpoint.onExchange = (_) async =>
            sessionB(withRefresh: withRefresh);
        expect(await signInB(rig), isTrue); // fully persisted
        // The store changed under it (another writer).
        storeOnDisk(rig.store, 'x-a', 'x-r');

        expect(await rig.svc.restoreFromStorage(), withRefresh);
        expect(rig.svc.accessToken, 'b-a');
        expect(rig.svc.idToken, 'b-id');
        expect(rig.svc.hasRefreshToken, withRefresh);
        rig.svc.dispose();
      });
    }
  });

  group('the persisted in-progress marker (across a restart)', () {
    void storeOnDisk(RecordingStore store) => store.data
      ..[kAccess] = 'a0'
      ..[kRefresh] = 'r0'
      ..[kId] = 'id0'
      ..[kExpires] = inOneDay().toIso8601String();

    TokenResponse sessionB() => tokens(
      'b-a',
      refresh: const RefreshTokenPresent('b-r'),
      id: 'b-id',
      expiresAt: inOneDay(),
    );

    Future<bool> signInB(_Rig rig) => rig.svc.exchangeAuthorizationCode(
      'c',
      codeVerifier: 'v',
      redirectUri: 'app://cb',
    );

    test('a store with no marker (written by an earlier version) restores '
        'normally after a restart', () async {
      final store = RecordingStore();
      storeOnDisk(store); // the four token keys only, as v0.1.0 writes them
      final endpoint = FakeEndpoint(
        onRefresh: (_) async =>
            tokens('a1', refresh: _rotated, expiresAt: inOneDay()),
      );
      final svc = _restart(store, endpoint);

      expect(await svc.restoreFromStorage(), isTrue);
      expect(svc.accessToken, 'a0');
      expect(await svc.refreshSession(), RefreshOutcome.refreshed);
      expect(endpoint.refreshes, ['r0']);
      svc.dispose();
    });

    test('a completed pass removes the marker: its session restores after '
        'a restart', () async {
      final rig = _Rig();
      rig.endpoint.onExchange = (_) async => sessionB();
      expect(await signInB(rig), isTrue);
      rig.svc.dispose();

      final next = _restart(rig.store);
      expect(await next.restoreFromStorage(), isTrue);
      expect(next.accessToken, 'b-a');
      expect(next.idToken, 'b-id');
      expect(rig.store.data.containsKey(kMarker), isFalse);
      next.dispose();
    });

    test('first token write lands, the second throws, the clean-up '
        'deletions fail: nothing is restored after a restart', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A on disk, unexpired
      rig.store
        ..beforeWrite = (key) async {
          if (key == kAccess) throw StateError('disk full');
        }
        ..beforeDelete = (key) async {
          if (key != kMarker) throw StateError('keychain locked');
        };
      rig.endpoint.onExchange = (_) async => sessionB();

      expect(await signInB(rig), isTrue); // B: memory-only
      expect(rig.store.data[kRefresh], 'b-r', reason: 'precondition: torn');
      expect(rig.store.data[kAccess], 'a0', reason: 'precondition: torn');
      rig.svc.dispose();

      final next = _restart(rig.store);
      expect(await next.restoreFromStorage(), isFalse);
      expect(next.isAuthenticated, isFalse, reason: 'not A, not torn A/B');
      expect(next.hasRefreshToken, isFalse);
      next.dispose();
    });

    test('the marker cannot be written: the store is left as it was and B '
        'is memory-only', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A
      final before = Map<String, String>.of(rig.store.data);
      rig.store.beforeWrite = (key) async {
        if (key == kMarker) throw StateError('keychain locked');
      };
      rig.endpoint.onExchange = (_) async => sessionB();
      rig.endpoint.onRefresh = (_) async => tokens(
        'b-a2',
        refresh: const RefreshTokenPresent('b-r2'),
        expiresAt: inOneDay(),
      );

      expect(await signInB(rig), isTrue);
      expect(rig.svc.accessToken, 'b-a');
      expect(rig.store.data, before, reason: 'the store is untouched');
      expect(
        rig.store.ops.where((op) => !op.endsWith(kMarker)),
        isEmpty,
        reason: 'no token key written or deleted',
      );
      // Memory-only from now on: a refresh persists nothing either.
      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
      expect(rig.svc.accessToken, 'b-a2');
      expect(rig.store.data, before);
      rig.svc.dispose();

      // After a restart the store's previous complete session (A) is
      // restored: the documented limit when not even the marker can be
      // written.
      final next = _restart(rig.store);
      expect(await next.restoreFromStorage(), isTrue);
      expect(next.accessToken, 'a0');
      next.dispose();
    });

    test('the marker cannot be removed: the whole session stays on disk but '
        'is not restored after a restart', () async {
      final rig = _Rig();
      rig.store.beforeDelete = (key) async {
        if (key == kMarker) throw StateError('keychain locked');
      };
      rig.endpoint.onExchange = (_) async => sessionB();

      expect(await signInB(rig), isTrue);
      expect(rig.svc.accessToken, 'b-a');
      expect(rig.store.data[kAccess], 'b-a', reason: 'precondition: whole');
      expect(rig.store.data[kRefresh], 'b-r', reason: 'precondition: whole');
      expect(rig.store.data.containsKey(kMarker), isTrue);
      rig.svc.dispose();

      final next = _restart(rig.store);
      expect(await next.restoreFromStorage(), isFalse);
      expect(next.isAuthenticated, isFalse);
      next.dispose();
    });

    test('a logout whose deletions fail is not undone after a restart; once '
        'the store works, a logout clears the marker', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A
      rig.store.beforeDelete = (key) async {
        if (key != kMarker) throw StateError('keychain locked');
      };
      await rig.svc.logout(notify: false);
      expect(rig.store.data[kAccess], 'a0', reason: 'precondition: A on disk');
      rig.svc.dispose();

      final next = _restart(rig.store);
      expect(
        await next.restoreFromStorage(),
        isFalse,
        reason: 'the user signed out of A',
      );
      expect(next.isAuthenticated, isFalse);

      rig.store.beforeDelete = null; // the keychain is back
      await next.logout(notify: false);
      expect(rig.store.data, isEmpty, reason: 'token keys and marker gone');
      next.dispose();
    });

    test('a refresh interrupted after its refresh-token write (the process '
        'dies): a restart restores the same account and refreshes with the '
        'NEW refresh token', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A: a0 / r0
      final crash = Barrier(); // never released: the process dies here
      rig.store.beforeWrite = (key) async {
        if (key == kAccess) await crash(key);
      };
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: _rotated, expiresAt: inOneDay());

      unawaited(rig.svc.refreshSession());
      await crash.entered;
      expect(rig.store.data[kRefresh], 'r1', reason: 'the rotation landed');
      expect(rig.store.data[kAccess], 'a0', reason: 'the access write did not');

      final endpoint = FakeEndpoint(
        onRefresh: (_) async => tokens(
          'a2',
          refresh: const RefreshTokenPresent('r2'),
          expiresAt: inOneDay(),
        ),
      );
      final next = _restart(rig.store, endpoint);
      expect(await next.restoreFromStorage(), isTrue);
      expect(next.accessToken, 'a0', reason: 'the same account');
      expect(await next.refreshSession(), RefreshOutcome.refreshed);
      expect(endpoint.refreshes, ['r1'], reason: 'never the revoked r0');
      expect(next.accessToken, 'a2');
      next.dispose();
    });

    test('a refresh whose write and clean-up both fail leaves only the same '
        'account\'s keys, restorable after a restart', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A: a0 / r0 / id0
      rig.store
        ..beforeWrite = (key) async {
          if (key == kAccess) throw StateError('disk full');
        }
        ..deleteError = StateError('keychain locked');
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: _rotated, expiresAt: inOneDay());

      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
      expect(rig.svc.accessToken, 'a1', reason: 'memory-only from now on');
      expect(rig.store.data[kRefresh], 'r1');
      expect(rig.store.data[kAccess], 'a0');
      expect(rig.store.data[kId], 'id0');
      expect(rig.store.data.containsKey(kMarker), isFalse);
      rig.svc.dispose();

      final endpoint = FakeEndpoint(
        onRefresh: (_) async => tokens('a2', expiresAt: inOneDay()),
      );
      final next = _restart(rig.store, endpoint);
      expect(await next.restoreFromStorage(), isTrue);
      expect(next.accessToken, 'a0');
      expect(next.idToken, 'id0');
      await next.refreshSession();
      expect(endpoint.refreshes, ['r1']);
      next.dispose();
    });

    test('a refresh never touches a marker an earlier pass left', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store);
      rig.store.data[kMarker] = '1'; // left by an earlier failed pass
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: _rotated, expiresAt: inOneDay());

      expect(await rig.svc.refreshSession(), RefreshOutcome.refreshed);
      expect(rig.store.data[kRefresh], 'r1');
      expect(rig.store.data[kMarker], '1', reason: 'not this pass\'s marker');
      expect(rig.store.ops.where((op) => op.endsWith(kMarker)), isEmpty);
      rig.svc.dispose();

      expect(await _restart(rig.store).restoreFromStorage(), isFalse);
    });

    /// The store a previous process left after a sign-in failed part-way:
    /// A's access token beside B's refresh token, marked.
    void tornAndMarked(RecordingStore store) => store.data
      ..[kAccess] = 'a0'
      ..[kRefresh] = 'b-r'
      ..[kId] = 'id0'
      ..[kExpires] = inOneDay().toIso8601String()
      ..[kMarker] = '1';

    test('an existing marker is never rewritten: a sign-in on a store whose '
        'writes fail destructively keeps it, so a restart still '
        'refuses', () async {
      final store = RecordingStore();
      tornAndMarked(store);
      final endpoint = FakeEndpoint(
        onExchange: (_) async => tokens(
          'c-a',
          refresh: const RefreshTokenPresent('c-r'),
          expiresAt: inOneDay(),
        ),
      );
      final svc = _restart(store, endpoint);
      expect(await svc.restoreFromStorage(), isFalse);
      // The keychain now fails every update destructively.
      store.destructiveWriteFailure = (_) => true;

      expect(
        await svc.exchangeAuthorizationCode(
          'c',
          codeVerifier: 'v',
          redirectUri: 'app://cb',
        ),
        isTrue,
        reason: 'C is adopted, memory-only',
      );
      svc.dispose();

      final next = _restart(store);
      expect(await next.restoreFromStorage(), isFalse, reason: 'never A/B');
      expect(next.isAuthenticated, isFalse);
      expect(store.data[kMarker], '1', reason: 'the marker survives');
      expect(store.ops, isNot(contains('write:$kMarker')));
      next.dispose();
    });

    test('an existing marker is never rewritten: a logout on a store whose '
        'writes fail destructively and whose deletions fail keeps it, so a '
        'restart still refuses', () async {
      final store = RecordingStore();
      tornAndMarked(store);
      final svc = _restart(store);
      expect(await svc.restoreFromStorage(), isFalse);
      store.destructiveWriteFailure = (_) => true;
      store.deleteError = StateError('keychain locked');

      await svc.logout(notify: false);
      svc.dispose();

      final next = _restart(store);
      expect(await next.restoreFromStorage(), isFalse, reason: 'never A/B');
      expect(next.isAuthenticated, isFalse);
      expect(store.data[kMarker], '1', reason: 'the marker survives');
      expect(store.ops, isNot(contains('write:$kMarker')));
      next.dispose();
    });

    test('in-process: a logout that can neither mark the store nor delete '
        'its keys is not undone by a restore', () async {
      final rig = _Rig();
      await seedSession(rig.svc, rig.store); // A
      rig.store
        ..beforeWrite = (key) async {
          if (key == kMarker) throw StateError('keychain locked');
        }
        ..deleteError = StateError('keychain locked');
      await rig.svc.logout(notify: false);
      expect(rig.store.data[kAccess], 'a0', reason: 'precondition: A on disk');
      expect(rig.store.data.containsKey(kMarker), isFalse);

      expect(await rig.svc.restoreFromStorage(), isFalse);
      expect(rig.svc.isAuthenticated, isFalse);
      rig.svc.dispose();
    });
  });

  group('exchangeAuthorizationCode reports a discarded session as false', () {
    test('exchange → logout → success: false, nothing stored', () async {
      final rig = _Rig();
      final reply = Completer<TokenResponse>();
      rig.endpoint.onExchange = (_) => reply.future;

      final ok = rig.svc.exchangeAuthorizationCode(
        'c',
        codeVerifier: 'v',
        redirectUri: 'app://cb',
      );
      await rig.svc.logout(notify: false);
      reply.complete(
        tokens('a1', refresh: _rotated, id: 'id1', expiresAt: inOneDay()),
      );

      expect(await ok, isFalse, reason: 'callers treat true as signed in');
      expect(rig.svc.isAuthenticated, isFalse);
      expect(rig.svc.hasRefreshToken, isFalse);
      expect(rig.store.data, isEmpty);
      rig.svc.dispose();
    });

    test('logout landing mid-write of the exchange: false, nothing '
        'stored', () async {
      final rig = _Rig();
      final barrier = Barrier();
      rig.store.beforeWrite = barrier.call;
      rig.endpoint.onExchange = (_) async =>
          tokens('a1', refresh: _rotated, id: 'id1', expiresAt: inOneDay());

      final ok = rig.svc.exchangeAuthorizationCode(
        'c',
        codeVerifier: 'v',
        redirectUri: 'app://cb',
      );
      await barrier.entered;
      final loggedOut = rig.svc.logout(notify: false);
      barrier.release();

      expect(await ok, isFalse);
      await loggedOut;
      expect(rig.svc.isAuthenticated, isFalse);
      expect(rig.store.data, isEmpty);
      rig.svc.dispose();
    });
  });

  group('dispose is terminal', () {
    test('refresh in flight → dispose → unavailable: no retry armed, no '
        'further calls', () {
      fakeAsync((async) {
        final rig = _Rig(retry: const RefreshRetryPolicy());
        seedSession(rig.svc, rig.store);
        async.flushMicrotasks();
        final reply = Completer<TokenResponse>();
        rig.endpoint.onRefresh = (_) => reply.future;

        RefreshOutcome? outcome;
        rig.svc.refreshSession().then((o) => outcome = o);
        async.flushMicrotasks();
        expect(rig.endpoint.refreshes, hasLength(1));

        rig.svc.dispose();
        reply.completeError(const AuthUnavailable(statusCode: 503));
        async.flushMicrotasks();

        expect(outcome, RefreshOutcome.unavailable);
        expect(rig.svc.hasPendingRefreshRetry, isFalse);
        expect(async.pendingTimers, isEmpty, reason: 'nothing re-armed');
        async.elapse(const Duration(hours: 1));
        expect(rig.endpoint.refreshes, hasLength(1));
        expect(rig.svc.accessToken, 'a0', reason: 'the session is kept');
      });
    });

    test('refresh in flight → dispose → success: the rotated tokens are '
        'persisted, but no proactive refresh is armed', () {
      fakeAsync((async) {
        final rig = _Rig(retry: const RefreshRetryPolicy());
        seedSession(rig.svc, rig.store);
        async.flushMicrotasks();
        final reply = Completer<TokenResponse>();
        rig.endpoint.onRefresh = (_) => reply.future;

        RefreshOutcome? outcome;
        rig.svc.refreshSession().then((o) => outcome = o);
        async.flushMicrotasks();
        rig.svc.dispose();
        reply.complete(
          tokens(
            'a1',
            refresh: _rotated,
            expiresAt: DateTime.now().add(const Duration(minutes: 10)),
          ),
        );
        async.flushMicrotasks();

        expect(outcome, RefreshOutcome.refreshed);
        expect(rig.svc.accessToken, 'a1');
        expect(
          rig.store.data[kRefresh],
          'r1',
          reason: 'the server already rotated r0: r1 must reach the store',
        );
        expect(async.pendingTimers, isEmpty, reason: 'nothing re-armed');
        async.elapse(const Duration(days: 2));
        expect(rig.endpoint.refreshes, hasLength(1));
      });
    });

    test('after dispose a refresh makes no request', () async {
      final rig = _Rig(retry: const RefreshRetryPolicy());
      await seedSession(rig.svc, rig.store);
      rig.endpoint.onRefresh = (_) async =>
          tokens('a1', refresh: _rotated, expiresAt: inOneDay());

      rig.svc.dispose();
      expect(await rig.svc.refreshSession(), RefreshOutcome.discarded);
      expect(await rig.svc.refreshAccessToken(), isFalse);
      expect(rig.endpoint.refreshes, isEmpty);
      expect(rig.svc.accessToken, 'a0');
      expect(rig.store.ops, isEmpty);
    });

    test('after dispose scheduleNextRefresh arms nothing', () {
      fakeAsync((async) {
        final rig = _Rig();
        seedSession(
          rig.svc,
          rig.store,
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        );
        async.flushMicrotasks();
        rig.endpoint.onRefresh = (_) async =>
            tokens('a1', refresh: _rotated, expiresAt: inOneDay());

        rig.svc.dispose();
        rig.svc.scheduleNextRefresh();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(days: 2));
        expect(rig.endpoint.refreshes, isEmpty);
      });
    });
  });
}
