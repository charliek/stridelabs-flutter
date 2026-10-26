import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

/// A [TokenStore] that keeps every key under `<namespace>.` in [inner]: two
/// namespaces over one backing store never see each other's keys. Every key
/// [AuthService](auth_service.dart) uses passes through here, its
/// write-in-progress marker included, so a half-written session of one
/// namespace never blocks or leaks into another.
///
/// Use it where several environments of one app share a backing store, e.g.
/// dev and prod builds with one application id over Android's secure storage
/// (see `defaultTokenStore`'s `mobileNamespace`).
class NamespacedTokenStore implements TokenStore {
  NamespacedTokenStore(this.inner, {required this.namespace})
    : _prefix = '$namespace.';

  /// The backing store.
  final TokenStore inner;

  /// The store name, e.g. `myapp-dev`.
  final String namespace;

  final String _prefix;

  String _key(String key) => '$_prefix$key';

  @override
  Future<String?> read(String key) => inner.read(_key(key));

  @override
  Future<void> write(String key, String value) => inner.write(_key(key), value);

  @override
  Future<void> delete(String key) => inner.delete(_key(key));
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

/// Test-only override of [defaultTokenStore]'s platform check, in the style of
/// Flutter's `debugDefaultTargetPlatformOverride`: `true` takes the Android/iOS
/// branch, `false` the desktop one, `null` (the default) asks [Platform]. It lets
/// a test on a desktop host exercise the PUBLIC [defaultTokenStore] (in
/// particular its `mobileNamespace` forwarding). Reset it to `null` afterwards.
@visibleForTesting
bool? debugTokenStoreMobileOverride;

/// The platform-appropriate default store:
///
/// - Android / iOS → [SecureStorageTokenStore] (OS-backed secure enclave)
/// - everything else (macOS, Linux, desktop) → [FileTokenStore] under
///   [defaultTokenStoreDir]
///
/// See [FileTokenStore] for why desktop deliberately avoids the keychain.
///
/// [appName] only names the desktop directory. On Android/iOS every app
/// environment shares the one secure store under the same `slauth_*` keys
/// (dev and prod builds share an application id, and an iOS keychain outlives
/// an uninstall), so a dev build installed over a prod one restores the prod
/// session. [mobileNamespace] opts out of that: when set, the mobile store is
/// wrapped in a [NamespacedTokenStore], so its keys become
/// `<mobileNamespace>.slauth_*`. `null` (the default) keeps exactly the
/// un-namespaced `slauth_*` keys, so a consumer that does not opt in is
/// untouched. Opting in later starts that environment signed out once (the
/// session sits under the old keys; nothing is migrated), so do it where
/// no session was stored under the plain keys, or where a one-time sign-out
/// is acceptable. Desktop ignores [mobileNamespace]: its directory is already
/// per [appName].
TokenStore defaultTokenStore({
  String appName = 'slaudio-mobile',
  String? mobileNamespace,
}) => defaultTokenStoreFor(
  mobile:
      debugTokenStoreMobileOverride ?? (Platform.isAndroid || Platform.isIOS),
  appName: appName,
  mobileNamespace: mobileNamespace,
);

/// [defaultTokenStore]'s platform decision as a seam: [mobile] stands for
/// "running on Android/iOS", [secureStore] builds the mobile backing store
/// (default [SecureStorageTokenStore]) and [desktopDir] replaces
/// [defaultTokenStoreDir]. Only tests pass the last two.
@visibleForTesting
TokenStore defaultTokenStoreFor({
  required bool mobile,
  required String appName,
  String? mobileNamespace,
  TokenStore Function()? secureStore,
  String? desktopDir,
}) {
  if (mobileNamespace != null && mobileNamespace.isEmpty) {
    // `''` would write `.slauth_*`: a typo, not a namespace.
    throw ArgumentError.value(
      mobileNamespace,
      'mobileNamespace',
      'must not be empty (use null for the un-namespaced keys)',
    );
  }
  if (mobile) {
    final store = secureStore?.call() ?? SecureStorageTokenStore();
    return mobileNamespace == null
        ? store
        : NamespacedTokenStore(store, namespace: mobileNamespace);
  }
  return FileTokenStore(desktopDir ?? defaultTokenStoreDir(appName: appName));
}
