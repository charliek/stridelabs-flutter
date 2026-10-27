import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

/// The spent voice allowance a server names on a `POST /voice/tts` 429 and
/// the relay's `limit` event (`PROTOCOL.md` §7): read only when it carries
/// both a known `scope` and a valid `resets_at`; otherwise no limit at all,
/// so the app says what it always said. (What the user is told is each
/// app's copy: tapper keeps its `message` cases.)
void main() {
  final november = DateTime.utc(2026, 11, 1);

  test('each scope reads and writes back exactly', () {
    for (final (wire, scope) in [
      ('user_day', VoiceLimitScope.userDay),
      ('user_month', VoiceLimitScope.userMonth),
      ('global_month', VoiceLimitScope.globalMonth),
    ]) {
      final json = {'scope': wire, 'resets_at': '2026-11-15T12:00:00Z'};
      final limit = VoiceLimit.fromJson(json);
      expect(limit, VoiceLimit(scope, DateTime.utc(2026, 11, 15, 12)));
      expect(limit!.toJson(), json, reason: wire);
      expect(scope.wire, wire);
      expect(VoiceLimitScope.fromWire(wire), scope);
    }
  });

  test('a 429 body reads as bytes, text or a decoded map', () {
    const body =
        '{"detail":"voice beta limit reached","scope":"user_month","resets_at":"2026-11-01T00:00:00Z"}';
    final expected = VoiceLimit(VoiceLimitScope.userMonth, november);
    expect(VoiceLimit.fromBody(utf8.encode(body)), expected);
    expect(VoiceLimit.fromBody(body), expected);
    expect(VoiceLimit.fromBody(jsonDecode(body)), expected);
  });

  test('no scope, an unknown scope or no valid reset is no limit', () {
    for (final body in <Object?>[
      // An older server: `detail` alone.
      '{"detail":"voice beta limit reached"}',
      // A scope this app does not know.
      '{"detail":"x","scope":"team_week","resets_at":"2026-11-01T00:00:00Z"}',
      '{"detail":"x","scope":7,"resets_at":"2026-11-01T00:00:00Z"}',
      // A scope with no (or no usable) reset.
      '{"detail":"x","scope":"user_day"}',
      '{"detail":"x","scope":"user_day","resets_at":"soon"}',
      '{"detail":"x","scope":"user_day","resets_at":1730419200}',
      // No offset: not RFC 3339, and it would read as local time.
      '{"detail":"x","scope":"user_day","resets_at":"2026-11-01T00:00:00"}',
      // Not a JSON object at all.
      'not json',
      '[]',
      utf8.encode('{"scope":'),
      null,
      42,
    ]) {
      expect(VoiceLimit.fromBody(body), isNull, reason: '$body');
    }
  });

  test('a reset with an offset or a fraction is kept as its UTC instant', () {
    final limit = VoiceLimit.fromJson({
      'scope': 'user_day',
      'resets_at': '2026-10-31T19:00:00-05:00',
    });
    expect(limit!.resetsAt, november);
    expect(limit.resetsAt.isUtc, isTrue);
    expect(limit.toJson()['resets_at'], '2026-11-01T00:00:00Z');
    expect(
      VoiceLimit.rfc3339(DateTime.utc(2026, 11, 1, 0, 0, 0, 250)),
      '2026-11-01T00:00:00.250Z',
    );
  });
}
