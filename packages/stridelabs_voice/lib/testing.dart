/// Fakes for testing an app's voice code against `stridelabs_voice`: the
/// relay's server side ([FakeRelayServer], [FakeRelayChannel]), the
/// microphone ([FakeMicCapture]), the reply speaker's ports
/// ([FakeReplyTts], [FakeTtsAuth], [FakeReplyPlayer], [FakeClipFiles]), the
/// whole transport ([FakeVoiceTransport]) and a parser for the `MVOICE`
/// debug lines ([MvoiceLine]).
///
/// Test code only. It imports no `flutter_test`, but nothing here belongs in
/// a release build. [FakeRelayChannel] ENFORCES the relay's rules (audio
/// pacing, frame size, the idle timeout): a breach lands in `violations`,
/// which a test requires to be empty. The WAV-file microphone is not here:
/// it is `package:stridelabs_voice/wav_mic.dart`, for an app's debug code.
library;

export 'src/testing/mvoice_line.dart' show MvoiceLine;
export 'src/testing/relay_fakes.dart'
    show
        FakeMicCapture,
        FakeRelayChannel,
        FakeRelayServer,
        RelayAttempt,
        isSilence;
export 'src/testing/speaker_fakes.dart'
    show
        FakeClipFiles,
        FakeReplyPlayer,
        FakeReplyTts,
        FakeTtsAuth,
        FakeTtsCall,
        kFakeMp3;
export 'src/testing/transport_fakes.dart' show FakeVoiceTransport;
