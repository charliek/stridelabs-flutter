import 'slauth_config.dart';

/// Build the slauth (Ory Hydra) OAuth2 authorize URL for a PKCE S256 flow.
///
/// Targets slauth's `/oauth2/auth` endpoint directly. `offline_access` in the
/// scope is required for slauth to issue a refresh token. [audience] is an
/// **explicit** parameter — the issued access token carries it as `aud`, and
/// a backend typically validates a specific `aud` (which differs from the
/// client id), so it must never be silently defaulted to the client id.
Uri buildAuthorizeUrl({
  required String slauthBaseUrl,
  required String clientId,
  required String redirectUri,
  required String codeChallenge,
  required String state,
  required String audience,
  String scope = SlauthConfig.defaultScope,
}) {
  return Uri.parse('$slauthBaseUrl/oauth2/auth').replace(
    queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scope,
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'audience': audience,
    },
  );
}

/// Build slauth's RP-initiated logout (OIDC end-session) URL.
///
/// Hits Hydra's `/oauth2/sessions/logout` through slauth's proxy, which ends the
/// shared Kratos session and the Hydra login session, then redirects to
/// [postLogoutRedirectUri] (a custom scheme registered for this client).
/// [idTokenHint] lets Hydra validate the redirect and skip a prompt.
Uri buildEndSessionUrl({
  required String slauthBaseUrl,
  required String idTokenHint,
  required String postLogoutRedirectUri,
}) {
  return Uri.parse('$slauthBaseUrl/oauth2/sessions/logout').replace(
    queryParameters: {
      'id_token_hint': idTokenHint,
      'post_logout_redirect_uri': postLogoutRedirectUri,
    },
  );
}
