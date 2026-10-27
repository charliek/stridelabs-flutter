import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../stridelabs_voice.dart';

// The relay's fakes, the union of lumen's and tapper's
// (`test/fakes/relay_fakes.dart` in both apps) with D1 §8.4's changes: the
// pacing lead a parameter, `ready()` with the advertised fields, `sendRaw`,
// and the server's `acceptedRates`. Public through `testing.dart`.

/// Stands in for `package:record`: a permission answer, per-rate refusals,
/// and a chunk stream the test feeds.
class FakeMicCapture implements MicCapture {
  FakeMicCapture({this.permission = true, Set<int>? refusedRates})
    : refusedRates = refusedRates ?? {};

  bool permission;
  Object? permissionError;
  final Set<int> refusedRates;

  /// Holds [hasPermission] until completed (the OS prompt still up).
  Completer<void>? permissionGate;

  /// Holds [start] until completed (a slow recorder start).
  Completer<void>? startGate;

  /// Thrown by every [stop] (a recorder that cannot be turned off), which
  /// then leaves capture running.
  Object? stopError;

  /// Holds [stop] until completed (a slow recorder stop).
  Completer<void>? stopGate;

  final startedRates = <int>[];
  int stopCount = 0;
  int disposeCount = 0;
  StreamController<Uint8List>? _chunks;

  /// Capture is running and its stream is open.
  bool get capturing => _chunks != null && !_chunks!.isClosed;

  @override
  Future<bool> hasPermission() async {
    final gate = permissionGate;
    if (gate != null) await gate.future;
    final error = permissionError;
    if (error != null) throw error;
    return permission;
  }

  @override
  Future<Stream<Uint8List>> start(int sampleRate) async {
    startedRates.add(sampleRate);
    final gate = startGate;
    if (gate != null) await gate.future;
    if (refusedRates.contains(sampleRate)) {
      throw StateError('sample rate $sampleRate refused');
    }
    final chunks = StreamController<Uint8List>();
    _chunks = chunks;
    return chunks.stream;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final gate = stopGate;
    if (gate != null) await gate.future;
    final error = stopError;
    if (error != null) throw error;
    final chunks = _chunks;
    // Not awaited: an unlistened controller's close never completes.
    if (chunks != null && !chunks.isClosed) unawaited(chunks.close());
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }

  /// One chunk of captured audio.
  void feed(Uint8List chunk) => _chunks!.add(chunk);

  /// The recorder failed mid-capture.
  void fail(Object error) => _chunks!.addError(error);

  /// The recorder's stream ended on its own.
  void end() => _chunks!.close();
}

/// The relay's limits (`PROTOCOL.md` §2.4).
const _maxFrameBytes = 64 * 1024;
const _idleTimeout = Duration(seconds: 10);

/// The server side of one accepted relay socket. It ENFORCES the relay's
/// rules, against the test's monotonic clock: audio only between `ready` and
/// `end`, frames of even length and at most 64 KiB, never more than
/// [leadMs] ahead of real time nor idle (no frame for ten seconds, or the
/// audio ten seconds behind), and no text but `{"type":"end"}`. A breach is
/// recorded in [violations] (shared with its [FakeRelayServer]), which the
/// tests require to be empty — where the real relay would close the socket
/// with 1008.
class FakeRelayChannel implements RelayChannel {
  FakeRelayChannel({
    this.rate = 24000,
    Duration Function()? clock,
    List<String>? violations,
    this.leadMs = kDefaultRelayLeadMs,
  }) : _clock = clock ?? (() => Duration.zero),
       violations = violations ?? <String>[];

  /// The `rate` of the upgrade this socket answered.
  final int rate;

  /// The server's pacing lead, which this socket enforces (whatever its
  /// `ready` advertised).
  final int leadMs;
  final Duration Function() _clock;
  final List<String> violations;
  Duration? _readyAt;
  Duration? _lastAudioAt;
  bool endReceived = false;

  final _incoming = StreamController<Object?>();
  final sentAudio = <Uint8List>[];

  /// Everything sent, in order: a `String` per text frame, a `Uint8List`
  /// per audio frame.
  final sent = <Object>[];
  int? _serverCloseCode;

  /// The code this side closed with (the first close's, as the real channel
  /// sends only that one); null while open.
  int? clientCloseCode;

  bool get closedByClient => clientCloseCode != null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  int? get closeCode => _serverCloseCode;

  bool get _open => clientCloseCode == null && !_incoming.isClosed;

  void _violation(String what) =>
      violations.add('rate=$rate t=${_clock().inMilliseconds}ms: $what');

  @override
  void sendText(String text) {
    sent.add(text);
    if (!_open) return;
    if (text != kRelayEndFrame) {
      _violation('a text frame other than end: $text');
    } else {
      checkIdle();
      endReceived = true;
    }
  }

  @override
  void sendAudio(Uint8List frame) {
    final copy = Uint8List.fromList(frame);
    sentAudio.add(copy);
    sent.add(copy);
    if (!_open) return;
    final ready = _readyAt;
    if (ready == null) _violation('audio before ready');
    if (endReceived) _violation('audio after end');
    if (frame.length.isOdd) _violation('an odd frame (${frame.length} B)');
    if (frame.length > _maxFrameBytes) {
      _violation('a frame over 64 KiB (${frame.length} B)');
    }
    if (ready == null) return;
    checkIdle();
    final now = _clock();
    final allowed = _bytesIn(now - ready + Duration(milliseconds: leadMs));
    if (audioBytes > allowed) {
      _violation('pacing: $audioBytes B sent, $allowed B allowed');
    }
    _lastAudioAt = now;
  }

  /// The relay's idle rule, as of now: a frame within the last ten seconds,
  /// and the audio no more than ten seconds behind real time.
  void checkIdle() {
    final ready = _readyAt;
    if (ready == null || endReceived || !_open) return;
    final caughtUp =
        ready + Duration(microseconds: audioBytes * 1000000 ~/ (rate * 2));
    final last = _lastAudioAt ?? ready;
    final from = last < caughtUp ? last : caughtUp;
    if (_clock() - from > _idleTimeout) {
      _violation('idle: nothing since ${from.inMilliseconds}ms');
    }
  }

  int _bytesIn(Duration duration) =>
      rate * 2 * duration.inMicroseconds ~/ Duration.microsecondsPerSecond;

  @override
  Future<void> close(int code) async {
    checkIdle();
    clientCloseCode ??= code;
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  /// The relay sends [event].
  void send(RelayEvent event) => _incoming.add(jsonEncode(event.toJson()));

  /// The relay sends [frame] as it is (a newer or an older server's wire:
  /// extra fields, unknown types).
  void sendRaw(String frame) => _incoming.add(frame);

  /// The relay says `ready`, advertising the facts given (a bare `ready`,
  /// an older server's, when none is): audio may flow from now.
  void ready({List<int>? rates, String? encoding, int? leadMs}) {
    _readyAt = _clock();
    send(RelayReady(rates: rates, encoding: encoding, leadMs: leadMs));
  }

  /// The relay closes with [code] (null: the connection just ended).
  void serverClose(int? code) {
    checkIdle();
    _serverCloseCode = code;
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  int get audioBytes => sentAudio.fold(0, (sum, f) => sum + f.length);
}

/// One upgrade the transport attempted.
typedef RelayAttempt = ({Uri uri, Map<String, String> headers});

/// The relay's upgrade endpoint: refuses an upgrade at a rate outside
/// [acceptedRates] with 422 (when set), else answers each attempt from
/// [script] (an `int` refuses with that HTTP status, any other object is
/// thrown, null accepts), accepting once the script runs out.
class FakeRelayServer {
  FakeRelayServer({
    Duration Function()? clock,
    this.acceptedRates,
    this.leadMs = kDefaultRelayLeadMs,
  }) : clock = clock ?? (() => Duration.zero);

  /// The monotonic clock the relay's rules are enforced against.
  final Duration Function() clock;

  /// The rates this server takes (null: any).
  final Set<int>? acceptedRates;

  /// The pacing lead every socket it answers enforces.
  final int leadMs;

  /// Every rule any socket of this server saw broken (see
  /// [FakeRelayChannel]).
  final violations = <String>[];

  final attempts = <RelayAttempt>[];
  final channels = <FakeRelayChannel>[];
  final script = <Object?>[];

  /// Holds every upgrade until completed (a slow network).
  Completer<void>? gate;

  FakeRelayChannel get channel => channels.last;

  Future<RelayChannel> connect(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    attempts.add((uri: uri, headers: Map.of(headers)));
    final hold = gate;
    if (hold != null) await hold.future;
    final rate = int.parse(uri.queryParameters['rate'] ?? '24000');
    final accepted = acceptedRates;
    if (accepted != null && !accepted.contains(rate)) {
      throw const RelayUpgradeException(422);
    }
    final answer = script.isEmpty ? null : script.removeAt(0);
    if (answer is int) throw RelayUpgradeException(answer);
    if (answer != null) throw answer;
    final channel = FakeRelayChannel(
      rate: rate,
      clock: clock,
      violations: violations,
      leadMs: leadMs,
    );
    channels.add(channel);
    return channel;
  }

  /// The idle rule for sockets still open now, then [violations].
  List<String> verify() {
    for (final channel in channels) {
      channel.checkIdle();
    }
    return violations;
  }
}

bool isSilence(Uint8List frame) => frame.every((b) => b == 0);
