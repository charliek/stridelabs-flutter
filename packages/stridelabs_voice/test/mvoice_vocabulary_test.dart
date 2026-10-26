import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

/// The `MVOICE` vocabulary is a public contract (D1 §8.5): apps'
/// integration harnesses parse its lines, so an event is never renamed or
/// removed. The set is pinned here, and every line the package writes names
/// a pinned event.
void main() {
  test('the MVOICE vocabulary is pinned', () {
    expect(kMvoiceEvents, {
      // The relay transport.
      'mic_on', 'mic_off', 'ready', 'capture_refused', 'upgrade_refused',
      'rate_retry', 'ready_refused', 'ready_timeout', 'relay_error',
      'speech_start', 'end_of_turn', 'utterance', 'end_sent', 'end_closed',
      'socket_closed', 'session_end', 'stall_filled', 'reply_playing',
      'reply_stopped',
      // The reply speaker.
      'speak_stop', 'speak_skipped', 'speak_first_sentence', 'speak_turn_done',
      'speak_tts_request', 'speak_tts_bytes', 'speak_tts_retry',
      'speak_tts_auth', 'speak_tts_unsupported_type', 'speak_playback_start',
      'speak_playback_silent', 'speak_playback_end', 'speak_playback_failed',
    });
  });

  test('every MVOICE line the package writes names a pinned event', () {
    // Each source writes its lines through one `_mvoice('<event>', …)`
    // helper, whose event is a literal.
    final call = RegExp(r"_mvoice\(\s*'([^']*)'");
    final events = <String, String>{};
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final match in call.allMatches(source)) {
        events[match.group(1)!] = file.path;
      }
      // No line is written past the helper.
      final direct = RegExp(r"'MVOICE \$event").allMatches(source).length;
      final written = RegExp("'MVOICE ").allMatches(source).length;
      expect(written, direct, reason: '${file.path} writes MVOICE directly');
    }
    // The transport's own events, at least: the scan is not vacuous.
    expect(
      events.keys,
      containsAll(['mic_on', 'ready', 'rate_retry', 'ready_refused']),
    );
    for (final MapEntry(key: event, value: path) in events.entries) {
      expect(kMvoiceEvents, contains(event), reason: '$path: $event');
    }
  });
}
