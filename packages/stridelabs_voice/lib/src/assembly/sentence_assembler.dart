import '../protocol/constants.dart';

/// Abbreviations whose period does not end a sentence (lowercase). Missing
/// a real sentence end only joins two sentences into one TTS chunk; a false
/// split puts a pause mid-sentence, so the list errs towards not splitting
/// ("a.m."/"p.m." because opening hours are a staple reply).
const Set<String> kNonTerminalAbbreviations = {
  'mr.',
  'mrs.',
  'ms.',
  'dr.',
  'st.',
  'jr.',
  'sr.',
  'e.g.',
  'i.e.',
  'vs.',
  'etc.',
  'a.m.',
  'p.m.',
};

/// Splits an assistant reply into sentences to speak, each exactly once, as
/// it streams (the reply speaker's input).
///
/// `assistant_partial` text is CUMULATIVE within one model response and
/// restarts with each response after a tool round. The assembler keeps a
/// cursor into the current response: everything before it (the spoken
/// prefix) has been spoken or skipped. A partial that starts with the spoken
/// prefix is the same response, possibly revised past it: only its unspoken
/// suffix is replaced, nothing is repeated. One that does not is a new
/// response (a tool round ran): the previous response's unspoken tail is
/// spoken only if it is a complete sentence, and the cursor restarts. A
/// sentence is emitted once its boundary is certain (terminal punctuation
/// followed by whitespace, or a line break). `assistant_final` speaks the
/// unspoken remainder; a final that does not continue the spoken prefix
/// makes the unspoken tail obsolete, and only what of the final was not
/// already said this turn is spoken.
///
/// Text is cleaned for speech: markdown emphasis, headers and list markers
/// are stripped, fenced code blocks are skipped and URLs (bare domains like
/// `brewery.co/menu` too) read as "link".
/// Periods in decimals ("3.5"), common abbreviations ("Dr.", "e.g.") and list
/// numbers ("1.") do not end a sentence. A chunk longer than
/// [maxSpokenChunk] is split at a clause boundary (`,;:`) or a space.
///
/// Pure Dart; the caller owns one per spoken turn (or calls [reset]).
class SentenceAssembler {
  /// [maxSpokenChunk] starts at the protocol's minimum text bound
  /// ([kTtsMinTextChars], 600): every server takes that much, whatever it
  /// advertises.
  SentenceAssembler({int maxSpokenChunk = kTtsMinTextChars})
    : _maxSpokenChunk = _checkBound(maxSpokenChunk);

  int _maxSpokenChunk;

  /// The longest chunk handed to TTS, in UTF-16 code units (which never
  /// undercount the server's character count). The speaker raises it to the
  /// bound the TTS route advertises (`X-Voice-Tts-Max-Chars`) and drops it
  /// back to [kTtsMinTextChars]; it applies to the text assembled from then
  /// on. Must be positive.
  int get maxSpokenChunk => _maxSpokenChunk;
  set maxSpokenChunk(int value) => _maxSpokenChunk = _checkBound(value);

  static int _checkBound(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'maxSpokenChunk', 'must be positive');
    }
    return value;
  }

  /// The current model response's cumulative text, as last seen.
  String _response = '';

  /// Index into [_response]: everything before it is spoken or skipped.
  int _cursor = 0;

  /// The cursor is inside a fenced code block.
  bool _inFence = false;

  /// Every chunk emitted this turn, in order.
  final List<String> _spokenThisTurn = [];

  /// What has been spoken (or skipped) of the current model response.
  String get spokenPrefix => _response.substring(0, _cursor);

  /// Sentences completed by this partial (cumulative text of the current
  /// model response).
  List<String> assistantPartial(String cumulativeText) {
    final out = <String>[];
    if (!cumulativeText.startsWith(spokenPrefix)) {
      // A new model response (a tool round ran): the previous one is over.
      out.addAll(_endResponse());
    }
    // The same response, or its revision: the unspoken suffix is replaced.
    _response = cumulativeText;
    out.addAll(_drain(cumulativeText, atEnd: false));
    return _said(out);
  }

  /// The reply's final text: only what has not been said is emitted.
  List<String> assistantFinal(String text) {
    final offset = _remainderOffset(text);
    if (offset != null) {
      // Re-anchor the cursor in the final text (it may differ from the last
      // partial only in leading whitespace or in what follows the cursor).
      _response = text;
      _cursor = offset;
      return _said(_drain(text, atEnd: true));
    }
    // Not the response the partials were building: their unspoken tail is
    // obsolete. Speak the final, less what was already said this turn.
    final alreadySaid = List.of(_spokenThisTurn);
    _restartResponse();
    _response = text;
    final out = [
      for (final chunk in _drain(text, atEnd: true))
        if (!alreadySaid.remove(chunk)) chunk,
    ];
    return _said(out);
  }

  /// A tool round ran (the reply speaker calls this at the turn's
  /// `tool_card`): the current model response is over. A partial alone
  /// cannot always show it — with nothing of the response spoken yet, the
  /// next response's first partial looks like a revision — so the boundary
  /// is explicit. The unspoken tail is spoken if it is a complete sentence
  /// (otherwise dropped), and the next partial starts a new response.
  List<String> responseBoundary() => _said(_endResponse());

  /// Forget everything (a new turn).
  void reset() {
    _restartResponse();
    _spokenThisTurn.clear();
  }

  void _restartResponse() {
    _response = '';
    _cursor = 0;
    _inFence = false;
  }

  List<String> _said(List<String> chunks) {
    _spokenThisTurn.addAll(chunks);
    return chunks;
  }

  /// The current model response is over (a tool round ran): its unspoken
  /// tail is spoken only if it is a complete sentence, otherwise dropped;
  /// then a fresh cursor for the next response.
  List<String> _endResponse() {
    final tail = _completeSentence.hasMatch(_response.substring(_cursor))
        ? _drain(_response, atEnd: true)
        : const <String>[];
    _restartResponse();
    return tail;
  }

  /// Where [finalText] continues past the spoken prefix, or null when it
  /// does not start with it (leading whitespace aside).
  int? _remainderOffset(String finalText) {
    final spoken = spokenPrefix;
    if (finalText.startsWith(spoken)) return spoken.length;
    final spokenTrimmed = spoken.trimLeft();
    final finalTrimmed = finalText.trimLeft();
    if (!finalTrimmed.startsWith(spokenTrimmed)) return null;
    return finalText.length - finalTrimmed.length + spokenTrimmed.length;
  }

  /// Scans [text] from the cursor, emitting every chunk whose boundary is
  /// certain. With [atEnd] the text is complete and the tail is a chunk too.
  /// The cursor (and the fence state) only advance past committed text, so a
  /// later, longer partial rescans exactly what was left undecided.
  List<String> _drain(String text, {required bool atEnd}) {
    final out = <String>[];
    var i = _cursor;
    var chunkStart = _cursor;

    void commit(int to) {
      i = to;
      chunkStart = to;
      _cursor = to;
    }

    while (i < text.length) {
      if (i == 0 || text.codeUnitAt(i - 1) == _newline) {
        final lineEnd = text.indexOf('\n', i);
        final lineComplete = lineEnd >= 0 || atEnd;
        final next = lineEnd >= 0 ? lineEnd + 1 : text.length;
        final head = text.substring(i, lineEnd >= 0 ? lineEnd : text.length);
        final isFence = _fenceLine.hasMatch(head);
        if (_inFence) {
          // Code is never spoken. A line could still become the closing
          // fence until it is complete (the cursor stays at its start).
          if (!lineComplete) break;
          if (isFence) _inFence = false;
          commit(next);
          continue;
        }
        if (isFence) {
          // An opening fence ends the chunk before it. The fence is entered
          // only once its line is complete, so inside a fence the cursor
          // always rests at a line start.
          _emitChunk(out, text, chunkStart, i);
          commit(i);
          if (!lineComplete) break;
          _inFence = true;
          commit(next);
          continue;
        }
        if (!lineComplete && _couldBecomeFence.hasMatch(head)) break;
      }

      final c = text.codeUnitAt(i);
      if (c == _newline) {
        _emitChunk(out, text, chunkStart, i);
        commit(i + 1);
        continue;
      }
      if (_terminals.contains(c)) {
        var j = i + 1;
        while (j < text.length && _terminals.contains(text.codeUnitAt(j))) {
          j++;
        }
        while (j < text.length && _closers.contains(text.codeUnitAt(j))) {
          j++;
        }
        if (j >= text.length) {
          if (!atEnd) break; // Whether this ends the sentence is not known yet.
          _emitChunk(out, text, chunkStart, j);
          commit(j);
          continue;
        }
        if (_isSpace(text.codeUnitAt(j)) &&
            !(j == i + 1 && c == _period && _isFalseStop(text, i))) {
          _emitChunk(out, text, chunkStart, j);
          commit(j);
          continue;
        }
        i = j;
        continue;
      }
      i++;
    }

    if (atEnd && chunkStart < text.length) {
      _emitChunk(out, text, chunkStart, text.length);
      commit(text.length);
    }
    return out;
  }

  /// The single period at [dot] follows an abbreviation or a list number.
  bool _isFalseStop(String text, int dot) {
    var start = dot;
    while (start > 0 && !_isSpace(text.codeUnitAt(start - 1))) {
      start--;
    }
    final token = text.substring(start, dot + 1);
    final word = token.replaceFirst(_leadingOpeners, '').toLowerCase();
    if (kNonTerminalAbbreviations.contains(word)) return true;
    // "1." opening a line is a list marker, not the end of a sentence.
    if (_listNumber.hasMatch(token)) return _onlySpaceBefore(text, start);
    return false;
  }

  void _emitChunk(List<String> out, String text, int start, int end) {
    if (end <= start) return;
    final cleaned = _clean(
      text.substring(start, end),
      atLineStart: _onlySpaceBefore(text, start),
    );
    if (!_speakable.hasMatch(cleaned)) return;
    out.addAll(_splitLong(cleaned, maxSpokenChunk));
  }
}

const _newline = 0x0A;
const _period = 0x2E;
const _question = 0x3F;
const _exclamation = 0x21;
const _terminals = {_period, _question, _exclamation};

/// Closing marks that may follow terminal punctuation: `" ' ) ] * _ ” ’`.
const _closers = {0x22, 0x27, 0x29, 0x5D, 0x2A, 0x5F, 0x201D, 0x2019};

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

/// Only whitespace between the start of [index]'s line and [index].
bool _onlySpaceBefore(String text, int index) {
  for (var k = index - 1; k >= 0; k--) {
    final c = text.codeUnitAt(k);
    if (c == _newline) return true;
    if (!_isSpace(c)) return false;
  }
  return true;
}

final _fenceLine = RegExp(r'^\s{0,3}(```|~~~)');
final _couldBecomeFence = RegExp(r'^\s{0,3}(`{1,2}|~{1,2})$');
final _leadingOpeners = RegExp('^["\'(\\[*_“‘]+');
final _listNumber = RegExp(r'^\d+\.$');
final _speakable = RegExp(r'[\p{L}\p{N}]', unicode: true);

final _markdownLink = RegExp(r'\[([^\]]*)\]\([^)]*\)');
final _url = RegExp(r'(?:https?://|www\.)\S+', caseSensitive: false);

/// A bare domain ("brewery.co", "example.com/menu") on the common TLDs. The
/// dot must be followed directly by the TLD and the TLD must end the word,
/// so "3.5", "e.g.", "Dr. Smith" and "St. Paul" never match.
final _bareDomain = RegExp(
  r'\b[a-z0-9-]+(?:\.[a-z0-9-]+)*'
  r'\.(?:com|org|net|io|ai|dev|app|co|us|edu|gov|me|info|biz)'
  r'(?![a-z0-9-])(?:/\S*)?',
  caseSensitive: false,
);

/// Ends in terminal punctuation (closing marks and whitespace allowed).
final _completeSentence = RegExp('[.?!]["\'\u201d\u2019)\\]*_]*\\s*\$');
final _urlTrailing = RegExp(r'[.,;:!?)\]"”’]+$');
final _header = RegExp(r'^\s*#{1,6}\s+');
final _listMarker = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+');
final _quoteMarker = RegExp(r'^\s*>\s?');
final _emphasisStars = RegExp(r'\*+|~~|`');
final _edgeUnderscores = RegExp(
  r'(?<![\p{L}\p{N}])_+|_+(?![\p{L}\p{N}])',
  unicode: true,
);
final _whitespace = RegExp(r'\s+');

/// One chunk (never spanning a line break) as it should be spoken.
String _clean(String raw, {required bool atLineStart}) {
  var s = raw;
  if (atLineStart) {
    s = s
        .replaceFirst(_header, '')
        .replaceFirst(_quoteMarker, '')
        .replaceFirst(_listMarker, '');
  }
  s = s.replaceAllMapped(_markdownLink, (m) => m[1]!);
  String link(Match m) =>
      'link${_urlTrailing.firstMatch(m[0]!)?.group(0) ?? ''}';
  s = s.replaceAllMapped(_url, link).replaceAllMapped(_bareDomain, link);
  s = s.replaceAll(_emphasisStars, '').replaceAll(_edgeUnderscores, '');
  return s.replaceAll(_whitespace, ' ').trim();
}

/// [text] in pieces of at most [max], cut at the last clause boundary (`,;:`
/// then a space) in the back two-thirds of the window, else at the last
/// space, else hard (never inside a surrogate pair).
List<String> _splitLong(String text, int max) {
  final out = <String>[];
  var rest = text;
  while (rest.length > max) {
    var cut = -1;
    for (var k = max - 1; k >= max ~/ 3; k--) {
      final c = rest.codeUnitAt(k);
      if ((c == 0x2C || c == 0x3B || c == 0x3A) &&
          _isSpace(rest.codeUnitAt(k + 1))) {
        cut = k + 1;
        break;
      }
    }
    if (cut <= 0) cut = rest.lastIndexOf(' ', max);
    if (cut <= 0) {
      cut = max;
      final unit = rest.codeUnitAt(cut - 1);
      if (unit >= 0xD800 && unit <= 0xDBFF) cut--;
    }
    final piece = rest.substring(0, cut).trim();
    if (piece.isNotEmpty) out.add(piece);
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}
