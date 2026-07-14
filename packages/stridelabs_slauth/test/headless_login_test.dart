import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/src/headless_login.dart';
import 'package:stridelabs_slauth/src/slauth_config.dart';

const _config = SlauthConfig(
  baseUrl: 'https://auth.test',
  clientId: 'slaudio-mobile',
  audience: 'slaudio',
  redirectUri: 'slaudio://auth/callback',
  postLogoutUri: 'slaudio://auth/logout',
);

const _identity = 'd2dbb2e7-8ed3-4bf3-8497-25ac40afb00d';

String _makeJwt(String sub) {
  const header =
      'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0'; // {"alg":"none","typ":"JWT"}
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","aud":["slaudio"],"email":"t@t"}'))
      .replaceAll('=', '');
  return '$header.$payload.';
}

/// Replays the EXACT verified redirect chain from native_flow_probe.py:
///   GET  /.ory/self-service/login/browser        -> 200 JSON (csrf node) + Set-Cookie
///   POST /self-service/login?flow=...             -> 200 JSON session + Set-Cookie
///   GET  /oauth2/auth  (#1)                       -> 302 /oauth/login
///   GET  /oauth/login                             -> 302 `authorize url`
///   GET  /oauth2/auth  (#2)                       -> 302 /oauth/consent
///   GET  /oauth/consent                           -> 302 `authorize url`
///   GET  /oauth2/auth  (#3)                       -> 302 slaudio://auth/callback?code&state
///   POST /oauth2/token                            -> 200 JSON tokens
class _ReplayAdapter implements HttpClientAdapter {
  _ReplayAdapter({required this.redirectUri, this.callbackQuery});

  final String redirectUri;

  /// Builds the callback query string from the observed `state`. Defaults to a
  /// valid `code`+matching-`state`. Override for the mismatch / error cases.
  final String Function(String state)? callbackQuery;

  int authHits = 0;
  String? _authorizeUrl;
  final List<String> requestLog = [];
  final List<String> cookieHeadersSeen = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final method = options.method.toUpperCase();
    final path = uri.path;
    requestLog.add('$method $path');
    final cookie = options.headers['cookie'];
    if (cookie != null) cookieHeadersSeen.add('$cookie');

    if (method == 'GET' && path.endsWith('/self-service/login/browser')) {
      return _json(200, {
        'ui': {
          'action':
              '${uri.scheme}://${uri.host}/self-service/login?flow=flow-1',
          'nodes': [
            {
              'attributes': {'name': 'csrf_token', 'value': 'CSRF-TOKEN-123'},
            },
          ],
        },
      }, setCookie: 'csrf_token=abc; Path=/; HttpOnly');
    }

    if (method == 'POST' && path == '/self-service/login') {
      return _json(200, {
        'session': {
          'identity': {'id': _identity},
        },
      }, setCookie: 'ory_session_local=SESSION-COOKIE; Path=/; HttpOnly');
    }

    if (method == 'GET' && path == '/oauth2/auth') {
      authHits++;
      if (authHits == 1) {
        _authorizeUrl = uri.toString();
        return _redirect('/oauth/login');
      }
      if (authHits == 2) return _redirect('/oauth/consent');
      final state = uri.queryParameters['state'] ?? '';
      final query =
          callbackQuery?.call(state) ?? 'code=AUTH-CODE-123&state=$state';
      return _redirect('$redirectUri?$query');
    }

    if (method == 'GET' &&
        (path == '/oauth/login' || path == '/oauth/consent')) {
      return _redirect(_authorizeUrl!);
    }

    if (method == 'POST' && path == '/oauth2/token') {
      return _json(200, {
        'access_token': _makeJwt(_identity),
        'refresh_token': 'refresh-token-1',
        'id_token': _makeJwt(_identity),
        'token_type': 'bearer',
        'expires_in': 900,
      });
    }

    return _json(404, {'error': 'unexpected $method $path'});
  }

  ResponseBody _redirect(String location) => ResponseBody.fromString(
    '',
    302,
    headers: {
      'location': [location],
    },
  );

  ResponseBody _json(int status, Object data, {String? setCookie}) {
    final headers = <String, List<String>>{
      'content-type': ['application/json'],
    };
    if (setCookie != null) headers['set-cookie'] = [setCookie];
    return ResponseBody.fromString(jsonEncode(data), status, headers: headers);
  }
}

HeadlessLogin _buildLogin(_ReplayAdapter adapter) {
  final dio = Dio(BaseOptions(validateStatus: (s) => s != null && s < 400))
    ..httpClientAdapter = adapter;
  return HeadlessLogin(config: _config, dio: dio, cookieJar: CookieJar());
}

void main() {
  group('HeadlessLogin', () {
    test('replays the 5-hop probe chain and returns tokens', () async {
      final adapter = _ReplayAdapter(redirectUri: _config.redirectUri);
      final login = _buildLogin(adapter);

      final tokens = await login.login(
        email: 'test@example.com',
        password: 'secret',
      );

      expect(tokens['access_token'], isA<String>());
      expect(tokens['refresh_token'], 'refresh-token-1');
      expect(tokens['id_token'], isA<String>());

      // Exactly three authorize hits (auth -> login -> auth -> consent -> auth).
      expect(adapter.authHits, 3);

      // Session cookie from the Kratos login POST propagated to the authorize
      // requests via the CookieManager + jar.
      expect(
        adapter.cookieHeadersSeen.any((c) => c.contains('ory_session_local')),
        isTrue,
        reason: 'authorize requests must carry the Kratos session cookie',
      );

      // Full observed sequence matches the probe.
      expect(adapter.requestLog, [
        'GET /.ory/self-service/login/browser',
        'POST /self-service/login',
        'GET /oauth2/auth',
        'GET /oauth/login',
        'GET /oauth2/auth',
        'GET /oauth/consent',
        'GET /oauth2/auth',
        'POST /oauth2/token',
      ]);
    });

    test('rejects a state mismatch on the callback', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        callbackQuery: (_) => 'code=AUTH-CODE-123&state=WRONG-STATE',
      );
      final login = _buildLogin(adapter);

      await expectLater(
        login.login(email: 'a@b', password: 'p'),
        throwsA(
          isA<HeadlessLoginException>().having(
            (e) => e.message,
            'message',
            contains('state mismatch'),
          ),
        ),
      );
    });

    test('surfaces an error query on the callback', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        callbackQuery: (state) =>
            'error=access_denied&error_description=nope&state=$state',
      );
      final login = _buildLogin(adapter);

      await expectLater(
        login.login(email: 'a@b', password: 'p'),
        throwsA(
          isA<HeadlessLoginException>().having(
            (e) => e.message,
            'message',
            contains('access_denied'),
          ),
        ),
      );
    });
  });
}
