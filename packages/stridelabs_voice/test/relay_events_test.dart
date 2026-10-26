import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

/// The protocol's golden fixture (`PROTOCOL.md` §11): a byte copy of the
/// `stridelabs-voice` crate's `fixtures/relay_events.json`, by a path
/// relative to the package, the `flutter test` working directory. Neither
/// repository reads the other's files: its SHA-256 is the drift check.
const _goldenPath = 'test/fixtures/relay_events.json';

/// The relay's event vocabulary, pinned by the golden: every entry must
/// parse to its variant and serialize back to exactly that entry.
void main() {
  final file = File(_goldenPath);
  if (!file.existsSync()) {
    throw StateError(
      'the relay golden $_goldenPath is missing (run "flutter test" from '
      'packages/stridelabs_voice)',
    );
  }
  final bytes = file.readAsBytesSync();
  final golden = (jsonDecode(utf8.decode(bytes)) as List<dynamic>)
      .cast<Map<String, dynamic>>();

  test("the golden's SHA-256 is the protocol's", () {
    expect(bytes, hasLength(620));
    expect(sha256.convert(bytes).toString(), kRelayEventsGoldenSha256);
  });

  test('the golden is this package rendering its events, byte for byte', () {
    // The crate's canonical form: one compact object per line, two-space
    // indent, LF line ends, a final LF.
    final events = [for (final entry in golden) RelayEvent.fromJson(entry)!];
    final rendered =
        '[\n${events.map((e) => '  ${jsonEncode(e.toJson())}').join(',\n')}\n]\n';
    expect(rendered, utf8.decode(bytes));
  });

  test('the fixture parses, in order, to one of every variant and code', () {
    final parsed = [for (final entry in golden) RelayEvent.fromJson(entry)];
    expect(parsed, [
      const RelayReady(
        rates: [24000, 16000],
        encoding: kPcmS16le,
        leadMs: 5000,
      ),
      const RelaySpeechStart(),
      const RelayPartial("what's the weather"),
      const RelaySpeechEnd(),
      const RelayEndOfTurn("What's the weather in Chicago?"),
      const RelayError(RelayErrorCode.provider),
      RelayError(
        RelayErrorCode.limit,
        limit: VoiceLimit(VoiceLimitScope.userDay, DateTime.utc(2026, 10, 25)),
      ),
      RelayError(
        RelayErrorCode.limit,
        limit: VoiceLimit(VoiceLimitScope.userMonth, DateTime.utc(2026, 11, 1)),
      ),
      RelayError(
        RelayErrorCode.limit,
        limit: VoiceLimit(
          VoiceLimitScope.globalMonth,
          DateTime.utc(2026, 11, 1),
        ),
      ),
      const RelayError(RelayErrorCode.internal),
      // An older server's.
      const RelayReady(),
    ]);
    // Nothing in the vocabulary is missing from the fixture.
    expect(parsed.map((e) => e.runtimeType).toSet(), {
      RelayReady,
      RelaySpeechStart,
      RelayPartial,
      RelaySpeechEnd,
      RelayEndOfTurn,
      RelayError,
    });
    expect(
      parsed.whereType<RelayError>().map((e) => e.code).toSet(),
      RelayErrorCode.values.toSet(),
    );
    // And a limit of every scope.
    expect(
      parsed
          .whereType<RelayError>()
          .map((e) => e.limit?.scope)
          .whereType<VoiceLimitScope>()
          .toSet(),
      VoiceLimitScope.values.toSet(),
    );
  });

  test("a limit with no scope, or one this app doesn't know, is a bare limit", () {
    for (final frame in [
      // An older server.
      '{"type":"error","code":"limit"}',
      // A newer server's scope.
      '{"type":"error","code":"limit","scope":"team_week","resets_at":"2026-11-01T00:00:00Z"}',
      // A scope without a usable reset.
      '{"type":"error","code":"limit","scope":"user_day"}',
      '{"type":"error","code":"limit","scope":"user_day","resets_at":"later"}',
    ]) {
      expect(
        RelayEvent.parse(frame),
        const RelayError(RelayErrorCode.limit),
        reason: frame,
      );
    }
    // A scope on another code is not read: only a limit has one.
    expect(
      RelayEvent.parse(
        '{"type":"error","code":"provider","scope":"user_day","resets_at":"2026-11-01T00:00:00Z"}',
      ),
      const RelayError(RelayErrorCode.provider),
    );
  });

  test('every entry serializes back to exactly itself', () {
    for (final entry in golden) {
      final event = RelayEvent.fromJson(entry)!;
      expect(event.toJson(), entry, reason: '$entry');
      // And through the wire as a text frame.
      expect(RelayEvent.parse(jsonEncode(event.toJson())), event);
    }
  });

  test('anything outside the vocabulary is skipped, not fatal', () {
    for (final frame in [
      'not json',
      '[]',
      '"ready"',
      '{}',
      '{"type":"audio_progress"}',
      '{"type":"partial"}',
      '{"type":"partial","text":3}',
      '{"type":"end_of_turn"}',
      '{"type":"error"}',
      '{"type":"error","code":"quota"}',
    ]) {
      expect(RelayEvent.parse(frame), isNull, reason: frame);
    }
    // Extra fields are tolerated (the relay may add some).
    expect(
      RelayEvent.parse('{"type":"partial","text":"a","final":true}'),
      const RelayPartial('a'),
    );
  });

  test("a ready's unusable facts are absent, never a refusal", () {
    for (final (frame, ready) in [
      (
        '{"type":"ready","rates":[16000],"encoding":"opus","lead_ms":1500}',
        const RelayReady(rates: [16000], encoding: 'opus', leadMs: 1500),
      ),
      // Each fact alone: the others keep their defaults.
      ('{"type":"ready","lead_ms":8000}', const RelayReady(leadMs: 8000)),
      // Not a non-empty list of positive integers.
      ('{"type":"ready","rates":[]}', const RelayReady()),
      ('{"type":"ready","rates":[24000,"16000"]}', const RelayReady()),
      ('{"type":"ready","rates":[24000,0]}', const RelayReady()),
      ('{"type":"ready","rates":[24000.5]}', const RelayReady()),
      ('{"type":"ready","rates":24000}', const RelayReady()),
      // Not a string.
      ('{"type":"ready","encoding":7}', const RelayReady()),
      // Not a positive integer.
      ('{"type":"ready","lead_ms":0}', const RelayReady()),
      ('{"type":"ready","lead_ms":-5000}', const RelayReady()),
      ('{"type":"ready","lead_ms":"5000"}', const RelayReady()),
      ('{"type":"ready","lead_ms":null,"rates":null}', const RelayReady()),
      // Outside the protocol's bounds: 8 to 48 kHz, distinct; a lead of at
      // most 30 s (an overflowing one included).
      ('{"type":"ready","rates":[1]}', const RelayReady()),
      ('{"type":"ready","rates":[24000,7999]}', const RelayReady()),
      ('{"type":"ready","rates":[48001]}', const RelayReady()),
      ('{"type":"ready","rates":[24000,24000]}', const RelayReady()),
      ('{"type":"ready","lead_ms":30001}', const RelayReady()),
      ('{"type":"ready","lead_ms":9223372036854775}', const RelayReady()),
      // The bounds themselves are kept.
      (
        '{"type":"ready","rates":[8000,48000],"lead_ms":30000}',
        const RelayReady(rates: [8000, 48000], leadMs: 30000),
      ),
    ]) {
      expect(RelayEvent.parse(frame), ready, reason: frame);
    }
  });
}
