import 'auth_config.dart';
import 'authorize_url.dart' as urls;

/// Immutable configuration for a single slauth OAuth2 public client — the
/// slauth/Hydra [AuthConfig].
///
/// [audience] is **explicit and required** — it must never be defaulted to
/// [clientId]. An app is commonly registered under one client id (e.g.
/// `myapp-mobile`) while its backend validates a different `aud` on the access
/// token (e.g. `aud=myapp`), so the two differ. Defaulting audience to the
/// client id would mint tokens the API rejects.
class SlauthConfig extends AuthConfig {
  const SlauthConfig({
    required this.baseUrl,
    required this.clientId,
    required this.audience,
    required this.redirectUri,
    required this.postLogoutUri,
    this.scope = defaultScope,
  });

  /// slauth base URL (e.g. `https://auth.local.stridelabs.ai`). No trailing slash.
  final String baseUrl;

  /// OAuth2 client id this app is registered as in slauth/Hydra.
  @override
  final String clientId;

  /// The API audience the issued access token must carry (`aud`). Separate from
  /// [clientId]; see the class doc.
  final String audience;

  /// OAuth redirect URI (custom scheme) registered for this client.
  @override
  final String redirectUri;

  /// Post-logout redirect URI (custom scheme) for RP-initiated logout.
  final String postLogoutUri;

  /// OAuth2 scope. `offline_access` is required for slauth to issue a refresh
  /// token; `openid` for the id token used as `id_token_hint` on logout.
  final String scope;

  static const String defaultScope = 'openid offline_access email profile';

  /// slauth's `/oauth2/auth` URL — exactly `buildAuthorizeUrl` with this
  /// config's base URL, client id, redirect URI, audience and scope.
  @override
  Uri authorizeUrl({required String codeChallenge, required String state}) =>
      urls.buildAuthorizeUrl(
        slauthBaseUrl: baseUrl,
        clientId: clientId,
        redirectUri: redirectUri,
        codeChallenge: codeChallenge,
        state: state,
        audience: audience,
        scope: scope,
      );

  /// slauth's end-session step — exactly `buildEndSessionUrl` with this
  /// config's base URL and [postLogoutUri], returning to [postLogoutUri]'s
  /// scheme. Null when [idTokenHint] is null or empty (Hydra needs the hint to
  /// validate the redirect without a prompt; the apps skip the step then).
  @override
  EndSessionRequest? endSessionRequest({String? idTokenHint}) {
    if (idTokenHint == null || idTokenHint.isEmpty) return null;
    return EndSessionRequest(
      url: urls.buildEndSessionUrl(
        slauthBaseUrl: baseUrl,
        idTokenHint: idTokenHint,
        postLogoutRedirectUri: postLogoutUri,
      ),
      callbackUrlScheme: Uri.parse(postLogoutUri).scheme,
    );
  }
}
