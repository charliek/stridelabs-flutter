/// OAuth2 authorization-code + PKCE client for StrideLabs native apps:
/// slauth (Ory Hydra + Kratos) by default, any provider via a pluggable
/// token endpoint and config.
///
/// Public API:
/// - [AuthConfig] — what the browser half needs (client id, redirect URI,
///   callback scheme, authorize URL, optional [EndSessionRequest]).
/// - [SlauthConfig] — the slauth [AuthConfig]; `audience` is explicit, never
///   the client id.
/// - [Pkce] — S256 verifier/challenge + `state` generation.
/// - [buildAuthorizeUrl] / [buildEndSessionUrl] — slauth URL builders
///   (audience explicit).
/// - [WebAuth] / [FlutterWebAuth2Impl] / [WebAuthOptions] — system-browser
///   flow abstraction and its plugin options.
/// - [TokenEndpoint] ([TokenExchangeRequest], [TokenResponse],
///   [RefreshTokenField]) and [HydraTokenEndpoint] — the token half (exchange,
///   refresh), pluggable; Hydra's `/oauth2/token` is the default.
/// - [AuthEndpointException] — typed endpoint failures: [AuthUnauthorized]
///   (dead grant → logout) and [AuthUnavailable] (transient → keep session).
/// - [TokenStore] and impls ([SecureStorageTokenStore], [FileTokenStore],
///   [InMemoryTokenStore]) + [defaultTokenStore] / [defaultTokenStoreDir].
/// - [AuthService] — token lifecycle (exchange, refresh + rotation, persist,
///   logout) with the typed [RefreshOutcome] and the opt-in
///   [RefreshRetryPolicy].
/// - [HeadlessLogin] — DEBUG-ONLY headless password login (drives local E2E).
///
/// Note: [HeadlessLogin] and its deps ([Pkce], [buildAuthorizeUrl],
/// [SlauthConfig], [AuthConfig]) intentionally avoid `package:flutter/*` so
/// they can run from a plain `dart run` tool; importing this barrel pulls the
/// Flutter-dependent pieces, so tools that must `dart run` should import
/// `src/headless_login.dart` (etc.) directly.
library;

export 'src/auth_config.dart';
export 'src/auth_errors.dart';
export 'src/auth_service.dart';
export 'src/authorize_url.dart';
export 'src/headless_login.dart';
export 'src/pkce.dart';
export 'src/slauth_config.dart';
export 'src/token_endpoint.dart';
export 'src/token_store.dart';
export 'src/web_auth.dart';
