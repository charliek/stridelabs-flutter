import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_web_auth_2_platform_interface/flutter_web_auth_2_platform_interface.dart';
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

/// Records what `FlutterWebAuth2.authenticate` hands the platform.
class _RecordingPlatform extends FlutterWebAuth2Platform {
  final calls = <({String url, String scheme, Map<String, dynamic> options})>[];

  @override
  Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
    required Map<String, dynamic> options,
  }) async {
    calls.add((url: url, scheme: callbackUrlScheme, options: options));
    return 'myapp://auth/callback?code=c&state=s';
  }

  @override
  Future<void> clearAllDanglingCalls() async {}
}

/// A consumer-style fake written against the ORIGINAL `WebAuth` signature:
/// it must keep compiling (tapper's and slaudio's tests have these).
class _ConsumerFakeWebAuth implements WebAuth {
  @override
  Future<Uri> authenticate({
    required Uri url,
    required String callbackUrlScheme,
  }) async => Uri.parse('myapp://auth/callback');
}

final _url = Uri.parse('https://auth.test/oauth2/auth?client_id=x');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RecordingPlatform platform;

  setUp(() {
    platform = _RecordingPlatform();
    FlutterWebAuth2Platform.instance = platform;
  });

  test('defaults reproduce the plain plugin call exactly', () async {
    final result = await const FlutterWebAuth2Impl().authenticate(
      url: _url,
      callbackUrlScheme: 'myapp',
    );

    expect(result, Uri.parse('myapp://auth/callback?code=c&state=s'));
    final call = platform.calls.single;
    expect(call.url, _url.toString());
    expect(call.scheme, 'myapp');
    // What `FlutterWebAuth2.authenticate(url:, callbackUrlScheme:)` (no
    // options — the pre-WebAuthOptions call) sends.
    expect(call.options, const FlutterWebAuth2Options().toJson());
  });

  test('WebAuthOptions.defaults and WebAuthOptions() map to the plugin '
      'defaults', () {
    for (final options in [WebAuthOptions.defaults, WebAuthOptions()]) {
      expect(
        options.toPluginOptions().toJson(),
        const FlutterWebAuth2Options().toJson(),
      );
    }
  });

  test('every non-default option reaches the plugin call', () async {
    final options = WebAuthOptions(
      preferEphemeral: true,
      useWebview: false,
      timeout: Duration(seconds: 90),
      httpsHost: 'auth.example.com',
      httpsPath: '/callback',
      intentFlags: 268435456,
      customTabsPackageOrder: ['com.android.chrome'],
      landingPageHtml: '<p>done</p>',
      windowName: '_self',
      debugOrigin: 'http://localhost:1234',
      silentAuth: true,
    );
    await FlutterWebAuth2Impl(
      options: options,
    ).authenticate(url: _url, callbackUrlScheme: 'myapp');

    expect(platform.calls.single.options, {
      'preferEphemeral': true,
      'useWebview': false,
      'timeout': 90,
      'httpsHost': 'auth.example.com',
      'httpsPath': '/callback',
      'intentFlags': 268435456,
      'customTabsPackageOrder': ['com.android.chrome'],
      'landingPageHtml': '<p>done</p>',
      'windowName': '_self',
      'debugOrigin': 'http://localhost:1234',
      'silentAuth': true,
    });
  });

  test('a sub-second timeout is rounded UP to whole seconds, never to 0', () {
    int? seconds(Duration d) =>
        WebAuthOptions(timeout: d).toPluginOptions().timeout;
    expect(seconds(const Duration(milliseconds: 500)), 1);
    expect(seconds(const Duration(microseconds: 1)), 1);
    expect(seconds(const Duration(seconds: 1)), 1);
    expect(seconds(const Duration(milliseconds: 1001)), 2);
    expect(seconds(const Duration(seconds: 90)), 90);
  });

  test('a sub-second timeout reaches the plugin call as 1 s', () async {
    await FlutterWebAuth2Impl(
      options: WebAuthOptions(timeout: const Duration(milliseconds: 500)),
    ).authenticate(url: _url, callbackUrlScheme: 'myapp');
    expect(platform.calls.single.options['timeout'], 1);
  });

  test('a zero or negative timeout is rejected at construction', () {
    for (final bad in [Duration.zero, const Duration(seconds: -1)]) {
      expect(
        () => WebAuthOptions(timeout: bad),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'timeout')),
        reason: '$bad',
      );
    }
  });

  test('a fake on the original WebAuth signature still works', () async {
    final WebAuth fake = _ConsumerFakeWebAuth();
    expect(
      await fake.authenticate(url: _url, callbackUrlScheme: 'myapp'),
      Uri.parse('myapp://auth/callback'),
    );
  });
}
