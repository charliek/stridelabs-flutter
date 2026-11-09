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
///   POST /api/v1/account/login                    -> 200 + Set-Cookie (403 without Origin)
///   GET  /oauth2/auth  (#1)                       -> 302 /oauth/login
///   GET  /oauth/login                             -> 302 `authorize url`
///   GET  /oauth2/auth  (#2)                       -> 302 /oauth/consent
///   GET  /oauth/consent                           -> 302 `authorize url`
///   GET  /oauth2/auth  (#3)                       -> 302 slaudio://auth/callback?code&state
///   POST /oauth2/token                            -> 200 JSON tokens
///
/// With [screenFlow], the chain slauth runs for a first-party custom-scheme
/// client under AUTH_MODE=native: `/oauth/consent` sends the browser to the SPA's
/// `/consent` page instead of back to authorize, and only
/// `POST /api/v1/oauth/consent/accept` moves the flow on.
///
/// Both POSTs answer 403 unless they carry the auth UI's `Origin` and a JSON
/// content type, as slauth does.
///
/// With [providerFlow], the second authorize sends the browser to the provider
/// route `/oauth/consent?flow=`, an ordinary redirect that is not the page.
class _ReplayAdapter implements HttpClientAdapter {
  _ReplayAdapter({
    required this.redirectUri,
    this.callbackQuery,
    this.screenFlow,
    this.providerFlow,
    this.accept,
  });

  final String redirectUri;

  /// The flow the `/oauth/consent` hop sends to the SPA page with.
  final String? screenFlow;

  /// The flow the second authorize sends to `/oauth/consent` with.
  final String? providerFlow;

  /// Overrides the accept answer. Given the URL the default redirects to.
  final ResponseBody Function(String redirectTo)? accept;

  final List<RequestOptions> acceptRequests = [];
  final List<RequestOptions> loginRequests = [];

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

    if (method == 'POST' && path == '/api/v1/account/login') {
      final refusal = _refuseUnlessSameOrigin(options);
      if (refusal != null) return refusal;
      loginRequests.add(options);
      return _json(200, {
        'ok': true,
      }, setCookie: 'slauth_session=SESSION-COOKIE; Path=/; HttpOnly');
    }

    if (method == 'GET' && path == '/oauth2/auth') {
      authHits++;
      if (authHits == 1) {
        _authorizeUrl = uri.toString();
        return _redirect('/oauth/login');
      }
      if (authHits == 2) {
        return _redirect(
          providerFlow == null
              ? '/oauth/consent'
              : '/oauth/consent?flow=$providerFlow',
        );
      }
      final state = uri.queryParameters['state'] ?? '';
      final query =
          callbackQuery?.call(state) ?? 'code=AUTH-CODE-123&state=$state';
      return _redirect('$redirectUri?$query');
    }

    if (method == 'GET' && path == '/oauth/consent' && screenFlow != null) {
      // Absolute, as slauth sends it (`AUTH_UI_URL` + `/consent?...`).
      return _redirect(
        Uri.parse(
          'https://auth.test/consent',
        ).replace(queryParameters: {'flow': screenFlow}).toString(),
      );
    }

    if (method == 'GET' &&
        (path == '/oauth/login' || path == '/oauth/consent')) {
      return _redirect(_authorizeUrl!);
    }

    if (method == 'GET' && path == '/consent') {
      // The SPA's shell: a 200 whatever the page goes on to do.
      return ResponseBody.fromString(
        '<!doctype html><div id="root"></div>',
        200,
        headers: {
          'content-type': ['text/html'],
        },
      );
    }

    if (method == 'POST' && path == '/api/v1/oauth/consent/accept') {
      final refusal = _refuseUnlessSameOrigin(options);
      if (refusal != null) return refusal;
      acceptRequests.add(options);
      return accept?.call(_authorizeUrl!) ??
          _jsonResponse(200, {'redirect_to': _authorizeUrl});
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

  /// slauth's gate on its JSON POSTs: the auth UI's exact `Origin`, and a JSON
  /// body. Null when the request passes.
  ResponseBody? _refuseUnlessSameOrigin(RequestOptions options) {
    final origin = options.headers['Origin'] ?? options.headers['origin'];
    if (origin != 'https://auth.test') {
      return _jsonResponse(403, {'detail': 'Origin not allowed'});
    }
    if (!'${options.contentType}'.startsWith('application/json')) {
      return _jsonResponse(403, {'detail': 'Content-Type must be JSON'});
    }
    return null;
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

ResponseBody _jsonResponse(int status, Object data) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    'content-type': ['application/json'],
  },
);

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

      // Session cookie from the login POST propagated to the authorize
      // requests via the CookieManager + jar.
      expect(
        adapter.cookieHeadersSeen.any((c) => c.contains('slauth_session')),
        isTrue,
        reason: 'authorize requests must carry the session cookie',
      );

      // Full observed sequence matches the probe.
      expect(jsonDecode(adapter.loginRequests.single.data as String), {
        'email': 'test@example.com',
        'password': 'secret',
      });
      expect(adapter.requestLog, [
        'POST /api/v1/account/login',
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

  group('HeadlessLogin on the consent screen', () {
    // Needs percent-encoding in the page's URL, so a test sees it decoded.
    const flowHandle = 'fl+ow/han=dle';

    Matcher failsWith(String message) => throwsA(
      isA<HeadlessLoginException>().having(
        (e) => e.message,
        'message',
        message,
      ),
    );

    test('accepts the flow and finishes with tokens', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        screenFlow: flowHandle,
      );

      final tokens = await _buildLogin(
        adapter,
      ).login(email: 'test@example.com', password: 'secret');

      expect(tokens['access_token'], isA<String>());
      expect(tokens['refresh_token'], 'refresh-token-1');
      expect(adapter.requestLog, [
        'POST /api/v1/account/login',
        'GET /oauth2/auth',
        'GET /oauth/login',
        'GET /oauth2/auth',
        'GET /oauth/consent',
        'POST /api/v1/oauth/consent/accept',
        'GET /oauth2/auth',
        'POST /oauth2/token',
      ], reason: 'the page itself is never fetched');
    });

    test('sends what slauth\'s accept requires', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        screenFlow: flowHandle,
      );

      await _buildLogin(adapter).login(email: 'a@b', password: 'p');

      final request = adapter.acceptRequests.single;
      expect(request.uri.toString(), startsWith(_config.baseUrl));
      expect(jsonDecode(request.data as String), {'flow': flowHandle});
      expect(request.contentType, Headers.jsonContentType);
      expect(request.headers['Origin'], 'https://auth.test');
      expect(
        '${request.headers['cookie']}',
        contains('slauth_session'),
        reason: 'the flow is bound to the session',
      );
    });

    test('a redirect_to straight to the callback finishes the flow', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        screenFlow: flowHandle,
        accept: (authorizeUrl) {
          final state = Uri.parse(authorizeUrl).queryParameters['state'];
          return _jsonResponse(200, {
            'redirect_to': '${_config.redirectUri}?code=C&state=$state',
          });
        },
      );

      final tokens = await _buildLogin(
        adapter,
      ).login(email: 'a@b', password: 'p');

      expect(tokens['access_token'], isA<String>());
      expect(adapter.authHits, 2);
    });

    test('a state mismatch after the accept is still refused', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        screenFlow: flowHandle,
        accept: (_) => _jsonResponse(200, {
          'redirect_to': '${_config.redirectUri}?code=C&state=WRONG',
        }),
      );

      await expectLater(
        _buildLogin(adapter).login(email: 'a@b', password: 'p'),
        failsWith('state mismatch'),
      );
    });

    for (final status in [400, 401, 403, 422, 502]) {
      test('an accept answering $status fails, naming the status', () async {
        final adapter = _ReplayAdapter(
          redirectUri: _config.redirectUri,
          screenFlow: flowHandle,
          accept: (_) => _jsonResponse(status, {'detail': 'refused'}),
        );

        await expectLater(
          _buildLogin(adapter).login(email: 'a@b', password: 'p'),
          failsWith('consent accept failed: badResponse (HTTP $status)'),
        );
        expect(adapter.requestLog, isNot(contains('POST /oauth2/token')));
      });
    }

    test('an accept answering 200 with no redirect_to fails', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        screenFlow: flowHandle,
        accept: (_) => _jsonResponse(200, {'ok': true}),
      );

      await expectLater(
        _buildLogin(adapter).login(email: 'a@b', password: 'p'),
        failsWith('consent accept: response has no redirect_to'),
      );
    });

    test('a client Dio that lets every status through still fails', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        screenFlow: flowHandle,
        accept: (_) =>
            _jsonResponse(403, {'redirect_to': 'https://auth.test/'}),
      );
      final login = HeadlessLogin(
        config: _config,
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = adapter,
        cookieJar: CookieJar(),
      );

      await expectLater(
        login.login(email: 'a@b', password: 'p'),
        failsWith('consent accept failed: 403'),
      );
    });

    test('a flow on the provider route stays a chain of redirects with no '
        'accept', () async {
      final adapter = _ReplayAdapter(
        redirectUri: _config.redirectUri,
        providerFlow: flowHandle,
      );

      final tokens = await _buildLogin(
        adapter,
      ).login(email: 'a@b', password: 'p');

      expect(tokens['access_token'], isA<String>());
      expect(adapter.acceptRequests, isEmpty);
      expect(adapter.requestLog, [
        'POST /api/v1/account/login',
        'GET /oauth2/auth',
        'GET /oauth/login',
        'GET /oauth2/auth',
        'GET /oauth/consent',
        'GET /oauth2/auth',
        'POST /oauth2/token',
      ]);
    });

    for (final (name, location) in [
      ('no flow', '/consent'),
      ('an empty flow', '/consent?flow='),
      ('the old challenge name', '/consent?consent_challenge=x'),
      ('another path', '/other/consent?flow=x'),
    ]) {
      test('a hop with $name is not treated as the consent page', () async {
        final adapter = _PageAdapter(location);
        await expectLater(
          _buildLogin(adapter).login(email: 'a@b', password: 'p'),
          failsWith('authorize hop 1: expected a redirect, got HTTP 200'),
        );
        expect(adapter.acceptRequests, isEmpty);
      });
    }
  });
}

/// Sends the first authorize straight to [location], a page answering 200.
class _PageAdapter extends _ReplayAdapter {
  _PageAdapter(this.location) : super(redirectUri: _config.redirectUri);

  final String location;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/oauth2/auth') return _redirect(location);
    if (path.endsWith('/consent')) {
      return ResponseBody.fromString('<html></html>', 200);
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}
