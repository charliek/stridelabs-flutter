/// The fixed values of the StrideLabs voice protocol, revision 1
/// (`PROTOCOL.md` in the `stridelabs-voice` crate, the canonical text).
library;

/// The one text frame the client sends: no more audio is coming (§2.2).
const String kRelayEndFrame = '{"type":"end"}';

/// The sample rates every revision-1 server takes, the client's default
/// candidates in order (§3.2): what a client tries before any `ready` has
/// advertised the server's own, and after them when one has.
const List<int> kDefaultRelaySampleRates = [24000, 16000];

/// What an absent `lead_ms` means (§3.1): an older server's pacing lead.
const int kDefaultRelayLeadMs = 5000;

/// The lowest and highest sample rates a server may offer, in Hz (the
/// `stridelabs-voice` crate's `MIN_SAMPLE_RATE` and `MAX_SAMPLE_RATE`). An
/// advertised list with a rate outside them is not used.
const int kMinRelaySampleRate = 8000;
const int kMaxRelaySampleRate = 48000;

/// The largest `lead_ms` this client takes from a `ready`; a larger one is
/// not used (the default applies). Six times revision 1's 5 s minimum and
/// any provider's need — the client never buffers more than 3 s before
/// `ready` and paces in real time after it — while the byte arithmetic it
/// feeds stays small (2.9 MB at 48 kHz), so a hostile or broken value can
/// neither overflow nor unpace the stream.
const int kMaxRelayLeadMs = 30000;

/// The smallest lead the client keeps itself to, however small the server's
/// (§3.2).
const Duration kMinClientLead = Duration(milliseconds: 500);

/// The one revision-1 audio encoding (§9): 16-bit little-endian signed PCM,
/// mono. Any other in `ready` is a session this client cannot speak.
const String kPcmS16le = 'pcm_s16le';

/// The smallest text bound a server may advertise (§5.2): a client splits
/// its sentences to this until a TTS response says more.
const int kTtsMinTextChars = 600;

/// The TTS route's header with the server's text bound (§5.2).
const String kTtsMaxCharsHeader = 'x-voice-tts-max-chars';

/// The TTS request's idempotency header (§5.1).
const String kIdempotencyKeyHeader = 'Idempotency-Key';

/// The audio types this client accepts from the TTS route, each with its
/// clip file's extension (§8).
const Map<String, String> kAllowedAudioTypes = {'audio/mpeg': '.mp3'};

/// The SHA-256 of the protocol's golden fixture (§11), checked against this
/// package's byte copy, `test/fixtures/relay_events.json`.
const String kRelayEventsGoldenSha256 =
    '0437bc8114b0397e3b9734e03c9cb3d72f18ba928f22a160e19fb68f6226ed15';

/// The client's own pacing lead for a server that advertised [leadMs]
/// (§3.2): a second under it, never under [kMinClientLead]; four seconds
/// when the server advertised none ([kDefaultRelayLeadMs] less a second).
Duration clientLeadFor(int? leadMs) {
  final lead = Duration(milliseconds: (leadMs ?? kDefaultRelayLeadMs) - 1000);
  return lead < kMinClientLead ? kMinClientLead : lead;
}

/// The media type of [contentType] (its parameters dropped, lower-cased)
/// when it is one of [kAllowedAudioTypes]; null otherwise (§5.3).
String? allowedMediaType(String? contentType) {
  if (contentType == null) return null;
  final type = contentType.split(';').first.trim().toLowerCase();
  return kAllowedAudioTypes.containsKey(type) ? type : null;
}
