import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../assembly/turn_assembler.dart';
import '../debug/voice_debug.dart';
import '../protocol/close_codes.dart';
import '../protocol/constants.dart';
import '../protocol/relay_events.dart';
import '../protocol/voice_limit.dart';
import 'mic_capture.dart';
import 'relay_channel.dart';
import 'voice_transport.dart';

/// Posts one finished utterance; returns the outcome word the transport
/// prints in `MVOICE utterance <word>` (`posted`, `queued` or `dropped`, the
/// app's names for what its turn coordinator did).
typedef UtteranceSink = String Function(VoiceUtterance utterance);

/// A bearer token for the relay's upgrade: the current one (refreshed first
/// when it is about to expire), or a refreshed one when [forceRefresh] (after
/// a 401). Null when signed out.
typedef AccessTokenSource =
    Future<String?> Function({required bool forceRefresh});

/// How many times one mic-on moves to the next candidate rate after the
/// server refused one at the upgrade (422, `PROTOCOL.md` §3.2).
const _maxRateRetries = 2;

/// [VoiceTransport] over the StrideLabs voice relay (`PROTOCOL.md` §2): the
/// microphone streamed to the app's `GET /voice/stream`, the relay's speech
/// events turned into utterances by a [TurnAssembler] and handed to
/// [UtteranceSink] (the app's turn coordinator posts them as voice turns).
/// Replies are spoken by the reply speaker, not here.
///
/// **The session is logical.** [connect] opens nothing, so it is ready at
/// once. The socket lives only while the mic is on: [enableMicrophone]
/// checks the permission, then starts capture (PCM16 mono, at the first of
/// [sampleRates] the device takes) AND opens the socket together; audio
/// captured before the relay's `ready` is buffered (the newest
/// [preReadyBuffer], oldest dropped), then everything is sent as
/// [frameDuration] frames in real time. [disableMicrophone] stops capture,
/// sends `{"type":"end"}`, waits up to [endWait] for the relay to deliver
/// the last transcript and close, and closes.
///
/// **The advertised facts** (`PROTOCOL.md` §3): each `ready` may carry the
/// server's `rates`, `encoding` and `lead_ms`. [sampleRates] puts the last
/// `ready`'s rates first (kept for this transport's lifetime), then 24000
/// and 16000; [lead] is a second under the last `ready`'s `lead_ms` (4 s
/// when it had none). At `ready`, the buffered audio is trimmed (oldest
/// first) to [lead] before it is sent. An `encoding` other than `pcm_s16le`
/// is a session this client cannot speak: it ends as `unavailable`, closing
/// 4104. An older server's bare `ready` keeps every default.
///
/// **Rates:** a capture refusal moves to the next candidate (and a rate the
/// microphone refused is not tried again by this transport); so does a 422
/// at the upgrade, at most twice per mic-on, after forgetting the kept list
/// (it may be an older deployment's). A revision-1 server takes both
/// default rates, so it never answers 422 to either.
///
/// **Upgrade failures** (the relay checks everything before the `101`): a
/// 401 refreshes the token and retries once; a 429 waits
/// [throttleRetryDelay] and retries once (the relay's 2 s admission interval
/// answers a quick re-open with 429 too, and the status alone cannot tell
/// the two apart, `PROTOCOL.md` §2.1); then 404/503 → `closedByServer` +
/// `unavailable`, 429 → `closedByServer` + `limitReached`, anything else →
/// `dropped`. No `ready` within [readyTimeout] → `dropped`.
///
/// **Closes while the mic is on:** 4000 → `sessionLimit`, 4001 →
/// `superseded`, 4002 → `limitReached` (each `closedByServer`), carrying the
/// spent allowance the relay's `limit` event named just before it
/// ([VoiceEnd.limit]); anything else → `dropped`. A refused upgrade's 429
/// carries none: the connector exposes only its status. A close after our
/// `end` is the normal ending: nothing is reported (the debug line
/// `MVOICE end_closed code=<code>` names its code). A remote end first
/// flushes what was already transcribed.
///
/// **Our close code** says why we left ([RelayClientCloseCode]): 1000 after
/// `end` (mic off); 4104 for a failure on this side (no `ready`, capture
/// failed or stopped while the mic was on, a failed capture start, a
/// recorder that could not be stopped at mic-off, an encoding this client
/// cannot speak); 4103 for a socket replaced by one at another rate; and
/// [disconnect]'s [VoiceDisconnectCause] otherwise: 4100 left the
/// conversation, 4101 paused, 4102 idle, 4103 disposed ([dispose]), 4104 a
/// failed start.
///
/// **Half-duplex:** driven by the reply player's transitions
/// ([speakerPlaying]), not by polling. Unless [interruptByVoice], the mic is
/// muted the moment playback starts and stays muted [speakerTail] after it
/// stops: every frame that ARRIVES meanwhile — whenever it was captured, so
/// a capture stall spanning a short reply is covered too — is replaced by
/// silence of the same size (the stream stays alive: the relay closes one
/// that stops sending), and no speech event reaches the assembler. A segment
/// open when the mute begins is cut there (its partial is what was said),
/// and one that STARTS during the mute is ignored to its `end_of_turn`.
///
/// **Keep-alive:** if capture stalls with the socket open, silence fills the
/// gap up to real time once it is [stallFill] behind (the relay closes a
/// stream that falls ten seconds behind); audio never runs more than [lead]
/// ahead of real time.
///
/// **Listening:** a user speech segment that is heard reports
/// `VoiceListening(true)` at its `speech_start` and `VoiceListening(false)`
/// when it closes (its `end_of_turn`, a half-duplex cut, mic-off, the
/// session's end).
///
/// **Clocks:** pacing, the stall fill, the lead cap, the half-duplex tail and
/// the assembler's windows run on a MONOTONIC clock ([monotonic], a
/// [Stopwatch] by default), so a wall-clock jump can neither burst audio nor
/// stall it. The wall clock ([now]) only stamps the debug lines.
class RelayVoiceTransport implements VoiceTransport {
  RelayVoiceTransport({
    required this._accessToken,
    required this._streamUri,
    required UtteranceSink onUtterance,
    ValueListenable<bool>? speakerPlaying,
    bool Function()? interruptByVoice,
    this._onSpeechStart,
    Stream<void>? transcriptCleared,
    MicCapture Function()? micFactory,
    RelayConnector? connector,
    VoiceDebugSink? debug,
    bool Function(String text) isUnfinished = isUnfinishedFragment,
    Duration mergeWindow = const Duration(milliseconds: 1500),
    Duration Function()? monotonic,
    DateTime Function()? now,
    this.readyTimeout = const Duration(seconds: 12),
    this.endWait = const Duration(seconds: 2),
    this.speakerTail = const Duration(milliseconds: 500),
    this.preReadyBuffer = const Duration(seconds: 3),
    this.throttleRetryDelay = const Duration(milliseconds: 2100),
    this.frameDuration = const Duration(milliseconds: 80),
    this.stallFill = const Duration(seconds: 2),
    this.releaseWaitTimeout = const Duration(seconds: 3),
  }) : _postUtterance = onUtterance,
       _speaker = speakerPlaying,
       _interruptByVoice = interruptByVoice ?? _never,
       _newMic = micFactory ?? RecordMicCapture.new,
       _connect = connector ?? connectRelay,
       _debug = debug ?? defaultVoiceDebugSink,
       _monotonic = monotonic ?? _stopwatch(),
       _now = now ?? DateTime.now {
    // The assembler's merge and flush windows and stt_ms, on the monotonic
    // clock too (its API takes instants).
    final epoch = DateTime.utc(2000);
    _assembler = TurnAssembler(
      onUtterance: _onUtterance,
      onPendingChanged: _onPendingChanged,
      onSegmentFlushed: _onSegmentFlushed,
      now: () => epoch.add(_monotonic()),
      mergeWindow: mergeWindow,
      isUnfinished: isUnfinished,
    );
    _clearedSub = transcriptCleared?.listen((_) => _onTranscriptCleared());
    _playing = speakerPlaying?.value ?? false;
    speakerPlaying?.addListener(_onSpeakerChanged);
  }

  static bool _never() => false;

  static Duration Function() _stopwatch() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// How long after the mic goes on the relay has to say `ready`.
  final Duration readyTimeout;

  /// How long mic-off waits, after `end`, for the relay's last events and
  /// its close.
  final Duration endWait;

  /// How long after the reply stops the mic is still silenced: echo, room
  /// reverb, the canceller catching up, and audio the recorder captured
  /// during the reply but delivers late.
  final Duration speakerTail;

  /// How much audio is kept while the socket opens (the oldest is dropped).
  final Duration preReadyBuffer;

  /// How long a 429 at the upgrade waits before its one retry: just past the
  /// relay's two-second admission interval.
  final Duration throttleRetryDelay;

  /// The length of each audio frame sent (80 ms: 3840 bytes at 24 kHz, 2560
  /// at 16 kHz).
  final Duration frameDuration;

  /// How far behind real time a stalled capture may fall before silence
  /// fills the gap.
  final Duration stallFill;

  /// The longest mic-on waits for the previous session's socket and
  /// recorder to be released.
  final Duration releaseWaitTimeout;

  final AccessTokenSource _accessToken;
  final Uri Function(int sampleRate) _streamUri;
  final UtteranceSink _postUtterance;
  final ValueListenable<bool>? _speaker;
  final bool Function() _interruptByVoice;
  final void Function()? _onSpeechStart;
  final MicCapture Function() _newMic;
  final RelayConnector _connect;
  final VoiceDebugSink _debug;
  final Duration Function() _monotonic;
  final DateTime Function() _now;

  late final TurnAssembler _assembler;
  StreamSubscription<void>? _clearedSub;

  final _events = StreamController<VoiceTransportEvent>.broadcast();
  final _remoteEnds = StreamController<VoiceEnd>.broadcast();

  /// Bumped by every disconnect, dispose and remote end: a session (and any
  /// await) that sees another value is stale.
  int _gen = 0;

  /// Bumped by every mic-off, disconnect and dispose: an [enableMicrophone]
  /// still waiting (on the permission, or on capture starting) that sees
  /// another value was turned off meanwhile, and starts nothing.
  int _micGen = 0;
  bool _connected = false;
  bool _disposed = false;

  /// The mic-on session, if the mic is on.
  _RelaySession? _session;

  /// The session ending after mic-off, while it delivers its last events.
  _RelaySession? _ending;
  Future<void>? _finishing;

  /// The last session's release (socket + recorder), which the next mic-on
  /// waits for: two recorders at once can fail on Android.
  Future<void>? _releasing;

  /// An [enableMicrophone] in flight, joined by concurrent callers of the
  /// same mic generation only.
  Future<MicEnableResult>? _enabling;
  int _enablingMicGen = -1;

  /// The last `ready`'s `rates` (null: none seen, the last had none, or a
  /// rate 422 made this transport forget them).
  List<int>? _advertisedRates;

  /// The last `ready`'s `lead_ms` (null: none seen, or the last had none).
  int? _advertisedLeadMs;

  /// Rates the microphone refused: not tried again by this transport.
  final Set<int> _micRefused = {};

  /// This transport reported listening for the open segment and has not
  /// reported its end.
  bool _listeningShown = false;

  /// Half-duplex: the reply is playing, and (monotonic) when the mute after
  /// it ends.
  bool _playing = false;
  Duration? _tailUntil;

  /// A `speech_start` reached the assembler and its `end_of_turn` has not.
  bool _segmentOpen = false;

  Duration? _micOnAt;

  @override
  Stream<VoiceTransportEvent> get events => _events.stream;

  @override
  Stream<VoiceEnd> get remoteEnds => _remoteEnds.stream;

  @override
  bool get isConnected => _connected;

  /// The capture rates a mic-on tries, best first (`PROTOCOL.md` §3.2): the
  /// last `ready`'s rates, then 24000 and 16000 where not already listed,
  /// minus the rates the microphone refused. Never empty: when every
  /// candidate was refused, the last one is tried again.
  List<int> get sampleRates {
    final candidates = <int>[...?_advertisedRates];
    for (final rate in kDefaultRelaySampleRates) {
      if (!candidates.contains(rate)) candidates.add(rate);
    }
    final usable = [
      for (final rate in candidates)
        if (!_micRefused.contains(rate)) rate,
    ];
    return usable.isEmpty ? [candidates.last] : usable;
  }

  /// How far ahead of real time this client lets audio run:
  /// [clientLeadFor] the last `ready`'s `lead_ms` (4 s until one is seen,
  /// and after one without it).
  Duration get lead => clientLeadFor(_advertisedLeadMs);

  @override
  Future<void> connect(String conversationId) async {
    if (_disposed) throw const VoiceConnectCancelled();
    _connected = true;
  }

  /// Ends the session; its socket (and one still delivering a mic-off's last
  /// events) closes with [cause]'s code ([RelayClientCloseCode.forCause]).
  @override
  Future<void> disconnect(VoiceDisconnectCause cause) async {
    _gen++;
    _micGen++;
    _connected = false;
    final session = _session;
    final ending = _ending;
    _session = null;
    _assembler.reset();
    _segmentOpen = false;
    _listeningShown = false;
    final code = RelayClientCloseCode.forCause(cause);
    await Future.wait([
      if (session != null) session.close(code),
      if (ending != null) ending.close(code),
    ]);
  }

  @override
  Future<MicEnableResult> enableMicrophone() {
    final micGen = _micGen;
    final pending = _enabling;
    // A reconnect never joins an enable a mic-off or disconnect superseded.
    if (pending != null && _enablingMicGen == micGen) return pending;
    final started = _enable(micGen);
    _enabling = started;
    _enablingMicGen = micGen;
    return started.whenComplete(() {
      if (identical(_enabling, started)) _enabling = null;
    });
  }

  Future<MicEnableResult> _enable(int micGen) async {
    if (!_connected) return MicEnableResult.notConnected;
    if (_session != null) return MicEnableResult.success;
    final gen = _gen;
    // The last mic-off's final transcript first (a new socket would
    // supersede it), and its socket and recorder released.
    final finishing = _finishing;
    if (finishing != null) await finishing;
    await _awaitRelease();
    if (micGen != _micGen) return MicEnableResult.cancelled;
    if (gen != _gen || !_connected) return MicEnableResult.notConnected;

    final mic = _newMic();
    final bool granted;
    try {
      granted = await mic.hasPermission();
    } catch (error) {
      debugPrint('RelayVoice: the mic permission check failed: $error');
      unawaited(_disposeMic(mic));
      return MicEnableResult.unavailable;
    }
    // Turned off (or torn down) while the permission was pending: no
    // capture, no socket.
    if (micGen != _micGen) {
      unawaited(_disposeMic(mic));
      return MicEnableResult.cancelled;
    }
    if (gen != _gen || !_connected) {
      unawaited(_disposeMic(mic));
      return MicEnableResult.notConnected;
    }
    if (!granted) {
      unawaited(_disposeMic(mic));
      return MicEnableResult.denied;
    }

    final session = _RelaySession(this, gen, micGen, mic, sampleRates.first);
    _session = session;
    _listeningShown = false;
    _segmentOpen = false;
    _micOnAt = _monotonic();
    _mvoice('mic_on');
    return session.start();
  }

  /// Mic-off: stops capture, sends `end`, waits for the last transcript,
  /// closes 1000.
  ///
  /// Throws the recorder's error when it could not be stopped: its audio may
  /// still be flowing, so the session has then ended as a client-side
  /// failure (4104, no `end`; what was transcribed is flushed) and the caller
  /// ends the voice session too (as [VoiceDisconnectCause.failed]). The next
  /// mic-on is not held up by it.
  @override
  Future<void> disableMicrophone() {
    // Supersedes an enable still waiting on the permission or the recorder.
    _micGen++;
    final session = _session;
    if (session == null) return _finishing ?? Future<void>.value();
    _session = null;
    _ending = session;
    _mvoice('mic_off');
    final finished = session.finish();
    // What the next mic-on waits for: never fails (the failure is this
    // caller's).
    late final Future<void> finishing;
    finishing = finished
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() {
          if (identical(_finishing, finishing)) {
            _finishing = null;
            _ending = null;
          }
          // No segment outlives the mic.
          if (session.gen == _gen) _endListening();
        });
    _finishing = finishing;
    return finishing.then((_) => finished);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _speaker?.removeListener(_onSpeakerChanged);
    try {
      await disconnect(VoiceDisconnectCause.disposed);
    } finally {
      unawaited(_clearedSub?.cancel());
      _assembler.dispose();
      await _events.close();
      await _remoteEnds.close();
    }
  }

  Future<void> _awaitRelease() async {
    final releasing = _releasing;
    if (releasing == null) return;
    await releasing.timeout(
      releaseWaitTimeout,
      onTimeout: () {
        debugPrint(
          'RelayVoice: the last session is still releasing after '
          '${releaseWaitTimeout.inSeconds}s; continuing without it',
        );
      },
    );
  }

  /// The session [session] ended on its own while the mic was on: what was
  /// transcribed is flushed to the conversation, then the end is reported
  /// with the transport already disconnected.
  ///
  /// The socket closes as a client-side failure (4104), never as a mic-off
  /// (1000, which means after `end`): the relay never said `ready`, capture
  /// failed or stopped, the session was one this client cannot speak, or the
  /// relay (or the network) already ended the socket, in which case the
  /// close sends nothing.
  void _endRemotely(_RelaySession session, VoiceEnd end) {
    if (!identical(_session, session) || session.gen != _gen) {
      unawaited(session.close(RelayClientCloseCode.clientFailure));
      return;
    }
    _session = null;
    _mvoice(
      'session_end',
      '${end.reason.name}${end.notice == null ? '' : ' ${end.notice!.name}'}',
    );
    _assembler.flush();
    _gen++;
    _connected = false;
    _segmentOpen = false;
    _listeningShown = false;
    unawaited(session.close(RelayClientCloseCode.clientFailure));
    if (!_remoteEnds.isClosed) _remoteEnds.add(end);
  }

  /// The reply player started or stopped. Started: muted at once, and a
  /// segment open now is cut — the words before the reply are kept (its
  /// partial), the rest is not heard. Stopped: muted for [speakerTail] more.
  void _onSpeakerChanged() {
    final playing = _speaker?.value ?? false;
    if (playing == _playing) return;
    _playing = playing;
    if (!playing) {
      _tailUntil = _monotonic() + speakerTail;
      _mvoice('reply_stopped');
      return;
    }
    _tailUntil = null;
    _mvoice('reply_playing');
    if (_interruptByVoice() || !_segmentOpen) return;
    _segmentOpen = false;
    _assembler.flush();
    _endListening();
  }

  /// The assembler closed the open segment without its `end_of_turn` (its
  /// fallback flush): the segment, and its listening, are over.
  void _onSegmentFlushed() {
    if (_disposed) return;
    _segmentOpen = false;
    _endListening();
  }

  /// The heard segment closed: its listening is over.
  void _endListening() {
    if (!_listeningShown) return;
    _listeningShown = false;
    _emit(const VoiceListening(false));
  }

  /// Half-duplex: whether the mic is silenced now — the reply is playing,
  /// or stopped less than [speakerTail] ago — unless "Interrupt by voice".
  bool _halfDuplexMuted() {
    if (_interruptByVoice()) return false;
    if (_playing) return true;
    final until = _tailUntil;
    return until != null && _monotonic() < until;
  }

  void _onRelayEvent(_RelaySession session, RelayEvent event) {
    if (session.gen != _gen) return;
    switch (event) {
      case RelayReady():
        return; // The session's own.
      case RelayError(:final code, :final limit):
        _mvoice(
          'relay_error',
          '${code.wire}${limit == null ? '' : ' scope=${limit.scope.wire}'}',
        );
        return;
      case RelaySpeechStart():
        if (_halfDuplexMuted()) {
          session.suppressing = true;
          _mvoice('speech_start', 'ignored (muted)');
          return;
        }
        session.suppressing = false;
        _segmentOpen = true;
        _assembler.speechStart();
        _mvoice('speech_start');
        if (session.micOn) {
          _listeningShown = true;
          _emit(const VoiceListening(true));
        }
        _onSpeechStart?.call();
        return;
      case RelaySpeechEnd() || RelayPartial() || RelayEndOfTurn():
        break;
    }
    // The rest of a segment: never heard while muted, nor at all when the
    // segment began muted.
    if (_halfDuplexMuted() || session.suppressing) {
      if (event is RelayEndOfTurn) session.suppressing = false;
      return;
    }
    switch (event) {
      case RelaySpeechEnd():
        _assembler.speechEnd();
      case RelayPartial(:final text):
        _assembler.partial(text);
      case RelayEndOfTurn(:final text):
        _segmentOpen = false;
        _mvoice('end_of_turn');
        _assembler.endOfTurn(text);
        _endListening();
      default:
        break;
    }
  }

  void _onUtterance(VoiceUtterance utterance) {
    if (_disposed) return;
    final outcome = _postUtterance(utterance);
    _mvoice('utterance', '$outcome stt_ms=${utterance.sttMs}');
  }

  void _onPendingChanged(String pending) =>
      _emit(VoicePendingTranscript(pending));

  /// The app dropped its trailing transcript bubble (on its `thinking` and
  /// on another turn's final reply): text still pending here is shown again.
  void _onTranscriptCleared() {
    if (_disposed) return;
    final pending = _assembler.pendingDisplay;
    if (pending.isNotEmpty) _emit(VoicePendingTranscript(pending));
  }

  void _emit(VoiceTransportEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// A `ready` the session accepted: its advertised facts replace the last
  /// ones (an absent fact is its default again).
  void _adopt(RelayReady ready) {
    final rates = ready.rates;
    // A rate whose frame would hold no sample cannot be sent at.
    _advertisedRates = rates != null && rates.every((r) => _frameBytesAt(r) > 0)
        ? rates
        : null;
    _advertisedLeadMs = ready.leadMs;
  }

  /// The bytes of one [frameDuration] frame at [rate]: whole samples, so
  /// always even.
  int _frameBytesAt(int rate) =>
      (rate * frameDuration.inMicroseconds ~/ Duration.microsecondsPerSecond) *
      2;

  /// Debug-only timing lines (`MVOICE <event>[ <detail>] t=… +…ms`, the
  /// vocabulary of [kMvoiceEvents]): event names, codes and times — never
  /// transcript text or tokens.
  void _mvoice(String event, [String? detail]) {
    assert(kMvoiceEvents.contains(event), 'MVOICE $event is not pinned');
    final since = _micOnAt;
    final offset = since == null
        ? ''
        : ' +${(_monotonic() - since).inMilliseconds}ms';
    _debug(
      'MVOICE $event${detail == null ? '' : ' $detail'} '
      't=${_now().millisecondsSinceEpoch}$offset',
    );
  }

  static Future<void> _disposeMic(MicCapture mic) async {
    try {
      await mic.dispose();
    } catch (error) {
      debugPrint('RelayVoice: releasing the recorder failed: $error');
    }
  }
}

enum _Phase { opening, ready, closed }

/// A recorder's failure to stop.
typedef _StopFailure = ({Object error, StackTrace stackTrace});

/// One mic-on: the capture, the socket (re-opened for a retry or a rate
/// change), the frames, and the ending.
class _RelaySession {
  _RelaySession(this.t, this.gen, this.micGen, this.mic, this.rate)
    : tried = {rate};

  final RelayVoiceTransport t;
  final int gen;

  /// The mic generation this mic-on belongs to (see
  /// [RelayVoiceTransport._micGen]).
  final int micGen;
  final MicCapture mic;

  /// The rate capture and the socket are at (or moving to).
  int rate;

  /// Every rate this mic-on has been at: a rate change goes to the first
  /// candidate not in it.
  final Set<int> tried;

  /// How many times a 422 at the upgrade moved this mic-on to another rate.
  int rateRetries = 0;

  _Phase phase = _Phase.opening;

  /// False from [finish] on: a close is then the normal ending.
  bool micOn = true;

  /// Captured audio is accepted.
  bool capturing = false;

  /// Capture started (its stream is being read) at some point.
  bool captureStarted = false;

  /// A [_recapture] in flight (its own capture start follows [rate]); mic-off
  /// joins it, and learns whether the recorder would stop.
  Future<_StopFailure?>? recapture;

  /// A segment that started while the mic was silenced: ignored to its end.
  bool suppressing = false;

  /// The spent allowance the relay's `limit` event named, for the 4002
  /// close that follows it.
  VoiceLimit? limit;

  RelayChannel? channel;
  StreamSubscription<Object?>? channelSub;
  StreamSubscription<Uint8List>? micSub;
  Future<Stream<Uint8List>>? micStart;

  /// Completes when the capture stream being read ends.
  Completer<void> micDone = Completer<void>();

  /// Bumped per socket attempt; an attempt that sees another value stops.
  int attempt = 0;

  /// Completes at `ready`, or when the socket (or its open) is over.
  Completer<void> readyOrDone = Completer<void>();

  /// Completes when the socket is over (the relay closed it, or we did).
  Completer<void> socketDone = Completer<void>();

  final ListQueue<Uint8List> preReady = ListQueue<Uint8List>();
  int preReadyBytes = 0;
  final BytesBuilder carry = BytesBuilder();

  /// When this socket said `ready`, on the transport's monotonic clock.
  Duration? readyAt;
  int sentBytes = 0;
  bool endSent = false;
  Timer? readyTimer;
  Timer? stallTimer;
  Future<void>? closing;

  int get bytesPerSecond => rate * 2;

  /// The bytes of [duration] of audio at [rate].
  int _bytesIn(Duration duration) =>
      bytesPerSecond * duration.inMilliseconds ~/ 1000;

  /// Whole samples, so always even.
  int get frameBytes => t._frameBytesAt(rate);

  bool get live => phase != _Phase.closed && gen == t._gen;

  /// The first candidate rate this mic-on has not been at; null when none
  /// is left.
  int? _nextRate() {
    for (final candidate in t.sampleRates) {
      if (!tried.contains(candidate)) return candidate;
    }
    return null;
  }

  /// Moves this mic-on to [next]: a socket at the new rate replaces the
  /// current one (whose upgrade was refused, or which the device cannot
  /// feed).
  void _moveTo(int next) {
    rate = next;
    tried.add(next);
    _reopen();
  }

  Future<MicEnableResult> start() async {
    _armReadyDeadline();
    unawaited(_open());

    final stream = await _startCapture();
    // Turned off meanwhile: mic-off's finish() owns the session now; a
    // disconnect or dispose already closed it. Either way the recorder that
    // may have started is released by the close, never read.
    if (!micOn) return MicEnableResult.cancelled;
    // The close that superseded it (a disconnect or dispose) already chose
    // the code; the first close's is the one sent.
    if (micGen != t._micGen) {
      await close(RelayClientCloseCode.micOff);
      return MicEnableResult.cancelled;
    }
    if (!live) {
      // Ended remotely meanwhile (already closed, as a failure).
      await close(RelayClientCloseCode.clientFailure);
      return MicEnableResult.notConnected;
    }
    if (stream == null) {
      // Capture could not start at any rate: a failed start.
      if (identical(t._session, this)) t._session = null;
      await close(RelayClientCloseCode.clientFailure);
      return MicEnableResult.unavailable;
    }
    _listen(stream);
    return MicEnableResult.success;
  }

  /// Starts capture at [rate]. A rate the device refuses moves this mic-on
  /// to the next candidate; a recorder that started at a rate the server
  /// refused meanwhile (a 422 moved [rate]) is stopped and started again at
  /// the new one. Null when no rate could be captured, or the session ended.
  Future<Stream<Uint8List>?> _startCapture() async {
    while (live && micOn) {
      final at = rate;
      final Stream<Uint8List> stream;
      try {
        final starting = mic.start(at);
        micStart = starting;
        stream = await starting;
      } catch (error) {
        debugPrint('RelayVoice: capture at $at Hz failed: $error');
        t._mvoice('capture_refused', 'rate=$at');
        t._micRefused.add(at);
        // A 422 may have moved the socket on already.
        if (rate != at) continue;
        final next = _nextRate();
        if (next == null) return null;
        _moveTo(next);
        continue;
      }
      if (rate == at || !live || !micOn) return stream;
      if (await _stopMic() != null) return null;
    }
    return null;
  }

  /// Reads [stream], the capture at [rate].
  void _listen(Stream<Uint8List> stream) {
    capturing = true;
    captureStarted = true;
    micSub = stream.listen(
      _onAudio,
      onError: (Object error) => _onCaptureEnded('failed: $error'),
      onDone: () => _onCaptureEnded('ended'),
    );
  }

  /// The server refused the rate capture is running at (a 422 moved
  /// [rate]): capture again at the new one before its socket says `ready`.
  /// Nothing captured at the old rate is sent.
  ///
  /// Its result is the recorder's failure to stop, for a mic-off that came
  /// meanwhile ([finish] joins it): the old recorder's, or that of one the
  /// move started after the mic-off, which is then stopped unread. With the
  /// mic still on, a failure ends the session here instead.
  Future<_StopFailure?> _recapture() async {
    try {
      return await _moveCapture();
    } finally {
      recapture = null;
    }
  }

  Future<_StopFailure?> _moveCapture() async {
    capturing = false;
    final sub = micSub;
    micSub = null;
    if (sub != null) unawaited(sub.cancel());
    micDone = Completer<void>();
    final failure = await _stopMic();
    if (failure != null) {
      if (micOn && live) _fail(const VoiceEnd(VoiceEndReason.dropped));
      return failure;
    }
    if (!live || !micOn) return null;
    final stream = await _startCapture();
    if (!live) return null;
    // Mic-off while the recorder started: it runs unread, so it is stopped
    // here, and mic-off learns whether it would.
    if (!micOn) return stream == null ? null : await _stopMic();
    if (stream == null) {
      debugPrint('RelayVoice: capture could not move to $rate Hz');
      _fail(const VoiceEnd(VoiceEndReason.dropped));
      return null;
    }
    _listen(stream);
    return null;
  }

  /// Mic-off: the last audio, `end`, the last events, then the close (1000).
  /// A recorder that cannot be stopped ends it as a failure instead (4104,
  /// no `end`), and its error is rethrown.
  Future<void> finish() async {
    micOn = false;
    // A capture moving to another rate (after a 422): its recorder stop is
    // this mic-off's too.
    final moving = recapture;
    if (moving != null) {
      final moveFailure = await moving;
      if (moveFailure != null) {
        if (gen == t._gen) t._assembler.flush();
        await close(RelayClientCloseCode.clientFailure);
        Error.throwWithStackTrace(moveFailure.error, moveFailure.stackTrace);
      }
    }
    final recorderStarted = await _awaitMicStart();
    // Off before capture began: nothing was said, so nothing to send. But a
    // recorder whose start was still pending at mic-off may have started
    // since ([start] then leaves it unread): it is stopped here, and one
    // that cannot be stopped is a failure, as below (4104, never 1000).
    if (!captureStarted) {
      final stopFailure = recorderStarted && closing == null
          ? await _stopMic()
          : null;
      if (stopFailure != null) {
        await close(RelayClientCloseCode.clientFailure);
        Error.throwWithStackTrace(stopFailure.error, stopFailure.stackTrace);
      }
      await close(RelayClientCloseCode.micOff);
      return;
    }
    final stopFailure = await _stopCapture();
    if (stopFailure != null) {
      // The recorder could not be turned off: a failure on this side, never
      // the normal ending (no `end`, no 1000). What was transcribed stands.
      if (gen == t._gen) t._assembler.flush();
      await close(RelayClientCloseCode.clientFailure);
      Error.throwWithStackTrace(stopFailure.error, stopFailure.stackTrace);
    }
    // Speech buffered before `ready` is still worth sending.
    if (phase == _Phase.opening) await readyOrDone.future;
    final socket = channel;
    if (phase == _Phase.ready && live && socket != null) {
      stallTimer?.cancel();
      socket.sendText(kRelayEndFrame);
      endSent = true;
      t._mvoice('end_sent');
      t._assembler.micOff();
      await socketDone.future.timeout(t.endWait, onTimeout: () {});
    }
    // A segment that never completed: its partial is what was said.
    if (gen == t._gen) t._assembler.flush();
    await close(RelayClientCloseCode.micOff);
  }

  /// The code this session closed with (the first [close]'s); null while
  /// open. A socket whose upgrade lands after the close gets it too.
  int? closeCode;

  /// Ends everything at once, the socket closing with [code]
  /// ([RelayClientCloseCode]). Idempotent; later calls share the first (and
  /// its code).
  Future<void> close(int code) => closing ??= _close(code);

  Future<void> _close(int code) async {
    closeCode = code;
    phase = _Phase.closed;
    attempt++;
    capturing = false;
    readyTimer?.cancel();
    stallTimer?.cancel();
    if (!readyOrDone.isCompleted) readyOrDone.complete();
    if (!socketDone.isCompleted) socketDone.complete();
    final socket = _detachSocket();
    final captureSub = micSub;
    micSub = null;
    // Cancelling stops delivery at once; its future only reports the
    // source's own cleanup, which nothing here waits on.
    if (captureSub != null) unawaited(captureSub.cancel());
    final release = Future.wait([
      if (socket != null) socket.close(code),
      _releaseMic(),
    ]).then<void>((_) {}, onError: (Object _) {});
    t._releasing = release;
    await release;
  }

  /// Stops delivery from the current socket and forgets it; the caller
  /// closes what is returned.
  RelayChannel? _detachSocket() {
    final socketSub = channelSub;
    final socket = channel;
    channelSub = null;
    channel = null;
    if (socketSub != null) unawaited(socketSub.cancel());
    return socket;
  }

  Future<void> _releaseMic() async {
    await _awaitMicStart();
    await _stopMic();
    await RelayVoiceTransport._disposeMic(mic);
  }

  /// Waits out a recorder start in flight; whether one started (one that
  /// failed, or none at all, left nothing to stop).
  Future<bool> _awaitMicStart() async {
    final starting = micStart;
    if (starting == null) return false;
    try {
      await starting;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Stops the recorder; its failure (logged) or null.
  Future<_StopFailure?> _stopMic() async {
    try {
      await mic.stop();
      return null;
    } catch (error, stackTrace) {
      debugPrint('RelayVoice: stopping capture failed: $error');
      return (error: error, stackTrace: stackTrace);
    }
  }

  /// Stops capture for [finish], keeping the audio already delivered (and
  /// the remainder shorter than a frame, sent as a final short frame). The
  /// recorder's failure to stop, if it failed (then nothing more is taken
  /// from it, or sent).
  Future<_StopFailure?> _stopCapture() async {
    await _awaitMicStart();
    _StopFailure? failure;
    if (capturing) {
      failure = await _stopMic();
      // The recorder delivers what it still held, then ends its stream.
      if (failure == null) {
        await micDone.future.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () {},
        );
      }
    }
    capturing = false;
    final sub = micSub;
    micSub = null;
    if (sub != null) unawaited(sub.cancel());
    if (failure != null) return failure;
    final rest = carry.takeBytes();
    final even = rest.length & ~1;
    if (even > 0 && phase != _Phase.closed) {
      _onFrame(Uint8List.sublistView(rest, 0, even));
    }
    return null;
  }

  /// The `ready` deadline of the socket being opened now.
  void _armReadyDeadline() {
    readyTimer?.cancel();
    readyTimer = Timer(t.readyTimeout, _onReadyTimeout);
  }

  void _onCaptureEnded(String how) {
    if (!micDone.isCompleted) micDone.complete();
    if (!capturing || !micOn || !live) return;
    debugPrint('RelayVoice: capture $how while the mic was on');
    _fail(const VoiceEnd(VoiceEndReason.dropped));
  }

  /// The socket attempt loop: one retry after a 401 (with a refreshed
  /// token) and one after a 429; a 422 moves this mic-on to the next rate
  /// (at most twice); then the failure is mapped and reported.
  Future<void> _open() async {
    final mine = ++attempt;
    bool stale() => attempt != mine || !live;
    var forceRefresh = false;
    var retried401 = false;
    var retried429 = false;
    while (true) {
      String? token;
      try {
        token = await t._accessToken(forceRefresh: forceRefresh);
      } catch (error) {
        debugPrint('RelayVoice: no access token: $error');
      }
      // One refresh per 401: a later retry (a 429's) uses the token as is.
      forceRefresh = false;
      if (stale()) return;
      final RelayChannel socket;
      try {
        socket = await t._connect(
          t._streamUri(rate),
          headers: {if (token != null) 'Authorization': 'Bearer $token'},
        );
      } on RelayUpgradeException catch (error) {
        if (stale()) return;
        final status = error.statusCode;
        t._mvoice('upgrade_refused', 'status=${status ?? '-'}');
        if (status == 401 && !retried401) {
          retried401 = true;
          forceRefresh = true;
          continue;
        }
        if (status == 429 && !retried429) {
          retried429 = true;
          await Future<void>.delayed(t.throttleRetryDelay);
          if (stale()) return;
          continue;
        }
        if (status == 422 && _rateRefused()) return;
        _fail(_upgradeEnd(status));
        return;
      } catch (error) {
        if (stale()) return;
        debugPrint('RelayVoice: the relay could not be reached: $error');
        _fail(const VoiceEnd(VoiceEndReason.dropped));
        return;
      }
      if (stale()) {
        // Landed after the session closed (with that close's code), or after
        // a rate change replaced this attempt.
        unawaited(
          socket.close(closeCode ?? RelayClientCloseCode.disposedOrReplaced),
        );
        return;
      }
      channel = socket;
      channelSub = socket.messages.listen(
        _onMessage,
        onError: (Object _) {}, // The close that follows decides.
        onDone: _onSocketDone,
      );
      return;
    }
  }

  /// The server does not take [rate] (a 422 at the upgrade): the rates an
  /// earlier `ready` advertised may be an older deployment's, so they are
  /// forgotten, and this mic-on moves to the next candidate — capture too,
  /// when it already runs. False when this mic-on has moved twice already,
  /// or no candidate is left: the 422 then ends it.
  bool _rateRefused() {
    if (rateRetries >= _maxRateRetries) return false;
    t._advertisedRates = null;
    final next = _nextRate();
    if (next == null) return false;
    rateRetries++;
    t._mvoice('rate_retry', 'rate=$next');
    _moveTo(next);
    // A recorder still starting is moved by the capture start in flight.
    if (captureStarted && recapture == null) recapture = _recapture();
    return true;
  }

  /// This mic-on moved to another rate: the socket opened for the old one —
  /// even one already `ready` — is dropped and a new one opened, with none
  /// of the old socket's state: its pacing starts from zero at the new
  /// `ready`, its keep-alive is stopped, and it has its own `ready`
  /// deadline.
  void _reopen() {
    final socket = _detachSocket();
    if (socket != null) {
      unawaited(socket.close(RelayClientCloseCode.disposedOrReplaced));
    }
    phase = _Phase.opening;
    readyAt = null;
    sentBytes = 0;
    endSent = false;
    stallTimer?.cancel();
    stallTimer = null;
    // Nothing captured at the old rate is sent: sizes are per rate.
    preReady.clear();
    preReadyBytes = 0;
    carry.clear();
    if (readyOrDone.isCompleted) readyOrDone = Completer<void>();
    if (socketDone.isCompleted) socketDone = Completer<void>();
    _armReadyDeadline();
    unawaited(_open());
  }

  static VoiceEnd _upgradeEnd(int? status) => switch (status) {
    401 => const VoiceEnd(VoiceEndReason.closedByServer),
    404 || 503 => const VoiceEnd(
      VoiceEndReason.closedByServer,
      VoiceEndNotice.unavailable,
    ),
    429 => const VoiceEnd(
      VoiceEndReason.closedByServer,
      VoiceEndNotice.limitReached,
    ),
    _ => const VoiceEnd(VoiceEndReason.dropped),
  };

  /// What close [code] ends the session as; a 4002 carries [limit], the
  /// `limit` event's spent allowance, if one came.
  static VoiceEnd _closeEnd(int? code, VoiceLimit? limit) => switch (code) {
    RelayCloseCode.sessionLimit => const VoiceEnd(
      VoiceEndReason.closedByServer,
      VoiceEndNotice.sessionLimit,
    ),
    RelayCloseCode.superseded => const VoiceEnd(
      VoiceEndReason.closedByServer,
      VoiceEndNotice.superseded,
    ),
    RelayCloseCode.limit => VoiceEnd(
      VoiceEndReason.closedByServer,
      VoiceEndNotice.limitReached,
      limit,
    ),
    _ => const VoiceEnd(VoiceEndReason.dropped),
  };

  /// The socket (or its open) failed: reported as a remote end while the
  /// mic is on; after mic-off it only ends the session.
  ///
  /// Either way the socket closes as a client-side failure (4104): no `end`
  /// was sent (see [RelayVoiceTransport._endRemotely]).
  void _fail(VoiceEnd end) {
    if (micOn && live && identical(t._session, this)) {
      t._endRemotely(this, end);
    } else {
      unawaited(close(RelayClientCloseCode.clientFailure));
    }
  }

  void _onReadyTimeout() {
    if (phase != _Phase.opening || !live) return;
    t._mvoice('ready_timeout');
    _fail(const VoiceEnd(VoiceEndReason.dropped));
  }

  void _onMessage(Object? message) {
    if (!live || message is! String) return;
    final event = RelayEvent.parse(message);
    if (event == null) return;
    if (event is RelayReady) {
      _onReady(event);
      return;
    }
    if (event case RelayError(code: RelayErrorCode.limit, :final limit?)) {
      this.limit = limit;
    }
    t._onRelayEvent(this, event);
  }

  void _onReady(RelayReady ready) {
    if (phase != _Phase.opening) return;
    final encoding = ready.encoding;
    if (encoding != null && encoding != kPcmS16le) {
      // A session in an encoding this client cannot speak (`PROTOCOL.md`
      // §3.2): nothing is sent, and nothing it advertised is kept.
      t._mvoice('ready_refused', 'reason=encoding');
      _fail(
        const VoiceEnd(
          VoiceEndReason.closedByServer,
          VoiceEndNotice.unavailable,
        ),
      );
      return;
    }
    t._adopt(ready);
    phase = _Phase.ready;
    readyAt = t._monotonic();
    readyTimer?.cancel();
    // The buffered audio goes out at once: no more of it than the lead
    // allows, the oldest dropped (none at a lead of 4 s or more, since the
    // buffer holds at most [RelayVoiceTransport.preReadyBuffer]).
    final cap = _bytesIn(t.lead);
    while (preReadyBytes > cap && preReady.isNotEmpty) {
      preReadyBytes -= preReady.removeFirst().length;
    }
    t._mvoice(
      'ready',
      'rate=$rate buffered_ms=${preReadyBytes * 1000 ~/ bytesPerSecond} '
          'lead_ms=${ready.leadMs ?? kDefaultRelayLeadMs}',
    );
    while (preReady.isNotEmpty) {
      _send(preReady.removeFirst());
    }
    preReadyBytes = 0;
    stallTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _fillStall(),
    );
    if (!readyOrDone.isCompleted) readyOrDone.complete();
  }

  void _onSocketDone() {
    final code = channel?.closeCode;
    if (!socketDone.isCompleted) socketDone.complete();
    if (!readyOrDone.isCompleted) readyOrDone.complete();
    // The normal ending: the relay closed after our `end` (1000 when all is
    // well).
    if (live && !micOn && endSent) {
      t._mvoice('end_closed', 'code=${code ?? '-'}');
    }
    // Closed by us (or stale), or the normal ending after mic-off.
    if (!live || !micOn) return;
    t._mvoice('socket_closed', 'code=${code ?? '-'}');
    _fail(_closeEnd(code, limit));
  }

  void _onAudio(Uint8List chunk) {
    if (!capturing || phase == _Phase.closed) return;
    carry.add(chunk);
    final size = frameBytes;
    if (carry.length < size) return;
    final bytes = carry.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= size) {
      _onFrame(Uint8List.sublistView(bytes, offset, offset + size));
      offset += size;
    }
    if (offset < bytes.length) carry.add(Uint8List.sublistView(bytes, offset));
  }

  void _onFrame(Uint8List frame) {
    final out = t._halfDuplexMuted() ? Uint8List(frame.length) : frame;
    if (phase == _Phase.ready) {
      _send(out);
    } else {
      _buffer(out);
    }
  }

  /// Pre-`ready`: keep the newest [RelayVoiceTransport.preReadyBuffer] of
  /// audio.
  void _buffer(Uint8List frame) {
    preReady.addLast(frame);
    preReadyBytes += frame.length;
    final cap = _bytesIn(t.preReadyBuffer);
    while (preReadyBytes > cap) {
      preReadyBytes -= preReady.removeFirst().length;
    }
  }

  /// Real time since `ready`, as bytes of audio — monotonic, so never
  /// negative and never jumping.
  int _elapsedBytes() {
    final ready = readyAt;
    if (ready == null) return 0;
    return _bytesIn(t._monotonic() - ready);
  }

  /// Sends one frame; false when it was not sent (no socket, after `end`,
  /// or past [RelayVoiceTransport.lead]).
  bool _send(Uint8List frame) {
    final socket = channel;
    if (endSent || socket == null || phase != _Phase.ready) return false;
    if (sentBytes + frame.length > _elapsedBytes() + _bytesIn(t.lead)) {
      return false;
    }
    socket.sendAudio(frame);
    sentBytes += frame.length;
    return true;
  }

  /// Capture stalled: fill the gap with silence, up to real time.
  void _fillStall() {
    if (phase != _Phase.ready || endSent || !live) return;
    final due = _elapsedBytes();
    if (due - sentBytes <= _bytesIn(t.stallFill)) return;
    final size = frameBytes;
    var filled = 0;
    while (sentBytes + size <= due && _send(Uint8List(size))) {
      filled++;
    }
    t._mvoice('stall_filled', 'frames=$filled');
  }
}
