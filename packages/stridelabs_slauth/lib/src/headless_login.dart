import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import 'authorize_url.dart';
import 'pkce.dart';
import 'slauth_config.dart';

// Debug-mode detection WITHOUT importing package:flutter/foundation — that would
// pull dart:ui and make this library uncompilable under a plain `dart run` tool
// (a live driving probe). Mirrors Flutter's own kDebugMode definition.
const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');
const bool _kProfileMode = bool.fromEnvironment('dart.vm.profile');
const bool kIsDebugMode = !_kReleaseMode && !_kProfileMode;

/// Thrown when the headless login flow fails at a specific step.
///
/// [message] names the step and at most an HTTP status, a Dio error category,
/// an error class or a registered OAuth2 error code. It never carries a URL
/// (the authorize URLs hold `state` and the PKCE challenge), a consent
/// flow handle, a response body (token responses hold tokens), a value from any
/// of those, or another exception's text, so it is safe to print or show.
class HeadlessLoginException implements Exception {
  HeadlessLoginException(this.message);
  final String message;
  @override
  String toString() => 'HeadlessLoginException: $message';
}

/// DEBUG-ONLY headless password login against slauth.
///
/// A faithful Dart port of the verified native-flow probe: it signs in with one
/// `POST /api/v1/account/login` (JSON) to obtain a session cookie, then runs the
/// PKCE `/oauth2/auth` round-trip following redirects MANUALLY (custom-scheme
/// callbacks are never auto-followed by any HTTP client), validates `state`, and
/// exchanges the code at `/oauth2/token`. Returns the raw token response map —
/// the same shape [AuthService.storeTokens] persists.
///
/// A hop that lands on slauth's consent page (`/consent?flow=`), which slauth
/// shows first-party custom-scheme clients on every authorize, is approved
/// through slauth's consent API on the user's behalf.
///
/// This bypasses the system browser and is intended only for local E2E driving /
/// a live driving tool. It is hard-guarded to debug builds: constructing it
/// in a release/profile build throws.
///
/// slauth requires the auth UI's `Origin` on the login and consent POSTs, so
/// this sends `config.baseUrl`'s origin. That assumes the base URL's origin
/// equals slauth's `AUTH_UI_URL` origin (true for local slauth via prox or the
/// native stack, and for both deployed environments). Needs slauth at or after
/// N7: there is no fallback to the `/.ory` shim.
///
/// Every failure is a [HeadlessLoginException] with a redacted message (see
/// there): network and decode errors are reduced to their step, status and
/// category, never passed through.
class HeadlessLogin {
  HeadlessLogin({required this.config, Dio? dio, CookieJar? cookieJar})
    : _jar = cookieJar ?? CookieJar() {
    if (!kIsDebugMode) {
      throw StateError(
        'HeadlessLogin is debug-only and must not run in a '
        'release/profile build.',
      );
    }
    assert(kIsDebugMode);
    _dio =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
            // Accept 3xx as non-error so we can follow redirects by hand.
            validateStatus: (s) => s != null && s < 400,
          ),
        );
    _dio.interceptors.add(CookieManager(_jar));
  }

  final SlauthConfig config;
  final CookieJar _jar;
  late final Dio _dio;

  /// The `Origin` slauth's account and consent POSTs require: [config]'s base
  /// URL origin, which must equal slauth's `AUTH_UI_URL` origin.
  String get _origin => Uri.parse(config.baseUrl).origin;

  /// Maximum manual redirect hops before giving up (the probe needs 5).
  static const _maxHops = 12;

  /// OAuth2 (RFC 6749 §4.1.2.1) and OIDC Core (§3.1.2.6) authorization error
  /// codes: the only `error` values a failure message may repeat. Anything
  /// else in the callback's `error` is server-controlled text and is dropped.
  static const _knownAuthorizeErrors = {
    'invalid_request',
    'unauthorized_client',
    'access_denied',
    'unsupported_response_type',
    'invalid_scope',
    'server_error',
    'temporarily_unavailable',
    'interaction_required',
    'login_required',
    'account_selection_required',
    'consent_required',
    'invalid_request_uri',
    'invalid_request_object',
    'request_not_supported',
    'request_uri_not_supported',
    'registration_not_supported',
  };

  /// Run the full flow. Returns the parsed `/oauth2/token` response
  /// (`access_token`, `refresh_token`, `id_token`, `expires_in`, ...).
  ///
  /// Throws a [HeadlessLoginException] (redacted) on any failure.
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) {
    final step = _Step('login');
    return _redacted(step, () => _login(email, password, step));
  }

  Future<Map<String, dynamic>> _login(
    String email,
    String password,
    _Step step,
  ) async {
    final base = config.baseUrl;

    // 1. Password login: one JSON POST, which sets the session cookie.
    final origin = _origin;
    final loginRes = await _dio.post(
      '$base/api/v1/account/login',
      data: jsonEncode({'email': email, 'password': password}),
      options: Options(
        headers: {'Origin': origin},
        contentType: Headers.jsonContentType,
        // The body isn't read on success, and a refusal's is never quoted.
        responseType: ResponseType.plain,
      ),
    );
    if (loginRes.statusCode != 200) {
      throw HeadlessLoginException('login failed: ${loginRes.statusCode}');
    }

    // 2. Authorize with PKCE, following redirects manually until the
    //    custom-scheme callback is reached.
    final pkce = Pkce.generate();
    final state = Pkce.generateState();
    var url = buildAuthorizeUrl(
      slauthBaseUrl: base,
      clientId: config.clientId,
      redirectUri: config.redirectUri,
      codeChallenge: pkce.challenge,
      state: state,
      audience: config.audience,
      scope: config.scope,
    ).toString();

    String? code;
    for (var hop = 0; hop < _maxHops; hop++) {
      step.name = 'authorize hop $hop';
      final flow = _consentFlow(Uri.parse(url));
      final String location;
      if (flow != null) {
        step.name = 'consent accept';
        location = await _acceptConsent(flow, step);
      } else {
        final r = await _dio.get(
          url,
          options: Options(
            headers: {'Accept': 'text/html'},
            followRedirects: false,
            validateStatus: (s) => s != null && s < 400,
          ),
        );
        final status = r.statusCode ?? 0;
        if (status < 300 || status > 399) {
          // Never the URL: it carries `state` and the PKCE challenge.
          throw HeadlessLoginException(
            'authorize hop $hop: expected a redirect, got HTTP $status',
          );
        }
        final header = r.headers.value('location');
        if (header == null) {
          throw HeadlessLoginException('authorize hop $hop: missing Location');
        }
        location = header;
      }
      url = Uri.parse(url).resolve(location).toString();
      if (url.startsWith(config.redirectUri)) {
        final q = Uri.parse(url).queryParameters;
        final error = q['error'];
        if (error != null) {
          // Only a registered error code: the value is server-controlled.
          final known = _knownAuthorizeErrors.contains(error);
          throw HeadlessLoginException(
            'authorize error: ${known ? error : '(unrecognized error code)'}',
          );
        }
        if (q['state'] != state) {
          throw HeadlessLoginException('state mismatch');
        }
        code = q['code'];
        break;
      }
    }
    if (code == null || code.isEmpty) {
      throw HeadlessLoginException(
        'no authorization code within $_maxHops hops',
      );
    }

    // 3. Token exchange (native: no Origin header, form-encoded).
    step.name = 'token exchange';
    final tokenRes = await _dio.post(
      '$base/oauth2/token',
      data: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': config.redirectUri,
        'client_id': config.clientId,
        'code_verifier': pkce.verifier,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.json,
      ),
    );
    if (tokenRes.statusCode != 200) {
      throw HeadlessLoginException(
        'token exchange failed: ${tokenRes.statusCode}',
      );
    }
    final tokens = _asMap(tokenRes.data, step);
    if (tokens['access_token'] is! String) {
      throw HeadlessLoginException('token response missing access_token');
    }
    return tokens;
  }

  /// The `flow` handle if [url] is slauth's consent page, the SPA route its
  /// consent provider sends first-party custom-scheme clients to. The provider
  /// route `/oauth/consent` carries the same parameter and is an ordinary
  /// redirect, so the path must match exactly.
  static String? _consentFlow(Uri url) {
    if (url.path != '/consent') return null;
    final flow = url.queryParameters['flow'];
    return flow == null || flow.isEmpty ? null : flow;
  }

  /// Approve [flow] the way the page's Continue button does: a JSON POST with
  /// the session cookie and the auth UI's `Origin`, which slauth requires.
  /// Returns where to go next.
  Future<String> _acceptConsent(String flow, _Step step) async {
    final res = await _dio.post(
      '${config.baseUrl}/api/v1/oauth/consent/accept',
      data: jsonEncode({'flow': flow}),
      options: Options(
        headers: {'Origin': _origin},
        contentType: Headers.jsonContentType,
        responseType: ResponseType.json,
      ),
    );
    if (res.statusCode != 200) {
      throw HeadlessLoginException('consent accept failed: ${res.statusCode}');
    }
    final redirectTo = _asMap(res.data, step)['redirect_to'];
    if (redirectTo is! String || redirectTo.isEmpty) {
      throw HeadlessLoginException(
        'consent accept: response has no redirect_to',
      );
    }
    return redirectTo;
  }

  /// Exercise refresh-token rotation once (used by a live driving tool to
  /// prove the token rotates). Returns the refreshed token response.
  ///
  /// Throws a [HeadlessLoginException] (redacted) on any failure.
  Future<Map<String, dynamic>> refresh(String refreshToken) {
    final step = _Step('refresh');
    return _redacted(step, () async {
      final res = await _dio.post(
        '${config.baseUrl}/oauth2/token',
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': config.clientId,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.json,
        ),
      );
      if (res.statusCode != 200) {
        throw HeadlessLoginException('refresh failed: ${res.statusCode}');
      }
      return _asMap(res.data, step);
    });
  }

  /// Run [body], letting its own [HeadlessLoginException]s through and
  /// replacing anything else with a redacted one naming the current step.
  ///
  /// A [DioException]'s text can carry the request URL (with `state` and the
  /// PKCE challenge) or a decode error quoting the response body; other
  /// errors (a [FormatException] from a malformed `Location`, a cast error)
  /// can quote values too. Only the step, the HTTP status, the Dio category
  /// and the error class survive.
  static Future<T> _redacted<T>(_Step step, Future<T> Function() body) async {
    try {
      return await body();
    } on HeadlessLoginException {
      rethrow;
    } on DioException catch (e) {
      if (e.error is FormatException) {
        // Dio's own JSON decode failed (its message quotes the body).
        throw HeadlessLoginException(
          '${step.name}: response body is not valid JSON',
        );
      }
      final status = e.response?.statusCode;
      throw HeadlessLoginException(
        '${step.name} failed: ${e.type.name}'
        '${status == null ? '' : ' (HTTP $status)'}',
      );
    } catch (e) {
      throw HeadlessLoginException('${step.name} failed: ${e.runtimeType}');
    }
  }

  /// Coerce a Dio `response.data` (Map, or a raw String when the Content-Type
  /// sniff misfires) into a JSON object. Failures name [step] and the shape,
  /// never the body (`jsonDecode`'s own message quotes it).
  static Map<String, dynamic> _asMap(Object? raw, _Step step) {
    if (raw is Map<String, dynamic>) return raw;
    Object? value = raw;
    if (raw is String) {
      try {
        value = jsonDecode(raw);
      } on FormatException {
        throw HeadlessLoginException(
          '${step.name}: response body is not valid JSON',
        );
      }
      if (value is Map<String, dynamic>) return value;
    }
    throw HeadlessLoginException(
      '${step.name}: expected a JSON object, got ${value.runtimeType}',
    );
  }
}

/// The request a flow is on, for [HeadlessLoginException] messages.
class _Step {
  _Step(this.name);
  String name;
}
