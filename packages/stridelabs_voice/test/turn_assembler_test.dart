import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

/// A relay event at [t] ms after the session opened.
typedef _Ev = (int t, String kind, String? text);

const _start = 'start';
const _end = 'end';
const _partial = 'partial';
const _eot = 'eot';

/// The spike's keywords-on multi-fragment cases (plan 013 E1, Meta Muse on
/// synthesized speech), with the RECORDED timings from `E1-results.json`
/// (`speechStart`, `speechEnd`, `speechComplete`; ms from session start).
/// Muse ends a turn at every pause; the expected column is what the pinned
/// merge rule (unfinished → wait ≤ 1.5 s for `speech_start`) makes of them.
/// Together they reproduce the spike's measured residual splits with the
/// rule at 1500 ms: set A 2/20 (A15, A18), set B 3/20 (B05, B09, B15).
final _spikeCases = <String, (List<_Ev>, List<String>)>{
  'A15': (
    [
      (536, _start, null),
      (2210, _end, null),
      (2210, _eot, 'Is it going to rain in Seattle?'),
      (2457, _start, null),
      (3825, _end, null),
      (3825, _eot, 'on Saturday afternoon?'),
    ],
    // Both fragments look finished: a known residual split.
    ['Is it going to rain in Seattle?', 'on Saturday afternoon?'],
  ),
  'A18': (
    [
      (412, _start, null),
      (3621, _end, null),
      (3621, _eot, 'Show me what a cozy reading nook.'),
      (4176, _start, null),
      (5935, _end, null),
      (5935, _eot, 'with a big window could look like'),
    ],
    // Misleading punctuation ends the first fragment.
    ['Show me what a cozy reading nook.', 'with a big window could look like'],
  ),
  'B01': (
    [
      (442, _start, null),
      (4917, _end, null),
      (4917, _eot, 'Set a timer for'),
      (5488, _start, null),
      (6220, _end, null),
      (6220, _eot, 'Ten minutes.'),
    ],
    ['Set a timer for Ten minutes.'],
  ),
  'B02': (
    [
      (408, _start, null),
      (2171, _end, null),
      (2171, _eot, "What's the weather in"),
      (2891, _start, null),
      (5780, _end, null),
      (5780, _eot, 'um Denver this weekend'),
    ],
    ["What's the weather in um Denver this weekend"],
  ),
  'B04': (
    [
      (493, _start, null),
      (5615, _end, null),
      (5615, _eot, 'I want to plan a trip to'),
      (5858, _start, null),
      (6993, _end, null),
      (6993, _eot, ' Portland next month.'),
    ],
    ['I want to plan a trip to Portland next month.'],
  ),
  'B05': (
    [
      (520, _start, null),
      (3238, _end, null),
      (3238, _eot, ' generate an image of'),
      (4357, _start, null),
      (7024, _end, null),
      (7024, _eot, 'a lighthouse at sunset'),
      // 2132 ms after the previous end_of_turn: past the 1.5 s window.
      (9156, _start, null),
      (10132, _end, null),
      (10132, _eot, 'with big waves'),
    ],
    ['generate an image of a lighthouse at sunset', 'with big waves'],
  ),
  'B09': (
    [
      (415, _start, null),
      (3776, _end, null),
      (3776, _eot, 'What was the name of that brewery?'),
      (5299, _start, null),
      (6206, _end, null),
      (6206, _eot, 'In Grand Marais?'),
    ],
    ['What was the name of that brewery?', 'In Grand Marais?'],
  ),
  'B14': (
    [
      (456, _start, null),
      (3096, _end, null),
      (3096, _eot, 'Remember that, unallergic to'),
      (3902, _start, null),
      (4645, _end, null),
      (4645, _eot, 'shellfish?'),
    ],
    ['Remember that, unallergic to shellfish?'],
  ),
  'B15': (
    [
      (417, _start, null),
      (1563, _end, null),
      (1563, _eot, 'Tell me a joke.'),
      (2267, _start, null),
      (3459, _end, null),
      (3459, _eot, 'about'),
      (4260, _start, null),
      (7311, _end, null),
      (7311, _eot, 'uh accountants'),
    ],
    ['Tell me a joke.', 'about uh accountants'],
  ),
  'B17': (
    [
      (654, _start, null),
      (6747, _end, null),
      (6747, _eot, 'set a reminder for Friday at'),
      (6983, _start, null),
      (8028, _end, null),
      (8028, _eot, '3 PM'),
    ],
    ['set a reminder for Friday at 3 PM'],
  ),
  'B18': (
    [
      (483, _start, null),
      (1148, _end, null),
      (1148, _eot, 'Show me.'),
      (2254, _start, null),
      (5637, _end, null),
      (5637, _eot, 'A picture of a mountain cabin in winter.'),
    ],
    // "me" is a function word, so "Show me." counts as unfinished despite
    // its period, and the next fragment (1106 ms later) joins it.
    ['Show me. A picture of a mountain cabin in winter.'],
  ),
};

void main() {
  group('isUnfinishedFragment', () {
    final table = <String, bool>{
      'Set a timer for': true, // no terminal punctuation
      'Ten minutes.': false,
      'Is it going to rain in Seattle?': false,
      'Wow!': false,
      'Show me.': true, // function word, punctuation stripped
      'Tell me a joke.': false,
      'What is THE.': true, // case-insensitive
      'He said "stop."': false, // closing quote after the period
      'um': true,
      'Hmm?': true,
      '': true,
      'about': true,
      "That's it.": false,
    };
    for (final MapEntry(key: fragment, value: unfinished) in table.entries) {
      test('"$fragment" → ${unfinished ? 'unfinished' : 'finished'}', () {
        expect(isUnfinishedFragment(fragment), unfinished);
      });
    }
  });

  group('spike split cases (keywords on, recorded timings)', () {
    for (final MapEntry(key: id, value: (events, expected))
        in _spikeCases.entries) {
      test('$id → ${expected.length} utterance(s)', () {
        fakeAsync((async) {
          final h = _Harness(async);
          h.replay(events);
          async.elapse(const Duration(seconds: 15));
          expect(h.texts, expected);
        });
      });
    }

    test('sttMs runs from the first speech_start to the final end_of_turn', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay(_spikeCases['B01']!.$1);
        expect(h.out, [
          const VoiceUtterance('Set a timer for Ten minutes.', 5778),
        ]);

        final b15 = _Harness(async);
        b15.replay(_spikeCases['B15']!.$1);
        async.elapse(const Duration(seconds: 2));
        // "Tell me a joke." 417 → 1563; "about uh accountants" from its own
        // first start (2267) to its final end_of_turn (7311).
        expect(b15.out, const [
          VoiceUtterance('Tell me a joke.', 1146),
          VoiceUtterance('about uh accountants', 5044),
        ]);
      });
    });

    test('B05 merges into one utterance when every pause is under 1.5 s', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (520, _start, null),
          (3238, _eot, ' generate an image of'),
          (4357, _start, null),
          (7024, _eot, 'a lighthouse at sunset'),
          (8224, _start, null), // 1200 ms later
          (10132, _eot, 'with big waves'),
        ]);
        async.elapse(const Duration(seconds: 2));
        expect(h.texts, [
          'generate an image of a lighthouse at sunset with big waves',
        ]);
      });
    });
  });

  group('the 1.5 s merge window', () {
    test('a speech_start 1.49 s after an unfinished fragment merges', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (1000, _eot, 'Set a timer for'),
          (2490, _start, null),
          (3000, _eot, 'ten minutes.'),
        ]);
        expect(h.texts, ['Set a timer for ten minutes.']);
      });
    });

    test('a speech_start 1.51 s after an unfinished fragment does not', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (1000, _eot, 'Set a timer for'),
          (2510, _start, null),
          (3000, _eot, 'ten minutes.'),
        ]);
        expect(h.texts, ['Set a timer for', 'ten minutes.']);
        expect(h.out.first.sttMs, 1000);
      });
    });

    test('a speech_start exactly at the deadline still merges', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (1000, _eot, 'Set a timer for'),
          (2500, _start, null), // end_of_turn + 1500 ms exactly
          (3000, _eot, 'ten minutes.'),
        ]);
        expect(h.out, [
          const VoiceUtterance('Set a timer for ten minutes.', 3000),
        ]);
      });
    });

    test('an unfinished fragment is emitted just after the window closes', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([(0, _start, null), (500, _eot, 'Turn on the')]);
        async.elapse(const Duration(milliseconds: 1500));
        expect(h.out, isEmpty, reason: 'a start now would still merge');
        async.elapse(const Duration(milliseconds: 1));
        expect(h.texts, ['Turn on the']);
      });
    });

    test('a start past the deadline whose timer has not run yet splits', () {
      // The timer is only a backstop: the event's own time decides, so a
      // late timer cannot let a start after the window merge.
      final epoch = DateTime.utc(2026, 10, 17);
      var now = epoch;
      final out = <VoiceUtterance>[];
      fakeAsync((async) {
        final a = TurnAssembler(onUtterance: out.add, now: () => now);
        a.speechStart();
        now = epoch.add(const Duration(milliseconds: 800));
        a.endOfTurn('Set a timer for');
        // The clock moves past the deadline without the timer running.
        now = epoch.add(const Duration(milliseconds: 2400));
        a.speechStart();
        expect(out, [const VoiceUtterance('Set a timer for', 800)]);
        now = epoch.add(const Duration(milliseconds: 3000));
        a.endOfTurn('ten minutes.');
        expect(out.map((u) => u.text), ['Set a timer for', 'ten minutes.']);
        a.dispose();
      });
    });

    test('a finished fragment is emitted at once', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([(0, _start, null), (700, _eot, 'What time is it?')]);
        expect(h.out, [const VoiceUtterance('What time is it?', 700)]);
      });
    });
  });

  group('speech_start without an end_of_turn', () {
    test('flushes 1 s after speech_end, with the live partial', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (400, _partial, 'turn on'),
          (800, _partial, 'turn on the lights'),
          (1200, _end, null),
        ]);
        async.elapse(const Duration(milliseconds: 999));
        expect(h.out, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(h.out, [const VoiceUtterance('turn on the lights', 2200)]);
      });
    });

    test('flushes 10 s after the start when no speech_end comes', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([(0, _start, null), (300, _partial, 'hello')]);
        async.elapse(const Duration(milliseconds: 9699));
        expect(h.out, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(h.texts, ['hello']);
      });
    });

    test('a fallback flush reports the segment closed; an end_of_turn does '
        'not', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (500, _eot, 'Hello there.'),
          (1000, _start, null),
          (1200, _end, null),
        ]);
        expect(h.segmentsFlushed, 0, reason: 'closed by its end_of_turn');
        async.elapse(const Duration(seconds: 1));
        expect(h.segmentsFlushed, 1, reason: 'the speech_end flush');
        // Its late end_of_turn closes nothing more.
        h.assembler.endOfTurn('');
        h.assembler.flush(); // nothing open
        expect(h.segmentsFlushed, 1);
        // Nor for the start-only (10 s) flush with nothing said.
        h.replay([(3000, _start, null)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.segmentsFlushed, 2);
      });
    });

    test('flushes a waiting fragment whose continuation never completes', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (900, _eot, 'Set a timer for'),
          (1500, _start, null), // cancels the merge wait...
          (1900, _end, null), // ...and never completes
        ]);
        async.elapse(const Duration(milliseconds: 1000));
        expect(h.texts, ['Set a timer for']);
      });
    });

    test("a flushed segment's late end_of_turn is not emitted again", () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (600, _partial, 'turn on the lights'),
          (900, _end, null),
        ]);
        async.elapse(const Duration(seconds: 1)); // flushed at 1900
        expect(h.texts, ['turn on the lights']);
        // Muse's speechComplete for that segment arrives late.
        h.replay([(2300, _eot, 'Turn on the lights.')]);
        async.elapse(const Duration(seconds: 5));
        expect(h.texts, ['turn on the lights'], reason: 'one emission');
      });
    });

    test('a segment flushed with nothing said keeps its late end_of_turn', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([(0, _start, null), (700, _end, null)]);
        async.elapse(const Duration(seconds: 1)); // flushed, nothing to say
        expect(h.out, isEmpty);
        h.replay([(2000, _eot, 'Hello there.')]);
        async.elapse(const Duration(seconds: 5));
        expect(h.texts, ['Hello there.'], reason: 'one emission');
      });
    });

    test('after a flush, the next segment is assembled normally', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (400, _partial, 'hello'),
          (500, _end, null),
        ]);
        async.elapse(const Duration(seconds: 1));
        h.replay([
          (2000, _start, null), // a new segment: no late end is expected now
          (2600, _eot, 'What time is it?'),
        ]);
        expect(h.texts, ['hello', 'What time is it?']);
      });
    });

    test('a speech_start after a speech_end re-arms the flush: no mid-speech '
        'flush, and the real end_of_turn is still emitted', () {
      fakeAsync((async) {
        final h = _Harness(async, isUnfinished: (_) => false);
        h.replay([
          (0, _start, null),
          (200, _partial, 'hello'),
          (400, _end, null),
          (900, _start, null), // the speaker resumes, 500 ms later
        ]);
        // 1 s after the first end: the stale speech_end timer is gone.
        h.replay([(1400, _partial, 'hello wor')]);
        expect(h.out, isEmpty);
        expect(h.segmentsFlushed, 0);
        h.replay([(2000, _eot, 'hello world')]);
        expect(h.texts, ['hello world']);
        async.elapse(const Duration(seconds: 20));
        expect(h.texts, ['hello world'], reason: 'said once');
        expect(h.segmentsFlushed, 0);
      });
    });

    test('the re-armed start timer still flushes a segment that never '
        'completes, from the second start', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (200, _partial, 'hello'),
          (400, _end, null),
          (900, _start, null),
        ]);
        // Not at the first end + 1 s, nor at the first start + 10 s.
        h.replay([(10899, _partial, 'hello')]);
        expect(h.out, isEmpty);
        expect(h.segmentsFlushed, 0);
        // The second start + 10 s.
        async.elapse(const Duration(milliseconds: 1));
        expect(h.texts, ['hello']);
        expect(h.segmentsFlushed, 1);
      });
    });

    test('a silent start (no partial, no end_of_turn) emits nothing', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([(0, _start, null), (500, _end, null)]);
        async.elapse(const Duration(seconds: 20));
        expect(h.out, isEmpty);
      });
    });
  });

  group('micOff', () {
    test('emits a waiting unfinished fragment at once', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([(0, _start, null), (800, _eot, 'Set a timer for')]);
        h.assembler.micOff();
        expect(h.out, [const VoiceUtterance('Set a timer for', 800)]);
      });
    });

    test('with a segment open, emits after its final end_of_turn', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([(0, _start, null), (600, _partial, 'remind me to')]);
        h.assembler.micOff();
        expect(h.out, isEmpty);
        // The final end_of_turn arrives; unfinished or not, nothing more is
        // coming, so it is emitted without the merge wait.
        h.replay([(900, _eot, 'remind me to')]);
        expect(h.texts, ['remind me to']);
      });
    });

    test('with nothing held, emits nothing', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.assembler.micOff();
        async.elapse(const Duration(seconds: 5));
        expect(h.out, isEmpty);
      });
    });
  });

  group('pending display', () {
    test('shows pending fragments plus the live partial, cleared on emit', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (300, _partial, 'set a'),
          (800, _eot, 'Set a timer for'),
          (1200, _start, null),
          (1400, _partial, 'ten'),
        ]);
        expect(h.assembler.pendingDisplay, 'Set a timer for ten');
        h.replay([(1800, _eot, 'ten minutes.')]);
        expect(h.assembler.pendingDisplay, '');
        expect(h.pending, [
          'set a',
          'Set a timer for',
          'Set a timer for ten',
          '',
        ]);
      });
    });

    test('ignores a partial when no segment is open', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.assembler.partial('stale');
        expect(h.assembler.pendingDisplay, '');
        expect(h.pending, isEmpty);
      });
    });
  });

  group('flush, reset, clamping', () {
    test('flush emits what is held, the partial included', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([
          (0, _start, null),
          (500, _eot, 'Show me'),
          (900, _start, null),
          (1100, _partial, 'a picture'),
        ]);
        h.assembler.flush();
        expect(h.texts, ['Show me a picture']);
      });
    });

    test('dispose leaves no timers and ignores later events', () {
      fakeAsync((async) {
        // One waiting on the merge window, one on an open segment's flush.
        final merging = _Harness(async)
          ..replay([(0, _start, null), (500, _eot, 'Set a timer for')]);
        final open = _Harness(async)
          ..replay([(0, _start, null), (200, _partial, 'turn on')]);
        expect(async.pendingTimers, hasLength(2));
        merging.assembler.dispose();
        open.assembler.dispose();
        expect(async.pendingTimers, isEmpty);
        for (final h in [merging, open]) {
          h.assembler
            ..speechStart()
            ..speechEnd()
            ..endOfTurn('ten minutes.')
            ..micOff()
            ..flush();
        }
        async.elapse(const Duration(seconds: 15));
        expect(merging.out, isEmpty);
        expect(open.out, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('reset drops everything and cancels the timers', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.replay([(0, _start, null), (500, _eot, 'Set a timer for')]);
        h.assembler.reset();
        async.elapse(const Duration(seconds: 15));
        expect(h.out, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('sttMs is clamped to 0-600000, null with no speech_start', () {
      expect(clampSttMs(-5), 0);
      expect(clampSttMs(700000), 600000);
      fakeAsync((async) {
        final h = _Harness(async);
        h.assembler.endOfTurn('No start was seen.');
        expect(h.out, [const VoiceUtterance('No start was seen.', null)]);
      });
    });
  });

  group('the injected policy', () {
    // "Set a timer for" ... a pause of 2.5 s ... "Ten minutes."
    final slowResume = <_Ev>[
      (0, _start, null),
      (400, _end, null),
      (400, _eot, 'Set a timer for'),
      (2900, _start, null),
      (3300, _end, null),
      (3300, _eot, 'Ten minutes.'),
    ];

    test('the defaults are the 1.5 s window and the English end words', () {
      fakeAsync((async) {
        final h = _Harness(async)..replay(slowResume);
        expect(h.texts, ['Set a timer for', 'Ten minutes.']);
      });
      final defaults = TurnAssembler(onUtterance: (_) {});
      expect(defaults.mergeWindow, const Duration(milliseconds: 1500));
      expect(defaults.isUnfinished, same(isUnfinishedFragment));
    });

    test('a longer mergeWindow holds a fragment for a slower speaker', () {
      fakeAsync((async) {
        final h = _Harness(async, mergeWindow: const Duration(seconds: 3))
          ..replay(slowResume);
        expect(h.texts, ['Set a timer for Ten minutes.']);
      });
    });

    test('a shorter mergeWindow gives up sooner, and not before its end', () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          mergeWindow: const Duration(milliseconds: 300),
        )..replay([(0, _eot, 'Set a timer for')]);
        async.elapse(const Duration(milliseconds: 300));
        expect(h.out, isEmpty, reason: 'a start AT the deadline still merges');
        async.elapse(const Duration(milliseconds: 1));
        expect(h.texts, ['Set a timer for']);
      });
    });

    test("another language's end words decide what waits", () {
      // French: "de" ending a punctuated fragment means more is coming;
      // the English list does not know it.
      const frenchEndWords = {'de', 'le', 'la', 'un', 'une', 'pour'};
      bool french(String f) =>
          isUnfinishedFragment(f) ||
          frenchEndWords.contains(
            f.split(' ').last.replaceAll('.', '').toLowerCase(),
          );
      const events = <_Ev>[
        (0, _start, null),
        (400, _end, null),
        (400, _eot, 'Dis-moi ce que tu penses de.'),
        (900, _start, null),
        (1300, _end, null),
        (1300, _eot, 'cette idée.'),
      ];
      fakeAsync((async) {
        final h = _Harness(async, isUnfinished: french)..replay(events);
        expect(h.texts, ['Dis-moi ce que tu penses de. cette idée.']);
      });
      fakeAsync((async) {
        final h = _Harness(async)..replay(events);
        expect(h.texts, ['Dis-moi ce que tu penses de.', 'cette idée.']);
      });
    });

    test('a policy that finds nothing unfinished emits at once', () {
      fakeAsync((async) {
        final h = _Harness(async, isUnfinished: (_) => false)
          ..replay([(0, _eot, 'Set a timer for')]);
        expect(h.texts, ['Set a timer for']);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a policy that finds everything unfinished waits the window', () {
      fakeAsync((async) {
        final h = _Harness(async, isUnfinished: (_) => true)
          ..replay([(0, _eot, 'Turn it off now.')]);
        expect(h.out, isEmpty, reason: 'a finished fragment, held anyway');
        async.elapse(const Duration(milliseconds: 1501));
        expect(h.texts, ['Turn it off now.']);
      });
    });

    test('the policy sees the newest fragment only, normalised', () {
      final seen = <String>[];
      fakeAsync((async) {
        _Harness(
          async,
          isUnfinished: (f) {
            seen.add(f);
            return false;
          },
        ).replay([(0, _eot, '  one   two '), (100, _eot, 'three')]);
      });
      expect(seen, ['one two', 'three']);
    });
  });
}

class _Harness {
  _Harness(
    this.async, {
    Duration? mergeWindow,
    bool Function(String)? isUnfinished,
  }) : _origin = async.elapsed {
    final epoch = DateTime.utc(2026, 10, 17);
    assembler = TurnAssembler(
      onUtterance: out.add,
      onPendingChanged: pending.add,
      onSegmentFlushed: () => segmentsFlushed++,
      now: () => epoch.add(async.elapsed - _origin),
      mergeWindow: mergeWindow ?? const Duration(milliseconds: 1500),
      isUnfinished: isUnfinished ?? isUnfinishedFragment,
    );
  }

  /// [TurnAssembler.onSegmentFlushed] calls.
  int segmentsFlushed = 0;

  final FakeAsync async;
  final Duration _origin;
  late final TurnAssembler assembler;
  final out = <VoiceUtterance>[];
  final pending = <String>[];

  List<String> get texts => out.map((u) => u.text).toList();

  /// Feeds [events] at their times (ms since this harness was made).
  void replay(List<_Ev> events) {
    for (final (t, kind, text) in events) {
      final at = _origin + Duration(milliseconds: t);
      if (at > async.elapsed) async.elapse(at - async.elapsed);
      switch (kind) {
        case _start:
          assembler.speechStart();
        case _end:
          assembler.speechEnd();
        case _partial:
          assembler.partial(text!);
        case _eot:
          assembler.endOfTurn(text!);
      }
    }
  }
}
