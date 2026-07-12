/// Debug-only agent-driving helpers for StrideLabs Flutter apps, built on
/// [Marionette](https://pub.dev/packages/marionette_flutter).
///
/// Public API:
/// - [initMarionetteDriver] — start the Marionette binding and forward
///   `debugPrint` output into its log collector (gate the call behind
///   `kDebugMode` so it tree-shakes out of release builds).
/// - [isFlutterTest] — web-safe detection of the `flutter test` environment, so
///   callers can skip installing the Marionette binding under the test runner.
/// - [logDriveState] / [logDriveResult] — emit the `MSTATE` / `MRESULT` lines an
///   agent greps out of Marionette's `get-logs` (a stable, greppable contract).
library;

export 'src/drive_state.dart';
export 'src/marionette_init.dart';
export 'src/test_detection.dart';
