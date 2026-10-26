import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

import 'support/fakes.dart';

/// One backing store for every environment, as Android's secure storage is
/// for every build sharing the application id. Records each key touched.
class _SharedSecureStore extends InMemoryTokenStore {
  final List<String> written = [];
  final List<String> deleted = [];
  final Set<String> touched = {};

  @override
  Future<String?> read(String key) {
    touched.add(key);
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    touched.add(key);
    written.add(key);
    return super.write(key, value);
  }

  @override
  Future<void> delete(String key) {
    touched.add(key);
    deleted.add(key);
    return super.delete(key);
  }
}

AuthService _service(TokenStore store) =>
    AuthService.withEndpoint(endpoint: FakeEndpoint(), store: store);

/// What a fresh process of the environment restores from [store].
Future<bool> _restores(TokenStore store) async {
  final service = _service(store);
  final restored = await service.restoreFromStorage();
  service.dispose();
  return restored;
}

Future<void> _signIn(TokenStore store, String refreshToken) async {
  final service = _service(store);
  await service.storeTokens({
    'access_token': makeJwt('user-1'),
    'refresh_token': refreshToken,
    'id_token': 'id-token',
    'expires_in': 900,
  });
  service.dispose();
}

/// Every at-rest key AuthService uses (its marker included), as the
/// un-namespaced `slauth_*` names a production app keeps today.
const _plainKeys = {
  'slauth_access_token',
  'slauth_refresh_token',
  'slauth_id_token',
  'slauth_expires_at',
  'slauth_write_in_progress',
};

Set<String> _namespaced(String ns) => {for (final k in _plainKeys) '$ns.$k'};

void main() {
  late _SharedSecureStore shared;
  late TokenStore dev;
  late TokenStore prod;

  tearDown(() => debugTokenStoreMobileOverride = null);

  setUp(() {
    shared = _SharedSecureStore();
    dev = NamespacedTokenStore(shared, namespace: 'app-dev');
    prod = NamespacedTokenStore(shared, namespace: 'app-prod');
  });

  group('NamespacedTokenStore', () {
    test(
      'read / write / delete go to <namespace>.<key> in the inner store',
      () async {
        await dev.write('k', 'v');
        expect(shared.written, ['app-dev.k']);
        expect(await shared.read('app-dev.k'), 'v');
        expect(await shared.read('k'), isNull);
        expect(await dev.read('k'), 'v');
        await dev.delete('k');
        expect(shared.deleted, ['app-dev.k']);
        expect(await shared.read('app-dev.k'), isNull);
      },
    );

    test('exposes its inner store and namespace', () {
      final store = NamespacedTokenStore(shared, namespace: 'app-dev');
      expect(store.inner, same(shared));
      expect(store.namespace, 'app-dev');
    });
  });

  group('environments over one secure store', () {
    test('dev does not see the prod session, nor prod the dev one', () async {
      await _signIn(prod, 'rt-prod');
      expect(await _restores(prod), isTrue);
      expect(await _restores(dev), isFalse);

      shared.touched.clear();
      await _signIn(dev, 'rt-dev');
      expect(shared.touched, everyElement(startsWith('app-dev.')));
      expect(await _restores(dev), isTrue);

      // Each keeps its own refresh token (at-rest key name).
      expect(await dev.read(kRefresh), 'rt-dev');
      expect(await prod.read(kRefresh), 'rt-prod');
    });

    test(
      'every key, the write-in-progress marker included, is namespaced',
      () async {
        await _signIn(prod, 'rt-prod');
        expect(shared.touched, isNotEmpty);
        expect(shared.touched, everyElement(startsWith('app-prod.')));
        // A new session's pass writes the marker first and deletes it last.
        expect(shared.written.first, 'app-prod.$kMarker');
        expect(shared.deleted.last, 'app-prod.$kMarker');
        expect(shared.touched, isNot(contains(kMarker)));
      },
    );

    test('a dev logout leaves the prod session', () async {
      await _signIn(prod, 'rt-prod');
      await _signIn(dev, 'rt-dev');

      final devService = _service(dev);
      await devService.restoreFromStorage();
      await devService.logout();
      devService.dispose();

      expect(await _restores(dev), isFalse);
      expect(await _restores(prod), isTrue);
    });

    test(
      "a dev pass stopped half-way doesn't block the prod session",
      () async {
        await _signIn(prod, 'rt-prod');
        // Dev's marker left behind (a crash mid-write).
        await dev.write(kMarker, '1');
        expect(await _restores(dev), isFalse);
        expect(await _restores(prod), isTrue);
      },
    );
  });

  group('defaultTokenStore key names', () {
    test(
      'the default writes exactly today\'s slauth_* names: mobile',
      () async {
        // mobileNamespace omitted (null): the store is the secure store itself.
        final store = defaultTokenStoreFor(
          mobile: true,
          appName: 'myapp',
          secureStore: () => shared,
        );
        expect(identical(store, shared), isTrue);

        await _signIn(store, 'rt');
        expect(shared.touched, _plainKeys);
        expect(shared.touched, everyElement(startsWith('slauth_')));
        expect(shared.written.first, 'slauth_write_in_progress');
      },
    );

    test(
      'the default writes exactly today\'s slauth_* names: desktop',
      () async {
        final tmp = await Directory.systemTemp.createTemp(
          'slauth_default_test',
        );
        addTearDown(() => tmp.delete(recursive: true));
        final store = defaultTokenStoreFor(
          mobile: false,
          appName: 'myapp',
          desktopDir: '${tmp.path}/tokens',
        );
        expect(store, isA<FileTokenStore>());

        await _signIn(store, 'rt');
        // One file per key; the marker is gone once the session is whole.
        final names = Directory(
          '${tmp.path}/tokens',
        ).listSync().map((e) => e.uri.pathSegments.last).toSet();
        expect(names, _plainKeys.difference({'slauth_write_in_progress'}));
      },
    );

    test(
      'mobileNamespace writes <ns>.slauth_*, as the app copies did',
      () async {
        final store = defaultTokenStoreFor(
          mobile: true,
          appName: 'lumen-dev',
          mobileNamespace: 'lumen-dev',
          secureStore: () => shared,
        );
        expect(
          store,
          isA<NamespacedTokenStore>()
              .having((s) => s.namespace, 'namespace', 'lumen-dev')
              .having((s) => s.inner, 'inner', same(shared)),
        );

        await _signIn(store, 'rt');
        expect(shared.touched, _namespaced('lumen-dev'));

        // The same names the apps' own NamespacedTokenStore copies wrote.
        final copy = _SharedSecureStore();
        await _signIn(NamespacedTokenStore(copy, namespace: 'lumen-dev'), 'rt');
        expect(shared.touched, copy.touched);
        expect(shared.written, copy.written);
        expect(shared.deleted, copy.deleted);
      },
    );

    test('mobileNamespace never reaches the desktop store', () async {
      final tmp = await Directory.systemTemp.createTemp('slauth_default_test');
      addTearDown(() => tmp.delete(recursive: true));
      final store = defaultTokenStoreFor(
        mobile: false,
        appName: 'myapp',
        mobileNamespace: 'myapp-dev',
        desktopDir: '${tmp.path}/tokens',
      );
      expect(store, isA<FileTokenStore>());
      await _signIn(store, 'rt');
      final names = Directory(
        '${tmp.path}/tokens',
      ).listSync().map((e) => e.uri.pathSegments.last);
      expect(names, everyElement(startsWith('slauth_')));
    });

    test('an empty mobileNamespace is refused, not written as .slauth_*', () {
      expect(
        () => defaultTokenStoreFor(
          mobile: true,
          appName: 'myapp',
          mobileNamespace: '',
          secureStore: () => shared,
        ),
        throwsArgumentError,
      );
      expect(
        () => defaultTokenStore(appName: 'myapp', mobileNamespace: ''),
        throwsArgumentError,
      );
    });

    group('the public defaultTokenStore on mobile', () {
      setUp(() => debugTokenStoreMobileOverride = true);

      test('without mobileNamespace it is the bare secure store', () {
        final store = defaultTokenStore(appName: 'myapp');
        expect(store, isA<SecureStorageTokenStore>());
        expect(store, isNot(isA<NamespacedTokenStore>()));
      });

      test('mobileNamespace wraps the secure store in that namespace', () {
        final store = defaultTokenStore(
          appName: 'myapp',
          mobileNamespace: 'lumen-dev',
        );
        expect(
          store,
          isA<NamespacedTokenStore>()
              .having((s) => s.namespace, 'namespace', 'lumen-dev')
              .having((s) => s.inner, 'inner', isA<SecureStorageTokenStore>()),
        );
      });

      test('appName alone never becomes a namespace', () {
        final store = defaultTokenStore(appName: 'lumen-dev');
        expect(store, isA<SecureStorageTokenStore>());
        expect(store, isNot(isA<NamespacedTokenStore>()));
      });
    });

    test('on this host (desktop) the public entry point is unchanged', () {
      final plain = defaultTokenStore(appName: 'myapp');
      final opted = defaultTokenStore(appName: 'myapp', mobileNamespace: 'x');
      for (final store in [plain, opted]) {
        expect(
          store,
          isA<FileTokenStore>().having(
            (s) => s.dirPath,
            'dirPath',
            endsWith('/myapp'),
          ),
        );
      }
    });
  });
}
