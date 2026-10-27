import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';
import 'package:stridelabs_voice/testing.dart';

import 'support/speech.dart';

/// A smoke test per public fake of `testing.dart` (D1 §8.4): each does the
/// one thing an app's tests rely on it for. The deeper behaviour is covered
/// where the package's own tests use them (the transport's and the speaker's).
void main() {
  group('FakeMicCapture', () {
    test('permission, per-rate refusals, fed chunks and teardown', () async {
      final mic = FakeMicCapture(refusedRates: {24000});
      expect(await mic.hasPermission(), isTrue);
      mic.permission = false;
      expect(await mic.hasPermission(), isFalse);

      await expectLater(mic.start(24000), throwsStateError);
      expect(mic.capturing, isFalse);
      final stream = await mic.start(16000);
      expect(mic.startedRates, [24000, 16000]);
      expect(mic.capturing, isTrue);

      final chunks = <Uint8List>[];
      var done = false;
      stream.listen(chunks.add, onDone: () => done = true);
      mic.feed(Uint8List.fromList([1, 2]));
      await pumpEventQueue();
      expect(chunks, [
        [1, 2],
      ]);

      await mic.stop();
      await mic.dispose();
      await pumpEventQueue();
      expect(
        [mic.stopCount, mic.disposeCount, done, mic.capturing],
        [1, 1, isTrue, isFalse],
      );
    });
  });

  group('FakeRelayServer and FakeRelayChannel', () {
    test(
      'an upgrade answers a channel that sends events, raw and close',
      () async {
        final server = FakeRelayServer();
        final uri = Uri.parse('wss://relay.test/voice/stream?rate=16000');
        final channel =
            await server.connect(uri, headers: {'authorization': 'Bearer t'})
                as FakeRelayChannel;
        expect(identical(channel, server.channel), isTrue);
        expect(channel.rate, 16000);
        expect(server.attempts.single.uri, uri);
        expect(server.attempts.single.headers, {'authorization': 'Bearer t'});

        final frames = <Object?>[];
        var closeCode = -1;
        channel.messages.listen(
          frames.add,
          onDone: () => closeCode = channel.closeCode ?? -1,
        );
        channel.ready(rates: [24000, 16000], encoding: kPcmS16le, leadMs: 3000);
        channel.send(const RelayEndOfTurn('hello'));
        channel.sendRaw('{"type":"newer","x":1}');
        channel.serverClose(RelayCloseCode.done);
        await pumpEventQueue();

        final ready = RelayEvent.parse(frames[0] as String) as RelayReady;
        expect(
          [ready.rates, ready.encoding, ready.leadMs],
          [
            [24000, 16000],
            kPcmS16le,
            3000,
          ],
        );
        expect(
          (RelayEvent.parse(frames[1] as String) as RelayEndOfTurn).text,
          'hello',
        );
        expect(frames[2], '{"type":"newer","x":1}');
        expect(closeCode, RelayCloseCode.done);
        expect(server.verify(), isEmpty);
      },
    );

    test('a bare ready advertises nothing', () async {
      final server = FakeRelayServer();
      final channel =
          await server.connect(Uri.parse('wss://r.test/s'), headers: {})
              as FakeRelayChannel;
      final frames = <Object?>[];
      channel.messages.listen(frames.add);
      channel.ready();
      await pumpEventQueue();
      final ready = RelayEvent.parse(frames.single as String) as RelayReady;
      expect([ready.rates, ready.encoding, ready.leadMs], [null, null, null]);
    });

    test('the rules are enforced: a breach is a violation', () async {
      final server = FakeRelayServer();
      final channel =
          await server.connect(Uri.parse('wss://r.test/s'), headers: {})
              as FakeRelayChannel;
      channel.sendAudio(speech(4));
      expect(server.violations.single, contains('audio before ready'));
      server.violations.clear();

      channel.ready();
      channel.sendAudio(speech(3));
      expect(server.violations.single, contains('an odd frame'));
      server.violations.clear();
      // 24000 Hz, 5000 ms of lead: 240,000 B are allowed at t=0.
      channel.sendAudio(speech(64 * 1024));
      channel.sendAudio(speech(64 * 1024));
      channel.sendAudio(speech(64 * 1024));
      expect(server.violations, isEmpty);
      channel.sendAudio(speech(64 * 1024));
      expect(server.violations.single, contains('pacing'));
      server.violations.clear();

      channel.sendText('hello');
      expect(server.violations.single, contains('a text frame other than end'));
      server.violations.clear();

      channel.sendText(kRelayEndFrame);
      channel.sendAudio(speech(2));
      expect(server.violations, anyElement(contains('audio after end')));
      expect(channel.endReceived, isTrue);
      expect(channel.audioBytes, 4 + 3 + 4 * 64 * 1024 + 2);
    });

    test('leadMs sets the pacing rule', () async {
      final server = FakeRelayServer(leadMs: 1000);
      final channel =
          await server.connect(Uri.parse('wss://r.test/s'), headers: {})
              as FakeRelayChannel;
      expect(channel.leadMs, 1000);
      channel.ready();
      // 1000 ms at 24 kHz is 48,000 B.
      channel.sendAudio(speech(48000));
      expect(server.violations, isEmpty);
      channel.sendAudio(speech(2));
      expect(server.violations.single, contains('pacing'));
    });

    test('idle: nothing for ten seconds is a violation, by the clock', () {
      var now = Duration.zero;
      final channel = FakeRelayChannel(clock: () => now)..ready();
      now = const Duration(seconds: 11);
      channel.checkIdle();
      expect(channel.violations.single, contains('idle'));
    });

    test(
      'acceptedRates refuses another rate with 422; the script answers',
      () async {
        final server = FakeRelayServer(acceptedRates: {16000});
        await expectLater(
          server.connect(Uri.parse('wss://r.test/s?rate=24000'), headers: {}),
          throwsA(
            isA<RelayUpgradeException>().having(
              (e) => e.statusCode,
              'status',
              422,
            ),
          ),
        );
        server.script.addAll([503, StateError('no network'), null]);
        final uri = Uri.parse('wss://r.test/s?rate=16000');
        await expectLater(
          server.connect(uri, headers: {}),
          throwsA(
            isA<RelayUpgradeException>().having(
              (e) => e.statusCode,
              'status',
              503,
            ),
          ),
        );
        await expectLater(server.connect(uri, headers: {}), throwsStateError);
        await server.connect(uri, headers: {});
        expect(server.attempts, hasLength(4));
        expect(server.channels, hasLength(1));
      },
    );

    test('gate holds every upgrade until completed', () {
      fakeAsync((async) {
        final server = FakeRelayServer()..gate = Completer<void>();
        var answered = false;
        server
            .connect(Uri.parse('wss://r.test/s'), headers: {})
            .then((_) => answered = true);
        async.flushMicrotasks();
        expect(answered, isFalse);
        server.gate!.complete();
        async.flushMicrotasks();
        expect(answered, isTrue);
      });
    });

    test('isSilence tells zeros from speech', () {
      expect(isSilence(Uint8List(8)), isTrue);
      expect(isSilence(speech(8)), isFalse);
    });
  });

  group('FakeReplyTts and FakeTtsCall', () {
    test('a send waits for the test; reply answers it', () async {
      final tts = FakeReplyTts()..extras = () => {'binding': 7};
      final request = tts.request('Hi.', voice: 'v', idempotencyKey: 'k1');
      expect(request.extras, {'binding': 7});
      final pending = request.send();
      expect(tts.texts, ['Hi.']);
      expect([tts.last.voice, tts.last.idempotencyKey], ['v', 'k1']);
      expect(tts.last.answered, isFalse);

      tts.last.reply(kFakeMp3, 'audio/mpeg', 1200);
      final clip = await pending;
      expect(clip.bytes, kFakeMp3);
      expect([clip.mediaType, clip.maxTextChars], ['audio/mpeg', 1200]);
      expect(tts.last.answered, isTrue);
    });

    test('autoReply answers 200 at once', () async {
      final tts = FakeReplyTts()..autoReply = true;
      final clip = await tts
          .request('Hi.', voice: 'v', idempotencyKey: 'k')
          .send();
      expect(clip.bytes, kFakeMp3);
    });

    test(
      'failStatus is a DioException carrying status, body and headers',
      () async {
        final tts = FakeReplyTts();
        final pending = tts
            .request('a', voice: 'v', idempotencyKey: 'k')
            .send();
        tts.last.failStatus(429, retryAfter: '30', maxTextChars: 900);
        final error = await pending.then<DioException?>(
          (_) => null,
          onError: (Object e) => e as DioException,
        );
        expect(error!.response!.statusCode, 429);
        expect(error.response!.data, {'detail': 'nope'});
        expect(error.response!.headers.value('retry-after'), '30');
        expect(error.response!.headers.value(kTtsMaxCharsHeader), '900');
      },
    );

    test(
      'the transport failures are told apart as the app\'s Dio shows them',
      () async {
        final failures = <String, void Function(FakeTtsCall)>{
          'network': (c) => c.failNetwork(),
          'reset': (c) => c.failReset(),
          'slow': (c) => c.failSlow(),
          'connect timeout': (c) => c.failConnectTimeout(),
          'body lost': (c) => c.failBodyLost(),
        };
        final retried = <String, bool>{};
        for (final MapEntry(key: name, value: fail) in failures.entries) {
          final tts = FakeReplyTts();
          final pending = tts
              .request('a', voice: 'v', idempotencyKey: 'k')
              .send();
          fail(tts.last);
          final error = await pending.then<Object>(
            (_) => 'no error',
            onError: (Object e) => e,
          );
          retried[name] = error is DioException && isTransportFailure(error);
        }
        expect(retried, {
          'network': true,
          'reset': true,
          'slow': false,
          'connect timeout': false,
          'body lost': false,
        });
      },
    );
  });

  group('FakeTtsAuth', () {
    test(
      'refreshAhead refreshes an expired token once, and says if it did',
      () async {
        final auth = FakeTtsAuth(expired: true);
        expect(await auth.refreshAhead(), isTrue);
        expect(auth.expired, isFalse);
        expect(await auth.refreshAhead(), isTrue);
        expect([auth.aheadCalls, auth.refreshes], [2, 1]);

        final failing = FakeTtsAuth(expired: true, refreshSucceeds: false);
        expect(await failing.refreshAhead(), isFalse);
        expect(failing.expired, isTrue);
      },
    );

    test(
      'refreshAfterUnauthorized records the extras; the gate holds it',
      () async {
        final auth = FakeTtsAuth()..refreshGate = Completer<void>();
        var result = <bool>[];
        final pending = auth
            .refreshAfterUnauthorized({'binding': 1})
            .then(result.add);
        await pumpEventQueue();
        expect(result, isEmpty);
        auth.refreshGate!.complete();
        await pending;
        expect(result, [true]);
        expect(auth.extrasSeen, [
          {'binding': 1},
        ]);
        expect(auth.afterUnauthorizedCalls, 1);
      },
    );
  });

  group('FakeReplyPlayer', () {
    test('clips play in order; the test moves playback on', () async {
      final player = FakeReplyPlayer();
      final events = <ReplyClipEvent>[];
      player.clipEvents.listen(events.add);
      await player.enqueue('a.mp3', mediaType: 'audio/mpeg');
      await player.enqueue('b.mp3', mediaType: 'audio/mpeg');
      await pumpEventQueue();
      expect(events, [const ReplyClipEvent('a.mp3', ReplyClipPhase.started)]);
      expect(player.enqueuedTypes, ['audio/mpeg', 'audio/mpeg']);

      player.finishHead();
      await pumpEventQueue();
      expect(events.skip(1), [
        const ReplyClipEvent('a.mp3', ReplyClipPhase.finished),
        const ReplyClipEvent('b.mp3', ReplyClipPhase.started),
      ]);
      player.finishHead(heard: false);
      await pumpEventQueue();
      expect(events.last, const ReplyClipEvent('b.mp3', ReplyClipPhase.silent));
      expect(player.queue, isEmpty);

      await player.release(captureLive: true);
      await player.stop();
      await player.dispose();
      expect(
        [player.releases, player.stopCount, player.disposed],
        [
          [true],
          1,
          isTrue,
        ],
      );
    });

    test('a silent player starts and fails a clip only on request', () async {
      final player = FakeReplyPlayer()..silent = true;
      final events = <ReplyClipEvent>[];
      player.clipEvents.listen(events.add);
      await player.enqueue('a.mp3', mediaType: 'audio/mpeg');
      await pumpEventQueue();
      expect(events, isEmpty);
      player.startHead();
      player.failHead();
      await pumpEventQueue();
      expect(
        [for (final e in events) e.phase],
        [ReplyClipPhase.started, ReplyClipPhase.failed],
      );
    });
  });

  group('FakeClipFiles', () {
    test(
      'writes by media type, names from the prefix, deletes, sweeps',
      () async {
        final files = FakeClipFiles(prefix: 'app-tts-');
        final path = await files.write(
          Uint8List.fromList(kFakeMp3),
          mediaType: 'audio/mpeg',
        );
        expect(path, endsWith('app-tts-0.mp3'));
        expect(files.files[path], kFakeMp3);
        expect(files.types[path], 'audio/mpeg');

        await expectLater(
          files.write(Uint8List(1), mediaType: 'audio/wav'),
          throwsArgumentError,
        );
        await files.delete(path);
        expect(files.files, isEmpty);
        expect(files.written[path], kFakeMp3, reason: 'kept after deletion');
        expect(files.deleted, [path]);
        await files.sweep();
        expect(files.sweeps, 1);
      },
    );

    test('writeGate holds a write open', () {
      fakeAsync((async) {
        final files = FakeClipFiles()..writeGate = Completer<void>();
        String? path;
        files
            .write(Uint8List(2), mediaType: 'audio/mpeg')
            .then((p) => path = p);
        async.flushMicrotasks();
        expect(path, isNull);
        files.writeGate!.complete();
        async.flushMicrotasks();
        expect(path, isNotNull);
      });
    });
  });

  group('FakeVoiceTransport', () {
    test(
      'connects, records calls, and answers the mic with micResult',
      () async {
        final transport = FakeVoiceTransport();
        expect(transport.isConnected, isFalse);
        await transport.connect('c1');
        expect(
          [transport.isConnected, transport.connectArgs],
          [
            isTrue,
            ['c1'],
          ],
        );
        expect(await transport.enableMicrophone(), MicEnableResult.success);
        transport.micResult = MicEnableResult.denied;
        expect(await transport.enableMicrophone(), MicEnableResult.denied);
        await transport.disableMicrophone();
        expect([transport.micEnableCount, transport.micDisableCount], [2, 1]);

        await transport.disconnect(VoiceDisconnectCause.paused);
        expect(transport.isConnected, isFalse);
        expect(transport.disconnectCauses, [VoiceDisconnectCause.paused]);
        await transport.dispose();
        await transport.dispose();
        expect(transport.disposeCount, 2);
      },
    );

    test('a disconnect during a gated connect cancels it', () async {
      final gate = Completer<void>();
      final transport = FakeVoiceTransport()..connectFuture = gate.future;
      final connecting = expectLater(
        transport.connect('c1'),
        throwsA(isA<VoiceConnectCancelled>()),
      );
      await transport.disconnect(VoiceDisconnectCause.leftConversation);
      gate.complete();
      await connecting;
      expect(transport.isConnected, isFalse);
    });

    test(
      'emit and emitRemoteEnd reach the listeners, the end after isConnected is false',
      () async {
        final transport = FakeVoiceTransport();
        await transport.connect('c1');
        final events = <VoiceTransportEvent>[];
        final ends = <VoiceEnd>[];
        final connectedAtEnd = <bool>[];
        transport.events.listen(events.add);
        transport.remoteEnds.listen((end) {
          ends.add(end);
          connectedAtEnd.add(transport.isConnected);
        });

        transport.emit(const VoiceListening(true));
        final limit = VoiceLimit(
          VoiceLimitScope.userDay,
          DateTime.utc(2026, 10, 27),
        );
        transport.emitRemoteEnd(
          VoiceEndReason.closedByServer,
          VoiceEndNotice.limitReached,
          limit,
        );
        await pumpEventQueue();
        expect(events, [const VoiceListening(true)]);
        expect(ends, [
          VoiceEnd(
            VoiceEndReason.closedByServer,
            VoiceEndNotice.limitReached,
            limit,
          ),
        ]);
        expect(connectedAtEnd, [false]);
      },
    );
  });

  group('MvoiceLine', () {
    test('parses the event, words, fields and t; drops the elapsed suffix', () {
      final line = MvoiceLine.parse(
        'MVOICE speak_playback_failed reason=start_timeout i=2 t=1700000000123 turn+812ms',
      )!;
      expect(line.event, 'speak_playback_failed');
      expect(line.words, isEmpty);
      expect(line.fields, {'reason': 'start_timeout', 'i': '2'});
      expect(line.t, 1700000000123);
      expect(line.clip, 2);

      final end = MvoiceLine.parse(
        'MVOICE session_end closedByServer limitReached t=5 +40ms',
      )!;
      expect(end.words, ['closedByServer', 'limitReached']);
      expect(end.clip, isNull);
      expect(end.toString(), contains('session_end'));
    });

    test('a line with no t has none; a foreign line is null', () {
      expect(MvoiceLine.parse('MVOICE mic_on')!.t, isNull);
      expect(MvoiceLine.parse('flutter: MVOICE mic_on t=1'), isNull);
      expect(MvoiceLine.parse('MVOICE '), isNull);
      expect(MvoiceLine.parse(''), isNull);
    });
  });
}
