import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/src/token_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('slauth_store_test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('FileTokenStore', () {
    test('round-trip write / read / overwrite / delete', () async {
      final store = FileTokenStore('${tmp.path}/tokens');

      expect(await store.read('slauth_access_token'), isNull);

      await store.write('slauth_access_token', 'token-v1');
      expect(await store.read('slauth_access_token'), 'token-v1');

      // Atomic overwrite (temp + rename) replaces the value.
      await store.write('slauth_access_token', 'token-v2');
      expect(await store.read('slauth_access_token'), 'token-v2');

      await store.delete('slauth_access_token');
      expect(await store.read('slauth_access_token'), isNull);
    });

    test('file is 0600 and dir is 0700 on POSIX', () async {
      final dir = '${tmp.path}/tokens';
      final store = FileTokenStore(dir);
      await store.write('slauth_refresh_token', 'secret');

      if (Platform.isWindows) {
        return; // non-POSIX: ACL-based, chmod is a no-op — skip perm assertions
      }

      final fileStat = await File('$dir/slauth_refresh_token').stat();
      expect(fileStat.mode & 0x1FF, 0x180, reason: 'file should be 0600');

      final dirStat = await Directory(dir).stat();
      expect(dirStat.mode & 0x1FF, 0x1C0, reason: 'dir should be 0700');
    });

    test(
      'a failed atomic rename cleans up the secret-bearing temp file',
      () async {
        final dir = '${tmp.path}/tokens';
        await Directory(dir).create(recursive: true);
        const key = 'slauth_refresh_token';
        final target = File('$dir/$key');
        // Occupy the destination with a directory so the final atomic rename
        // fails. The write must throw AND remove the uniquely-named temp file it
        // created — otherwise a secret-bearing file (each write uses a distinct
        // temp path now, so a fixed `.tmp` can't be recreated under default
        // perms by an overlapping write) would be left behind on disk.
        await Directory(target.path).create();
        final store = FileTokenStore(dir);

        await expectLater(store.write(key, 'secret-value'), throwsA(anything));

        // Only the occupying directory remains; the temp file was cleaned up.
        final leftoverFiles = Directory(dir).listSync().whereType<File>();
        expect(
          leftoverFiles,
          isEmpty,
          reason: 'the temp file must be removed when the write fails',
        );
      },
    );

    test(
      'write throws (fail-closed) when the dir chmod cannot be applied (POSIX)',
      () async {
        if (Platform.isWindows) return;
        // Point the store at a path occupied by a regular file: dir.create fails,
        // and even if it didn't, chmod on a bogus dir would — either way write
        // must throw rather than silently persisting a weak-perm token.
        final bogus = File('${tmp.path}/not-a-dir');
        await bogus.writeAsString('x');
        final store = FileTokenStore(bogus.path);
        await expectLater(
          store.write('slauth_access_token', 'secret'),
          throwsA(anything),
        );
      },
    );
  });

  group('InMemoryTokenStore', () {
    test('round-trip', () async {
      final store = InMemoryTokenStore();
      expect(await store.read('k'), isNull);
      await store.write('k', 'v');
      expect(await store.read('k'), 'v');
      await store.delete('k');
      expect(await store.read('k'), isNull);
    });
  });

  group('defaultTokenStoreDir', () {
    test('resolves a per-OS app-support path', () {
      final dir = defaultTokenStoreDir(appName: 'slaudio-mobile');
      expect(dir, contains('slaudio-mobile'));
      expect(dir, isNotEmpty);
    });
  });
}
