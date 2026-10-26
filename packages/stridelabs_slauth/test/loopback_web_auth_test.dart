// LoopbackWebAuth: the loopback redirect, its typed failures, cancel/reopen
// and the single-winner races.
//
// Real loopback sockets: every test picks its own ephemeral port (bind 0,
// read it, close it, then configure the redirect with it), and
// the launcher is a fake. Attempt deadlines are fakes the test fires by hand
// (the deadline seam), so no race depends on scheduling; only the one test
// about the real timer uses one. "Port released" is always asserted by binding the
// port again after the terminal outcome. Requests are written by hand on raw
// sockets (no HttpClient: flutter_test's binding replaces it once a
// testWidgets has run, and raw sockets also let a test spoof headers, send an
// absolute-form target or hold a connection mid-request).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/src/default_browser.dart'
    show ToolRun, ToolTimedOut;
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

/// How long a test waits for something that should happen promptly.
const _prompt = Duration(seconds: 10);

const _callbackPath = '/auth/callback';

/// The body length a held request declares and does not send.
const _declaredBody = 64;

void main() {
  group('accept', () {
    test('serves the landing page, then completes with the configured redirect '
        'plus the query, and releases the port', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);
      expect(h.launcher.launched, [_authorizeUrl('S1')]);

      final reply = await _send(
        h.port,
        _request(h.port, '$_callbackPath?code=C1&state=S1'),
      );

      expect(reply.status, HttpStatus.ok);
      expect(reply.headers['content-type'], 'text/html; charset=utf-8');
      expect(reply.headers['connection'], 'close');
      expect(reply.headers['cache-control'], 'no-store');
      expect(reply.body, defaultLandingPageHtml);
      expect(reply.body, isNot(contains('C1')));
      expect(reply.body, isNot(contains('S1')));

      final outcome = await pending.outcome;
      expect(outcome.uri, h.redirectWith('code=C1&state=S1'));
      await _expectPortFree(h.port);
    });

    test("serves the app's own landing page when it passes one", () async {
      const page = '<!doctype html><title>My App</title><p>Back to My App.</p>';
      final h = await _Harness.start(landingPageHtml: page);
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      final reply = await _send(
        h.port,
        _request(h.port, '$_callbackPath?code=C1&state=S1'),
      );

      expect(reply.status, HttpStatus.ok);
      expect(reply.headers['content-type'], 'text/html; charset=utf-8');
      expect(reply.headers['content-length'], '${utf8.encode(page).length}');
      expect(reply.body, page);
      expect(h.auth.landingPageHtml, page);
      expect((await pending.outcome).uri, h.redirectWith('code=C1&state=S1'));
      await _expectPortFree(h.port);
    });

    test('accepts an error callback with the right state (the screen maps '
        'it)', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      await h.expectAccepts(pending, 'error=access_denied&state=S1');
    });

    test('ignores every other request with a 404 and keeps listening, then '
        'accepts the valid callback', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      final strays = <String, String>{
        'a request before the valid one (favicon)': _request(
          h.port,
          '/favicon.ico',
        ),
        'wrong path': _request(h.port, '/other?code=C&state=S1'),
        'trailing slash': _request(h.port, '$_callbackPath/?code=C&state=S1'),
        'path prefix': _request(h.port, '/auth?code=C&state=S1'),
        'wrong state': _request(h.port, '$_callbackPath?code=C&state=S2'),
        'missing state': _request(h.port, '$_callbackPath?code=C'),
        'empty state': _request(h.port, '$_callbackPath?code=C&state='),
        'repeated state (equal)': _request(
          h.port,
          '$_callbackPath?code=C&state=S1&state=S1',
        ),
        'repeated state (different)': _request(
          h.port,
          '$_callbackPath?code=C&state=S1&state=S2',
        ),
        'POST': _request(
          h.port,
          '$_callbackPath?code=C&state=S1',
          method: 'POST',
        ),
        'PUT': _request(
          h.port,
          '$_callbackPath?code=C&state=S1',
          method: 'PUT',
        ),
        'HEAD': _request(
          h.port,
          '$_callbackPath?code=C&state=S1',
          method: 'HEAD',
        ),
        'absolute-form target': _request(
          h.port,
          'http://127.0.0.1:${h.port}$_callbackPath?code=C&state=S1',
        ),
        'network-path target': _request(
          h.port,
          '//evil.example$_callbackPath?code=C&state=S1',
        ),
      };
      for (final MapEntry(key: name, value: request) in strays.entries) {
        final reply = await _send(h.port, request);
        expect(reply.status, HttpStatus.notFound, reason: name);
        expect(pending.settled, isFalse, reason: name);
      }

      await h.expectAccepts(pending, 'code=C1&state=S1');
    });

    test('a query that does not decode as UTF-8 gets a 400, a garbage request '
        'is dropped, and the server keeps listening', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      // %ff is well-formed escape syntax whose bytes are not UTF-8: decoding
      // the query throws inside the handler. (Malformed escape syntax never
      // gets this far: Dart's parser repairs it, see the pinning test.)
      for (final target in [
        '$_callbackPath?code=C&state=%ff',
        '$_callbackPath?code=%ff&state=S1',
        '$_callbackPath?%c3%28=1&state=S1',
      ]) {
        final reply = await _send(h.port, _request(h.port, target));
        expect(reply.status, HttpStatus.badRequest, reason: target);
      }
      // Dart's own parser rejects these before the handler sees them.
      for (final garbage in [
        'GARBAGE\r\n\r\n',
        'GET /a b c HTTP/1.1\r\n\r\n',
        'GET $_callbackPath?state=S1 HTTP/1.1\r\nBad Header\r\n\r\n',
      ]) {
        final reply = await _send(h.port, garbage);
        expect(reply.status, isNot(HttpStatus.ok), reason: garbage);
      }
      expect(pending.settled, isFalse);

      await h.expectAccepts(pending, 'code=C1&state=S1');
    });

    test('Host, X-Forwarded-* and Forwarded spoofing do not change the '
        'result', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      final reply = await _send(
        h.port,
        _request(
          h.port,
          '$_callbackPath?code=C1&state=S1',
          headers: {
            'Host': 'evil.example:4443',
            'X-Forwarded-Host': 'evil2.example',
            'X-Forwarded-Proto': 'https',
            'X-Forwarded-Port': '443',
            'Forwarded': 'host=evil3.example;proto=https',
          },
        ),
      );

      expect(reply.status, HttpStatus.ok);
      final uri = (await pending.outcome).uri!;
      expect(uri, h.redirectWith('code=C1&state=S1'));
      expect(uri.scheme, 'http');
      expect(uri.host, '127.0.0.1');
      expect(uri.port, h.port);
      await _expectPortFree(h.port);
    });

    test('refuses a target with a fragment (404, keeps listening): the parser '
        'would silently truncate it', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      for (final target in [
        '$_callbackPath?state=S1&code=C#&code=D',
        '$_callbackPath?code=C&state=S1#',
        '$_callbackPath?code=C&state=S1#fragment',
        '$_callbackPath#?code=C&state=S1',
      ]) {
        final reply = await _send(h.port, _request(h.port, target));
        expect(reply.status, HttpStatus.notFound, reason: target);
        expect(pending.settled, isFalse, reason: target);
      }

      await h.expectAccepts(pending, 'code=C1&state=S1');
    });

    test("pins dart:io's request-target normalisation: malformed escapes are "
        'relayed repaired, dot segments are removed', () async {
      // Dart's parser builds request.uri with Uri.parse before the handler
      // sees it, and there is no raw target to check instead. Acceptance
      // still needs the exact state; this pins what is relayed, so an SDK
      // change shows up here.
      final h = await _Harness.start();
      final cases = <String, (String, String)>{
        // request target: (expected path, expected query)
        '$_callbackPath?state=S0&code=%zz': (
          _callbackPath,
          'state=S0&code=%25zz',
        ),
        '$_callbackPath?state=S1&code=%': (_callbackPath, 'state=S1&code=%25'),
        '/other/..$_callbackPath?code=C&state=S2': (
          _callbackPath,
          'code=C&state=S2',
        ),
        '/auth/%2e/callback?code=C&state=S3': (
          _callbackPath,
          'code=C&state=S3',
        ),
      };
      for (final (i, MapEntry(key: target, value: (path, query)))
          in cases.entries.indexed) {
        final pending = h.authenticate('S$i');
        await h.launcher.waitFor(i + 1);

        final reply = await _send(h.port, _request(h.port, target));

        expect(reply.status, HttpStatus.ok, reason: target);
        final uri = (await pending.outcome).uri!;
        expect(uri.path, path, reason: target);
        expect(uri.query, query, reason: target);
        expect(uri.origin, 'http://127.0.0.1:${h.port}', reason: target);
        await _expectPortFree(h.port);
      }
    });

    test("relays duplicate or mixed code/error parameters unchanged, for the "
        "screen's validator to reject", () async {
      final h = await _Harness.start();
      final queries = [
        'state=S0&code=A&code=B',
        'state=S1&code=A&error=access_denied',
        'state=S2&error=a&error=b',
      ];
      for (final (i, query) in queries.indexed) {
        final pending = h.authenticate('S$i');
        await h.launcher.waitFor(i + 1);

        final reply = await _send(
          h.port,
          _request(h.port, '$_callbackPath?$query'),
        );

        expect(reply.status, HttpStatus.ok, reason: query);
        expect((await pending.outcome).uri!.query, query);
        await _expectPortFree(h.port);
      }
    });

    test('a favicon request after the accept is refused and the result is '
        'unchanged', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);
      await _send(h.port, _request(h.port, '$_callbackPath?code=C1&state=S1'));
      final first = await pending.outcome;

      final favicon = await _send(h.port, _request(h.port, '/favicon.ico'));

      expect(favicon.refused, isTrue);
      expect(first.uri, h.redirectWith('code=C1&state=S1'));
      expect((await pending.outcome).uri, first.uri);
      await _expectPortFree(h.port);
    });

    test('a slow client gets the landing page for at most '
        '${LoopbackWebAuth.landingPageDeadline.inSeconds} s, then the sign-in '
        'completes anyway', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      // The landing page's write never finishes on its own.
      final held = await h.holdCallback('code=C1&state=S1');
      final clock = Stopwatch()..start();
      final outcome = await pending.outcome;

      expect(outcome.uri, h.redirectWith('code=C1&state=S1'));
      const bound = LoopbackWebAuth.landingPageDeadline;
      // The write really stalled (else this test would prove nothing) ...
      expect(
        clock.elapsed,
        greaterThanOrEqualTo(bound - const Duration(milliseconds: 200)),
      );
      // ... and the bound, not the client, ended it.
      expect(clock.elapsed, lessThan(bound + const Duration(seconds: 3)));
      await held.closed.timeout(_prompt);
      await _expectPortFree(h.port);
    });
  });

  group('typed failures', () {
    test('a launcher Launch Error ends the attempt with LoopbackNoBrowser and '
        'releases the port at once', () async {
      final h = await _Harness.start(
        respond: (_) async => throw PlatformException(
          code: 'Launch Error',
          message: 'Failed to launch URL: ${_authorizeUrl('S1')}',
        ),
      );

      final outcome = await h.authenticate('S1').outcome;

      final error = outcome.error;
      expect(error, isA<LoopbackNoBrowser>());
      error as LoopbackNoBrowser;
      expect(error.code, 'Launch Error');
      expect(error.hostPort, '127.0.0.1:${h.port}');
      // The launcher's message carried the authorize URL; the failure does
      // not.
      expect(error.toString(), isNot(contains('S1')));
      expect(error.toString(), isNot(contains('authorize')));
      await _expectPortFree(h.port);
    });

    test('a launcher that returns false is LoopbackNoBrowser too', () async {
      final h = await _Harness.start(respond: (_) async => false);

      final outcome = await h.authenticate('S1').outcome;

      expect(outcome.error, isA<LoopbackNoBrowser>());
      await _expectPortFree(h.port);
    });

    test('any other launcher error ends the attempt, releases the port and '
        'surfaces unchanged', () async {
      final boom = StateError('boom');
      final h = await _Harness.start(respond: (_) async => throw boom);

      final outcome = await h.authenticate('S1').outcome;

      expect(outcome.error, same(boom));
      await _expectPortFree(h.port);
    });

    test('a bind conflict inside this process is LoopbackPortBusy and nothing '
        'launches', () async {
      final h = await _Harness.start();
      final holder = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        h.port,
      );
      addTearDown(holder.close);

      final outcome = await h.authenticate('S1').outcome;

      final error = outcome.error;
      expect(error, isA<LoopbackPortBusy>());
      error as LoopbackPortBusy;
      expect(error.code, LoopbackPortBusy.errorCode);
      expect(error.hostPort, '127.0.0.1:${h.port}');
      // Dart's same-process refusal, not an OS errno.
      expect(error.socketException.osError?.errorCode, -1);
      expect(h.launcher.launched, isEmpty);
    });

    test('a bind conflict with another process (EADDRINUSE) is '
        'LoopbackPortBusy', () async {
      final h = await _Harness.start();
      final holder = await _OtherProcessHolder.bind(h.port);
      addTearDown(holder.stop);

      final outcome = await h.authenticate('S1').outcome;

      final error = outcome.error;
      expect(error, isA<LoopbackPortBusy>());
      error as LoopbackPortBusy;
      expect(error.hostPort, '127.0.0.1:${h.port}');
      // A real errno: EADDRINUSE (98 on Linux, 48 on macOS).
      expect(
        error.socketException.osError?.errorCode,
        Platform.isMacOS ? 48 : 98,
      );
      expect(h.launcher.launched, isEmpty);

      await holder.stop();
      await _expectPortFree(h.port);
    });

    test('a timeout is LoopbackTimeout (TIMEOUT, not CANCELED) and releases '
        'the port (the real timer)', () async {
      // Nothing competes with this deadline, so its length cannot make the
      // test flaky; it only proves the default Timer.new wiring.
      final h = await _Harness.start(
        realTimeout: const Duration(milliseconds: 200),
      );

      final outcome = await h.authenticate('S1').outcome;

      final error = outcome.error;
      expect(error, isA<LoopbackTimeout>());
      error as LoopbackTimeout;
      expect(error.code, 'TIMEOUT');
      expect(error.code, isNot(LoopbackWebAuth.canceledCode));
      expect(error.hostPort, '127.0.0.1:${h.port}');
      await _expectPortFree(h.port);
    });

    test('the deadline starts once listening, with the configured timeout '
        '(5 minutes by default)', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      expect(h.deadlines.started, hasLength(1));
      expect(h.deadlines.last.duration, const Duration(minutes: 5));
      expect(h.deadlines.last.cancelled, isFalse);

      await h.auth.cancel();
      await pending.outcome;
      expect(h.deadlines.last.cancelled, isTrue);
    });

    test('retry after a launch failure succeeds on the same port', () async {
      final h = await _Harness.start(
        respond: (call) async =>
            call == 1 ? throw PlatformException(code: 'Launch Error') : true,
      );
      expect(
        (await h.authenticate('S1').outcome).error,
        isA<LoopbackNoBrowser>(),
      );
      await _expectPortFree(h.port);

      final pending = h.authenticate('S2');
      await h.launcher.waitFor(2);
      await h.expectAccepts(pending, 'code=C2&state=S2');
    });
  });

  group('cancel, supersede, dispose', () {
    test('cancel fails the attempt with a plain CANCELED and releases the '
        'port', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      await h.auth.cancel();

      final error = (await pending.outcome).error;
      expect(error, isA<PlatformException>());
      expect((error as PlatformException).code, 'CANCELED');
      expect(error, isNot(isA<LoopbackAuthFailure>()));
      await _expectPortFree(h.port);
    });

    test('cancel during bind: the server closes at once and nothing '
        'launches', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      // authenticate is now awaiting bind.
      final cancelled = h.auth.cancel();

      await cancelled;
      expect(_codeOf((await pending.outcome).error), 'CANCELED');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.launcher.launched, isEmpty);
      await _expectPortFree(h.port);
    });

    test('cancel while the launch is still pending settles without waiting '
        'for the launcher; its late result changes nothing', () async {
      final launch = Completer<bool>();
      final h = await _Harness.start(respond: (_) => launch.future);
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      await h.auth.cancel().timeout(_prompt);
      expect(_codeOf((await pending.outcome).error), 'CANCELED');
      await _expectPortFree(h.port);

      launch.completeError(PlatformException(code: 'Launch Error'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(_codeOf((await pending.outcome).error), 'CANCELED');
    });

    test('cancel then an immediate retry succeeds on the same port', () async {
      final h = await _Harness.start();
      final first = h.authenticate('S1');
      await h.launcher.waitFor(1);

      unawaited(h.auth.cancel());
      final second = h.authenticate('S2');
      await h.launcher.waitFor(2);

      expect(_codeOf((await first.outcome).error), 'CANCELED');
      await h.expectAccepts(second, 'code=C2&state=S2');
    });

    test('a second authenticate cancels the first; a stale callback with the '
        'old state is ignored', () async {
      final h = await _Harness.start();
      final first = h.authenticate('S1');
      await h.launcher.waitFor(1);

      final second = h.authenticate('S2');
      expect(_codeOf((await first.outcome).error), 'CANCELED');
      await h.launcher.waitFor(2);
      expect(h.launcher.launched, [_authorizeUrl('S1'), _authorizeUrl('S2')]);

      final stale = await _send(
        h.port,
        _request(h.port, '$_callbackPath?code=C1&state=S1'),
      );
      expect(stale.status, HttpStatus.notFound);
      expect(second.settled, isFalse);

      await h.expectAccepts(second, 'code=C2&state=S2');
    });

    test('an attempt superseded during bind closes its server at once and '
        'never launches', () async {
      final h = await _Harness.start();
      final first = h.authenticate('S1');
      final second = h.authenticate('S2'); // the first is still binding

      expect(_codeOf((await first.outcome).error), 'CANCELED');
      await h.launcher.waitFor(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.launcher.launched, [_authorizeUrl('S2')]);

      await h.expectAccepts(second, 'code=C2&state=S2');
    });

    test('an attempt cancelled while waiting for the previous one to release '
        'never binds', () async {
      final h = await _Harness.start();
      final first = h.authenticate('S1');
      await h.launcher.waitFor(1);

      final second = h.authenticate('S2'); // waits for the first's release
      await h.auth.cancel();

      expect(_codeOf((await first.outcome).error), 'CANCELED');
      expect(_codeOf((await second.outcome).error), 'CANCELED');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.launcher.launched, [_authorizeUrl('S1')]);
      await _expectPortFree(h.port);
    });

    test('dispose cancels the pending attempt and refuses new ones', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      await h.auth.dispose();

      expect(_codeOf((await pending.outcome).error), 'CANCELED');
      await _expectPortFree(h.port);
      expect((await h.authenticate('S2').outcome).error, isA<StateError>());
      expect(h.launcher.launched, hasLength(1));
    });
  });

  // The browser check ("no default browser"): asked before each
  // launch. It can take up to its bound (a separate process), and an attempt
  // that ended meanwhile (Cancel, a newer attempt, dispose) must launch
  // nothing, whatever the check then says.
  group('the browser check', () {
    test('"no browser": LoopbackNoBrowser, nothing launched, the port '
        'released', () async {
      final h = await _Harness.start(browserCheck: (_) async => false);
      final outcome = await h.authenticate('S1').outcome;
      expect(outcome.error, isA<LoopbackNoBrowser>());
      expect(h.launcher.launched, isEmpty);
      await _expectPortFree(h.port);
    });

    test('"may open", or a check that fails, launches', () async {
      final yes = await _Harness.start(browserCheck: (_) async => true);
      final first = yes.authenticate('S1');
      await yes.launcher.waitFor(1);
      expect(yes.launcher.launched, [_authorizeUrl('S1')]);
      await yes.auth.cancel();
      await first.outcome;

      final failing = await _Harness.start(
        browserCheck: (_) async => throw StateError('lookup broke'),
      );
      final second = failing.authenticate('S2');
      await failing.launcher.waitFor(1);
      expect(failing.launcher.launched, [_authorizeUrl('S2')]);
      await failing.auth.cancel();
      await second.outcome;
    });

    test('Cancel while the check is pending: its later "may open" launches '
        'nothing', () async {
      final check = _HeldCheck();
      final h = await _Harness.start(browserCheck: check.call);
      final pending = h.authenticate('S1');
      await check.waitFor(1);

      await h.auth.cancel();
      expect(_codeOf((await pending.outcome).error), 'CANCELED');
      await _expectPortFree(h.port);

      check.answer(0, true);
      await _settle();
      expect(h.launcher.launched, isEmpty);
    });

    test('dispose while the check is pending: nothing launches', () async {
      final check = _HeldCheck();
      final h = await _Harness.start(browserCheck: check.call);
      final pending = h.authenticate('S1');
      await check.waitFor(1);

      await h.auth.dispose();
      expect(_codeOf((await pending.outcome).error), 'CANCELED');

      check.answer(0, true);
      await _settle();
      expect(h.launcher.launched, isEmpty);
    });

    test('superseded while the check is pending: only the newer attempt '
        'launches', () async {
      final check = _HeldCheck();
      final h = await _Harness.start(browserCheck: check.call);
      final first = h.authenticate('S1');
      await check.waitFor(1);

      final second = h.authenticate('S2');
      expect(_codeOf((await first.outcome).error), 'CANCELED');
      await check.waitFor(2);

      check.answer(0, true); // the superseded attempt's answer
      await _settle();
      expect(h.launcher.launched, isEmpty);

      check.answer(1, true);
      await h.launcher.waitFor(1);
      expect(h.launcher.launched, [_authorizeUrl('S2')]);
      await h.auth.cancel();
      await second.outcome;
    });

    test('the lookup timing out (launch anyway) after a Cancel launches '
        'nothing; without one it launches', () async {
      // The real check, linuxDefaultBrowserCheck, whose lookup times out: "cannot
      // tell", which launches as before.
      final held = Completer<void>();
      var asked = 0;
      Future<ToolRun> slowTools(String _, List<String> _, Duration _) async {
        asked++;
        await held.future;
        return const ToolTimedOut();
      }

      final h = await _Harness.start(
        browserCheck: (url) => linuxDefaultBrowserCheck(url, run: slowTools),
      );
      final cancelled = h.authenticate('S1');
      await _until(() => asked == 1);
      await h.auth.cancel();
      expect(_codeOf((await cancelled.outcome).error), 'CANCELED');
      held.complete();
      await _settle();
      expect(h.launcher.launched, isEmpty);

      // The same fallback for a live attempt does launch.
      final live = h.authenticate('S2');
      await h.launcher.waitFor(1);
      expect(h.launcher.launched, [_authorizeUrl('S2')]);
      await h.auth.cancel();
      await live.outcome;
    });

    test('reopen whose check is pending, then Cancel: nothing launches and '
        'reopen reports false', () async {
      final check = _HeldCheck();
      final h = await _Harness.start(browserCheck: check.call);
      final pending = h.authenticate('S1');
      await check.waitFor(1);
      check.answer(0, true);
      await h.launcher.waitFor(1);

      final reopened = h.auth.reopen();
      await check.waitFor(2);
      await h.auth.cancel();
      check.answer(1, true);
      expect(await reopened, isFalse);
      await _settle();
      expect(h.launcher.launched, hasLength(1));
      expect(_codeOf((await pending.outcome).error), 'CANCELED');
    });
  });

  group('reopen', () {
    test('relaunches the same authorize URL and keeps listening', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      expect(await h.auth.reopen(), isTrue);

      expect(h.launcher.launched, [_authorizeUrl('S1'), _authorizeUrl('S1')]);
      expect(pending.settled, isFalse);
      await h.expectAccepts(pending, 'code=C1&state=S1');
    });

    test('a reopen failure throws LoopbackNoBrowser and keeps the attempt '
        'alive, then a callback still succeeds', () async {
      final h = await _Harness.start(
        respond: (call) async => switch (call) {
          2 => throw PlatformException(code: 'Launch Error'),
          3 => false,
          _ => true,
        },
      );
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      await expectLater(h.auth.reopen(), throwsA(isA<LoopbackNoBrowser>()));
      await expectLater(h.auth.reopen(), throwsA(isA<LoopbackNoBrowser>()));

      expect(pending.settled, isFalse);
      final stray = await _send(h.port, _request(h.port, '/favicon.ico'));
      expect(stray.status, HttpStatus.notFound);
      await h.expectAccepts(pending, 'code=C1&state=S1');
    });

    test('returns false and launches nothing with no attempt, or after '
        'cancel, timeout or accept', () async {
      final h = await _Harness.start();
      expect(await h.auth.reopen(), isFalse);
      expect(h.launcher.launched, isEmpty);

      // After cancel.
      final cancelled = h.authenticate('S1');
      await h.launcher.waitFor(1);
      await h.auth.cancel();
      await cancelled.outcome;
      expect(await h.auth.reopen(), isFalse);
      expect(h.launcher.launched, hasLength(1));

      // After a timeout.
      final timedOut = h.authenticate('S2');
      await h.launcher.waitFor(2);
      h.fireDeadline();
      expect((await timedOut.outcome).error, isA<LoopbackTimeout>());
      expect(await h.auth.reopen(), isFalse);
      expect(h.launcher.launched, hasLength(2));

      // After an accept.
      final accepted = h.authenticate('S3');
      await h.launcher.waitFor(3);
      await _send(h.port, _request(h.port, '$_callbackPath?code=C&state=S3'));
      expect((await accepted.outcome).uri, isNotNull);
      expect(await h.auth.reopen(), isFalse);
      expect(h.launcher.launched, hasLength(3));
    });

    test('a reopen whose attempt ends while it launches returns false and '
        'drops the launcher error', () async {
      final relaunch = Completer<bool>();
      final h = await _Harness.start(
        respond: (call) => call == 2 ? relaunch.future : Future.value(true),
      );
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      final reopened = h.auth.reopen();
      await h.launcher.waitFor(2);
      await h.auth.cancel();
      relaunch.completeError(PlatformException(code: 'Launch Error'));

      expect(await reopened, isFalse);
      expect(_codeOf((await pending.outcome).error), 'CANCELED');
    });
  });

  group('races (single winner)', () {
    test('two valid callbacks at once: exactly one wins', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      // Both connections are open before either request is written, then
      // both requests go out back to back.
      final a = await _Held.open(h.port, null);
      final b = await _Held.open(h.port, null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      a.write(_request(h.port, '$_callbackPath?code=CA&state=S1'));
      b.write(_request(h.port, '$_callbackPath?code=CB&state=S1'));
      final replies = [await a.reply(), await b.reply()];

      final winners = [
        for (final (i, r) in replies.indexed)
          if (r.status == HttpStatus.ok) i,
      ];
      expect(winners, hasLength(1), reason: '${replies.map((r) => r.status)}');
      final code = winners.single == 0 ? 'CA' : 'CB';
      expect(
        (await pending.outcome).uri,
        h.redirectWith('code=$code&state=S1'),
      );
      await _expectPortFree(h.port);
    });

    test('a second valid callback while the first is still being answered '
        'gets a 404; the first wins', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      // The first valid callback's landing page stays in flight with the
      // server still listening: a deterministic overlap.
      final first = await h.holdCallback('code=CA&state=S1');
      // The claim cancels the attempt's deadline: a strict barrier.
      await h.waitUntilClaimed();
      expect(pending.settled, isFalse);

      final second = await _send(
        h.port,
        _request(h.port, '$_callbackPath?code=CB&state=S1'),
      );

      expect(second.status, HttpStatus.notFound);
      first.sendDeclaredBody(); // end the overlap now, not at the bound
      expect((await pending.outcome).uri, h.redirectWith('code=CA&state=S1'));
      await first.closed.timeout(_prompt);
      await _expectPortFree(h.port);
    });

    test('the deadline fires first: TIMEOUT, and a callback right after it '
        'changes nothing', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      h.fireDeadline();
      final late = await _send(
        h.port,
        _request(h.port, '$_callbackPath?code=C1&state=S1'),
      );

      // Refused, or a 404 if it landed before the listener closed.
      expect(late.status, isNot(HttpStatus.ok));
      expect((await pending.outcome).error, isA<LoopbackTimeout>());
      await _expectPortFree(h.port);
    });

    test('the callback is claimed first: the deadline is cancelled, and a '
        'late firing changes nothing', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      final reply = await _send(
        h.port,
        _request(h.port, '$_callbackPath?code=C1&state=S1'),
      );
      expect(reply.status, HttpStatus.ok);
      expect(h.deadlines.last.cancelled, isTrue);
      // A timer event already on its way when the claim happened.
      h.fireDeadline();

      expect((await pending.outcome).uri, h.redirectWith('code=C1&state=S1'));
      await _expectPortFree(h.port);
    });

    test('the deadline fires while the accepted callback is still being '
        'answered: the accept wins', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);
      // A valid callback whose landing page stays in flight.
      final held = await h.holdCallback('code=C1&state=S1');
      await h.waitUntilClaimed();

      h.fireDeadline();
      held.sendDeclaredBody(); // let the landing page finish now

      expect((await pending.outcome).uri, h.redirectWith('code=C1&state=S1'));
      await held.closed.timeout(_prompt);
      await _expectPortFree(h.port);
    });

    test("a superseded attempt's late launcher error has no effect on the "
        'new attempt', () async {
      final firstLaunch = Completer<bool>();
      final h = await _Harness.start(
        respond: (call) => call == 1 ? firstLaunch.future : Future.value(true),
      );
      final first = h.authenticate('S1');
      await h.launcher.waitFor(1);
      final second = h.authenticate('S2');
      await h.launcher.waitFor(2);
      expect(_codeOf((await first.outcome).error), 'CANCELED');

      firstLaunch.completeError(PlatformException(code: 'Launch Error'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(second.settled, isFalse);
      await h.expectAccepts(second, 'code=C2&state=S2');
    });
  });

  group('forced connection close', () {
    // A connection mid-request (headers sent, a declared body withheld) is
    // "active" to Dart's server: its default close() leaves it open. Each
    // terminal outcome must close it anyway.
    final outcomes = <String, Future<void> Function(_Harness, _Pending)>{
      'cancel': (h, pending) async {
        await h.auth.cancel();
        expect(_codeOf((await pending.outcome).error), 'CANCELED');
      },
      'dispose': (h, pending) async {
        await h.auth.dispose();
        expect(_codeOf((await pending.outcome).error), 'CANCELED');
      },
      'a newer authenticate': (h, pending) async {
        final newer = h.authenticate('S2');
        expect(_codeOf((await pending.outcome).error), 'CANCELED');
        await h.auth.cancel();
        await newer.outcome;
      },
      'timeout': (h, pending) async {
        h.fireDeadline();
        expect((await pending.outcome).error, isA<LoopbackTimeout>());
      },
      'accept': (h, pending) async {
        final reply = await _send(
          h.port,
          _request(h.port, '$_callbackPath?code=C1&state=S1'),
        );
        expect(reply.status, HttpStatus.ok);
        expect((await pending.outcome).uri, isNotNull);
      },
    };
    for (final MapEntry(key: name, value: end) in outcomes.entries) {
      test(
        'a connection held open mid-request does not survive $name',
        () async {
          final h = await _Harness.start();
          final pending = h.authenticate('S1');
          await h.launcher.waitFor(1);
          final held = await h.holdMidRequest();

          await end(h, pending);

          await expectLater(held.closed.timeout(_prompt), completes);
          await _expectPortFree(h.port);
        },
      );
    }

    test('a connection held open mid-request does not survive a launch '
        'error', () async {
      final launch = Completer<bool>();
      final h = await _Harness.start(respond: (_) => launch.future);
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);
      final held = await h.holdMidRequest();

      launch.completeError(PlatformException(code: 'Launch Error'));

      expect((await pending.outcome).error, isA<LoopbackNoBrowser>());
      await expectLater(held.closed.timeout(_prompt), completes);
      await _expectPortFree(h.port);
    });

    test('an idle keep-alive connection does not survive cancel', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);
      final held = await _Held.open(
        h.port,
        _request(h.port, '/favicon.ico', close: false),
      );
      expect((await held.reply()).status, HttpStatus.notFound);
      expect(held.isClosed, isFalse);

      await h.auth.cancel();

      expect(_codeOf((await pending.outcome).error), 'CANCELED');
      await expectLater(held.closed.timeout(_prompt), completes);
      await _expectPortFree(h.port);
    });
  });

  group('input checks', () {
    test('an authorize URL without exactly one non-empty state fails fast and '
        'leaves the pending attempt alone', () async {
      final h = await _Harness.start();
      final pending = h.authenticate('S1');
      await h.launcher.waitFor(1);

      for (final url in [
        Uri.parse('https://auth.example.test/authorize?client_id=x'),
        Uri.parse('https://auth.example.test/authorize?state='),
        Uri.parse('https://auth.example.test/authorize?state=a&state=a'),
        Uri.parse('https://auth.example.test/authorize?state=a&state=b'),
        Uri.parse('https://auth.example.test/authorize?state=%ff'),
      ]) {
        await expectLater(
          h.auth.authenticate(url: url, callbackUrlScheme: '${h.redirect}'),
          throwsArgumentError,
          reason: '$url',
        );
      }
      for (final scheme in [
        'http',
        'myapp://auth/callback',
        'http://127.0.0.1:${h.port}/other',
      ]) {
        await expectLater(
          h.auth.authenticate(
            url: _authorizeUrl('S2'),
            callbackUrlScheme: scheme,
          ),
          throwsArgumentError,
          reason: scheme,
        );
      }

      expect(pending.settled, isFalse);
      expect(h.launcher.launched, hasLength(1));
      final reply = await _send(
        h.port,
        _request(h.port, '$_callbackPath?code=C1&state=S1'),
      );
      expect(reply.status, HttpStatus.ok);
      expect((await pending.outcome).uri, h.redirectWith('code=C1&state=S1'));
    });

    test('the redirect must be http://127.0.0.1 with a port from 1024 to '
        '65535; the timeout must be positive and defaults to 5 minutes', () {
      for (final bad in [
        'http://localhost:48210/auth/callback',
        'https://127.0.0.1:48210/auth/callback',
        'http://127.0.0.1/auth/callback',
        'http://127.0.0.1:0/auth/callback',
        'http://127.0.0.1:80/auth/callback',
        'http://127.0.0.1:1023/auth/callback',
        'http://127.0.0.1:65536/auth/callback',
        'http://user@127.0.0.1:48210/auth/callback',
        'http://127.0.0.1:48210/auth/callback?x=1',
        'http://127.0.0.1:48210/auth/callback#f',
        'http://[::1]:48210/auth/callback',
        'myapp://auth/callback',
      ]) {
        expect(
          () => LoopbackWebAuth(redirect: Uri.parse(bad)),
          throwsArgumentError,
          reason: bad,
        );
      }
      for (final port in [1024, 65535]) {
        final edge = Uri.parse('http://127.0.0.1:$port/auth/callback');
        expect(LoopbackWebAuth(redirect: edge).hostPort, '127.0.0.1:$port');
      }
      final good = Uri.parse('http://127.0.0.1:48210/auth/callback');
      expect(
        () => LoopbackWebAuth(redirect: good, timeout: Duration.zero),
        throwsArgumentError,
      );
      // Constructing binds nothing.
      final auth = LoopbackWebAuth(redirect: good);
      expect(auth.timeout, const Duration(minutes: 5));
      expect(LoopbackWebAuth.defaultTimeout, const Duration(minutes: 5));
      expect(auth.hostPort, '127.0.0.1:48210');
    });
  });

  test('the browser check defaults to linuxDefaultBrowserCheck with the '
      'default launcher on Linux, and to none with an injected launcher; the '
      'landing page defaults to defaultLandingPageHtml', () {
    final redirect = Uri.parse('http://127.0.0.1:48210/auth/callback');
    Future<bool> check(Uri _) async => true;
    Future<bool> launcher(Uri _) async => true;

    // Constructing binds and launches nothing, so the default launcher is
    // safe here.
    final plain = LoopbackWebAuth(redirect: redirect);
    expect(
      plain.browserCheck,
      Platform.isLinux ? same(linuxDefaultBrowserCheck) : isNull,
    );
    expect(plain.landingPageHtml, defaultLandingPageHtml);
    expect(
      LoopbackWebAuth(redirect: redirect, launcher: launcher).browserCheck,
      isNull,
    );
    expect(
      LoopbackWebAuth(redirect: redirect, browserCheck: check).browserCheck,
      equals(check),
    );
    expect(
      LoopbackWebAuth(
        redirect: redirect,
        launcher: launcher,
        browserCheck: check,
      ).browserCheck,
      equals(check),
    );
  });

  test('logs nothing: no URL, code or state reaches print or '
      'debugPrint', () async {
    final printed = <String>[];
    final savedDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        printed.add(message ?? '');
    addTearDown(() => debugPrint = savedDebugPrint);

    await runZoned(
      () async {
        final h = await _Harness.start(
          respond: (call) async =>
              call == 2 ? throw PlatformException(code: 'Launch Error') : true,
        );
        final pending = h.authenticate('S1');
        await h.launcher.waitFor(1);
        await _send(h.port, _request(h.port, '/favicon.ico'));
        await _send(h.port, _request(h.port, '$_callbackPath?state=%ff'));
        await expectLater(h.auth.reopen(), throwsA(isA<LoopbackNoBrowser>()));
        await _send(h.port, _request(h.port, '$_callbackPath?code=C&state=S1'));
        await pending.outcome;
        final cancelled = h.authenticate('S2');
        await h.auth.cancel();
        await cancelled.outcome;
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    expect(printed, isEmpty);
  });

  testWidgets('an inactive→resumed lifecycle change while waiting does not '
      'cancel (no lifecycle observer)', (tester) async {
    await tester.runAsync(() async {
      final h = await _Harness.start();
      try {
        final pending = h.authenticate('S1');
        await h.launcher.waitFor(1);

        // What GTK reports when the browser takes focus and the app gets it
        // back.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(pending.settled, isFalse);
        await h.expectAccepts(pending, 'code=C1&state=S1');
      } finally {
        await h.auth.dispose();
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Harness

Uri _authorizeUrl(String state) => Uri.parse(
  'https://auth.example.test/oauth2/authorize'
  '?client_id=client_test&response_type=code&state=$state',
);

String? _codeOf(Object? error) =>
    error is PlatformException ? error.code : null;

/// Lets everything already scheduled run (a check's answer reaching the
/// attempt, a launch it might start).
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

/// Waits (polling, at most [_prompt]) until [condition] holds.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(_prompt);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A [BrowserCheck] whose answers the test gives, one per call, in order.
class _HeldCheck {
  final List<Uri> asked = [];
  final List<Completer<bool>> _answers = [];

  Future<bool> call(Uri url) {
    asked.add(url);
    final answer = Completer<bool>();
    _answers.add(answer);
    return answer.future;
  }

  /// Answers call number [index] (0-based).
  void answer(int index, bool mayOpen) => _answers[index].complete(mayOpen);

  /// Completes once [count] calls have been made.
  Future<void> waitFor(int count) => _until(() => asked.length >= count);
}

/// One [LoopbackWebAuth] on a fresh ephemeral port with a fake launcher.
class _Harness {
  _Harness._(
    this.port,
    this.redirect,
    this.launcher,
    this.deadlines,
    this.auth,
  );

  /// Deadlines are [_FakeDeadline]s that fire only when the test says so,
  /// unless [realTimeout] asks for the real timer.
  /// [browserCheck]: asked before each launch (none by default: the fake
  /// launcher answers for itself).
  static Future<_Harness> start({
    Future<bool> Function(int call)? respond,
    Duration? realTimeout,
    BrowserCheck? browserCheck,
    String landingPageHtml = defaultLandingPageHtml,
  }) async {
    final port = await _freePort();
    final redirect = Uri.parse('http://127.0.0.1:$port$_callbackPath');
    final launcher = _FakeLauncher(respond);
    final deadlines = _FakeDeadlines();
    final auth = realTimeout == null
        ? LoopbackWebAuth(
            redirect: redirect,
            launcher: launcher.call,
            browserCheck: browserCheck,
            landingPageHtml: landingPageHtml,
            deadlineTimer: deadlines.call,
          )
        : LoopbackWebAuth(
            redirect: redirect,
            launcher: launcher.call,
            browserCheck: browserCheck,
            landingPageHtml: landingPageHtml,
            timeout: realTimeout,
          );
    final harness = _Harness._(port, redirect, launcher, deadlines, auth);
    addTearDown(harness._closeHeld);
    addTearDown(auth.dispose);
    return harness;
  }

  final int port;
  final Uri redirect;
  final _FakeLauncher launcher;
  final _FakeDeadlines deadlines;
  final LoopbackWebAuth auth;
  final List<_Held> _held = [];

  _Pending authenticate(String state) => _Pending(
    auth.authenticate(
      url: _authorizeUrl(state),
      callbackUrlScheme: redirect.toString(),
    ),
  );

  Uri redirectWith(String query) => Uri.parse('$redirect?$query');

  /// Sends the valid callback with [query]: it gets the landing page,
  /// [pending] completes with [redirect] plus [query], and the port is free.
  Future<void> expectAccepts(_Pending pending, String query) async {
    final reply = await _send(port, _request(port, '$_callbackPath?$query'));
    expect(reply.status, HttpStatus.ok);
    expect((await pending.outcome).uri, redirectWith(query));
    await _expectPortFree(port);
  }

  /// A valid callback with [query] that declares a body it does not send:
  /// Dart's server holds the response until the body arrives, so the landing
  /// page stays in flight (up to [LoopbackWebAuth.landingPageDeadline])
  /// until [_Held.sendDeclaredBody].
  Future<_Held> holdCallback(String query) => _Held.open(
    port,
    _request(
      port,
      '$_callbackPath?$query',
      headers: {'Content-Length': '$_declaredBody'},
      close: false,
    ),
  );

  /// Fires the latest attempt's deadline now.
  void fireDeadline() => deadlines.last.fire();

  /// Completes once the latest attempt's outcome is claimed: every claim
  /// cancels the attempt's deadline first, synchronously.
  Future<void> waitUntilClaimed() => deadlines.last.whenCancelled.timeout(
    _prompt,
    onTimeout: () => fail('the attempt was never claimed'),
  );

  /// A POST to the callback path that declares a body it never sends. The
  /// handler 404s it, but Dart's server holds the response until the body
  /// arrives, so the connection stays active until something force-closes
  /// it.
  Future<_Held> holdMidRequest() async {
    final held = await _Held.open(
      port,
      _request(
        port,
        '$_callbackPath?code=C&state=S1',
        method: 'POST',
        headers: {'Content-Length': '$_declaredBody'},
        close: false,
      ),
    );
    _held.add(held);
    // A full request on a second connection, answered after the held one's
    // headers were read (one event loop, in order), plus a short margin.
    final probe = await _send(port, _request(port, '/probe'));
    expect(probe.status, HttpStatus.notFound);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(held.isClosed, isFalse);
    return held;
  }

  void _closeHeld() {
    for (final held in _held) {
      held.destroy();
    }
  }
}

/// The deadline seam: records every deadline an attempt starts.
class _FakeDeadlines {
  final List<_FakeDeadline> started = [];

  _FakeDeadline get last => started.last;

  Timer call(Duration duration, void Function() onDeadline) {
    final deadline = _FakeDeadline(duration, onDeadline);
    started.add(deadline);
    return deadline;
  }
}

/// A deadline that fires only through [fire]. [fire] runs the callback even
/// after [cancel]: the worst case, a timer event already on its way.
class _FakeDeadline implements Timer {
  _FakeDeadline(this.duration, this._onDeadline);

  final Duration duration;
  final void Function() _onDeadline;
  final Completer<void> _cancelled = Completer<void>();
  int _tick = 0;

  bool get cancelled => _cancelled.isCompleted;

  /// Completes when the deadline is cancelled.
  Future<void> get whenCancelled => _cancelled.future;

  void fire() {
    _tick++;
    _onDeadline();
  }

  @override
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  @override
  bool get isActive => !cancelled && _tick == 0;

  @override
  int get tick => _tick;
}

/// Records each launch; answers with [respond] (default: launched).
class _FakeLauncher {
  _FakeLauncher(Future<bool> Function(int call)? respond)
    : _respond = respond ?? ((_) => Future.value(true));

  final Future<bool> Function(int call) _respond;
  final List<Uri> launched = [];
  final List<(int, Completer<void>)> _waiters = [];

  Future<bool> call(Uri url) {
    launched.add(url);
    for (final waiter in _waiters.toList()) {
      if (waiter.$1 <= launched.length) {
        _waiters.remove(waiter);
        waiter.$2.complete();
      }
    }
    return _respond(launched.length);
  }

  /// Completes once [count] launches have happened.
  Future<void> waitFor(int count) {
    if (launched.length >= count) return Future.value();
    final completer = Completer<void>();
    _waiters.add((count, completer));
    return completer.future.timeout(_prompt);
  }
}

class _Outcome {
  _Outcome({this.uri, this.error});

  final Uri? uri;
  final Object? error;
}

/// An authenticate future, observed from the start (so a failure is never
/// an unhandled error) and checkable for "still pending".
class _Pending {
  _Pending(Future<Uri> future)
    : _done = future.then(
        (uri) => _Outcome(uri: uri),
        onError: (Object error) => _Outcome(error: error),
      ) {
    unawaited(_done.then((_) => settled = true));
  }

  final Future<_Outcome> _done;
  bool settled = false;

  Future<_Outcome> get outcome => _done.timeout(_prompt);
}

// ---------------------------------------------------------------------------
// Sockets

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Binds [port] ourselves: fails the test if anything still holds it.
Future<void> _expectPortFree(int port) async {
  final ServerSocket socket;
  try {
    socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
  } on SocketException catch (e) {
    fail('port $port is still bound: $e');
  }
  await socket.close();
}

String _request(
  int port,
  String target, {
  String method = 'GET',
  Map<String, String> headers = const {},
  bool close = true,
}) {
  final text = StringBuffer('$method $target HTTP/1.1\r\n');
  if (!headers.keys.any((name) => name.toLowerCase() == 'host')) {
    text.write('Host: 127.0.0.1:$port\r\n');
  }
  headers.forEach((name, value) => text.write('$name: $value\r\n'));
  if (close) text.write('Connection: close\r\n');
  text.write('\r\n');
  return text.toString();
}

/// Sends [request] on a new connection and reads until the server closes it.
Future<_Reply> _send(int port, String request) async {
  final _Held held;
  try {
    held = await _Held.open(port, request);
  } on SocketException {
    return _Reply.refused();
  } on OSError {
    // A connection that lands while the listener closes can be reset during
    // connect, which Dart reports as a bare OSError.
    return _Reply.refused();
  }
  try {
    await held.closed.timeout(_prompt);
    return _Reply.parse(held.bytes);
  } finally {
    held.destroy();
  }
}

/// A raw client connection that records what arrives and when it closes.
class _Held {
  _Held._(this._socket) {
    _socket.done.ignore();
    _socket.listen(
      (data) {
        bytes.addAll(data);
        _maybeReplied();
      },
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
      cancelOnError: true,
    );
  }

  static Future<_Held> open(int port, String? request) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final held = _Held._(socket);
    if (request != null) held.write(request);
    return held;
  }

  final Socket _socket;
  final List<int> bytes = [];
  final Completer<void> _closed = Completer<void>();
  final Completer<_Reply> _replied = Completer<_Reply>();

  Future<void> get closed => _closed.future;
  bool get isClosed => _closed.isCompleted;

  void write(String request) {
    _socket.write(request);
    _socket.flush().ignore();
  }

  /// Sends the body a held request declared ([_declaredBody] bytes), so the
  /// server can finish answering it.
  void sendDeclaredBody() => write('x' * _declaredBody);

  /// The first complete response, or what arrived before the close.
  Future<_Reply> reply() => _replied.future.timeout(_prompt);

  void destroy() => _socket.destroy();

  void _onClosed() {
    if (!_closed.isCompleted) _closed.complete();
    if (!_replied.isCompleted) _replied.complete(_Reply.parse(bytes));
  }

  void _maybeReplied() {
    if (_replied.isCompleted) return;
    final reply = _Reply.parse(bytes);
    final length = int.tryParse(reply.headers['content-length'] ?? '');
    if (reply.status != null &&
        length != null &&
        utf8.encode(reply.body).length >= length) {
      _replied.complete(reply);
    }
  }
}

class _Reply {
  _Reply(this.status, this.headers, this.body, {this.refused = false});

  _Reply.refused() : this(null, const {}, '', refused: true);

  /// Parses one HTTP/1.1 response; [status] is null when no complete head
  /// arrived (the connection was dropped).
  factory _Reply.parse(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final split = text.indexOf('\r\n\r\n');
    if (split < 0) return _Reply(null, const {}, '');
    final lines = text.substring(0, split).split('\r\n');
    final parts = lines.first.split(' ');
    final headers = <String, String>{
      for (final line in lines.skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim().toLowerCase(): line
              .substring(line.indexOf(':') + 1)
              .trim(),
    };
    expect(headers['transfer-encoding'], isNull, reason: 'chunked reply');
    return _Reply(
      parts.length > 1 ? int.tryParse(parts[1]) : null,
      headers,
      text.substring(split + 4),
    );
  }

  final int? status;
  final Map<String, String> headers;
  final String body;
  final bool refused;
}

/// Holds a loopback port from a separate `dart` process, so binding it here
/// fails with the OS's EADDRINUSE (a conflict inside this process fails
/// differently, with no errno).
class _OtherProcessHolder {
  _OtherProcessHolder._(this._process, this._dir);

  static Future<_OtherProcessHolder> bind(int port) async {
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot == null || flutterRoot.isEmpty) {
      fail('FLUTTER_ROOT is not set: run this through `flutter test`');
    }
    final dart = '$flutterRoot/bin/cache/dart-sdk/bin/dart';
    final dir = await Directory.systemTemp.createTemp('slauth-loopback-test-');
    final script = File('${dir.path}/hold_port.dart');
    await script.writeAsString('''
import 'dart:io';

Future<void> main(List<String> args) async {
  final socket =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, int.parse(args.single));
  stdout.writeln('bound');
  await stdout.flush();
  await stdin.drain<void>();
  await socket.close();
}
''');
    final process = await Process.start(dart, [script.path, '$port']);
    final holder = _OtherProcessHolder._(process, dir);
    final bound = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line == 'bound');
    process.stderr.drain<void>().ignore();
    try {
      await bound.timeout(const Duration(seconds: 60));
    } catch (_) {
      await holder.stop();
      rethrow;
    }
    return holder;
  }

  final Process _process;
  final Directory _dir;
  bool _stopped = false;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _process.stdin.close();
    _process.kill();
    await _process.exitCode;
    await _dir.delete(recursive: true);
  }
}
