/// Desktop sign-in through the user's default browser and a loopback
/// redirect: the native-app pattern of RFC 8252 (section 7.3), with the
/// server, the browser launch and the attempt's lifecycle owned here.
///
/// `flutter_web_auth_2`'s Linux/Windows server mode is not used: it cancels a
/// pending sign-in whenever the window regains focus, leaks its socket when
/// the launch fails, lets the last request (a favicon fetch included) win,
/// builds its result from request headers, and keeps singleton state. This
/// file owns the whole flow instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import 'default_browser.dart' show linuxDefaultBrowserCheck;
import 'landing_page.dart';
import 'web_auth.dart';

/// Opens [url] in a browser. Reports "no browser" by returning `false` or by
/// throwing a [PlatformException] with code `Launch Error` (what
/// `url_launcher_linux` throws when its launch call fails).
typedef BrowserLauncher = Future<bool> Function(Uri url);

/// Starts the attempt's deadline: calls `onDeadline` once [duration] has
/// passed, unless the returned timer is cancelled first. [LoopbackWebAuth]
/// uses `Timer.new`; tests inject one they fire by hand.
typedef DeadlineTimerFactory =
    Timer Function(Duration duration, void Function() onDeadline);

/// Asked before each launch: whether a browser may open [url]. `false` means
/// no browser ([LoopbackNoBrowser]).
typedef BrowserCheck = Future<bool> Function(Uri url);

/// [LoopbackWebAuth]'s default launcher: the user's default browser, outside
/// the app (url_launcher). On Linux its default [BrowserCheck],
/// [linuxDefaultBrowserCheck], runs first.
Future<bool> launchInDefaultBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// A [WebAuth] whose pending sign-in the UI can end, and whose browser step it
/// can start again, while it waits.
abstract interface class InteractiveWebAuth implements WebAuth {
  /// Ends the pending sign-in: its [authenticate] future fails with a plain
  /// `PlatformException(code: 'CANCELED')`. The returned future completes once
  /// that attempt has released everything it held. A no-op when nothing is
  /// pending.
  Future<void> cancel();

  /// Opens the pending sign-in's authorize URL again while it keeps waiting.
  ///
  /// `true` once the browser was asked to open it; `false` when no sign-in is
  /// waiting (none started, still starting, or already over), in which case
  /// nothing is launched. A failed launch throws [LoopbackNoBrowser] (or the
  /// launcher's own error) and leaves the sign-in waiting.
  Future<bool> reopen();
}

/// A sign-in failure that [LoopbackWebAuth] names, so the app's sign-in screen
/// can map each to its own message without matching strings.
///
/// Each is a [PlatformException] whose [code] is distinct from `CANCELED`; a
/// cancel stays a plain `PlatformException(code: 'CANCELED')` and stays quiet.
sealed class LoopbackAuthFailure extends PlatformException {
  LoopbackAuthFailure._(String code, this.hostPort, String message)
    : super(code: code, message: message);

  /// The configured listening address, `host:port` (`127.0.0.1:8765`).
  final String hostPort;
}

/// The configured loopback address could not be bound: another program, or
/// another window of the same app mid-sign-in, holds it. Raised for any
/// [SocketException] from `bind`, whatever its errno: another process gives
/// EADDRINUSE, but a conflict inside this process gives Dart's own error,
/// with error code -1.
final class LoopbackPortBusy extends LoopbackAuthFailure {
  LoopbackPortBusy(String hostPort, this.socketException)
    : super._(errorCode, hostPort, 'Could not listen on $hostPort.');

  static const errorCode = 'PORT_BUSY';

  /// What `bind` threw.
  final SocketException socketException;
}

/// No browser could be opened: the launcher threw `Launch Error` or returned
/// `false`. Ends the sign-in (and releases the port at once) when it happens
/// on the first launch; leaves it waiting when it happens on [reopen].
final class LoopbackNoBrowser extends LoopbackAuthFailure {
  LoopbackNoBrowser(String hostPort)
    : super._(errorCode, hostPort, 'No browser could be opened.');

  /// The code `url_launcher_linux` uses for the same failure.
  static const errorCode = 'Launch Error';
}

/// No valid callback arrived before [LoopbackWebAuth.timeout].
final class LoopbackTimeout extends LoopbackAuthFailure {
  LoopbackTimeout(String hostPort)
    : super._(errorCode, hostPort, 'No sign-in callback arrived in time.');

  static const errorCode = 'TIMEOUT';
}

/// A desktop [WebAuth]: opens the authorize URL in the user's default browser
/// and waits for the redirect on a loopback HTTP server it owns (RFC 8252's
/// loopback redirect, on `127.0.0.1` and a fixed, registered port).
///
/// Opt-in: [FlutterWebAuth2Impl] is unchanged, and nothing selects this
/// class for the app. The app chooses where to use it (Linux, where it has
/// been proven end to end; the plugin's Windows paths have the same defects,
/// but this class is untested there), keeps the provider's config and the
/// callback validation, and may pass its own landing page.
///
/// [authenticate] takes the configured [redirect] itself as
/// `callbackUrlScheme`. It binds `127.0.0.1:<port>` before launching the
/// browser, and accepts exactly one request: a `GET` for [redirect]'s path
/// whose query has exactly one `state`, equal to the authorize URL's. That
/// request gets [landingPageHtml] and the sign-in completes with [redirect]
/// plus that request's query string (never anything from `Host`,
/// `X-Forwarded-*` or the request target's authority). Every other request
/// gets a small 404 (400 for a query that does not decode) and the server
/// keeps listening. The port is released on every outcome: accept, cancel,
/// timeout, launch error, a bind failure, a newer [authenticate] and
/// [dispose]; the returned future settles only after that.
///
/// What "the configured path" and "the query" mean here: `dart:io` exposes no
/// raw request target. Its parser builds `request.uri` with `Uri.parse`,
/// which repairs malformed escapes (`%` becomes `%25`, `%zz` becomes `%25zz`)
/// and removes dot segments (`/other/../auth/callback` and
/// `/auth/%2e/callback` both become `/auth/callback`) before this class sees
/// the request. So a non-canonical spelling of the path is accepted, and a
/// malformed escape is relayed repaired rather than refused (only a query
/// that does not decode, such as `%ff`, which is not UTF-8, gets the 400).
/// Neither weakens the check that matters: acceptance still needs exactly one
/// `state` that decodes to exactly the current attempt's value, which a
/// stray or injected request does not know (and `Pkce.generateState` emits
/// only unreserved characters, never `%`, so no repaired escape can decode
/// to it); a mangled `code` only fails the exchange, which is bound to the
/// PKCE verifier held in memory; and the app's callback validation (which
/// stays in the app) re-checks the result's destination and its single
/// `state`, `code` and `error` values. A target with a fragment (any `#`) is
/// refused, since the parser would silently drop everything after it.
///
/// One attempt at a time, single winner: a newer [authenticate] cancels the
/// pending one and binds only after it has released the port. Each attempt's
/// outcome is claimed synchronously by whichever event comes first; a late
/// request, timer, launcher or bind result then changes nothing, and never
/// touches a newer attempt.
///
/// It registers no app-lifecycle observer: refocusing the app while the
/// browser is open changes nothing. Nothing here logs the authorize URL,
/// the callback URL, the code or the state.
class LoopbackWebAuth implements InteractiveWebAuth {
  /// [redirect] must be `http://127.0.0.1:<port>/<path>` with a port from
  /// [minPort] to 65535 and no userinfo, query or fragment
  /// ([isLoopbackRedirect]); [timeout] must be positive. Both are checked
  /// here and throw an [ArgumentError].
  /// [launcher] opens the browser (default [launchInDefaultBrowser]).
  /// [browserCheck] runs before each launch, the first and every [reopen]:
  /// `false` is no browser ([LoopbackNoBrowser]). With the default launcher
  /// it defaults to [linuxDefaultBrowserCheck] on Linux and to none
  /// elsewhere; with an injected launcher, to none (the launcher then reports
  /// a missing browser itself). [landingPageHtml] is the page the accepted
  /// callback gets (default [defaultLandingPageHtml]): an app passes its own
  /// to name itself. [deadlineTimer] starts each attempt's [timeout]; only
  /// tests replace it.
  LoopbackWebAuth({
    required this.redirect,
    BrowserLauncher? launcher,
    BrowserCheck? browserCheck,
    this.timeout = defaultTimeout,
    this.landingPageHtml = defaultLandingPageHtml,
    this._deadlineTimer = Timer.new,
  }) : _launcher = launcher ?? launchInDefaultBrowser,
       browserCheck =
           browserCheck ??
           (launcher == null && Platform.isLinux
               ? linuxDefaultBrowserCheck
               : null),
       _landingPageBody = utf8.encode(landingPageHtml) {
    if (!isLoopbackRedirect(redirect)) {
      throw ArgumentError(
        'redirect must be http://127.0.0.1:<port>/<path> with a port from '
        '$minPort to 65535 and no userinfo, query or fragment',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
  }

  /// How long a sign-in waits for its callback unless [timeout] says otherwise.
  static const defaultTimeout = Duration(minutes: 5);

  /// How long the accepted request's landing page gets to reach the browser
  /// before its connection is closed regardless.
  static const landingPageDeadline = Duration(seconds: 2);

  /// The code of the plain [PlatformException] a cancelled sign-in fails with.
  static const canceledCode = 'CANCELED';

  /// The loopback redirect this instance listens for.
  final Uri redirect;

  /// How long one sign-in waits for its callback before failing with
  /// [LoopbackTimeout].
  final Duration timeout;

  /// The HTML the accepted callback gets, as `text/html; charset=utf-8`.
  final String landingPageHtml;

  /// The check run before each launch, or null for none (see the
  /// constructor for its default).
  final BrowserCheck? browserCheck;

  final BrowserLauncher _launcher;
  final List<int> _landingPageBody;
  final DeadlineTimerFactory _deadlineTimer;

  _Attempt? _latest;
  bool _disposed = false;

  /// [redirect]'s `host:port`, as the failures carry it.
  String get hostPort => '${redirect.host}:${redirect.port}';

  @override
  Future<Uri> authenticate({
    required Uri url,
    required String callbackUrlScheme,
  }) async {
    if (_disposed) throw StateError('LoopbackWebAuth was disposed');
    final state = _expectedState(url);
    if (Uri.tryParse(callbackUrlScheme) != redirect) {
      throw ArgumentError(
        'callbackUrlScheme must be the configured loopback redirect URI',
      );
    }

    // The attempt has its identity before anything is awaited, so a cancel
    // or a newer call during the waits below finds and ends it.
    final attempt = _Attempt(url, state);
    final previous = _latest;
    _latest = attempt;
    if (previous != null) {
      _fail(previous, _canceled());
      await previous.released.future;
    }
    // An attempt ended while the previous one released the port never binds.
    HttpServer? server;
    if (!attempt.claimed) {
      try {
        server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          redirect.port,
        );
      } on SocketException catch (e) {
        _fail(attempt, LoopbackPortBusy(hostPort, e));
      }
    }
    if (server == null || attempt.claimed) {
      // Never bound (ended first, or the bind failed), or ended while
      // binding: close at once, never launch.
      if (server != null) await _close(server);
      attempt.released.complete();
      return attempt.outcome.future;
    }

    attempt.server = server;
    server.listen(
      (request) => _handle(attempt, request).ignore(),
      onError: (Object _) {},
    );
    attempt.deadline = _deadlineTimer(
      timeout,
      () => _fail(attempt, LoopbackTimeout(hostPort)),
    );
    unawaited(_launch(attempt));
    return attempt.outcome.future;
  }

  @override
  Future<void> cancel() async {
    final attempt = _latest;
    if (attempt == null) return;
    _fail(attempt, _canceled());
    await attempt.released.future;
  }

  @override
  Future<bool> reopen() async {
    final attempt = _latest;
    if (attempt == null || attempt.claimed || attempt.server == null) {
      return false;
    }
    try {
      await _openBrowser(attempt);
    } catch (_) {
      if (!attempt.claimed) rethrow; // over while launching: drop the error
    }
    return !attempt.claimed;
  }

  /// Cancels any pending sign-in (as [cancel]) and refuses later
  /// [authenticate] calls.
  Future<void> dispose() async {
    _disposed = true;
    await cancel();
  }

  Future<void> _launch(_Attempt attempt) async {
    try {
      await _openBrowser(attempt);
    } catch (e, s) {
      _fail(attempt, e, s); // no-op once claimed
    }
  }

  /// Whether [attempt] may still open a browser: it is the current one, its
  /// outcome is not claimed (accepted, cancelled, timed out, failed,
  /// superseded) and this instance is not disposed.
  bool _isLive(_Attempt attempt) =>
      identical(_latest, attempt) && !attempt.claimed && !_disposed;

  /// Runs the browser check, then the launcher, for [attempt]'s authorize
  /// URL; completes once the browser was asked to open it. The check can
  /// take a while (a separate process, up to its bound), so the attempt is
  /// checked again after it: one that ended meanwhile (Cancel, a newer
  /// attempt, dispose) launches nothing, and its URL never opens. No browser
  /// throws [LoopbackNoBrowser]; any other launcher error surfaces as is. A
  /// check that fails counts as "may open" (the launch goes ahead, as when
  /// the desktop cannot tell).
  Future<void> _openBrowser(_Attempt attempt) async {
    final url = attempt.authorizeUrl;
    final check = browserCheck;
    if (check != null) {
      bool mayOpen;
      try {
        mayOpen = await check(url);
      } catch (_) {
        mayOpen = true;
      }
      if (!_isLive(attempt)) return;
      if (!mayOpen) throw LoopbackNoBrowser(hostPort);
    }
    if (!_isLive(attempt)) return;
    try {
      if (await _launcher(url)) return;
    } on PlatformException catch (e, s) {
      // A `Launch Error` becomes LoopbackNoBrowser without the launcher's
      // message, which may carry the URL.
      if (e.code == LoopbackNoBrowser.errorCode) {
        Error.throwWithStackTrace(LoopbackNoBrowser(hostPort), s);
      }
      rethrow;
    }
    throw LoopbackNoBrowser(hostPort);
  }

  Future<void> _handle(_Attempt attempt, HttpRequest request) async {
    int status;
    try {
      final result = _callbackResult(attempt, request);
      if (result != null && _claim(attempt)) {
        await _deliver(attempt, request, result);
        return;
      }
      status = HttpStatus.notFound;
    } catch (_) {
      // A query that does not decode (FormatException), or anything else
      // unexpected: answer and keep listening.
      status = HttpStatus.badRequest;
    }
    await _respond(
      request.response..statusCode = status,
      ContentType.text,
      status == HttpStatus.notFound ? _notFoundBody : _badRequestBody,
    );
  }

  /// Writes [body] with an explicit `Content-Length` and closes [response].
  static Future<void> _respond(
    HttpResponse response,
    ContentType contentType,
    List<int> body,
  ) {
    response.headers.contentType = contentType;
    response.contentLength = body.length;
    response.add(body);
    return response.close();
  }

  /// The sign-in result when [request] is this attempt's callback, else null.
  /// Throws a [FormatException] when the callback path's query does not
  /// decode.
  Uri? _callbackResult(_Attempt attempt, HttpRequest request) {
    if (request.method != 'GET') return null;
    final target = request.uri;
    // Origin-form only: an absolute-form or `//host/...` target is not ours.
    // A fragment is refused too: the parser cut the target at its `#`, so
    // relaying the rest would silently truncate what the client sent.
    if (target.hasScheme || target.hasAuthority || target.hasFragment) {
      return null;
    }
    if (target.path != redirect.path) return null;
    final states = target.queryParametersAll['state'];
    if (states == null ||
        states.length != 1 ||
        states.single != attempt.state) {
      return null;
    }
    return redirect.replace(query: target.query);
  }

  /// Answers the accepted callback with the landing page, then closes the
  /// server and completes the attempt with [result]. Never throws; a failed
  /// or slow write never stops the completion.
  Future<void> _deliver(
    _Attempt attempt,
    HttpRequest request,
    Uri result,
  ) async {
    final server = attempt.server;
    attempt.server = null;
    try {
      final response = request.response
        ..statusCode = HttpStatus.ok
        ..persistentConnection = false;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      await _respond(
        response,
        ContentType.html, // text/html; charset=utf-8
        _landingPageBody,
      ).timeout(landingPageDeadline);
    } catch (_) {
      // Delivered or not, the sign-in completes.
    } finally {
      if (server != null) await _close(server);
      attempt.released.complete();
      attempt.outcome.complete(result);
    }
  }

  /// Claims [attempt]'s terminal outcome: true for the first caller only.
  bool _claim(_Attempt attempt) {
    if (attempt.claimed) return false;
    attempt.claimed = true;
    attempt.deadline?.cancel();
    return true;
  }

  /// Ends [attempt] with [error] unless its outcome is already claimed. The
  /// claim is synchronous; the attempt's future fails once the port is free.
  void _fail(_Attempt attempt, Object error, [StackTrace? stackTrace]) {
    if (!_claim(attempt)) return;
    unawaited(_releaseThenFail(attempt, error, stackTrace));
  }

  /// Closes [attempt]'s server, if it is listening, waits until the attempt
  /// holds no server and never will again, then fails it with [error].
  Future<void> _releaseThenFail(
    _Attempt attempt,
    Object error,
    StackTrace? stackTrace,
  ) async {
    final server = attempt.server;
    if (server != null) {
      attempt.server = null;
      await _close(server);
      attempt.released.complete();
    }
    await attempt.released.future;
    attempt.outcome.completeError(error, stackTrace);
  }

  /// Closes [server] and every connection it still has, mid-request ones
  /// included (Dart's default `close()` leaves those open). Never throws.
  static Future<void> _close(HttpServer server) async {
    try {
      await server.close(force: true);
    } catch (_) {
      // Closing is best effort; the listener is gone either way.
    }
  }

  static PlatformException _canceled() => PlatformException(
    code: canceledCode,
    message: 'The sign-in was cancelled.',
  );

  /// The authorize URL's `state`: exactly one, non-empty.
  static String _expectedState(Uri url) {
    List<String>? states;
    try {
      states = url.queryParametersAll['state'];
    } on FormatException {
      states = null;
    }
    if (states == null || states.length != 1 || states.single.isEmpty) {
      throw ArgumentError(
        'the authorize url must carry exactly one non-empty state parameter',
      );
    }
    return states.single;
  }

  /// The lowest port a redirect may name: a loopback listener must not need
  /// root, so the privileged ports (below 1024) are refused. Also why an
  /// implicit or explicit default port (`:80`, which Dart's [Uri] drops) is
  /// refused.
  static const minPort = 1024;

  /// Whether [uri] is a redirect this class accepts:
  /// `http://127.0.0.1:<port>/<path>` with a port from [minPort] to 65535
  /// and no userinfo, query or fragment. An app that reads the redirect from
  /// its configuration may require more on top (its own path, a canonical
  /// spelling, since the same string is sent as `redirect_uri`).
  static bool isLoopbackRedirect(Uri uri) =>
      uri.scheme == 'http' &&
      uri.host == '127.0.0.1' &&
      uri.port >= minPort &&
      uri.port <= 65535 &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.path.startsWith('/');
}

final List<int> _notFoundBody = utf8.encode('Not found.\n');
final List<int> _badRequestBody = utf8.encode('Bad request.\n');

/// One sign-in attempt: its server, deadline and outcome.
class _Attempt {
  _Attempt(this.authorizeUrl, this.state);

  final Uri authorizeUrl;
  final String state;

  /// What [LoopbackWebAuth.authenticate] returns.
  final Completer<Uri> outcome = Completer<Uri>();

  /// Completes once this attempt holds no server and never will again.
  final Completer<void> released = Completer<void>();

  /// Set while listening; taken (set to null) by whoever closes it.
  HttpServer? server;
  Timer? deadline;

  /// Set, synchronously, by the first terminal outcome.
  bool claimed = false;
}
