import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/src/transport/relay_channel_stub.dart' as web;
import 'package:stridelabs_voice/stridelabs_voice.dart';

/// The real `dart:io` relay connector against a local server: a refused
/// upgrade surfaces its HTTP status, the bearer travels in a header, text
/// and binary frames go both ways, and the server's close code is reported.
void main() {
  group('connectRelay (dart:io)', () {
    late HttpServer server;
    late Uri base;
    final authorizations = <String?>[];
    final received = <Object?>[];
    final clientCloseCodes = <int?>[];
    // Completes when the server side of the (one) socket has seen its close.
    late Completer<void> serverSocketDone;

    setUp(() async {
      authorizations.clear();
      received.clear();
      clientCloseCodes.clear();
      serverSocketDone = Completer<void>();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('ws://127.0.0.1:${server.port}');
      server.listen((request) async {
        final refuse = int.tryParse(
          request.uri.queryParameters['status'] ?? '',
        );
        if (refuse != null) {
          request.response.statusCode = refuse;
          await request.response.close();
          return;
        }
        authorizations.add(request.headers.value('authorization'));
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen(
          (message) {
            received.add(message);
            if (message == '{"type":"end"}') {
              socket.add('{"type":"end_of_turn","text":"done"}');
              socket.close(4002, 'limit reached');
            }
          },
          onDone: () {
            clientCloseCodes.add(socket.closeCode);
            if (!serverSocketDone.isCompleted) serverSocketDone.complete();
          },
        );
        socket.add('{"type":"ready"}');
      });
    });

    tearDown(() => server.close(force: true));

    for (final status in [401, 404, 429, 503]) {
      test('a $status upgrade is a RelayUpgradeException($status)', () async {
        await expectLater(
          connectRelay(
            base.replace(
              path: '/voice/stream',
              queryParameters: {'status': '$status'},
            ),
            headers: const {'Authorization': 'Bearer t'},
          ),
          throwsA(
            isA<RelayUpgradeException>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
        );
      });
    }

    test(
      'nothing listening is a RelayUpgradeException with no status',
      () async {
        final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close();
        await expectLater(
          connectRelay(
            Uri.parse('ws://127.0.0.1:$port/voice/stream'),
            headers: const {},
          ),
          throwsA(
            isA<RelayUpgradeException>().having(
              (e) => e.statusCode,
              'statusCode',
              isNull,
            ),
          ),
        );
      },
    );

    test('frames both ways, then the server close code', () async {
      final channel = await connectRelay(
        base.replace(path: '/voice/stream'),
        headers: const {'Authorization': 'Bearer tok-1'},
      );
      expect(authorizations, ['Bearer tok-1']);
      final messages = <Object?>[];
      final done = Completer<void>();
      channel.messages.listen(messages.add, onDone: done.complete);

      channel.sendAudio(Uint8List.fromList([1, 2, 3, 4]));
      channel.sendText('{"type":"end"}');
      await done.future.timeout(const Duration(seconds: 5));

      expect(messages, [
        '{"type":"ready"}',
        '{"type":"end_of_turn","text":"done"}',
      ]);
      expect(received, [
        [1, 2, 3, 4],
        '{"type":"end"}',
      ]);
      expect(channel.closeCode, 4002);
      await channel.close(1000); // already closed: a no-op
    });

    test('close(code) sends that code, once', () async {
      final channel = await connectRelay(
        base.replace(path: '/voice/stream'),
        headers: const {},
      );
      await channel.close(4101);
      await channel.close(1000); // idempotent: the first code is the one sent
      await serverSocketDone.future.timeout(const Duration(seconds: 5));
      expect(clientCloseCodes, [4101]);
    });

    test('close(1000) sends a normal close', () async {
      final channel = await connectRelay(
        base.replace(path: '/voice/stream'),
        headers: const {},
      );
      await channel.close(1000);
      await serverSocketDone.future.timeout(const Duration(seconds: 5));
      expect(clientCloseCodes, [1000]);
    });
  });

  group('relayStreamUri', () {
    test('maps http to ws and https to wss, keeping host, port and path', () {
      String uri(String base, int rate) =>
          relayStreamUri(Uri.parse(base), rate).toString();
      expect(
        uri('http://localhost:8000', 24000),
        'ws://localhost:8000/voice/stream?rate=24000',
      );
      expect(
        uri('https://lumen.charliek.us', 16000),
        'wss://lumen.charliek.us/voice/stream?rate=16000',
      );
      expect(
        uri('https://example.com/api/', 24000),
        'wss://example.com/api/voice/stream?rate=24000',
      );
      expect(
        uri('http://10.0.2.2:8200/', 24000),
        'ws://10.0.2.2:8200/voice/stream?rate=24000',
      );
      // The base's own query is not carried: `rate` is the only parameter.
      expect(
        uri('https://example.com/api?tenant=a', 16000),
        'wss://example.com/api/voice/stream?rate=16000',
      );
    });
  });

  // tapper's web stub (no dart:io): every upgrade fails as unreachable.
  group('connectRelay (web stub)', () {
    test('refuses every upgrade with no status, reaching nothing', () async {
      await expectLater(
        web.connectRelay(
          Uri.parse('wss://example.com/voice/stream?rate=24000'),
          headers: const {'Authorization': 'Bearer t'},
        ),
        throwsA(
          isA<RelayUpgradeException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
    });
  });
}
