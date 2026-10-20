import 'dart:convert';

import 'package:dio/dio.dart';

import 'auth_errors.dart';
import 'slauth_config.dart';

/// What a [TokenEndpoint.exchange] needs to turn an authorization code into a
/// session: the code, the PKCE verifier that authenticates it, and the redirect
/// URI the authorize request used (OAuth2 requires it to match).
///
/// [toString] is redacted: the code and verifier are secrets.
class TokenExchangeRequest {
  const TokenExchangeRequest({
    required this.code,
    required this.codeVerifier,
    required this.redirectUri,
  });

  /// The authorization code from the redirect callback.
  final String code;

  /// The PKCE (S256) code verifier whose challenge the authorize request sent.
  final String codeVerifier;

  /// The redirect URI the authorize request used.
  final String redirectUri;

  @override
  String toString() => 'TokenExchangeRequest(<redacted>)';
}

/// The `refresh_token` field of a token response, in one of three states.
///
/// The states drive the refresh-token rule in `AuthService`:
///
/// | State | On refresh | On exchange (a new session) |
/// | --- | --- | --- |
/// | [RefreshTokenAbsent] | keep the stored refresh token | no refresh token (any old one is deleted) |
/// | [RefreshTokenPresent] | replace it (rotation) | store it |
/// | [RefreshTokenBlank] | upstream error: [AuthUnavailable], adopt nothing | the exchange fails, nothing stored |
sealed class RefreshTokenField {
  const RefreshTokenField();

  /// Classify a field that IS present in the response: `null` or `''` is
  /// [RefreshTokenBlank]; anything else is [RefreshTokenPresent].
  factory RefreshTokenField.fromValue(String? value) =>
      value == null || value.isEmpty
      ? const RefreshTokenBlank()
      : RefreshTokenPresent(value);
}

/// The response had no `refresh_token` field at all.
final class RefreshTokenAbsent extends RefreshTokenField {
  const RefreshTokenAbsent();

  @override
  String toString() => 'RefreshTokenAbsent()';
}

/// The response carried a refresh token. [value] is non-empty when built via
/// [RefreshTokenField.fromValue]; `AuthService` treats an empty [value] as
/// [RefreshTokenBlank] regardless.
final class RefreshTokenPresent extends RefreshTokenField {
  const RefreshTokenPresent(this.value);

  final String value;

  @override
  String toString() => 'RefreshTokenPresent(<redacted>)';
}

/// The response had a `refresh_token` field whose value was `null` or `''`.
/// This is an upstream error, never "no refresh token".
final class RefreshTokenBlank extends RefreshTokenField {
  const RefreshTokenBlank();

  @override
  String toString() => 'RefreshTokenBlank()';
}

/// A typed token response from a [TokenEndpoint].
///
/// [toString] is redacted: every field but [expiresAt] is a secret.
class TokenResponse {
  const TokenResponse({
    required this.accessToken,
    this.refreshToken = const RefreshTokenAbsent(),
    this.idToken,
    this.expiresAt,
  });

  /// Parse an OAuth2 token response object (`access_token`, `refresh_token`,
  /// `id_token`, `expires_at` (ISO-8601) or `expires_in` (seconds)).
  ///
  /// Throws a [FormatException] (whose message never contains a value from the
  /// body) when `access_token` is missing/empty or a field has the wrong type.
  /// `expires_at` wins over `expires_in` when both are present; an unparseable
  /// `expires_at` yields a null [expiresAt]. An empty `id_token` is treated as
  /// absent.
  factory TokenResponse.fromJson(Map<String, dynamic> json) {
    final accessToken = json['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const FormatException(
        'Missing or invalid access_token in token response',
      );
    }

    final RefreshTokenField refreshToken;
    if (!json.containsKey('refresh_token')) {
      refreshToken = const RefreshTokenAbsent();
    } else {
      final raw = json['refresh_token'];
      if (raw != null && raw is! String) {
        throw const FormatException('refresh_token is not a string');
      }
      refreshToken = RefreshTokenField.fromValue(raw as String?);
    }

    final rawId = json['id_token'];
    if (rawId != null && rawId is! String) {
      throw const FormatException('id_token is not a string');
    }
    final idToken = rawId is String && rawId.isNotEmpty ? rawId : null;

    DateTime? expiresAt;
    final rawExpiresAt = json['expires_at'];
    if (rawExpiresAt != null) {
      if (rawExpiresAt is! String) {
        throw const FormatException('expires_at is not a string');
      }
      expiresAt = DateTime.tryParse(rawExpiresAt);
    } else {
      final rawExpiresIn = json['expires_in'];
      if (rawExpiresIn != null) {
        if (rawExpiresIn is! num) {
          throw const FormatException('expires_in is not a number');
        }
        expiresAt = DateTime.now().add(Duration(seconds: rawExpiresIn.round()));
      }
    }

    return TokenResponse(
      accessToken: accessToken,
      refreshToken: refreshToken,
      idToken: idToken,
      expiresAt: expiresAt,
    );
  }

  /// Parse a raw HTTP response body: a decoded JSON object, or a JSON string
  /// (Dio hands back a raw `String` when the upstream Content-Type sniff fails
  /// — e.g. behind a proxy — even with `ResponseType.json`).
  ///
  /// Throws a [FormatException] whose message never contains the body.
  factory TokenResponse.fromBody(Object? body) {
    Object? decoded = body;
    if (body is String) {
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        // jsonDecode's message quotes the source; never let it escape.
        throw const FormatException('Token response body is not valid JSON');
      }
    }
    if (decoded is Map<String, dynamic>) return TokenResponse.fromJson(decoded);
    if (decoded is Map) {
      try {
        return TokenResponse.fromJson(Map<String, dynamic>.from(decoded));
      } on TypeError {
        throw const FormatException('Token response has non-string keys');
      }
    }
    throw FormatException(
      'Unexpected token response shape: ${decoded.runtimeType}',
    );
  }

  /// The new access token. Must be non-empty.
  final String accessToken;

  /// The `refresh_token` field, in one of its three states.
  final RefreshTokenField refreshToken;

  /// The OIDC id token, if the response carried one (used as `id_token_hint`
  /// on RP-initiated logout). Refresh responses usually omit it.
  final String? idToken;

  /// When [accessToken] expires, if the response said.
  final DateTime? expiresAt;

  @override
  String toString() => 'TokenResponse(<redacted>, expiresAt: $expiresAt)';
}

/// The token half of an OAuth2 authorization-code + PKCE flow: exchange a code
/// for a session, and refresh a session.
///
/// Implementations throw [AuthUnauthorized] when the grant is dead and
/// [AuthUnavailable] for every transient or upstream fault; `AuthService`
/// decides whether to log out. Anything else an implementation throws is
/// treated as [AuthUnavailable] (the session is kept).
///
/// [HydraTokenEndpoint] (slauth's `/oauth2/token`) is the default; an app with
/// a different token service (e.g. its own backend bridging WorkOS) supplies
/// its own via `AuthService.withEndpoint`.
abstract class TokenEndpoint {
  const TokenEndpoint();

  /// Exchange an authorization code (+ PKCE verifier) for a new session.
  Future<TokenResponse> exchange(TokenExchangeRequest request);

  /// Exchange [refreshToken] for a fresh access token (and, usually, a rotated
  /// refresh token).
  Future<TokenResponse> refresh(String refreshToken);
}

/// slauth's (Ory Hydra's) `/oauth2/token`, as a public client: no secret, the
/// PKCE verifier authenticates the exchange.
///
/// Error mapping: HTTP 400 (`invalid_grant`) or 401 → [AuthUnauthorized]; any
/// other non-2xx status, a timeout, a connection error, or a 2xx body that is
/// not a token response → [AuthUnavailable]. The status is classified here,
/// before any error body is decoded, whatever the injected client's own
/// `validateStatus` / `receiveDataWhenStatusError`: a permissive client, or a
/// 401 whose body is not valid JSON, still yields [AuthUnauthorized].
class HydraTokenEndpoint implements TokenEndpoint {
  /// Posts to `${config.baseUrl}/oauth2/token`. Pass [dio] to inject a client
  /// (tests); it is used as-is, so its `baseUrl` must point at slauth. Its
  /// status policy is overridden per request (see the class doc).
  HydraTokenEndpoint({required SlauthConfig config, Dio? dio})
    : _clientId = config.clientId,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: config.baseUrl,
              connectTimeout: httpTimeout,
              receiveTimeout: httpTimeout,
            ),
          );

  /// Connect and receive timeout of the default client.
  static const httpTimeout = Duration(seconds: 10);

  /// The token endpoint path, relative to slauth's base URL.
  static const tokenPath = '/oauth2/token';

  final Dio _dio;
  final String _clientId;

  @override
  Future<TokenResponse> exchange(TokenExchangeRequest request) => _post({
    'grant_type': 'authorization_code',
    'code': request.code,
    'redirect_uri': request.redirectUri,
    'client_id': _clientId,
    'code_verifier': request.codeVerifier,
  });

  @override
  Future<TokenResponse> refresh(String refreshToken) => _post({
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': _clientId,
  });

  Future<TokenResponse> _post(Map<String, String> form) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        tokenPath,
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          // Force a JSON decode: when Hydra's Content-Type comes back without
          // the exact `application/json` Dio sniffs for (e.g. behind a proxy),
          // Dio falls through to a raw String; TokenResponse.fromBody parses
          // that too. Critical on refresh: Hydra rotates the refresh token on
          // every success AND has reuse detection, so a 200 dropped on the
          // floor (String vs Map) would revoke the session.
          responseType: ResponseType.json,
          // The endpoint owns its status policy, whatever the injected
          // client's: only a 2xx is a token response; any other status
          // becomes a badResponse DioException carrying that status...
          validateStatus: _isSuccess,
          // ...and its body is never decoded, so an error body that is not
          // valid JSON cannot turn a 400/401 into a status-less decode error.
          receiveDataWhenStatusError: false,
        ),
      );
    } on DioException catch (e) {
      throw _classify(e.response?.statusCode, e.type);
    } catch (_) {
      // Dio wraps nearly everything in a DioException; anything else is still
      // a fault on the way to (or back from) the server, never a dead grant.
      throw const AuthUnavailable();
    }
    final status = response.statusCode;
    if (!_isSuccess(status)) {
      // A failed request that an interceptor on the injected client resolved
      // into a plain response: classify its status all the same.
      throw _classify(status, DioExceptionType.badResponse);
    }
    try {
      return TokenResponse.fromBody(response.data);
    } catch (_) {
      throw AuthUnavailable(statusCode: status, malformedResponse: true);
    }
  }

  static bool _isSuccess(int? status) =>
      status != null && status >= 200 && status < 300;

  /// 400/401 → the grant is dead; everything else → transient. Mirrors the
  /// pre-`TokenEndpoint` `AuthService.refreshAccessToken`, which logged out
  /// only on a 400 or 401 status.
  static AuthEndpointException _classify(int? status, DioExceptionType type) {
    if (status == 400 || status == 401) {
      return AuthUnauthorized(statusCode: status, dioType: type);
    }
    return AuthUnavailable(statusCode: status, dioType: type);
  }
}
