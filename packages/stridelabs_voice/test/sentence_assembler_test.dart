import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

/// Feeds every prefix of [text] as a cumulative partial, one character at a
/// time (the harshest streaming), then [text] as the final. Returns what was
/// spoken, in order.
List<String> _streamByChar(String text, {SentenceAssembler? assembler}) {
  final a = assembler ?? SentenceAssembler();
  final out = <String>[];
  for (var i = 1; i <= text.length; i++) {
    out.addAll(a.assistantPartial(text.substring(0, i)));
  }
  out.addAll(a.assistantFinal(text));
  return out;
}

void main() {
  group('cumulative partials', () {
    test('a sentence is emitted once its boundary is certain', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('Hel'), isEmpty);
      expect(
        a.assistantPartial('Hello there.'),
        isEmpty,
        reason: 'the period may still be a decimal or an abbreviation',
      );
      expect(a.assistantPartial('Hello there. How'), ['Hello there.']);
      expect(a.assistantPartial('Hello there. How are you?'), isEmpty);
      expect(a.assistantPartial('Hello there. How are you? I'), [
        'How are you?',
      ]);
      expect(a.assistantFinal('Hello there. How are you? I am fine.'), [
        'I am fine.',
      ]);
    });

    test('each sentence is spoken exactly once', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('One. Two'), ['One.']);
      expect(a.assistantPartial('One. Two'), isEmpty);
      expect(a.assistantPartial('One. Two. '), ['Two.']);
      expect(a.assistantFinal('One. Two. '), isEmpty);
    });

    test('char-by-char streaming speaks the same as the final alone', () {
      const reply =
          'Surly is open until 10 p.m. tonight! Want directions? '
          'It is about 3.5 miles away.';
      final streamed = _streamByChar(reply);
      expect(streamed, SentenceAssembler().assistantFinal(reply));
      expect(streamed, [
        'Surly is open until 10 p.m. tonight!',
        'Want directions?',
        'It is about 3.5 miles away.',
      ]);
    });

    test('a line break ends a chunk (list items without punctuation)', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('Here are two:\n- Surly\n- Fair'), [
        'Here are two:',
        'Surly',
      ]);
      expect(a.assistantFinal('Here are two:\n- Surly\n- Fair State'), [
        'Fair State',
      ]);
    });
  });

  group('tool rounds and the final', () {
    test('a partial not starting with the spoken prefix is a new response', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('Sure. Let me check the'), ['Sure.']);
      expect(a.assistantPartial('Sure. Let me check the weather.'), isEmpty);
      // A tool ran; the next model response streams from scratch. The
      // previous response's unspoken tail is a complete sentence, so it is
      // spoken; the cursor restarts.
      expect(a.assistantPartial("It's"), ['Let me check the weather.']);
      expect(a.assistantPartial("It's 72 and sunny. Enjoy"), [
        "It's 72 and sunny.",
      ]);
      expect(a.assistantFinal("It's 72 and sunny. Enjoy!"), ['Enjoy!']);
    });

    test("a new response drops the previous one's unfinished tail", () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('Sure. Let me check the'), ['Sure.']);
      expect(a.assistantPartial('It is sunny. '), ['It is sunny.']);
      expect(a.assistantFinal('It is sunny. '), isEmpty);
    });

    test(
      'a revision past the spoken prefix replaces only the unspoken part',
      () {
        final a = SentenceAssembler();
        expect(a.assistantPartial('Sure. Let me check th'), ['Sure.']);
        // Starts with the spoken "Sure.": the same response, revised.
        expect(a.assistantPartial('Sure. Let me look'), isEmpty);
        expect(a.assistantPartial('Sure. Let me look. Done'), ['Let me look.']);
        expect(a.assistantFinal('Sure. Let me look. Done.'), ['Done.']);
      },
    );

    test('with nothing spoken yet, a changed partial is a revision', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('Let me ch'), isEmpty);
      expect(a.assistantPartial('Here you go. '), ['Here you go.']);
      expect(a.assistantFinal('Here you go. '), isEmpty);
    });

    test('the final emits only the unspoken remainder', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('One. Two. Thr'), ['One.', 'Two.']);
      expect(a.spokenPrefix, 'One. Two.');
      expect(a.assistantFinal('One. Two. Three.'), ['Three.']);
    });

    test('a final with no partials (an action reply) is spoken whole', () {
      expect(
        SentenceAssembler().assistantFinal('Regenerated. Here is another.'),
        ['Regenerated.', 'Here is another.'],
      );
    });

    test('a final differing only in leading whitespace is not re-spoken', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial(' Hi there. How'), ['Hi there.']);
      expect(a.assistantFinal('Hi there. How are you?'), ['How are you?']);
    });

    test('a final that does not continue the spoken prefix: tail dropped', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('Checking the forecast. One'), [
        'Checking the forecast.',
      ]);
      // The unspoken "One" is obsolete; the final is spoken whole.
      expect(a.assistantFinal('Seattle has rain all week.'), [
        'Seattle has rain all week.',
      ]);
    });

    test('such a final skips what was already said this turn', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('Checking the forecast. Hold'), [
        'Checking the forecast.',
      ]);
      expect(
        a.assistantFinal(
          'Checking the forecast! Seattle is sunny. Checking '
          'the forecast. Enjoy.',
        ),
        ['Checking the forecast!', 'Seattle is sunny.', 'Enjoy.'],
        reason: 'only the exact sentence already spoken is skipped, once',
      );
    });

    test('responseBoundary: with nothing spoken yet, the complete preamble is '
        'spoken and the next response starts fresh', () {
      final a = SentenceAssembler();
      // "Let me check." is complete but undecided (the period may yet be
      // followed by more of the same sentence), so nothing is spoken.
      expect(a.assistantPartial('Let me check.'), isEmpty);
      // Without the boundary this partial would look like a revision and
      // the preamble would never be heard (see the test above).
      expect(a.responseBoundary(), ['Let me check.']);
      expect(a.spokenPrefix, '');
      expect(a.assistantPartial('It is sunny today. Rain'), [
        'It is sunny today.',
      ]);
      expect(a.assistantFinal('It is sunny today. Rain comes later.'), [
        'Rain comes later.',
      ]);
    });

    test('responseBoundary drops an unfinished tail', () {
      final a = SentenceAssembler();
      expect(a.assistantPartial('Sure. Let me ch'), ['Sure.']);
      expect(a.responseBoundary(), isEmpty);
      expect(a.assistantPartial('It is sunny. '), ['It is sunny.']);
      // A second card of the same round is a no-op.
      expect(a.responseBoundary(), isEmpty);
      expect(a.responseBoundary(), isEmpty);
    });

    test('after a boundary, a final with no partials is the new response', () {
      final a = SentenceAssembler();
      a.assistantPartial('Checking the forecast.');
      expect(a.responseBoundary(), ['Checking the forecast.']);
      // The final carries the last model response only.
      expect(a.assistantFinal('Seattle is sunny.'), ['Seattle is sunny.']);
    });

    test('reset forgets the turn', () {
      final a = SentenceAssembler();
      a.assistantPartial('Old reply. Half');
      a.reset();
      expect(a.spokenPrefix, '');
      expect(a.assistantFinal('New reply.'), ['New reply.']);
    });
  });

  group('cleaning for speech', () {
    final table = <String, (String, List<String>)>{
      'emphasis': (
        '**Heavy Rotation** is _really_ good. *Try* the tripel.',
        ['Heavy Rotation is really good.', 'Try the tripel.'],
      ),
      'headers and list markers at line start': (
        '## Taproom hours\n- Mon: closed\n* Tue: 3-10\n1. Wed: noon.\n2) Thu.',
        ['Taproom hours', 'Mon: closed', 'Tue: 3-10', 'Wed: noon.', 'Thu.'],
      ),
      'a fenced code block is skipped': (
        'Run this:\n```bash\necho "a. b. c."\n```\nThen restart.',
        ['Run this:', 'Then restart.'],
      ),
      'an unclosed fence skips to the end': (
        'Code:\n```\nx = 1. y = 2.\n',
        ['Code:'],
      ),
      'URLs read as "link"': (
        'See https://example.com/a.b?c=d. Or www.surly.com for more.',
        ['See link.', 'Or link for more.'],
      ),
      'bare domains read as "link"': (
        'The menu is at example.com/menu. Book via brewery.co today. '
            'Try Fair-State.coop.io/taps or SURLY.COM.',
        ['The menu is at link.', 'Book via link today.', 'Try link or link.'],
      ),
      'things that only look like domains are kept': (
        'It is 3.5 miles, e.g. past Dr. Smith in St. Paul. A brewery.company '
            'is not a link.',
        [
          'It is 3.5 miles, e.g. past Dr. Smith in St. Paul.',
          'A brewery.company is not a link.',
        ],
      ),
      'a markdown link reads as its text': (
        'Book at [Fair State](https://fairstate.coop/book). Done.',
        ['Book at Fair State.', 'Done.'],
      ),
      'a chunk with nothing to say is dropped': (
        'First.\n---\n***\nLast.',
        ['First.', 'Last.'],
      ),
      'snake_case survives': (
        'Set the file_name field.',
        ['Set the file_name field.'],
      ),
    };
    for (final MapEntry(key: name, value: (text, expected)) in table.entries) {
      test(name, () {
        expect(SentenceAssembler().assistantFinal(text), expected);
        expect(_streamByChar(text), expected, reason: 'streamed char by char');
      });
    }
  });

  group('boundaries that are not sentence ends', () {
    final table = <String, (String, List<String>)>{
      'decimals': (
        'It is 3.5 degrees. Gusts to 12.75 mph.',
        ['It is 3.5 degrees.', 'Gusts to 12.75 mph.'],
      ),
      'abbreviations': (
        'Dr. Smith and Mr. and Mrs. Jones live on Main St. downtown. '
            'Bring snacks, e.g. pretzels, i.e. salty ones, vs. sweet etc. '
            'Thanks.',
        [
          'Dr. Smith and Mr. and Mrs. Jones live on Main St. downtown.',
          'Bring snacks, e.g. pretzels, i.e. salty ones, vs. sweet etc. '
              'Thanks.',
        ],
      ),
      'list numbers': (
        'Top picks:\n1. Surly Furious.\n2. Fair State Roselle.\n',
        ['Top picks:', 'Surly Furious.', 'Fair State Roselle.'],
      ),
      'a number ending a mid-line sentence still ends it': (
        'I counted 3. Then 4.',
        ['I counted 3.', 'Then 4.'],
      ),
      'question and exclamation runs': (
        'Really?! Yes... Okay.',
        ['Really?!', 'Yes...', 'Okay.'],
      ),
      'a closing quote after the period': (
        'He said "go." Then left.',
        ['He said "go."', 'Then left.'],
      ),
    };
    for (final MapEntry(key: name, value: (text, expected)) in table.entries) {
      test(name, () {
        expect(SentenceAssembler().assistantFinal(text), expected);
        expect(_streamByChar(text), expected, reason: 'streamed char by char');
      });
    }
  });

  group('chunks longer than 600 characters', () {
    test('split at the last clause boundary inside the window', () {
      final clause = '${List.filled(40, 'word').join(' ')}, ';
      final text = '${List.filled(4, clause).join()}end.';
      expect(text.length, greaterThan(kTtsMinTextChars));
      final out = SentenceAssembler().assistantFinal(text);
      expect(out.length, greaterThan(1));
      for (final chunk in out) {
        expect(chunk.length, lessThanOrEqualTo(kTtsMinTextChars));
      }
      expect(out.first, endsWith(','));
      expect(out.join(' '), text.replaceAll(RegExp(r'\s+'), ' ').trim());
    });

    test('with no clause boundary, split at a space', () {
      final text = '${List.filled(150, 'word').join(' ')}.';
      final out = SentenceAssembler().assistantFinal(text);
      expect(out, hasLength(2));
      expect(out[0].length, lessThanOrEqualTo(kTtsMinTextChars));
      expect(out.join(' '), text);
    });

    test('with no space at all, a hard cut', () {
      final text = 'a' * 1300;
      final out = SentenceAssembler().assistantFinal(text);
      expect(out.map((c) => c.length), [600, 600, 100]);
    });
  });

  group('maxSpokenChunk', () {
    // One 1000-character sentence of 200 five-letter words.
    final long = '${List.filled(200, 'word').join(' ')}.';

    test('starts at the protocol minimum, 600', () {
      expect(SentenceAssembler().maxSpokenChunk, kTtsMinTextChars);
      expect(kTtsMinTextChars, 600);
    });

    test('a smaller bound from the constructor cuts shorter chunks', () {
      final out = SentenceAssembler(maxSpokenChunk: 100).assistantFinal(long);
      expect(out.length, greaterThan(5));
      expect(out.every((c) => c.length <= 100), isTrue);
      expect(out.join(' '), long);
    });

    test('a larger bound keeps what 600 would have split', () {
      expect(long.length, greaterThan(kTtsMinTextChars));
      expect(SentenceAssembler().assistantFinal(long).length, greaterThan(1));
      final a = SentenceAssembler(maxSpokenChunk: 1200);
      expect(a.assistantFinal(long), [long]);
    });

    test(
      'raised after a response advertised more, it applies from then on',
      () {
        final a = SentenceAssembler();
        expect(a.assistantFinal(long).length, greaterThan(1));
        a.reset();
        a.maxSpokenChunk = 1200;
        expect(a.maxSpokenChunk, 1200);
        expect(a.assistantFinal(long), [long]);
        a.reset();
        a.maxSpokenChunk = kTtsMinTextChars;
        expect(a.assistantFinal(long).length, greaterThan(1));
      },
    );

    test('streaming under a raised bound still speaks the sentence whole', () {
      final a = SentenceAssembler(maxSpokenChunk: 1200);
      expect(_streamByChar(long, assembler: a), [long]);
    });

    test('splitSpokenChunk is the split the assembler makes, public', () {
      for (final bound in [100, 600, 999]) {
        expect(
          splitSpokenChunk(long, bound),
          SentenceAssembler(maxSpokenChunk: bound).assistantFinal(long),
          reason: '$bound',
        );
      }
      expect(splitSpokenChunk(long, 1000), [long], reason: 'within it');
      expect(splitSpokenChunk('', 600), isEmpty);
      expect(
        () => splitSpokenChunk(long, 0),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'maxChars')),
      );
    });

    test('splitSpokenChunk never cuts a surrogate pair, even under a bound '
        'of 1', () {
      // Two emoji (two code units each) with no space: hard cuts only.
      expect(splitSpokenChunk('\u{1F600}\u{1F601}', 1), [
        '\u{1F600}',
        '\u{1F601}',
      ]);
      expect(splitSpokenChunk('a\u{1F600}b', 2), ['a', '\u{1F600}', 'b']);
    });

    test('a bound under 1 is refused, by the constructor and the setter', () {
      expect(
        () => SentenceAssembler(maxSpokenChunk: 0),
        throwsA(isA<ArgumentError>()),
      );
      final a = SentenceAssembler();
      expect(() => a.maxSpokenChunk = -5, throwsA(isA<ArgumentError>()));
      expect(a.maxSpokenChunk, kTtsMinTextChars, reason: 'left as it was');
    });
  });
}
