import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Thin wrapper around the system-browser OAuth flow so the login screen can be
/// widget-tested with a fake implementation injected via a provider.
abstract class WebAuth {
  Future<Uri> authenticate({
    required Uri url,
    required String callbackUrlScheme,
  });
}

/// Options for the `flutter_web_auth_2` system-browser flow, passed through by
/// [FlutterWebAuth2Impl].
///
/// Every field is optional: `null` means "the plugin's default", so
/// [WebAuthOptions.defaults] (or `WebAuthOptions()`) reproduces a plain
/// `FlutterWebAuth2.authenticate(url:, callbackUrlScheme:)` call exactly.
/// The platform notes are the plugin's (5.x).
///
/// The constructor is not `const` because it validates [timeout] (a `const`
/// constructor cannot inspect a [Duration]); [defaults] is the `const`
/// instance.
class WebAuthOptions {
  /// Throws an [ArgumentError] if [timeout] is zero or negative.
  WebAuthOptions({
    this.preferEphemeral,
    this.useWebview,
    this.timeout,
    this.httpsHost,
    this.httpsPath,
    this.intentFlags,
    this.customTabsPackageOrder,
    this.landingPageHtml,
    this.windowName,
    this.debugOrigin,
    this.silentAuth,
  }) {
    final t = timeout;
    if (t != null && t <= Duration.zero) {
      throw ArgumentError.value(t, 'timeout', 'must be positive');
    }
  }

  const WebAuthOptions._defaults()
    : preferEphemeral = null,
      useWebview = null,
      timeout = null,
      httpsHost = null,
      httpsPath = null,
      intentFlags = null,
      customTabsPackageOrder = null,
      landingPageHtml = null,
      windowName = null,
      debugOrigin = null,
      silentAuth = null;

  /// Every field unset: the plugin's own defaults.
  static const defaults = WebAuthOptions._defaults();

  /// iOS, macOS, Android: use an ephemeral browser session (no shared cookies)
  /// where possible. Plugin default: false.
  final bool? preferEphemeral;

  /// Linux, Windows: true uses the embedded webview (any callback scheme);
  /// false uses the plugin's local HTTP server (loopback callbacks only).
  /// Plugin default: true.
  final bool? useWebview;

  /// Linux, Windows, web: abort the flow after this long. Must be positive.
  /// The plugin takes whole seconds, so a fraction of a second is rounded
  /// up (500 ms → 1 s), never down to a zero-second timeout. Plugin default:
  /// 5 minutes.
  final Duration? timeout;

  /// The callback URL's host. Required by the plugin when the callback scheme
  /// is `https` (Android, and iOS ≥ 17.4 / macOS ≥ 14.4); on Linux/Windows with
  /// the webview, compared against the callback URL's host for any scheme.
  final String? httpsHost;

  /// The callback URL's path; see [httpsHost].
  final String? httpsPath;

  /// Android: intent flags for the Custom Tabs intent. Plugin default: 0.
  final int? intentFlags;

  /// Android: browser packages to try for Custom Tabs, in order.
  final List<String>? customTabsPackageOrder;

  /// Linux, Windows with `useWebview: false`: the HTML shown by the local
  /// server once the callback arrives. Plugin default: an auto-closing page.
  final String? landingPageHtml;

  /// Web: the window name for the `window.open` call.
  final String? windowName;

  /// Web, debug builds only: override the redirect URL's origin.
  final String? debugOrigin;

  /// Web: load the URL in a hidden iframe (silent auth). Plugin default: false.
  final bool? silentAuth;

  /// The plugin options these map to. Unset fields are passed as `null`, which
  /// the plugin resolves to its own defaults.
  FlutterWebAuth2Options toPluginOptions() => FlutterWebAuth2Options(
    preferEphemeral: preferEphemeral,
    useWebview: useWebview,
    timeout: _wholeSecondsRoundedUp(timeout),
    httpsHost: httpsHost,
    httpsPath: httpsPath,
    intentFlags: intentFlags,
    customTabsPackageOrder: customTabsPackageOrder,
    landingPageHtml: landingPageHtml,
    windowName: windowName,
    debugOrigin: debugOrigin,
    silentAuth: silentAuth,
  );

  static int? _wholeSecondsRoundedUp(Duration? d) => d == null
      ? null
      : (d.inMicroseconds + Duration.microsecondsPerSecond - 1) ~/
            Duration.microsecondsPerSecond;
}

/// Production implementation backed by `flutter_web_auth_2` — opens the OS
/// "secure browser" (`ASWebAuthenticationSession` on iOS/macOS, Chrome Custom
/// Tabs on Android, a webview on Linux/Windows) and returns the custom-scheme
/// callback URI.
class FlutterWebAuth2Impl implements WebAuth {
  /// [options] defaults to [WebAuthOptions.defaults], i.e. the plugin's own
  /// defaults (the same call this class made before it took options).
  const FlutterWebAuth2Impl({this.options = WebAuthOptions.defaults});

  final WebAuthOptions options;

  @override
  Future<Uri> authenticate({
    required Uri url,
    required String callbackUrlScheme,
  }) async {
    final result = await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackUrlScheme,
      options: options.toPluginOptions(),
    );
    return Uri.parse(result);
  }
}
