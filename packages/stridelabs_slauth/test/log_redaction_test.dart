import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

import 'support/fakes.dart';

// Canary values: if any of these ever reaches a log line, a secret leaked.
const _code = 'CANARYCODE4a1f';
const _verifier = 'CANARYVERIFIER9e2c';
const _state = 'CANARYSTATE5b7d';
const _access = 'CANARYACCESS3c8e';
const _refresh = 'CANARYREFRESH6d0a';
const _id = 'CANARYIDTOKEN2f9b';
const _body = 'CANARYBODY8a3c';
const _canaries = [_code, _verifier, _state, _access, _refresh, _id, _body];

/// A body that carries every canary.
const _canaryJson =
    '{"error":"invalid_grant","error_description":"$_body",'
    '"state":"$_state","code":"$_code","code_verifier":"$_verifier",'
    '"access_token":"$_access","refresh_token":"$_refresh","id_token":"$_id"}';

/// A message that carries every canary (for exceptions' toString()).
const _canaryMessage =
    'failed: $_body code=$_code verifier=$_verifier state=$_state '
    'access=$_access refresh=$_refresh id=$_id';

/// An exception whose toString() leaks every canary.
class _LeakyException implements Exception {
  @override
  String toString() => _canaryMessage;
}

/// Every way the token endpoint can fail over HTTP, each carrying canaries.
final _httpFailures = <String, ResponseBody Function(RequestOptions)>{
  '400 json': (_) => rawBody(_canaryJson, 400),
  '401 json': (_) => rawBody(_canaryJson, 401),
  '403 text': (_) => rawBody(_canaryMessage, 403, contentType: 'text/plain'),
  '500 json': (_) => rawBody(_canaryJson, 500),
  '502 html': (_) =>
      rawBody('<p>$_canaryMessage</p>', 502, contentType: 'text/html'),
  '503 text': (_) => rawBody(_canaryMessage, 503, contentType: 'text/plain'),
  '200 malformed json': (_) =>
      rawBody('{"access_token":"$_access", $_body', 200),
  '200 malformed text': (_) =>
      rawBody(_canaryMessage, 200, contentType: 'text/plain'),
  '200 non-object': (_) => rawBody('["$_access","$_refresh"]', 200),
  '200 mistyped': (_) => rawBody(
    '{"access_token":"$_access","refresh_token":{"v":"$_refresh"}}',
    200,
  ),
  '200 null refresh_token': (_) =>
      rawBody('{"access_token":"$_access","refresh_token":null}', 200),
  '200 empty refresh_token': (_) =>
      rawBody('{"access_token":"$_access","refresh_token":""}', 200),
  'adapter throws SocketException': (_) =>
      throw const SocketException(_canaryMessage),
  'adapter throws a leaky exception': (_) => throw _LeakyException(),
  'adapter throws DioException with canaries': (o) => throw DioException(
    requestOptions: o,
    type: DioExceptionType.connectionError,
    message: _canaryMessage,
    error: _LeakyException(),
  ),
  'adapter throws a receive timeout': (o) => throw DioException(
    requestOptions: o,
    type: DioExceptionType.receiveTimeout,
    message: _canaryMessage,
  ),
};

/// Every way a custom endpoint can fail, each carrying canaries.
final _endpointFailures = <String, Future<TokenResponse> Function()>{
  'throws a leaky exception': () async => throw _LeakyException(),
  'throws a StateError': () async => throw StateError(_canaryMessage),
  'throws a FormatException': () async =>
      throw const FormatException(_canaryMessage, _canaryJson),
  'throws an unmapped DioException': () async => throw DioException(
    requestOptions: RequestOptions(path: '/token?code=$_code&state=$_state'),
    response: Response(
      requestOptions: RequestOptions(path: '/token?code=$_code'),
      statusCode: 500,
      data: _canaryJson,
    ),
    type: DioExceptionType.badResponse,
    message: _canaryMessage,
  ),
  'throws AuthUnauthorized': () async =>
      throw const AuthUnauthorized(statusCode: 401),
  'throws AuthUnavailable': () async =>
      throw const AuthUnavailable(statusCode: 503, malformedResponse: true),
  'returns an empty access token': () async => const TokenResponse(
    accessToken: '',
    refreshToken: RefreshTokenPresent(_refresh),
    idToken: _id,
  ),
  'returns a null refresh token': () async => const TokenResponse(
    accessToken: _access,
    refreshToken: RefreshTokenBlank(),
    idToken: _id,
  ),
};

/// A scripted slauth for [HeadlessLogin]: it answers a good flow, except at
/// the steps a test overrides, and records the secrets the client generated
/// for this attempt (`state`, the PKCE challenge and verifier) as it sees them
/// on the wire, so a test can assert none of them reaches an error.
class _HeadlessSlauth {
  _HeadlessSlauth({this.flow, this.authorize, this.token});

  /// Overrides `GET /.ory/self-service/login/browser`.
  final ResponseBody Function()? flow;

  /// Overrides `GET /oauth2/auth` (given the request's `state`).
  final ResponseBody Function(RequestOptions o, String state)? authorize;

  /// Overrides `POST /oauth2/token`.
  final ResponseBody Function()? token;

  /// The client's per-attempt secrets, as seen on the wire.
  final secrets = <String>[];

  late final adapter = ScriptedAdapter(_respond);

  HeadlessLogin client() => HeadlessLogin(
    config: testConfig,
    dio: Dio(BaseOptions(validateStatus: (s) => s != null && s < 400))
      ..httpClientAdapter = adapter,
    cookieJar: CookieJar(),
  );

  static ResponseBody redirect(String location) => ResponseBody.fromString(
    '',
    302,
    headers: {
      'location': [location],
    },
  );

  ResponseBody _respond(RequestOptions o) {
    final path = o.uri.path;
    if (path.endsWith('/self-service/login/browser')) {
      return flow?.call() ??
          jsonBody({
            'ui': {
              'action': 'https://auth.test/self-service/login?flow=f1',
              'nodes': <Object>[],
            },
          });
    }
    if (path == '/self-service/login') return jsonBody({'session': {}});
    if (path == '/oauth2/auth') {
      final q = o.uri.queryParameters;
      final state = q['state']!;
      secrets.addAll([state, q['code_challenge']!]);
      return authorize?.call(o, state) ??
          redirect('${testConfig.redirectUri}?code=$_code&state=$state');
    }
    if (path == '/oauth2/token') {
      final form = Uri.splitQueryString(adapter.requests.last.body);
      final verifier = form['code_verifier'];
      if (verifier != null) secrets.add(verifier);
      return token?.call() ??
          jsonBody({
            'access_token': _access,
            'refresh_token': _refresh,
            'id_token': _id,
          });
    }
    return jsonBody({'error': 'unexpected'}, 404);
  }
}

void main() {
  late List<String> lines;
  late DebugPrintCallback original;

  setUp(() {
    lines = [];
    original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
  });

  tearDown(() => debugPrint = original);

  void expectNoCanary() {
    expect(lines, isNotEmpty, reason: 'the failure paths must log something');
    for (final line in lines) {
      for (final canary in _canaries) {
        expect(line, isNot(contains(canary)), reason: 'leaked in: $line');
      }
    }
  }

  /// A service on the real Hydra endpoint whose session holds canary tokens.
  Future<AuthService> hydraService(
    ResponseBody Function(RequestOptions) responder,
  ) async {
    final store = RecordingStore();
    final svc = AuthService(
      config: testConfig,
      store: store,
      dio: dioWith(ScriptedAdapter(responder)),
    );
    await seedSession(svc, store, access: _access, refresh: _refresh, id: _id);
    return svc;
  }

  group('Hydra endpoint failures log no secrets', () {
    for (final failure in _httpFailures.entries) {
      test('exchange: ${failure.key}', () async {
        final svc = await hydraService(failure.value);
        final ok = await svc.exchangeAuthorizationCode(
          _code,
          codeVerifier: _verifier,
          redirectUri: 'slaudio://auth/callback?state=$_state',
        );
        expect(ok, isFalse);
        expectNoCanary();
        svc.dispose();
      });

      test('refresh: ${failure.key}', () async {
        final svc = await hydraService(failure.value);
        expect(await svc.refreshSession(), isNot(RefreshOutcome.refreshed));
        expectNoCanary();
        svc.dispose();
      });
    }
  });

  group('custom endpoint failures log no secrets', () {
    for (final failure in _endpointFailures.entries) {
      test('exchange: ${failure.key}', () async {
        final endpoint = FakeEndpoint(
          onExchange: (_) => failure.value(),
          onRefresh: (_) => failure.value(),
        );
        final svc = AuthService.withEndpoint(
          endpoint: endpoint,
          store: RecordingStore(),
        );
        final ok = await svc.exchangeAuthorizationCode(
          _code,
          codeVerifier: _verifier,
          redirectUri: 'app://cb?state=$_state',
        );
        expect(ok, isFalse);
        expectNoCanary();
        svc.dispose();
      });

      test('refresh: ${failure.key}', () async {
        final store = RecordingStore();
        final svc = AuthService.withEndpoint(
          endpoint: FakeEndpoint(onRefresh: (_) => failure.value()),
          store: store,
          refreshRetry: const RefreshRetryPolicy(),
        );
        await seedSession(
          svc,
          store,
          access: _access,
          refresh: _refresh,
          id: _id,
        );
        expect(await svc.refreshSession(), isNot(RefreshOutcome.refreshed));
        expectNoCanary();
        svc.dispose();
      });
    }
  });

  test('a failing token store logs no secrets', () async {
    final store = RecordingStore()..writeError = _LeakyException();
    final svc = AuthService.withEndpoint(
      endpoint: FakeEndpoint(
        onExchange: (_) async => const TokenResponse(
          accessToken: _access,
          refreshToken: RefreshTokenPresent(_refresh),
          idToken: _id,
        ),
      ),
      store: store,
    );
    expect(
      await svc.exchangeAuthorizationCode(
        _code,
        codeVerifier: _verifier,
        redirectUri: 'app://cb',
      ),
      isTrue,
      reason: 'tokens kept in memory only',
    );
    expectNoCanary();
    svc.dispose();
  });

  group('HeadlessLogin failures leak no secrets', () {
    /// [call] must fail with a [HeadlessLoginException] naming [step] whose
    /// text (and any log line) holds no canary and none of the attempt's own
    /// secrets (`state`, PKCE challenge/verifier).
    Future<void> expectRedactedFailure(
      _HeadlessSlauth slauth,
      Future<Object?> Function(HeadlessLogin login) call, {
      required String step,
      String? detail,
      bool sawAuthorize = true,
    }) async {
      Object? error;
      try {
        await call(slauth.client());
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'the call must fail');
      if (sawAuthorize) {
        expect(
          slauth.secrets,
          isNotEmpty,
          reason: 'the flow reached authorize',
        );
      }
      // No secret in what a caller would print (whatever the error's type),
      // nor in any log line.
      for (final text in ['$error', ...lines]) {
        for (final secret in [..._canaries, ...slauth.secrets]) {
          expect(text, isNot(contains(secret)), reason: 'leaked in: $text');
        }
      }
      expect(error, isA<HeadlessLoginException>());
      final message = (error as HeadlessLoginException).message;
      for (final secret in [..._canaries, ...slauth.secrets]) {
        expect(message, isNot(contains(secret)));
      }
      expect(message, contains(step));
      if (detail != null) expect(message, contains(detail));
    }

    Future<Object?> login(HeadlessLogin l) =>
        l.login(email: 'e@example.com', password: 'pw');

    test('authorize answers 200 instead of a redirect (the URL carries state '
        'and the PKCE challenge)', () async {
      await expectRedactedFailure(
        _HeadlessSlauth(
          authorize: (_, _) =>
              rawBody('<p>$_canaryMessage</p>', 200, contentType: 'text/html'),
        ),
        login,
        step: 'authorize hop 0',
      );
    });

    test('authorize answers 400 with a canary body', () async {
      await expectRedactedFailure(
        _HeadlessSlauth(authorize: (_, _) => rawBody(_canaryJson, 400)),
        login,
        step: 'authorize hop 0',
      );
    });

    test('authorize fails to connect, the error naming the URL', () async {
      await expectRedactedFailure(
        _HeadlessSlauth(
          authorize: (o, _) => throw DioException(
            requestOptions: o,
            type: DioExceptionType.connectionError,
            message: 'could not reach ${o.uri}',
            error: SocketException('connect to ${o.uri} failed'),
          ),
        ),
        login,
        step: 'authorize hop 0',
      );
    });

    test('the callback carries an unregistered error value', () async {
      await expectRedactedFailure(
        _HeadlessSlauth(
          authorize: (_, state) => _HeadlessSlauth.redirect(
            '${testConfig.redirectUri}?error=$_body&state=$state',
          ),
        ),
        login,
        step: 'authorize error',
      );
    });

    test(
      'the callback\'s state does not match (it carries canaries)',
      () async {
        await expectRedactedFailure(
          _HeadlessSlauth(
            authorize: (_, _) => _HeadlessSlauth.redirect(
              '${testConfig.redirectUri}?code=$_code&state=$_state',
            ),
          ),
          login,
          step: 'state mismatch',
        );
      },
    );

    test('a malformed Location carrying the code', () async {
      await expectRedactedFailure(
        _HeadlessSlauth(
          authorize: (_, state) =>
              _HeadlessSlauth.redirect('http://[$_code?state=$state'),
        ),
        login,
        step: 'authorize hop 0',
      );
    });

    for (final (name, body, detail)
        in <(String, ResponseBody Function(), String)>[
          (
            'malformed JSON (application/json)',
            () => rawBody(
              '{"access_token":"$_access","refresh_token":"$_refresh", $_body',
              200,
            ),
            'not valid JSON',
          ),
          (
            'malformed JSON (text/plain)',
            () => rawBody(
              '{"access_token":"$_access","id_token":"$_id", $_body',
              200,
              contentType: 'text/plain',
            ),
            'not valid JSON',
          ),
          (
            '400 with a canary body',
            () => rawBody(_canaryJson, 400),
            'badResponse (HTTP 400)',
          ),
        ]) {
      test('the token exchange answers $name', () async {
        final slauth = _HeadlessSlauth(token: body);
        await expectRedactedFailure(
          slauth,
          login,
          step: 'token exchange',
          detail: detail,
        );
        expect(slauth.secrets, hasLength(3), reason: 'the verifier was sent');
      });

      test('refresh() answers $name', () async {
        await expectRedactedFailure(
          _HeadlessSlauth(token: body),
          (l) => l.refresh(_refresh),
          step: 'refresh',
          detail: detail,
          sawAuthorize: false,
        );
      });
    }

    test('the login flow answers malformed JSON', () async {
      await expectRedactedFailure(
        _HeadlessSlauth(
          flow: () => rawBody(
            '{"ui": "$_body", "csrf": "$_state"',
            200,
            contentType: 'text/plain',
          ),
        ),
        login,
        step: 'login flow',
        sawAuthorize: false,
      );
    });
  });

  test('failure lines name the operation, error class and status', () async {
    final svc = await hydraService((_) => rawBody(_canaryJson, 503));
    await svc.refreshSession();
    expect(
      lines,
      contains(
        '[AuthService] refresh failed: AuthUnavailable status=503 '
        'dio=badResponse',
      ),
    );
    svc.dispose();
  });
}
