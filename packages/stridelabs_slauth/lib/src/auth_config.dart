/// What the browser half of an OAuth2 authorization-code + PKCE (S256) login
/// needs, independent of the identity provider.
///
/// [SlauthConfig](slauth_config.dart) is the slauth/Hydra implementation. An
/// app on another provider implements its own, e.g. WorkOS AuthKit:
///
/// ```dart
/// class WorkOsAuthConfig extends AuthConfig {
///   const WorkOsAuthConfig({required this.clientId, required this.redirectUri});
///
///   @override
///   final String clientId;
///   @override
///   final String redirectUri;
///
///   @override
///   Uri authorizeUrl({required String codeChallenge, required String state}) =>
///       Uri.https('api.workos.com', '/user_management/authorize', {
///         'client_id': clientId,
///         'redirect_uri': redirectUri,
///         'response_type': 'code',
///         'code_challenge': codeChallenge,
///         'code_challenge_method': 'S256',
///         'state': state,
///         'provider': 'authkit',
///       });
///
///   // No end-session step: the default endSessionRequest returns null.
/// }
/// ```
///
/// This file deliberately imports nothing (no `package:flutter/*`), so it stays
/// usable from a plain `dart run` tool alongside `HeadlessLogin`.
abstract class AuthConfig {
  const AuthConfig();

  /// The OAuth2 client id this app is registered as.
  String get clientId;

  /// The OAuth2 redirect URI (usually a custom scheme) registered for this
  /// client. The token exchange must send the same value.
  String get redirectUri;

  /// The URL scheme the system browser intercepts to return the callback to
  /// the app. Defaults to [redirectUri]'s scheme.
  String get callbackUrlScheme => Uri.parse(redirectUri).scheme;

  /// Build the authorize URL for one login attempt from a fresh PKCE S256
  /// [codeChallenge] and an opaque CSRF [state] (regenerate both per attempt).
  Uri authorizeUrl({required String codeChallenge, required String state});

  /// The RP-initiated logout step to run in the system browser, or null when
  /// there is none: the provider has no end-session step (the default), or
  /// this provider needs an id token and [idTokenHint] is null/empty.
  EndSessionRequest? endSessionRequest({String? idTokenHint}) => null;
}

/// An RP-initiated logout (OIDC end-session) to open in the system browser:
/// the [url] to open and the [callbackUrlScheme] that returns to the app.
class EndSessionRequest {
  const EndSessionRequest({required this.url, required this.callbackUrlScheme});

  final Uri url;
  final String callbackUrlScheme;

  @override
  String toString() => 'EndSessionRequest(<redacted>)';
}
