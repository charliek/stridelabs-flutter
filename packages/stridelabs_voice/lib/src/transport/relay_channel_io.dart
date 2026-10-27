import 'dart:async';
import 'dart:io' show WebSocketException;
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'relay_channel.dart';

/// How long the TCP/TLS connect and the upgrade may take; the transport's
/// own `ready` deadline bounds the whole open.
const _connectTimeout = Duration(seconds: 10);

/// [RelayConnector] over `dart:io`: `IOWebSocketChannel.connect` with the
/// bearer in a header. A refused upgrade becomes [RelayUpgradeException] with
/// its HTTP status (dart:io reports it on `WebSocketException`).
Future<RelayChannel> connectRelay(
  Uri uri, {
  required Map<String, String> headers,
}) async {
  final channel = IOWebSocketChannel.connect(
    uri,
    headers: headers,
    connectTimeout: _connectTimeout,
  );
  try {
    await channel.ready;
  } catch (error) {
    // The failed channel's stream carries the same error: drain it, so it
    // is never reported as unhandled.
    channel.stream.listen(null, onError: (Object _) {});
    final cause = error is WebSocketChannelException ? error.inner : error;
    throw RelayUpgradeException(
      cause is WebSocketException ? cause.httpStatusCode : null,
    );
  }
  return _IoRelayChannel(channel);
}

class _IoRelayChannel implements RelayChannel {
  _IoRelayChannel(this._channel);

  final WebSocketChannel _channel;
  bool _closed = false;

  @override
  Stream<Object?> get messages => _channel.stream;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  void sendText(String text) => _add(text);

  @override
  void sendAudio(Uint8List frame) => _add(frame);

  /// A send on a socket the server already closed is dropped: its close is
  /// reported on [messages], which is what the transport acts on.
  void _add(Object data) {
    if (_closed) return;
    try {
      _channel.sink.add(data);
    } on StateError {
      // The sink closed under us.
    }
  }

  @override
  Future<void> close(int code) async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.sink.close(code).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Closing a socket that is already gone (or slow to answer) is not
      // an error worth surfacing: the session is over either way.
    }
  }
}
