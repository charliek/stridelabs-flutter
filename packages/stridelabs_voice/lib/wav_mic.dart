/// A `MicCapture` fed from a WAV file, for an app's DEBUG-ONLY code: a driven
/// app or an integration test talks to the voice relay with no microphone.
///
/// Gate it in the app, behind the const `kDebugMode` (a release build then
/// drops it): lumen's `LUMEN_MIC_WAV` dart-define is lumen's, not this
/// package's.
library;

export 'src/transport/wav_mic_capture.dart';
