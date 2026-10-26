import 'dart:typed_data';

import 'package:record/record.dart';

import 'relay_voice_transport.dart';

/// The microphone as [RelayVoiceTransport] uses it: a permission check
/// and a stream of 16-bit little-endian mono PCM. One instance per mic-on;
/// narrow on purpose, so tests drive the transport with a fake.
abstract interface class MicCapture {
  /// Asks for the microphone if it was never asked; false when refused.
  Future<bool> hasPermission();

  /// Starts capturing at [sampleRate] Hz. Throws when the device refuses
  /// that rate (the transport then tries the next one). May be called again
  /// after [stop], at another rate (the server refused the first).
  Future<Stream<Uint8List>> start(int sampleRate);

  /// Stops capturing; the stream ends once its last chunk is delivered.
  Future<void> stop();

  Future<void> dispose();
}

/// [MicCapture] over `package:record`'s [AudioRecorder].
class RecordMicCapture implements MicCapture {
  RecordMicCapture() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start(int sampleRate) =>
      _recorder.startStream(captureConfig(sampleRate));

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// The capture the relay transport pins: PCM16 mono with the
/// platform's echo cancellation, noise suppression and gain control, and on
/// Android the voice-communication source in communication mode, speaker on
/// (so the echo canceller has the reply to cancel).
///
/// `audioInterruption: none`: `record` otherwise takes audio focus and PAUSES
/// on losing it — and the app's own reply playback takes focus, which would
/// stall the stream mid-session (the relay closes a stream that stops
/// sending). Half-duplex silences the mic during replies instead.
RecordConfig captureConfig(int sampleRate) => RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: sampleRate,
  numChannels: 1,
  echoCancel: true,
  noiseSuppress: true,
  autoGain: true,
  audioInterruption: AudioInterruptionMode.none,
  androidConfig: const AndroidRecordConfig(
    audioSource: AndroidAudioSource.voiceCommunication,
    audioManagerMode: AudioManagerMode.modeInCommunication,
    speakerphone: true,
  ),
);
