import 'dart:typed_data';

import 'reply_clip_files.dart';

/// No `dart:io` (web): voice does not run there, so there is nothing to
/// store; a write fails, which the speaker treats as text-only.
class _NoReplyClipFiles implements ReplyClipFiles {
  const _NoReplyClipFiles();

  @override
  Future<String> write(Uint8List bytes, {required String mediaType}) =>
      Future.error(UnsupportedError('no file system for reply audio'));

  @override
  Future<void> delete(String path) async {}

  @override
  Future<int> sweep() async => 0;
}

ReplyClipFiles defaultReplyClipFiles({required String prefix}) =>
    const _NoReplyClipFiles();
