import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

import 'web_auth.dart';

/// The browser `flutter_web_auth_2` would open for a sign-in on Android, and
/// whether it opens there as an Auth Tab. What [androidAuthTabBrowser]
/// returns.
final class AuthTabBrowser {
  const AuthTabBrowser({
    required this.packageName,
    required this.version,
    required this.supportsAuthTab,
    this.error,
  });

  /// The browser's package (`com.android.chrome`), or null when no browser
  /// was found or the check failed.
  final String? packageName;

  /// The browser's `versionName`, when it could be read.
  final String? version;

  /// True only when the browser declares Auth Tab support
  /// (`CustomTabsClient.isAuthTabSupported`) and the plugin would open it as
  /// one. False whenever that is not known for certain.
  final bool supportsAuthTab;

  /// Why the check failed (off Android, no plugin, a platform error), or
  /// null when it ran.
  final String? error;

  @override
  String toString() =>
      'AuthTabBrowser(package: $packageName, version: $version, '
      'authTab: $supportsAuthTab${error == null ? '' : ', error: $error'})';
}

/// Decides whether a sign-in may use its https redirect: true only when the
/// browser that will open supports Auth Tab. [androidAuthTabSupported] is the
/// default; an app passes its own to log the decision or in tests.
typedef AuthTabCheck = Future<bool> Function(WebAuthOptions options);

@visibleForTesting
const authTabChannel = MethodChannel('stridelabs_slauth/auth_tab');

/// Asks Android which browser `flutter_web_auth_2` (5.1.x) would open for a
/// sign-in with [options] (its `customTabsPackageOrder`, then the default
/// browser, then the installed ones) and whether that browser declares Auth
/// Tab support. Never throws: off Android, without the plugin (a test, an
/// add-to-app host) or on a platform error it returns
/// `supportsAuthTab: false` with the [AuthTabBrowser.error].
///
/// Why it matters: the plugin launches an `AuthTabIntent` (unless an
/// ephemeral sign-in meets a browser below its version thresholds, when it
/// launches a Custom Tab, which this check also answers no for), and on a
/// browser without Auth Tab that intent quietly opens a plain Custom Tab,
/// where an https (App Link) callback never comes back to the app. Only a declared
/// Auth Tab is trusted, never a version guess: some browsers return https
/// callbacks before they declare it (Chrome 133 did, in our checks), and
/// this still says no for them, which only costs the custom scheme's
/// consent screen.
Future<AuthTabBrowser> androidAuthTabBrowser(WebAuthOptions options) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return const AuthTabBrowser(
      packageName: null,
      version: null,
      supportsAuthTab: false,
      error: 'not Android',
    );
  }
  try {
    final r = await authTabChannel.invokeMapMethod<String, Object?>(
      'authTabBrowser',
      {
        'customTabsPackageOrder': options.customTabsPackageOrder ?? <String>[],
        'preferEphemeral': options.preferEphemeral ?? false,
      },
    );
    final package = r?['package'];
    final version = r?['version'];
    return AuthTabBrowser(
      packageName: package is String ? package : null,
      version: version is String ? version : null,
      supportsAuthTab: r?['authTab'] == true,
    );
  } catch (e) {
    return AuthTabBrowser(
      packageName: null,
      version: null,
      supportsAuthTab: false,
      error: '$e',
    );
  }
}

/// [androidAuthTabBrowser]'s answer alone: the default [AuthTabCheck].
Future<bool> androidAuthTabSupported(WebAuthOptions options) async =>
    (await androidAuthTabBrowser(options)).supportsAuthTab;

/// The `redirect_uri` for one sign-in: [appLinkRedirect] (an https Android
/// App Link) when it is set, the platform is Android and [check] says the
/// browser opens as an Auth Tab; otherwise [customSchemeRedirect].
///
/// Call it at the start of each sign-in, not once per app run (the default
/// browser can change), and use the result for everything in that sign-in:
/// the authorize URL, the browser options
/// (`WebAuthOptions.forRedirect(redirect, base: base)`), the callback check
/// and the token exchange. Sign-out keeps its own custom-scheme redirect.
///
/// On Android, an [appLinkRedirect] that is not an https redirect
/// `WebAuthOptions.forRedirect` accepts throws an [ArgumentError] (a
/// configuration error, reported rather than hidden by the fallback). A
/// [check] that throws counts as no. [platform] defaults to
/// `defaultTargetPlatform`.
///
/// The check and the launch are separate moments: `flutter_web_auth_2`
/// chooses its browser again when it launches, moments later. Only a browser
/// change in between (the default switched, the browser removed) could open
/// an https sign-in in a plain Custom Tab; that sign-in would not return, and
/// the next attempt checks afresh.
Future<String> chooseSignInRedirect({
  required String customSchemeRedirect,
  required String appLinkRedirect,
  WebAuthOptions base = WebAuthOptions.defaults,
  AuthTabCheck check = androidAuthTabSupported,
  TargetPlatform? platform,
}) async {
  if (appLinkRedirect.isEmpty ||
      kIsWeb ||
      (platform ?? defaultTargetPlatform) != TargetPlatform.android) {
    return customSchemeRedirect;
  }
  final options = WebAuthOptions.forRedirect(appLinkRedirect, base: base);
  if (options.httpsHost == null) {
    // forRedirect passes any other scheme through unchanged.
    throw ArgumentError(
      'the App Link must be an https redirect',
      'appLinkRedirect',
    );
  }
  bool authTab;
  try {
    authTab = await check(options);
  } catch (_) {
    authTab = false;
  }
  return authTab ? appLinkRedirect : customSchemeRedirect;
}
