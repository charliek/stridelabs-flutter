import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

import 'support/relay_fakes.dart';

/// [RelayVoiceTransport] driven through a fake recorder and a fake relay
/// socket, under fakeAsync (the ready deadline, the 429 retry, the mic-off
/// wait, the half-duplex tail, the keep-alive). 24 kHz unless a test says
/// otherwise: 48 bytes a millisecond, 3840-byte (80 ms) frames.
void main() {
  test(
    'capture is pinned: PCM16 mono, voice processing on, Android in call mode',
    () {
      for (final rate in kDefaultRelaySampleRates) {
        final config = captureConfig(rate);
        expect(config.encoder, AudioEncoder.pcm16bits);
        expect(config.sampleRate, rate);
        expect(config.numChannels, 1);
        expect(
          (config.echoCancel, config.noiseSuppress, config.autoGain),
          (true, true, true),
        );
        // record must not pause the stream when the reply player takes focus.
        expect(config.audioInterruption, AudioInterruptionMode.none);
        expect(
          config.androidConfig.audioSource,
          AndroidAudioSource.voiceCommunication,
        );
        expect(
          config.androidConfig.audioManagerMode,
          AudioManagerMode.modeInCommunication,
        );
        expect(config.androidConfig.speakerphone, isTrue);
      }
      expect(kDefaultRelaySampleRates, [24000, 16000]);
    },
  );

  group('connect and mic-on', () {
    test('connect opens nothing; the mic needs a session', () {
      fakeAsync((async) {
        final r = _Relay(async);
        expect(_enable(r), MicEnableResult.notConnected);
        expect(r.mics, isEmpty);

        r.transport.connect('conv-1');
        async.flushMicrotasks();
        expect(r.transport.isConnected, isTrue);
        expect(r.mics, isEmpty);
        expect(r.server.attempts, isEmpty);
      });
    });

    test('a refused permission is denied and opens no socket', () {
      fakeAsync((async) {
        final r = _Relay(async, permission: false);
        expect(_micOn(r), MicEnableResult.denied);
        expect(r.server.attempts, isEmpty);
        expect(r.mic.startedRates, isEmpty);
        expect(r.mic.disposeCount, 1);
      });
    });

    test('capture and the socket start together: 24 kHz, the bearer token, '
        'rate in the URL', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        expect(_micOn(r), isNull, reason: 'capture is still starting');

        // The socket was not left waiting for the recorder.
        expect(r.server.attempts, hasLength(1));
        final attempt = r.server.attempts.single;
        expect(attempt.uri.queryParameters['rate'], '24000');
        expect(attempt.headers['Authorization'], 'Bearer tok-1');
        expect(r.tokenRequests, [false]);
        expect(r.mic.startedRates, [24000]);

        r.mic.startGate!.complete();
        async.flushMicrotasks();
        expect(r.enableResult, MicEnableResult.success);
        expect(r.mic.capturing, isTrue);
      });
    });

    test('a device that refuses 24 kHz captures at 16 kHz, on a socket '
        're-opened at 16 kHz; later sessions start there', () {
      fakeAsync((async) {
        final r = _Relay(async, refusedRates: {24000});
        expect(_micOn(r), MicEnableResult.success);
        expect(r.mic.startedRates, [24000, 16000]);
        expect(r.server.attempts.map((a) => a.uri.queryParameters['rate']), [
          '24000',
          '16000',
        ]);
        expect(r.server.channels.first.closedByClient, isTrue);

        r.server.channel.ready();
        async.flushMicrotasks();
        r.mic.feed(speech(2560 * 2 + 10));
        async.flushMicrotasks();
        expect(r.server.channel.sentAudio.map((f) => f.length), [2560, 2560]);

        _micOff(r);
        expect(_enable(r), MicEnableResult.success);
        expect(r.mics.last.startedRates, [16000]);
        expect(r.server.attempts.last.uri.queryParameters['rate'], '16000');
      });
    });

    test(
      'a device that refuses both rates is unavailable; nothing is left open',
      () {
        fakeAsync((async) {
          final r = _Relay(async, refusedRates: {24000, 16000});
          expect(_micOn(r), MicEnableResult.unavailable);
          expect(r.server.channels, everyElement(_closedByClient));
          expect(r.mic.disposeCount, 1);
          expect(r.ends, isEmpty);
          // The session is gone: the next tap starts afresh.
          r.mics.clear();
          r.refusedRates.clear();
          expect(_enable(r), MicEnableResult.success);
        });
      },
    );
  });

  group('frames', () {
    test('audio is re-chunked into 3840-byte frames, bytes and order kept', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        final input = <int>[];
        for (final size in [1000, 5000, 1, 3, 2000, 7680, 17]) {
          final chunk = Uint8List.fromList([
            for (var i = 0; i < size; i++) (input.length + i) % 251 + 1,
          ]);
          input.addAll(chunk);
          r.mic.feed(chunk);
          async.flushMicrotasks();
        }
        final frames = r.server.channel.sentAudio;
        expect(frames.map((f) => f.length), List.filled(4, 3840));
        expect([for (final f in frames) ...f], input.sublist(0, 4 * 3840));
      });
    });

    test(
      'no audio is sent before ready; then the newest 3 s, oldest dropped',
      () {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          // Four seconds of speech before the relay is ready, each 80 ms frame
          // marked with its index.
          for (var i = 0; i < 50; i++) {
            r.mic.feed(speech(3840, value: i + 1));
            async.elapse(const Duration(milliseconds: 80));
          }
          expect(r.server.channel.sentAudio, isEmpty);

          _ready(r);
          final frames = r.server.channel.sentAudio;
          // 3 s is 37 whole frames (2.96 s): frames 13..49 survive.
          expect(frames, hasLength(37));
          expect(frames.map((f) => f.first), [
            for (var i = 14; i <= 50; i++) i,
          ]);

          // Then live, in order.
          r.mic.feed(speech(3840, value: 99));
          async.flushMicrotasks();
          expect(frames.last.first, 99);
        });
      },
    );

    test('a stalled capture is filled with silence up to real time', () {
      fakeAsync((async) {
        final r = _Relay(async, stallFill: const Duration(seconds: 2));
        _micOn(r);
        _ready(r);
        r.mic.feed(speech(3840));
        async.elapse(const Duration(seconds: 2));
        expect(
          r.server.channel.sentAudio,
          hasLength(1),
          reason: 'not yet 2 s behind',
        );

        async.elapse(const Duration(milliseconds: 500));
        final frames = r.server.channel.sentAudio;
        // Real time is 2.5 s = 120000 bytes: 31 whole frames, all sent.
        expect(r.server.channel.audioBytes, 31 * 3840);
        expect(frames.skip(1), everyElement(predicate(isSilence)));
      });
    });

    test('audio never runs more than 4 s ahead of real time', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        // Five seconds at once (a recorder flushing a backlog).
        r.mic.feed(speech(48 * 5000));
        async.flushMicrotasks();
        expect(r.server.channel.audioBytes, 50 * 3840); // 4.0 s
      });
    });
  });

  group('mic-off', () {
    test('stops capture, sends the rest and end, waits up to 2 s for the '
        'relay, then closes', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.mic.feed(speech(3840 + 100));
        async.flushMicrotasks();

        var done = false;
        r.transport.disableMicrophone().then((_) => done = true);
        async.flushMicrotasks();
        final channel = r.server.channel;
        expect(r.mic.stopCount, greaterThanOrEqualTo(1));
        expect(channel.sent.map(_describe), [
          'audio 3840',
          'audio 100',
          kRelayEndFrame,
        ]);
        expect(done, isFalse);

        async.elapse(const Duration(milliseconds: 1999));
        expect(done, isFalse);
        expect(channel.closedByClient, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue);
        expect(channel.clientCloseCode, 1000);
        expect(r.mic.disposeCount, 1);
        expect(r.ends, isEmpty);
      });
    });

    test("the relay's close after end ends mic-off at once, silently", () {
      for (final code in [1000, 4002, null]) {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          _ready(r);
          var done = false;
          r.transport.disableMicrophone().then((_) => done = true);
          async.flushMicrotasks();
          r.server.channel.serverClose(code);
          async.flushMicrotasks();
          expect(done, isTrue, reason: '$code');
          expect(r.ends, isEmpty, reason: '$code');
        });
      }
    });

    test('the pending end_of_turn after end is posted at once', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        final channel = r.server.channel;
        channel.send(const RelaySpeechStart());
        channel.send(const RelayPartial('what is the weather in'));
        async.flushMicrotasks();

        r.transport.disableMicrophone();
        async.flushMicrotasks();
        expect(r.utterances, isEmpty);
        // Unfinished-looking, but the mic is off: no merge wait.
        channel.send(const RelayEndOfTurn('What is the weather in'));
        async.flushMicrotasks();
        expect(r.texts, ['What is the weather in']);
      });
    });

    test('a segment still open after the wait is flushed with its partial', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayPartial('turn on the lights'));
        async.flushMicrotasks();
        r.transport.disableMicrophone();
        async.elapse(const Duration(seconds: 2));
        expect(r.texts, ['turn on the lights']);
      });
    });

    test(
      'before ready: the buffered speech and end go out once it is ready',
      () {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          r.mic.feed(speech(3840 * 2));
          async.flushMicrotasks();
          var done = false;
          r.transport.disableMicrophone().then((_) => done = true);
          async.flushMicrotasks();
          expect(r.server.channel.sent, isEmpty);

          _ready(r);
          expect(r.server.channel.sent.map(_describe), [
            'audio 3840',
            'audio 3840',
            kRelayEndFrame,
          ]);
          r.server.channel.serverClose(1000);
          async.flushMicrotasks();
          expect(done, isTrue);
        });
      },
    );

    test('listening lasts exactly while a heard segment is open', () {
      // The relay's input to the state arbiter: `listening` at speech_start,
      // `idle` when the segment closes — whether or not a turn came of it
      // (the arbiter ranks a turn's `thinking` above it).
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel.send(const RelaySpeechStart());
        async.flushMicrotasks();
        expect(r.states, [_listening]);
        r.server.channel.send(const RelayEndOfTurn('')); // noise
        async.flushMicrotasks();
        expect(r.states, [_listening, _idle]);
        // Mic-off with no segment open reports nothing more.
        r.events.clear();
        _micOff(r);
        expect(r.states, isEmpty);
      });
    });

    test("the assembler's fallback flush ends the segment's listening", () {
      // A speech_start whose end_of_turn never comes: the assembler flushes
      // 1 s after speech_end (10 s after the start without one).
      for (final withEnd in [true, false]) {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          _ready(r);
          r.server.channel
            ..send(const RelaySpeechStart())
            ..send(const RelayPartial('turn on the'));
          if (withEnd) r.server.channel.send(const RelaySpeechEnd());
          async.flushMicrotasks();
          expect(r.states, [_listening]);
          async.elapse(Duration(seconds: withEnd ? 1 : 10));
          expect(r.states, [_listening, _idle], reason: 'withEnd=$withEnd');
          expect(r.texts, ['turn on the']);
          // The segment is closed: a reply starting now cuts nothing.
          r.speakerPlaying = true;
          async.flushMicrotasks();
          expect(r.states, hasLength(2));
          expect(r.texts, ['turn on the']);
          r.speakerPlaying = false;
          async.elapse(const Duration(seconds: 1));
          _micOff(r);
        });
      }
    });

    test('a segment still open at mic-off ends its listening there', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel.send(const RelaySpeechStart());
        async.flushMicrotasks();
        r.transport.disableMicrophone();
        async.flushMicrotasks();
        r.server.channel.serverClose(1000);
        async.flushMicrotasks();
        expect(r.states, [_listening, _idle]);
      });
    });

    test('a segment the reply cuts (half-duplex) ends its listening', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayPartial('book a'));
        async.flushMicrotasks();
        r.speakerPlaying = true;
        async.flushMicrotasks();
        expect(r.states, [_listening, _idle]);
        r.speakerPlaying = false;
        async.elapse(const Duration(seconds: 1));
        _micOff(r);
      });
    });
  });

  group('upgrade failures', () {
    test('a 401 refreshes the token and retries once', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.script.add(401);
        expect(_micOn(r), MicEnableResult.success);
        expect(r.server.attempts.map((a) => a.headers['Authorization']), [
          'Bearer tok-1',
          'Bearer tok-fresh',
        ]);
        expect(r.tokenRequests, [false, true]);
        _ready(r);
        r.mic.feed(speech(3840));
        async.flushMicrotasks();
        expect(r.server.channel.sentAudio, hasLength(1));
        expect(r.ends, isEmpty);
      });
    });

    test('401 then 429: the token is refreshed once, the retry reuses it', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.script.addAll([401, 429]);
        expect(_micOn(r), MicEnableResult.success);
        async.elapse(const Duration(milliseconds: 2100));
        expect(r.server.attempts.map((a) => a.headers['Authorization']), [
          'Bearer tok-1',
          'Bearer tok-fresh',
          'Bearer tok-fresh',
        ]);
        expect(r.tokenRequests, [false, true, false]);
        expect(r.ends, isEmpty);
      });
    });

    test('a second 401 ends the session (no third attempt)', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.script.addAll([401, 401]);
        _micOn(r);
        expect(r.server.attempts, hasLength(2));
        expect(r.ends, [const VoiceEnd(VoiceEndReason.closedByServer)]);
        expect(r.connectedAtEnd, [false]);
        expect(r.mic.disposeCount, 1);
      });
    });

    for (final (status, end) in <(Object, VoiceEnd)>[
      (
        404,
        const VoiceEnd(
          VoiceEndReason.closedByServer,
          VoiceEndNotice.unavailable,
        ),
      ),
      (
        503,
        const VoiceEnd(
          VoiceEndReason.closedByServer,
          VoiceEndNotice.unavailable,
        ),
      ),
      (500, const VoiceEnd(VoiceEndReason.dropped)),
      (422, const VoiceEnd(VoiceEndReason.dropped)),
      (
        const RelayUpgradeException(null),
        const VoiceEnd(VoiceEndReason.dropped),
      ),
      (
        StateError('connection refused'),
        const VoiceEnd(VoiceEndReason.dropped),
      ),
    ]) {
      // A 422 now moves to the next candidate rate (PROTOCOL.md §3.2): it
      // ends the session only once no rate is left, one attempt per rate.
      final attempts = status == 422 ? kDefaultRelaySampleRates.length : 1;
      test(
        '$status at the upgrade -> $end, '
        '${attempts == 1 ? 'one attempt' : 'one attempt per default rate'}',
        () {
          fakeAsync((async) {
            final r = _Relay(async);
            r.server.script.addAll(List.filled(attempts, status));
            _micOn(r);
            expect(r.server.attempts, hasLength(attempts));
            expect(r.ends, [end]);
            expect(r.transport.isConnected, isFalse);
          });
        },
      );
    }

    test('a 429 waits 2.1 s and retries once', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.script.add(429);
        expect(_micOn(r), MicEnableResult.success);
        expect(r.server.attempts, hasLength(1));
        async.elapse(const Duration(milliseconds: 2099));
        expect(r.server.attempts, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(r.server.attempts, hasLength(2));
        expect(r.ends, isEmpty);
      });
    });

    test('a second 429 is the voice limit', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.script.addAll([429, 429]);
        _micOn(r);
        async.elapse(const Duration(milliseconds: 2100));
        expect(r.server.attempts, hasLength(2));
        expect(r.ends, [
          const VoiceEnd(
            VoiceEndReason.closedByServer,
            VoiceEndNotice.limitReached,
          ),
        ]);
      });
    });

    test('no ready within 12 s is a drop', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        async.elapse(const Duration(milliseconds: 11999));
        expect(r.ends, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
        expect(r.server.channel.closedByClient, isTrue);
        expect(r.mic.disposeCount, 1);
      });
    });

    test('a 404 that lands while capture is starting ends the mic-on', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.script.add(404);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        _micOn(r);
        expect(r.ends, [
          const VoiceEnd(
            VoiceEndReason.closedByServer,
            VoiceEndNotice.unavailable,
          ),
        ]);
        r.mic.startGate!.complete();
        async.flushMicrotasks();
        expect(r.enableResult, MicEnableResult.notConnected);
        expect(r.mic.disposeCount, 1);
      });
    });
  });

  group('closes while the mic is on', () {
    for (final (code, end) in <(int?, VoiceEnd)>[
      (
        4000,
        const VoiceEnd(
          VoiceEndReason.closedByServer,
          VoiceEndNotice.sessionLimit,
        ),
      ),
      (
        4001,
        const VoiceEnd(
          VoiceEndReason.closedByServer,
          VoiceEndNotice.superseded,
        ),
      ),
      (
        4002,
        const VoiceEnd(
          VoiceEndReason.closedByServer,
          VoiceEndNotice.limitReached,
        ),
      ),
      (1000, const VoiceEnd(VoiceEndReason.dropped)),
      (1001, const VoiceEnd(VoiceEndReason.dropped)),
      (1008, const VoiceEnd(VoiceEndReason.dropped)),
      (1011, const VoiceEnd(VoiceEndReason.dropped)),
      (null, const VoiceEnd(VoiceEndReason.dropped)),
    ]) {
      test('close ${code ?? '(none)'} -> $end', () {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          _ready(r);
          if (code == RelayCloseCode.limit) {
            r.server.channel.send(const RelayError(RelayErrorCode.limit));
          }
          r.server.channel.serverClose(code);
          async.flushMicrotasks();
          expect(r.ends, [end]);
          expect(r.connectedAtEnd, [false]);
          expect(r.mic.disposeCount, 1);
          // One end per session: nothing more arrives from it.
          r.server.channel.serverClose(1011);
          async.flushMicrotasks();
          expect(r.ends, hasLength(1));
        });
      });
    }

    // tapper's (plan 016 B-4): the `limit` event's scope reaches the end.
    test(
      'a limit event names the spent allowance; the 4002 end carries it',
      () {
        for (final scope in VoiceLimitScope.values) {
          fakeAsync((async) {
            final r = _Relay(async);
            _micOn(r);
            _ready(r);
            final limit = VoiceLimit(scope, DateTime.utc(2026, 11, 1));
            r.server.channel.send(
              RelayError(RelayErrorCode.limit, limit: limit),
            );
            r.server.channel.serverClose(RelayCloseCode.limit);
            async.flushMicrotasks();
            expect(r.ends, [
              VoiceEnd(
                VoiceEndReason.closedByServer,
                VoiceEndNotice.limitReached,
                limit,
              ),
            ]);
          });
        }
      },
    );

    test("an older server's bare limit, or a scope this app does not know, "
        'is the plain limit end', () {
      for (final frame in [
        '{"type":"error","code":"limit"}',
        '{"type":"error","code":"limit","scope":"team_week","resets_at":"2026-11-01T00:00:00Z"}',
        null, // no event at all before the 4002
      ]) {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          _ready(r);
          if (frame != null) r.server.channel.sendRaw(frame);
          r.server.channel.serverClose(RelayCloseCode.limit);
          async.flushMicrotasks();
          expect(r.ends, [
            const VoiceEnd(
              VoiceEndReason.closedByServer,
              VoiceEndNotice.limitReached,
            ),
          ], reason: '$frame');
        });
      }
    });

    test('a limit event is not carried past its session to another close', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel.send(
          RelayError(
            RelayErrorCode.limit,
            limit: VoiceLimit(
              VoiceLimitScope.userDay,
              DateTime.utc(2026, 10, 25),
            ),
          ),
        );
        // Not a 4002 after all: the scope is the limit's only.
        r.server.channel.serverClose(1011);
        async.flushMicrotasks();
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);

        // The next session's 4002 has no limit event: it is the plain
        // limit end, never the earlier session's allowance.
        expect(_micOn(r), MicEnableResult.success);
        _ready(r);
        r.server.channel.serverClose(RelayCloseCode.limit);
        async.flushMicrotasks();
        expect(r.ends, [
          const VoiceEnd(VoiceEndReason.dropped),
          const VoiceEnd(
            VoiceEndReason.closedByServer,
            VoiceEndNotice.limitReached,
          ),
        ]);
      });
    });

    test(
      'the words already transcribed are posted before the end is reported',
      () {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          _ready(r);
          r.server.channel
            ..send(const RelaySpeechStart())
            ..send(const RelayEndOfTurn('Remind me to')); // waits to merge
          async.flushMicrotasks();
          expect(r.utterances, isEmpty);

          r.server.channel.serverClose(1011);
          async.flushMicrotasks();
          expect(r.texts, ['Remind me to']);
          expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
        });
      },
    );

    test('a capture that dies while the mic is on is a drop', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.mic.end();
        async.flushMicrotasks();
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
        expect(r.server.channel.closedByClient, isTrue);
      });
    });
  });

  group('half-duplex', () {
    test(
      'while a reply plays (+500 ms) the frames are silence of the same size',
      () {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          _ready(r);
          void frame() {
            r.mic.feed(speech(3840, value: 7));
            async.flushMicrotasks();
          }

          frame();
          r.speakerPlaying = true;
          frame();
          r.speakerPlaying = false; // the tail runs from the stop itself
          frame();
          async.elapse(const Duration(milliseconds: 499));
          frame();
          async.elapse(const Duration(milliseconds: 1));
          frame();

          final frames = r.server.channel.sentAudio;
          expect(frames.map((f) => f.length), List.filled(5, 3840));
          expect(frames.map(isSilence), [false, true, true, true, false]);
        });
      },
    );

    test('a segment that starts during the reply is ignored whole', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.events.clear();
        r.speakerPlaying = true;
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayPartial('the reply itself'))
          ..send(const RelaySpeechEnd())
          ..send(const RelayEndOfTurn('The reply itself.'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        expect(r.utterances, isEmpty);
        expect(r.speechStartTicks, 0);
        expect(r.states, isEmpty);
        expect(r.partials.where((p) => p.isNotEmpty), isEmpty);
      });
    });

    test('a segment open when the reply starts is cut there: its partial is '
        'kept, nothing during the mute reaches the assembler', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayPartial('set a timer'));
        async.flushMicrotasks();

        r.speakerPlaying = true;
        expect(r.texts, ['set a timer']);
        r.server.channel
          ..send(const RelayPartial('set a timer for ten'))
          ..send(const RelaySpeechEnd())
          ..send(const RelayEndOfTurn('Set a timer for ten minutes.'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 12)); // past every flush timer
        expect(r.texts, ['set a timer']);
        expect(r.partials, isNot(contains('set a timer for ten')));
      });
    });

    test('an end_of_turn during the mute is never posted, even for a segment '
        'begun before it', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel.send(const RelaySpeechStart()); // no partial yet
        async.flushMicrotasks();
        r.speakerPlaying = true;
        r.server.channel
          ..send(const RelaySpeechEnd())
          ..send(const RelayEndOfTurn('What time is it?'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 12));
        expect(r.utterances, isEmpty);
      });
    });

    test('nothing reaches the assembler during the tail either', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.speakerPlaying = true;
        r.speakerPlaying = false;
        async.elapse(const Duration(milliseconds: 499));
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayPartial('echo'))
          ..send(const RelayEndOfTurn('Echo.'));
        async.flushMicrotasks();
        expect(r.speechStartTicks, 0);

        async.elapse(const Duration(milliseconds: 1));
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayEndOfTurn('Hello.'));
        async.flushMicrotasks();
        expect(r.texts, ['Hello.']);
        expect(r.speechStartTicks, 1);
      });
    });

    test('a capture stall spanning a short reply: frames that arrive within '
        'the tail are silenced, whenever they were captured', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.speakerPlaying = true;
        async.elapse(const Duration(milliseconds: 200));
        r.speakerPlaying = false; // a 200 ms reply, nothing delivered during it
        async.elapse(const Duration(milliseconds: 200));
        // The recorder hands over what it held: captured during the reply.
        r.mic.feed(speech(3840 * 5, value: 9));
        async.flushMicrotasks();
        expect(r.server.channel.sentAudio.map(isSilence), List.filled(5, true));

        async.elapse(const Duration(milliseconds: 300)); // the tail is over
        r.mic.feed(speech(3840, value: 9));
        async.flushMicrotasks();
        expect(r.server.channel.sentAudio.last, isNot(predicate(isSilence)));
      });
    });

    test(
      'the mute follows the player at once: no frame is needed to notice',
      () {
        fakeAsync((async) {
          final r = _Relay(async);
          _micOn(r);
          _ready(r);
          r.speakerPlaying = true;
          // An event right at the transition, before any audio arrives.
          r.server.channel.send(const RelaySpeechStart());
          async.flushMicrotasks();
          expect(r.speechStartTicks, 0);
          expect(r.states, isEmpty);
        });
      },
    );

    test(
      'interrupt by voice: mic audio and speech flow while a reply plays',
      () {
        fakeAsync((async) {
          final r = _Relay(async)
            ..interruptByVoice = true
            ..speakerPlaying = true;
          _micOn(r);
          _ready(r);
          r.mic.feed(speech(3840, value: 7));
          r.server.channel.send(const RelaySpeechStart());
          async.flushMicrotasks();
          expect(r.server.channel.sentAudio.map(isSilence), [false]);
          expect(r.speechStartTicks, 1);
          expect(r.states, [_listening]);
        });
      },
    );
  });

  group('events', () {
    test('speech_start shows listening, partials the trailing bubble, '
        'end_of_turn posts with stt_ms', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel.send(const RelaySpeechStart());
        async.flushMicrotasks();
        expect(r.states, [_listening]);
        expect(r.speechStartTicks, 1);

        async.elapse(const Duration(milliseconds: 300));
        r.server.channel.send(const RelayPartial('hello there'));
        async.elapse(const Duration(milliseconds: 200));
        r.server.channel.send(const RelayEndOfTurn('Hello there.'));
        async.flushMicrotasks();
        expect(r.utterances, [const VoiceUtterance('Hello there.', 500)]);
        expect(r.partials, ['hello there', '']);
        // The posted text never reaches the display as pending text (the
        // turn coordinator adds the user message).
        expect(r.partials, isNot(contains('Hello there.')));
      });
    });

    test('pending text is shown again after the display clears it', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayEndOfTurn('Book a table for')); // waits to merge
        async.flushMicrotasks();
        r.events.clear();

        // The app's `thinking`, then another turn's final reply: each
        // clears its trailing bubble.
        r.cleared.add(null);
        r.cleared.add(null);
        async.flushMicrotasks();
        expect(r.partials, ['Book a table for', 'Book a table for']);
      });
    });

    test('MVOICE lines carry times, never transcript text or tokens', () {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);
      final mvoice = <String>[];
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.script.add(401);
        _micOn(r);
        _ready(r);
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayPartial('secret plans'))
          ..send(const RelayEndOfTurn('Secret plans.'));
        async.flushMicrotasks();
        _micOff(r);
        mvoice.addAll(r.mvoice);
      });
      // The MVOICE lines go to the debug sink; the rest of the transport's
      // diagnostics to debugPrint.
      logs.addAll(mvoice);
      expect(mvoice, everyElement(startsWith('MVOICE ')));
      for (final event in [
        'mic_on',
        'upgrade_refused status=401',
        'ready',
        'speech_start',
        'end_of_turn',
        'utterance posted',
        'end_sent',
        // The relay's close after our `end`, with its code.
        'end_closed code=1000',
      ]) {
        expect(
          mvoice.any((l) => l.startsWith('MVOICE $event')),
          isTrue,
          reason: event,
        );
      }
      expect(mvoice, everyElement(contains(' t=')));
      for (final line in logs) {
        expect(line.toLowerCase(), isNot(contains('secret')));
        expect(line, isNot(contains('tok-')));
      }
    });
  });

  group('clocks', () {
    test('a wall-clock jump neither bursts nor stalls the audio', () {
      fakeAsync((async) {
        final r = _Relay(async); // the production stall fill and lead
        _micOn(r);
        _ready(r);
        void speak(Duration length) {
          for (
            var t = Duration.zero;
            t < length;
            t += const Duration(milliseconds: 80)
          ) {
            r.mic.feed(speech(3840));
            async.elapse(const Duration(milliseconds: 80));
          }
        }

        r.wallSkew = const Duration(hours: 1); // the clock jumps forward
        speak(const Duration(seconds: 1));
        expect(r.server.channel.audioBytes, 13 * 3840);
        r.wallSkew = const Duration(hours: -2); // and back, past the start
        speak(const Duration(seconds: 1));
        expect(r.server.channel.audioBytes, 26 * 3840);
        // Silence fills a stalled capture only up to (monotonic) real time.
        async.elapse(const Duration(seconds: 4));
        final realTime = 48 * async.elapsed.inMilliseconds;
        expect(r.server.channel.audioBytes, lessThanOrEqualTo(realTime));
        expect(r.server.channel.audioBytes, greaterThan(realTime - 48 * 2500));
      });
    });
  });

  group('rate fallback after the first socket is ready', () {
    test('the 16 kHz socket has its own ready deadline, and its frames are '
        'paced from zero', () {
      fakeAsync((async) {
        final r = _Relay(async, refusedRates: {24000});
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        _micOn(r);
        final first = r.server.channel;
        expect(r.server.attempts.single.uri.queryParameters['rate'], '24000');
        first.ready();
        // The 24 kHz socket idles: its keep-alive sends silence meanwhile.
        async.elapse(const Duration(seconds: 3));
        expect(first.audioBytes, greaterThan(0));

        // Only now does the recorder refuse 24 kHz.
        r.mic.startGate!.complete();
        async.flushMicrotasks();
        expect(r.enableResult, MicEnableResult.success);
        expect(first.closedByClient, isTrue);
        final second = r.server.channel;
        expect(r.server.attempts.last.uri.queryParameters['rate'], '16000');

        // Its own deadline: 12 s from the re-open, not from mic-on (an old
        // deadline was cancelled at the first ready).
        async.elapse(const Duration(seconds: 2));
        second.ready();
        // A burst from the recorder: paced from THIS socket's ready, so 4 s
        // of it goes out (none of the first socket's bytes counted).
        r.mic.feed(speech(32 * 5000));
        async.flushMicrotasks();
        expect(second.sentAudio.map((f) => f.length).toSet(), {2560});
        expect(second.audioBytes, 50 * 2560);
        expect(r.ends, isEmpty);
      });
    });

    test('no ready from the 16 kHz socket within its own 12 s is a drop', () {
      fakeAsync((async) {
        final r = _Relay(async, refusedRates: {24000});
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        _micOn(r);
        r.server.channel.ready();
        async.elapse(const Duration(seconds: 5));
        r.mic.startGate!.complete();
        async.flushMicrotasks(); // re-opened at t = 5 s

        async.elapse(const Duration(milliseconds: 11999));
        expect(r.ends, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
      });
    });
  });

  group('mic generations', () {
    test('mic-off while the permission is pending: no capture, no socket', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.permissionGate = Completer<void>();
        expect(_micOn(r), isNull);
        r.transport.disableMicrophone();
        async.flushMicrotasks();

        r.mic.permissionGate!.complete();
        async.flushMicrotasks();
        expect(r.enableResult, MicEnableResult.cancelled);
        expect(r.mic.startedRates, isEmpty);
        expect(r.server.attempts, isEmpty);
        expect(r.mic.disposeCount, 1);
      });
    });

    test('mic-off while capture is starting: it is stopped, never read', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        _micOn(r);
        var done = false;
        r.transport.disableMicrophone().then((_) => done = true);
        r.mic.startGate!.complete();
        async.flushMicrotasks();

        expect(r.enableResult, MicEnableResult.cancelled);
        expect(done, isTrue);
        expect(r.mic.stopCount, greaterThanOrEqualTo(1));
        expect(r.mic.disposeCount, 1);
        // Nothing was said: no end, the socket simply closed.
        expect(r.server.channel.sent, isEmpty);
        expect(r.server.channel.closedByClient, isTrue);
      });
    });

    test('a reconnect while an old capture start is pending gets an '
        'independent mic-on', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        expect(_micOn(r), isNull, reason: 'capture is still starting');
        final oldMic = r.mic;
        // The same mic generation: this joins the pending enable.
        final oldEnable = r.transport.enableMicrophone();
        r.transport.disconnect(VoiceDisconnectCause.leftConversation);
        r.transport.connect('conv-1');
        async.flushMicrotasks();

        r.onNewMic = null;
        final newEnable = r.transport.enableMicrophone();
        expect(identical(newEnable, oldEnable), isFalse);
        MicEnableResult? newResult;
        newEnable.then((v) => newResult = v);
        MicEnableResult? joined;
        oldEnable.then((v) => joined = v);

        oldMic.startGate!.complete(); // the old recorder finally starts
        async.flushMicrotasks();
        expect(joined, MicEnableResult.cancelled);
        expect(oldMic.disposeCount, 1);
        expect(newResult, MicEnableResult.success);
        expect(r.mics, hasLength(2));
        expect(r.mic.capturing, isTrue);

        _ready(r);
        r.mic.feed(speech(3840));
        async.flushMicrotasks();
        expect(r.server.channel.sentAudio, hasLength(1));
        expect(r.server.channels.first.closedByClient, isTrue);
      });
    });

    test('a hung old recorder delays the next mic-on by at most 3 s', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>(); // never
        _micOn(r);
        r.transport.disconnect(VoiceDisconnectCause.leftConversation);
        r.transport.connect('conv-1');
        async.flushMicrotasks();
        r.onNewMic = null;
        MicEnableResult? result;
        r.transport.enableMicrophone().then((v) => result = v);
        async.elapse(const Duration(milliseconds: 2999));
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(result, MicEnableResult.success);
      });
    });
  });

  group('disconnect and dispose', () {
    test('a disconnect during the upgrade closes the socket that lands', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.gate = Completer<void>();
        _micOn(r);
        r.transport.disconnect(VoiceDisconnectCause.paused);
        async.flushMicrotasks();
        expect(r.mic.disposeCount, 1);
        r.server.gate!.complete();
        async.flushMicrotasks();
        expect(r.server.channel.closedByClient, isTrue);
        // With the code of the close it landed after.
        expect(r.server.channel.clientCloseCode, RelayClientCloseCode.paused);
        expect(r.ends, isEmpty);
        expect(r.transport.isConnected, isFalse);
      });
    });

    test('a disconnect with the mic on drops what was pending, silently', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayEndOfTurn('Half a'));
        async.flushMicrotasks();
        r.transport.disconnect(VoiceDisconnectCause.leftConversation);
        async.elapse(const Duration(seconds: 5));
        expect(r.utterances, isEmpty);
        expect(r.server.channel.clientCloseCode, 4100);
        expect(r.ends, isEmpty);
        expect(_enable(r), MicEnableResult.notConnected);
      });
    });

    test('dispose closes both streams', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.transport.dispose();
        async.flushMicrotasks();
        expect(r.eventsDone, isTrue);
        expect(r.endsDone, isTrue);
        expect(r.server.channel.closedByClient, isTrue);
        Object? error;
        r.transport.connect('conv-1').catchError((Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isA<VoiceConnectCancelled>());
      });
    });
  });

  // Plan 002 W4d: the client's close code names why it left
  // (`lumen-rs/src/voice/relay.rs`, "The client's close codes"), one test
  // per close site.
  group('client close codes', () {
    test('the table: 1000 mic off, 4100-4104 by cause; the relay\'s own '
        'codes unchanged', () {
      expect(
        {
          for (final cause in VoiceDisconnectCause.values)
            cause: RelayClientCloseCode.forCause(cause),
        },
        {
          VoiceDisconnectCause.leftConversation: 4100,
          VoiceDisconnectCause.paused: 4101,
          VoiceDisconnectCause.idle: 4102,
          VoiceDisconnectCause.disposed: 4103,
          VoiceDisconnectCause.failed: 4104,
        },
      );
      expect(
        (
          RelayClientCloseCode.micOff,
          RelayClientCloseCode.leftConversation,
          RelayClientCloseCode.paused,
          RelayClientCloseCode.idle,
          RelayClientCloseCode.disposedOrReplaced,
          RelayClientCloseCode.clientFailure,
        ),
        (1000, 4100, 4101, 4102, 4103, 4104),
      );
      expect(
        (
          RelayCloseCode.done,
          RelayCloseCode.goingAway,
          RelayCloseCode.policy,
          RelayCloseCode.error,
          RelayCloseCode.sessionLimit,
          RelayCloseCode.superseded,
          RelayCloseCode.limit,
        ),
        (1000, 1001, 1008, 1011, 4000, 4001, 4002),
      );
    });

    test('mic off, the relay closing after end: 1000', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        _micOff(r);
        expect(r.server.channel.endReceived, isTrue);
        expect(r.server.channel.clientCloseCode, RelayClientCloseCode.micOff);
        expect(r.ends, isEmpty);
      });
    });

    test('mic off, the relay not closing within endWait: 1000', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.transport.disableMicrophone();
        async.flushMicrotasks();
        expect(r.server.channel.endReceived, isTrue);
        expect(r.server.channel.closedByClient, isFalse);
        async.elapse(const Duration(seconds: 3));
        expect(r.server.channel.clientCloseCode, RelayClientCloseCode.micOff);
      });
    });

    test('mic off before capture began is a mic-off too: 1000, no end', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        _micOn(r);
        r.transport.disableMicrophone();
        r.mic.startGate!.complete();
        async.flushMicrotasks();
        expect(r.server.channel.endReceived, isFalse);
        expect(r.server.channel.clientCloseCode, RelayClientCloseCode.micOff);
      });
    });

    for (final (cause, code) in [
      (VoiceDisconnectCause.leftConversation, 4100),
      (VoiceDisconnectCause.paused, 4101),
      (VoiceDisconnectCause.idle, 4102),
      (VoiceDisconnectCause.disposed, 4103),
      (VoiceDisconnectCause.failed, 4104),
    ]) {
      test(
        'disconnect(${cause.name}) with the mic on closes $code, no end',
        () {
          fakeAsync((async) {
            final r = _Relay(async);
            _micOn(r);
            _ready(r);
            r.transport.disconnect(cause);
            async.flushMicrotasks();
            expect(r.server.channel.clientCloseCode, code);
            expect(r.server.channel.endReceived, isFalse);
            expect(r.ends, isEmpty);
          });
        },
      );
    }

    test('a disconnect while a mic-off is still delivering its last events '
        'closes with its cause', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.transport.disableMicrophone();
        async.flushMicrotasks();
        expect(r.server.channel.endReceived, isTrue);
        r.transport.disconnect(VoiceDisconnectCause.leftConversation);
        async.flushMicrotasks();
        expect(r.server.channel.clientCloseCode, 4100);
        // The mic-off's own close, after its wait, does not replace it.
        async.elapse(const Duration(seconds: 3));
        expect(r.server.channel.clientCloseCode, 4100);
      });
    });

    test('a disconnect while capture is starting keeps its code: the start '
        'that resumes later closes nothing anew', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        _micOn(r);
        r.transport.disconnect(VoiceDisconnectCause.leftConversation);
        async.flushMicrotasks();
        r.mic.startGate!.complete();
        async.flushMicrotasks();
        expect(r.enableResult, MicEnableResult.cancelled);
        expect(r.server.channel.clientCloseCode, 4100);
      });
    });

    test('dispose closes 4103 (transport disposed)', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.transport.dispose();
        async.flushMicrotasks();
        expect(r.server.channel.clientCloseCode, 4103);
      });
    });

    // A failure is never a 1000 (which means mic off, after `end`): 4104.
    test('an upgraded socket that never says ready closes 4104, no end', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        async.elapse(const Duration(seconds: 12));
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
        expect(r.server.channel.endReceived, isFalse);
        expect(r.server.channel.clientCloseCode, 4104);
      });
    });

    test('no ready after mic-off either: 4104, no end', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        r.mic.feed(speech(3840));
        async.flushMicrotasks();
        r.transport.disableMicrophone();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 12));
        expect(r.ends, isEmpty);
        expect(r.server.channel.endReceived, isFalse);
        expect(r.server.channel.clientCloseCode, 4104);
      });
    });

    test('no ready while capture is still starting: 4104, kept when the '
        'start resumes', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        _micOn(r);
        async.elapse(const Duration(seconds: 12));
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
        expect(r.server.channel.clientCloseCode, 4104);
        r.mic.startGate!.complete();
        async.flushMicrotasks();
        expect(r.enableResult, MicEnableResult.notConnected);
        expect(r.server.channel.clientCloseCode, 4104);
      });
    });

    test('the recorder failing while the mic is on closes 4104, no end', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.mic.fail(StateError('recorder died'));
        async.flushMicrotasks();
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
        expect(r.server.channel.endReceived, isFalse);
        expect(r.server.channel.clientCloseCode, 4104);
      });
    });

    test('capture stopping on its own while the mic is on closes 4104', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.mic.end();
        async.flushMicrotasks();
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
        expect(r.server.channel.clientCloseCode, 4104);
      });
    });

    test("the relay's close while the mic is on: this side's close is 4104 "
        '(the socket is already over, so it sends nothing)', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel.serverClose(RelayCloseCode.superseded);
        async.flushMicrotasks();
        expect(r.ends, hasLength(1));
        expect(r.server.channel.clientCloseCode, 4104);
      });
    });

    test('a capture start that fails at every rate closes 4104', () {
      fakeAsync((async) {
        final r = _Relay(async, refusedRates: {24000, 16000});
        expect(_micOn(r), MicEnableResult.unavailable);
        expect(r.server.channels, hasLength(2));
        // The 24 kHz socket was replaced by the 16 kHz one, which the failed
        // start then closed.
        expect(r.server.channels.first.clientCloseCode, 4103);
        expect(r.server.channels.last.clientCloseCode, 4104);
        expect(r.server.channels.last.endReceived, isFalse);
      });
    });

    // tapper's (its wave-D reviews): a recorder that cannot be stopped at
    // mic-off is a failure on this side, never the normal ending.
    test('a recorder that cannot be stopped at mic-off closes 4104, no end; '
        'the mic-off fails with its error', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.mic.feed(speech(3840 + 100));
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelayPartial('turn on the'));
        async.flushMicrotasks();
        final stuck = StateError('recorder stuck');
        r.mic.stopError = stuck;

        Object? error;
        var done = false;
        r.transport.disableMicrophone().then<void>(
          (_) {
            done = true;
          },
          onError: (Object e) {
            error = e;
          },
        );
        async.flushMicrotasks();
        final channel = r.server.channel;
        final closedAtOnce = channel.clientCloseCode;
        // Past the 250 ms capture drain and the 2 s end wait of a mic-off.
        async.elapse(const Duration(seconds: 3));
        expect(channel.clientCloseCode, 4104);
        expect(channel.endReceived, isFalse);
        expect(closedAtOnce, 4104, reason: 'at once, with no end wait');
        expect(
          channel.sent.map(_describe),
          ['audio 3840'],
          reason: 'nothing more is taken from a recorder that would not stop',
        );
        // The caller (the app's mic-off) learns of it, and ends the voice
        // session as VoiceDisconnectCause.failed.
        expect(done, isFalse);
        expect(error, same(stuck));
        expect(r.ends, isEmpty);
        // What was transcribed stands.
        expect(r.texts, ['turn on the']);
        expect(r.states, [_listening, _idle]);
        expect(r.mic.disposeCount, 1);

        // The failure does not hold up the next mic-on.
        expect(_enable(r), MicEnableResult.success);
        expect(r.mics, hasLength(2));
        _ready(r);
        _micOff(r);
        expect(r.server.channel.clientCloseCode, 1000);
      });
    });

    // tapper's: mic-off while the recorder is still starting. The recorder
    // that starts after it is never read, but it is running: one that cannot
    // be stopped fails the mic-off as on the normal path, never a 1000 with
    // the error swallowed.
    test('mic off while the recorder is starting, then a recorder that cannot '
        'be stopped: 4104, no end; the mic-off fails with its error', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        expect(_micOn(r), isNull, reason: 'the recorder is still starting');
        _ready(r);
        final stuck = StateError('recorder stuck');
        r.mic.stopError = stuck;

        Object? error;
        var done = false;
        r.transport.disableMicrophone().then<void>(
          (_) {
            done = true;
          },
          onError: (Object e) {
            error = e;
          },
        );
        async.flushMicrotasks();
        final channel = r.server.channel;
        expect(
          channel.closedByClient,
          isFalse,
          reason: 'mic-off waits for the recorder start',
        );
        r.mic.startGate!.complete();
        async.flushMicrotasks();
        expect(r.enableResult, MicEnableResult.cancelled);
        final closedAtOnce = channel.clientCloseCode;
        async.elapse(const Duration(seconds: 3));
        expect(channel.clientCloseCode, 4104);
        expect(closedAtOnce, 4104, reason: 'at once, with no end wait');
        expect(channel.endReceived, isFalse);
        expect(channel.sent, isEmpty);
        expect(done, isFalse);
        expect(error, same(stuck));
        expect(r.ends, isEmpty);
        expect(r.mic.disposeCount, 1);

        // The failure does not hold up the next mic-on.
        r.onNewMic = null;
        expect(_enable(r), MicEnableResult.success);
        expect(r.mics, hasLength(2));
        _ready(r);
        _micOff(r);
        expect(r.server.channel.clientCloseCode, 1000);
      });
    });

    test('control: mic off while the recorder is starting, with a recorder '
        'that stops: 1000, and the mic-off succeeds', () {
      fakeAsync((async) {
        final r = _Relay(async);
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        expect(_micOn(r), isNull, reason: 'the recorder is still starting');
        _ready(r);

        Object? error;
        var done = false;
        r.transport.disableMicrophone().then<void>(
          (_) {
            done = true;
          },
          onError: (Object e) {
            error = e;
          },
        );
        async.flushMicrotasks();
        r.mic.startGate!.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        expect(r.enableResult, MicEnableResult.cancelled);
        final channel = r.server.channel;
        expect(channel.clientCloseCode, 1000);
        expect(
          channel.endReceived,
          isFalse,
          reason: 'nothing was captured, so nothing to end',
        );
        expect(done, isTrue);
        expect(error, isNull);
        expect(r.mic.stopCount, greaterThanOrEqualTo(1));
        expect(r.mic.capturing, isFalse, reason: 'the recorder was stopped');
        expect(r.mic.disposeCount, 1);
        expect(r.ends, isEmpty);
      });
    });

    test('a socket replaced at another capture rate closes 4103', () {
      fakeAsync((async) {
        final r = _Relay(async, refusedRates: {24000});
        r.onNewMic = (mic) => mic.startGate = Completer<void>();
        _micOn(r);
        // The 24 kHz socket is up, and ready, before capture refuses the rate.
        final first = r.server.channel;
        _ready(r);
        r.mic.startGate!.complete();
        async.flushMicrotasks();
        expect(r.enableResult, MicEnableResult.success);
        expect(r.server.channels, hasLength(2));
        expect(first.clientCloseCode, 4103);
        expect(first.endReceived, isFalse);
        expect(r.server.channel.closedByClient, isFalse);
      });
    });

    test('an upgrade that lands after a rate change replaced its attempt '
        'closes 4103', () {
      fakeAsync((async) {
        final r = _Relay(async, refusedRates: {24000});
        r.server.gate = Completer<void>();
        // Capture refuses 24 kHz while its upgrade is still held: the 16 kHz
        // attempt replaces it before either lands.
        expect(_micOn(r), MicEnableResult.success);
        expect(r.server.channels, isEmpty);
        r.server.gate!.complete();
        async.flushMicrotasks();
        expect(r.server.channels.map((c) => c.rate), [24000, 16000]);
        expect(r.server.channels.first.clientCloseCode, 4103);
        expect(r.server.channels.last.closedByClient, isFalse);
      });
    });

    test('an upgrade that lands after the session closed gets that '
        "close's code", () {
      for (final cause in VoiceDisconnectCause.values) {
        fakeAsync((async) {
          final r = _Relay(async);
          r.server.gate = Completer<void>();
          _micOn(r);
          r.transport.disconnect(cause);
          async.flushMicrotasks();
          r.server.gate!.complete();
          async.flushMicrotasks();
          expect(
            r.server.channel.clientCloseCode,
            RelayClientCloseCode.forCause(cause),
            reason: cause.name,
          );
        });
      }
    });
  });

  // The advertised facts (PROTOCOL.md §3; D1 §8.4's new relay tests).
  group('the advertised facts', () {
    test('the advertised rates and lead are used', () {
      fakeAsync((async) {
        final r = _Relay(async, serverLeadMs: 2000);
        expect(_micOn(r), MicEnableResult.success);
        r.server.channel.ready(
          rates: [16000, 24000],
          encoding: kPcmS16le,
          leadMs: 2000,
        );
        async.flushMicrotasks();
        expect(r.transport.sampleRates, [16000, 24000]);
        expect(r.transport.lead, const Duration(milliseconds: 1000));
        expect(
          r.mvoice.where((l) => l.startsWith('MVOICE ready ')).single,
          startsWith('MVOICE ready rate=24000 buffered_ms=0 lead_ms=2000 '),
        );
        // A burst: one second of it goes out (the server enforces two).
        r.mic.feed(speech(48 * 5000));
        async.flushMicrotasks();
        expect(r.server.channel.audioBytes, 12 * 3840);
        _micOff(r);

        // The next mic-on opens at the server's first rate.
        expect(_enable(r), MicEnableResult.success);
        expect(r.mic.startedRates, [16000]);
        expect(r.server.attempts.last.uri.queryParameters['rate'], '16000');
        _ready(r);
        _micOff(r);
      });
    });

    test("an older server's bare ready keeps the defaults", () {
      fakeAsync((async) {
        final r = _Relay(async);
        expect(_micOn(r), MicEnableResult.success);
        _ready(r); // {"type":"ready"}
        expect(r.transport.sampleRates, kDefaultRelaySampleRates);
        expect(r.transport.lead, const Duration(seconds: 4));
        r.mic.feed(speech(48 * 5000));
        async.flushMicrotasks();
        expect(r.server.channel.audioBytes, 50 * 3840); // 4.0 s
        _micOff(r);
        expect(_enable(r), MicEnableResult.success);
        expect(r.mic.startedRates, [24000]);

        // A newer server's facts, then a rollback to an older one: its bare
        // ready replaces them, every fact back to its default.
        r.server.channel.ready(rates: [16000, 24000], leadMs: 8000);
        async.flushMicrotasks();
        expect(r.transport.sampleRates, [16000, 24000]);
        expect(r.transport.lead, const Duration(seconds: 7));
        _micOff(r);
        expect(_enable(r), MicEnableResult.success);
        expect(r.mic.startedRates, [16000]);
        _ready(r);
        expect(r.transport.sampleRates, kDefaultRelaySampleRates);
        expect(r.transport.lead, const Duration(seconds: 4));
        _micOff(r);
      });
    });

    test('a cold start opens at 24000 and falls back to 16000 only on a '
        'microphone refusal', () {
      // The installed clients' rule, kept: a server failure is not a reason
      // to change rates.
      fakeAsync((async) {
        final r = _Relay(async);
        r.server.script.add(503);
        _micOn(r);
        expect(r.mic.startedRates, [24000]);
        expect(r.server.attempts.map((a) => a.uri.queryParameters['rate']), [
          '24000',
        ]);
        expect(r.ends, [
          const VoiceEnd(
            VoiceEndReason.closedByServer,
            VoiceEndNotice.unavailable,
          ),
        ]);
      });
      fakeAsync((async) {
        final r = _Relay(async, refusedRates: {24000});
        expect(_micOn(r), MicEnableResult.success);
        expect(r.mic.startedRates, [24000, 16000]);
        expect(r.server.attempts.map((a) => a.uri.queryParameters['rate']), [
          '24000',
          '16000',
        ]);
        expect(
          r.mvoice.where((l) => l.startsWith('MVOICE rate_retry')),
          isEmpty,
        );
        _ready(r);
        _micOff(r);
      });
    });

    test('an obsolete cached rate list falls back to the defaults after a '
        'rate 422', () {
      for (final recorderSlow in [false, true]) {
        fakeAsync((async) {
          final r = _Relay(async, acceptedRates: {24000, 16000});
          expect(_micOn(r), MicEnableResult.success);
          // An earlier deployment advertised a rate this one no longer takes.
          r.server.channel.ready(rates: [48000, 24000, 16000]);
          async.flushMicrotasks();
          _micOff(r);
          expect(r.transport.sampleRates, [48000, 24000, 16000]);

          if (recorderSlow) {
            r.onNewMic = (mic) => mic.startGate = Completer<void>();
          }
          final result = _enable(r);
          if (recorderSlow) {
            // The 422 lands while the recorder is still starting at 48 kHz.
            expect(result, isNull);
            r.mic.startGate!.complete();
            async.flushMicrotasks();
            expect(r.enableResult, MicEnableResult.success);
          } else {
            expect(result, MicEnableResult.success);
          }
          expect(
            r.server.attempts.skip(1).map((a) => a.uri.queryParameters['rate']),
            ['48000', '24000'],
            reason: 'recorderSlow=$recorderSlow',
          );
          // Capture moved with the socket, and the kept list is forgotten.
          expect(r.mic.startedRates, [48000, 24000]);
          expect(r.mic.stopCount, greaterThanOrEqualTo(1));
          expect(r.transport.sampleRates, kDefaultRelaySampleRates);
          expect(
            r.mvoice.where((l) => l.startsWith('MVOICE rate_retry ')).single,
            startsWith('MVOICE rate_retry rate=24000 '),
          );
          _ready(r);
          r.mic.feed(speech(3840 * 2));
          async.flushMicrotasks();
          expect(r.server.channel.sentAudio.map((f) => f.length), [3840, 3840]);
          expect(r.ends, isEmpty);
          _micOff(r);
          expect(r.server.channel.clientCloseCode, 1000);
        });
      }
    });

    test('a rate 422 moves on at most twice per mic-on, then ends the '
        'session', () {
      fakeAsync((async) {
        final r = _Relay(async, acceptedRates: {24000});
        expect(_micOn(r), MicEnableResult.success);
        r.server.channel.ready(rates: [48000, 32000, 16000]);
        async.flushMicrotasks();
        _micOff(r);
        expect(r.transport.sampleRates, [48000, 32000, 16000, 24000]);

        // 48000 refused: the kept list is forgotten, so 24000 (not 32000)
        // is next.
        expect(_enable(r), MicEnableResult.success);
        expect(
          r.server.attempts.skip(1).map((a) => a.uri.queryParameters['rate']),
          ['48000', '24000'],
        );
        _ready(r);
        _micOff(r);
      });
      fakeAsync((async) {
        final r = _Relay(async, acceptedRates: {8000});
        expect(_micOn(r), MicEnableResult.success);
        expect(r.server.attempts.map((a) => a.uri.queryParameters['rate']), [
          '24000',
          '16000',
        ]);
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
      });
      fakeAsync((async) {
        final r = _Relay(async);
        expect(_micOn(r), MicEnableResult.success);
        r.server.channel.ready(rates: [48000, 32000]);
        async.flushMicrotasks();
        _micOff(r);
        r.server.script.addAll([422, 422, 422]);
        expect(_enable(r), MicEnableResult.success);
        expect(
          r.server.attempts.skip(1).map((a) => a.uri.queryParameters['rate']),
          ['48000', '24000', '16000'],
        );
        expect(r.ends, [const VoiceEnd(VoiceEndReason.dropped)]);
        expect(r.server.attempts, hasLength(4), reason: 'no third retry');
        expect(r.mic.disposeCount, 1);
      });
    });

    // astra's F1 review: values no server sends must not reach the byte
    // arithmetic (an overflowing lead, a rate with no whole frame).
    test('an absurd advertised lead or rate is not used', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        for (var i = 0; i < 50; i++) {
          r.mic.feed(speech(3840, value: i + 1));
          async.elapse(const Duration(milliseconds: 80));
        }
        // 9223372036854775 ms, times 48 bytes, overflows a 64-bit int.
        r.server.channel.ready(rates: [1], leadMs: 9223372036854775);
        async.flushMicrotasks();
        expect(r.transport.lead, const Duration(seconds: 4));
        expect(r.transport.sampleRates, kDefaultRelaySampleRates);
        // The 3 s buffer goes out whole, as at an older server's ready.
        expect(r.server.channel.sentAudio.map((f) => f.first), [
          for (var i = 14; i <= 50; i++) i,
        ]);
        expect(r.ends, isEmpty);
        _micOff(r);
        expect(_enable(r), MicEnableResult.success);
        expect(r.mic.startedRates, [24000]);
        _ready(r);
        _micOff(r);
      });
    });

    test('mic off while capture moves to another rate learns that the old '
        'recorder would not stop: 4104, no end, the error rethrown', () {
      fakeAsync((async) {
        final r = _Relay(async, acceptedRates: {24000, 16000});
        expect(_micOn(r), MicEnableResult.success);
        r.server.channel.ready(rates: [48000, 24000, 16000]);
        async.flushMicrotasks();
        _micOff(r);

        // The cached 48 kHz is refused (422): capture moves to 24 kHz, and
        // the 48 kHz recorder's stop is slow, then fails.
        final stuck = StateError('recorder stuck');
        r.onNewMic = (mic) => mic
          ..stopGate = Completer<void>()
          ..stopError = stuck;
        expect(_enable(r), MicEnableResult.success);
        expect(r.server.attempts.last.uri.queryParameters['rate'], '24000');
        expect(r.mic.stopCount, 1, reason: 'the move is stopping 48 kHz');
        _ready(r); // the 24 kHz socket

        Object? error;
        var done = false;
        r.transport.disableMicrophone().then<void>(
          (_) {
            done = true;
          },
          onError: (Object e) {
            error = e;
          },
        );
        async.flushMicrotasks();
        r.mic.stopGate!.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        final channel = r.server.channel;
        expect(channel.endReceived, isFalse);
        expect(channel.clientCloseCode, 4104);
        expect(done, isFalse);
        expect(error, same(stuck));
        expect(r.ends, isEmpty);
        expect(r.mic.disposeCount, 1);
      });
    });

    test('an encoding this client cannot speak closes 4104', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        r.mic.feed(speech(3840));
        async.flushMicrotasks();
        r.server.channel.ready(rates: [16000, 24000], encoding: 'opus');
        async.flushMicrotasks();
        expect(r.server.channel.clientCloseCode, 4104);
        expect(r.server.channel.sent, isEmpty);
        expect(r.ends, [
          const VoiceEnd(
            VoiceEndReason.closedByServer,
            VoiceEndNotice.unavailable,
          ),
        ]);
        expect(r.transport.isConnected, isFalse);
        // Nothing that session advertised is kept.
        expect(r.transport.sampleRates, kDefaultRelaySampleRates);
        expect(
          r.mvoice.where((l) => l.startsWith('MVOICE ready_refused ')),
          hasLength(1),
        );
        expect(r.mvoice.where((l) => l.startsWith('MVOICE ready ')), isEmpty);
      });
      // The control: the one revision-1 encoding, named.
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        r.mic.feed(speech(3840));
        async.flushMicrotasks();
        r.server.channel.ready(encoding: kPcmS16le);
        async.flushMicrotasks();
        expect(r.server.channel.sentAudio, hasLength(1));
        expect(r.ends, isEmpty);
        _micOff(r);
      });
    });

    test('at lead_ms 5000 the pre-ready trim removes nothing', () {
      for (final (leadMs, first, count) in [(5000, 14, 37), (2000, 39, 12)]) {
        fakeAsync((async) {
          final r = _Relay(async, serverLeadMs: leadMs);
          _micOn(r);
          // Four seconds before ready, each frame marked with its index.
          for (var i = 0; i < 50; i++) {
            r.mic.feed(speech(3840, value: i + 1));
            async.elapse(const Duration(milliseconds: 80));
          }
          r.server.channel.ready(leadMs: leadMs);
          async.flushMicrotasks();
          // 5000: the 3 s buffer (37 frames) whole. 2000: the newest second
          // (12 frames), the oldest trimmed, nothing past the lead.
          expect(
            r.server.channel.sentAudio.map((f) => f.first),
            [for (var i = first; i < first + count; i++) i],
            reason: 'lead_ms=$leadMs',
          );
          _micOff(r);
        });
      }
    });
  });

  // A provider whose turns are not Muse's (D1 §8.4: CR L-16, Codex P1-7).
  group('turns', () {
    test('a turn with no partial posts its end_of_turn text', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelaySpeechEnd())
          ..send(const RelayEndOfTurn('Turn on the lights.'));
        async.flushMicrotasks();
        expect(r.texts, ['Turn on the lights.']);
        expect(r.states, [_listening, _idle]);
        _micOff(r);
      });
    });

    test("a final-only provider's late end_of_turn after the 1 s flush "
        'still posts once', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelaySpeechEnd());
        async.flushMicrotasks();
        // The assembler's fallback flush: nothing to post, the segment over.
        async.elapse(const Duration(milliseconds: 1500));
        expect(r.utterances, isEmpty);
        expect(r.states, [_listening, _idle]);

        r.server.channel.send(const RelayEndOfTurn('What time is it?'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 12)); // past every timer
        expect(r.texts, ['What time is it?']);
        _micOff(r);
        expect(r.texts, ['What time is it?']);
      });
    });

    test('overlapping turns keep their order', () {
      fakeAsync((async) {
        final r = _Relay(async);
        _micOn(r);
        _ready(r);
        // Turn one's final comes after its flush, and turn two's speech
        // right behind it.
        r.server.channel
          ..send(const RelaySpeechStart())
          ..send(const RelaySpeechEnd());
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1200));
        r.server.channel
          ..send(const RelayEndOfTurn('Set a timer.'))
          ..send(const RelaySpeechStart())
          ..send(const RelayPartial('and what'))
          ..send(const RelaySpeechEnd())
          ..send(const RelayEndOfTurn('And what time is it?'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 12));
        expect(r.texts, ['Set a timer.', 'And what time is it?']);
        _micOff(r);
      });
    });
  });
}

final _epoch = DateTime.utc(2026, 10, 18, 12);

/// What the app maps to its `listening` and `idle` states.
const _listening = VoiceListening(true);
const _idle = VoiceListening(false);

final _closedByClient = predicate<FakeRelayChannel>(
  (channel) => channel.closedByClient,
  'closed by the client',
);

String _describe(Object sent) =>
    sent is Uint8List ? 'audio ${sent.length}' : sent as String;

/// Connects and enables the mic; the result once settled (null if pending).
MicEnableResult? _micOn(_Relay r) {
  r.transport.connect('conv-1');
  r.async.flushMicrotasks();
  return _enable(r);
}

MicEnableResult? _enable(_Relay r) {
  r.enableResult = null;
  r.transport.enableMicrophone().then((result) => r.enableResult = result);
  r.async.flushMicrotasks();
  return r.enableResult;
}

void _ready(_Relay r) {
  r.server.channel.ready();
  r.async.flushMicrotasks();
}

/// Mic off, the relay closing normally after `end`.
void _micOff(_Relay r) {
  r.transport.disableMicrophone();
  r.async.flushMicrotasks();
  r.server.channel.serverClose(1000);
  r.async.flushMicrotasks();
}

/// One transport over fakes, with the PRODUCTION timings (stall fill, lead,
/// tail, deadlines) unless a test passes another; the fake relay enforces
/// its rules, and every test ends by requiring that none was broken.
class _Relay {
  _Relay(
    this.async, {
    bool permission = true,
    Set<int>? refusedRates,
    Duration? stallFill,
    Set<int>? acceptedRates,
    int serverLeadMs = kDefaultRelayLeadMs,
  }) : refusedRates = refusedRates ?? {},
       server = FakeRelayServer(
         clock: () => async.elapsed,
         acceptedRates: acceptedRates,
         leadMs: serverLeadMs,
       ) {
    transport = RelayVoiceTransport(
      accessToken: ({required forceRefresh}) async {
        tokenRequests.add(forceRefresh);
        if (forceRefresh) currentToken = 'tok-fresh';
        return currentToken;
      },
      streamUri: (rate) =>
          Uri.parse('wss://api.example/voice/stream?rate=$rate'),
      onUtterance: (utterance) {
        utterances.add(utterance);
        return 'posted';
      },
      speakerPlaying: speaker,
      interruptByVoice: () => interruptByVoice,
      onSpeechStart: () => speechStartTicks++,
      transcriptCleared: cleared.stream,
      micFactory: () {
        final mic = FakeMicCapture(
          permission: permission,
          refusedRates: this.refusedRates,
        );
        onNewMic?.call(mic);
        mics.add(mic);
        return mic;
      },
      connector: server.connect,
      debug: mvoice.add,
      monotonic: () => async.elapsed,
      now: () => _epoch.add(async.elapsed + wallSkew),
      stallFill: stallFill ?? const Duration(seconds: 2),
    );
    addTearDown(
      () => expect(
        server.verify(),
        isEmpty,
        reason: 'the relay would have closed the socket (1008)',
      ),
    );
    transport.events.listen(events.add, onDone: () => eventsDone = true);
    transport.remoteEnds.listen((end) {
      ends.add(end);
      connectedAtEnd.add(transport.isConnected);
    }, onDone: () => endsDone = true);
  }

  final FakeAsync async;
  final Set<int> refusedRates;
  late final RelayVoiceTransport transport;
  final FakeRelayServer server;
  String currentToken = 'tok-1';

  /// How far the WALL clock is off the monotonic one (a clock change).
  Duration wallSkew = Duration.zero;
  final speaker = ValueNotifier<bool>(false);
  final cleared = StreamController<void>.broadcast();

  final mics = <FakeMicCapture>[];
  void Function(FakeMicCapture mic)? onNewMic;
  FakeMicCapture get mic => mics.last;

  set speakerPlaying(bool playing) => speaker.value = playing;
  bool interruptByVoice = false;
  int speechStartTicks = 0;

  final tokenRequests = <bool>[];

  /// Every `MVOICE` line, in order.
  final mvoice = <String>[];
  final utterances = <VoiceUtterance>[];
  final events = <VoiceTransportEvent>[];
  final ends = <VoiceEnd>[];
  final connectedAtEnd = <bool>[];
  bool eventsDone = false;
  bool endsDone = false;
  MicEnableResult? enableResult;

  List<String> get texts => [for (final u in utterances) u.text];

  List<VoiceListening> get states =>
      events.whereType<VoiceListening>().toList();

  List<String> get partials => [
    for (final e in events.whereType<VoicePendingTranscript>()) e.text,
  ];
}
