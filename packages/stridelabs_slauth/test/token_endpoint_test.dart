import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

import 'support/fakes.dart';

HydraTokenEndpoint _endpoint(ScriptedAdapter adapter) =>
    HydraTokenEndpoint(config: testConfig, dio: dioWith(adapter));

const _exchangeRequest = TokenExchangeRequest(
  code: 'the-code',
  codeVerifier: 'the-verifier',
  redirectUri: 'slaudio://auth/callback',
);

/// Run [call] against both grants of a fresh endpoint answering [responder].
Future<List<Object?>> _bothGrants(
  ResponseBody Function(RequestOptions) responder,
) async {
  final errors = <Object?>[];
  for (final call in <Future<TokenResponse> Function(HydraTokenEndpoint)>[
    (e) => e.exchange(_exchangeRequest),
    (e) => e.refresh('the-refresh-token'),
  ]) {
    final endpoint = _endpoint(ScriptedAdapter(responder));
    try {
      await call(endpoint);
      errors.add(null);
    } catch (e) {
      errors.add(e);
    }
  }
  return errors;
}

/// Same, but the adapter throws [error] instead of answering.
Future<List<Object?>> _bothGrantsThrowing(
  Object Function(RequestOptions) error,
) => _bothGrants((o) => throw error(o));

void main() {
  group('HydraTokenEndpoint request shape (today\'s exact form posts)', () {
    test('exchange posts the authorization_code grant form', () async {
      final adapter = ScriptedAdapter(
        (_) => jsonBody({'access_token': 'a', 'refresh_token': 'r'}),
      );
      await _endpoint(adapter).exchange(_exchangeRequest);

      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.options.method, 'POST');
      expect(req.options.uri.toString(), 'https://auth.test/oauth2/token');
      expect(req.options.contentType, Headers.formUrlEncodedContentType);
      expect(req.options.responseType, ResponseType.json);
      final form = req.options.data as Map;
      expect(form.keys.toList(), [
        'grant_type',
        'code',
        'redirect_uri',
        'client_id',
        'code_verifier',
      ]);
      expect(form, {
        'grant_type': 'authorization_code',
        'code': 'the-code',
        'redirect_uri': 'slaudio://auth/callback',
        'client_id': 'slaudio-mobile',
        'code_verifier': 'the-verifier',
      });
      expect(
        req.body,
        'grant_type=authorization_code&code=the-code'
        '&redirect_uri=slaudio%3A%2F%2Fauth%2Fcallback'
        '&client_id=slaudio-mobile&code_verifier=the-verifier',
      );
    });

    test('refresh posts the refresh_token grant form', () async {
      final adapter = ScriptedAdapter(
        (_) => jsonBody({'access_token': 'a', 'refresh_token': 'r'}),
      );
      await _endpoint(adapter).refresh('the-refresh-token');

      final req = adapter.requests.single;
      expect(req.options.method, 'POST');
      expect(req.options.uri.toString(), 'https://auth.test/oauth2/token');
      expect(req.options.contentType, Headers.formUrlEncodedContentType);
      expect(req.options.responseType, ResponseType.json);
      final form = req.options.data as Map;
      expect(form.keys.toList(), ['grant_type', 'refresh_token', 'client_id']);
      expect(form, {
        'grant_type': 'refresh_token',
        'refresh_token': 'the-refresh-token',
        'client_id': 'slaudio-mobile',
      });
      expect(
        req.body,
        'grant_type=refresh_token&refresh_token=the-refresh-token'
        '&client_id=slaudio-mobile',
      );
    });

    test('parses a JSON-object body and a raw-string body alike', () async {
      final when = DateTime.utc(2030, 1, 2, 3, 4, 5);
      final payload = {
        'access_token': 'a1',
        'refresh_token': 'r1',
        'id_token': 'i1',
        'expires_at': when.toIso8601String(),
      };
      for (final body in [
        jsonBody(payload),
        // Content-Type sniff miss: Dio hands back a String despite json.
        rawBody(
          '{"access_token":"a1","refresh_token":"r1","id_token":"i1",'
          '"expires_at":"${when.toIso8601String()}"}',
          200,
          contentType: 'text/plain',
        ),
      ]) {
        TokenResponse? res;
        Object? error;
        try {
          res = await _endpoint(ScriptedAdapter((_) => body)).refresh('r0');
        } catch (e) {
          error = e;
        }
        expect(error, isNull, reason: 'the body must parse');
        expect(res!.accessToken, 'a1');
        expect(res.refreshToken, isA<RefreshTokenPresent>());
        expect((res.refreshToken as RefreshTokenPresent).value, 'r1');
        expect(res.idToken, 'i1');
        expect(res.expiresAt, when);
      }
    });
  });

  group('HydraTokenEndpoint error mapping', () {
    for (final status in [400, 401]) {
      test('$status → AuthUnauthorized (both grants)', () async {
        final errors = await _bothGrants(
          (_) => jsonBody({'error': 'invalid_grant'}, status),
        );
        for (final e in errors) {
          expect(e, isA<AuthUnauthorized>());
          expect((e as AuthUnauthorized).statusCode, status);
          expect(e.dioType, DioExceptionType.badResponse);
        }
      });
    }

    for (final status in [500, 502, 503, 408, 429, 403, 404]) {
      test('$status → AuthUnavailable (both grants)', () async {
        final errors = await _bothGrants(
          (_) => jsonBody({'error': 'server_error'}, status),
        );
        for (final e in errors) {
          expect(e, isA<AuthUnavailable>());
          expect((e as AuthUnavailable).statusCode, status);
        }
      });
    }

    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.connectionError,
    ]) {
      test('${type.name} → AuthUnavailable (both grants)', () async {
        final errors = await _bothGrantsThrowing(
          (o) => DioException(requestOptions: o, type: type),
        );
        for (final e in errors) {
          expect(e, isA<AuthUnavailable>());
          expect((e as AuthUnavailable).dioType, type);
          expect(e.statusCode, isNull);
        }
      });
    }

    test('a raw socket error → AuthUnavailable (both grants)', () async {
      final errors = await _bothGrantsThrowing(
        (_) => const SocketException('connection refused'),
      );
      for (final e in errors) {
        expect(e, isA<AuthUnavailable>());
      }
    });

    test('malformed 200 bodies → AuthUnavailable (both grants)', () async {
      final bodies = <ResponseBody Function()>[
        // Invalid JSON with a JSON content type (Dio's own decode fails).
        () => rawBody('{not json', 200),
        // Not JSON at all, plain text.
        () => rawBody('<html>oops</html>', 200, contentType: 'text/plain'),
        // JSON, but not an object.
        () => jsonBody(['access_token', 'a']),
        // An object without an access token.
        () => jsonBody({'refresh_token': 'r'}),
        // An empty access token.
        () => jsonBody({'access_token': '', 'refresh_token': 'r'}),
        // A mistyped field.
        () => jsonBody({'access_token': 'a', 'refresh_token': 42}),
        () => jsonBody({'access_token': 'a', 'expires_in': 'soon'}),
      ];
      for (final body in bodies) {
        final errors = await _bothGrants((_) => body());
        for (final e in errors) {
          expect(e, isA<AuthUnavailable>());
        }
      }
    });
  });

  group('HydraTokenEndpoint classifies the status itself', () {
    // Whatever the injected client's own status policy.
    Dio permissive(ScriptedAdapter adapter) => Dio(
      BaseOptions(baseUrl: testConfig.baseUrl, validateStatus: (_) => true),
    )..httpClientAdapter = adapter;
    Dio stock(ScriptedAdapter adapter) => dioWith(adapter);

    /// Both grants on an endpoint whose client is built by [client].
    Future<List<Object?>> bothGrantsWith(
      Dio Function(ScriptedAdapter) client,
      ResponseBody Function() body,
    ) async {
      final errors = <Object?>[];
      for (final call in <Future<TokenResponse> Function(HydraTokenEndpoint)>[
        (e) => e.exchange(_exchangeRequest),
        (e) => e.refresh('the-refresh-token'),
      ]) {
        final adapter = ScriptedAdapter((_) => body());
        final endpoint = HydraTokenEndpoint(
          config: testConfig,
          dio: client(adapter),
        );
        try {
          await call(endpoint);
          errors.add(null);
        } catch (e) {
          errors.add(e);
        }
      }
      return errors;
    }

    for (final status in [400, 401]) {
      test('$status invalid_grant on a permissive client → '
          'AuthUnauthorized', () async {
        final errors = await bothGrantsWith(
          permissive,
          () => jsonBody({'error': 'invalid_grant'}, status),
        );
        for (final e in errors) {
          expect(e, isA<AuthUnauthorized>());
          expect((e as AuthUnauthorized).statusCode, status);
        }
      });
    }

    for (final client in {'stock': stock, 'permissive': permissive}.entries) {
      for (final body in <String, ResponseBody Function()>{
        'malformed JSON': () => rawBody('{"error": invalid', 401),
        'plain text': () =>
            rawBody('Unauthorized', 401, contentType: 'text/plain'),
        'an HTML page': () =>
            rawBody('<h1>401</h1>', 401, contentType: 'text/html'),
        'an empty body': () => rawBody('', 401),
      }.entries) {
        test('401 with ${body.key} (${client.key} client) → '
            'AuthUnauthorized', () async {
          final errors = await bothGrantsWith(client.value, body.value);
          for (final e in errors) {
            expect(e, isA<AuthUnauthorized>());
            expect((e as AuthUnauthorized).statusCode, 401);
          }
        });
      }
    }

    test('503 on a permissive client → AuthUnavailable', () async {
      final errors = await bothGrantsWith(
        permissive,
        () => jsonBody({'error': 'temporarily_unavailable'}, 503),
      );
      for (final e in errors) {
        expect(e, isA<AuthUnavailable>());
        expect((e as AuthUnavailable).statusCode, 503);
        // Classified by its status, not by failing to parse the error body.
        expect(e.dioType, DioExceptionType.badResponse);
        expect(e.malformedResponse, isFalse);
      }
    });

    test('a permissive client still parses a 200', () async {
      final errors = await bothGrantsWith(
        permissive,
        () => jsonBody({'access_token': 'a', 'refresh_token': 'r'}),
      );
      expect(errors, [null, null]);
    });

    test('a 401 an interceptor resolved into a response → '
        'AuthUnauthorized', () async {
      Dio resolving(ScriptedAdapter adapter) =>
          dioWith(adapter)
            ..interceptors.add(
              InterceptorsWrapper(
                onError: (e, handler) => handler.resolve(
                  Response(
                    requestOptions: e.requestOptions,
                    statusCode: e.response?.statusCode,
                    data: {'error': 'invalid_grant'},
                  ),
                ),
              ),
            );
      final errors = await bothGrantsWith(
        resolving,
        () => jsonBody({'error': 'invalid_grant'}, 401),
      );
      for (final e in errors) {
        expect(e, isA<AuthUnauthorized>());
        expect((e as AuthUnauthorized).statusCode, 401);
      }
    });
  });

  group('TokenResponse parsing', () {
    test('refresh_token: absent / value / null / empty string', () {
      expect(
        TokenResponse.fromJson({'access_token': 'a'}).refreshToken,
        isA<RefreshTokenAbsent>(),
      );
      final present = TokenResponse.fromJson({
        'access_token': 'a',
        'refresh_token': 'r1',
      }).refreshToken;
      expect(present, isA<RefreshTokenPresent>());
      expect((present as RefreshTokenPresent).value, 'r1');
      expect(
        TokenResponse.fromJson({
          'access_token': 'a',
          'refresh_token': null,
        }).refreshToken,
        isA<RefreshTokenBlank>(),
      );
      expect(
        TokenResponse.fromJson({
          'access_token': 'a',
          'refresh_token': '',
        }).refreshToken,
        isA<RefreshTokenBlank>(),
      );
    });

    test('expiry: expires_at wins; expires_in may be any number', () {
      final at = DateTime.utc(2031, 5, 6);
      expect(
        TokenResponse.fromJson({
          'access_token': 'a',
          'expires_at': at.toIso8601String(),
          'expires_in': 5,
        }).expiresAt,
        at,
      );
      final before = DateTime.now();
      final fromIn = TokenResponse.fromJson({
        'access_token': 'a',
        'expires_in': 900.0,
      }).expiresAt!;
      expect(fromIn.difference(before).inSeconds, inInclusiveRange(899, 900));
      expect(TokenResponse.fromJson({'access_token': 'a'}).expiresAt, isNull);
      expect(
        TokenResponse.fromJson({
          'access_token': 'a',
          'expires_in': null,
        }).expiresAt,
        isNull,
      );
    });

    test('an empty id_token is treated as absent', () {
      expect(
        TokenResponse.fromJson({'access_token': 'a', 'id_token': ''}).idToken,
        isNull,
      );
    });

    test('fromBody: map, JSON string, and shapes it rejects', () {
      String? accessOf(Object? body) {
        try {
          return TokenResponse.fromBody(body).accessToken;
        } on FormatException {
          return null;
        }
      }

      expect(accessOf({'access_token': 'a'}), 'a');
      expect(accessOf('{"access_token":"a"}'), 'a');
      expect(accessOf(<Object?, Object?>{'access_token': 'a'}), 'a');
      for (final bad in <Object?>[null, 42, '[1]', '{bad', <Object>[]]) {
        expect(
          () => TokenResponse.fromBody(bad),
          throwsFormatException,
          reason: 'body: $bad',
        );
      }
    });

    test('FormatException messages never quote the body', () {
      const canary = 'CANARY-BODY-7f3a';
      for (final bad in <Object?>[
        '{"access_token": "$canary", oops',
        '"$canary"',
        {'access_token': 42, 'note': canary},
        {'access_token': canary, 'refresh_token': 7},
        {'access_token': canary, 'id_token': 7},
        {'access_token': canary, 'expires_at': 7},
        {'access_token': canary, 'expires_in': canary},
      ]) {
        try {
          TokenResponse.fromBody(bad);
          fail('expected a FormatException for $bad');
        } on FormatException catch (e) {
          expect(e.toString(), isNot(contains(canary)));
          expect(e.source?.toString() ?? '', isNot(contains(canary)));
        }
      }
    });
  });

  group('redacted toString', () {
    test(
      'requests, responses, refresh tokens and errors never print secrets',
      () {
        const secret = 'CANARY-SECRET-91b2';
        final printed = <String>[
          const TokenExchangeRequest(
            code: secret,
            codeVerifier: secret,
            redirectUri: 'x://y',
          ).toString(),
          TokenResponse(
            accessToken: secret,
            refreshToken: const RefreshTokenPresent(secret),
            idToken: secret,
          ).toString(),
          const RefreshTokenPresent(secret).toString(),
          EndSessionRequest(
            url: Uri.parse('https://x/logout?id_token_hint=$secret'),
            callbackUrlScheme: 'x',
          ).toString(),
          const AuthUnauthorized(
            statusCode: 400,
            dioType: DioExceptionType.badResponse,
          ).toString(),
          const AuthUnavailable(
            statusCode: 503,
            malformedResponse: true,
          ).toString(),
        ];
        for (final s in printed) {
          expect(s, isNot(contains(secret)));
        }
        expect(
          const AuthUnavailable(statusCode: 503).toString(),
          'AuthUnavailable(status: 503, dioType: null, malformedResponse: false)',
        );
      },
    );
  });
}
