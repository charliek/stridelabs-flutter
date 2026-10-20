import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

const _slauth = SlauthConfig(
  baseUrl: 'https://auth.test',
  clientId: 'slaudio-mobile',
  audience: 'slaudio',
  redirectUri: 'slaudio://auth/callback',
  postLogoutUri: 'slaudio-logout://auth/logout',
  scope: 'openid offline_access',
);

/// The shape lumen's WorkOS AuthKit config will take (L3.3): proves the
/// abstraction can express it — authorize URL with `provider=authkit`, no
/// end-session step.
class _WorkOsConfig extends AuthConfig {
  const _WorkOsConfig();

  @override
  String get clientId => 'client_01ABC';

  @override
  String get redirectUri => 'lumen://auth/callback';

  @override
  Uri authorizeUrl({required String codeChallenge, required String state}) =>
      Uri.https('api.workos.com', '/user_management/authorize', {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'state': state,
        'provider': 'authkit',
      });
}

void main() {
  group('SlauthConfig as an AuthConfig', () {
    test('authorizeUrl is exactly buildAuthorizeUrl with the config', () {
      final AuthConfig config = _slauth;
      expect(
        config.authorizeUrl(codeChallenge: 'chal', state: 'st'),
        buildAuthorizeUrl(
          slauthBaseUrl: 'https://auth.test',
          clientId: 'slaudio-mobile',
          redirectUri: 'slaudio://auth/callback',
          codeChallenge: 'chal',
          state: 'st',
          audience: 'slaudio',
          scope: 'openid offline_access',
        ),
      );
    });

    test('client id, redirect URI and callback scheme', () {
      final AuthConfig config = _slauth;
      expect(config.clientId, 'slaudio-mobile');
      expect(config.redirectUri, 'slaudio://auth/callback');
      expect(config.callbackUrlScheme, 'slaudio');
    });

    test('endSessionRequest is exactly buildEndSessionUrl, returning to the '
        'post-logout scheme', () {
      final request = _slauth.endSessionRequest(idTokenHint: 'idt')!;
      expect(
        request.url,
        buildEndSessionUrl(
          slauthBaseUrl: 'https://auth.test',
          idTokenHint: 'idt',
          postLogoutRedirectUri: 'slaudio-logout://auth/logout',
        ),
      );
      expect(request.callbackUrlScheme, 'slaudio-logout');
    });

    test('no id token → no end-session step', () {
      expect(_slauth.endSessionRequest(), isNull);
      expect(_slauth.endSessionRequest(idTokenHint: ''), isNull);
    });
  });

  group('a WorkOS-shaped AuthConfig is expressible', () {
    test('authorize URL carries the AuthKit PKCE parameters', () {
      const AuthConfig config = _WorkOsConfig();
      final url = config.authorizeUrl(codeChallenge: 'chal', state: 'st');
      expect(url.origin, 'https://api.workos.com');
      expect(url.path, '/user_management/authorize');
      expect(url.queryParameters, {
        'client_id': 'client_01ABC',
        'redirect_uri': 'lumen://auth/callback',
        'response_type': 'code',
        'code_challenge': 'chal',
        'code_challenge_method': 'S256',
        'state': 'st',
        'provider': 'authkit',
      });
      expect(config.callbackUrlScheme, 'lumen');
    });

    test('no end-session step by default', () {
      const AuthConfig config = _WorkOsConfig();
      expect(config.endSessionRequest(idTokenHint: 'anything'), isNull);
    });
  });
}
