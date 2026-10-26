// The default-browser lookup behind LoopbackWebAuth's Linux browser check:
// `gio mime`, else `xdg-mime`, each bounded, never the network. What each
// tool's output means, the fallbacks (a tool missing, a timeout, an answer
// that cannot be read), and the check's rule: only a definite "no default"
// stops the launch.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/src/default_browser.dart';

/// `gio mime x-scheme-handler/https` in the C locale, with a default.
const _gioFound =
    'Default application for ?x-scheme-handler/https?: firefox.desktop\n'
    'Registered applications:\n'
    '\tfirefox.desktop\n'
    'Recommended applications:\n'
    '\tfirefox.desktop\n';

/// The same with no default (a desktop with no browser installed).
const _gioNone = 'No default applications for ?x-scheme-handler/https?\n';

/// A scripted [ToolRunner]: answers per executable, records every call.
class _Tools {
  _Tools(this.answers);

  final Map<String, ToolRun> answers;
  final List<({String executable, List<String> arguments, Duration timeout})>
  calls = [];

  Future<ToolRun> run(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    calls.add((executable: executable, arguments: arguments, timeout: timeout));
    return answers[executable] ?? const ToolMissing();
  }

  List<String> get ran => [for (final c in calls) c.executable];
}

void main() {
  group('parsing', () {
    test('gio: the default application, in the C locale and in UTF-8', () {
      expect(
        parseGioMime(_gioFound),
        isA<DefaultBrowserFound>().having(
          (f) => f.desktopEntry,
          'desktopEntry',
          'firefox.desktop',
        ),
      );
      expect(
        parseGioMime(
          'Default application for “x-scheme-handler/http”: '
          'fake-browser.desktop\nNo registered applications\n',
        ),
        isA<DefaultBrowserFound>().having(
          (f) => f.desktopEntry,
          'desktopEntry',
          'fake-browser.desktop',
        ),
      );
    });

    test('gio: none, and anything else unread (null)', () {
      expect(parseGioMime(_gioNone), isA<NoDefaultBrowser>());
      expect(parseGioMime(''), isNull);
      expect(parseGioMime('Standardanwendung für …: x.desktop\n'), isNull);
      expect(
        parseGioMime('Default application for ?x?: not-a-desktop-entry\n'),
        isNull,
      );
    });

    test('xdg-mime: the entry it prints, none when empty, else unknown', () {
      expect(
        parseXdgMimeDefault('firefox.desktop\n'),
        isA<DefaultBrowserFound>().having(
          (f) => f.desktopEntry,
          'desktopEntry',
          'firefox.desktop',
        ),
      );
      expect(parseXdgMimeDefault('\n'), isA<NoDefaultBrowser>());
      expect(parseXdgMimeDefault(''), isA<NoDefaultBrowser>());
      expect(
        parseXdgMimeDefault('a.desktop\nb.desktop\n'),
        isA<DefaultBrowserUnknown>(),
      );
      expect(parseXdgMimeDefault('oops'), isA<DefaultBrowserUnknown>());
    });
  });

  group('lookUpDefaultBrowser', () {
    test(
      'asks gio about the scheme, bounded, and stops at its answer',
      () async {
        final tools = _Tools({'gio': const ToolFinished(0, _gioFound)});
        final found = await lookUpDefaultBrowser('https', run: tools.run);
        expect(found, isA<DefaultBrowserFound>());
        expect(tools.calls.single.arguments, [
          'mime',
          'x-scheme-handler/https',
        ]);
        expect(tools.calls.single.timeout, defaultBrowserLookupTimeout);
        expect(defaultBrowserLookupTimeout, const Duration(seconds: 2));

        final none = _Tools({'gio': const ToolFinished(0, _gioNone)});
        expect(
          await lookUpDefaultBrowser('http', run: none.run),
          isA<NoDefaultBrowser>(),
        );
        expect(none.calls.single.arguments, ['mime', 'x-scheme-handler/http']);
      },
    );

    test('gio missing: xdg-mime answers', () async {
      final found = _Tools({
        'xdg-mime': const ToolFinished(0, 'firefox.desktop\n'),
      });
      expect(
        await lookUpDefaultBrowser('https', run: found.run),
        isA<DefaultBrowserFound>(),
      );
      expect(found.ran, ['gio', 'xdg-mime']);
      expect(found.calls.last.arguments, [
        'query',
        'default',
        'x-scheme-handler/https',
      ]);

      final none = _Tools({'xdg-mime': const ToolFinished(0, '\n')});
      expect(
        await lookUpDefaultBrowser('https', run: none.run),
        isA<NoDefaultBrowser>(),
      );
    });

    test('gio unreadable or failing: xdg-mime answers', () async {
      for (final gio in const [
        ToolFinished(0, 'Keine Standardanwendung\n'),
        ToolFinished(1, ''),
      ]) {
        final tools = _Tools({
          'gio': gio,
          'xdg-mime': const ToolFinished(0, ''),
        });
        expect(
          await lookUpDefaultBrowser('https', run: tools.run),
          isA<NoDefaultBrowser>(),
        );
        expect(tools.ran, ['gio', 'xdg-mime']);
      }
    });

    test(
      'no answer is "unknown": neither tool, a timeout, a failure',
      () async {
        final neither = _Tools({});
        expect(
          await lookUpDefaultBrowser('https', run: neither.run),
          isA<DefaultBrowserUnknown>(),
        );
        expect(neither.ran, ['gio', 'xdg-mime']);

        // A gio that times out ends the lookup: the desktop is not answering.
        final gioSlow = _Tools({
          'gio': const ToolTimedOut(),
          'xdg-mime': const ToolFinished(0, ''),
        });
        expect(
          await lookUpDefaultBrowser('https', run: gioSlow.run),
          isA<DefaultBrowserUnknown>(),
        );
        expect(gioSlow.ran, ['gio']);

        final xdgSlow = _Tools({'xdg-mime': const ToolTimedOut()});
        expect(
          await lookUpDefaultBrowser('https', run: xdgSlow.run),
          isA<DefaultBrowserUnknown>(),
        );

        final xdgFails = _Tools({'xdg-mime': const ToolFinished(3, '')});
        expect(
          await lookUpDefaultBrowser('https', run: xdgFails.run),
          isA<DefaultBrowserUnknown>(),
        );
      },
    );
  });

  group("the launcher's rule (linuxDefaultBrowserCheck)", () {
    final url = Uri.parse('https://auth.example.test/oauth2/authorize');

    test('only a definite "no default" stops the launch', () async {
      Future<bool> mayOpen(Map<String, ToolRun> answers) =>
          linuxDefaultBrowserCheck(url, run: _Tools(answers).run);

      expect(await mayOpen({'gio': const ToolFinished(0, _gioNone)}), isFalse);
      expect(await mayOpen({'gio': const ToolFinished(0, _gioFound)}), isTrue);
      // Cannot tell: launch as before.
      expect(await mayOpen({}), isTrue);
      expect(await mayOpen({'gio': const ToolTimedOut()}), isTrue);
    });

    test("asks about the URL's own scheme", () async {
      final tools = _Tools({'gio': const ToolFinished(0, _gioFound)});
      await linuxDefaultBrowserCheck(
        Uri.parse('http://127.0.0.1:1/fake/oauth2/authorize'),
        run: tools.run,
      );
      expect(tools.calls.single.arguments.last, 'x-scheme-handler/http');
    });
  });

  group('runTool (real processes)', () {
    final posix = Platform.isLinux || Platform.isMacOS;

    test('a missing tool', () async {
      expect(
        await runTool(
          'slauth-no-such-tool-${pid}x',
          const [],
          const Duration(seconds: 2),
        ),
        isA<ToolMissing>(),
      );
    });

    test(
      'a tool that answers: its exit code and stdout',
      () async {
        final run = await runTool('sh', const [
          '-c',
          'echo "\$LC_ALL"; exit 3',
        ], const Duration(seconds: 5));
        expect(
          run,
          isA<ToolFinished>()
              .having((r) => r.exitCode, 'exitCode', 3)
              .having((r) => r.stdout, 'stdout', 'C\n'),
        );
      },
      skip: posix ? false : 'POSIX only',
    );

    test(
      'a tool that hangs: timed out within the bound, and killed',
      () async {
        final watch = Stopwatch()..start();
        final run = await runTool('sleep', const [
          '30',
        ], const Duration(milliseconds: 300));
        expect(run, isA<ToolTimedOut>());
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      },
      skip: posix ? false : 'POSIX only',
    );
  });
}
