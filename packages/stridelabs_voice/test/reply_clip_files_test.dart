import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/src/playback/reply_clip_files_io.dart'
    show IoReplyClipFiles;
import 'package:stridelabs_voice/src/playback/reply_clip_files_stub.dart'
    as web;
import 'package:stridelabs_voice/stridelabs_voice.dart';

const _mp3 = 'audio/mpeg';

/// The clip store over a real temp directory: the app's prefix names every
/// file, the clip's media type names its extension, and a sweep touches
/// nothing of another prefix.
void main() {
  late Directory dir;
  final bytes = Uint8List.fromList([1, 2, 3, 4]);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stridelabs_voice_clips_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  String nameOf(String path) => File(path).uri.pathSegments.last;

  group('the file name', () {
    for (final prefix in ['lumen-tts-', 'tapper-tts-']) {
      test(
        'is the app prefix, a uuid and the type extension ($prefix)',
        () async {
          final files = IoReplyClipFiles(dir, prefix: prefix);
          final path = await files.write(bytes, mediaType: _mp3);
          expect(
            nameOf(path),
            matches(
              RegExp(
                '^${RegExp.escape(prefix)}'
                r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
                r'[0-9a-f]{12}\.mp3$',
              ),
            ),
          );
          expect(File(path).parent.path, dir.path);
          expect(await File(path).readAsBytes(), bytes);
        },
      );
    }

    test(
      "the extension is the allowed-set table's entry for the type",
      () async {
        final files = IoReplyClipFiles(dir, prefix: 'p-');
        final path = await files.write(bytes, mediaType: _mp3);
        expect(kAllowedAudioTypes[_mp3], '.mp3');
        expect(path, endsWith(kAllowedAudioTypes[_mp3]!));
      },
    );

    test('each clip is a new file', () async {
      final files = IoReplyClipFiles(dir, prefix: 'p-');
      final a = await files.write(bytes, mediaType: _mp3);
      final b = await files.write(bytes, mediaType: _mp3);
      expect(a, isNot(b));
    });

    test('a type outside the table throws and writes nothing', () async {
      var wrote = false;
      final files = IoReplyClipFiles(
        dir,
        prefix: 'p-',
        writeBytes: (file, bytes) async => wrote = true,
      );
      for (final type in ['audio/wav', 'AUDIO/MPEG', 'audio/mpeg; q=1', '']) {
        await expectLater(
          files.write(bytes, mediaType: type),
          throwsA(isA<ArgumentError>()),
          reason: type,
        );
      }
      expect(wrote, isFalse);
      expect(await dir.list().toList(), isEmpty);
    });

    test('an empty prefix is refused: a sweep would take every file', () {
      expect(
        () => IoReplyClipFiles(dir, prefix: ''),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('delete and sweep', () {
    test(
      'delete removes the file, and a file already gone is no error',
      () async {
        final files = IoReplyClipFiles(dir, prefix: 'p-');
        final path = await files.write(bytes, mediaType: _mp3);
        await files.delete(path);
        expect(File(path).existsSync(), isFalse);
        await files.delete(path);
      },
    );

    test('sweep deletes this prefix only and counts what went', () async {
      File('${dir.path}/lumen-tts-old1.mp3').writeAsBytesSync(bytes);
      File('${dir.path}/lumen-tts-old2.mp3').writeAsBytesSync(bytes);
      File('${dir.path}/tapper-tts-other.mp3').writeAsBytesSync(bytes);
      File('${dir.path}/notes.txt').writeAsBytesSync(bytes);
      Directory('${dir.path}/lumen-tts-dir').createSync();
      final files = IoReplyClipFiles(dir, prefix: 'lumen-tts-');
      expect(await files.sweep(), 2);
      final left = [for (final e in dir.listSync()) nameOf(e.path)]..sort();
      expect(left, ['lumen-tts-dir', 'notes.txt', 'tapper-tts-other.mp3']);
      expect(await files.sweep(), 0);
    });

    test('sweep of a directory that does not exist is zero', () async {
      final gone = Directory('${dir.path}/missing');
      expect(await IoReplyClipFiles(gone, prefix: 'p-').sweep(), 0);
    });
  });

  test('a failed write leaves no partial file and rethrows', () async {
    final files = IoReplyClipFiles(
      dir,
      prefix: 'p-',
      writeBytes: (file, bytes) async {
        await file.writeAsBytes(bytes.sublist(0, 2));
        throw const FileSystemException('disk full');
      },
    );
    await expectLater(
      files.write(bytes, mediaType: _mp3),
      throwsA(isA<FileSystemException>()),
    );
    expect(await dir.list().toList(), isEmpty);
  });

  group('the platform default', () {
    test(
      'keeps its files in the temp directory under the given prefix',
      () async {
        final prefix = 'stridelabs-voice-test-${pid}_';
        final files = defaultReplyClipFiles(prefix: prefix);
        final path = await files.write(bytes, mediaType: _mp3);
        try {
          expect(File(path).parent.path, Directory.systemTemp.path);
          expect(nameOf(path), startsWith(prefix));
          expect(path, endsWith('.mp3'));
          expect(await files.sweep(), 1);
          expect(File(path).existsSync(), isFalse);
        } finally {
          await files.delete(path);
        }
      },
    );
  });

  group('without dart:io (web)', () {
    final files = web.defaultReplyClipFiles(prefix: 'lumen-tts-');

    test('a write fails, which the speaker treats as text-only', () async {
      await expectLater(
        files.write(bytes, mediaType: _mp3),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('delete and sweep have nothing to do', () async {
      await files.delete('/anything');
      expect(await files.sweep(), 0);
    });
  });
}
