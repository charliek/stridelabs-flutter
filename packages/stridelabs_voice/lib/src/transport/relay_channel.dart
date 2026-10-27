import 'dart:typed_data';

import 'relay_channel_stub.dart'
    if (dart.library.io) 'relay_channel_io.dart'
    as platform;

/// One `GET /voice/stream` WebSocket, as [RelayVoiceTransport] uses it.
/// Narrow on purpose, so tests drive the transport through a fake.
abstract interface class RelayChannel {
  /// Text frames as `String`, binary as `List<int>`. Ends when the socket
  /// closes, whichever side closed it.
  Stream<Object?> get messages;

  void sendText(String text);

  /// One frame of the session's audio (revision 1: s16le mono).
  void sendAudio(Uint8List frame);

  /// The code of the close frame the SERVER sent; null before that, or when
  /// the connection ended without one (or this side closed first).
  int? get closeCode;

  /// Closes this side with [code], which says why the client is leaving
  /// (`RelayClientCloseCode`: 1000 after `end`, 4100–4104 otherwise; the
  /// relay records it). Idempotent: the first close's code is the one sent.
  Future<void> close(int code);
}

/// The relay answered the upgrade with something other than `101`
/// ([statusCode]), or the upgrade failed without an HTTP answer (null: DNS,
/// TCP, TLS, a timeout, or no `dart:io`).
class RelayUpgradeException implements Exception {
  const RelayUpgradeException(this.statusCode);

  final int? statusCode;

  @override
  String toString() => 'RelayUpgradeException(${statusCode ?? 'no response'})';
}

/// Opens one relay socket to [uri] with [headers]; throws
/// [RelayUpgradeException] when the upgrade fails.
typedef RelayConnector =
    Future<RelayChannel> Function(
      Uri uri, {
      required Map<String, String> headers,
    });

/// The platform's connector: `dart:io` WebSockets (Android, macOS, Linux),
/// with a 10 s connect and a 2 s close. Web has none — a browser WebSocket
/// cannot carry an `Authorization` header — so there every upgrade fails as
/// unreachable (`RelayUpgradeException(null)`).
Future<RelayChannel> connectRelay(
  Uri uri, {
  required Map<String, String> headers,
}) => platform.connectRelay(uri, headers: headers);

/// `GET /voice/stream` under [baseUrl], as a WebSocket URI at [sampleRate]:
/// `http` becomes `ws` and `https` becomes `wss`; the host, port and any
/// base path are kept, and the query is `rate=<sampleRate>` alone.
Uri relayStreamUri(Uri baseUrl, int sampleRate) {
  final scheme = switch (baseUrl.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    final other => other,
  };
  final path = baseUrl.path.endsWith('/') ? baseUrl.path : '${baseUrl.path}/';
  return baseUrl.replace(
    scheme: scheme,
    path: '${path}voice/stream',
    queryParameters: {'rate': '$sampleRate'},
  );
}
