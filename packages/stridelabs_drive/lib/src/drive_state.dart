import 'package:flutter/foundation.dart';

/// Debug-only structured logs for agent driving, captured by Marionette's
/// `get-logs`. They expose state an agent can't read from the widget tree (the
/// CLI can't call custom VM-service extensions) and outcomes shown only in
/// transient SnackBars.
///
/// Both are no-ops in release builds (`kDebugMode` is a const `false`, so the
/// bodies — and these call sites — tree-shake out), matching the Marionette
/// binding. They intentionally write straight to `debugPrint` (not the app-log
/// channel, e.g. `stridelabs_logging`) so the `MSTATE`/`MRESULT` lines stay a
/// stable, greppable contract for the driving harness. Agents read them with
/// `marionette -i <app> get-logs | grep 'M…'`.

String? _lastState;

/// Emit `MSTATE <state>` only when [state] changes, so an agent can read live
/// app state and wait on transitions without screenshotting or re-listing the
/// element tree. Dedup keeps the (cumulative, capped) log buffer readable.
void logDriveState(String state) {
  if (!kDebugMode) return;
  if (state == _lastState) return;
  _lastState = state;
  debugPrint('MSTATE $state');
}

/// Emit `MRESULT <action> ok` / `MRESULT <action> error=…` so an agent can
/// confirm the outcome of an action whose only UI feedback is a transient
/// SnackBar.
void logDriveResult(String action, {required bool ok, Object? error}) {
  if (!kDebugMode) return;
  debugPrint('MRESULT $action ${ok ? 'ok' : 'error=$error'}');
}
