import 'package:flutter/foundation.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

/// Starts the Marionette driving binding and forwards `debugPrint` output into
/// it, so an agent driving the app over the Dart VM Service can read app logs
/// via Marionette's `get_logs`.
///
/// Debug-only: callers should gate the single call site behind `kDebugMode`, so
/// this function — and the `marionette_flutter` import — are tree-shaken out of
/// release builds. (`flutter build … --release` verifies this.)
///
/// No custom `isInteractiveWidget`/`extractText` hooks are configured: Marionette
/// already detects the Material widgets our components wrap (IconButton,
/// FilledButton, TextField, Text, …). Stable widget keys, not custom hooks, are
/// what make targeting reliable here.
bool _initialized = false;

void initMarionetteDriver() {
  // Idempotent: a second call within the same isolate (e.g. an accidental double
  // bootstrap) would otherwise stack another `debugPrint` wrapper feeding a dead
  // PrintLogCollector. MarionetteBinding.ensureInitialized() self-guards, but the
  // debugPrint override below does not, so we guard the whole routine here.
  if (_initialized) {
    return;
  }
  _initialized = true;

  final logCollector = PrintLogCollector();
  MarionetteBinding.ensureInitialized(
    MarionetteConfiguration(logCollector: logCollector),
  );

  final flutterDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) {
      logCollector.addLog(message);
    }
    flutterDebugPrint(message, wrapWidth: wrapWidth);
  };
}
