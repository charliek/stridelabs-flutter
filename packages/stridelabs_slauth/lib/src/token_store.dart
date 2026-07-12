import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Key/value persistence for auth tokens at rest.
///
/// Abstracted so [AuthService](auth_service.dart) is agnostic to the backing
/// store and unit-testable with an in-memory / recording fake, and so the store
/// can vary by platform (see [defaultTokenStore]).
abstract class TokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Mobile store backed by the OS keychain/keystore (iOS Keychain, Android
/// Keystore-backed AES). Used on Android/iOS, where a signed app has a usable
/// secure enclave.
class SecureStorageTokenStore implements TokenStore {
  SecureStorageTokenStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Desktop store: one `0600` file per key under [dirPath] (dir forced to `0700`).
///
/// Chosen over the keychain on macOS/Linux **for developer / headless-agent
/// builds** after codesign testing: the macOS keychain entitlement requires a
/// dev signing cert that an ad-hoc debug codesign can't provide (secure storage
/// then throws at runtime), and Linux CI/agent hosts routinely lack a running
/// `libsecret`/`gnome-keyring`. A `0600` file in the app-support dir is a
/// consistent trust model for a personal desktop tool (the device already holds
/// e.g. `~/.ssh` private keys at the same protection).
///
/// Writes go to a temp file, are locked down, then atomically renamed over the
/// target so a crash can't leave a truncated token blob paired with a live
/// access token.
class FileTokenStore implements TokenStore {
  FileTokenStore(this.dirPath);

  final String dirPath;

  // Monotonic per-process counter so two writes in the same microsecond still
  // get distinct temp paths.
  static int _tmpSeq = 0;

  File _file(String key) => File('$dirPath/${Uri.encodeComponent(key)}');

  @override
  Future<String?> read(String key) async {
    final f = _file(key);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> write(String key, String value) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    // Lock the dir down (0700) on every write, not just creation, and fail hard
    // if we can't — a world-readable dir undermines the 0600 files inside it.
    await _chmod('700', dirPath);

    final f = _file(key);
    // Unique temp path per write (pid + microseconds + counter). Reusing a fixed
    // `${f.path}.tmp` lets overlapping writes recreate the temp path after
    // another has renamed it, landing a secret under default (fail-open) perms.
    final tmp = File(
      '${f.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.'
      '${_tmpSeq++}.tmp',
    );
    try {
      // Create the temp file EMPTY, lock it to 0600, and only THEN write the
      // secret into it. Writing first would briefly land the token on disk with
      // umask-default perms before the chmod, a fail-open window.
      await tmp.writeAsString('');
      await _chmod('600', tmp.path);
      await tmp.writeAsString(value);
      await tmp.rename(f.path);
    } catch (_) {
      // Clean up the (possibly perm-default) temp file if any step failed.
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {
          // Best effort — nothing more we can do.
        }
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }

  /// chmod [path] to [mode], THROWING on failure (POSIX only). Fail-closed:
  /// a token file we can't confirm is 0600 must not be left holding a secret,
  /// so callers let the exception abort the write rather than persisting with
  /// umask-default (potentially world-readable) permissions.
  Future<void> _chmod(String mode, String path) async {
    if (Platform.isWindows) return; // non-POSIX: filesystem ACLs, not chmod
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'chmod $mode failed (exit ${result.exitCode}): ${result.stderr}',
        path,
      );
    }
  }
}

/// In-memory store — for tests and ephemeral use only (nothing persists).
class InMemoryTokenStore implements TokenStore {
  final Map<String, String> _m = {};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async => _m[key] = value;

  @override
  Future<void> delete(String key) async => _m.remove(key);
}

/// Per-OS default application-support directory for [FileTokenStore], resolved
/// from environment variables (no `path_provider` dependency, so it also works
/// from a plain `dart run` tool):
///
/// - macOS: `~/Library/Application Support/<appName>`
/// - Linux/other POSIX: `$XDG_DATA_HOME/<appName>` or `~/.local/share/<appName>`
String defaultTokenStoreDir({String appName = 'slaudio-mobile'}) {
  final env = Platform.environment;
  final home = env['HOME'] ?? Directory.current.path;
  if (Platform.isMacOS) {
    return '$home/Library/Application Support/$appName';
  }
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return '$xdg/$appName';
  return '$home/.local/share/$appName';
}

/// The platform-appropriate default store:
///
/// - Android / iOS → [SecureStorageTokenStore] (OS-backed secure enclave)
/// - everything else (macOS, Linux, desktop) → [FileTokenStore] under
///   [defaultTokenStoreDir]
///
/// See [FileTokenStore] for why desktop deliberately avoids the keychain.
TokenStore defaultTokenStore({String appName = 'slaudio-mobile'}) {
  if (Platform.isAndroid || Platform.isIOS) {
    return SecureStorageTokenStore();
  }
  return FileTokenStore(defaultTokenStoreDir(appName: appName));
}
