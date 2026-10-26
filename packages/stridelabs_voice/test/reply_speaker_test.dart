import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/src/playback/reply_clip_files_io.dart'
    show IoReplyClipFiles;
import 'package:stridelabs_voice/stridelabs_voice.dart';
import 'package:stridelabs_voice/testing.dart';

import 'support/tts_server.dart';

/// The reply speaker over its ports — a fake TTS client (or the real
/// [RelayTtsClient] on a fake server), a fake player, in-memory clip files,
/// and the app's event streams and settings as the test drives them — the
/// union of lumen's and tapper's speaker tests, plus the token, typed-audio,
/// text-bound and disposal cases (D1 §8.3, §8.4).
void main() {
  // The speaker listens to the app lifecycle (pause stops it).
  TestWidgetsFlutterBinding.ensureInitialized();

  group('which replies are spoken', () {
    for (final mode in _Mode.values) {
      for (final origin in _Origin.values) {
        final speaks =
            mode == _Mode.always ||
            (mode == _Mode.auto && origin == _Origin.voice);
        test(
          '${mode.name} × ${origin.name}: ${speaks ? 'spoken' : 'silent'}',
          () {
            fakeAsync((async) {
              final s = _Speaker(async, mode: mode)..origins['t1'] = origin;
              s.feed(const SpeakerFinal('t1', 'Hello there. How are you?'));
              expect(s.tts.texts, speaks ? ['Hello there.'] : isEmpty);
              if (speaks) {
                s.tts.last.reply();
                s.flush();
                expect(s.tts.texts, ['Hello there.', 'How are you?']);
                expect(s.tts.calls.first.voice, 'Jason');
              }
            });
          },
        );
      }
    }

    for (final origin in _Origin.values) {
      test('where voice does not run (web): always × ${origin.name} asks for '
          'no speech', () {
        fakeAsync((async) {
          final s = _Speaker(async, mode: _Mode.always)
            ..supported = false
            ..origins['t1'] = origin;
          s.feed(const SpeakerPartial('t1', 'Hello there. How'));
          s.feed(const SpeakerFinal('t1', 'Hello there. How are you?'));
          s.feed(const SpeakerTurnCommitted('t1'));
          s.feed(const SpeakerTurnDone('t1'));
          expect(s.tts.calls, isEmpty, reason: 'no /voice/tts request');
          expect(s.players, isEmpty);
          expect(s.playing, isFalse);
        });
      });
    }

    test('a turn the coordinator did not start is never spoken', () {
      fakeAsync((async) {
        final s = _Speaker(async, mode: _Mode.always);
        s.feed(const SpeakerFinal('x', 'Hello there.'));
        expect(s.tts.calls, isEmpty);
      });
    });

    test('the voice setting is the voice asked for', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.voice = 'Hazel';
        s.feed(const SpeakerFinal('t1', 'Hi.'));
        expect(s.tts.last.voice, 'Hazel');
      });
    });

    test('a mode change mid-reply that no longer covers it stops it', () {
      fakeAsync((async) {
        final s = _Speaker(async, mode: _Mode.always)
          ..origins['t1'] = _Origin.typed;
        s.speakOne('t1', 'Typed reply. More.');
        expect(s.playing, isTrue);
        s.setMode(_Mode.auto);
        expect(s.playing, isFalse);
        expect(s.player.stopCount, 1);
      });
    });
  });

  group('the audio pipeline', () {
    test('prefetch one ahead: one request at a time, in order, one ahead', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two. Three.'));
        expect(s.tts.texts, ['One.']);
        expect(s.playing, isFalse, reason: 'nothing handed to the player yet');

        s.tts.calls[0].reply([1]);
        s.flush();
        // One plays; Two is fetched meanwhile.
        expect(s.player.enqueued, hasLength(1));
        expect(s.playing, isTrue);
        expect(s.tts.texts, ['One.', 'Two.']);

        s.tts.calls[1].reply([2]);
        s.flush();
        // Two is queued behind One: no third request yet.
        expect(s.player.enqueued, hasLength(2));
        expect(s.tts.texts, ['One.', 'Two.']);

        s.player.finishHead();
        s.flush();
        expect(s.tts.texts, ['One.', 'Two.', 'Three.']);
        s.tts.calls[2].reply([3]);
        s.flush();
        // Handed to the player in sentence order.
        expect(
          [for (final p in s.player.enqueued) s.files.written[p]],
          [
            [1],
            [2],
            [3],
          ],
        );

        s.player.finishHead();
        s.flush();
        expect(s.playing, isTrue);
        s.player.finishHead();
        s.flush();
        expect(s.playing, isFalse);
        expect(
          s.playingLog,
          [true, false],
          reason: 'one continuous playing span across the three clips',
        );
        expect(s.files.files, isEmpty, reason: 'each clip deleted after it');
        expect(s.files.deleted, s.player.enqueued);
      });
    });

    test(
      'streamed partials speak each sentence once, while still streaming',
      () {
        fakeAsync((async) {
          final s = _Speaker(async)..origins['t1'] = _Origin.voice;
          s.tts.autoReply = true;
          s.feed(const SpeakerTurnSeen('t1'));
          s.feed(const SpeakerPartial('t1', 'Surly is'));
          expect(s.tts.calls, isEmpty);
          s.feed(const SpeakerPartial('t1', 'Surly is open. Fair'));
          expect(s.tts.texts, ['Surly is open.']);
          expect(s.playing, isTrue, reason: 'first audio before the turn ends');
          s.feed(const SpeakerPartial('t1', 'Surly is open. Fair State too. '));
          s.feed(const SpeakerFinal('t1', 'Surly is open. Fair State too. '));
          s.feed(const SpeakerTurnCommitted('t1'));
          s.feed(const SpeakerTurnDone('t1'));
          expect(s.tts.texts, ['Surly is open.', 'Fair State too.']);
        });
      },
    );

    test(
      'a tool_card is a response boundary: the complete preamble is spoken',
      () {
        fakeAsync((async) {
          final s = _Speaker(async)..origins['t1'] = _Origin.voice;
          s.tts.autoReply = true;
          // Undecided on its own (nothing follows the period yet).
          s.feed(const SpeakerPartial('t1', 'Let me check the forecast.'));
          expect(s.tts.calls, isEmpty);
          s.feed(const SpeakerToolBoundary('t1'));
          expect(s.tts.texts, ['Let me check the forecast.']);
          // The next model response streams from scratch.
          s.feed(const SpeakerPartial('t1', 'It is sunny. Rain'));
          s.player.finishHead();
          s.flush();
          expect(s.tts.texts, ['Let me check the forecast.', 'It is sunny.']);
        });
      },
    );

    test('the latest turn wins at its first sentence', () {
      fakeAsync((async) {
        final s = _Speaker(async)
          ..origins['t1'] = _Origin.voice
          ..origins['t2'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'First reply. Still the first.'));
        s.tts.calls[0].reply();
        s.flush();
        expect(s.playing, isTrue);
        final pendingOld = s.tts.calls[1];
        expect(pendingOld.text, 'Still the first.');

        // The next turn starts: the old reply plays on until the new one
        // has a sentence to say.
        s.feed(const SpeakerTurnSeen('t2'));
        s.feed(const SpeakerPartial('t2', 'Second'));
        expect(s.player.stopCount, 0);
        expect(s.playing, isTrue);

        s.feed(const SpeakerFinal('t2', 'Second reply.'));
        expect(s.player.stopCount, 1);
        expect(s.tts.texts.last, 'Second reply.');
        // The old reply's response lands late: dropped, never played.
        pendingOld.reply();
        s.tts.last.reply();
        s.flush();
        expect(s.player.enqueued, hasLength(2));
        expect(s.files.files.keys, [s.player.enqueued.last]);
        expect(s.files.deleted, [s.player.enqueued.first]);
      });
    });

    test(
      'a newer turn that will not be spoken ends the older reply at once',
      () {
        fakeAsync((async) {
          final s = _Speaker(async)
            ..origins['t1'] = _Origin.voice
            ..origins['t2'] = _Origin.typed; // auto: not spoken
          s.speakOne('t1', 'Voice reply. More.');
          expect(s.playing, isTrue);
          s.feed(const SpeakerTurnSeen('t2'));
          expect(s.playing, isFalse);
          expect(s.player.stopCount, 1);
        });
      },
    );

    test('a speech response that lands after a stop is dropped', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'Hello. World.'));
        final pending = s.tts.last;
        s.speaker.stop(SpeakerStopReason.micTap);
        pending.reply();
        s.flush();
        expect(s.files.written, isEmpty, reason: 'nothing written');
        expect(s.players, isEmpty, reason: 'nothing handed to a player');
        expect(s.playing, isFalse);
        expect(s.tts.calls, hasLength(1));
        // The stopped turn stays silent for the rest of its stream.
        s.feed(const SpeakerFinal('t1', 'Hello. World. Again.'));
        expect(s.tts.calls, hasLength(1));
        // The next turn speaks.
        s.origins['t2'] = _Origin.voice;
        s.feed(const SpeakerFinal('t2', 'Next.'));
        expect(s.tts.texts.last, 'Next.');
      });
    });

    test('a turn_failed of the reply playing ends its audio', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'Partial reply. More.');
        s.feed(const SpeakerTurnFailed('t1'));
        expect(s.playing, isFalse);
        expect(s.player.stopCount, 1);
      });
    });

    test('a turn the app cancels stops its reply at once', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)
          ..origins['t1'] = _Origin.voice
          ..origins['t2'] = _Origin.voice;
        s.speakOne('t1', 'It is sunny. Rain comes later.');
        s.cancelled.add('t1');
        s.flush();
        expect(s.playing, isFalse);
        expect(s.player.stopCount, 1);
        // The rest of that turn stays silent; another turn speaks.
        s.feed(const SpeakerFinal('t1', 'It is sunny. Rain comes later. Yes.'));
        expect(s.tts.calls, hasLength(2));
        s.feed(const SpeakerFinal('t2', 'Next.'));
        expect(s.tts.texts.last, 'Next.');
      });
      expect(
        lines,
        contains(startsWith('MVOICE speak_stop reason=cancelled ')),
      );
    });
  });

  group('failures leave the reply text-only', () {
    // Without a Retry-After a failure is this turn's alone (a cooldown is
    // the group below).
    final cases = <String, void Function(FakeTtsCall call)>{
      '429 without Retry-After': (call) => call.failStatus(429),
      '503 without Retry-After': (call) => call.failStatus(503),
      '502': (call) => call.failStatus(502, retryAfter: '30'),
      // Slow, not lost: never retried (a lost connection is the retry
      // group below).
      'a receive timeout': (call) => call.failSlow(),
      'a connect timeout': (call) => call.failConnectTimeout(),
    };
    for (final MapEntry(key: name, value: fail) in cases.entries) {
      test('TTS $name: no more requests or audio for the turn, one line', () {
        final lines = _captureDebugPrint();
        fakeAsync((async) {
          final s = _Speaker(async)..origins['t1'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One. Two.'));
          fail(s.tts.last);
          s.flush();
          expect(s.tts.calls, hasLength(1));
          expect(s.players, isEmpty);
          expect(s.playingLog, isEmpty);
          s.feed(const SpeakerPartial('t1', 'One. Two. Three. Four'));
          expect(s.tts.calls, hasLength(1));
          // The next turn tries again.
          s.origins['t2'] = _Origin.voice;
          s.feed(const SpeakerFinal('t2', 'Next.'));
          expect(s.tts.calls, hasLength(2));
        });
        final failures = lines.where((l) => l.startsWith('[speaker]'));
        expect(failures, hasLength(1));
        expect(failures.single, contains('text-only'));
        expect(failures.single, isNot(contains('One')));
      });
    }

    test('a failure mid-reply stops what was queued', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.calls[0].reply();
        s.flush();
        expect(s.playing, isTrue);
        s.tts.calls[1].failStatus(502);
        s.flush();
        expect(s.playing, isFalse);
        expect(s.player.stopCount, 1);
        expect(s.files.files, isEmpty);
      });
    });

    test('a clip the player cannot load or play ends the reply', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'One. Two.');
        s.player.failHead();
        s.flush();
        expect(s.playing, isFalse);
        s.origins['t2'] = _Origin.voice;
        s.tts.autoReply = true;
        s.player.enqueueError = StateError('cannot load');
        s.feed(const SpeakerFinal('t2', 'Next.'));
        expect(s.playing, isFalse);
        expect(s.files.files, isEmpty);
      });
    });

    test('a clip that started and never ends gives up after the stall '
        'timeout (60 s; the start timeout is not involved)', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.feed(const SpeakerFinal('t1', 'Stuck.'));
        expect(s.playing, isTrue);
        async.elapse(const Duration(seconds: 59));
        expect(s.playing, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(s.playing, isFalse);
        expect(s.player.stopCount, 1);
      });
      expect(lines, contains(contains('reply speech failed (stalled)')));
      expect(lines.where((l) => l.contains('speak_playback_failed')), isEmpty);
    });
  });

  group('the playback-start timeout (T6 F2)', () {
    test('a clip that never starts fails after 5 s: the speaker is idle, '
        'the mic mute released, the text kept', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.prepareSilentPlayer = true; // libmpv never opening its output
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        expect(s.player.enqueued, hasLength(2));
        expect(s.playing, isTrue);
        async.elapse(const Duration(milliseconds: 4999));
        expect(s.playing, isTrue, reason: 'within the bound');
        async.elapse(const Duration(milliseconds: 1));
        expect(s.playing, isFalse, reason: 'released at the bound');
        // The app's mirror (its half-duplex mute and agent indicator) heard
        // exactly one span.
        expect(s.playingLog, [true, false]);
        expect(s.player.stopCount, 1);
        expect(s.files.files, isEmpty, reason: 'both clips deleted');
        // The next reply speaks.
        s.origins['t2'] = _Origin.voice;
        s.prepareSilentPlayer = false;
        s.feed(const SpeakerFinal('t2', 'Next.'));
        expect(s.tts.texts.last, 'Next.');
        expect(s.playing, isTrue);
      });
      final failed = lines.where((l) => l.contains('speak_playback_failed'));
      expect(failed, hasLength(1));
      expect(
        failed.single,
        startsWith('MVOICE speak_playback_failed reason=start_timeout i=0 '),
      );
      expect(
        lines,
        contains(startsWith('[speaker] reply speech failed (start_timeout)')),
      );
      expect(lines.where((l) => l.contains('(stalled)')), isEmpty);
    });

    test('a clip that starts late but within the bound plays', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.prepareSilentPlayer = true;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        async.elapse(const Duration(milliseconds: 4900));
        s.player.startHead();
        s.flush();
        async.elapse(const Duration(seconds: 20));
        expect(s.playing, isTrue, reason: 'started: only the stall applies');
        s.player.finishHead();
        s.flush();
        // Clip 1 is due now; it too starts late, within its own bound.
        async.elapse(const Duration(milliseconds: 4900));
        s.player.startHead();
        s.player.finishHead();
        s.flush();
        expect(s.playing, isFalse, reason: 'the reply played out');
        expect(s.player.stopCount, 0);
      });
      expect(lines.where((l) => l.contains('speak_playback_failed')), isEmpty);
      expect(lines.where((l) => l.contains('reply speech failed')), isEmpty);
      for (final what in [
        'speak_playback_start i=0',
        'speak_playback_end i=0',
        'speak_playback_start i=1',
        'speak_playback_end i=1',
      ]) {
        expect(lines, contains(startsWith('MVOICE $what ')), reason: what);
      }
    });

    test('a clip queued behind a playing one is timed from when that one '
        'ended, not from when it was handed over', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.prepareSilentPlayer = true;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.player.startHead(); // clip 0 plays; clip 1 waits behind it
        s.flush();
        async.elapse(const Duration(seconds: 30));
        expect(s.playing, isTrue);
        s.player.finishHead(); // clip 1 is due now, and never starts
        s.flush();
        async.elapse(const Duration(milliseconds: 4999));
        expect(s.playing, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        expect(s.playing, isFalse);
      });
      expect(
        lines,
        contains(
          startsWith('MVOICE speak_playback_failed reason=start_timeout i=1 '),
        ),
      );
    });

    test('injectable: the bound the speaker was built with', () {
      fakeAsync((async) {
        final s = _Speaker(
          async,
          playbackStartTimeout: const Duration(seconds: 2),
        )..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.prepareSilentPlayer = true;
        s.feed(const SpeakerFinal('t1', 'One.'));
        async.elapse(const Duration(milliseconds: 1999));
        expect(s.playing, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        expect(s.playing, isFalse);
      });
    });

    test('a start timeout longer than the stall timeout: a clip that never '
        'starts still fails as start_timeout, at the start bound (the stall '
        'clock waits for a start)', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(
          async,
          playbackStartTimeout: const Duration(seconds: 90),
        )..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.prepareSilentPlayer = true;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        async.elapse(const Duration(seconds: 89));
        expect(s.playing, isTrue, reason: 'past the 60 s stall timeout');
        async.elapse(const Duration(seconds: 1));
        expect(s.playing, isFalse);
      });
      expect(
        lines,
        contains(
          startsWith('MVOICE speak_playback_failed reason=start_timeout i=0 '),
        ),
      );
      expect(lines.where((l) => l.contains('(stalled)')), isEmpty);
    });

    test(
      "a player's own failure logs speak_playback_failed reason=playback",
      () {
        final lines = _captureDebugPrint();
        fakeAsync((async) {
          final s = _Speaker(async)..origins['t1'] = _Origin.voice;
          s.speakOne('t1', 'One. Two.');
          s.player.failHead();
          s.flush();
          expect(s.playing, isFalse);
        });
        expect(
          lines,
          contains(
            startsWith('MVOICE speak_playback_failed reason=playback i=0 '),
          ),
        );
      },
    );
  });

  group('one retry, after a transport failure only (plan 016 B-5)', () {
    for (final MapEntry(key: name, value: fail) in {
      'refused': (FakeTtsCall call) => call.failNetwork(),
      'reset before a response': (FakeTtsCall call) => call.failReset(),
    }.entries) {
      test('$name: sent once more under the same key; one clip', () {
        fakeAsync((async) {
          final s = _Speaker(async)..origins['t1'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One. Two.'));
          expect(s.tts.calls, hasLength(1));
          fail(s.tts.calls[0]);
          s.flush();
          expect(s.tts.texts, ['One.', 'One.'], reason: 'the retry');
          expect(s.tts.calls[1].idempotencyKey, s.tts.calls[0].idempotencyKey);
          expect(
            s.tts.calls[0].idempotencyKey,
            matches(RegExp(r'^[0-9a-f-]{36}$')),
            reason: 'a v4 uuid',
          );
          expect(
            s.tts.calls.where((c) => !c.answered),
            hasLength(1),
            reason: 'one attempt in flight',
          );
          s.tts.calls[1].reply();
          s.flush();
          expect(s.player.enqueued, hasLength(1), reason: 'one clip');
          expect(s.playing, isTrue);
          // The next sentence is a new charge: a new key.
          expect(s.tts.texts, ['One.', 'One.', 'Two.']);
          expect(
            s.tts.calls[2].idempotencyKey,
            isNot(s.tts.calls[0].idempotencyKey),
          );
        });
      });
    }

    test('a retry that fails too ends the reply text-only, one line', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.calls[0].failNetwork();
        s.flush();
        s.tts.calls[1].failNetwork();
        s.flush();
        expect(s.tts.calls, hasLength(2), reason: 'one retry, no more');
        expect(s.players, isEmpty);
      });
      final failures = lines.where((l) => l.startsWith('[speaker]'));
      expect(failures, hasLength(1));
      expect(failures.single, contains('text-only'));
    });

    final never = <String, void Function(FakeTtsCall call)>{
      'a receive timeout (slow)': (call) => call.failSlow(),
      'a connect timeout (slow)': (call) => call.failConnectTimeout(),
      'a body lost after its headers': (call) => call.failBodyLost(),
      '422': (call) => call.failStatus(422),
      '429': (call) => call.failStatus(429),
      '500': (call) => call.failStatus(500),
      '502': (call) => call.failStatus(502),
      '503': (call) => call.failStatus(503),
    };
    for (final MapEntry(key: name, value: fail) in never.entries) {
      test('never retried: $name', () {
        fakeAsync((async) {
          final s = _Speaker(async)..origins['t1'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One. Two.'));
          fail(s.tts.calls[0]);
          s.flush();
          expect(s.tts.calls, hasLength(1));
          expect(s.players, isEmpty);
        });
      });
    }

    test('no per-attempt timeout: a 15 s synthesis still plays', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'Slow one.'));
        async.elapse(const Duration(seconds: 15));
        expect(s.tts.calls, hasLength(1), reason: 'no retry while waiting');
        s.tts.last.reply();
        s.flush();
        expect(s.player.enqueued, hasLength(1));
        expect(s.playing, isTrue);
        expect(s.tts.calls, hasLength(1));
      });
    });

    test('the retry starts only with at least 5 s of the 20 s budget left', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'Late.'));
        async.elapse(const Duration(milliseconds: 15001));
        s.tts.last.failNetwork();
        s.flush();
        expect(s.tts.calls, hasLength(1), reason: '4.999 s left: none');
        expect(s.playing, isFalse);

        s.origins['t2'] = _Origin.voice;
        s.feed(const SpeakerFinal('t2', 'In time.'));
        async.elapse(const Duration(seconds: 15));
        s.tts.last.failNetwork();
        s.flush();
        expect(s.tts.texts, [
          'Late.',
          'In time.',
          'In time.',
        ], reason: '5 s left: retried');
        // The retry has what is left of the one budget, not 20 s more.
        async.elapse(const Duration(seconds: 5));
        s.tts.last.reply();
        s.flush();
        expect(s.players, isEmpty, reason: 'the budget ran out first');
      });
    });

    test('a stop between the attempts aborts the retry', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.speaker.stop(SpeakerStopReason.micTap);
        s.tts.calls[0].failNetwork();
        s.flush();
        expect(s.tts.calls, hasLength(1));
      });
    });
  });

  group('the token (TtsAuth, PROTOCOL.md §5.3)', () {
    test('an expired token is refreshed ahead: the sentence is spoken, one '
        'send', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final auth = FakeTtsAuth(expired: true);
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One.'));
        expect(auth.aheadCalls, 1);
        expect(auth.refreshes, 1);
        expect(s.tts.calls, hasLength(1), reason: 'sent after the refresh');
        s.tts.last.reply();
        s.flush();
        expect(s.player.enqueued, hasLength(1));
        expect(auth.afterUnauthorizedCalls, 0);
        // A token that is not about to expire is not refreshed again.
        s.player.finishHead();
        s.origins['t2'] = _Origin.voice;
        s.feed(const SpeakerFinal('t2', 'Two.'));
        expect(auth.aheadCalls, 2);
        expect(auth.refreshes, 1);
      });
      expect(lines.where((l) => l.contains('speak_tts_auth')), isEmpty);
    });

    test('an expired token still speaks the sentence, charged once: one '
        'key, two sends (a revision-1 server through RelayTtsClient)', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final server = _ChargingServer();
        final tokens = _Tokens('expired');
        final auth = _TokenAuth(tokens, server);
        final s = _Speaker(
          async,
          auth: auth,
          replyTts: RelayTtsClient(server.dio(tokens)),
        )..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One.'));
        s.settle();
        expect(server.sends, hasLength(2), reason: 'a 401, then the retry');
        expect(server.sends.map((r) => r.key).toSet(), hasLength(1));
        expect(server.sends.map((r) => r.token), ['expired', 'fresh']);
        expect(server.charged, hasLength(1), reason: 'charged once');
        expect(auth.afterUnauthorized, 1);
        expect(s.player.enqueued, hasLength(1), reason: 'spoken');
        expect(s.playing, isTrue);
      });
      expect(
        lines,
        contains(startsWith('MVOICE speak_tts_retry i=0 reason=auth ')),
      );
      expect(lines.where((l) => l.contains('speak_tts_auth')), isEmpty);
    });

    test('the same, refreshed ahead: one key, one send, charged once (a '
        'revision-1 server through RelayTtsClient)', () {
      fakeAsync((async) {
        final server = _ChargingServer();
        final tokens = _Tokens('expired');
        final auth = _TokenAuth(tokens, server, expiredLocally: true);
        final s = _Speaker(
          async,
          auth: auth,
          replyTts: RelayTtsClient(server.dio(tokens)),
        )..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One.'));
        s.settle();
        expect(server.sends.map((r) => r.token), ['fresh']);
        expect(server.charged, hasLength(1));
        expect(s.player.enqueued, hasLength(1));
      });
    });

    test('a 401 retries once under the same key and extras, after a '
        'refresh for that sentence', () {
      fakeAsync((async) {
        final auth = FakeTtsAuth();
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        var binding = 0;
        s.tts.extras = () => {'app.session': ++binding};
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.calls[0].failStatus(401);
        s.flush();
        expect(auth.afterUnauthorizedCalls, 1);
        expect(auth.extrasSeen, [
          {'app.session': 1},
        ], reason: "the sentence's own extras");
        expect(s.tts.calls, hasLength(2));
        expect(s.tts.calls[1].text, 'One.');
        expect(s.tts.calls[1].idempotencyKey, s.tts.calls[0].idempotencyKey);
        expect(s.tts.calls[1].extras, same(s.tts.calls[0].extras));
        s.tts.calls[1].reply();
        s.flush();
        expect(s.player.enqueued, hasLength(1));
        expect(s.tts.calls[2].extras, {'app.session': 2});
      });
    });

    test('a second 401 gives up with speak_tts_auth, still refreshing for '
        'the next sentence', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final auth = FakeTtsAuth();
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.calls[0].failStatus(401);
        s.flush();
        s.tts.calls[1].failStatus(401);
        s.flush();
        expect(s.tts.calls, hasLength(2), reason: 'no third send');
        expect(auth.afterUnauthorizedCalls, 2);
        expect(s.players, isEmpty);
        expect(s.playing, isFalse);
        // The reply is text-only; the next turn speaks.
        s.origins['t2'] = _Origin.voice;
        s.feed(const SpeakerFinal('t2', 'Next.'));
        expect(s.tts.texts.last, 'Next.');
      });
      expect(
        lines,
        contains(startsWith('MVOICE speak_tts_auth i=0 reason=unauthorized ')),
      );
      expect(
        lines.where((l) => l.startsWith('[speaker]')).single,
        contains('status 401'),
      );
    });

    test('a 401 on the last allowed send still refreshes, and does not '
        'resend', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final auth = FakeTtsAuth();
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.calls[0].failNetwork(); // the transport retry spends send 2
        s.flush();
        expect(s.tts.calls, hasLength(2));
        s.tts.calls[1].failStatus(401);
        s.flush();
        expect(
          auth.afterUnauthorizedCalls,
          1,
          reason: 'refreshed for the next sentence',
        );
        expect(s.tts.calls, hasLength(2), reason: 'not sent a third time');
        expect(s.players, isEmpty);
      });
      expect(
        lines,
        contains(startsWith('MVOICE speak_tts_auth i=0 reason=unauthorized ')),
      );
    });

    test('a refresh that fails gives up: no resend', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final auth = FakeTtsAuth(refreshSucceeds: false);
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.calls[0].failStatus(401);
        s.flush();
        expect(auth.afterUnauthorizedCalls, 1);
        expect(s.tts.calls, hasLength(1));
        expect(s.players, isEmpty);
      });
      expect(
        lines,
        contains(startsWith('MVOICE speak_tts_auth i=0 reason=refresh ')),
      );
    });

    test('a 503 never refreshes, whatever its body', () {
      for (final (retryAfter, body) in <(String?, Object?)>[
        (null, null),
        ('5', {'detail': 'voice beta unavailable'}),
        ('5', {'detail': 'authentication is unavailable'}),
      ]) {
        fakeAsync((async) {
          final auth = FakeTtsAuth();
          final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One. Two.'));
          s.tts.calls[0].failStatus(503, retryAfter: retryAfter, body: body);
          s.flush();
          expect(auth.afterUnauthorizedCalls, 0, reason: '$body');
          expect(auth.refreshes, 0, reason: '$body');
          expect(s.tts.calls, hasLength(1), reason: 'not resent: $body');
        });
      }
    });

    test('two sends at most per sentence, whatever the mix', () {
      for (final (name, first, second)
          in <(String, void Function(FakeTtsCall), void Function(FakeTtsCall))>[
            (
              'refused, refused',
              (c) => c.failNetwork(),
              (c) => c.failNetwork(),
            ),
            ('401, refused', (c) => c.failStatus(401), (c) => c.failNetwork()),
            ('refused, 401', (c) => c.failNetwork(), (c) => c.failStatus(401)),
            ('401, 401', (c) => c.failStatus(401), (c) => c.failStatus(401)),
          ]) {
        fakeAsync((async) {
          final auth = FakeTtsAuth();
          final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One. Two.'));
          first(s.tts.calls[0]);
          s.flush();
          expect(s.tts.calls, hasLength(2), reason: name);
          second(s.tts.calls[1]);
          s.flush();
          expect(s.tts.calls, hasLength(2), reason: name);
          expect(
            s.tts.calls.map((c) => c.idempotencyKey).toSet(),
            hasLength(1),
            reason: name,
          );
          expect(s.players, isEmpty, reason: name);
        });
      }
    });

    test('no TtsAuth is B-5\'s behaviour: no refresh ahead, a 401 gives the '
        'sentence up', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        expect(s.tts.calls, hasLength(1), reason: 'sent at once');
        s.tts.calls[0].failStatus(401);
        s.flush();
        expect(s.tts.calls, hasLength(1), reason: 'not resent');
        expect(s.players, isEmpty);
      });
      expect(lines.where((l) => l.contains('speak_tts_auth')), isEmpty);
      expect(lines.where((l) => l.contains('speak_tts_retry')), isEmpty);
      expect(
        lines.where((l) => l.startsWith('[speaker]')).single,
        contains('status 401'),
      );
    });

    test('a refresh ahead that leaves no usable token skips the sentence; '
        'the reply goes on', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final auth = FakeTtsAuth(expired: true, refreshSucceeds: false);
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        expect(auth.aheadCalls, 2, reason: 'each sentence asks again');
        expect(s.tts.calls, isEmpty, reason: 'nothing sent');
        expect(s.playing, isFalse);
        // The token comes back: the next sentence of the same reply speaks.
        auth.expired = false;
        s.feed(const SpeakerFinal('t1', 'One. Two. Three.'));
        expect(s.tts.texts, ['Three.']);
      });
      for (final i in [0, 1]) {
        expect(
          lines,
          contains(startsWith('MVOICE speak_tts_auth i=$i reason=ahead ')),
        );
      }
      expect(lines.where((l) => l.contains('text-only')), isEmpty);
    });

    test('a refresh ahead that leaves under 5 s sends nothing', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final auth = FakeTtsAuth(expired: true)..refreshGate = Completer();
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'Late.'));
        async.elapse(const Duration(milliseconds: 15001));
        auth.refreshGate!.complete();
        s.flush();
        expect(auth.refreshes, 1);
        expect(s.tts.calls, isEmpty, reason: '4.999 s left: not sent');

        // Its control: a refresh that leaves exactly 5 s sends.
        s.origins['t2'] = _Origin.voice;
        auth
          ..expired = true
          ..refreshGate = Completer();
        s.feed(const SpeakerFinal('t2', 'In time.'));
        async.elapse(const Duration(seconds: 15));
        auth.refreshGate!.complete();
        s.flush();
        expect(s.tts.texts, ['In time.'], reason: '5 s left: sent');
      });
      expect(
        lines,
        contains(startsWith('[speaker] reply speech failed (timeout)')),
      );
    });

    group('a refresh that outlasts', () {
      // Each case acts while the refresh is held, then lets it finish.
      final cases = <String, void Function(_Speaker s, FakeAsync async)>{
        "the sentence's budget": (s, async) =>
            async.elapse(const Duration(seconds: 20)),
        'a stop': (s, async) => s.speaker.stop(SpeakerStopReason.micTap),
        'a sign-out (a teardown)': (s, async) =>
            s.speaker.stop(SpeakerStopReason.teardown),
        'a replacement turn': (s, async) {
          s.tts.autoReply = true;
          s.feed(const SpeakerFinal('t2', 'Newer.'));
        },
      };
      for (final MapEntry(key: name, value: act) in cases.entries) {
        test('$name ahead sends nothing', () {
          fakeAsync((async) {
            final auth = FakeTtsAuth(expired: true)..refreshGate = Completer();
            final s = _Speaker(async, auth: auth)
              ..origins['t1'] = _Origin.voice
              ..origins['t2'] = _Origin.voice;
            s.feed(const SpeakerFinal('t1', 'Held.'));
            act(s, async);
            s.flush();
            auth.refreshGate!.complete();
            s.flush();
            expect(s.tts.texts, isNot(contains('Held.')));
          });
        });

        test('$name after a 401 sends nothing more', () {
          fakeAsync((async) {
            final auth = FakeTtsAuth();
            final s = _Speaker(async, auth: auth)
              ..origins['t1'] = _Origin.voice
              ..origins['t2'] = _Origin.voice;
            s.feed(const SpeakerFinal('t1', 'Held.'));
            auth.refreshGate = Completer();
            s.tts.calls[0].failStatus(401);
            s.flush();
            expect(auth.afterUnauthorizedCalls, 1);
            act(s, async);
            s.flush();
            auth.refreshGate!.complete();
            s.flush();
            expect(
              s.tts.texts.where((t) => t == 'Held.'),
              hasLength(1),
              reason: 'no retry',
            );
          });
        });
      }

      test('none of them: the retry goes out (the control)', () {
        fakeAsync((async) {
          final auth = FakeTtsAuth();
          final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'Held.'));
          auth.refreshGate = Completer();
          s.tts.calls[0].failStatus(401);
          s.flush();
          async.elapse(const Duration(seconds: 14));
          auth.refreshGate!.complete();
          s.flush();
          expect(s.tts.texts, ['Held.', 'Held.']);
        });
      });
    });

    test("while the app's refresh retry is pending: the held token goes out "
        'ahead, and a 401 is not resent', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final auth = FakeTtsAuth(expired: true)..pendingRetry = true;
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        expect(auth.aheadCalls, 1);
        expect(s.tts.calls, hasLength(1), reason: 'sent with the held token');
        s.tts.calls[0].failStatus(401);
        s.flush();
        expect(auth.afterUnauthorizedCalls, 1);
        expect(auth.refreshes, 0, reason: 'neither entry point refreshed');
        expect(s.tts.calls, hasLength(1), reason: 'not resent');
      });
      expect(
        lines,
        contains(startsWith('MVOICE speak_tts_auth i=0 reason=refresh ')),
      );
    });

    test('a TtsAuth that throws (against its contract) counts as no', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final auth = _ThrowingAuth();
        final s = _Speaker(async, auth: auth)..origins['t1'] = _Origin.voice;
        // Ahead: as a false, the sentence skipped and the reply going on.
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        expect(s.tts.calls, isEmpty);
        expect(auth.aheadCalls, 2, reason: 'the next sentence asked too');
        // After a 401: as a failed refresh, no resend.
        auth.throwAhead = false;
        s.origins['t2'] = _Origin.voice;
        s.feed(const SpeakerFinal('t2', 'Three.'));
        s.tts.last.failStatus(401);
        s.flush();
        expect(s.tts.calls, hasLength(1));
      });
      expect(
        lines,
        contains(startsWith('MVOICE speak_tts_auth i=1 reason=ahead ')),
      );
      expect(
        lines,
        contains(startsWith('MVOICE speak_tts_auth i=0 reason=refresh ')),
      );
    });
  });

  group('typed audio', () {
    test('a non-MP3 answer is skipped and the reply goes on', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.calls[0].reply(kFakeMp3, 'audio/wav');
        s.flush();
        expect(s.files.written, isEmpty, reason: 'nothing written');
        expect(s.players, isEmpty, reason: 'nothing played');
        expect(s.tts.texts, ['One.', 'Two.'], reason: 'the reply goes on');
        s.tts.calls[1].reply();
        s.flush();
        expect(s.player.enqueued, hasLength(1));
        expect(s.playing, isTrue);
      });
      expect(
        lines,
        contains(
          startsWith('MVOICE speak_tts_unsupported_type i=0 type=audio/wav '),
        ),
      );
      expect(lines.where((l) => l.contains('text-only')), isEmpty);
    });

    test('audio/mpeg plays: its clip file and the player get its type', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One.'));
        s.tts.calls[0].reply(kFakeMp3, 'audio/mpeg');
        s.flush();
        expect(s.players, hasLength(1), reason: 'handed to a player');
        expect(s.player.enqueued, hasLength(1));
        expect(s.player.enqueuedTypes, ['audio/mpeg']);
        expect(s.files.types.values, ['audio/mpeg']);
        expect(s.player.enqueued.single, endsWith('.mp3'));
      });
    });

    test('a fake server answering audio/wav through RelayTtsClient is '
        'refused gracefully; audio/mpeg plays', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final server = ScriptedTtsServer([
          TtsAnswer.audio(kFakeMp3, 'audio/wav'),
          TtsAnswer.audio(),
        ]);
        final s = _Speaker(async, replyTts: RelayTtsClient(dioOver(server)))
          ..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.settle();
        expect(server.requests, hasLength(2), reason: 'the reply went on');
        expect(s.player.enqueued, hasLength(1), reason: 'only Two plays');
        expect(s.player.enqueuedTypes, ['audio/mpeg']);
      });
      expect(
        lines,
        contains(
          startsWith('MVOICE speak_tts_unsupported_type i=0 type=audio/wav '),
        ),
      );
    });

    test('a type that could not be a token is logged as -', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One.'));
        s.tts.calls[0].reply(kFakeMp3, 'audio/x wav=1');
        s.flush();
      });
      expect(
        lines,
        contains(startsWith('MVOICE speak_tts_unsupported_type i=0 type=- ')),
      );
    });
  });

  group('the advertised text bound', () {
    // One 1000-character sentence of 200 five-letter words.
    final long = '${List.filled(200, 'word').join(' ')}.';

    test('the latest max-chars header wins, and none means 600', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        expect(s.speaker.maxSpokenChunk, kTtsMinTextChars, reason: 'a start');
        final steps = <(String, void Function(FakeTtsCall), int)>[
          (
            'a 200 with 1200',
            (c) => c.reply(kFakeMp3, 'audio/mpeg', 1200),
            1200,
          ),
          ('a 200 with none', (c) => c.reply(), 600),
          ('a 200 with 900', (c) => c.reply(kFakeMp3, 'audio/mpeg', 900), 900),
          ('a 200 with 599', (c) => c.reply(kFakeMp3, 'audio/mpeg', 599), 600),
          (
            'a 429 with 1000',
            (c) => c.failStatus(429, maxTextChars: 1000),
            1000,
          ),
          ('a transport failure', (c) => c.failSlow(), 1000),
          (
            'a 422 with 1200',
            (c) => c.failStatus(422, maxTextChars: 1200),
            600,
          ),
          ('a 401 with 800', (c) => c.failStatus(401, maxTextChars: 800), 800),
          (
            'a wav 200 with 700',
            (c) => c.reply(kFakeMp3, 'audio/wav', 700),
            700,
          ),
        ];
        var turn = 0;
        for (final (name, answer, bound) in steps) {
          final id = 't${++turn}';
          s.origins[id] = _Origin.voice;
          s.feed(SpeakerFinal(id, 'Hi.'));
          answer(s.tts.last);
          s.flush();
          expect(s.speaker.maxSpokenChunk, bound, reason: name);
        }
      });
    });

    test('new sentences are split to it', () {
      fakeAsync((async) {
        final s = _Speaker(async)
          ..origins['t1'] = _Origin.voice
          ..origins['t2'] = _Origin.voice;
        s.tts.autoReply = true;
        s.feed(SpeakerFinal('t1', long));
        expect(s.tts.calls.first.text.length, lessThanOrEqualTo(600));
        s.speaker.stop(SpeakerStopReason.micTap);
        // A response advertises 1200: the next long sentence goes whole.
        s.tts.autoReply = false;
        s.origins['t3'] = _Origin.voice;
        s.feed(const SpeakerFinal('t3', 'Hi.'));
        s.tts.last.reply(kFakeMp3, 'audio/mpeg', 1200);
        s.flush();
        s.speaker.stop(SpeakerStopReason.micTap);
        s.feed(SpeakerFinal('t2', long));
        expect(s.tts.last.text, long);
      });
    });

    test('a high-to-low bound re-splits the queued sentence', () {
      fakeAsync((async) {
        final s = _Speaker(async)
          ..origins['t1'] = _Origin.voice
          ..origins['t2'] = _Origin.voice;
        // A first response raises the bound to 1200.
        s.feed(const SpeakerFinal('t1', 'Warm up.'));
        s.tts.last.reply(kFakeMp3, 'audio/mpeg', 1200);
        s.flush();
        s.player.finishHead();
        s.flush();
        // Assembled under 1200: one sentence, queued behind 'Hi.'.
        s.feed(SpeakerFinal('t2', 'Hi. $long'));
        expect(s.tts.last.text, 'Hi.');
        // Its response advertises nothing: 600 from here.
        s.tts.last.reply();
        s.flush();
        expect(s.speaker.maxSpokenChunk, 600);
        final pieces = [s.tts.last.text];
        expect(pieces.single.length, lessThanOrEqualTo(600));
        s.tts.last.reply();
        s.flush();
        s.player.finishHead();
        s.flush();
        pieces.add(s.tts.last.text);
        expect(pieces.join(' '), long, reason: 'nothing lost, nothing added');
        for (final piece in pieces) {
          expect(piece.length, lessThanOrEqualTo(600));
        }
        // Each piece is its own sentence: its own key.
        final keys = s.tts.calls.skip(2).map((c) => c.idempotencyKey).toSet();
        expect(keys, hasLength(2));
      });
    });

    test('a new speaker starts at 600', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'Hi.'));
        s.tts.last.reply(kFakeMp3, 'audio/mpeg', 1200);
        s.flush();
        expect(s.speaker.maxSpokenChunk, 1200);
        s.speaker.dispose();
        expect(s.build().maxSpokenChunk, kTtsMinTextChars);
      });
    });
  });

  group('the extras', () {
    test('evaluated once per sentence: every send of it carries them', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        var reads = 0;
        s.tts.extras = () => {'app.session': ++reads};
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        expect(reads, 1);
        s.tts.calls[0].failNetwork();
        s.flush();
        expect(reads, 1, reason: 'the retry carries the same values');
        expect(s.tts.calls[1].extras, {'app.session': 1});
        s.tts.calls[1].reply();
        s.flush();
        expect(reads, 2, reason: 'the next sentence reads its own');
        expect(s.tts.calls[2].extras, {'app.session': 2});
      });
    });
  });

  group('an app Dio whose validateStatus accepts every status '
      '(RelayTtsClient)', () {
    /// The speaker on RelayTtsClient over [server], on a Dio whose own rule
    /// would take any status for a success.
    _Speaker over(FakeAsync async, ScriptedTtsServer server, {TtsAuth? auth}) {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'https://api.example',
          validateStatus: (_) => true,
        ),
      )..httpClientAdapter = server;
      return _Speaker(async, auth: auth, replyTts: RelayTtsClient(dio))
        ..origins['t1'] = _Origin.voice
        ..origins['t2'] = _Origin.voice;
    }

    test('a 503 still cools speech down', () {
      fakeAsync((async) {
        final server = ScriptedTtsServer([
          TtsAnswer.status(503, retryAfter: '5'),
          TtsAnswer.audio(),
          TtsAnswer.audio(),
        ]);
        final s = over(async, server);
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.settle();
        expect(server.requests, hasLength(1), reason: 'Two not asked for');
        s.feed(const SpeakerFinal('t2', 'Inside.'));
        s.settle();
        expect(server.requests, hasLength(1), reason: 'inside the cooldown');
        expect(s.players, isEmpty);
      });
    });

    test('a 401 still refreshes and sends again', () {
      fakeAsync((async) {
        final server = ScriptedTtsServer([
          TtsAnswer.status(401),
          TtsAnswer.audio(),
        ]);
        final auth = FakeTtsAuth();
        final s = over(async, server, auth: auth);
        s.feed(const SpeakerFinal('t1', 'One.'));
        s.settle();
        expect(auth.afterUnauthorizedCalls, 1);
        expect(server.requests, hasLength(2));
        expect(s.player.enqueued, hasLength(1));
      });
    });

    test('a 429 still gives the limit notice', () {
      fakeAsync((async) {
        final server = ScriptedTtsServer([
          TtsAnswer.status(
            429,
            retryAfter: '120',
            body:
                '{"detail":"voice beta limit reached","scope":"user_day",'
                '"resets_at":"2026-10-25T00:00:00Z"}',
          ),
        ]);
        final s = over(async, server);
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.settle();
        expect(s.notices, [
          VoiceLimit(VoiceLimitScope.userDay, DateTime.utc(2026, 10, 25)),
        ]);
        expect(server.requests, hasLength(1));
      });
    });
  });

  group('a Retry-After cools speech down for every turn', () {
    // The status line and `Retry-After` arrive, then the body breaks. Dio
    // keeps no response, but the client's transport watch kept the head: the
    // cooldown holds, through the real RelayTtsClient and Dio.
    for (final status in [503, 429]) {
      test('a $status whose body broke after its Retry-After: the next turn '
          'waits out the cooldown (RelayTtsClient on a real Dio)', () {
        fakeAsync((async) {
          final server = ScriptedTtsServer([
            TtsAnswer.status(status, retryAfter: '5', bodyLost: true),
            TtsAnswer.audio(),
          ]);
          final s = _Speaker(async, replyTts: RelayTtsClient(dioOver(server)))
            ..origins['t1'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One.'));
          s.settle();
          expect(server.requests, hasLength(1), reason: 'not retried');

          s.origins['t2'] = _Origin.voice;
          s.feed(const SpeakerFinal('t2', 'Two.'));
          s.settle();
          expect(
            server.requests,
            hasLength(1),
            reason: 'inside the cooldown: no speech asked for',
          );

          async.elapse(const Duration(seconds: 5));
          s.origins['t3'] = _Origin.voice;
          s.feed(const SpeakerFinal('t3', 'Three.'));
          s.settle();
          expect(server.requests, hasLength(2), reason: 'the cooldown ended');
        });
      });
    }

    test('429: text-only for every turn until it ends, one line', () {
      final lines = _captureDebugPrint();
      fakeAsync((async) {
        final s = _Speaker(async)
          ..origins['t1'] = _Origin.voice
          ..origins['t2'] = _Origin.voice
          ..origins['t3'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.last.failStatus(429, retryAfter: '120');
        s.flush();
        expect(s.playingLog, isEmpty);

        // A later turn within the window asks for nothing...
        async.elapse(const Duration(seconds: 60));
        s.feed(const SpeakerPartial('t2', 'Hi there. '));
        expect(s.tts.calls, hasLength(1));
        // ...nor once the window ends mid-turn: that reply stays text.
        async.elapse(const Duration(seconds: 61));
        s.feed(const SpeakerFinal('t2', 'Hi there. And more.'));
        expect(s.tts.calls, hasLength(1));

        // The next turn after it speaks.
        s.feed(const SpeakerFinal('t3', 'Back.'));
        expect(s.tts.texts, ['One.', 'Back.']);
      });
      final speaker = lines.where((l) => l.startsWith('[speaker]')).toList();
      expect(speaker, hasLength(1));
      expect(speaker.single, contains('status 429'));
      expect(speaker.single, contains('120s'));
    });

    test('429 naming its scope: one notice for the screen, the same cooldown '
        '(plan 016 B-4)', () {
      for (final (scope, resetsAt) in [
        ('user_day', DateTime.utc(2026, 10, 25)),
        ('user_month', DateTime.utc(2026, 11, 1)),
        ('global_month', DateTime.utc(2026, 11, 1)),
      ]) {
        fakeAsync((async) {
          final s = _Speaker(async)
            ..origins['t1'] = _Origin.voice
            ..origins['t2'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One. Two.'));
          // As the app's Dio hands the body over: bytes.
          s.tts.last.failStatus(
            429,
            retryAfter: '120',
            body: utf8.encode(
              jsonEncode({
                'detail': 'voice beta limit reached',
                'scope': scope,
                'resets_at': VoiceLimit.rfc3339(resetsAt),
              }),
            ),
          );
          s.flush();
          expect(s.notices, [
            VoiceLimit(VoiceLimitScope.fromWire(scope)!, resetsAt),
          ]);
          // The cooldown is today's: the next turn inside it asks nothing,
          // and publishes nothing more.
          async.elapse(const Duration(seconds: 60));
          s.feed(const SpeakerFinal('t2', 'Hi.'));
          expect(s.tts.calls, hasLength(1));
          expect(s.notices, hasLength(1));
        });
      }
    });

    test('429 with no scope (an older server) or one the app does not know: '
        'no notice, the cooldown as before', () {
      for (final body in <Object?>[
        null, // {"detail": "nope"}
        utf8.encode('{"detail":"voice beta limit reached"}'),
        utf8.encode(
          '{"detail":"voice beta limit reached","scope":"team_week",'
          '"resets_at":"2026-11-01T00:00:00Z"}',
        ),
        utf8.encode('not json'),
      ]) {
        fakeAsync((async) {
          final s = _Speaker(async)
            ..origins['t1'] = _Origin.voice
            ..origins['t2'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One.'));
          s.tts.last.failStatus(429, retryAfter: '120', body: body);
          s.flush();
          expect(s.notices, isEmpty, reason: '$body');
          s.feed(const SpeakerFinal('t2', 'Two.'));
          expect(s.tts.calls, hasLength(1), reason: 'still cooling down');
        });
      }
    });

    test('a scope on anything but a 429 is no notice', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One.'));
        s.tts.last.failStatus(
          503,
          retryAfter: '5',
          body: {
            'detail': 'x',
            'scope': 'user_day',
            'resets_at': '2026-10-25T00:00:00Z',
          },
        );
        s.flush();
        expect(s.notices, isEmpty);
      });
    });

    test('429: a Retry-After past 24 h is capped at 24 h', () {
      fakeAsync((async) {
        final s = _Speaker(async)
          ..origins['t1'] = _Origin.voice
          ..origins['t2'] = _Origin.voice
          ..origins['t3'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One.'));
        s.tts.last.failStatus(429, retryAfter: '9999999');
        s.flush();
        async.elapse(const Duration(hours: 23, minutes: 59));
        s.feed(const SpeakerFinal('t2', 'Two.'));
        expect(s.tts.calls, hasLength(1));
        async.elapse(const Duration(minutes: 1));
        s.feed(const SpeakerFinal('t3', 'Three.'));
        expect(s.tts.texts.last, 'Three.');
      });
    });

    test('503 with Retry-After: a short cooldown (capped at a minute)', () {
      for (final (retryAfter, wait) in [
        ('5', const Duration(seconds: 5)),
        ('3600', const Duration(minutes: 1)),
      ]) {
        fakeAsync((async) {
          final s = _Speaker(async)
            ..origins['t1'] = _Origin.voice
            ..origins['t2'] = _Origin.voice
            ..origins['t3'] = _Origin.voice;
          s.feed(const SpeakerFinal('t1', 'One.'));
          s.tts.last.failStatus(503, retryAfter: retryAfter);
          s.flush();
          async.elapse(wait - const Duration(milliseconds: 1));
          s.feed(const SpeakerFinal('t2', 'Two.'));
          expect(s.tts.calls, hasLength(1), reason: 'Retry-After $retryAfter');
          async.elapse(const Duration(milliseconds: 1));
          s.feed(const SpeakerFinal('t3', 'Three.'));
          expect(s.tts.texts.last, 'Three.', reason: 'Retry-After $retryAfter');
        });
      }
    });
  });

  group('nothing holds playing (and the mic mute) for good', () {
    test(
      'a prefetch whose file never lands ends the reply at the fetch bound',
      () {
        fakeAsync((async) {
          final s = _Speaker(async)..origins['t1'] = _Origin.voice;
          s.speakOne('t1', 'One. Two.');
          // The next sentence's speech lands, its file write hangs.
          s.files.writeGate = Completer<void>();
          s.tts.last.reply();
          s.flush();
          // The clip playing ends: playing is held by the fetch in flight.
          s.player.finishHead();
          s.flush();
          expect(s.playing, isTrue);
          async.elapse(const Duration(seconds: 19));
          expect(s.playing, isTrue);
          async.elapse(const Duration(seconds: 1));
          expect(s.playing, isFalse);
          // The late file is deleted, never played.
          s.files.writeGate!.complete();
          s.flush();
          expect(s.player.enqueued, hasLength(1));
          expect(s.files.files, isEmpty);
        });
      },
    );

    test('a speech request that never answers ends the reply at the bound', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'One. Two.');
        s.player.finishHead();
        s.flush();
        expect(s.playing, isTrue, reason: 'the prefetch holds it');
        async.elapse(const Duration(seconds: 20));
        expect(s.playing, isFalse);
        s.tts.last.reply();
        s.flush();
        expect(s.player.enqueued, hasLength(1));
      });
    });

    test('disposing the speaker alone clears the playing flag', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'One. Two.');

        // The app's provider is rebuilt: this speaker goes, a new one comes.
        s.speaker.dispose();
        final next = s.build();
        s.flush();
        expect(s.playing, isFalse);
        expect(s.playingLog, [true, false]);
        expect(s.player.disposed, isTrue);
        expect(s.player.stopCount, 1);
        expect(s.player.releases, [true], reason: 'stopped, then released');
        expect(s.files.files, isEmpty);
        // The replacement speaks.
        s.origins['t2'] = _Origin.voice;
        s.feed(const SpeakerFinal('t2', 'Fresh.'));
        expect(s.tts.texts.last, 'Fresh.');
        s.tts.last.reply();
        s.flush();
        expect(next.playing.value, isTrue);
      });
    });
  });

  group('disposal (safe in a Riverpod onDispose)', () {
    test('a playing listener that disposes the speaker as playback starts '
        'leaves no player, clip or timer behind', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speaker.playing.addListener(() {
          if (s.speaker.playing.value) s.speaker.dispose();
        });
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.last.reply();
        s.flush();
        expect(s.players, isEmpty, reason: 'no player made after disposal');
        expect(s.files.files, isEmpty, reason: 'the clip deleted');
        expect(async.pendingTimers, isEmpty, reason: 'nothing armed');
        expect(s.tts.calls, hasLength(1), reason: 'Two not asked for');
        expect(s.playingLog, [true, false]);
      });
    });

    test('a playing listener that stops the reply as playback starts: the '
        'clip is never handed to a player', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speaker.playing.addListener(() {
          if (s.speaker.playing.value) {
            s.speaker.stop(SpeakerStopReason.micTap);
          }
        });
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        s.tts.last.reply();
        s.flush();
        expect(s.players, isEmpty);
        expect(s.files.files, isEmpty, reason: 'the clip deleted');
        expect(s.tts.calls, hasLength(1), reason: 'Two not asked for');
        expect(s.playing, isFalse);
      });
    });

    test('a playing listener that disposes the speaker as playback ends: '
        'no error, and the player is let go', () {
      final errors = <FlutterErrorDetails>[];
      final original = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = original);
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.feed(const SpeakerFinal('t1', 'One.'));
        expect(s.playing, isTrue);
        s.speaker.playing.addListener(() {
          if (!s.speaker.playing.value) s.speaker.dispose();
        });
        s.player.finishHead();
        async.elapse(const Duration(seconds: 1));
        expect(s.playingLog, [true, false]);
        expect(s.player.disposed, isTrue);
        expect(
          () => s.speaker.playing.addListener(() {}),
          throwsFlutterError,
          reason: 'disposed, after its notification',
        );
      });
      expect(errors, isEmpty);
    });

    test('while playing: playing turns false one microtask later, never '
        'inside dispose', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'One. Two.');
        expect(s.playingLog, [true]);
        s.speaker.dispose();
        expect(s.playingLog, [true], reason: 'nothing notified synchronously');
        expect(s.speaker.playing.value, isTrue);
        async.flushMicrotasks();
        expect(s.playingLog, [true, false], reason: 'one microtask later');
        expect(s.speaker.playing.value, isFalse);
      });
    });

    test('the listener attached at disposal hears that false once; the '
        'notifier is then disposed', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'One. Two.');
        final heard = <bool>[];
        void mirror() => heard.add(s.speaker.playing.value);
        s.speaker.playing.addListener(mirror);
        s.speaker.dispose();
        // The app's own onDispose may detach its mirror after this; allowed.
        async.flushMicrotasks();
        expect(heard, [false]);
        expect(
          () => s.speaker.playing.addListener(() {}),
          throwsFlutterError,
          reason: 'disposed after notifying',
        );
        s.speaker.playing.removeListener(mirror); // allowed after dispose
        async.elapse(const Duration(minutes: 2));
        expect(heard, [false], reason: 'nothing more, ever');
      });
    });

    test('while silent: nothing is notified, now or later', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speaker.dispose();
        async.elapse(const Duration(minutes: 2));
        expect(s.playingLog, isEmpty);
        expect(
          () => s.speaker.playing.addListener(() {}),
          throwsFlutterError,
          reason: 'disposed',
        );
      });
    });

    test("a replacement speaker is never cleared by the old one's flag: the "
        'old false lands before the new one can play', () {
      fakeAsync((async) {
        final s = _Speaker(async)
          ..origins['t1'] = _Origin.voice
          ..origins['t2'] = _Origin.voice;
        s.speakOne('t1', 'One. Two.');
        // The app's mirror: ONE flag both speakers write (its provider).
        final mirror = <(String, bool)>[];
        s.speaker.playing.addListener(
          () => mirror.add(('old', s.speaker.playing.value)),
        );
        s.speaker.dispose();
        final next = s.build();
        next.playing.addListener(() => mirror.add(('new', next.playing.value)));
        // The replacement starts at once, its speech answered at once.
        s.tts.autoReply = true;
        s.events.add(const SpeakerFinal('t2', 'Fresh. More.'));
        async.elapse(const Duration(seconds: 1));
        expect(mirror, [('old', false), ('new', true)]);
        expect(next.playing.value, isTrue);
      });
    });

    test('after it, nothing the speaker hears changes anything', () {
      fakeAsync((async) {
        final s = _Speaker(async)
          ..origins['t1'] = _Origin.voice
          ..origins['t2'] = _Origin.voice;
        s.feed(const SpeakerFinal('t1', 'One. Two.'));
        final pending = s.tts.last;
        s.speaker.dispose();
        async.flushMicrotasks();
        pending.reply(); // a late response
        s.feed(const SpeakerFinal('t2', 'New.')); // a late event
        s.cancelled.add('t2');
        s.modes.add(SpeechModeChange.off);
        s.speechStarts.add(null);
        s.micOffs.add(null);
        s.speaker.stop(SpeakerStopReason.micTap);
        s.speaker.dispose(); // twice: a no-op
        async.elapse(const Duration(minutes: 2));
        expect(s.tts.calls, hasLength(1));
        expect(s.files.written, isEmpty);
        expect(s.players, isEmpty);
        expect(s.playingLog, isEmpty);
      });
    });

    test('the limit notices end with it', () {
      fakeAsync((async) {
        final s = _Speaker(async);
        var done = false;
        s.speaker.limitNotices.listen(null, onDone: () => done = true);
        s.speaker.dispose();
        async.flushMicrotasks();
        expect(done, isTrue);
      });
    });
  });

  group('stops before the speaker heard of the turn', () {
    for (final (name, act) in <(String, void Function(_Speaker s))>[
      (
        'the app pausing',
        (s) {
          _pauseApp();
          _resumeApp();
        },
      ),
      ('the screen leaving', (s) => s.speaker.stop(SpeakerStopReason.leave)),
      ('a teardown', (s) => s.speaker.stop(SpeakerStopReason.teardown)),
    ]) {
      test('$name silences the turn in flight', () {
        fakeAsync((async) {
          final s = _Speaker(async)
            ..origins['t1'] = _Origin.voice
            ..origins['t2'] = _Origin.voice;
          // t1 is streaming, nothing of it reached the speaker yet.
          s.active = 't1';
          act(s);
          s.flush();
          s.feed(const SpeakerFinal('t1', 'Late reply.'));
          expect(s.tts.calls, isEmpty);
          s.feed(const SpeakerFinal('t2', 'Next.'));
          expect(s.tts.texts, ['Next.']);
        });
        TestWidgetsFlutterBinding.instance.resetInternalState();
      });
    }

    test(
      'while paused nothing is fetched; a turn started then stays silent',
      () {
        fakeAsync((async) {
          final s = _Speaker(async)
            ..origins['t1'] = _Origin.voice
            ..origins['t2'] = _Origin.voice
            ..origins['t3'] = _Origin.voice;
          _pauseApp();
          s.feed(const SpeakerPartial('t1', 'In the back'));
          s.feed(const SpeakerFinal('t1', 'In the background. Yes.'));
          expect(s.tts.calls, isEmpty);
          // t2 starts while paused; its first event comes after the resume.
          s.active = 't2';
          _resumeApp();
          s.feed(const SpeakerFinal('t2', 'After.'));
          s.feed(const SpeakerFinal('t1', 'Still t1.'));
          expect(s.tts.calls, isEmpty);
          s.active = 't3';
          s.feed(const SpeakerFinal('t3', 'Fresh.'));
          expect(s.tts.texts, ['Fresh.']);
        });
        TestWidgetsFlutterBinding.instance.resetInternalState();
      },
    );

    test('without listenToLifecycle the app lifecycle is not heard', () {
      fakeAsync((async) {
        final s = _Speaker(async, listenToLifecycle: false)
          ..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'Reply. More.');
        _pauseApp();
        expect(s.playing, isTrue);
        expect(s.player.stopCount, 0);
      });
      TestWidgetsFlutterBinding.instance.resetInternalState();
    });
  });

  group('the audio focus', () {
    test('given back when a reply ends: all of it with the mic off', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.feed(const SpeakerFinal('t1', 'One.'));
        s.feed(const SpeakerTurnDone('t1'));
        expect(s.player.releases, isEmpty, reason: 'still playing');
        s.player.finishHead();
        s.flush();
        expect(s.player.releases, [false]);
      });
    });

    test('kept between two sentences while the turn still streams', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.tts.autoReply = true;
        s.feed(const SpeakerPartial('t1', 'First part. Still'));
        s.player.finishHead();
        s.flush();
        expect(s.playing, isFalse, reason: 'waiting for the next sentence');
        expect(s.player.releases, isEmpty, reason: 'no focus bounce mid-reply');
        s.feed(const SpeakerFinal('t1', 'First part. Still more.'));
        s.player.finishHead();
        s.flush();
        expect(s.player.releases, isEmpty);
        s.feed(const SpeakerTurnDone('t1'));
        expect(s.player.releases, [false], reason: 'the turn is over');
      });
    });

    test('with the mic on, the capture is kept; mic-off gives it all back', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.micOn = true;
        s.speakOne('t1', 'One. Two.');
        s.speaker.stop(SpeakerStopReason.micTap);
        s.flush();
        expect(s.player.releases, [true]);
        s.micOn = false;
        s.micOffs.add(null);
        s.flush();
        expect(s.player.releases, [true, false]);
      });
    });
  });

  group('what stops a reply (and clears playing)', () {
    test('barge-in: user speech with "Interrupt by voice" on', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'A long reply. With more.');
        s.userSpeaks();
        expect(s.playing, isTrue, reason: 'interrupt off: half-duplex');
        s.interrupt = true;
        s.userSpeaks();
        expect(s.playing, isFalse);
        expect(s.player.stopCount, 1);
        // The rest of the turn is not spoken.
        s.feed(const SpeakerFinal('t1', 'A long reply. With more. And more.'));
        expect(s.tts.calls, hasLength(2));
      });
    });

    test('a mic tap (the screen calls stop)', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'Reply. More.');
        s.speaker.stop(SpeakerStopReason.micTap);
        expect(s.playing, isFalse);
        expect(s.playingLog, [true, false]);
      });
    });

    test('the app pausing', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'Reply. More.');
        _driveLifecycle(const [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]);
        expect(s.playing, isFalse);
        expect(s.player.stopCount, 1);
      });
      // The binding's lifecycle state outlives the test.
      TestWidgetsFlutterBinding.instance.resetInternalState();
    });

    test('the audio mode going to never', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'Reply. More.');
        s.setMode(_Mode.never);
        expect(s.playing, isFalse);
        expect(s.player.stopCount, 1);
      });
    });
  });

  group('clip files', () {
    test('swept at start, kept while queued, deleted after playing', () async {
      final dir = await Directory.systemTemp.createTemp('stridelabs-voice-');
      addTearDown(() => dir.delete(recursive: true));
      final stale = File('${dir.path}/lumen-tts-stale.mp3')
        ..writeAsBytesSync([1]);
      final other = File('${dir.path}/other.mp3')..writeAsBytesSync([1]);

      final tts = FakeReplyTts()..autoReply = true;
      final players = <FakeReplyPlayer>[];
      final events = StreamController<SpeakerTurnEvent>.broadcast();
      addTearDown(events.close);
      final speaker = ReplySpeaker(
        _ports(
          turnEvents: events.stream,
          files: IoReplyClipFiles(dir, prefix: 'lumen-tts-'),
          tts: tts,
          playerFactory: () {
            final player = FakeReplyPlayer();
            players.add(player);
            return player;
          },
        ),
      );
      addTearDown(speaker.dispose);
      await _settle();
      expect(stale.existsSync(), isFalse, reason: 'swept at start');
      expect(other.existsSync(), isTrue, reason: 'not ours');

      events.add(const SpeakerFinal('t1', 'One. Two.'));
      await _settle();
      final player = players.single;
      expect(player.enqueued, hasLength(2));
      final first = File(player.enqueued[0]);
      final second = File(player.enqueued[1]);
      expect(first.uri.pathSegments.last, startsWith('lumen-tts-'));
      expect(first.uri.pathSegments.last, endsWith('.mp3'));
      expect(first.readAsBytesSync(), isNotEmpty);
      expect(second.existsSync(), isTrue);

      player.finishHead();
      await _settle();
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isTrue);

      // A stop deletes what was still queued.
      speaker.stop(SpeakerStopReason.leave);
      await _settle();
      expect(second.existsSync(), isFalse);
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), ['other.mp3']);
    });

    test('dispose deletes what is left', () {
      fakeAsync((async) {
        final s = _Speaker(async)..origins['t1'] = _Origin.voice;
        s.speakOne('t1', 'One. Two.');
        expect(s.files.files, isNotEmpty);
        s.speaker.dispose();
        s.flush();
        expect(s.files.files, isEmpty);
        expect(s.player.disposed, isTrue);
      });
    });
  });

  test('MVOICE lines carry times and indexes, never reply text', () {
    final lines = _captureDebugPrint();
    fakeAsync((async) {
      final s = _Speaker(async)..origins['t1'] = _Origin.voice;
      s.tts.autoReply = true;
      s.feed(const SpeakerPartial('t1', 'Secret plans here. More'));
      s.feed(const SpeakerFinal('t1', 'Secret plans here. More secrets.'));
      s.feed(const SpeakerTurnDone('t1'));
      s.player.finishHead();
      s.player.finishHead();
      s.flush();
    });
    final mvoice = lines.where((l) => l.startsWith('MVOICE ')).toList();
    for (final what in [
      'speak_first_sentence',
      'speak_tts_request i=0',
      'speak_tts_bytes i=0',
      'speak_playback_start i=0',
      'speak_turn_done',
      'speak_playback_end i=1',
    ]) {
      expect(
        mvoice.any((l) => l.startsWith('MVOICE $what')),
        isTrue,
        reason: what,
      );
    }
    for (final line in mvoice) {
      expect(line, matches(RegExp(r' t=\d+ turn\+\d+ms$')));
      expect(line.toLowerCase(), isNot(contains('secret')));
      expect(line, isNot(contains('plans')));
    }
  });

  test('MVOICE lines go to the debug sink it was given', () {
    final printed = _captureDebugPrint();
    final sink = <String>[];
    fakeAsync((async) {
      final s = _Speaker(async, debug: sink.add)..origins['t1'] = _Origin.voice;
      s.tts.autoReply = true;
      s.feed(const SpeakerFinal('t1', 'One.'));
    });
    expect(sink, contains(startsWith('MVOICE speak_tts_request i=0 ')));
    expect(printed.where((l) => l.startsWith('MVOICE ')), isEmpty);
  });

  test('a clip that was not heard (silent) ends like a played one: logged '
      'apart, never as a failure', () {
    final lines = _captureDebugPrint();
    fakeAsync((async) {
      final s = _Speaker(async)..origins['t1'] = _Origin.voice;
      s.tts.autoReply = true;
      s.feed(const SpeakerFinal('t1', 'One. Two.'));
      s.feed(const SpeakerTurnDone('t1'));
      expect(s.player.enqueued, hasLength(2));
      s.player.finishHead(heard: false);
      s.flush();
      expect(s.playing, isTrue, reason: 'Two plays on');
      s.player.finishHead(heard: false);
      s.flush();
      expect(s.playing, isFalse);
      expect(s.files.files, isEmpty, reason: 'each clip deleted after it');
      expect(s.files.deleted, s.player.enqueued);
    });
    final mvoice = lines.where((l) => l.startsWith('MVOICE ')).toList();
    for (final i in [0, 1]) {
      expect(
        mvoice.where((l) => l.startsWith('MVOICE speak_playback_silent i=$i')),
        hasLength(1),
        reason: 'clip $i',
      );
    }
    expect(mvoice.where((l) => l.contains('speak_playback_end')), isEmpty);
    expect(lines.where((l) => l.contains('text-only')), isEmpty);
  });
}

/// The app's audio-response setting, as the test's eligibility reads it.
enum _Mode { auto, always, never }

/// Who started a turn, as the test's coordinator says.
enum _Origin { typed, action, voice }

/// One speaker over fakes, under fakeAsync: the app's streams are
/// controllers the test adds to, its settings fields the test sets.
class _Speaker {
  _Speaker(
    this.async, {
    this.mode = _Mode.auto,
    TtsAuth? auth,
    ReplyTts? replyTts,
    this._playbackStartTimeout,
    this._debug,
    this._listenToLifecycle = true,
  }) {
    ports = SpeakerPorts(
      turnEvents: events.stream,
      cancelledTurns: cancelled.stream,
      speechModeChanges: modes.stream,
      userSpeechStarts: speechStarts.stream,
      micOff: micOffs.stream,
      clipFiles: files,
      activeTurnId: () => active,
      isEligible: _eligible,
      interruptByVoice: () => interrupt,
      tts: replyTts ?? tts,
      voice: () => voice,
      playerFactory: () {
        final player = FakeReplyPlayer();
        if (prepareSilentPlayer) player.silent = true;
        players.add(player);
        return player;
      },
      captureLive: () => micOn,
      ttsAuth: auth,
    );
    speaker = build();
    speaker.playing.addListener(() => playingLog.add(speaker.playing.value));
    speaker.limitNotices.listen(notices.add);
    flush();
  }

  final FakeAsync async;
  final Duration? _playbackStartTimeout;
  final VoiceDebugSink? _debug;
  final bool _listenToLifecycle;

  final events = StreamController<SpeakerTurnEvent>.broadcast();
  final cancelled = StreamController<String>.broadcast();
  final modes = StreamController<SpeechModeChange>.broadcast();
  final speechStarts = StreamController<void>.broadcast();
  final micOffs = StreamController<void>.broadcast();

  final tts = FakeReplyTts();
  final players = <FakeReplyPlayer>[];
  final files = FakeClipFiles();
  final origins = <String, _Origin>{};
  final playingLog = <bool>[];
  final notices = <VoiceLimit>[];
  _Mode mode;
  bool supported = true;
  String? active;
  bool interrupt = false;
  bool micOn = false;
  String voice = 'Jason';
  bool prepareSilentPlayer = false;
  late final SpeakerPorts ports;
  late final ReplySpeaker speaker;

  /// A speaker over these ports (the app's provider building one), on the
  /// fake clock; disposed when the test ends.
  ReplySpeaker build() {
    final speaker = ReplySpeaker(
      ports,
      debug: _debug,
      listenToLifecycle: _listenToLifecycle,
      playbackStartTimeout: _playbackStartTimeout ?? const Duration(seconds: 5),
      monotonic: () => async.elapsed,
    );
    addTearDown(speaker.dispose);
    return speaker;
  }

  bool _eligible(String turnId) {
    if (!supported) return false;
    final origin = origins[turnId];
    if (origin == null) return false;
    return switch (mode) {
      _Mode.never => false,
      _Mode.always => true,
      _Mode.auto => origin == _Origin.voice,
    };
  }

  FakeReplyPlayer get player => players.single;

  bool get playing => speaker.playing.value;

  void flush() => async.flushMicrotasks();

  /// Time for a real Dio to answer on a fake transport.
  void settle() => async.elapse(const Duration(milliseconds: 100));

  void feed(SpeakerTurnEvent event) {
    events.add(event);
    flush();
  }

  void setMode(_Mode next) {
    mode = next;
    modes.add(
      next == _Mode.never ? SpeechModeChange.off : SpeechModeChange.changed,
    );
    flush();
  }

  void userSpeaks() {
    speechStarts.add(null);
    flush();
  }

  /// [turnId]'s reply [text] arrives; its first sentence plays and the next
  /// is being fetched.
  void speakOne(String turnId, String text) {
    feed(SpeakerFinal(turnId, text));
    tts.last.reply();
    flush();
    expect(playing, isTrue);
  }
}

/// Ports for a speaker outside fakeAsync: every turn eligible, the rest
/// idle.
SpeakerPorts _ports({
  required Stream<SpeakerTurnEvent> turnEvents,
  required ReplyClipFiles files,
  required ReplyTts tts,
  required ReplyAudioPlayer Function() playerFactory,
}) => SpeakerPorts(
  turnEvents: turnEvents,
  cancelledTurns: const Stream.empty(),
  speechModeChanges: const Stream.empty(),
  userSpeechStarts: const Stream.empty(),
  micOff: const Stream.empty(),
  clipFiles: files,
  activeTurnId: () => null,
  isEligible: (_) => true,
  interruptByVoice: () => false,
  tts: tts,
  voice: () => 'Jason',
  playerFactory: playerFactory,
  captureLive: () => false,
);

/// A [TtsAuth] that breaks its contract: its calls throw ([refreshAhead]
/// only while [throwAhead]; otherwise it answers true).
class _ThrowingAuth implements TtsAuth {
  bool throwAhead = true;
  int aheadCalls = 0;

  @override
  Future<bool> refreshAhead() {
    aheadCalls++;
    return throwAhead ? Future.error(StateError('broken')) : Future.value(true);
  }

  @override
  Future<bool> refreshAfterUnauthorized(Map<String, Object?> extras) =>
      Future.error(StateError('broken'));
}

/// The app's token, as its interceptor attaches it.
class _Tokens {
  _Tokens(this.current);

  String current;
}

/// The app's [TtsAuth] over [_Tokens]: a refresh takes the server's valid
/// token. [expiredLocally]: the app knows its token expired (refresh ahead);
/// otherwise it learns only from the server's `401`.
class _TokenAuth implements TtsAuth {
  _TokenAuth(this._tokens, this._server, {this.expiredLocally = false});

  final _Tokens _tokens;
  final _ChargingServer _server;
  bool expiredLocally;
  int afterUnauthorized = 0;

  @override
  Future<bool> refreshAhead() async {
    if (expiredLocally) {
      _tokens.current = _server.validToken;
      expiredLocally = false;
    }
    return true;
  }

  @override
  Future<bool> refreshAfterUnauthorized(Map<String, Object?> extras) async {
    afterUnauthorized++;
    _tokens.current = _server.validToken;
    return true;
  }
}

/// A revision-1 TTS server: a `401` (charging nothing) for any token but
/// [validToken]; otherwise the sentence is charged once per
/// `Idempotency-Key` (a repeat answers the first verdict) and spoken.
class _ChargingServer implements HttpClientAdapter {
  final validToken = 'fresh';
  final List<({String? key, String? token})> sends = [];
  final Set<String> charged = {};

  /// The app's Dio: its interceptor attaches the bearer token.
  Dio dio(_Tokens tokens) => dioOver(this)
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Authorization'] = 'Bearer ${tokens.current}';
          handler.next(options);
        },
      ),
    );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final token = (options.headers['Authorization'] as String?)?.substring(7);
    final key = options.headers[kIdempotencyKeyHeader] as String?;
    sends.add((key: key, token: token));
    if (token != validToken) {
      return ResponseBody.fromString(
        '{"detail":"invalid token"}',
        401,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          kTtsMaxCharsHeader: ['600'],
        },
      );
    }
    charged.add(key!);
    return ResponseBody.fromBytes(
      kFakeMp3,
      200,
      headers: {
        Headers.contentTypeHeader: ['audio/mpeg'],
        kTtsMaxCharsHeader: ['600'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Real file IO and fake playback: a few event-loop turns.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

List<String> _captureDebugPrint() {
  final lines = <String>[];
  final original = debugPrint;
  debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
  addTearDown(() => debugPrint = original);
  return lines;
}

void _pauseApp() => _driveLifecycle(const [
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
]);

void _resumeApp() => _driveLifecycle(const [
  AppLifecycleState.hidden,
  AppLifecycleState.inactive,
  AppLifecycleState.resumed,
]);

void _driveLifecycle(List<AppLifecycleState> states) {
  for (final state in states) {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  }
}
