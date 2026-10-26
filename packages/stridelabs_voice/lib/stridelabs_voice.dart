/// The client side of the StrideLabs voice protocol (`PROTOCOL.md` in the
/// `stridelabs-voice` crate, revision 1).
///
/// Public API:
/// - The protocol: [RelayEvent] and its variants ([RelayReady] with the
///   advertised facts, [RelaySpeechStart], [RelayPartial], [RelaySpeechEnd],
///   [RelayEndOfTurn], [RelayError] with [RelayErrorCode]); [VoiceLimit] and
///   [VoiceLimitScope]; the server's [RelayCloseCode] and the client's
///   [RelayClientCloseCode]; the protocol's constants ([kRelayEndFrame],
///   [kDefaultRelaySampleRates], [kDefaultRelayLeadMs], [kPcmS16le],
///   [kTtsMinTextChars], …) with [clientLeadFor] and [allowedMediaType].
/// - The transport: the [VoiceTransport] port and its events
///   ([VoiceTransportEvent], [VoiceEnd], [MicEnableResult],
///   [VoiceDisconnectCause]); [RelayVoiceTransport] over the relay;
///   [RelayChannel] / [RelayConnector] / [connectRelay] (`dart:io`; a stub
///   on web) and [relayStreamUri]; the [MicCapture] port and
///   [RecordMicCapture] with its [captureConfig].
/// - The turn assembly the transport runs: [TurnAssembler] (its merge
///   window and end-word policy injectable), [VoiceUtterance] and the
///   default policy [isUnfinishedFragment]; the reply's [SentenceAssembler],
///   split to its [SentenceAssembler.maxSpokenChunk].
/// - The reply speaker: [ReplySpeaker] over its [SpeakerPorts] (the app's
///   [SpeakerTurnEvent]s, [SpeechModeChange]s and seams), with its
///   [SpeakerStopReason]s, its `playing` flag and its limit notices; and
///   [splitSpokenChunk], the splitter a sentence over the text bound is cut
///   with.
/// - Its TTS client: the [ReplyTts] port ([ReplyTtsRequest], [ReplyClip],
///   [UnsupportedAudioType]) and [RelayTtsClient] on an app's Dio (with
///   [kNoAuthReplayExtra]); the optional [TtsAuth] port; and the transport
///   rule, [ResponseHeadersWatch] with [responseHead], [clearResponseHead]
///   and [isTransportFailure].
/// - Playback: the [ReplyAudioPlayer] port and [JustAudioReplyPlayer] with
///   its [ReplyClipEvent]s and [replyAudioSessionConfiguration]; the
///   [ReplyClipFiles] store ([defaultReplyClipFiles], its file prefix the
///   app's, its extension from the clip's media type).
/// - Debug lines: [VoiceDebugSink], [defaultVoiceDebugSink] and the pinned
///   `MVOICE` vocabulary [kMvoiceEvents].
///
/// Two more entry points: `package:stridelabs_voice/testing.dart` (the
/// fakes, for tests) and `package:stridelabs_voice/wav_mic.dart` (a WAV file
/// as the microphone, for an app's debug code).
library;

export 'src/assembly/sentence_assembler.dart';
export 'src/assembly/turn_assembler.dart';
export 'src/debug/voice_debug.dart';
export 'src/http/transport_failure.dart';
export 'src/playback/reply_audio_player.dart';
export 'src/playback/reply_clip_files.dart';
export 'src/protocol/close_codes.dart';
export 'src/protocol/constants.dart';
export 'src/protocol/relay_events.dart';
export 'src/protocol/voice_limit.dart';
export 'src/speaker/relay_tts_client.dart';
export 'src/speaker/reply_speaker.dart';
export 'src/speaker/reply_tts.dart';
export 'src/speaker/speaker_ports.dart';
export 'src/speaker/tts_auth.dart';
export 'src/transport/mic_capture.dart';
export 'src/transport/relay_channel.dart';
export 'src/transport/relay_voice_transport.dart';
export 'src/transport/voice_transport.dart';
