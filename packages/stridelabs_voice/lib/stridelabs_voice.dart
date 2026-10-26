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
/// - The turn assembly the transport runs: [TurnAssembler], [VoiceUtterance]
///   and the default end-word policy [isUnfinishedFragment].
/// - Debug lines: [VoiceDebugSink], [defaultVoiceDebugSink] and the pinned
///   `MVOICE` vocabulary [kMvoiceEvents].
library;

export 'src/assembly/turn_assembler.dart';
export 'src/debug/voice_debug.dart';
export 'src/protocol/close_codes.dart';
export 'src/protocol/constants.dart';
export 'src/protocol/relay_events.dart';
export 'src/protocol/voice_limit.dart';
export 'src/transport/mic_capture.dart';
export 'src/transport/relay_channel.dart';
export 'src/transport/relay_voice_transport.dart';
export 'src/transport/voice_transport.dart';

// Later units add the sentence assembler, the reply speaker and its TTS
// client, the player and clip files here; the fakes go in `testing.dart`.
