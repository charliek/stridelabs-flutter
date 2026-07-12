import 'dart:io' show Platform;

/// True when running under `flutter test` / `integration_test`.
///
/// The Flutter test runner sets the `FLUTTER_TEST` environment variable, which
/// callers use to skip installing the Marionette binding during tests (the test
/// framework installs its own `WidgetsBinding`).
bool get isFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');
