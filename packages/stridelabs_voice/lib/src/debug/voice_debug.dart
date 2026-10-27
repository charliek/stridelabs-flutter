import 'package:flutter/foundation.dart';

/// Where the package's `MVOICE` timing lines go. One line per call, without
/// a trailing newline. Lines carry event names, codes, sizes and times —
/// never transcript or reply text, never a token.
typedef VoiceDebugSink = void Function(String line);

/// The default [VoiceDebugSink]: [debugPrint] in debug builds, nothing
/// otherwise.
void defaultVoiceDebugSink(String line) {
  if (kDebugMode) debugPrint(line);
}

/// Every `MVOICE` event this package writes: a PUBLIC contract, since apps'
/// integration harnesses parse the lines (`MvoiceLine`). An event is never
/// renamed or removed, and new information is only ever a new `key=value`.
///
/// Line format: `MVOICE <event>[ <word>…][ <key>=<value>…] t=<epoch ms>`,
/// then ` +<ms>ms` (the transport: since mic-on) or ` turn+<ms>ms` (the
/// speaker: since the turn was first seen). No value contains a space.
///
/// | event | words / fields |
/// |---|---|
/// | `mic_on`, `mic_off` | — |
/// | `ready` | `rate=<hz> buffered_ms=<n> lead_ms=<n>` |
/// | `capture_refused` | `rate=<hz>` |
/// | `upgrade_refused` | `status=<code\|->` |
/// | `rate_retry` | `rate=<hz>` (the next rate, after a `422`) |
/// | `ready_refused` | `reason=encoding` |
/// | `ready_timeout` | — |
/// | `relay_error` | word `<provider\|limit\|internal>`; `scope=<wire>` on a scoped limit |
/// | `speech_start` | — / words `ignored (muted)` |
/// | `end_of_turn` | — |
/// | `utterance` | word `<posted\|queued\|dropped>`; `stt_ms=<n\|null>` |
/// | `end_sent` | — |
/// | `end_closed` | `code=<code\|->` |
/// | `socket_closed` | `code=<code\|->` |
/// | `session_end` | words `<VoiceEndReason>[ <VoiceEndNotice>]` |
/// | `stall_filled` | `frames=<n>` |
/// | `reply_playing`, `reply_stopped` | — |
/// | `speak_stop` | `reason=<bargeIn\|micTap\|pause\|leave\|audioMode\|teardown\|cancelled>` |
/// | `speak_skipped` | word `cooldown` |
/// | `speak_first_sentence`, `speak_turn_done` | — |
/// | `speak_tts_request` | `i=<n>` |
/// | `speak_tts_bytes` | `i=<n> bytes=<n> ms=<n>` |
/// | `speak_tts_retry` | `i=<n>` (transport), `i=<n> reason=auth` (`401`) |
/// | `speak_tts_auth` | `i=<n> reason=<ahead\|refresh\|unauthorized>` |
/// | `speak_tts_unsupported_type` | `i=<n> type=<media type\|->` |
/// | `speak_playback_start`, `speak_playback_silent`, `speak_playback_end` | `i=<n>` |
/// | `speak_playback_failed` | `reason=<playback\|start_timeout> i=<n>` |
const Set<String> kMvoiceEvents = {
  // The relay transport.
  'mic_on',
  'mic_off',
  'ready',
  'capture_refused',
  'upgrade_refused',
  'rate_retry',
  'ready_refused',
  'ready_timeout',
  'relay_error',
  'speech_start',
  'end_of_turn',
  'utterance',
  'end_sent',
  'end_closed',
  'socket_closed',
  'session_end',
  'stall_filled',
  'reply_playing',
  'reply_stopped',
  // The reply speaker.
  'speak_stop',
  'speak_skipped',
  'speak_first_sentence',
  'speak_turn_done',
  'speak_tts_request',
  'speak_tts_bytes',
  'speak_tts_retry',
  'speak_tts_auth',
  'speak_tts_unsupported_type',
  'speak_playback_start',
  'speak_playback_silent',
  'speak_playback_end',
  'speak_playback_failed',
};
