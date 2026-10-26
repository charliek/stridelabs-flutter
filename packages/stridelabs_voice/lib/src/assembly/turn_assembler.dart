import 'dart:async';

/// The largest `stt_ms` a voice turn reports (10 minutes); the server stores
/// it as an int metric.
const int kMaxSttMs = 600000;

/// [ms] clamped into the `stt_ms` range, 0 to [kMaxSttMs].
int clampSttMs(int ms) => ms.clamp(0, kMaxSttMs);

/// One spoken request, ready to post as a voice turn.
class VoiceUtterance {
  const VoiceUtterance(this.text, this.sttMs);

  /// The fragments of the utterance, joined with single spaces.
  final String text;

  /// First `speech_start` of the utterance to its final `end_of_turn`,
  /// clamped (see [clampSttMs]); null when no `speech_start` was seen.
  final int? sttMs;

  @override
  bool operator ==(Object other) =>
      other is VoiceUtterance && other.text == text && other.sttMs == sttMs;

  @override
  int get hashCode => Object.hash(text, sttMs);

  @override
  String toString() => 'VoiceUtterance("$text", sttMs: $sttMs)';
}

/// Words that, ending a fragment, mean the speaker paused mid-request ("Set a
/// timer for", "Show me."). Compared lowercase with punctuation stripped.
const Set<String> kUnfinishedEndWords = {
  'for',
  'in',
  'of',
  'to',
  'about',
  'at',
  'is',
  'the',
  'a',
  'an',
  'my',
  'and',
  'or',
  'with',
  'from',
  'on',
  'that',
  'me',
  'like',
  'by',
  'um',
  'uh',
  'hmm',
};

final _whitespace = RegExp(r'\s+');

/// How far past its deadline the merge timer fires.
const _pastDeadline = Duration(milliseconds: 1);
final _trailingClosers = RegExp('["\'”’)\\]]+\$');
final _notWordChar = RegExp(r"[^\p{L}\p{N}']", unicode: true);

/// Collapses whitespace runs to one space and trims.
String _normalize(String text) => text.trim().replaceAll(_whitespace, ' ');

/// A fragment looks unfinished when it lacks terminal `.?!` or its last word
/// is one of [kUnfinishedEndWords] (case-insensitive, punctuation stripped).
bool isUnfinishedFragment(String fragment) {
  final text = _normalize(fragment).replaceFirst(_trailingClosers, '');
  if (text.isEmpty) return true;
  final last = text[text.length - 1];
  if (last != '.' && last != '?' && last != '!') return true;
  final word = text.split(' ').last.toLowerCase().replaceAll(_notWordChar, '');
  return kUnfinishedEndWords.contains(word);
}

/// Turns the relay's speech events into whole utterances.
///
/// A provider may end a turn at every pause, so one request often arrives as
/// several `end_of_turn` fragments. A fragment that looks unfinished
/// ([isUnfinished], by default [isUnfinishedFragment]) waits up to [mergeWindow] for the next
/// `speech_start` (one arriving AT the deadline still merges) and is joined
/// to the fragment that follows; a finished one is emitted at once. A
/// `speech_start` that never completes is flushed [speechEndFlush] after its
/// `speech_end`, or [speechStartFlush] after the start; if that segment's
/// `end_of_turn` turns up after all, it is not emitted a second time.
/// [micOff] emits what is pending once the final `end_of_turn` is in (at
/// once when nothing is outstanding).
///
/// Pure Dart: timers come from `dart:async` (faked by `fake_async` in tests)
/// and the clock is injectable. Not reentrant: call it from one isolate's
/// event loop, as the transport does.
class TurnAssembler {
  TurnAssembler({
    required this.onUtterance,
    this.onPendingChanged,
    this.onSegmentFlushed,
    DateTime Function()? now,
    this.mergeWindow = const Duration(milliseconds: 1500),
    this.speechEndFlush = const Duration(seconds: 1),
    this.speechStartFlush = const Duration(seconds: 10),
    this.isUnfinished = isUnfinishedFragment,
  }) : _now = now ?? DateTime.now;

  /// Called with each utterance, in order.
  final void Function(VoiceUtterance utterance) onUtterance;

  /// Called whenever [pendingDisplay] changes (empty once emitted).
  final void Function(String pending)? onPendingChanged;

  /// Called when [flush] closes a segment whose `end_of_turn` has not come
  /// (the start-without-completion timers, or the caller's own flush): the
  /// segment is over as far as the speaker is concerned.
  final void Function()? onSegmentFlushed;

  /// How long an unfinished fragment waits for the next `speech_start`.
  final Duration mergeWindow;

  /// A `speech_start` with no `end_of_turn` is flushed this long after its
  /// `speech_end`...
  final Duration speechEndFlush;

  /// ...or this long after the start, whichever comes first.
  final Duration speechStartFlush;

  /// Whether a fragment looks unfinished, so it waits [mergeWindow] for the
  /// next one (the end-word policy; [isUnfinishedFragment], English, by
  /// default).
  final bool Function(String fragment) isUnfinished;

  final DateTime Function() _now;

  /// The utterance's `end_of_turn` fragments, each normalized and non-empty.
  final List<String> _fragments = [];

  /// The open segment's live transcript, normalized; null when empty.
  String? _partial;

  /// First `speech_start` of the utterance being assembled.
  DateTime? _utteranceStart;

  /// When the utterance's last piece (an `end_of_turn`) arrived.
  DateTime? _lastPieceAt;

  /// A `speech_start` arrived and its `end_of_turn` has not.
  bool _segmentOpen = false;

  /// [micOff] was called: emit after the outstanding `end_of_turn`.
  bool _micOff = false;

  /// The last moment a `speech_start` still joins the waiting fragment.
  DateTime? _mergeDeadline;

  /// A segment was flushed before its `end_of_turn`, with [_partial] as its
  /// text (true) or with nothing to say (false); null when no flushed
  /// segment is awaiting its late `end_of_turn`. Cleared by the next
  /// `speech_start`.
  bool? _flushedSegmentHadText;

  Timer? _mergeTimer;
  Timer? _flushTimer;
  String _lastPending = '';
  bool _disposed = false;

  /// The pending fragments plus the live partial, for the trailing bubble.
  String get pendingDisplay => [..._fragments, ?_partial].join(' ');

  void speechStart() {
    if (_disposed) return;
    final now = _now();
    // A new segment: a flushed one's end_of_turn can no longer be told apart.
    _flushedSegmentHadText = null;
    final deadline = _mergeDeadline;
    if (deadline != null && now.isAfter(deadline)) {
      // The window closed before this start; its timer just has not run.
      _emit();
    }
    // The speaker went on: the fragment waiting for this joins the next one.
    _cancelMerge();
    _utteranceStart ??= now;
    if (!_segmentOpen) {
      _segmentOpen = true;
      _armFlush(speechStartFlush);
    }
  }

  void speechEnd() {
    if (_disposed || !_segmentOpen) return;
    _armFlush(speechEndFlush);
  }

  /// The live (cumulative) transcript of the open segment. Ignored when no
  /// segment is open, so a late partial cannot linger in the bubble.
  void partial(String text) {
    if (_disposed || !_segmentOpen) return;
    final normalized = _normalize(text);
    _partial = normalized.isEmpty ? null : normalized;
    _notifyPending();
  }

  void endOfTurn(String text) {
    if (_disposed) return;
    final flushedHadText = _flushedSegmentHadText;
    _flushedSegmentHadText = null;
    // The late end of a segment already flushed with its partial: said.
    if (flushedHadText == true) return;
    _cancelFlush();
    _segmentOpen = false;
    _partial = null;
    final fragment = _normalize(text);
    if (fragment.isNotEmpty) {
      _fragments.add(fragment);
      _lastPieceAt = _now();
    }
    // No fragments: noise (a segment that transcribed to nothing), which
    // _emit drops along with the utterance's start.
    if (_fragments.isEmpty || _micOff || !isUnfinished(_fragments.last)) {
      _emit();
      return;
    }
    _cancelMerge();
    _mergeDeadline = _now().add(mergeWindow);
    // Fires just after the deadline, so a start AT the deadline still merges
    // (speechStart compares against the deadline itself).
    _mergeTimer = Timer(mergeWindow + _pastDeadline, _emit);
    _notifyPending();
  }

  /// The mic went off: no more speech is coming. Emits what is pending once
  /// the outstanding `end_of_turn` arrives, or now if none is outstanding.
  void micOff() {
    if (_disposed) return;
    _micOff = true;
    if (_segmentOpen) return;
    _emit();
  }

  /// Emits whatever is held now, the live partial included (the relay closed
  /// before its `end_of_turn`).
  void flush() {
    if (_disposed) return;
    final segmentOpen = _segmentOpen;
    final partial = _partial;
    if (partial != null) {
      _fragments.add(partial);
      _lastPieceAt = _now();
    }
    _emit();
    if (!segmentOpen) return;
    // Remember the cut segment, so its late end_of_turn is not said twice.
    _flushedSegmentHadText = partial != null;
    onSegmentFlushed?.call();
  }

  /// Drops everything held, without emitting.
  void reset() {
    _cancelMerge();
    _cancelFlush();
    _segmentOpen = false;
    _partial = null;
    _fragments.clear();
    _utteranceStart = null;
    _lastPieceAt = null;
    _micOff = false;
    _flushedSegmentHadText = null;
    _notifyPending();
  }

  void dispose() {
    reset();
    _disposed = true;
  }

  /// Emits the held fragments as one utterance and resets.
  void _emit() {
    final text = _fragments.join(' ');
    final start = _utteranceStart;
    final end = _lastPieceAt ?? _now();
    reset();
    if (text.isEmpty) return;
    final sttMs = start == null
        ? null
        : clampSttMs(end.difference(start).inMilliseconds);
    onUtterance(VoiceUtterance(text, sttMs));
  }

  void _armFlush(Duration after) {
    _cancelFlush();
    // The start-without-completion flush.
    _flushTimer = Timer(after, flush);
  }

  void _cancelMerge() {
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _mergeDeadline = null;
  }

  void _cancelFlush() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _notifyPending() {
    final pending = pendingDisplay;
    if (pending == _lastPending) return;
    _lastPending = pending;
    onPendingChanged?.call(pending);
  }
}
