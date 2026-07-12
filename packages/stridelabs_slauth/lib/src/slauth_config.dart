/// Immutable configuration for a single slauth OAuth2 public client.
///
/// [audience] is **explicit and required** — it must never be defaulted to
/// [clientId]. An app is commonly registered under one client id (e.g.
/// `myapp-mobile`) while its backend validates a different `aud` on the access
/// token (e.g. `aud=myapp`), so the two differ. Defaulting audience to the
/// client id would mint tokens the API rejects.
class SlauthConfig {
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
  final String clientId;

  /// The API audience the issued access token must carry (`aud`). Separate from
  /// [clientId]; see the class doc.
  final String audience;

  /// OAuth redirect URI (custom scheme) registered for this client.
  final String redirectUri;

  /// Post-logout redirect URI (custom scheme) for RP-initiated logout.
  final String postLogoutUri;

  /// OAuth2 scope. `offline_access` is required for slauth to issue a refresh
  /// token; `openid` for the id token used as `id_token_hint` on logout.
  final String scope;

  static const String defaultScope = 'openid offline_access email profile';
}
