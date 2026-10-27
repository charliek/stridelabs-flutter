import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../protocol/constants.dart';
import 'reply_clip_files.dart';

const _uuid = Uuid();

/// [ReplyClipFiles] in [directory] (`Directory.systemTemp` in the app), each
/// file named from [prefix].
class IoReplyClipFiles implements ReplyClipFiles {
  IoReplyClipFiles(
    this.directory, {
    required this.prefix,
    Future<void> Function(File file, Uint8List bytes)? writeBytes,
  }) : _writeBytes = writeBytes ?? _writeAll {
    // An empty prefix would make [sweep] delete every file in the directory.
    if (prefix.isEmpty) throw ArgumentError.value(prefix, 'prefix', 'is empty');
  }

  final Directory directory;

  /// What every file this store writes starts with.
  final String prefix;
  final Future<void> Function(File file, Uint8List bytes) _writeBytes;

  // No fsync: the player reads it back in this process, and a file a crash
  // leaves is swept at the next start.
  static Future<void> _writeAll(File file, Uint8List bytes) =>
      file.writeAsBytes(bytes);

  /// A write that fails (a full disk, say) leaves no partial file behind.
  @override
  Future<String> write(Uint8List bytes, {required String mediaType}) async {
    final extension = kAllowedAudioTypes[mediaType];
    if (extension == null) {
      throw ArgumentError.value(mediaType, 'mediaType', 'is not supported');
    }
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      '$prefix${_uuid.v4()}$extension',
    );
    try {
      await _writeBytes(file, bytes);
    } catch (_) {
      try {
        await file.delete();
      } on FileSystemException {
        // Never created, or already gone.
      }
      rethrow;
    }
    return file.path;
  }

  @override
  Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }

  @override
  Future<int> sweep() async {
    if (!await directory.exists()) return 0;
    var deleted = 0;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!name.startsWith(prefix)) continue;
      try {
        await entry.delete();
        deleted++;
      } on FileSystemException {
        // In use or gone: the next sweep tries again.
      }
    }
    return deleted;
  }
}

ReplyClipFiles defaultReplyClipFiles({required String prefix}) =>
    IoReplyClipFiles(Directory.systemTemp, prefix: prefix);
