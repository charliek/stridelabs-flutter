# stridelabs_voice

The client side of the StrideLabs voice protocol: the relay transport
(microphone to `GET /voice/stream`), its events, limits and close codes, the
reply speaker and its TTS client (`POST /voice/tts`), and the pinned `MVOICE`
debug-line vocabulary. Lifecycle policy (when to connect, when to tear down),
eligibility, persisted settings, the voice catalog's display list and the
limit copy stay in the app.

## The protocol

The package speaks [`PROTOCOL.md`](https://github.com/charliek/stridelabs-rust/blob/v0.11.0/crates/voice/PROTOCOL.md)
of the `stridelabs-voice` crate. It targets **revision 1**, whose golden
fixture (`test/fixtures/relay_events.json`, a byte copy of the crate's) has
the SHA-256 `0437bc8114b0397e3b9734e03c9cb3d72f18ba928f22a160e19fb68f6226ed15`
(`kRelayEventsGoldenSha256`; a package test pins it). A server that serves the
tagged crate speaks what this package reads; the events of the golden also
parse in the apps' installed clients (frozen copies under
`test/installed_clients/`).

## Using it

```yaml
dependencies:
  stridelabs_voice:
    git:
      url: https://github.com/charliek/stridelabs-flutter.git
      ref: vX.Y.Z # a release tag that has this package, or a reviewed commit
      path: packages/stridelabs_voice
```

```dart
import 'package:stridelabs_voice/stridelabs_voice.dart';
```

- **The transport.** `RelayVoiceTransport` implements the `VoiceTransport`
  port: it opens the relay socket (`connectRelay`, `dart:io`; a stub on web),
  streams the microphone (`MicCapture`, `RecordMicCapture` over
  `package:record`) paced to real time, and turns the relay's events into
  `VoiceTransportEvent`s, posted utterances (`TurnAssembler`) and a
  `VoiceEnd` when the server ends the session.
- **The speaker.** `ReplySpeaker` speaks an assistant reply sentence by
  sentence over `SpeakerPorts`: the app's event streams and seams, a
  `ReplyTts` (`RelayTtsClient` on the app's `Dio`, whose auth interceptor
  stays the app's; mark the TTS request so it is not replayed generically:
  `kNoAuthReplayExtra`), an optional `TtsAuth` (a refresh ahead of a request
  and one retry of a `401` under the same `Idempotency-Key`), a player
  (`JustAudioReplyPlayer`) and clip files (`defaultReplyClipFiles`, the file
  prefix the app's).
- **Debug lines.** Both write `MVOICE <event> …` lines to a
  `VoiceDebugSink` (`debugPrint` in debug builds). `kMvoiceEvents` is the
  pinned vocabulary: an event is never renamed or removed, and new
  information is only a new `key=value`.

## Testing

`package:stridelabs_voice/testing.dart` has the fakes the package's own tests
use, for an app's tests (no `flutter_test` import):

| Fake | Stands in for |
| --- | --- |
| `FakeRelayServer`, `FakeRelayChannel` | the relay: upgrades (a script of refusals, `acceptedRates`), `ready` with advertised facts, raw frames, closes; it enforces the relay's rules and records breaches in `violations` |
| `FakeMicCapture` | the microphone: permission, per-rate refusals, fed chunks |
| `FakeReplyTts`, `FakeTtsCall`, `FakeTtsAuth` | `POST /voice/tts`: every send answered by the test, and the app's token refresh |
| `FakeReplyPlayer`, `FakeClipFiles` | playback and the clip files |
| `FakeVoiceTransport` | the whole `VoiceTransport`, for the app's own tests |
| `MvoiceLine` | a parsed `MVOICE` line, for integration harnesses |

`package:stridelabs_voice/wav_mic.dart` has `WavMicCapture`, a `MicCapture`
that plays a 16-bit mono WAV file in real time (then silence), so a driven app
or an integration test talks to the relay without a microphone. It is for an
app's debug-only code: gate it behind `kDebugMode` and the app's own switch (a
dart-define, say) so a release build drops it.

## Platform notes (the app's)

The package declares no manifest entries; the app does.

- **Android:** `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS`.
- **macOS:** the `com.apple.security.device.audio-input` entitlement and an
  `NSMicrophoneUsageDescription`.
- **Linux:** `libmpv` through `just_audio_media_kit`, which the app registers
  (this package depends on `just_audio` only).
- **Web:** no microphone (the relay channel and clip files are stubs).
- **iOS:** untried.
