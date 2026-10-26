// FROZEN: a verbatim copy of an installed client's parser, the test of
// `installed_clients_test.dart`. Never edit it: every byte after the
// marker line is the source file's, checked against this SHA-256.
// Source: tapper build 113 (commit ca691a2b83ee4c9b370c0c951287958bd63d2a54, release v2026.10.25)
//   apps/flutter_client/lib/voice/relay_events.dart
// SHA-256: 56de95dd8aab93a1002455dfd559813ee7fe2eec0923f6ddffab6247dc319aa1
// Formatted as it was (the short style of its language version):
// @dart=3.6
// ignore_for_file: type=lint
// ---- frozen below ----
import 'dart:convert';

import 'voice_limit.dart';

/// What `GET /voice/stream` sends the phone: Muse's events, normalized by
/// tapper-rs (`tapper-rs/src/voice/events.rs`, `RelayEvent`). The wire shape
/// is pinned by ONE golden file both test suites read,
/// `test/fixtures/voice_relay_events.json`.
///
/// | event | meaning |
/// |---|---|
/// | `{"type":"ready"}` | Muse accepted the session: send audio |
/// | `{"type":"speech_start"}` | the speaker started |
/// | `{"type":"partial","text":…}` | the utterance so far (cumulative) |
/// | `{"type":"speech_end"}` | the speaker stopped (the turn may still be completing) |
/// | `{"type":"end_of_turn","text":…}` | the utterance's final text |
/// | `{"type":"error","code":…}` | the relay is about to close, and why |
///
/// A `limit` error also carries the spent allowance's `scope` and its
/// `resets_at` (plan 016 B-4), read as a [VoiceLimit]; an older server's
/// bare `limit`, or one whose scope this app does not know, is a limit of
/// no known scope ([RelayError.limit] null).
sealed class RelayEvent {
  const RelayEvent();

  /// The event a text frame carries, or null for anything else: malformed
  /// JSON, an unknown `type` or error code, a missing field. The relay may
  /// grow new events; an old client skips them.
  static RelayEvent? parse(String frame) {
    final Object? json;
    try {
      json = jsonDecode(frame);
    } on FormatException {
      return null;
    }
    return json is Map<String, Object?> ? fromJson(json) : null;
  }

  /// See [parse].
  static RelayEvent? fromJson(Map<String, Object?> json) {
    final text = json['text'];
    return switch (json['type']) {
      'ready' => const RelayReady(),
      'speech_start' => const RelaySpeechStart(),
      'speech_end' => const RelaySpeechEnd(),
      'partial' when text is String => RelayPartial(text),
      'end_of_turn' when text is String => RelayEndOfTurn(text),
      'error' => switch (RelayErrorCode.fromWire(json['code'])) {
          RelayErrorCode.limit =>
            RelayError(RelayErrorCode.limit, limit: VoiceLimit.fromJson(json)),
          final code? => RelayError(code),
          null => null,
        },
      _ => null,
    };
  }

  /// The wire form, exactly as the relay serializes it.
  Map<String, Object?> toJson();
}

/// Muse acknowledged the session: audio may flow.
final class RelayReady extends RelayEvent {
  const RelayReady();

  @override
  Map<String, Object?> toJson() => {'type': 'ready'};

  @override
  bool operator ==(Object other) => other is RelayReady;

  @override
  int get hashCode => (RelayReady).hashCode;
}

/// The speaker started.
final class RelaySpeechStart extends RelayEvent {
  const RelaySpeechStart();

  @override
  Map<String, Object?> toJson() => {'type': 'speech_start'};

  @override
  bool operator ==(Object other) => other is RelaySpeechStart;

  @override
  int get hashCode => (RelaySpeechStart).hashCode;
}

/// The speaker stopped; the turn may still be completing.
final class RelaySpeechEnd extends RelayEvent {
  const RelaySpeechEnd();

  @override
  Map<String, Object?> toJson() => {'type': 'speech_end'};

  @override
  bool operator ==(Object other) => other is RelaySpeechEnd;

  @override
  int get hashCode => (RelaySpeechEnd).hashCode;
}

/// The current utterance's text so far — cumulative, so each replaces the
/// last.
final class RelayPartial extends RelayEvent {
  const RelayPartial(this.text);

  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'partial', 'text': text};

  @override
  bool operator ==(Object other) => other is RelayPartial && other.text == text;

  @override
  int get hashCode => Object.hash(RelayPartial, text);
}

/// The utterance is complete: its final text.
final class RelayEndOfTurn extends RelayEvent {
  const RelayEndOfTurn(this.text);

  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'end_of_turn', 'text': text};

  @override
  bool operator ==(Object other) =>
      other is RelayEndOfTurn && other.text == text;

  @override
  int get hashCode => Object.hash(RelayEndOfTurn, text);
}

/// The relay is about to close the socket; the close code says the rest.
final class RelayError extends RelayEvent {
  const RelayError(this.code, {this.limit});

  final RelayErrorCode code;

  /// A `limit` error's spent allowance (plan 016 B-4); null for the other
  /// codes, and for a `limit` whose scope is missing or unknown.
  final VoiceLimit? limit;

  @override
  Map<String, Object?> toJson() =>
      {'type': 'error', 'code': code.wire, ...?limit?.toJson()};

  @override
  bool operator ==(Object other) =>
      other is RelayError && other.code == code && other.limit == limit;

  @override
  int get hashCode => Object.hash(RelayError, code, limit);
}

/// Which side failed (the relay's `ErrorCode`).
enum RelayErrorCode {
  /// Muse failed: it errored, closed unexpectedly, or never acked (1011).
  provider,

  /// A budget is spent (4002): the user's day or month, or everyone's
  /// month ([RelayError.limit] says which).
  limit,

  /// tapper-rs failed (1011).
  internal;

  /// Pinned explicitly so renaming a case can't silently change the wire.
  String get wire => switch (this) {
        RelayErrorCode.provider => 'provider',
        RelayErrorCode.limit => 'limit',
        RelayErrorCode.internal => 'internal',
      };

  static RelayErrorCode? fromWire(Object? value) => switch (value) {
        'provider' => RelayErrorCode.provider,
        'limit' => RelayErrorCode.limit,
        'internal' => RelayErrorCode.internal,
        _ => null,
      };
}
