import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'installed_clients/lumen_v2026_10_23/relay_events.dart' as lumen;
import 'installed_clients/tapper_build_113/relay_events.dart' as tapper;
import 'installed_clients/tapper_build_113/voice_limit.dart' as tapper;

/// The clients already installed against a revision-1 server (D1 §6.13):
/// FROZEN, verbatim copies of lumen v2026.10.23's and tapper build 113's
/// event parsers (`test/installed_clients/`) read the protocol's golden. An
/// installed client cannot change, so a golden that one of them reads
/// otherwise than as its old type is a protocol break.
void main() {
  final golden =
      jsonDecode(File('test/fixtures/relay_events.json').readAsStringSync())
          as List<dynamic>;
  final entries = golden.cast<Map<String, dynamic>>();

  test('the frozen copies are the installed sources, byte for byte', () {
    for (final path in [
      'test/installed_clients/lumen_v2026_10_23/relay_events.dart',
      'test/installed_clients/tapper_build_113/relay_events.dart',
      'test/installed_clients/tapper_build_113/voice_limit.dart',
    ]) {
      final text = File(path).readAsStringSync();
      final recorded = RegExp(
        r'^// SHA-256: ([0-9a-f]{64})$',
        multiLine: true,
      ).firstMatch(text)!.group(1);
      const marker = '// ---- frozen below ----\n';
      final body = text.substring(text.indexOf(marker) + marker.length);
      expect(
        sha256.convert(utf8.encode(body)).toString(),
        recorded,
        reason: path,
      );
    }
  });

  test("the installed clients' parsers accept the golden", () {
    // lumen v2026.10.23: no scope on a limit, nothing read from a ready.
    expect(
      [for (final entry in entries) lumen.RelayEvent.fromJson(entry)],
      [
        const lumen.RelayReady(), // the advertising ready
        const lumen.RelaySpeechStart(),
        const lumen.RelayPartial("what's the weather"),
        const lumen.RelaySpeechEnd(),
        const lumen.RelayEndOfTurn("What's the weather in Chicago?"),
        const lumen.RelayError(lumen.RelayErrorCode.provider),
        const lumen.RelayError(lumen.RelayErrorCode.limit),
        const lumen.RelayError(lumen.RelayErrorCode.limit),
        const lumen.RelayError(lumen.RelayErrorCode.limit),
        const lumen.RelayError(lumen.RelayErrorCode.internal),
        const lumen.RelayReady(), // an older server's
      ],
    );

    // tapper build 113: the scoped limits read as its VoiceLimit.
    expect(
      [for (final entry in entries) tapper.RelayEvent.fromJson(entry)],
      [
        const tapper.RelayReady(),
        const tapper.RelaySpeechStart(),
        const tapper.RelayPartial("what's the weather"),
        const tapper.RelaySpeechEnd(),
        const tapper.RelayEndOfTurn("What's the weather in Chicago?"),
        const tapper.RelayError(tapper.RelayErrorCode.provider),
        tapper.RelayError(
          tapper.RelayErrorCode.limit,
          limit: tapper.VoiceLimit(
            tapper.VoiceLimitScope.userDay,
            DateTime.utc(2026, 10, 25),
          ),
        ),
        tapper.RelayError(
          tapper.RelayErrorCode.limit,
          limit: tapper.VoiceLimit(
            tapper.VoiceLimitScope.userMonth,
            DateTime.utc(2026, 11, 1),
          ),
        ),
        tapper.RelayError(
          tapper.RelayErrorCode.limit,
          limit: tapper.VoiceLimit(
            tapper.VoiceLimitScope.globalMonth,
            DateTime.utc(2026, 11, 1),
          ),
        ),
        const tapper.RelayError(tapper.RelayErrorCode.internal),
        const tapper.RelayReady(),
      ],
    );

    // And the scoped 429 body of both routes (`PROTOCOL.md` §7), which
    // build 113's speech client reads with VoiceLimit.fromBody.
    const body =
        '{"detail":"voice beta limit reached","scope":"user_day",'
        '"resets_at":"2026-10-25T00:00:00Z"}';
    final limit = tapper.VoiceLimit(
      tapper.VoiceLimitScope.userDay,
      DateTime.utc(2026, 10, 25),
    );
    expect(tapper.VoiceLimit.fromBody(utf8.encode(body)), limit);
    expect(tapper.VoiceLimit.fromBody(body), limit);
  });
}
