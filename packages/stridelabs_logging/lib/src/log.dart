import 'package:flutter/foundation.dart';

/// Signature for a crash-reporting / observability sink that [log] fans out to.
typedef LogSink = void Function(String area, String message);

/// Optional crash-reporting / observability sink — the seam for adding a
/// backend without touching any call site.
///
/// Null by default, so [log] is just a `debugPrint`. Wire this to a backend
/// (Sentry/Crashlytics, a breadcrumb recorder, …) when one is actually
/// available and every [log] call fans out to it in addition to `debugPrint`.
LogSink? logSink;

/// Emit an app log line under [area] (a short subsystem tag, e.g. `auth`, `api`)
/// as `[area] message` via `debugPrint` (rate-limited, and captured by the
/// Marionette log collector in debug). The one convention the app logs through.
///
/// This is deliberately *not* where the Marionette driving lines live — those
/// (`MSTATE`/`MRESULT`, see `stridelabs_drive`'s `drive_state.dart`) also write
/// straight to `debugPrint` but stay a stable, greppable contract of their own.
///
/// When [logSink] is set, the line is also fanned out to it — the seam a future
/// crash-reporting backend (Sentry/Crashlytics) hooks into; for now a single
/// `debugPrint` is all that runs by default.
void log(String area, String message) {
  debugPrint('[$area] $message');
  logSink?.call(area, message);
}
