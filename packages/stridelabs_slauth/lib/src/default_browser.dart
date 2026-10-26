/// Whether Linux has a default application for a URL scheme, asked of the
/// desktop's own tools in a separate process: bounded, off the UI thread, and
/// never touching the network. [linuxDefaultBrowserCheck] is the
/// [BrowserCheck] built on it, [LoopbackWebAuth]'s default on Linux.
///
/// Why a lookup at all: `url_launcher_linux` launches with
/// `gtk_show_uri_on_window`, which (GTK 3.24.41, with a parent window)
/// returns success at once even when no application handles the URL, and
/// never reports the failure, so a missing browser could never be reported.
/// url_launcher's own `canLaunchUrl` is no answer either: with no scheme
/// handler it falls through to `g_file_query_default_handler`, which with GVfs
/// installed asks the URL itself over HTTP, synchronously on the GTK thread,
/// with no deadline.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'loopback_web_auth.dart' show BrowserCheck, LoopbackWebAuth;

/// A [BrowserCheck] for Linux: false only when the desktop says no
/// application is the default for [url]'s scheme; true when one is, and when
/// the lookup cannot tell (no tool, a timeout), so the launch then goes ahead.
///
/// [LoopbackWebAuth]'s default check on Linux, with its default launcher. It
/// asks [lookUpDefaultBrowser]: `gio mime` (or `xdg-mime`) in a separate
/// process, at most 2 s, off the UI thread, no network. Without it, a sign-in
/// on a desktop with no browser would wait for one that never opens, until
/// its timeout or a cancel. [run] is the process seam (tests).
Future<bool> linuxDefaultBrowserCheck(
  Uri url, {
  @visibleForTesting ToolRunner run = runTool,
}) async =>
    await lookUpDefaultBrowser(url.scheme, run: run) is! NoDefaultBrowser;

/// What [lookUpDefaultBrowser] found.
sealed class DefaultBrowser {
  const DefaultBrowser();
}

/// A default application is registered for the scheme: its desktop entry.
final class DefaultBrowserFound extends DefaultBrowser {
  const DefaultBrowserFound(this.desktopEntry);

  final String desktopEntry;

  @override
  String toString() => 'DefaultBrowserFound($desktopEntry)';
}

/// The desktop's tools say no application is the scheme's default.
final class NoDefaultBrowser extends DefaultBrowser {
  const NoDefaultBrowser();

  @override
  String toString() => 'NoDefaultBrowser';
}

/// No answer: neither tool is installed, one timed out, or what they said
/// could not be read. The caller launches anyway (and, with no browser
/// after all, waits until Cancel or its timeout, with the UI responsive).
final class DefaultBrowserUnknown extends DefaultBrowser {
  const DefaultBrowserUnknown(this.why);

  final String why;

  @override
  String toString() => 'DefaultBrowserUnknown($why)';
}

/// How one tool's run ended.
sealed class ToolRun {
  const ToolRun();
}

/// The tool is not installed (or could not be started).
final class ToolMissing extends ToolRun {
  const ToolMissing();
}

/// The tool did not finish in time; it was killed.
final class ToolTimedOut extends ToolRun {
  const ToolTimedOut();
}

/// The tool finished.
final class ToolFinished extends ToolRun {
  const ToolFinished(this.exitCode, this.stdout);

  final int exitCode;
  final String stdout;
}

/// Runs a tool, bounded by a timeout; the seam [lookUpDefaultBrowser] takes.
typedef ToolRunner =
    Future<ToolRun> Function(
      String executable,
      List<String> arguments,
      Duration timeout,
    );

/// How long one tool may take before the lookup gives up on it.
const defaultBrowserLookupTimeout = Duration(seconds: 2);

/// The default application for [scheme] (`http`, `https`), asked of
/// `gio mime x-scheme-handler/<scheme>`, or of
/// `xdg-mime query default x-scheme-handler/<scheme>` when `gio` is missing
/// or says something this does not recognise. Each runs in its own process,
/// in the C locale (so `gio` answers in English), for at most [timeout]. A timeout ends the
/// lookup as [DefaultBrowserUnknown] (no second tool: the desktop is not
/// answering). [run] is the process seam (tests).
Future<DefaultBrowser> lookUpDefaultBrowser(
  String scheme, {
  ToolRunner run = runTool,
  Duration timeout = defaultBrowserLookupTimeout,
}) async {
  final mimeType = 'x-scheme-handler/$scheme';
  final gio = await run('gio', ['mime', mimeType], timeout);
  switch (gio) {
    case ToolTimedOut():
      return const DefaultBrowserUnknown('gio timed out');
    case ToolFinished(exitCode: 0, :final stdout):
      final answer = parseGioMime(stdout);
      if (answer != null) return answer;
    case ToolFinished() || ToolMissing():
      break;
  }
  final xdg = await run('xdg-mime', ['query', 'default', mimeType], timeout);
  return switch (xdg) {
    ToolMissing() => const DefaultBrowserUnknown('no gio or xdg-mime'),
    ToolTimedOut() => const DefaultBrowserUnknown('xdg-mime timed out'),
    ToolFinished(exitCode: 0, :final stdout) => parseXdgMimeDefault(stdout),
    ToolFinished(:final exitCode) => DefaultBrowserUnknown(
      'xdg-mime exited $exitCode',
    ),
  };
}

final _gioDefault = RegExp(
  r'^Default application for .*: *(\S+\.desktop) *$',
  multiLine: true,
);
final _gioNone = RegExp(r'^No default applications for ', multiLine: true);

/// `gio mime x-scheme-handler/<scheme>`'s answer (C locale): the default
/// application, none, or null when the output is neither.
@visibleForTesting
DefaultBrowser? parseGioMime(String stdout) {
  final found = _gioDefault.firstMatch(stdout);
  if (found != null) return DefaultBrowserFound(found.group(1)!);
  if (_gioNone.hasMatch(stdout)) return const NoDefaultBrowser();
  return null;
}

/// `xdg-mime query default x-scheme-handler/<scheme>`'s answer: the desktop
/// entry it prints, or none when it prints nothing.
@visibleForTesting
DefaultBrowser parseXdgMimeDefault(String stdout) {
  final entry = stdout.trim();
  if (entry.isEmpty) return const NoDefaultBrowser();
  if (entry.contains('\n') || !entry.endsWith('.desktop')) {
    return const DefaultBrowserUnknown('xdg-mime printed something else');
  }
  return DefaultBrowserFound(entry);
}

/// [ToolRunner]'s real implementation: starts [executable] (from `PATH`) in
/// the C locale, closes its stdin, and waits at most [timeout] for it to
/// exit, killing it if it does not. Only its stdout is kept.
Future<ToolRun> runTool(
  String executable,
  List<String> arguments,
  Duration timeout,
) async {
  final Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      environment: const {'LC_ALL': 'C'},
    );
  } on ProcessException {
    return const ToolMissing();
  }
  unawaited(process.stdin.close());
  unawaited(process.stderr.drain<void>());
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  try {
    final exitCode = await process.exitCode.timeout(timeout);
    // Bounded too: a child the tool started could hold its stdout open.
    return ToolFinished(exitCode, await stdout.timeout(timeout));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return const ToolTimedOut();
  }
}
