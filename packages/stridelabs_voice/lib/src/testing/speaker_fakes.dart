import 'dart:async';
import 'dart:io' show HttpException, SocketException;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import '../../stridelabs_voice.dart';

// The reply speaker's fakes, the union of lumen's and tapper's
// (`test/fakes/speaker_fakes.dart` in both apps) with D1 §8.4's changes:
// `extras` recorded and evaluated once per request; `reply` takes the media
// type and the advertised bound; `failStatus` takes the bound; one
// FakeTtsCall per send(); the player and the clip files take the media type;
// the new FakeTtsAuth (plus `pendingRetry` and `refreshes`, for the app's
// pending-retry guard). No Riverpod overrides: the speaker takes its ports.
// Public through `testing.dart`.

/// A few bytes standing in for an MP3 (an ID3 tag's start).
const List<int> kFakeMp3 = [0x49, 0x44, 0x33, 1, 2, 3];

/// One `POST /voice/tts` send the [FakeReplyTts] received; the test answers
/// it.
class FakeTtsCall {
  FakeTtsCall(this.text, this.voice, this.idempotencyKey, this.extras);

  final String text;
  final String voice;

  /// The sentence's `Idempotency-Key`: the same for a retry of it.
  final String idempotencyKey;

  /// The request's extras, read once when it was made: the same object for
  /// every send of the sentence.
  final Map<String, Object?> extras;
  final _reply = Completer<ReplyClip>();

  bool get answered => _reply.isCompleted;

  /// A 200 with [bytes] (a few fake MP3 bytes by default) of [mediaType],
  /// advertising [maxTextChars] when given.
  void reply([
    List<int> bytes = kFakeMp3,
    String mediaType = 'audio/mpeg',
    int? maxTextChars,
  ]) => _reply.complete(
    ReplyClip(Uint8List.fromList(bytes), mediaType, maxTextChars: maxTextChars),
  );

  /// The server answered [status] with [body] (`{"detail": …}` unless
  /// given: as the app's Dio hands it over, bytes, or anything a test
  /// needs), with a `Retry-After` of [retryAfter] and an
  /// `X-Voice-Tts-Max-Chars` of [maxTextChars] when given (raw, as the
  /// headers carry them).
  void failStatus(
    int status, {
    String? retryAfter,
    Object? body,
    int? maxTextChars,
  }) {
    final options = RequestOptions(path: '/voice/tts');
    _reply.completeError(
      DioException(
        requestOptions: options,
        response: Response<Object?>(
          requestOptions: options,
          statusCode: status,
          data: body ?? {'detail': 'nope'},
          headers: Headers.fromMap({
            if (retryAfter != null) 'retry-after': [retryAfter],
            if (maxTextChars != null) kTtsMaxCharsHeader: ['$maxTextChars'],
          }),
        ),
        type: DioExceptionType.badResponse,
      ),
    );
  }

  /// No connection: refused, or the host unreachable (a transport failure,
  /// retried once).
  void failNetwork() => _fail(DioExceptionType.connectionError);

  /// The connection reset mid-request, before any response (a transport
  /// failure, retried once).
  void failReset() => _fail(
    DioExceptionType.unknown,
    cause: const SocketException('Connection reset by peer'),
  );

  /// The response never came within Dio's receive timeout: slow, not lost
  /// (never retried).
  void failSlow() => _fail(DioExceptionType.receiveTimeout);

  /// The connection could not be made in time: slow, not refused (never
  /// retried).
  void failConnectTimeout() => _fail(DioExceptionType.connectionTimeout);

  /// The status line and headers arrived, then the body broke (a reset
  /// mid-body): the server's answer, not a lost connection (never
  /// retried).
  void failBodyLost() => _fail(
    DioExceptionType.unknown,
    cause: const HttpException('Connection closed while receiving data'),
    headersReceived: true,
  );

  /// As the app's Dio fails it: the transport was watched
  /// ([ResponseHeadersWatch]) and saw no headers, unless [headersReceived].
  void _fail(
    DioExceptionType type, {
    Object? cause,
    bool headersReceived = false,
  }) => _reply.completeError(
    DioException(
      requestOptions: RequestOptions(
        path: '/voice/tts',
        extra: {
          kResponseWatched: true,
          kResponseHeadersReceived: headersReceived,
        },
      ),
      type: type,
      error: cause,
    ),
  );
}

/// [ReplyTts] whose every send waits for the test ([FakeTtsCall]), or —
/// with [autoReply] — answers 200 at once. [calls] holds every send, a
/// retry included.
class FakeReplyTts implements ReplyTts {
  final List<FakeTtsCall> calls = [];
  bool autoReply = false;

  /// The app's extras, evaluated once per [request] (as
  /// [RelayTtsClient]'s are).
  Map<String, Object?> Function()? extras;

  /// How many requests (sentences) were made; each makes one or two
  /// [calls].
  int requests = 0;

  List<String> get texts => [for (final c in calls) c.text];

  FakeTtsCall get last => calls.last;

  @override
  ReplyTtsRequest request(
    String text, {
    required String voice,
    required String idempotencyKey,
  }) {
    requests++;
    return _FakeTtsRequest(
      this,
      text,
      voice,
      idempotencyKey,
      Map.unmodifiable(extras?.call() ?? const <String, Object?>{}),
    );
  }
}

class _FakeTtsRequest implements ReplyTtsRequest {
  _FakeTtsRequest(this._tts, this._text, this._voice, this._key, this.extras);

  final FakeReplyTts _tts;
  final String _text;
  final String _voice;
  final String _key;

  @override
  final Map<String, Object?> extras;

  @override
  Future<ReplyClip> send() {
    final call = FakeTtsCall(_text, _voice, _key, extras);
    _tts.calls.add(call);
    if (_tts.autoReply) call.reply();
    return call._reply.future;
  }
}

/// [TtsAuth] whose token is [expired] or not, and whose refreshes succeed
/// or fail as [refreshSucceeds] says.
class FakeTtsAuth implements TtsAuth {
  FakeTtsAuth({this.expired = false, this.refreshSucceeds = true});

  /// [refreshAhead] refreshes (and clears it, on success) when true.
  bool expired;

  /// The outcome of either refresh.
  bool refreshSucceeds;

  /// The app's own refresh retry is pending (lumen's
  /// `hasPendingRefreshRetry`): neither entry point starts a refresh;
  /// [refreshAhead] answers true (the held token goes out),
  /// [refreshAfterUnauthorized] false.
  bool pendingRetry = false;

  /// Holds every refresh open until completed (the delayed-refresh tests).
  Completer<void>? refreshGate;

  int aheadCalls = 0;
  int afterUnauthorizedCalls = 0;

  /// Refreshes started, by either entry point.
  int refreshes = 0;

  /// The extras each [refreshAfterUnauthorized] was given.
  final List<Map<String, Object?>> extrasSeen = [];

  @override
  Future<bool> refreshAhead() async {
    aheadCalls++;
    if (!expired || pendingRetry) return true;
    final ok = await _refresh();
    if (ok) expired = false;
    return ok;
  }

  @override
  Future<bool> refreshAfterUnauthorized(Map<String, Object?> extras) async {
    afterUnauthorizedCalls++;
    extrasSeen.add(extras);
    if (pendingRetry) return false;
    final ok = await _refresh();
    if (ok) expired = false;
    return ok;
  }

  Future<bool> _refresh() async {
    refreshes++;
    final gate = refreshGate;
    if (gate != null) await gate.future;
    return refreshSucceeds;
  }
}

/// [ReplyAudioPlayer] that plays nothing: the test moves playback on with
/// [finishHead]. A clip handed to an idle player starts at once (its
/// `started` event), the next starts when the one before it finishes.
class FakeReplyPlayer implements ReplyAudioPlayer {
  final _events = StreamController<ReplyClipEvent>.broadcast();

  /// Every clip ever enqueued, in order.
  final List<String> enqueued = [];

  /// Each enqueued clip's media type, in the same order.
  final List<String> enqueuedTypes = [];

  /// Clips enqueued and not finished (the head is playing).
  final List<String> queue = [];
  int stopCount = 0;
  bool disposed = false;

  /// Thrown by the next [enqueue] (a clip that cannot load).
  Object? enqueueError;

  /// Clips never report a start on their own (a stuck player, or one the
  /// test starts with [startHead]).
  bool silent = false;

  @override
  Stream<ReplyClipEvent> get clipEvents => _events.stream;

  @override
  Future<void> enqueue(String path, {required String mediaType}) async {
    final error = enqueueError;
    if (error != null) {
      enqueueError = null;
      throw error;
    }
    enqueued.add(path);
    enqueuedTypes.add(mediaType);
    queue.add(path);
    if (queue.length == 1 && !silent) {
      _events.add(ReplyClipEvent(path, ReplyClipPhase.started));
    }
  }

  /// The clip playing now reached its end, heard (or silent, with
  /// `heard: false`); the next one starts (unless [silent]).
  void finishHead({bool heard = true}) {
    final head = queue.removeAt(0);
    _events.add(
      ReplyClipEvent(
        head,
        heard ? ReplyClipPhase.finished : ReplyClipPhase.silent,
      ),
    );
    if (queue.isNotEmpty && !silent) {
      _events.add(ReplyClipEvent(queue.first, ReplyClipPhase.started));
    }
  }

  /// The clip playing now reports its start (a [silent] player's clips
  /// start only this way).
  void startHead() =>
      _events.add(ReplyClipEvent(queue.first, ReplyClipPhase.started));

  /// Playback failed (e.g. the clip could not be decoded).
  void failHead() =>
      _events.add(ReplyClipEvent(queue.first, ReplyClipPhase.failed));

  @override
  Future<void> stop() async {
    stopCount++;
    queue.clear();
  }

  /// Every [release] call's `captureLive`.
  final List<bool> releases = [];

  @override
  Future<void> release({required bool captureLive}) async =>
      releases.add(captureLive);

  @override
  Future<void> dispose() async {
    disposed = true;
    queue.clear();
    await _events.close();
  }
}

/// [ReplyClipFiles] in memory, its names from [prefix].
class FakeClipFiles implements ReplyClipFiles {
  FakeClipFiles({this.prefix = 'test-tts-'});

  final String prefix;
  int _next = 0;

  /// The clips stored now, by path.
  final Map<String, Uint8List> files = {};

  /// Every clip ever written, by path (kept after deletion).
  final Map<String, List<int>> written = {};

  /// Every clip's media type, by path (kept after deletion).
  final Map<String, String> types = {};
  final List<String> deleted = [];
  int sweeps = 0;

  /// Holds every write until completed (a slow or hung disk).
  Completer<void>? writeGate;

  @override
  Future<String> write(Uint8List bytes, {required String mediaType}) async {
    final gate = writeGate;
    if (gate != null) await gate.future;
    final extension = kAllowedAudioTypes[mediaType];
    if (extension == null) {
      throw ArgumentError.value(mediaType, 'mediaType', 'is not supported');
    }
    final path = 'mem/$prefix${_next++}$extension';
    files[path] = bytes;
    written[path] = List.of(bytes);
    types[path] = mediaType;
    return path;
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
    deleted.add(path);
  }

  @override
  Future<int> sweep() async {
    sweeps++;
    return 0;
  }
}
