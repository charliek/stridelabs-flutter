import 'dart:typed_data';

import 'reply_clip_files_stub.dart'
    if (dart.library.io) 'reply_clip_files_io.dart'
    as platform;

/// Where the reply speaker keeps each sentence's audio while it plays: one
/// file per clip, deleted once it has played (or been dropped). Narrow on
/// purpose, so tests run the speaker over memory or a temp directory.
///
/// Every file name starts with the store's prefix (the app's: `lumen-tts-`,
/// `tapper-tts-`), which [sweep] finds what a previous run left behind by.
abstract interface class ReplyClipFiles {
  /// Writes [bytes], a clip of [mediaType] (one of `kAllowedAudioTypes`), to
  /// a new `<prefix><uuid><extension>`, the extension that type's table
  /// entry names (`audio/mpeg`: `.mp3`); returns its path. An unsupported
  /// [mediaType] throws an [ArgumentError] and writes nothing.
  Future<String> write(Uint8List bytes, {required String mediaType});

  /// Deletes [path]; a file already gone is not an error.
  Future<void> delete(String path);

  /// Deletes every `<prefix>*` file there (a crash or kill mid-reply leaves
  /// some); returns how many went.
  Future<int> sweep();
}

/// The platform's store, its files named from [prefix]: `Directory.systemTemp`
/// (the app's cache directory on Android); on web, where voice does not run,
/// one whose writes fail.
ReplyClipFiles defaultReplyClipFiles({required String prefix}) =>
    platform.defaultReplyClipFiles(prefix: prefix);
