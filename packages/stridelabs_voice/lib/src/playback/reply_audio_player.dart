import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../protocol/constants.dart';

/// What happened to one clip the reply speaker handed to the player.
enum ReplyClipPhase {
  /// Its audio started: the player is playing it (on Linux, its position
  /// has moved; see [JustAudioReplyPlayer]).
  started,

  /// It played to its end.
  finished,

  /// It reached its end without being heard: it played for under half its
  /// length (libmpv with no audio device ends a clip at once, see
  /// [JustAudioReplyPlayer]). The speaker moves on as after [finished].
  silent,

  /// It (or the playback it was part of) failed: the speaker drops the
  /// reply. Clips that were stopped report nothing.
  failed,
}

@immutable
class ReplyClipEvent {
  const ReplyClipEvent(this.path, this.phase);

  final String path;
  final ReplyClipPhase phase;

  @override
  bool operator ==(Object other) =>
      other is ReplyClipEvent && other.path == path && other.phase == phase;

  @override
  int get hashCode => Object.hash(path, phase);

  @override
  String toString() => 'ReplyClipEvent(${phase.name}, $path)';
}

/// The reply speaker's player: an ordered queue of audio files, played back to
/// back. Narrow on purpose, so tests drive the speaker with a fake.
abstract interface class ReplyAudioPlayer {
  /// Each clip's [ReplyClipPhase.started] and then [ReplyClipPhase.finished]
  /// (or [ReplyClipPhase.silent], or [ReplyClipPhase.failed]); none for a
  /// clip [stop] dropped.
  Stream<ReplyClipEvent> get clipEvents;

  /// Appends [path], a clip of [mediaType] (one of [kAllowedAudioTypes]), to
  /// the queue; with nothing playing it plays at once, otherwise right after
  /// the clip before it. Throws when it cannot be loaded, an unsupported
  /// [mediaType] included.
  Future<void> enqueue(String path, {required String mediaType});

  /// Stops playback now and forgets the queue.
  Future<void> stop();

  /// The reply is over (it played out or was stopped): give the audio focus
  /// back, so other apps' audio resumes — unless [captureLive] and, on this
  /// platform, deactivating the audio session would stop the mic's
  /// recorder (iOS/macOS share one session with it; on Android the
  /// recorder holds no focus, so it is always given back). A no-op while a
  /// newer reply plays or when nothing was taken.
  Future<void> release({required bool captureLive});

  Future<void> dispose();
}

/// The audio session spoken replies play in. `speech()` — on Android
/// speech content on the media stream, taking audio focus to play — keeps
/// the reply out of the recorder's way: `record` runs with
/// `audioInterruption: none` (`captureConfig`), so it never holds focus
/// and the reply taking it cannot pause the capture. The focus is
/// TRANSIENT (other apps pause, and resume once the reply gives it back,
/// [ReplyAudioPlayer.release]). The iOS fields (unused on Android) keep
/// the session recordable: `speech()`'s `playback` category would silence
/// the microphone there.
final AudioSessionConfiguration replyAudioSessionConfiguration =
    const AudioSessionConfiguration.speech().copyWith(
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.allowBluetooth,
    );

/// [ReplyAudioPlayer] over one just_audio [AudioPlayer] and its playlist:
/// a clip enqueued while another plays is appended, so the player moves on
/// without a gap. The audio session is configured for speech
/// ([replyAudioSessionConfiguration]) before the first clip; the player is
/// built then too, so nothing is touched until a reply is spoken.
///
/// Every operation (enqueue, stop, the end-of-playlist handling) runs in
/// order on one chain, so a clip appended just as the playlist ended is
/// played rather than stranded.
///
/// Linux has no audio session (audio_session has no implementation there):
/// the default session steps are skipped and activation always succeeds.
///
/// A clip that reaches its end after playing for under half its length
/// (when that length is known and at least [silentCheckMinLength]) was not
/// heard: it ends as [ReplyClipPhase.silent]. libmpv with no audio device
/// does that: every clip "completes" within milliseconds, without error.
///
/// A clip has [ReplyClipPhase.started] when the player is playing it: its
/// playing state with the media ready, or — where [startNeedsProgress], by
/// default on Linux — its first position update past zero after that.
/// media_kit (Linux) reports playing and ready as soon as the file is loaded
/// and `play()` was asked for, BEFORE libmpv has opened its audio output;
/// a libmpv that never returns from opening it (T6 2026-10-22, F2: headless
/// Linux) then reports nothing more, and only a position that moves shows
/// the clip is under way. The reply speaker's start timeout
/// (`ReplySpeaker.playbackStartTimeout`) waits for this event.
///
/// A playlist that cannot start (the session refused audio focus, asked for
/// explicitly before each `play()`) fails at once. One that is not playing
/// for [systemPauseGrace] — it never got going, or the system paused it (an
/// interruption) — fails then: a transient interruption resumes by itself
/// well within it, and a permanent loss of focus would otherwise hold the
/// reply (and the mic's half-duplex mute) for good. Player states arrive
/// asynchronously, so the not-playing states from before `play()` only arm
/// that clock, which the first playing state stops.
class JustAudioReplyPlayer implements ReplyAudioPlayer {
  JustAudioReplyPlayer({
    AudioPlayer Function()? createPlayer,
    Future<void> Function()? configureSession,
    Future<bool> Function()? activateSession,
    Future<bool> Function()? deactivateSession,
    bool? releaseKeepsCapture,
    bool? startNeedsProgress,
    DateTime Function()? now,
    this.systemPauseGrace = const Duration(seconds: 5),
  }) : _now = now ?? DateTime.now,
       startNeedsProgress =
           startNeedsProgress ?? defaultTargetPlatform == TargetPlatform.linux,
       _createPlayer = createPlayer ?? AudioPlayer.new,
       _configureSession =
           configureSession ??
           (_noAudioSession ? _skipSession : _configureSpeechSession),
       _activateSession =
           activateSession ??
           (_noAudioSession ? _sessionless : _setSessionActive(true)),
       _deactivateSession =
           deactivateSession ??
           (_noAudioSession ? _sessionless : _setSessionActive(false)),
       _releaseKeepsCapture =
           releaseKeepsCapture ??
           defaultTargetPlatform == TargetPlatform.android;

  /// Linux: [AudioSession] would only reach a missing plugin.
  static bool get _noAudioSession =>
      defaultTargetPlatform == TargetPlatform.linux;

  static Future<void> _skipSession() async {}

  static Future<bool> _sessionless() async => true;

  static Future<void> _configureSpeechSession() async =>
      (await AudioSession.instance).configure(replyAudioSessionConfiguration);

  static Future<bool> Function() _setSessionActive(bool active) =>
      () async => (await AudioSession.instance).setActive(active);

  /// Shorter clips are never judged silent: too short to time.
  static const silentCheckMinLength = Duration(milliseconds: 300);

  final Duration systemPauseGrace;

  /// A clip has started only once its position moved past zero while
  /// playing (Linux's media_kit: see the class docs), not merely at its
  /// playing state.
  final bool startNeedsProgress;
  final DateTime Function() _now;
  final AudioPlayer Function() _createPlayer;
  final Future<void> Function() _configureSession;
  final Future<bool> Function() _activateSession;
  final Future<bool> Function() _deactivateSession;

  /// Giving the session back leaves a live capture running (Android: the
  /// recorder holds no audio focus).
  final bool _releaseKeepsCapture;

  /// The session was activated (focus taken) and not given back since.
  bool _sessionActive = false;
  Timer? _resumeTimer;
  final _events = StreamController<ReplyClipEvent>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  AudioPlayer? _player;
  Future<void> _chain = Future<void>.value();
  bool _disposed = false;

  /// The playlist loaded now, by path (playlist index = list index); empty
  /// once it finished, failed or was stopped.
  final List<String> _playlist = [];

  /// [_playlist]'s sources: just_audio sets each one's duration once known.
  final List<IndexedAudioSource> _sources = [];

  /// The index of the clip playing (or about to start) in [_playlist].
  int _current = 0;

  /// When the clip at [_current] started playing (its position zero, as
  /// best known); null until it has.
  DateTime? _startedAt;

  /// A playlist is loaded and neither finished nor stopped.
  bool get _running => _playlist.isNotEmpty;

  /// The first clip of this playlist has not reported its start yet.
  bool _awaitingStart = false;

  @override
  Stream<ReplyClipEvent> get clipEvents => _events.stream;

  @override
  Future<void> enqueue(String path, {required String mediaType}) =>
      _serial(() async {
        if (_disposed) return;
        if (!kAllowedAudioTypes.containsKey(mediaType)) {
          throw UnsupportedError('reply audio of type $mediaType');
        }
        final player = await _ensurePlayer();
        final source = AudioSource.file(path);
        if (!_running) {
          _playlist
            ..clear()
            ..add(path);
          _sources
            ..clear()
            ..add(source);
          _current = 0;
          _startedAt = null;
          _awaitingStart = true;
          try {
            await player.setAudioSources([source]);
          } catch (_) {
            _resetRun();
            rethrow;
          }
          if (!await _activateSession()) {
            // just_audio's play() would silently do nothing.
            debugPrint('[speaker] audio focus refused');
            _failRun();
            return;
          }
          _sessionActive = true;
          // Completes only when playback pauses or ends: never awaited here.
          unawaited(
            player.play().catchError((Object error) {
              debugPrint('[speaker] play failed: ${error.runtimeType}');
              _failRun();
            }),
          );
        } else {
          _playlist.add(path);
          _sources.add(source);
          await player.addAudioSource(source);
        }
      });

  @override
  Future<void> stop() => _serial(() async {
    final player = _player;
    _resetRun();
    if (player == null) return;
    await player.stop();
  });

  @override
  Future<void> release({required bool captureLive}) => _serial(() async {
    if (_disposed || _running || !_sessionActive) return;
    if (captureLive && !_releaseKeepsCapture) return;
    if (await _deactivateSession()) _sessionActive = false;
  });

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _resetRun();
    await _chain;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _player?.dispose();
    await _events.close();
  }

  Future<void> _serial(Future<void> Function() op) {
    final next = _chain.then((_) => op());
    _chain = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<AudioPlayer> _ensurePlayer() async {
    final existing = _player;
    if (existing != null) return existing;
    await _configureSession();
    final player = _createPlayer();
    _subscriptions
      ..add(player.currentIndexStream.listen(_onIndex))
      ..add(player.playerStateStream.listen(_onState))
      ..add(
        player.playbackEventStream.listen(
          _onPlaybackEvent,
          // Failures are the error stream's (below).
          onError: (Object _) {},
        ),
      )
      ..add(
        player.errorStream.listen((error) {
          debugPrint('[speaker] playback error ${error.code}');
          _failRun();
        }),
      );
    _player = player;
    return player;
  }

  void _resetRun() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _awaitingStart = false;
    _playlist.clear();
    _sources.clear();
    _current = 0;
    _startedAt = null;
  }

  void _emit(String path, ReplyClipPhase phase) {
    if (!_events.isClosed) _events.add(ReplyClipEvent(path, phase));
  }

  /// The clip at [_current] started playing, [position] ago: detected by a
  /// position update that came late, the audio it proves played still
  /// counts towards its length.
  void _started({Duration position = Duration.zero}) {
    _startedAt = _now().subtract(position);
    _emit(_playlist[_current], ReplyClipPhase.started);
  }

  /// The clip at [k] reached its end: [ReplyClipPhase.silent] when it played
  /// for under half its known length (a clip that never reported its start
  /// played for none of it), else [ReplyClipPhase.finished].
  void _ended(int k) {
    final length = _sources[k].duration;
    final startedAt = k == _current ? _startedAt : null;
    final played = startedAt == null
        ? Duration.zero
        : _now().difference(startedAt);
    final heard =
        length == null || length < silentCheckMinLength || played * 2 >= length;
    _emit(
      _playlist[k],
      heard ? ReplyClipPhase.finished : ReplyClipPhase.silent,
    );
  }

  /// The clip at [_current] is next, the one before it over: it starts at
  /// once, or on its first position update ([startNeedsProgress]). Until
  /// then it has played nothing: none of the clip before it counts.
  void _nextDue() {
    _startedAt = null;
    if (startNeedsProgress) {
      _awaitingStart = true;
    } else {
      _awaitingStart = false;
      _started();
    }
  }

  /// The playlist moved on: the clips before [index] finished.
  void _onIndex(int? index) {
    if (!_running || index == null || index <= _current) return;
    if (index >= _playlist.length) return;
    for (var k = _current; k < index; k++) {
      _ended(k);
    }
    _current = index;
    _nextDue();
  }

  void _onState(PlayerState state) {
    if (!_running) return;
    if (state.playing && state.processingState == ProcessingState.ready) {
      _resumeTimer?.cancel();
      _resumeTimer = null;
      if (_awaitingStart && !startNeedsProgress) {
        _awaitingStart = false;
        _started();
      }
    }
    if (state.processingState == ProcessingState.completed) {
      // Re-checked in order: a stale completion of an earlier playlist
      // finds the player loaded again and does nothing.
      unawaited(_serial(_onCompleted));
    } else if (!state.playing) {
      // Not our pause (that ends the run first): not started yet, or an
      // interruption.
      _resumeTimer ??= Timer(systemPauseGrace, () {
        _resumeTimer = null;
        if (!_running) return;
        debugPrint('[speaker] playback is not playing; giving up');
        _failRun();
      });
    }
  }

  /// [startNeedsProgress]: the clip at [_current] started once the player,
  /// playing it with its media ready, reports a position past zero.
  void _onPlaybackEvent(PlaybackEvent event) {
    if (!startNeedsProgress || !_running || !_awaitingStart) return;
    if (event.processingState != ProcessingState.ready ||
        event.currentIndex != _current ||
        event.updatePosition <= Duration.zero ||
        _player?.playing != true) {
      return;
    }
    _awaitingStart = false;
    _started(position: event.updatePosition);
  }

  /// The playlist reached its end. A clip appended just too late is played
  /// on; otherwise the run is over (paused, so the next run's `play()`
  /// takes the audio session again).
  Future<void> _onCompleted() async {
    final player = _player;
    if (player == null || !_running) return;
    if (player.processingState != ProcessingState.completed) return;
    final last = player.currentIndex ?? _current;
    for (var k = _current; k <= last; k++) {
      if (k < _playlist.length) _ended(k);
    }
    if (last + 1 < _playlist.length) {
      _current = last + 1;
      _nextDue();
      await player.seek(Duration.zero, index: _current);
      return;
    }
    _resetRun();
    await player.pause();
  }

  /// Everything of this playlist failed.
  void _failRun() {
    if (!_running) return;
    final lost = _playlist.sublist(_current);
    _resetRun();
    for (final path in lost) {
      _emit(path, ReplyClipPhase.failed);
    }
    final player = _player;
    if (player != null) unawaited(_serial(player.stop));
  }
}
