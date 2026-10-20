import 'package:dio/dio.dart';

/// A typed failure from a [TokenEndpoint](token_endpoint.dart) call.
///
/// Endpoints classify every failure into one of two outcomes and throw it;
/// [AuthService](auth_service.dart) decides what to do with it:
///
/// - [AuthUnauthorized] — the grant is dead (an expired/revoked refresh token,
///   an invalid code). On refresh, the session is cleared (logout).
/// - [AuthUnavailable] — a transient or upstream fault (5xx, 408, 429, a
///   timeout, a connection error, a malformed body). On refresh, the session is
///   kept (memory and store) so a later attempt can succeed.
///
/// Every field is non-secret **by construction** (a status code, an enum, a
/// flag), so [toString] is always safe to log. Never attach a response body, a
/// URL, a token, an authorization code or a PKCE verifier to one of these.
sealed class AuthEndpointException implements Exception {
  const AuthEndpointException({
    this.statusCode,
    this.dioType,
    this.malformedResponse = false,
  });

  /// HTTP status of the upstream response, when there was one.
  final int? statusCode;

  /// The Dio failure category, when the endpoint talks HTTP through Dio and
  /// the failure came from Dio (e.g. [DioExceptionType.badResponse],
  /// [DioExceptionType.receiveTimeout], [DioExceptionType.connectionError]).
  final DioExceptionType? dioType;

  /// True when the upstream answered but its body could not be used as a token
  /// response (not JSON, not an object, a missing or mistyped field).
  final bool malformedResponse;

  /// Short class name for redacted logs (stable under obfuscation, unlike
  /// `runtimeType`).
  String get kind;

  @override
  String toString() =>
      '$kind(status: $statusCode, dioType: ${dioType?.name}, '
      'malformedResponse: $malformedResponse)';
}

/// The grant is dead: the refresh token is expired/revoked/reused, or the
/// authorization code is invalid. A refresh that fails this way logs out.
///
/// Hydra/slauth: HTTP 400 (`invalid_grant`) or 401.
final class AuthUnauthorized extends AuthEndpointException {
  const AuthUnauthorized({
    super.statusCode,
    super.dioType,
    super.malformedResponse,
  });

  @override
  String get kind => 'AuthUnauthorized';
}

/// A transient or upstream fault: the session must be kept. A refresh that
/// fails this way leaves tokens in memory and on disk untouched.
///
/// Hydra/slauth: any HTTP status other than 400/401, a timeout, a connection
/// error, or a body that is not a usable token response.
final class AuthUnavailable extends AuthEndpointException {
  const AuthUnavailable({
    super.statusCode,
    super.dioType,
    super.malformedResponse,
  });

  @override
  String get kind => 'AuthUnavailable';
}
