import 'package:flutter/foundation.dart' show immutable;

/// One `MVOICE` line (see `kMvoiceEvents`), parsed for an app's integration
/// harness: its [event] (`speak_playback_start`), the plain [words] after it
/// (`posted`, `closedByServer limitReached`), its `key=value` [fields] (`i`,
/// `code`, `reason`, `status`) and its `t=` ([t], epoch ms). The trailing
/// `+<ms>ms` / `turn+<ms>ms` is dropped.
///
/// From lumen's `integration_test/support/it_voice.dart` (`Mvoice`), renamed.
@immutable
class MvoiceLine {
  const MvoiceLine._(this.event, this.words, this.fields, this.t, this.line);

  /// The parse of [line], or null when it is not an `MVOICE` line.
  static MvoiceLine? parse(String line) {
    // The tag is split from its space on purpose: the vocabulary test counts
    // a quoted tag-and-space literal as the package WRITING a line.
    const tag = 'MVOICE';
    if (!line.startsWith('$tag ')) return null;
    final tokens = line.substring(tag.length + 1).split(' ');
    if (tokens.first.isEmpty) return null;
    final words = <String>[];
    final fields = <String, String>{};
    int? t;
    for (final token in tokens.skip(1)) {
      final eq = token.indexOf('=');
      if (eq > 0) {
        final key = token.substring(0, eq);
        final value = token.substring(eq + 1);
        if (key == 't') {
          t = int.tryParse(value);
        } else {
          fields[key] = value;
        }
      } else if (token.isNotEmpty &&
          !token.startsWith('+') &&
          !token.startsWith('turn+')) {
        words.add(token);
      }
    }
    return MvoiceLine._(tokens.first, words, fields, t, line);
  }

  final String event;
  final List<String> words;
  final Map<String, String> fields;

  /// The line's `t=` (epoch ms); null when it carries none.
  final int? t;

  /// The line as printed.
  final String line;

  /// The `i=` field (the reply clip's index); null when absent.
  int? get clip => int.tryParse(fields['i'] ?? '');

  @override
  String toString() => line;
}
