import 'dart:async';

import '../../stridelabs_voice.dart';

// The voice transport fake, lumen's (`test/fakes/transport_fakes.dart`) with
// D1 §8.4's changes: no audio mode (the package has none), `emit` takes a
// VoiceTransportEvent, `emitRemoteEnd` takes the spent limit, and the mic's
// outcome is `micResult`. Public through `testing.dart`.

/// Test double for [VoiceTransport]. Records call counts (every call the
/// app makes, connected or not), exposes the [events] and [remoteEnds]
/// streams tests can [emit] / [emitRemoteEnd] into, and honours the
/// interface's supersede contract: a `disconnect()` or `dispose()` while a
/// gated [connect] is pending makes it throw [VoiceConnectCancelled].
class FakeVoiceTransport implements VoiceTransport {
  final List<String> connectArgs = [];
  int get connectCount => connectArgs.length;
  int disconnectCount = 0;

  /// The cause of every [disconnect], in order.
  final List<VoiceDisconnectCause> disconnectCauses = [];
  int disposeCount = 0;
  int micEnableCount = 0;
  int micDisableCount = 0;
  bool _connectedFlag = false;
  int _gen = 0;
  final _eventCtrl = StreamController<VoiceTransportEvent>.broadcast();
  final _remoteEndCtrl = StreamController<VoiceEnd>.broadcast();

  /// Optional gate for `connect`; tests can hand a pending `Future` so the
  /// session never finishes attaching (stands in for a slow connect). Lets
  /// tests simulate disconnect/dispose mid-connect.
  Future<void>? connectFuture;

  /// Optional error to throw from `connect` (after the gate) so tests can
  /// simulate a connect failure and the follow-up retry path.
  Object? connectError;

  /// What [enableMicrophone] returns.
  MicEnableResult micResult = MicEnableResult.success;

  /// Optional gate for [enableMicrophone] (stands in for a slow OS
  /// permission prompt or socket open).
  Future<void>? micEnableFuture;

  /// Optional gate for [disableMicrophone].
  Future<void>? micDisableFuture;

  /// Optional error thrown by [disableMicrophone] (after the gate): the mic
  /// may still be live.
  Object? micDisableError;

  /// Optional error thrown by [disconnect] once the session is down (a
  /// release that failed).
  Object? disconnectError;

  @override
  bool get isConnected => _connectedFlag;

  @override
  Stream<VoiceTransportEvent> get events => _eventCtrl.stream;

  @override
  Stream<VoiceEnd> get remoteEnds => _remoteEndCtrl.stream;

  @override
  Future<void> connect(String conversationId) async {
    connectArgs.add(conversationId);
    if (_connectedFlag) return;
    final gen = ++_gen;
    if (connectFuture != null) await connectFuture!;
    if (gen != _gen) throw const VoiceConnectCancelled();
    if (connectError != null) throw connectError!;
    _connectedFlag = true;
  }

  @override
  Future<void> disconnect(VoiceDisconnectCause cause) async {
    disconnectCount++;
    disconnectCauses.add(cause);
    _gen++;
    _connectedFlag = false;
    if (disconnectError != null) throw disconnectError!;
  }

  @override
  Future<MicEnableResult> enableMicrophone() async {
    micEnableCount++;
    if (micEnableFuture != null) await micEnableFuture!;
    return micResult;
  }

  @override
  Future<void> disableMicrophone() async {
    micDisableCount++;
    if (micDisableFuture != null) await micDisableFuture!;
    if (micDisableError != null) throw micDisableError!;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    _gen++;
    _connectedFlag = false;
    if (!_eventCtrl.isClosed) await _eventCtrl.close();
    if (!_remoteEndCtrl.isClosed) await _remoteEndCtrl.close();
  }

  /// Emit [event] onto the [events] stream so tests can verify the app's
  /// mapping of the transport's events.
  void emit(VoiceTransportEvent event) => _eventCtrl.add(event);

  /// End the session remotely, as the contract orders it: [isConnected] is
  /// already false when [reason] (with its [notice] and spent [limit])
  /// reaches listeners.
  void emitRemoteEnd(
    VoiceEndReason reason, [
    VoiceEndNotice? notice,
    VoiceLimit? limit,
  ]) {
    _gen++;
    _connectedFlag = false;
    _remoteEndCtrl.add(VoiceEnd(reason, notice, limit));
  }
}
