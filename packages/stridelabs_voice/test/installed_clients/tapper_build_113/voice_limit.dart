// FROZEN: a verbatim copy of an installed client's parser, the test of
// `installed_clients_test.dart`. Never edit it: every byte after the
// marker line is the source file's, checked against this SHA-256.
// Source: tapper build 113 (commit ca691a2b83ee4c9b370c0c951287958bd63d2a54, release v2026.10.25)
//   apps/flutter_client/lib/voice/voice_limit.dart
// SHA-256: ccc5a97f2460d36e71ea662a9316f4715f40f97b59b48bf4cb9620cdfe80e84c
// Formatted as it was (the short style of its language version):
// @dart=3.6
// ignore_for_file: type=lint
// ---- frozen below ----
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:intl/intl.dart';

/// Which voice allowance is spent: tapper-rs's `scope` (plan 016 B-4), on a
/// `POST /voice/tts` 429 body and on the relay's `limit` event.
enum VoiceLimitScope {
  /// The user's allowance for the UTC day.
  userDay,

  /// The user's allowance for the UTC calendar month.
  userMonth,

  /// Everyone's allowance for the UTC calendar month: voice is off for every
  /// user until it resets.
  globalMonth;

  /// Pinned explicitly so renaming a case can't silently change the wire.
  String get wire => switch (this) {
        VoiceLimitScope.userDay => 'user_day',
        VoiceLimitScope.userMonth => 'user_month',
        VoiceLimitScope.globalMonth => 'global_month',
      };

  /// The scope [value] names, or null for anything else (a newer server's
  /// scope this app does not know is no scope at all).
  static VoiceLimitScope? fromWire(Object? value) => switch (value) {
        'user_day' => VoiceLimitScope.userDay,
        'user_month' => VoiceLimitScope.userMonth,
        'global_month' => VoiceLimitScope.globalMonth,
        _ => null,
      };
}

/// A spent voice allowance, as tapper-rs reports it (plan 016 B-4): its
/// [scope] and when it comes back ([resetsAt], UTC).
///
/// Built only from a body or event that carries BOTH a known `scope` and a
/// valid RFC 3339 `resets_at`. Anything less — an older server that sends
/// neither, a scope this app does not know, a malformed time — is no
/// [VoiceLimit], and the caller says what it always said.
@immutable
class VoiceLimit {
  const VoiceLimit(this.scope, this.resetsAt);

  final VoiceLimitScope scope;

  /// When [scope]'s allowance resets (UTC).
  final DateTime resetsAt;

  /// The limit [json] names (its `scope` and `resets_at`), or null.
  static VoiceLimit? fromJson(Map<String, Object?> json) {
    final scope = VoiceLimitScope.fromWire(json['scope']);
    final resetsAt = json['resets_at'];
    if (scope == null || resetsAt is! String) return null;
    // RFC 3339 carries an offset (`Z` or `±hh:mm`), which Dart reads as a
    // UTC instant; a time without one would be read as LOCAL, so it is no
    // reset at all.
    final parsed = DateTime.tryParse(resetsAt);
    if (parsed == null || !parsed.isUtc) return null;
    return VoiceLimit(scope, parsed);
  }

  /// The limit an error response's [body] names: a JSON object as bytes (the
  /// speech request asks for bytes), as text, or already decoded. Null for
  /// anything else, a body that is not JSON included.
  static VoiceLimit? fromBody(Object? body) {
    Object? json = body;
    try {
      if (json is List<int>) json = utf8.decode(json);
      if (json is String) json = jsonDecode(json);
    } on FormatException {
      return null;
    }
    return json is Map<String, Object?> ? fromJson(json) : null;
  }

  /// The wire form: `scope`, and `resets_at` as tapper-rs writes it (RFC
  /// 3339, UTC, `Z`, whole seconds when it has no fraction).
  Map<String, Object?> toJson() =>
      {'scope': scope.wire, 'resets_at': rfc3339(resetsAt)};

  /// What the user is told.
  String get message => switch (scope) {
        VoiceLimitScope.userDay => "You've reached today's voice limit",
        VoiceLimitScope.userMonth => "You've reached this month's voice limit",
        VoiceLimitScope.globalMonth =>
          'Voice is unavailable until ${DateFormat.MMMMd().format(resetsAt.toLocal())}',
      };

  /// [instant] as RFC 3339 in UTC: `2026-11-01T00:00:00Z`, with a fraction
  /// only when it has one.
  static String rfc3339(DateTime instant) {
    final utc = instant.toUtc();
    final iso = utc.toIso8601String();
    return utc.millisecond == 0 && utc.microsecond == 0
        ? '${iso.substring(0, 19)}Z'
        : iso;
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceLimit && other.scope == scope && other.resetsAt == resetsAt;

  @override
  int get hashCode => Object.hash(scope, resetsAt);

  @override
  String toString() => 'VoiceLimit(${scope.wire}, ${rfc3339(resetsAt)})';
}
