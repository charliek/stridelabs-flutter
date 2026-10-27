import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;

import 'constants.dart';
import 'voice_limit.dart';

/// What `GET /voice/stream` sends the client (`PROTOCOL.md` §2.3), as the
/// `stridelabs-voice` crate serializes it. The wire shape is pinned by the
/// protocol's golden fixture, of which this package keeps a byte copy
/// (`test/fixtures/relay_events.json`, its SHA-256 checked).
///
/// | event | meaning |
/// |---|---|
/// | `{"type":"ready", …}` | the provider accepted the session: send audio; carries the advertised facts (§3.1) |
/// | `{"type":"speech_start"}` | the speaker started |
/// | `{"type":"partial","text":…}` | OPTIONAL: the turn so far (cumulative) |
/// | `{"type":"speech_end"}` | the speaker stopped (the turn may still be completing) |
/// | `{"type":"end_of_turn","text":…}` | the turn's final text |
/// | `{"type":"error","code":…}` | the relay is about to close, and why |
///
/// A `limit` error also carries the spent allowance's `scope` and its
/// `resets_at`, read as a [VoiceLimit]; an older server's bare `limit`, or
/// one whose scope this client does not know, is a limit of no known scope
/// ([RelayError.limit] null).
sealed class RelayEvent {
  const RelayEvent();

  /// The event a text frame carries, or null for anything else: malformed
  /// JSON, an unknown `type` or error code, a missing field. The relay may
  /// grow new events; a client skips them (§1).
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
      'ready' => RelayReady._fromJson(json),
      'speech_start' => const RelaySpeechStart(),
      'speech_end' => const RelaySpeechEnd(),
      'partial' when text is String => RelayPartial(text),
      'end_of_turn' when text is String => RelayEndOfTurn(text),
      'error' => switch (RelayErrorCode.fromWire(json['code'])) {
        RelayErrorCode.limit => RelayError(
          RelayErrorCode.limit,
          limit: VoiceLimit.fromJson(json),
        ),
        final code? => RelayError(code),
        null => null,
      },
      _ => null,
    };
  }

  /// The wire form, exactly as the relay serializes it.
  Map<String, Object?> toJson();
}

/// The provider accepted the session: audio may flow. Carries the server's
/// advertised facts (`PROTOCOL.md` §3.1); an older server sends none, and
/// each absent fact has its default ([kDefaultRelaySampleRates], [kPcmS16le],
/// [kDefaultRelayLeadMs]).
final class RelayReady extends RelayEvent {
  const RelayReady({this.rates, this.encoding, this.leadMs});

  /// What a `ready` frame carries; a field that is not usable is absent.
  factory RelayReady._fromJson(Map<String, Object?> json) => RelayReady(
    rates: _rates(json['rates']),
    encoding: switch (json['encoding']) {
      final String encoding => encoding,
      _ => null,
    },
    leadMs: switch (json['lead_ms']) {
      final int lead when lead > 0 && lead <= kMaxRelayLeadMs => lead,
      _ => null,
    },
  );

  /// The sample rates the server accepts, its default first; null unless a
  /// non-empty list of distinct integers, each within [kMinRelaySampleRate]
  /// and [kMaxRelaySampleRate].
  final List<int>? rates;

  /// The session's audio encoding; null unless a string.
  final String? encoding;

  /// How far ahead of real time the server lets audio run, in ms; null
  /// unless a positive integer of at most [kMaxRelayLeadMs]. (One under
  /// revision 1's 5000 is kept: the client then leads by at least
  /// [kMinClientLead], §3.2, rather than overrun the server.)
  final int? leadMs;

  static List<int>? _rates(Object? value) {
    if (value is! List || value.isEmpty) return null;
    final rates = <int>[];
    for (final rate in value) {
      if (rate is! int ||
          rate < kMinRelaySampleRate ||
          rate > kMaxRelaySampleRate ||
          rates.contains(rate)) {
        return null;
      }
      rates.add(rate);
    }
    return List.unmodifiable(rates);
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'ready',
    'rates': ?rates,
    'encoding': ?encoding,
    'lead_ms': ?leadMs,
  };

  @override
  bool operator ==(Object other) =>
      other is RelayReady &&
      listEquals(other.rates, rates) &&
      other.encoding == encoding &&
      other.leadMs == leadMs;

  @override
  int get hashCode => Object.hash(
    RelayReady,
    rates == null ? null : Object.hashAll(rates!),
    encoding,
    leadMs,
  );

  @override
  String toString() => 'RelayReady(${toJson()})';
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

/// The current turn's text so far — cumulative, so each replaces the last.
/// Optional: a provider may send none.
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

/// The turn is complete: its final text.
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

  /// A `limit` error's spent allowance; null for the other codes, and for a
  /// `limit` whose scope is missing or unknown.
  final VoiceLimit? limit;

  @override
  Map<String, Object?> toJson() => {
    'type': 'error',
    'code': code.wire,
    ...?limit?.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is RelayError && other.code == code && other.limit == limit;

  @override
  int get hashCode => Object.hash(RelayError, code, limit);
}

/// Which side failed (`PROTOCOL.md` §4.1).
enum RelayErrorCode {
  /// The speech-to-text provider failed (1011).
  provider,

  /// A budget is spent (4002): the user's day or month, or everyone's
  /// month ([RelayError.limit] says which).
  limit,

  /// The server failed (1011).
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
