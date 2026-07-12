/// Web fallback for [isFlutterTest].
///
/// Web has no `dart:io`, so `Platform.environment` is unavailable. Web is also
/// not a Marionette driving target, so reporting `false` is correct: the driver
/// is never selected on web regardless of the test runner.
bool get isFlutterTest => false;
