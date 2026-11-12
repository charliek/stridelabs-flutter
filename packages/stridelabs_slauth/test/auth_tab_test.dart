import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/src/auth_tab.dart' show authTabChannel;
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

const _scheme = 'myapp://auth/callback';
const _link = 'https://auth.example.com/app/myapp/callback';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Answers the channel with [reply] (or throws [error]) and records calls.
  List<MethodCall> answer({Object? reply, PlatformException? error}) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(authTabChannel, (call) async {
      calls.add(call);
      if (error != null) throw error;
      return reply;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(authTabChannel, null));
    return calls;
  }

  group('androidAuthTabBrowser', () {
    test('passes the plugin options that choose the browser', () async {
      final calls = answer(
        reply: {
          'package': 'com.android.chrome',
          'version': '147.0.7727.55',
          'authTab': true,
        },
      );
      final browser = await androidAuthTabBrowser(
        WebAuthOptions(
          preferEphemeral: true,
          customTabsPackageOrder: const ['org.mozilla.firefox'],
        ),
      );

      expect(calls.single.method, 'authTabBrowser');
      expect(calls.single.arguments, {
        'customTabsPackageOrder': ['org.mozilla.firefox'],
        'preferEphemeral': true,
      });
      expect(browser.packageName, 'com.android.chrome');
      expect(browser.version, '147.0.7727.55');
      expect(browser.supportsAuthTab, isTrue);
      expect(browser.error, isNull);
    });

    test('unset options are sent as the plugin defaults', () async {
      final calls = answer(reply: {'authTab': false});
      await androidAuthTabBrowser(WebAuthOptions.defaults);
      expect(calls.single.arguments, {
        'customTabsPackageOrder': <String>[],
        'preferEphemeral': false,
      });
    });

    test('a browser without Auth Tab, or no browser, is a no', () async {
      for (final reply in <Object?>[
        {'package': 'com.android.chrome', 'version': '133.0', 'authTab': false},
        {'package': null, 'version': null, 'authTab': false},
        {'authTab': 'true'}, // only a real true counts
        null,
      ]) {
        answer(reply: reply);
        final browser = await androidAuthTabBrowser(WebAuthOptions.defaults);
        expect(browser.supportsAuthTab, isFalse, reason: '$reply');
      }
    });

    test('never throws: a platform error or no plugin is a no', () async {
      answer(error: PlatformException(code: 'AUTH_TAB_CHECK_FAILED'));
      var browser = await androidAuthTabBrowser(WebAuthOptions.defaults);
      expect(browser.supportsAuthTab, isFalse);
      expect(browser.error, contains('AUTH_TAB_CHECK_FAILED'));

      // No handler at all: MissingPluginException.
      messenger.setMockMethodCallHandler(authTabChannel, null);
      browser = await androidAuthTabBrowser(WebAuthOptions.defaults);
      expect(browser.supportsAuthTab, isFalse);
      expect(browser.error, contains('MissingPluginException'));
    });

    test('off Android it answers no without asking', () async {
      final calls = answer(reply: {'authTab': true});
      for (final p in TargetPlatform.values.where(
        (p) => p != TargetPlatform.android,
      )) {
        debugDefaultTargetPlatformOverride = p;
        try {
          final browser = await androidAuthTabBrowser(WebAuthOptions.defaults);
          expect(browser.supportsAuthTab, isFalse, reason: '$p');
          expect(await androidAuthTabSupported(WebAuthOptions.defaults), false);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
      expect(calls, isEmpty);
    });

    test('androidAuthTabSupported is the browser answer alone', () async {
      answer(reply: {'package': 'com.android.chrome', 'authTab': true});
      expect(await androidAuthTabSupported(WebAuthOptions.defaults), isTrue);
      answer(reply: {'package': 'com.android.chrome', 'authTab': false});
      expect(await androidAuthTabSupported(WebAuthOptions.defaults), isFalse);
    });
  });

  group('chooseSignInRedirect', () {
    Future<String> choose({
      String appLink = _link,
      TargetPlatform? platform,
      required AuthTabCheck check,
      WebAuthOptions base = WebAuthOptions.defaults,
    }) => chooseSignInRedirect(
      customSchemeRedirect: _scheme,
      appLinkRedirect: appLink,
      base: base,
      check: check,
      platform: platform,
    );

    test('Android with an Auth Tab browser takes the App Link', () async {
      WebAuthOptions? asked;
      final redirect = await choose(
        platform: TargetPlatform.android,
        base: WebAuthOptions(
          preferEphemeral: true,
          customTabsPackageOrder: const ['com.android.chrome'],
        ),
        check: (options) async {
          asked = options;
          return true;
        },
      );
      expect(redirect, _link);
      // The check sees the options the sign-in will use.
      expect(asked!.httpsHost, 'auth.example.com');
      expect(asked!.httpsPath, '/app/myapp/callback');
      expect(asked!.preferEphemeral, isTrue);
      expect(asked!.customTabsPackageOrder, ['com.android.chrome']);
    });

    test('Android without Auth Tab falls back to the custom scheme', () async {
      expect(
        await choose(
          platform: TargetPlatform.android,
          check: (_) async => false,
        ),
        _scheme,
      );
    });

    test('a check that throws counts as no', () async {
      expect(
        await choose(
          platform: TargetPlatform.android,
          check: (_) async => throw StateError('boom'),
        ),
        _scheme,
      );
    });

    test('no App Link, or not Android: the custom scheme, unasked', () async {
      var asked = 0;
      Future<bool> check(WebAuthOptions _) async {
        asked++;
        return true;
      }

      expect(
        await choose(
          appLink: '',
          platform: TargetPlatform.android,
          check: check,
        ),
        _scheme,
      );
      for (final p in TargetPlatform.values.where(
        (p) => p != TargetPlatform.android,
      )) {
        expect(
          await choose(platform: p, check: check),
          _scheme,
          reason: '$p',
        );
      }
      expect(asked, 0);
    });

    test('platform defaults to defaultTargetPlatform', () async {
      // flutter_test's default platform is Android.
      expect(await choose(check: (_) async => true), _link);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(await choose(check: (_) async => true), _scheme);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('an unusable App Link is a configuration error, not a fallback', () {
      for (final bad in [
        'https://auth.example.com/app/myapp/',
        'https://Auth.example.com/app/myapp/callback',
        'https://0x7f.1/callback',
      ]) {
        expect(
          choose(
            appLink: bad,
            platform: TargetPlatform.android,
            check: (_) async => true,
          ),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'redirectUri'),
          ),
          reason: bad,
        );
      }
    });

    test('the default check asks the channel', () async {
      final calls = answer(reply: {'package': 'p', 'authTab': true});
      expect(
        await chooseSignInRedirect(
          customSchemeRedirect: _scheme,
          appLinkRedirect: _link,
        ),
        _link,
      );
      expect(calls, hasLength(1));
    });
  });
}
