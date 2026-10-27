import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:uuid/uuid.dart';

import '../assembly/sentence_assembler.dart';
import '../debug/voice_debug.dart';
import '../http/transport_failure.dart';
import '../playback/reply_audio_player.dart';
import '../playback/reply_clip_files.dart';
import '../protocol/constants.dart';
import '../protocol/voice_limit.dart';
import 'reply_tts.dart';
import 'speaker_ports.dart';
import 'tts_auth.dart';

/// Why the reply speaker stopped (the `MVOICE speak_stop` line names it).
enum SpeakerStopReason {
  /// The user spoke over the reply ("Interrupt by voice" on).
  bargeIn,

  /// A mic tap while the reply played (manual barge-in).
  micTap,

  /// The app went to the background.
  pause,

  /// The conversation screen went away.
  leave,

  /// The audio mode no longer speaks this reply.
  audioMode,

  /// The voice session was torn down (sign-out, a failed start, a remote
  /// end, an explicit disconnect: whichever of them the app's policy stops
  /// the speaker for).
  teardown;

  /// Also silences the app's active turn ([SpeakerPorts.activeTurnId]),
  /// which may not have sent the speaker anything yet (it would otherwise
  /// start speaking after the stop).
  bool get silencesActiveTurn => switch (this) {
    pause || leave || teardown => true,
    bargeIn || micTap || audioMode => false,
  };
}

/// Speaks replies with the speech of `POST /voice/tts`, sentence by sentence
/// while the reply still streams. Everything it reads comes through its
/// [SpeakerPorts]; it writes only [playing] and [limitNotices].
///
/// **Which replies.** Those [SpeakerPorts.isEligible] says, read per event,
/// so a setting change applies at once; [SpeakerPorts.speechModeChanges]
/// stops the reply playing when it no longer is.
///
/// **Source.** [SpeakerPorts.turnEvents]. Per turn a [SentenceAssembler] is
/// fed its partials and final, told about a response boundary at each tool
/// round, and reset when the turn is committed, done or failed.
///
/// **Latest turn wins.** A newer turn's first sentence stops the older
/// reply's audio (a newer turn that will not be spoken stops it at its
/// first event). Every stop and switch bumps a generation, so a speech
/// response that lands after it is dropped.
///
/// **Audio.** One sentence is fetched at a time, at most one ahead of the
/// clip playing; each is written to a clip file ([SpeakerPorts.clipFiles],
/// its extension from the clip's media type) and appended to the player's
/// queue (one playlist, no gap between clips), and deleted once it has
/// played or been dropped. Files a previous run left are swept first.
///
/// **One sentence, at most two sends** (`PROTOCOL.md` §5.3). Each sentence
/// gets an `Idempotency-Key` (a v4 uuid), so the server charges it once
/// however often it is sent. Its budget, [fetchTimeout], starts before
/// anything else. With a [SpeakerPorts.ttsAuth] the token is refreshed
/// ahead when it is about to expire (a sentence that has no usable token is
/// skipped, `speak_tts_auth reason=ahead`; the reply goes on). The request
/// is sent once more, under the same key and extras, either after a
/// transport failure with no response headers ([isTransportFailure]: never
/// a timeout or a response), or after a `401` once
/// [TtsAuth.refreshAfterUnauthorized] succeeded — never both. A `401`
/// refreshes even when no send is left (for the next sentence), and a
/// second `401` or a failed refresh gives up (`speak_tts_auth`). No `503`
/// refreshes. Before EVERY send, the first included, the reply must still
/// be the current one (no stop, switch or teardown since) with at least
/// [retryMinBudget] of the budget left: a stale reply ends silently, one
/// out of budget fails as a timeout. There is no per-attempt timeout:
/// [fetchTimeout] is the sentence's one budget.
///
/// **Typed audio.** A clip in a type this client does not play
/// ([UnsupportedAudioType], or a [ReplyClip] outside `kAllowedAudioTypes`)
/// is skipped (`speak_tts_unsupported_type`): nothing is played or written,
/// and the reply goes on.
///
/// **The text bound.** [maxSpokenChunk] is the most recent TTS response's
/// `X-Voice-Tts-Max-Chars` (600 when it has none, or one under 600; a `422`
/// resets it to 600), for the speaker's lifetime. New sentences are split
/// to it, and a queued sentence longer than it is split again before its
/// request.
///
/// **Failure.** Any other speech, file or playback failure ends that
/// reply's audio — the reply stays text — with one debug line. So does a
/// sentence whose speech and file take longer than [fetchTimeout]; a clip
/// due to play that has not started [playbackStartTimeout] after it was
/// handed to the player (or after the clip before it ended); and
/// [playbackStallTimeout] of no progress while playing with no clip waiting
/// for its start. So nothing holds [playing] — and the mic's half-duplex
/// mute — for good. A `429` with `Retry-After` starts a cooldown shared by
/// every turn (at most [maxLimitCooldown]): no speech is asked for until it
/// ends, and replies are text-only meanwhile; a `503` with `Retry-After` is
/// a short one (at most [maxUnavailableCooldown]). A `429` whose body names
/// the spent allowance is also published once on [limitNotices].
///
/// **Stopped by** [stop], barge-in ([SpeakerPorts.userSpeechStarts] with
/// [SpeakerPorts.interruptByVoice]), the app's pause (with
/// `listenToLifecycle`), the audio mode, and the app cancelling the turn
/// ([SpeakerPorts.cancelledTurns]). A stopped reply stays silent for the
/// rest of its turn; the next turn speaks again. A pause, a leave and a
/// teardown also silence the app's turn in flight, even before it sent
/// anything; while the app is paused nothing is fetched or played, and a
/// turn that started meanwhile stays silent.
///
/// **Playing** ([playing]): from the first clip handed to the player until
/// the queue drains with nothing more being fetched, or a stop. When a reply
/// ends, the audio focus is given back ([ReplyAudioPlayer.release]; the
/// mic's capture decides how, [SpeakerPorts.captureLive]).
///
/// **Disposal** ([dispose]) notifies nothing synchronously: it can run in a
/// Riverpod `onDispose`, where the app's mirror of [playing] may not write
/// other providers, or in a listener of [playing] itself. Whatever a
/// [playing] listener does (a stop, a disposal), the speaker re-checks
/// after notifying it: nothing is enqueued or armed for a reply it ended.
class ReplySpeaker {
  ReplySpeaker(
    this._ports, {
    VoiceDebugSink? debug,
    bool listenToLifecycle = true,
    this.playbackStartTimeout = const Duration(seconds: 5),
    this.playbackStallTimeout = const Duration(seconds: 60),
    this.fetchTimeout = const Duration(seconds: 20),
    this.retryMinBudget = const Duration(seconds: 5),
    this.maxLimitCooldown = const Duration(hours: 24),
    this.maxUnavailableCooldown = const Duration(minutes: 1),
    Duration Function()? monotonic,
    DateTime Function()? now,
  }) : _debug = debug ?? defaultVoiceDebugSink,
       _monotonic = monotonic ?? _stopwatch(),
       _now = now ?? DateTime.now {
    _subs = [
      _ports.turnEvents.listen(_onEvent),
      _ports.cancelledTurns.listen(_onTurnCancelled),
      _ports.speechModeChanges.listen(_onModeChanged),
      _ports.userSpeechStarts.listen((_) => _onUserSpeech()),
      // The focus a reply kept while the mic was on goes back with the mic.
      _ports.micOff.listen((_) {
        if (!_playing.value) _releaseFocus();
      }),
    ];
    if (listenToLifecycle) {
      _lifecycle = AppLifecycleListener(onPause: _onPause, onResume: _onResume);
    }
    _start();
  }

  static Duration Function() _stopwatch() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// The longest a clip due to play may take to start: from when it is
  /// handed to the player, or — queued behind another — from when the clip
  /// before it ended, to its [ReplyClipPhase.started].
  final Duration playbackStartTimeout;

  /// The longest a reply may play without progress (a clip starting or
  /// ending, or the next clip arriving) while no clip waits for its start.
  final Duration playbackStallTimeout;

  /// The longest one sentence may take, from its start to its clip file:
  /// the refresh ahead, both sends and the file included.
  final Duration fetchTimeout;

  /// The least of [fetchTimeout] that must be left for any send to start,
  /// the first included.
  final Duration retryMinBudget;

  /// The longest cooldown a `429`'s `Retry-After` sets.
  final Duration maxLimitCooldown;

  /// The longest cooldown a `503`'s `Retry-After` sets.
  final Duration maxUnavailableCooldown;

  /// At most this many sends per sentence (`PROTOCOL.md` §5.3).
  static const _maxSends = 2;
  static const _uuid = Uuid();

  final SpeakerPorts _ports;
  final VoiceDebugSink _debug;
  final Duration Function() _monotonic;
  final DateTime Function() _now;

  late final List<StreamSubscription<Object?>> _subs;
  AppLifecycleListener? _lifecycle;
  bool _disposed = false;

  final _playing = ValueNotifier<bool>(false);
  final _limitNotices = StreamController<VoiceLimit>.broadcast();

  /// The app is in the background: nothing is fetched or played.
  bool _paused = false;

  /// No speech is asked for while this runs (a `Retry-After`).
  Timer? _cooldown;
  Timer? _fetchTimer;

  /// Bumped by every stop and turn switch: a fetch that sees another value
  /// is stale.
  int _gen = 0;

  /// The turn whose events feed [_assembler] (the newest seen).
  String? _feedTurn;

  /// [_feedTurn]'s stream reported its end (committed, done, failed).
  bool _feedTurnOver = false;
  final SentenceAssembler _assembler = SentenceAssembler();
  Duration? _turnStartedAt;
  bool _firstSentenceLogged = false;

  /// The turn whose sentences are fetched and played.
  String? _speakTurn;
  final Queue<String> _texts = Queue<String>();
  bool _fetching = false;

  /// Clips handed to the player and not finished, in order.
  final List<String> _queued = [];
  final Map<String, int> _clipIndex = {};
  int _nextIndex = 0;

  Timer? _stallTimer;

  /// The clip the start watch waits on (the head of [_queued], not started
  /// yet), and its [playbackStartTimeout].
  String? _startAwaited;
  Timer? _startTimer;

  /// Clips in [_queued] that reported their start.
  final Set<String> _startedClips = {};

  /// Turns never to be spoken again (stopped or failed), newest last.
  final LinkedHashSet<String> _silenced = LinkedHashSet<String>();
  static const _silencedCapacity = 32;

  ReplyAudioPlayer? _player;
  StreamSubscription<ReplyClipEvent>? _playerSub;
  ReplyClipFiles get _files => _ports.clipFiles;
  Future<void>? _sweep;

  /// Audio of a reply is playing, queued, or on its way. The app mirrors it
  /// (its "speaking" state, the mic's half-duplex mute). After [dispose] it
  /// is cleared one microtask later, then disposed.
  ValueListenable<bool> get playing => _playing;

  /// A speech budget found spent: a `429` whose body named the spent
  /// allowance (`scope` and `resets_at`). One event per refusal, so the same
  /// limit twice notifies twice. A `429` without them (an older server) is
  /// a cooldown with no notice.
  Stream<VoiceLimit> get limitNotices => _limitNotices.stream;

  /// The longest sentence asked for now, in UTF-16 code units: the text
  /// bound the most recent TTS response advertised, at least
  /// [kTtsMinTextChars].
  int get maxSpokenChunk => _assembler.maxSpokenChunk;

  /// Stops the reply now: nothing more of it is fetched or played, its
  /// clips are deleted, and its turn (and the turn being assembled) stays
  /// silent. A no-op when nothing is being spoken.
  void stop(SpeakerStopReason reason) {
    if (_disposed) return;
    final active = _replyInProgress || (_feedTurn != null && !_feedTurnOver);
    final inFlight = reason.silencesActiveTurn ? _ports.activeTurnId() : null;
    for (final turnId in [_speakTurn, _feedTurn, inFlight]) {
      if (turnId != null) _silence(turnId);
    }
    _assembler.reset();
    _dropAudio();
    if (active || inFlight != null) {
      _mvoice('speak_stop', 'reason=${reason.name}');
    }
  }

  /// Stops listening (the ports' streams, the lifecycle) and every timer,
  /// and lets the player go (stopped, released as far as the mic's capture,
  /// read now, allows — [SpeakerPorts.captureLive] — disposed) and the clip
  /// files with it.
  ///
  /// Safe in a Riverpod `onDispose`, and in a [playing] listener: nothing is
  /// notified synchronously. ONE microtask later [playing] turns false, when
  /// a reply was playing — its listeners (the app's mirror) still attached,
  /// so they hear it — and the notifier is then disposed, which detaches
  /// them (never during a notification of its own). A replacement speaker
  /// cannot have started playing within that microtask, so a mirror that
  /// writes only for the speaker it mirrors never clears a newer one's
  /// state.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _gen++;
    _lifecycle?.dispose();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _cancelStall();
    _startTimer?.cancel();
    _startTimer = null;
    _fetchTimer?.cancel();
    _cooldown?.cancel();
    final playing = _playing;
    final wasPlaying = playing.value;
    scheduleMicrotask(() {
      if (wasPlaying) playing.value = false;
      playing.dispose();
    });
    unawaited(_limitNotices.close());
    final leftover = List.of(_queued);
    _queued.clear();
    _texts.clear();
    final player = _player;
    _player = null;
    unawaited(_playerSub?.cancel());
    if (player == null) {
      _deleteAll(leftover);
    } else {
      // Read now, while the ports are still the app's: the micOff
      // subscription that would give the focus back later is gone.
      final captureLive = _captureLiveAtDisposal();
      // Stopped first, so the focus can go back.
      Future<void> quietly(Future<void> Function() step) =>
          step().catchError((Object _) {});
      unawaited(
        quietly(player.stop)
            .then(
              (_) => quietly(() => player.release(captureLive: captureLive)),
            )
            .then((_) => quietly(player.dispose))
            .whenComplete(() => _deleteAll(leftover)),
      );
    }
  }

  /// [SpeakerPorts.captureLive] at disposal, which may run in a Riverpod
  /// `onDispose`: if reading it fails there, the capture counts as live (its
  /// session is kept, as for a live mic).
  bool _captureLiveAtDisposal() {
    try {
      return _ports.captureLive();
    } catch (error) {
      debugPrint(
        '[speaker] reading the capture state at disposal failed: '
        '${error.runtimeType}',
      );
      return true;
    }
  }

  /// Audio of a reply is playing, queued or on its way, or its turn is still
  /// streaming sentences to speak.
  bool get _replyInProgress =>
      _speakTurn != null &&
      (_playing.value ||
          _fetching ||
          _texts.isNotEmpty ||
          _queued.isNotEmpty ||
          (_feedTurn == _speakTurn && !_feedTurnOver));

  /// Whether [turnId]'s reply is spoken now.
  bool _eligible(String turnId) {
    if (_paused || _silenced.contains(turnId)) return false;
    return _ports.isEligible(turnId);
  }

  /// The speaker runs from now: stale clips are swept first (once).
  void _start() {
    _sweep ??= _sweepStale();
  }

  Future<void> _sweepStale() async {
    try {
      final swept = await _files.sweep();
      if (swept > 0) debugPrint('[speaker] swept $swept stale reply clip(s)');
    } catch (error) {
      debugPrint(
        '[speaker] sweeping stale reply clips failed: '
        '${error.runtimeType}',
      );
    }
  }

  void _onModeChanged(SpeechModeChange change) {
    if (_disposed) return;
    if (change == SpeechModeChange.off) {
      stop(SpeakerStopReason.audioMode);
      return;
    }
    final turnId = _speakTurn;
    if (turnId != null && !_eligible(turnId)) {
      stop(SpeakerStopReason.audioMode);
    }
  }

  void _onUserSpeech() {
    if (_disposed || !_replyInProgress) return;
    if (!_ports.interruptByVoice()) return;
    stop(SpeakerStopReason.bargeIn);
  }

  void _onPause() {
    _paused = true;
    stop(SpeakerStopReason.pause);
  }

  /// Back in the foreground: a turn that started while paused stays silent.
  void _onResume() {
    if (_disposed) return;
    final inFlight = _ports.activeTurnId();
    if (inFlight != null) _silence(inFlight);
    _paused = false;
  }

  /// The app cancelled [turnId] (preempted, reset, a conversation switch):
  /// its audio stops now, whatever replaces it.
  void _onTurnCancelled(String turnId) {
    if (_disposed) return;
    final speaking = _speakTurn == turnId && _replyInProgress;
    _abandon(turnId);
    if (speaking) _mvoice('speak_stop', 'reason=cancelled');
  }

  void _onEvent(SpeakerTurnEvent event) {
    if (_disposed) return;
    final turnId = event.turnId;
    if (turnId != _feedTurn) _beginTurn(turnId);
    final ends =
        event is SpeakerTurnCommitted ||
        event is SpeakerTurnDone ||
        event is SpeakerTurnFailed;
    if (ends && !_feedTurnOver) {
      _feedTurnOver = true;
      // Its last clip may have ended before the turn did.
      if (_speakTurn == turnId && !_playing.value) _releaseFocus();
    }
    if (!_eligible(turnId)) return;
    switch (event) {
      case SpeakerPartial(:final cumulativeText):
        _speak(turnId, _assembler.assistantPartial(cumulativeText));
      case SpeakerFinal(:final text):
        _speak(turnId, _assembler.assistantFinal(text));
      case SpeakerToolBoundary():
        _speak(turnId, _assembler.responseBoundary());
      case SpeakerTurnFailed():
        // A failed turn shows no reply: none is spoken either.
        _abandon(turnId);
      case SpeakerTurnDone():
        _assembler.reset();
        if (_speakTurn == turnId) _mvoice('speak_turn_done');
      case SpeakerTurnCommitted():
        _assembler.reset();
      case SpeakerTurnSeen():
        break;
    }
  }

  /// [turnId] is newer than every turn seen so far (one turn streams at a
  /// time, so an older one never comes back).
  void _beginTurn(String turnId) {
    // Started while the app is in the background: never spoken.
    if (_paused) _silence(turnId);
    _feedTurn = turnId;
    _feedTurnOver = false;
    _assembler.reset();
    _turnStartedAt = _monotonic();
    _firstSentenceLogged = false;
    // A newer turn that will not be spoken ends the older reply now: none
    // of its sentences will ever take over.
    if (_speakTurn != null && !_eligible(turnId)) _dropAudio();
  }

  void _speak(String turnId, List<String> sentences) {
    if (sentences.isEmpty) return;
    if (_cooldown != null) {
      // Speech is limited for now: this reply is text-only, all of it.
      _silence(turnId);
      _mvoice('speak_skipped', 'cooldown');
      return;
    }
    if (!_firstSentenceLogged) {
      _firstSentenceLogged = true;
      _mvoice('speak_first_sentence');
    }
    if (_speakTurn != turnId) {
      // Latest turn wins: the older reply's audio ends here.
      if (_speakTurn != null) _dropAudio();
      _speakTurn = turnId;
    }
    _start();
    _texts.addAll(sentences);
    _pump();
  }

  /// Starts the next fetch: one at a time, at most one clip ahead of the
  /// one playing.
  void _pump() {
    if (_disposed ||
        _paused ||
        _cooldown != null ||
        _fetching ||
        _texts.isEmpty ||
        _queued.length > 1) {
      return;
    }
    final turnId = _speakTurn;
    if (turnId == null) return;
    var text = _texts.removeFirst();
    // Assembled under a larger bound than the latest response advertised.
    if (text.length > maxSpokenChunk) {
      final pieces = splitSpokenChunk(text, maxSpokenChunk);
      text = pieces.first;
      for (var k = pieces.length - 1; k > 0; k--) {
        _texts.addFirst(pieces[k]);
      }
    }
    final index = _nextIndex++;
    final gen = _gen;
    _fetching = true;
    // The whole of this sentence, bounded: the refresh ahead, both sends,
    // the file.
    _fetchTimer?.cancel();
    _fetchTimer = Timer(fetchTimeout, () {
      _fetchTimer = null;
      if (gen == _gen && _fetching) _fail(turnId, 'timeout');
    });
    unawaited(_fetch(gen, turnId, index, text));
  }

  Future<void> _fetch(int gen, String turnId, int index, String text) async {
    // The sentence's budget starts here, before any refresh.
    final startedAt = _monotonic();
    // Stopped or superseded meanwhile (a stop, a switch, a teardown): what
    // this fetch got is dropped, and a failure is no longer this reply's.
    bool stale() => gen != _gen || _disposed;
    // The one rule before every send: still current, and enough budget.
    bool fresh() =>
        !stale() && fetchTimeout - (_monotonic() - startedAt) >= retryMinBudget;
    try {
      final request = _ports.tts.request(
        text,
        voice: _ports.voice(),
        idempotencyKey: _uuid.v4(),
      );
      _mvoice('speak_tts_request', 'i=$index');
      final auth = _ports.ttsAuth;
      if (auth != null && !await _ask(auth.refreshAhead)) {
        if (stale()) return;
        _mvoice('speak_tts_auth', 'i=$index reason=ahead');
        _skipSentence('no usable token');
        return;
      }
      if (!fresh()) {
        if (!stale()) _fail(turnId, 'timeout');
        return;
      }
      final clip = await _send(request, index, stale, fresh);
      if (stale()) return;
      final mediaType = allowedMediaType(clip.mediaType);
      if (mediaType == null) {
        _skipUnsupported(index, clip.mediaType);
        return;
      }
      _mvoice(
        'speak_tts_bytes',
        'i=$index bytes=${clip.bytes.length} '
            'ms=${(_monotonic() - startedAt).inMilliseconds}',
      );
      await _sweep; // never write before the sweep is done with the dir
      final path = await _files.write(clip.bytes, mediaType: mediaType);
      if (stale()) {
        unawaited(_delete(path));
        return;
      }
      _endFetch();
      _queued.add(path);
      _clipIndex[path] = index;
      _refreshPlaying();
      // A [playing] listener may have stopped the reply or disposed the
      // speaker: then the clip went with it (deleted), and no player is
      // made or fed for it.
      if (stale()) return;
      _watchStart();
      _watchStall();
      final enqueued = _ensurePlayer().enqueue(path, mediaType: mediaType);
      // The next sentence is fetched while this one loads and plays.
      _pump();
      await enqueued;
    } catch (error) {
      if (stale()) return;
      if (error is UnsupportedAudioType) {
        _skipUnsupported(index, error.mediaType);
        return;
      }
      _noticeLimit(error);
      final cooldown = _cooldownFor(error);
      if (cooldown == null) {
        _fail(turnId, error);
      } else {
        _startCooldown(cooldown, error);
        _abandon(turnId);
      }
    }
  }

  /// [request]'s audio, in at most [_maxSends] sends: one more, under the
  /// same key and extras, after a transport failure, or after a `401` once
  /// the refresh succeeded — while [fresh] (checked after every await).
  /// Anything else is rethrown as it came. Every response's advertised
  /// bound is noted.
  Future<ReplyClip> _send(
    ReplyTtsRequest request,
    int index,
    bool Function() stale,
    bool Function() fresh,
  ) async {
    for (var sends = 1; ; sends++) {
      try {
        final clip = await request.send();
        _noteResponse(clip);
        return clip;
      } catch (error) {
        _noteResponse(error);
        if (stale()) rethrow;
        final last = sends == _maxSends;
        if (_statusOf(error) == 401) {
          final auth = _ports.ttsAuth;
          if (auth == null) rethrow;
          // Even with no send left: the next sentence gets a fresh token.
          final refreshed = await _ask(
            () => auth.refreshAfterUnauthorized(request.extras),
          );
          if (last) {
            _mvoice('speak_tts_auth', 'i=$index reason=unauthorized');
            rethrow;
          }
          if (!refreshed) {
            _mvoice('speak_tts_auth', 'i=$index reason=refresh');
            rethrow;
          }
          if (!fresh()) rethrow;
          _mvoice('speak_tts_retry', 'i=$index reason=auth');
        } else if (!last && isTransportFailure(error) && fresh()) {
          _mvoice('speak_tts_retry', 'i=$index');
        } else {
          rethrow;
        }
      }
    }
  }

  /// A [TtsAuth] answer; one that throws (against its contract) is false.
  static Future<bool> _ask(Future<bool> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return false;
    }
  }

  static int? _statusOf(Object error) =>
      error is DioException ? responseHead(error)?.status : null;

  /// The text bound from a TTS response ([outcome]: a clip or a failure),
  /// the most recent one winning: its advertised value, or 600 for none
  /// and after a `422`. A failure with no response leaves it as it is.
  void _noteResponse(Object outcome) {
    if (_disposed) return;
    final int? advertised;
    switch (outcome) {
      case ReplyClip(:final maxTextChars):
      case UnsupportedAudioType(:final maxTextChars):
        advertised = maxTextChars;
      case DioException():
        final head = responseHead(outcome);
        if (head == null) return;
        advertised = head.status == 422 ? null : head.maxTextChars;
      default:
        return;
    }
    _assembler.maxSpokenChunk =
        advertised != null && advertised >= kTtsMinTextChars
        ? advertised
        : kTtsMinTextChars;
  }

  /// The sentence [index]'s audio is in a type this client does not play.
  void _skipUnsupported(int index, String? mediaType) {
    final type = mediaType != null && _mediaTypeToken.hasMatch(mediaType)
        ? mediaType
        : '-';
    _mvoice('speak_tts_unsupported_type', 'i=$index type=$type');
    _skipSentence('audio type $type');
  }

  /// A media type as a log value: no spaces, no `=`.
  static final _mediaTypeToken = RegExp(
    r"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$",
  );

  /// The sentence being fetched is given up and the reply goes on: the next
  /// one is fetched (or, with nothing left, the reply ends as it would
  /// after its last clip).
  void _skipSentence(String why) {
    debugPrint('[speaker] a sentence was skipped ($why); the reply goes on');
    _endFetch();
    _pump();
    _refreshPlaying();
    _watchStall();
  }

  /// No sentence is being fetched now: its budget's timer goes with it.
  void _endFetch() {
    _fetchTimer?.cancel();
    _fetchTimer = null;
    _fetching = false;
  }

  /// A `429` or `503` that says when to come back: how long to wait (capped).
  ///
  /// Read off the response's status and header ([responseHead]), so a
  /// response whose body broke after its headers keeps its cooldown.
  Duration? _cooldownFor(Object error) {
    if (error is! DioException) return null;
    final head = responseHead(error);
    final cap = switch (head?.status) {
      429 => maxLimitCooldown,
      503 => maxUnavailableCooldown,
      _ => null,
    };
    if (cap == null) return null;
    final seconds = int.tryParse(head!.retryAfter?.trim() ?? '');
    if (seconds == null || seconds <= 0) return null;
    final wait = Duration(seconds: seconds);
    return wait > cap ? cap : wait;
  }

  /// A `429` whose body names the spent allowance: published on
  /// [limitNotices]. Any other failure (a `429` with no or an unknown scope
  /// included) says nothing.
  void _noticeLimit(Object error) {
    if (error is! DioException || error.response?.statusCode != 429) return;
    final limit = VoiceLimit.fromBody(error.response?.data);
    if (limit != null) _limitNotices.add(limit);
  }

  void _startCooldown(Duration wait, Object error) {
    debugPrint(
      '[speaker] reply speech is limited (${_describe(error)}); '
      'replies are text-only for ${wait.inSeconds}s',
    );
    _cooldown?.cancel();
    _cooldown = Timer(wait, () => _cooldown = null);
  }

  ReplyAudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = _ports.playerFactory();
    _playerSub = player.clipEvents.listen(_onClip);
    _player = player;
    return player;
  }

  void _onClip(ReplyClipEvent event) {
    if (_disposed || !_queued.contains(event.path)) return; // dropped
    final index = _clipIndex[event.path];
    switch (event.phase) {
      case ReplyClipPhase.started:
        _startedClips.add(event.path);
        _watchStart();
        _watchStall();
        _mvoice('speak_playback_start', 'i=$index');
      // A silent clip (it ended without being heard) is over all the same:
      // only the log tells them apart, never the user.
      case ReplyClipPhase.finished || ReplyClipPhase.silent:
        _queued.remove(event.path);
        _clipIndex.remove(event.path);
        _startedClips.remove(event.path);
        // The next clip (if one is queued) is due now.
        _watchStart();
        unawaited(_delete(event.path));
        if (event.phase == ReplyClipPhase.silent) {
          _mvoice('speak_playback_silent', 'i=$index');
        } else {
          _mvoice('speak_playback_end', 'i=$index');
        }
        _pump();
        _refreshPlaying();
        // Still playing (more queued, or the next being fetched): watched.
        _watchStall();
      case ReplyClipPhase.failed:
        final turnId = _speakTurn;
        if (turnId == null) return;
        _mvoice('speak_playback_failed', 'reason=playback i=$index');
        _fail(turnId, 'playback');
    }
  }

  /// Keeps the start watch on the clip due to play: the head of [_queued],
  /// until it reports its start. A clip queued behind another is not due
  /// yet, so its [playbackStartTimeout] runs from when the one before it
  /// ended. Past it, the reply's audio ends as for any playback failure
  /// (the text stays; the next reply tries again).
  void _watchStart() {
    final head = _queued.isEmpty ? null : _queued.first;
    final due = head == null || _startedClips.contains(head) ? null : head;
    if (due == _startAwaited) return;
    _startTimer?.cancel();
    _startTimer = null;
    _startAwaited = due;
    if (due == null) return;
    _startTimer = Timer(playbackStartTimeout, () {
      _startTimer = null;
      final turnId = _speakTurn;
      if (_disposed || _startAwaited != due || turnId == null) return;
      _startAwaited = null;
      _mvoice(
        'speak_playback_failed',
        'reason=start_timeout i=${_clipIndex[due]}',
      );
      _fail(turnId, 'start_timeout');
    });
  }

  /// [turnId]'s speech failed: its reply is text only from here.
  void _fail(String turnId, Object error) {
    debugPrint(
      '[speaker] reply speech failed (${_describe(error)}); '
      'this reply is text-only',
    );
    _abandon(turnId);
  }

  /// [turnId] is never spoken again: what is assembled of it is forgotten
  /// and, if it is the reply being spoken, its audio ends.
  void _abandon(String turnId) {
    _silence(turnId);
    if (_feedTurn == turnId) _assembler.reset();
    if (_speakTurn == turnId) _dropAudio();
  }

  /// Ends the reply being spoken ([_speakTurn] is none after): nothing
  /// more of it is fetched or played, what was fetched is deleted (once the
  /// player let go of it), and responses still in flight are stale.
  void _dropAudio() {
    _speakTurn = null;
    _gen++;
    _texts.clear();
    _endFetch();
    _nextIndex = 0;
    _cancelStall();
    final dropped = List.of(_queued);
    _queued.clear();
    _clipIndex.clear();
    _startedClips.clear();
    _watchStart();
    final player = _player;
    if (player != null && dropped.isNotEmpty) {
      unawaited(
        player
            .stop()
            .then<void>(
              (_) {},
              onError: (Object error) {
                debugPrint(
                  '[speaker] stopping playback failed: '
                  '${error.runtimeType}',
                );
              },
            )
            .whenComplete(() => _deleteAll(dropped)),
      );
    } else {
      _deleteAll(dropped);
    }
    _refreshPlaying();
  }

  void _refreshPlaying() {
    if (_disposed) return;
    // Between two clips of a reply already playing, the next on its way.
    final playing = _queued.isNotEmpty || (_fetching && _playing.value);
    if (playing == _playing.value) return;
    _playing.value = playing;
    if (!playing) _releaseFocus();
  }

  /// The reply is over — not merely between two sentences while its turn
  /// still streams: the player gives the audio focus back, as far as the
  /// mic's live capture allows ([ReplyAudioPlayer.release]).
  void _releaseFocus() {
    final player = _player;
    if (player == null || _disposed) return;
    if (_playing.value || _replyInProgress) return;
    unawaited(
      player.release(captureLive: _ports.captureLive()).catchError((Object e) {
        debugPrint(
          '[speaker] releasing the audio session failed: '
          '${e.runtimeType}',
        );
      }),
    );
  }

  /// Progress: the stall clock starts afresh while the reply plays and no
  /// clip waits for its start (the start watch times that one, whatever
  /// either bound is): it catches a clip that started and never ends, or the
  /// next clip never arriving. Otherwise it is off.
  void _watchStall() {
    if (_playing.value && _startAwaited == null) {
      _armStall();
    } else {
      _cancelStall();
    }
  }

  void _armStall() {
    _stallTimer?.cancel();
    _stallTimer = Timer(playbackStallTimeout, () {
      _stallTimer = null;
      final turnId = _speakTurn;
      if (turnId != null && _playing.value) _fail(turnId, 'stalled');
    });
  }

  void _cancelStall() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _silence(String turnId) {
    _silenced
      ..remove(turnId)
      ..add(turnId);
    while (_silenced.length > _silencedCapacity) {
      _silenced.remove(_silenced.first);
    }
  }

  void _deleteAll(List<String> paths) {
    for (final path in paths) {
      unawaited(_delete(path));
    }
  }

  /// Only for a path [_files] wrote.
  Future<void> _delete(String path) async {
    try {
      await _files.delete(path);
    } catch (error) {
      debugPrint(
        '[speaker] deleting a reply clip failed: '
        '${error.runtimeType}',
      );
    }
  }

  /// A failure for the log: a status or a class, never a body, URL or text.
  static String _describe(Object error) {
    if (error is DioException) {
      final status = responseHead(error)?.status;
      return status == null ? error.type.name : 'status $status';
    }
    if (error is String) return error;
    return error.runtimeType.toString();
  }

  /// Debug-only timing lines (`MVOICE <event>[ <detail>] t=… turn+…ms`, the
  /// vocabulary of [kMvoiceEvents]): event names, clip indexes, sizes and
  /// times — never text or tokens. `turn+` is the time since the speaker
  /// first saw the turn.
  void _mvoice(String event, [String? detail]) {
    assert(kMvoiceEvents.contains(event), 'MVOICE $event is not pinned');
    final since = _turnStartedAt;
    final offset = since == null
        ? ''
        : ' turn+${(_monotonic() - since).inMilliseconds}ms';
    _debug(
      'MVOICE $event${detail == null ? '' : ' $detail'} '
      't=${_now().millisecondsSinceEpoch}$offset',
    );
  }
}
