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
/// (the authorize URLs hold `state` and the PKCE challenge), a response body
/// (token responses hold tokens), a value from either, or another exception's
/// text, so it is safe to print or show.
class HeadlessLoginException implements Exception {
  HeadlessLoginException(this.message);
  final String message;
  @override
  String toString() => 'HeadlessLoginException: $message';
}

/// DEBUG-ONLY headless password login against slauth.
///
/// A faithful Dart port of the verified native-flow probe: it drives Kratos
/// password login (browser flow, JSON) to obtain a session cookie, then runs the
/// PKCE `/oauth2/auth` round-trip following redirects MANUALLY (custom-scheme
/// callbacks are never auto-followed by any HTTP client), validates `state`, and
/// exchanges the code at `/oauth2/token`. Returns the raw token response map —
/// the same shape [AuthService.storeTokens] persists.
///
/// This bypasses the system browser and is intended only for local E2E driving /
/// a live driving tool. It is hard-guarded to debug builds: constructing it
/// in a release/profile build throws. There is intentionally NO CORS/Origin
/// handling — that is a web-browser concern, not a native-client one.
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
    final step = _Step('login flow');
    return _redacted(step, () => _login(email, password, step));
  }

  Future<Map<String, dynamic>> _login(
    String email,
    String password,
    _Step step,
  ) async {
    final base = config.baseUrl;

    // 1. Kratos password login (browser flow, JSON) → session cookie.
    final flowRes = await _dio.get(
      '$base/.ory/self-service/login/browser',
      options: Options(
        headers: {'Accept': 'application/json'},
        responseType: ResponseType.json,
      ),
    );
    final flow = _asMap(flowRes.data, step);
    final ui = _asMap(flow['ui'], step);
    final action = ui['action'] as String?;
    if (action == null) {
      throw HeadlessLoginException('login flow missing ui.action');
    }
    final csrf = _extractCsrf(ui['nodes']);

    step.name = 'kratos login';
    final loginRes = await _dio.post(
      action,
      data: jsonEncode({
        'method': 'password',
        'identifier': email,
        'password': password,
        'csrf_token': csrf,
      }),
      options: Options(
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.json,
      ),
    );
    if (loginRes.statusCode != 200) {
      throw HeadlessLoginException(
        'kratos login failed: ${loginRes.statusCode}',
      );
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
      final location = r.headers.value('location');
      if (location == null) {
        throw HeadlessLoginException('authorize hop $hop: missing Location');
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

  String _extractCsrf(Object? nodes) {
    if (nodes is! List) return '';
    for (final n in nodes) {
      if (n is Map) {
        final attrs = n['attributes'];
        if (attrs is Map && attrs['name'] == 'csrf_token') {
          return (attrs['value'] as String?) ?? '';
        }
      }
    }
    return '';
  }
}

/// The request a flow is on, for [HeadlessLoginException] messages.
class _Step {
  _Step(this.name);
  String name;
}
