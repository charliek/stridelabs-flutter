import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Thin wrapper around the system-browser OAuth flow so the login screen can be
/// widget-tested with a fake implementation injected via a provider.
abstract class WebAuth {
  Future<Uri> authenticate({
    required Uri url,
    required String callbackUrlScheme,
  });
}

/// Production implementation backed by `flutter_web_auth_2` — opens the OS
/// "secure browser" (`ASWebAuthenticationSession` on iOS/macOS, Chrome Custom
/// Tabs on Android) and returns the custom-scheme callback URI.
class FlutterWebAuth2Impl implements WebAuth {
  const FlutterWebAuth2Impl();

  @override
  Future<Uri> authenticate({
    required Uri url,
    required String callbackUrlScheme,
  }) async {
    final result = await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackUrlScheme,
    );
    return Uri.parse(result);
  }
}
