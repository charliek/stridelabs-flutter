import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/wav_mic.dart';

/// The debug-only WAV mic (moved from lumen, plan 001 L3.5): real-time 80 ms
/// chunks paced by elapsed time (a fake clock here), silence after the file, a
/// replay on restart, nothing after stop, and typed refusals. Lumen's
/// dart-define wiring and its committed corpus stay in lumen.
void main() {
  group('pacing', () {
    test('80 ms chunks of 3,840 bytes at 24 kHz, the file in order', () {
      fakeAsync((async) {
        final pcm = _ramp(3840 * 3);
        final run = _Run(async, _wav(pcm));

        async.elapse(const Duration(milliseconds: 240));
        expect(run.times, [80, 160, 240]);
        expect(run.chunks.map((c) => c.length), [3840, 3840, 3840]);
        expect(run.chunks.expand((c) => c), pcm);

        run.mic.stop();
        async.flushMicrotasks();
      });
    });

    test('16 kHz chunks are 2,560 bytes', () {
      fakeAsync((async) {
        final run = _Run(async, _wav(_ramp(5120), rate: 16000), rate: 16000);
        async.elapse(const Duration(milliseconds: 160));
        expect(run.chunks.map((c) => c.length), [2560, 2560]);
        expect(WavMicCapture.chunkBytesFor(24000), 3840);
        run.mic.stop();
        async.flushMicrotasks();
      });
    });

    test('due times count from start: a stall is caught up, not carried', () {
      fakeAsync((async) {
        var stall = Duration.zero;
        final run = _Run(
          async,
          _wav(_ramp(3840 * 20)),
          clock: () => async.elapsed + stall,
        );
        async.elapse(const Duration(milliseconds: 160));
        expect(run.chunks, hasLength(2));

        // The isolate was busy for 200 ms: the clock moved on without the
        // timers. The next tick (at 240 ms of timer time, 440 ms of clock)
        // sends every chunk due by then.
        stall = const Duration(milliseconds: 200);
        async.elapse(const Duration(milliseconds: 80));
        expect(run.chunks, hasLength(5));

        // And the schedule stays on the clock's 80 ms grid: the next chunk
        // is due at 480 ms of clock (280 ms of timer time), not 80 ms after
        // the late tick; by 600 ms of clock, 7 chunks (one chunk per timer
        // re-armed 80 ms after each tick would have sent 5).
        async.elapse(const Duration(milliseconds: 160));
        expect(run.chunks, hasLength(7));
        expect(run.times, [80, 160, 240, 240, 240, 280, 360]);
        expect(
          run.chunks.expand((c) => c),
          _ramp(3840 * 20).sublist(0, 3840 * 7),
        );
        run.mic.stop();
        async.flushMicrotasks();
      });
    });
  });

  test('after the file: silence, same size, same pace, until stop', () {
    fakeAsync((async) {
      final pcm = _ramp(3840 * 2 + 1920, offset: 1);
      final run = _Run(async, _wav(pcm));

      async.elapse(const Duration(milliseconds: 800));
      expect(run.times, [for (var i = 1; i <= 10; i++) i * 80]);
      expect(run.chunks.map((c) => c.length), everyElement(3840));
      expect(run.chunks[0], pcm.sublist(0, 3840));
      expect(run.chunks[1], pcm.sublist(3840, 7680));
      expect(run.chunks[2].sublist(0, 1920), pcm.sublist(7680));
      expect(run.chunks[2].sublist(1920), everyElement(0));
      for (final chunk in run.chunks.skip(3)) {
        expect(chunk, everyElement(0));
      }
      expect(run.done, isFalse);

      run.mic.stop();
      async.flushMicrotasks();
      expect(run.done, isTrue);
    });
  });

  test('a start after stop plays the file from the beginning again', () {
    fakeAsync((async) {
      final pcm = _ramp(3840 * 4);
      final run = _Run(async, _wav(pcm));
      async.elapse(const Duration(milliseconds: 250));
      expect(run.chunks, hasLength(3));

      run.mic.stop();
      async.flushMicrotasks();
      expect(run.done, isTrue);

      final again = _Run.on(async, run.mic);
      async.elapse(const Duration(milliseconds: 160));
      // 80 ms after the restart, the file's first chunk.
      expect(again.times, [80, 160]);
      expect(again.chunks[0], pcm.sublist(0, 3840));
      expect(again.chunks[1], pcm.sublist(3840, 7680));
      run.mic.stop();
      async.flushMicrotasks();
    });
  });

  group('ending', () {
    test('stop mid-stream: no chunk after it, done at once, no timer', () {
      fakeAsync((async) {
        final run = _Run(async, _wav(_ramp(3840 * 10)));
        async.elapse(const Duration(milliseconds: 120));
        expect(run.chunks, hasLength(1));

        run.mic.stop();
        async.flushMicrotasks();
        expect(run.done, isTrue);
        expect(async.pendingTimers, isEmpty);

        async.elapse(const Duration(seconds: 2));
        expect(run.chunks, hasLength(1));
      });
    });

    test('the listener cancelling stops the pacing', () {
      fakeAsync((async) {
        final run = _Run(async, _wav(_ramp(3840 * 10)));
        async.elapse(const Duration(milliseconds: 100));
        run.subscription.cancel();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(run.chunks, hasLength(1));
      });
    });

    test('an old stream cancelling late never stops a restarted capture', () {
      fakeAsync((async) {
        final run = _Run(async, _wav(_ramp(3840 * 10)));
        async.elapse(const Duration(milliseconds: 100));
        // Paused, the old stream holds its `done` (and its cancel) back...
        run.subscription.pause();
        run.mic.stop();
        async.flushMicrotasks();

        final again = _Run.on(async, run.mic);
        // ...until it resumes, after the restart.
        run.subscription.resume();
        async.flushMicrotasks();
        expect(run.done, isTrue);

        async.elapse(const Duration(milliseconds: 240));
        expect(again.chunks, hasLength(3));
        expect(again.done, isFalse);
        run.mic.stop();
        async.flushMicrotasks();
      });
    });

    test('dispose ends the stream, and the mic cannot start again', () {
      fakeAsync((async) {
        final run = _Run(async, _wav(_ramp(3840)));
        async.elapse(const Duration(milliseconds: 80));
        run.mic.dispose();
        async.flushMicrotasks();
        expect(run.done, isTrue);
        expect(async.pendingTimers, isEmpty);

        Object? error;
        run.mic.start(24000).catchError((Object e) {
          error = e;
          return const Stream<Uint8List>.empty();
        });
        async.flushMicrotasks();
        expect(error, isA<StateError>());
      });
    });

    test('a stop while the file is read: the start fails, nothing plays', () {
      fakeAsync((async) {
        final file = Completer<Uint8List>();
        final mic = WavMicCapture(
          'x.wav',
          readFile: (_) => file.future,
          clock: () => async.elapsed,
        );
        Object? error;
        mic
            .start(24000)
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        mic.stop();
        file.complete(_wav(_ramp(3840)));
        async.flushMicrotasks();
        expect(error, isA<StateError>());
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a second start while capturing is refused', () {
      fakeAsync((async) {
        final run = _Run(async, _wav(_ramp(3840)));
        Object? error;
        run.mic.start(24000).catchError((Object e) {
          error = e;
          return const Stream<Uint8List>.empty();
        });
        async.flushMicrotasks();
        expect(error, isA<StateError>());
        run.mic.stop();
        async.flushMicrotasks();
      });
    });
  });

  test('hasPermission is always true (there is no device to ask)', () async {
    expect(await WavMicCapture('x.wav').hasPermission(), isTrue);
  });

  group('refusals: typed, from start, never a resample', () {
    test('a sample rate other than the one asked for', () {
      fakeAsync((async) {
        final mic = WavMicCapture(
          'x.wav',
          readFile: (_) async => _wav(_ramp(2560), rate: 16000),
          clock: () => async.elapsed,
        );
        Object? error;
        mic.start(24000).catchError((Object e) {
          error = e;
          return const Stream<Uint8List>.empty();
        });
        async.flushMicrotasks();
        expect(
          error,
          isA<WavMicException>().having(
            (e) => e.problem,
            'problem',
            WavMicProblem.sampleRateMismatch,
          ),
        );
        expect(async.pendingTimers, isEmpty);

        // The transport then asks for its next rate, which matches.
        final run = _Run.on(async, mic, rate: 16000);
        async.elapse(const Duration(milliseconds: 80));
        expect(run.chunks.single, hasLength(2560));
        mic.stop();
        async.flushMicrotasks();
      });
    });

    final cases = <String, (Uint8List, WavMicProblem)>{
      'no bytes': (Uint8List(0), WavMicProblem.malformed),
      'not RIFF': (_patch(_wav(_ramp(64)), 0, 'RIFX'), WavMicProblem.malformed),
      'not WAVE': (_patch(_wav(_ramp(64)), 8, 'AVI '), WavMicProblem.malformed),
      'no data chunk': (
        _riff([_chunk('fmt ', _fmt())]),
        WavMicProblem.malformed,
      ),
      'data before fmt': (
        _riff([_chunk('data', _ramp(64)), _chunk('fmt ', _fmt())]),
        WavMicProblem.malformed,
      ),
      'a data chunk longer than the file': (
        _wav(_ramp(64)).sublist(0, 44 + 32),
        WavMicProblem.malformed,
      ),
      'half a sample': (
        _riff([_chunk('fmt ', _fmt()), _chunk('data', _ramp(63))]),
        WavMicProblem.malformed,
      ),
      'a short fmt chunk': (
        _riff([
          _chunk('fmt ', _fmt().sublist(0, 14)),
          _chunk('data', _ramp(64)),
        ]),
        WavMicProblem.malformed,
      ),
      '8-bit': (
        _wav(_ramp(64), bits: 8, blockAlign: 1),
        WavMicProblem.notPcm16,
      ),
      '32-bit float': (
        _wav(_ramp(64), format: 3, bits: 32, blockAlign: 4),
        WavMicProblem.notPcm16,
      ),
      'stereo': (
        _wav(_ramp(64), channels: 2, blockAlign: 4),
        WavMicProblem.notMono,
      ),
      // The RIFF chunk's declared size bounds the walk.
      'RIFF size 4 (audio outside the container)': (
        _riffSize(_wav(_ramp(64)), 4),
        WavMicProblem.malformed,
      ),
      'RIFF size 0xffffffff': (
        _riffSize(_wav(_ramp(64)), 0xFFFFFFFF),
        WavMicProblem.malformed,
      ),
      'a RIFF size that ends before the data chunk': (
        _riffSize(_wav(_ramp(64)), 4 + 24),
        WavMicProblem.malformed,
      ),
      'bytes after the RIFF chunk': (
        Uint8List.fromList([..._wav(_ramp(64)), ..._ramp(16)]),
        WavMicProblem.malformed,
      ),
      'a truncated trailing LIST chunk': (
        _riff([
          _chunk('fmt ', _fmt()),
          _chunk('data', _ramp(64)),
          _truncatedChunk('LIST', declared: 32, present: 8),
        ]),
        WavMicProblem.malformed,
      ),
      'a data length past the end of the file': (
        _riff([
          _chunk('fmt ', _fmt()),
          _truncatedChunk('data', declared: 128, present: 64),
        ]),
        WavMicProblem.malformed,
      ),
      'a chunk header cut off': (
        _riff([
          _chunk('fmt ', _fmt()),
          _chunk('data', _ramp(64)),
          ascii.encode('LIST'),
        ]),
        WavMicProblem.malformed,
      ),
    };
    for (final MapEntry(key: name, value: (bytes, problem)) in cases.entries) {
      test(name, () {
        expect(
          () => WavPcm.parse(bytes),
          throwsA(
            isA<WavMicException>().having((e) => e.problem, 'problem', problem),
          ),
        );
      });
    }

    test('start reports a bad file as its typed error', () {
      fakeAsync((async) {
        final mic = WavMicCapture(
          'x.wav',
          readFile: (_) async => _wav(_ramp(64), channels: 2, blockAlign: 4),
          clock: () => async.elapsed,
        );
        Object? error;
        mic.start(24000).catchError((Object e) {
          error = e;
          return const Stream<Uint8List>.empty();
        });
        async.flushMicrotasks();
        expect(
          error,
          isA<WavMicException>().having(
            (e) => e.problem,
            'problem',
            WavMicProblem.notMono,
          ),
        );
      });
    });

    test('a file that is not there is a file system error', () async {
      final missing =
          '${Directory.systemTemp.path}/stridelabs-no-such-file.wav';
      await expectLater(
        WavMicCapture(missing).start(24000),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('the headers it accepts', () {
    test('extra chunks (ffmpeg\'s LIST), odd-sized and padded', () {
      final pcm = _ramp(64);
      final parsed = WavPcm.parse(
        _riff([
          _chunk('LIST', _ramp(5)),
          _chunk('fmt ', _fmt()),
          _chunk('fact', _ramp(4)),
          _chunk('data', pcm),
        ]),
      );
      expect(parsed.sampleRate, 24000);
      expect(parsed.samples, pcm);
    });

    test('WAVE_FORMAT_EXTENSIBLE with the PCM sub-format', () {
      final fmt = BytesBuilder()
        ..add(_fmt(format: 0xFFFE))
        ..add(_u16(22))
        ..add(_u16(16)) // valid bits
        ..add(_u32(4)) // channel mask
        ..add(_u16(1)) // the PCM sub-format GUID's first two bytes
        ..add(Uint8List(14));
      final parsed = WavPcm.parse(
        _riff([_chunk('fmt ', fmt.toBytes()), _chunk('data', _ramp(8))]),
      );
      expect(parsed.samples, hasLength(8));
    });

    test('a file on disk, through the default reader and clock', () async {
      final dir = await Directory.systemTemp.createTemp('stridelabs-wav-mic');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/speech.wav';
      await File(path).writeAsBytes(_wav(_ramp(3840 * 2)));
      final mic = WavMicCapture(path);
      final stream = await mic.start(24000);
      final first = await stream.first.timeout(const Duration(seconds: 5));
      expect(first, _ramp(3840));
      await mic.dispose();
    });
  });
}

/// One started capture, its chunks and when each arrived (ms after start).
class _Run {
  _Run(
    FakeAsync async,
    Uint8List file, {
    int rate = 24000,
    Duration Function()? clock,
  }) : this.on(
         async,
         WavMicCapture(
           'speech.wav',
           readFile: (_) async => file,
           clock: clock ?? () => async.elapsed,
         ),
         rate: rate,
       );

  _Run.on(this._async, this.mic, {int rate = 24000}) {
    final startedAt = _async.elapsed;
    late Stream<Uint8List> stream;
    mic.start(rate).then((s) => stream = s);
    _async.flushMicrotasks();
    subscription = stream.listen((chunk) {
      chunks.add(chunk);
      times.add((_async.elapsed - startedAt).inMilliseconds);
    }, onDone: () => done = true);
  }

  final FakeAsync _async;
  final WavMicCapture mic;
  late final StreamSubscription<Uint8List> subscription;
  final chunks = <Uint8List>[];
  final times = <int>[];
  bool done = false;
}

/// [length] bytes that differ from chunk to chunk.
Uint8List _ramp(int length, {int offset = 0}) => Uint8List.fromList([
  for (var i = 0; i < length; i++) (i * 7 + offset) & 0xFF,
]);

Uint8List _u16(int value) =>
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List();

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

/// A 16-byte `fmt ` body.
Uint8List _fmt({
  int format = 1,
  int channels = 1,
  int rate = 24000,
  int bits = 16,
  int blockAlign = 2,
}) =>
    (BytesBuilder()
          ..add(_u16(format))
          ..add(_u16(channels))
          ..add(_u32(rate))
          ..add(_u32(rate * blockAlign))
          ..add(_u16(blockAlign))
          ..add(_u16(bits)))
        .toBytes();

/// A chunk: its id, its size, its body, a pad byte when the size is odd.
Uint8List _chunk(String id, Uint8List body) =>
    (BytesBuilder()
          ..add(ascii.encode(id))
          ..add(_u32(body.length))
          ..add(body)
          ..add(body.length.isOdd ? [0] : const <int>[]))
        .toBytes();

Uint8List _riff(List<Uint8List> chunks) {
  final rest = BytesBuilder()..add(ascii.encode('WAVE'));
  for (final chunk in chunks) {
    rest.add(chunk);
  }
  final body = rest.toBytes();
  return (BytesBuilder()
        ..add(ascii.encode('RIFF'))
        ..add(_u32(body.length))
        ..add(body))
      .toBytes();
}

/// The plain 44-byte-header WAV of [pcm].
Uint8List _wav(
  Uint8List pcm, {
  int rate = 24000,
  int format = 1,
  int channels = 1,
  int bits = 16,
  int blockAlign = 2,
}) => _riff([
  _chunk(
    'fmt ',
    _fmt(
      format: format,
      channels: channels,
      rate: rate,
      bits: bits,
      blockAlign: blockAlign,
    ),
  ),
  _chunk('data', pcm),
]);

/// [bytes] with its RIFF size field set to [size].
Uint8List _riffSize(Uint8List bytes, int size) =>
    Uint8List.fromList(bytes)..setRange(4, 8, _u32(size));

/// A chunk whose header declares [declared] bytes but holds [present].
Uint8List _truncatedChunk(
  String id, {
  required int declared,
  required int present,
}) =>
    (BytesBuilder()
          ..add(ascii.encode(id))
          ..add(_u32(declared))
          ..add(_ramp(present)))
        .toBytes();

Uint8List _patch(Uint8List bytes, int at, String tag) =>
    Uint8List.fromList(bytes)..setRange(at, at + 4, ascii.encode(tag));
