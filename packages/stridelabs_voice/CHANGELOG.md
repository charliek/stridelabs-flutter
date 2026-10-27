# Changelog

## 0.1.0 - 2026-10-27

The first entry: the voice client lumen and tapper each kept a copy of, as one
package (lumen plan 003, W1.7). Not published to pub.dev.

Targets `PROTOCOL.md` revision 1 of the `stridelabs-voice` crate
(<https://github.com/charliek/stridelabs-rust/blob/v0.11.0/crates/voice/PROTOCOL.md>;
golden fixture SHA-256
`0437bc8114b0397e3b9734e03c9cb3d72f18ba928f22a160e19fb68f6226ed15`).

### Changed
- `TtsAuth.refreshAfterUnauthorized(extras)`: the contract drops the clause
  that let it answer true when "the held token is already newer than the one
  the sentence carried". The extras are frozen at `request()`, before the
  refresh ahead, and the app's interceptor attaches the token later, so they
  cannot say which token an attempt carried (tapper's review). It now
  refreshes the session the extras identify and answers true only if a
  refresh succeeded (a concurrent refresh the implementation joined counts).
  `SpeakerPorts.ttsAuth`'s doc: with null the speaker never refreshes.

### Added
- The protocol: `RelayEvent` and its variants, `VoiceLimit`, the close codes,
  the constants and `clientLeadFor` / `allowedMediaType`.
- `RelayVoiceTransport` over the `VoiceTransport` port, `RelayChannel` /
  `connectRelay`, the `MicCapture` port with `RecordMicCapture`, and the
  `TurnAssembler` / `SentenceAssembler`.
- `ReplySpeaker` over `SpeakerPorts`, `RelayTtsClient` on the app's `Dio`
  (with the optional `TtsAuth`: a refresh ahead of a request and one retry of
  a `401` under the same `Idempotency-Key`), `JustAudioReplyPlayer` and the
  clip files.
- The pinned `MVOICE` vocabulary (`kMvoiceEvents`) and `VoiceDebugSink`.
- `package:stridelabs_voice/testing.dart`: `FakeRelayServer`,
  `FakeRelayChannel`, `FakeMicCapture`, `FakeReplyTts`, `FakeTtsCall`,
  `FakeTtsAuth`, `FakeReplyPlayer`, `FakeClipFiles`, `FakeVoiceTransport`,
  `MvoiceLine`, `isSilence`, `kFakeMp3`.
- `package:stridelabs_voice/wav_mic.dart`: `WavMicCapture`, `WavPcm`,
  `WavMicProblem`, `WavMicException` (lumen's debug WAV microphone; its
  dart-define gate stays in lumen).
