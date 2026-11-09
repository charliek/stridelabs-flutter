// Drives HeadlessLogin end to end against a real slauth at or after N7
// (`POST /api/v1/account/login`, `/consent?flow=`), where first-party
// custom-scheme clients take the consent screen on every authorize. The Origin
// HeadlessLogin sends is SLAUTH_LIVE_BASE's, so it must equal the stack's
// AUTH_UI_URL origin (native-stack.sh and prox set it so).
// Skipped unless SLAUTH_LIVE_BASE is set, so CI never needs a stack.
//
// From a slauth checkout, `scripts/native-stack.sh up`, then:
//
//   source /tmp/slauth-e2e-stack.env
//   SLAUTH_LIVE_BASE="$BASE" SLAUTH_LIVE_EMAIL="$TEST_EMAIL" \
//     SLAUTH_LIVE_PASSWORD="$TEST_PASSWORD" SLAUTH_LIVE_SUBJECT="$IDENTITY_ID" \
//     flutter test test/headless_login_live_test.dart
//
// It prints only request paths and whether claims matched, never a token, a
// query string or a cookie.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/src/headless_login.dart';
import 'package:stridelabs_slauth/src/slauth_config.dart';

Map<String, dynamic> _jwtClaims(Object? token) {
  final parts = (token as String).split('.');
  return jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      )
      as Map<String, dynamic>;
}

void main() {
  final env = Platform.environment;
  final base = env['SLAUTH_LIVE_BASE'];

  for (final (clientId, audience, scheme) in const [
    ('slaudio-mobile', 'slaudio', 'slaudio'),
    ('tapper', 'tapper', 'tapper'),
  ]) {
    test(
      '$clientId signs in through the consent screen',
      () async {
        final subject = env['SLAUTH_LIVE_SUBJECT']!;
        final paths = <String>[];
        final dio =
            Dio(
                BaseOptions(
                  connectTimeout: const Duration(seconds: 15),
                  receiveTimeout: const Duration(seconds: 15),
                  validateStatus: (s) => s != null && s < 400,
                ),
              )
              ..interceptors.add(
                InterceptorsWrapper(
                  onRequest: (options, handler) {
                    paths.add('${options.method} ${options.uri.path}');
                    handler.next(options);
                  },
                ),
              );

        final tokens =
            await HeadlessLogin(
              config: SlauthConfig(
                baseUrl: base!,
                clientId: clientId,
                audience: audience,
                redirectUri: '$scheme://auth/callback',
                postLogoutUri: '$scheme://auth/logout',
              ),
              dio: dio,
            ).login(
              email: env['SLAUTH_LIVE_EMAIL']!,
              password: env['SLAUTH_LIVE_PASSWORD']!,
            );

        // ignore: avoid_print
        print('live $clientId: ${paths.join(' -> ')}');
        expect(paths, contains('POST /api/v1/account/login'));
        expect(paths, contains('POST /api/v1/oauth/consent/accept'));

        final access = _jwtClaims(tokens['access_token']);
        expect(access['sub'], subject);
        expect(access['aud'], contains(audience));
        expect(_jwtClaims(tokens['id_token'])['sub'], subject);
        expect(tokens['refresh_token'], isA<String>());

        // The server takes its own token back: it isn't merely JWT-shaped.
        final userinfo = await Dio().get<Map<String, dynamic>>(
          '$base/userinfo',
          options: Options(
            headers: {'Authorization': 'Bearer ${tokens['access_token']}'},
          ),
        );
        expect(userinfo.data?['sub'], subject);

        // ignore: avoid_print
        print('live $clientId: tokens issued, access and id sub match subject');
      },
      skip: base == null ? 'SLAUTH_LIVE_BASE is not set' : false,
    );
  }
}
