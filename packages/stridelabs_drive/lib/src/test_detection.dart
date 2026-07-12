// Web-safe detection of the `flutter test` environment.
//
// A bare `dart:io` `Platform.environment` lookup breaks web compilation, so the
// IO and web implementations are split behind a conditional import: web (and any
// non-`dart:io` platform) gets the `false` fallback; IO platforms get the real
// `FLUTTER_TEST` check.
export 'test_detection_web.dart' if (dart.library.io) 'test_detection_io.dart';
