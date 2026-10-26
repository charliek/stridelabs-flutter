import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';
import 'package:stridelabs_voice/testing.dart';

const _mp3 = 'audio/mpeg';

/// [JustAudioReplyPlayer]'s playlist handling over a fake just_audio player
/// whose state reaches listeners asynchronously, as the real one's does.
void main() {
  test('clips play back to back: appended while playing, then a fresh run', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.player.enqueue('a', mediaType: _mp3);
      h.flush();
      expect(h.fake.loads, [
        ['a'],
      ]);
      expect(h.fake.playCalls, 1);
      expect(h.events, [
        _started('a'),
      ], reason: 'stale not-playing states before play() are no failure');

      h.player.enqueue('b', mediaType: _mp3);
      h.flush();
      expect(h.fake.appended, ['b'], reason: 'appended, not reloaded');
      h.fake.advance(); // a -> b
      h.flush();
      expect(h.events, [_started('a'), _finished('a'), _started('b')]);

      h.fake.advance(); // b -> the end
      h.flush();
      expect(h.events.last, _finished('b'));
      expect(h.fake.pauseCalls, 1, reason: 'the next run takes focus again');

      h.player.enqueue('c', mediaType: _mp3);
      h.flush();
      expect(h.fake.loads.last, ['c']);
      expect(h.events.last, _started('c'));
      expect(h.fake.playCalls, 2);
      expect(h.activations, 2);
      expect(h.configurations, 1);
    });
  });

  test('a clip appended just as the playlist ended is played on', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.player.enqueue('a', mediaType: _mp3);
      h.flush();
      // The end is reached and a clip appended before either is handled.
      h.fake.advance();
      h.player.enqueue('b', mediaType: _mp3);
      h.flush();
      expect(h.events, [_started('a'), _finished('a'), _started('b')]);
      expect(h.fake.currentIndex, 1);
      expect(h.fake.processingState, ProcessingState.ready);
    });
  });

  test('audio focus refused: the clip fails, nothing plays', () {
    fakeAsync((async) {
      final h = _Harness(async)..focusGranted = false;
      h.player.enqueue('a', mediaType: _mp3);
      h.flush();
      expect(h.fake.playCalls, 0);
      expect(h.events, [_failed('a')]);
      expect(h.fake.stopCalls, 1);
    });
  });

  test('a system pause fails the run unless it resumes within the grace', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.player
        ..enqueue('a', mediaType: _mp3)
        ..enqueue('b', mediaType: _mp3);
      h.flush();
      h.fake.systemPause();
      h.flush();
      async.elapse(const Duration(seconds: 4));
      h.fake.systemResume();
      h.flush();
      async.elapse(const Duration(seconds: 10));
      expect(h.events.where((e) => e.phase == ReplyClipPhase.failed), isEmpty);

      h.fake.systemPause();
      h.flush();
      async.elapse(const Duration(seconds: 5));
      expect(h.events.skip(1), [_failed('a'), _failed('b')]);
    });
  });

  test('a run that never gets to play gives up after the grace', () {
    fakeAsync((async) {
      final h = _Harness(async)..fake.playDoesNothing = true;
      h.player.enqueue('a', mediaType: _mp3);
      h.flush();
      async.elapse(const Duration(milliseconds: 4999));
      expect(h.events, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(h.events, [_failed('a')]);
    });
  });

  group('the audio focus (the session seam)', () {
    test('taken per run, given back once the run is over', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        expect(h.activations, 1);
        h.player.release(captureLive: false);
        h.flush();
        expect(h.deactivations, 0, reason: 'a reply is still playing');
        h.fake.advance(); // a ends
        h.flush();
        h.player.release(captureLive: false);
        h.player.release(captureLive: false);
        h.flush();
        expect(h.deactivations, 1, reason: 'given back once');
        h.player.enqueue('b', mediaType: _mp3);
        h.flush();
        expect(h.activations, 2, reason: 'the next reply takes it again');
      });
    });

    test('a live capture keeps the session where giving it back would stop '
        'the recorder', () {
      for (final keepsCapture in [true, false]) {
        fakeAsync((async) {
          final h = _Harness(async, releaseKeepsCapture: keepsCapture);
          h.player.enqueue('a', mediaType: _mp3);
          h.flush();
          h.player.stop();
          h.player.release(captureLive: true);
          h.flush();
          // Android (the recorder holds no focus): given back anyway.
          expect(
            h.deactivations,
            keepsCapture ? 1 : 0,
            reason: 'releaseKeepsCapture=$keepsCapture',
          );
          // The mic going off gives it back everywhere.
          h.player.release(captureLive: false);
          h.flush();
          expect(h.deactivations, 1);
        });
      }
    });

    test('nothing is given back that was never taken', () {
      fakeAsync((async) {
        final h = _Harness(async)..focusGranted = false;
        h.player.release(captureLive: false);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        h.player.release(captureLive: false);
        h.flush();
        expect(h.deactivations, 0);
      });
    });

    test('replies take transient focus', () {
      expect(
        replyAudioSessionConfiguration.androidAudioFocusGainType,
        AndroidAudioFocusGainType.gainTransient,
      );
      expect(
        replyAudioSessionConfiguration.androidAudioAttributes?.contentType,
        AndroidAudioContentType.speech,
      );
    });
  });

  group('the default session steps, by platform', () {
    // audio_session's channel, answered as on a platform without its plugin
    // (Linux): every call is recorded and refused.
    const sessionChannel = MethodChannel('com.ryanheise.audio_session');
    final sessionCalls = <String>[];

    setUp(() {
      sessionCalls.clear();
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sessionChannel, (call) async {
            sessionCalls.add(call.method);
            throw MissingPluginException();
          });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sessionChannel, null);
    });

    /// One reply played to its end and given back, with only the player
    /// injected (the session steps, and when a clip counts as started, are
    /// the platform's defaults).
    List<ReplyClipEvent> playOneReply() {
      final events = <ReplyClipEvent>[];
      fakeAsync((async) {
        final fake = _FakeAudioPlayer();
        final player = JustAudioReplyPlayer(createPlayer: () => fake);
        player.clipEvents.listen(events.add);
        player.enqueue('a', mediaType: _mp3);
        async.flushMicrotasks();
        fake.progress(); // Linux waits for it; elsewhere it changes nothing
        async.flushMicrotasks();
        fake.advance();
        async.flushMicrotasks();
        player.release(captureLive: false);
        async.flushMicrotasks();
      });
      return events;
    }

    test('Linux: the reply plays and audio_session is never called', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(playOneReply(), [_started('a'), _finished('a')]);
      expect(sessionCalls, isEmpty);
      expect(JustAudioReplyPlayer().startNeedsProgress, isTrue);
    });

    test('only Linux waits for the position to move before a start', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          JustAudioReplyPlayer().startNeedsProgress,
          isFalse,
          reason: '$platform',
        );
      }
    });

    test('Android and macOS still configure the speech session', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
        debugDefaultTargetPlatformOverride = platform;
        sessionCalls.clear();
        expect(playOneReply(), [_started('a'), _finished('a')]);
        expect(sessionCalls, contains('setConfiguration'), reason: '$platform');
      }
    });
  });

  group('a clip that ends far too soon was not heard', () {
    // As in the Linux spike: libmpv with no audio device "completed" a
    // 1.56 s clip 11 ms after play(), without an error.
    const length = Duration(milliseconds: 1560);
    const instant = Duration(milliseconds: 11);

    test('under half its length played: silent, and the run moves on '
        'as after an end', () {
      fakeAsync((async) {
        final h = _Harness(async)..fake.clipLength = length;
        h.player
          ..enqueue('a', mediaType: _mp3)
          ..enqueue('b', mediaType: _mp3);
        h.flush();
        async.elapse(instant);
        h.fake.advance(); // a -> b
        h.flush();
        async.elapse(length ~/ 2 - const Duration(milliseconds: 1));
        h.fake.advance(); // b -> the end
        h.flush();
        expect(h.events, [
          _started('a'),
          _silent('a'),
          _started('b'),
          _silent('b'),
        ]);
        expect(h.fake.pauseCalls, 1, reason: 'the run ended as usual');
        h.player.enqueue('c', mediaType: _mp3);
        h.flush();
        expect(h.events.last, _started('c'), reason: 'the next run plays');
      });
    });

    test('half its length or more played: finished', () {
      fakeAsync((async) {
        final h = _Harness(async)..fake.clipLength = length;
        h.player
          ..enqueue('a', mediaType: _mp3)
          ..enqueue('b', mediaType: _mp3);
        h.flush();
        async.elapse(length);
        h.fake.advance(); // a -> b
        h.flush();
        async.elapse(length ~/ 2);
        h.fake.advance(); // b -> the end
        h.flush();
        expect(h.events, [
          _started('a'),
          _finished('a'),
          _started('b'),
          _finished('b'),
        ]);
      });
    });

    test('too short to judge, or of unknown length: finished', () {
      for (final clipLength in [
        JustAudioReplyPlayer.silentCheckMinLength -
            const Duration(milliseconds: 1),
        null,
      ]) {
        fakeAsync((async) {
          final h = _Harness(async)..fake.clipLength = clipLength;
          h.player.enqueue('a', mediaType: _mp3);
          h.flush();
          h.fake.advance();
          h.flush();
          expect(h.events, [
            _started('a'),
            _finished('a'),
          ], reason: '$clipLength');
        });
      }
    });
  });

  group('a start needs a position that moves (startNeedsProgress, Linux)', () {
    // T6 2026-10-22, F2: media_kit reported the clip playing and ready, then
    // libmpv never returned from opening its audio output and nothing more
    // came: no position, no end, no error.
    test('playing and ready alone is not a start; the first position past '
        'zero is', () {
      fakeAsync((async) {
        final h = _Harness(async, startNeedsProgress: true);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        expect(h.fake.playing, isTrue);
        expect(h.fake.processingState, ProcessingState.ready);
        expect(h.events, isEmpty, reason: 'loaded and asked to play only');
        h.fake.progress(position: Duration.zero);
        h.flush();
        expect(h.events, isEmpty, reason: 'a position that has not moved');
        h.fake.progress();
        h.flush();
        expect(h.events, [_started('a')]);
        h.fake.progress(position: const Duration(milliseconds: 200));
        h.flush();
        expect(h.events, [_started('a')], reason: 'once per clip');
      });
    });

    test('the next clip of the playlist starts on its own first position', () {
      fakeAsync((async) {
        final h = _Harness(async, startNeedsProgress: true);
        h.player
          ..enqueue('a', mediaType: _mp3)
          ..enqueue('b', mediaType: _mp3);
        h.flush();
        h.fake.progress();
        h.flush();
        h.fake.advance(); // a -> b
        h.flush();
        expect(h.events, [_started('a'), _finished('a')]);
        h.fake.progress();
        h.flush();
        expect(h.events, [_started('a'), _finished('a'), _started('b')]);
      });
    });

    test('a clip whose position never moves reports nothing, however long: '
        "the speaker's start timeout decides", () {
      fakeAsync((async) {
        final h = _Harness(async, startNeedsProgress: true);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        async.elapse(const Duration(minutes: 2));
        expect(h.events, isEmpty);
        expect(h.fake.stopCalls, 0);
      });
    });

    test('the next clip starts from nothing: after a clip that was heard, '
        'one that completes without its position moving was not', () {
      fakeAsync((async) {
        final h = _Harness(async, startNeedsProgress: true)
          ..fake.clipLength = const Duration(milliseconds: 1560);
        h.player
          ..enqueue('a', mediaType: _mp3)
          ..enqueue('b', mediaType: _mp3);
        h.flush();
        h.fake.progress();
        h.flush();
        async.elapse(const Duration(seconds: 2)); // a plays out
        h.fake.advance(); // a -> b
        h.flush();
        async.elapse(const Duration(milliseconds: 10));
        h.fake.advance(); // b "completes" at once, never moving
        h.flush();
        expect(h.events, [_started('a'), _finished('a'), _silent('b')]);
      });
    });

    test('a start detected late counts what its position proves played', () {
      fakeAsync((async) {
        final h = _Harness(async, startNeedsProgress: true)
          ..fake.clipLength = const Duration(milliseconds: 600);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        async.elapse(const Duration(milliseconds: 400));
        // The first position update arrives 400 ms in, saying so.
        h.fake.progress(position: const Duration(milliseconds: 400));
        h.flush();
        async.elapse(const Duration(milliseconds: 200));
        h.fake.advance(); // the whole 600 ms played
        h.flush();
        expect(h.events, [_started('a'), _finished('a')]);
      });
    });

    test('a clip that ends without its position moving was not heard', () {
      fakeAsync((async) {
        final h = _Harness(async, startNeedsProgress: true)
          ..fake.clipLength = const Duration(milliseconds: 1560);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        h.fake.advance(); // libmpv without an audio device: done at once
        h.flush();
        expect(h.events, [_silent('a')]);
      });
    });
  });

  test('a playback error fails the run', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.player.enqueue('a', mediaType: _mp3);
      h.flush();
      h.fake.error();
      h.flush();
      expect(h.events.last, _failed('a'));
    });
  });

  test('stop ends the run: no more events, the player stopped', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.player
        ..enqueue('a', mediaType: _mp3)
        ..enqueue('b', mediaType: _mp3);
      h.flush();
      h.player.stop();
      h.flush();
      expect(h.fake.stopCalls, 1);
      h.fake.advance();
      h.flush();
      expect(h.events, [_started('a')]);
      h.player.enqueue('c', mediaType: _mp3);
      h.flush();
      expect(h.fake.loads.last, ['c']);
    });
  });

  group('the media type', () {
    test('every type the package accepts is playable', () {
      fakeAsync((async) {
        final h = _Harness(async);
        for (final type in kAllowedAudioTypes.keys) {
          h.player.enqueue('clip', mediaType: type);
        }
        h.flush();
        expect(h.events, [_started('clip')]);
      });
    });

    test('an unsupported type throws before anything is touched, and the '
        'next clip starts afresh', () {
      fakeAsync((async) {
        final h = _Harness(async);
        Object? thrown;
        h.player
            .enqueue('a', mediaType: 'audio/wav')
            .catchError((Object e) => thrown = e);
        h.flush();
        expect(thrown, isA<UnsupportedError>());
        expect(h.fake.loads, isEmpty);
        expect(h.configurations, 0, reason: 'no session, no player');
        expect(h.events, isEmpty);

        h.player.enqueue('b', mediaType: _mp3);
        h.flush();
        expect(h.fake.loads, [
          ['b'],
        ]);
        expect(h.events, [_started('b')]);
      });
    });

    test('an unsupported type appended mid-run leaves the playlist alone', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        var refused = false;
        h.player
            .enqueue('b', mediaType: 'audio/ogg')
            .catchError((Object _) => refused = true);
        h.flush();
        expect(refused, isTrue);
        expect(h.fake.appended, isEmpty);
        h.fake.advance(); // a -> the end
        h.flush();
        expect(h.events, [_started('a'), _finished('a')]);
      });
    });
  });

  group('stop and dispose are not held behind a pending load or append', () {
    test('a stop while an append never completes stops the player at once; '
        'after interruptWait the stuck player is abandoned and the next '
        'reply plays on a new one', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        expect(h.events, [_started('a')]);
        final stuck = h.fake..appendGate = Completer<void>(); // never ends
        h.player.enqueue('b', mediaType: _mp3);
        h.flush();

        var stopped = false;
        h.player.stop().then((_) => stopped = true);
        h.flush();
        expect(stuck.stopCalls, 1, reason: 'not queued behind the append');
        expect(stuck.playing, isFalse);
        expect(stopped, isFalse, reason: 'the append is still in flight');

        h.player.enqueue('c', mediaType: _mp3);
        h.flush();
        expect(h.built, hasLength(1), reason: 'waits, up to the bound');
        async.elapse(h.player.interruptWait);
        expect(stopped, isTrue);
        // The stuck append holds that player's playlist lock for good: its
        // own next load could never start.
        expect(h.events, [_started('a'), _started('c')]);
        expect(stuck.disposeCalls, 1, reason: 'abandoned');
        expect(h.built, hasLength(2));
        expect(h.fake.loads, [
          ['c'],
        ]);
      });
    });

    test('a native stop that never returns: stop completes after '
        'interruptWait, and the next reply plays on a new player', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        final stuck = h.fake..stopGate = Completer<void>(); // never ends

        var stopped = false;
        h.player.stop().then((_) => stopped = true);
        h.flush();
        expect(stuck.playing, isFalse);
        async.elapse(h.player.interruptWait);
        expect(stopped, isTrue);
        expect(stuck.disposeCalls, 1, reason: 'abandoned');

        h.player.enqueue('c', mediaType: _mp3);
        h.flush();
        expect(h.built, hasLength(2));
        expect(h.events, [_started('a'), _started('c')]);
      });
    });

    test('focus taken only after a stop, its release and the disposal is '
        'given back as that release said', () {
      for (final captureLive in [false, true]) {
        fakeAsync((async) {
          // iOS: a live capture keeps the shared session.
          final h = _Harness(async, releaseKeepsCapture: false);
          final activation = h.activationGate = Completer<void>();
          h.player.enqueue('a', mediaType: _mp3);
          h.flush();
          expect(h.activations, 1);
          // The speaker's teardown order: stop, release, then dispose.
          h.player.stop();
          h.player
              .release(captureLive: captureLive)
              .then((_) => h.player.dispose());
          async.elapse(h.player.interruptWait);
          expect(h.deactivations, 0, reason: 'nothing was taken yet');

          activation.complete(); // the focus is granted after all
          h.flush();
          expect(
            h.deactivations,
            captureLive ? 0 : 1,
            reason: 'captureLive=$captureLive',
          );
          expect(h.fake.playCalls, 0);
        });
      }
    });

    test("an abandoned player's late play() failure leaves the next reply "
        'alone', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        final stuck = h.fake..appendGate = Completer<void>();
        h.player.enqueue('b', mediaType: _mp3);
        h.flush();
        h.player.stop();
        async.elapse(h.player.interruptWait); // a's player abandoned
        h.player.enqueue('c', mediaType: _mp3);
        h.flush();
        expect(h.events, [_started('a'), _started('c')]);

        stuck.plays.single.completeError(PlayerException(1, 'late', 0));
        h.flush();
        expect(h.events, [_started('a'), _started('c')]);
        expect(h.fake.stopCalls, 0, reason: "c's player is left playing");
      });
    });

    test('a late focus being given back: the next reply takes the session '
        'only after it', () {
      fakeAsync((async) {
        final h = _Harness(async);
        final lateFocus = h.activationGate = Completer<void>();
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        h.player.stop();
        h.player.release(captureLive: false);
        async.elapse(h.player.interruptWait);
        h.activationGate = null;
        final deactivation = h.deactivationGate = Completer<void>();
        lateFocus.complete(); // a's focus, granted after its stop
        h.flush();
        expect(h.deactivations, 1, reason: 'being given back');

        h.player.enqueue('c', mediaType: _mp3);
        h.flush();
        expect(h.activations, 1, reason: 'c waits for the give-back');
        deactivation.complete();
        h.flush();
        expect(h.activations, 2);
        expect(h.events, [_started('c')]);

        h.deactivationGate = null;
        h.fake.advance(); // c ends
        h.flush();
        h.player.release(captureLive: false);
        h.flush();
        expect(h.deactivations, 2, reason: "c's own focus given back");
      });
    });

    test('a late give-back that outlasts interruptWait leaves the next '
        "reply's session to it", () {
      fakeAsync((async) {
        final h = _Harness(async);
        final lateFocus = h.activationGate = Completer<void>();
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        h.player.stop();
        h.player.release(captureLive: false);
        async.elapse(h.player.interruptWait);
        h.activationGate = null;
        final deactivation = h.deactivationGate = Completer<void>();
        lateFocus.complete();
        h.flush();

        h.player.enqueue('c', mediaType: _mp3);
        async.elapse(h.player.interruptWait); // c goes ahead without it
        expect(h.activations, 2);
        h.deactivationGate = null;
        deactivation.complete(); // a's give-back returns after c took it
        h.flush();

        h.fake.advance(); // c ends
        h.flush();
        h.player.release(captureLive: false);
        h.flush();
        expect(
          h.deactivations,
          2,
          reason: "c's session is still its own to give back",
        );
      });
    });

    test('a late focus after the next reply already ended and gave its '
        'focus back is given back too', () {
      fakeAsync((async) {
        final h = _Harness(async);
        final lateFocus = h.activationGate = Completer<void>();
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        h.player.stop();
        h.player.release(captureLive: false);
        async.elapse(h.player.interruptWait);
        h.activationGate = null;
        h.player.enqueue('c', mediaType: _mp3);
        h.flush();
        h.fake.advance(); // c ends
        h.flush();
        h.player.release(captureLive: false);
        h.flush();
        expect(h.deactivations, 1);

        lateFocus.complete(); // a's focus, granted with no reply left
        h.flush();
        expect(h.deactivations, 2, reason: 'nobody else would give it back');
      });
    });

    test('disposed while the session is being configured: no player is '
        'left undisposed', () {
      fakeAsync((async) {
        final h = _Harness(async);
        final configure = h.configureGate = Completer<void>();
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        h.player.dispose();
        h.flush();
        configure.complete();
        h.flush();
        async.elapse(h.player.interruptWait);
        expect(h.built.where((p) => p.disposeCalls == 0), isEmpty);
        expect(h.activations, 0);
      });
    });

    test('dispose completes while an append never completes', () async {
      // Real time: our subscriptions' cancels complete in the root zone.
      final fake = _FakeAudioPlayer();
      final player = JustAudioReplyPlayer(
        createPlayer: () => fake,
        configureSession: () async {},
        activateSession: () async => true,
        deactivateSession: () async => true,
        interruptWait: const Duration(milliseconds: 50),
      );
      final events = <ReplyClipEvent>[];
      player.clipEvents.listen(events.add);
      await player.enqueue('a', mediaType: _mp3);
      await pumpEventQueue();
      expect(events, [_started('a')]);
      fake.appendGate = Completer<void>(); // never completes
      unawaited(player.enqueue('b', mediaType: _mp3));
      await pumpEventQueue();

      final disposed = player.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(fake.disposeCalls, 1, reason: 'cuts the append at once');
      await disposed.timeout(const Duration(seconds: 5));
    });

    test("the speaker's disposal with a native stop that never returns "
        'still disposes the player and deletes the clips', () async {
      // Real time: the wrapper's disposal completes through our
      // subscriptions' cancels, which finish in the root zone.
      final fakes = <_FakeAudioPlayer>[];
      final player = JustAudioReplyPlayer(
        createPlayer: () {
          final fake = _FakeAudioPlayer()..stopGate = Completer<void>();
          fakes.add(fake);
          return fake;
        },
        configureSession: () async {},
        activateSession: () async => true,
        deactivateSession: () async => true,
        interruptWait: const Duration(milliseconds: 50),
      );
      final s = _SpeakerOver(null, player);
      s.events.add(const SpeakerFinal('t1', 'One.'));
      await pumpEventQueue();
      expect(s.files.files, hasLength(1));
      expect(fakes.single.playing, isTrue);

      s.speaker.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fakes.single.disposeCalls, greaterThan(0));
      expect(s.files.files, isEmpty);
    });

    test('a load a stop cut plays nothing, whenever it returns', () {
      fakeAsync((async) {
        final h = _Harness(async);
        final load = h.fake.loadGate = Completer<void>();
        h.player.enqueue('a', mediaType: _mp3);
        h.flush();
        h.player.stop();
        h.flush();
        expect(h.fake.stopCalls, 1);
        load.complete(); // the load returns after all
        h.flush();
        async.elapse(h.player.interruptWait);
        expect(h.activations, 0);
        expect(h.fake.playCalls, 0);
        expect(h.events, isEmpty);
      });
    });

    test('a barge-in stops the clip playing at once while the next clip\'s '
        'append stalls, and its clips are deleted', () {
      fakeAsync((async) {
        final h = _Harness(async);
        final s = _SpeakerOver(async, h.player)..interrupt = true;
        h.fake.appendGate = Completer<void>();
        s.events.add(const SpeakerFinal('t1', 'One. Two.'));
        async.flushMicrotasks();
        expect(h.events, [_started(s.files.written.keys.first)]);
        expect(s.files.written, hasLength(2), reason: 'Two. is appending');

        s.speechStarts.add(null);
        async.flushMicrotasks();
        expect(s.speaker.playing.value, isFalse);
        expect(h.fake.stopCalls, 1, reason: 'not queued behind the append');
        expect(h.fake.playing, isFalse);
        async.elapse(h.player.interruptWait);
        expect(s.files.files, isEmpty);
      });
    });
  });

  group("the speaker's disposal gives the session back as the mic allows "
      '(iOS: shared with the recorder)', () {
    for (final micLive in [false, true]) {
      test(micLive ? 'mic live: kept' : 'mic off: deactivated', () {
        fakeAsync((async) {
          final h = _Harness(async, releaseKeepsCapture: false);
          final s = _SpeakerOver(async, h.player)..micLive = micLive;
          s.events.add(const SpeakerFinal('t1', 'One.'));
          async.flushMicrotasks();
          expect(h.activations, 1);
          expect(s.speaker.playing.value, isTrue);

          s.speaker.dispose(); // e.g. sign-out, during playback
          async.flushMicrotasks();
          expect(h.fake.disposeCalls, 1);
          expect(h.deactivations, micLive ? 0 : 1);
        });
      });
    }
  });

  test('a clip that cannot load throws, and the next starts afresh', () {
    fakeAsync((async) {
      final h = _Harness(async)..fake.loadError = StateError('bad mp3');
      Object? thrown;
      h.player
          .enqueue('a', mediaType: _mp3)
          .catchError((Object e) => thrown = e);
      h.flush();
      expect(thrown, isA<StateError>());
      h.player.enqueue('b', mediaType: _mp3);
      h.flush();
      expect(h.fake.loads.last, ['b']);
      expect(h.events, [_started('b')]);
    });
  });
}

ReplyClipEvent _started(String p) => ReplyClipEvent(p, ReplyClipPhase.started);
ReplyClipEvent _finished(String p) =>
    ReplyClipEvent(p, ReplyClipPhase.finished);
ReplyClipEvent _failed(String p) => ReplyClipEvent(p, ReplyClipPhase.failed);
ReplyClipEvent _silent(String p) => ReplyClipEvent(p, ReplyClipPhase.silent);

class _Harness {
  _Harness(
    this.async, {
    bool releaseKeepsCapture = true,
    bool startNeedsProgress = false,
  }) {
    player = JustAudioReplyPlayer(
      createPlayer: () {
        // The first is [fake] as the test set it up; each later one (after
        // the wrapper abandoned a stuck player) is a new fake.
        if (built.isNotEmpty) fake = _FakeAudioPlayer();
        built.add(fake);
        return fake;
      },
      startNeedsProgress: startNeedsProgress,
      configureSession: () async {
        configurations++;
        final gate = configureGate;
        if (gate != null) await gate.future;
      },
      activateSession: () async {
        activations++;
        final gate = activationGate;
        if (gate != null) await gate.future;
        return focusGranted;
      },
      deactivateSession: () async {
        deactivations++;
        final gate = deactivationGate;
        if (gate != null) await gate.future;
        return true;
      },
      releaseKeepsCapture: releaseKeepsCapture,
      now: () => DateTime.utc(2026).add(async.elapsed),
    );
    player.clipEvents.listen(events.add);
  }

  final FakeAsync async;

  /// The player the wrapper uses now (the newest it built).
  _FakeAudioPlayer fake = _FakeAudioPlayer();

  /// Every player the wrapper built, in order.
  final built = <_FakeAudioPlayer>[];
  late final JustAudioReplyPlayer player;

  /// While set, configuring / activating the session waits for it.
  Completer<void>? configureGate;
  Completer<void>? activationGate;
  Completer<void>? deactivationGate;
  final events = <ReplyClipEvent>[];
  bool focusGranted = true;
  int activations = 0;
  int deactivations = 0;
  int configurations = 0;

  void flush() => async.flushMicrotasks();
}

/// A [ReplySpeaker] over [player] (the real wrapper, on the fake just_audio
/// player), with fake speech that answers at once and in-memory clips.
class _SpeakerOver {
  _SpeakerOver(FakeAsync? async, ReplyAudioPlayer player) {
    tts.autoReply = true;
    speaker = ReplySpeaker(
      SpeakerPorts(
        turnEvents: events.stream,
        cancelledTurns: const Stream.empty(),
        speechModeChanges: const Stream.empty(),
        userSpeechStarts: speechStarts.stream,
        micOff: const Stream.empty(),
        clipFiles: files,
        activeTurnId: () => null,
        isEligible: (_) => true,
        interruptByVoice: () => interrupt,
        tts: tts,
        voice: () => 'Jason',
        playerFactory: () => player,
        captureLive: () => micLive,
      ),
      listenToLifecycle: false,
      monotonic: async == null ? null : () => async.elapsed,
    );
    addTearDown(speaker.dispose);
    async?.flushMicrotasks();
  }

  final events = StreamController<SpeakerTurnEvent>.broadcast();
  final speechStarts = StreamController<void>.broadcast();
  final tts = FakeReplyTts();
  final files = FakeClipFiles();
  bool interrupt = false;
  bool micLive = false;
  late final ReplySpeaker speaker;
}

/// The parts of just_audio's [AudioPlayer] the wrapper uses. Streams deliver
/// asynchronously (like the real player's subjects), states are distinct.
class _FakeAudioPlayer implements AudioPlayer {
  final _index = StreamController<int?>.broadcast();
  final _state = StreamController<PlayerState>.broadcast();
  final _errors = StreamController<PlayerException>.broadcast();
  final _playback = StreamController<PlaybackEvent>.broadcast();
  final List<String> _sources = [];
  final loads = <List<String>>[];
  final appended = <String>[];
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  Object? loadError;

  /// While set, [setAudioSources] / [addAudioSource] wait for it before
  /// doing anything (a load or an append the platform has not finished).
  /// Both hold the playlist's lock meanwhile, as just_audio 0.10.6's do
  /// (`ConcatenatingAudioSource._lock`, taken by `add` across the platform
  /// call and by `_init` in `setAudioSources`): a stuck append blocks every
  /// later load of this player.
  Completer<void>? loadGate;
  Completer<void>? appendGate;

  /// While set, [stop] waits for it after updating its state (just_audio
  /// stops releasing its platform).
  Completer<void>? stopGate;

  Future<void> _playlistLock = Future<void>.value();

  Future<T> _withPlaylistLock<T>(Future<T> Function() body) {
    final result = _playlistLock.then((_) => body());
    _playlistLock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// The length each clip reports once loaded (just_audio sets it on the
  /// source); null: unknown.
  Duration? clipLength;

  /// play() changes nothing (just_audio's own session activation failed).
  bool playDoesNothing = false;
  bool _playing = false;
  ProcessingState _processing = ProcessingState.idle;
  int? _currentIndex;
  PlayerState? _last;

  void _emitState() {
    final next = PlayerState(_playing, _processing);
    if (_last != null &&
        _last!.playing == next.playing &&
        _last!.processingState == next.processingState) {
      return;
    }
    _last = next;
    _state.add(next);
  }

  void _setIndex(int index) {
    _currentIndex = index;
    _index.add(index);
  }

  /// The clip playing ends: the next plays, or the playlist completes.
  void advance() {
    final index = _currentIndex ?? 0;
    if (index + 1 < _sources.length) {
      _setIndex(index + 1);
    } else {
      _processing = ProcessingState.completed;
      _emitState();
    }
  }

  void systemPause() {
    _playing = false;
    _emitState();
  }

  void systemResume() {
    _playing = true;
    _emitState();
  }

  void error() => _errors.add(PlayerException(1, 'decoder', 0));

  /// A playback event for the clip playing, at [position] (just_audio's
  /// `updatePosition`, as the platform reported it).
  void progress({Duration position = const Duration(milliseconds: 40)}) =>
      _playback.add(
        PlaybackEvent(
          processingState: _processing,
          updatePosition: position,
          currentIndex: _currentIndex,
        ),
      );

  @override
  Stream<int?> get currentIndexStream => _index.stream;

  @override
  Stream<PlayerState> get playerStateStream => _state.stream;

  @override
  Stream<PlayerException> get errorStream => _errors.stream;

  @override
  Stream<PlaybackEvent> get playbackEventStream => _playback.stream;

  @override
  int? get currentIndex => _currentIndex;

  @override
  ProcessingState get processingState => _processing;

  @override
  bool get playing => _playing;

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) => _withPlaylistLock(() async {
    final gate = loadGate;
    if (gate != null) await gate.future;
    final error = loadError;
    if (error != null) {
      loadError = null;
      throw error;
    }
    for (final source in audioSources) {
      (source as IndexedAudioSource).duration = clipLength;
    }
    _sources
      ..clear()
      ..addAll(audioSources.map(_pathOf));
    loads.add(List.of(_sources));
    _processing = ProcessingState.loading;
    _emitState();
    _setIndex(0);
    _processing = ProcessingState.ready;
    _emitState();
    return const Duration(seconds: 1);
  });

  @override
  Future<void> addAudioSource(AudioSource audioSource) =>
      _withPlaylistLock(() async {
        final gate = appendGate;
        if (gate != null) await gate.future;
        (audioSource as IndexedAudioSource).duration = clipLength;
        final path = _pathOf(audioSource);
        _sources.add(path);
        appended.add(path);
      });

  @override
  Future<void> play() {
    playCalls++;
    if (playDoesNothing) return Future<void>.value();
    _playing = true;
    _emitState();
    // Until paused (never, here), or a test fails it.
    final result = Completer<void>();
    plays.add(result);
    return result.future;
  }

  /// Each [play]'s future, in order.
  final plays = <Completer<void>>[];

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing = false;
    _emitState();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing = false;
    _processing = ProcessingState.idle;
    _emitState();
    final gate = stopGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (index != null) _setIndex(index);
    _processing = ProcessingState.ready;
    _emitState();
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _index.close();
    await _state.close();
    await _errors.close();
    await _playback.close();
  }

  static String _pathOf(AudioSource source) =>
      (source as UriAudioSource).uri.toFilePath();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
