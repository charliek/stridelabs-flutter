/// slauth (Ory Hydra + Kratos) OAuth2 PKCE client for StrideLabs native apps.
///
/// Public API:
/// - [SlauthConfig] — per-client config; `audience` is explicit, never the client id.
/// - [Pkce] — S256 verifier/challenge + `state` generation.
/// - [buildAuthorizeUrl] / [buildEndSessionUrl] — URL builders (audience explicit).
/// - [WebAuth] / [FlutterWebAuth2Impl] — system-browser flow abstraction.
/// - [TokenStore] and impls ([SecureStorageTokenStore], [FileTokenStore],
///   [InMemoryTokenStore]) + [defaultTokenStore] / [defaultTokenStoreDir].
/// - [AuthService] — token lifecycle (exchange, refresh+rotation, persist, logout).
/// - [HeadlessLogin] — DEBUG-ONLY headless password login (drives local E2E).
///
/// Note: [HeadlessLogin] and its deps ([Pkce], [buildAuthorizeUrl], [SlauthConfig])
/// intentionally avoid `package:flutter/*` so they can run from a plain `dart run`
/// tool; importing this barrel pulls the Flutter-dependent pieces, so tools that
/// must `dart run` should import `src/headless_login.dart` (etc.) directly.
library;

export 'src/auth_service.dart';
export 'src/authorize_url.dart';
export 'src/headless_login.dart';
export 'src/pkce.dart';
export 'src/slauth_config.dart';
export 'src/token_store.dart';
export 'src/web_auth.dart';
