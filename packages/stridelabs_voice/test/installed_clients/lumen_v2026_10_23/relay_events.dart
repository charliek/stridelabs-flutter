// FROZEN: a verbatim copy of an installed client's parser, the test of
// `installed_clients_test.dart`. Never edit it: every byte after the
// marker line is the source file's, checked against this SHA-256.
// Source: lumen v2026.10.23 (commit 37494715848f7e6d09f2dc500e4309baced7d0ce)
//   apps/flutter_client/lib/voice/relay_events.dart
// SHA-256: 234a7d680b8bf86b18191d05d5e1381bf22eb004187807864f065ebd0c49929f
// ignore_for_file: type=lint
// ---- frozen below ----
import 'dart:convert';

/// What `GET /voice/stream` sends the phone: Muse's events, normalized by
/// lumen-rs (`lumen-rs/src/voice/events.rs`, `RelayEvent`). The wire shape
/// is pinned by ONE golden file that lumen-rs's tests and this app's tests
/// both read, `lumen-rs/tests/fixtures/voice_relay_events.json`.
///
/// | event | meaning |
/// |---|---|
/// | `{"type":"ready"}` | Muse accepted the session: send audio |
/// | `{"type":"speech_start"}` | the speaker started |
/// | `{"type":"partial","text":…}` | the utterance so far (cumulative) |
/// | `{"type":"speech_end"}` | the speaker stopped (the turn may still be completing) |
/// | `{"type":"end_of_turn","text":…}` | the utterance's final text |
/// | `{"type":"error","code":…}` | the relay is about to close, and why |
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
  const RelayError(this.code);

  final RelayErrorCode code;

  @override
  Map<String, Object?> toJson() => {'type': 'error', 'code': code.wire};

  @override
  bool operator ==(Object other) => other is RelayError && other.code == code;

  @override
  int get hashCode => Object.hash(RelayError, code);
}

/// Which side failed (the relay's `ErrorCode`).
enum RelayErrorCode {
  /// Muse failed: it errored, closed unexpectedly, or never acked (1011).
  provider,

  /// A budget is spent (4002).
  limit,

  /// lumen-rs failed (1011).
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
