import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'mic_capture.dart';

/// Why a WAV file cannot be played as the mic.
enum WavMicProblem {
  /// Not a RIFF/WAVE file, or its chunks do not add up.
  malformed,

  /// Not 16-bit integer PCM.
  notPcm16,

  /// More than one channel.
  notMono,

  /// Its sample rate is not the one capture asked for (never resampled).
  sampleRateMismatch,
}

/// [WavMicCapture.start]'s typed refusal. The message names the file's
/// property, never its content.
class WavMicException implements Exception {
  const WavMicException(this.problem, this.detail);

  final WavMicProblem problem;
  final String detail;

  @override
  String toString() => 'WavMicException(${problem.name}): $detail';
}

/// A RIFF/WAVE file's 16-bit mono PCM and its sample rate.
@immutable
class WavPcm {
  const WavPcm(this.sampleRate, this.samples);

  final int sampleRate;

  /// s16le mono, as captured audio is.
  final Uint8List samples;

  /// Parses [bytes]: `RIFF` `<size>` `WAVE`, then chunks; a `fmt ` chunk of
  /// PCM (format 1, or WAVE_FORMAT_EXTENSIBLE with the PCM sub-format), one
  /// channel, 16 bits; then a `data` chunk. Other chunks (ffmpeg's `LIST`)
  /// are skipped. Throws [WavMicException] otherwise.
  ///
  /// The RIFF chunk's declared size bounds everything: it must cover exactly
  /// the rest of the file (plus a pad byte when odd), and the chunks must
  /// fill it exactly, each with its own pad byte, so a truncated chunk
  /// (`data` or any after it) and bytes outside the container are refused,
  /// never read as audio.
  factory WavPcm.parse(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    String tag(int at) => String.fromCharCodes(bytes, at, at + 4);
    if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const WavMicException(
        WavMicProblem.malformed,
        'not a RIFF/WAVE file',
      );
    }
    final riffSize = view.getUint32(4, Endian.little);
    // The container: from `WAVE` to its declared end.
    final end = 8 + riffSize;
    if (riffSize < 4 || end > bytes.length) {
      throw WavMicException(
        WavMicProblem.malformed,
        'the RIFF chunk declares $riffSize bytes; the file holds '
        '${bytes.length - 8}',
      );
    }
    if (bytes.length != end + (riffSize.isOdd ? 1 : 0)) {
      throw WavMicException(
        WavMicProblem.malformed,
        '${bytes.length - end} bytes after the RIFF chunk',
      );
    }
    int? sampleRate;
    (int, int)? data;
    var at = 12;
    while (at < end) {
      if (end - at < 8) {
        throw const WavMicException(
          WavMicProblem.malformed,
          'a chunk header is cut off at the end of the RIFF chunk',
        );
      }
      final id = tag(at);
      final size = view.getUint32(at + 4, Endian.little);
      final body = at + 8;
      // Chunks are padded to an even length.
      final next = body + size + (size.isOdd ? 1 : 0);
      if (next > end) {
        throw WavMicException(
          WavMicProblem.malformed,
          'the "$id" chunk runs past the end of the RIFF chunk',
        );
      }
      if (id == 'fmt ') {
        if (sampleRate != null) {
          throw const WavMicException(
            WavMicProblem.malformed,
            'two "fmt " chunks',
          );
        }
        sampleRate = _checkFormat(view, body, size);
      } else if (id == 'data') {
        if (sampleRate == null) {
          throw const WavMicException(
            WavMicProblem.malformed,
            'the "data" chunk comes before "fmt "',
          );
        }
        if (data != null) {
          throw const WavMicException(
            WavMicProblem.malformed,
            'two "data" chunks',
          );
        }
        if (size.isOdd) {
          throw const WavMicException(
            WavMicProblem.malformed,
            'the "data" chunk holds half a sample',
          );
        }
        data = (body, size);
      }
      at = next;
    }
    if (data == null) {
      throw const WavMicException(WavMicProblem.malformed, 'no "data" chunk');
    }
    final (from, length) = data;
    return WavPcm(
      sampleRate!,
      Uint8List.fromList(bytes.sublist(from, from + length)),
    );
  }

  /// The `fmt ` chunk at [at] ([size] bytes): its sample rate, if the format
  /// is 16-bit mono PCM.
  static int _checkFormat(ByteData view, int at, int size) {
    if (size < 16) {
      throw const WavMicException(
        WavMicProblem.malformed,
        'the "fmt " chunk is too short',
      );
    }
    var format = view.getUint16(at, Endian.little);
    // WAVE_FORMAT_EXTENSIBLE: the sub-format GUID's first two bytes.
    if (format == 0xFFFE && size >= 40) {
      format = view.getUint16(at + 24, Endian.little);
    }
    final channels = view.getUint16(at + 2, Endian.little);
    final sampleRate = view.getUint32(at + 4, Endian.little);
    final blockAlign = view.getUint16(at + 12, Endian.little);
    final bits = view.getUint16(at + 14, Endian.little);
    if (format != 1 || bits != 16) {
      throw WavMicException(
        WavMicProblem.notPcm16,
        'format $format with $bits-bit samples, not 16-bit PCM',
      );
    }
    if (channels != 1) {
      throw WavMicException(WavMicProblem.notMono, '$channels channels, not 1');
    }
    if (sampleRate == 0 || blockAlign != 2) {
      throw WavMicException(
        WavMicProblem.malformed,
        'sample rate $sampleRate, block align $blockAlign',
      );
    }
    return sampleRate;
  }
}

/// DEBUG-ONLY [MicCapture] that "speaks" a WAV file, so a driven app (or an
/// integration test) can talk to the voice relay with no microphone.
///
/// [start] reads [path], which must be RIFF/WAVE 16-bit mono PCM at exactly
/// the rate asked for (anything else is a [WavMicException]; the transport
/// then tries its next rate). It then streams the file in real time: one
/// [chunkDuration] chunk (24 kHz: 3,840 bytes) each time that much wall time
/// has passed since [start], each due time counted from [start] itself, so a
/// late timer catches up rather than delays every chunk after it. Past the
/// end of the file it sends silence at the same pace, the way a quiet room
/// would, until [stop]. [stop] and [dispose] end the stream at once; a
/// [start] after [stop] plays the file from the beginning again.
///
/// The app decides when to construct it (lumen: a debug build with
/// `--dart-define=LUMEN_MIC_WAV=<path>`, behind the const `kDebugMode`, so a
/// release build drops it). From lumen's `lib/voice/wav_mic_capture.dart`.
class WavMicCapture implements MicCapture {
  WavMicCapture(
    this.path, {
    Future<Uint8List> Function(String path)? readFile,
    Duration Function()? clock,
  }) : _readFile = readFile ?? _readFromDisk,
       _clock = clock ?? _monotonic();

  /// The WAV file.
  final String path;

  /// How much audio each chunk carries, as the real recorder delivers it.
  static const chunkDuration = Duration(milliseconds: 80);

  final Future<Uint8List> Function(String path) _readFile;

  /// Monotonic elapsed time (the test seam for pacing).
  final Duration Function() _clock;

  WavPcm? _pcm;
  StreamController<Uint8List>? _controller;
  Timer? _timer;
  int _chunkBytes = 0;
  int _sent = 0;
  Duration _startedAt = Duration.zero;
  bool _disposed = false;

  /// Bumped by every [start] and [_halt]: a start that sees another value
  /// after reading the file was stopped (or superseded) meanwhile.
  int _generation = 0;

  /// The bytes of one [chunkDuration] chunk at [sampleRate].
  static int chunkBytesFor(int sampleRate) =>
      sampleRate * chunkDuration.inMilliseconds ~/ 1000 * 2;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start(int sampleRate) async {
    if (_disposed) throw StateError('WavMicCapture is disposed');
    if (_controller != null) throw StateError('WavMicCapture is capturing');
    final generation = ++_generation;
    final pcm = _pcm ??= WavPcm.parse(await _readFile(path));
    if (pcm.sampleRate != sampleRate) {
      throw WavMicException(
        WavMicProblem.sampleRateMismatch,
        'the file is ${pcm.sampleRate} Hz, capture asked for $sampleRate Hz',
      );
    }
    if (generation != _generation || _disposed) {
      throw StateError('WavMicCapture was stopped while starting');
    }
    // A listener cancelling ends THIS capture only. A stream that ended
    // while paused reports its cancel late (when resumed), possibly after a
    // restart: by then it is not the current one, and nothing happens.
    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onCancel: () {
        if (identical(_controller, controller)) _halt();
      },
    );
    _controller = controller;
    _chunkBytes = chunkBytesFor(sampleRate);
    _sent = 0;
    _startedAt = _clock();
    debugPrint(
      '[wav-mic] streaming $path at $sampleRate Hz '
      '(${pcm.samples.length * 1000 ~/ (sampleRate * 2)} ms, then silence)',
    );
    _scheduleNext();
    return controller.stream;
  }

  @override
  Future<void> stop() async => _halt();

  @override
  Future<void> dispose() async {
    _disposed = true;
    _halt();
  }

  /// Arms the timer for the next chunk's due time, counted from [start].
  void _scheduleNext() {
    final due = chunkDuration * (_sent + 1);
    final wait = due - (_clock() - _startedAt);
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _deliverDue);
  }

  /// Sends every chunk whose time has come (more than one after a stall).
  void _deliverDue() {
    _timer = null;
    final controller = _controller;
    if (controller == null) return;
    final elapsed = _clock() - _startedAt;
    final due = elapsed.inMicroseconds ~/ chunkDuration.inMicroseconds;
    while (_sent < due) {
      controller.add(_chunk(_sent));
      _sent++;
    }
    _scheduleNext();
  }

  /// Chunk [index]: the file's bytes there, zero-filled past its end.
  Uint8List _chunk(int index) {
    final samples = _pcm!.samples;
    final chunk = Uint8List(_chunkBytes);
    final from = index * _chunkBytes;
    if (from < samples.length) {
      final to = from + _chunkBytes;
      chunk.setRange(
        0,
        (to < samples.length ? to : samples.length) - from,
        samples,
        from,
      );
    }
    return chunk;
  }

  /// Ends the stream (its `done` follows at once) and the pacing.
  void _halt() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) {
      // Completes only once a listener has seen `done`: never awaited.
      unawaited(controller.close());
    }
  }

  static Future<Uint8List> _readFromDisk(String path) =>
      File(path).readAsBytes();

  static Duration Function() _monotonic() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}
