import 'package:flutter/foundation.dart' show immutable;

import '../protocol/voice_limit.dart';

/// What a [VoiceTransport] tells the app while a session runs. The app maps
/// each to its own state and display events.
sealed class VoiceTransportEvent {
  const VoiceTransportEvent();
}

/// The user is speaking ([listening] true, at a heard segment's
/// `speech_start`) or the segment closed (false: its `end_of_turn`, a
/// half-duplex cut, mic-off, the session's end).
final class VoiceListening extends VoiceTransportEvent {
  const VoiceListening(this.listening);

  final bool listening;

  @override
  bool operator ==(Object other) =>
      other is VoiceListening && other.listening == listening;

  @override
  int get hashCode => Object.hash(VoiceListening, listening);

  @override
  String toString() => 'VoiceListening($listening)';
}

/// The text heard but not yet posted (empty once posted): the trailing
/// transcript bubble.
final class VoicePendingTranscript extends VoiceTransportEvent {
  const VoicePendingTranscript(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      other is VoicePendingTranscript && other.text == text;

  @override
  int get hashCode => Object.hash(VoicePendingTranscript, text);

  @override
  String toString() => 'VoicePendingTranscript("$text")';
}

/// Outcome of [VoiceTransport.enableMicrophone] — typed across the
/// transport/app boundary so consumers can `switch` on a closed set without
/// comparing magic strings.
enum MicEnableResult {
  /// The mic is on and its audio is being sent.
  success,

  /// There is no voice session, or it ended while the mic was being enabled
  /// (caller must `connect()` first).
  notConnected,

  /// The OS denied mic permission. Recovery is a Settings trip.
  denied,

  /// Permission state we don't recognize / unavailable platform channel /
  /// no rate the device can capture — caller should surface a generic error
  /// and log details.
  unavailable,

  /// The attempt was superseded by a teardown (mic-off, disconnect, dispose)
  /// before it finished. Not an error the user needs to hear about.
  cancelled,
}

/// Why a voice session ended without the app calling
/// [VoiceTransport.disconnect]. Diagnostic: the first cause wins.
enum VoiceEndReason {
  /// The connection was lost (network, a socket error, no `ready`).
  dropped,

  /// The server closed or refused the session (a close code, a refused
  /// upgrade, a session this client cannot speak).
  closedByServer,
}

/// What the user should be told about a session the server ended or refused,
/// beyond its [VoiceEndReason] (the relay's statuses and close codes).
enum VoiceEndNotice {
  /// Voice is not served here (404), not configured (503), or speaks an
  /// encoding this client cannot.
  unavailable,

  /// A voice budget is spent (429, or close 4002); [VoiceEnd.limit] says
  /// which when the relay said so.
  limitReached,

  /// The session reached its length cap (close 4000).
  sessionLimit,

  /// A newer session for the same user took over (close 4001). Nothing to
  /// say: the user started it.
  superseded,
}

/// One remote end: why, and what the user should hear about it (null for the
/// generic "voice disconnected").
@immutable
class VoiceEnd {
  const VoiceEnd(this.reason, [this.notice, this.limit]);

  final VoiceEndReason reason;
  final VoiceEndNotice? notice;

  /// A [VoiceEndNotice.limitReached]'s spent allowance, when the relay's
  /// `limit` event named it: never for a refused upgrade (the connector
  /// exposes only its status) or an older server.
  final VoiceLimit? limit;

  @override
  bool operator ==(Object other) =>
      other is VoiceEnd &&
      other.reason == reason &&
      other.notice == notice &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(reason, notice, limit);

  @override
  String toString() =>
      'VoiceEnd(${reason.name}'
      '${notice == null ? '' : ', ${notice!.name}'}'
      '${limit == null ? '' : ', $limit'})';
}

/// Why the app ends a voice session ([VoiceTransport.disconnect]). The relay
/// transport closes its socket with each one's code
/// (`RelayClientCloseCode.forCause`, `PROTOCOL.md` §4.2), which the server
/// records and acts on in no way.
enum VoiceDisconnectCause {
  /// A failure on this side: a start that did not end with the mic on, or a
  /// mic that could not be turned off. (A plain mic-off is not a disconnect:
  /// the transport sends `end` and closes on its own, 1000.)
  failed,

  /// The user left the conversation: its screen went away, or they signed
  /// out (which drops it).
  leftConversation,

  /// The app was paused or backgrounded (Android/iOS).
  paused,

  /// The session sat idle (the mic off, nothing busy) for the grace.
  idle,

  /// The transport is being disposed or replaced ([VoiceTransport.dispose]).
  disposed,
}

/// Thrown by [VoiceTransport.connect] when a `disconnect()` or `dispose()`
/// supersedes it; the transport is left disconnected.
class VoiceConnectCancelled implements Exception {
  const VoiceConnectCancelled();

  @override
  String toString() => 'VoiceConnectCancelled';
}

/// One voice session's mechanics. Lifecycle POLICY (when to connect, when to
/// tear down) is the app's; an implementation only knows how to open, run
/// and close a session.
abstract interface class VoiceTransport {
  /// Transport → app events. Broadcast; lives as long as the transport.
  Stream<VoiceTransportEvent> get events;

  /// The session ended without the app calling [disconnect]. Broadcast. At
  /// most one per session, only for a session that was established (if it
  /// ends before [connect] returns, that connect throws
  /// [VoiceConnectCancelled]), and emitted once the session is over
  /// ([isConnected] is false); releasing its resources may still be
  /// completing — the next [enableMicrophone] waits for that.
  Stream<VoiceEnd> get remoteEnds;

  bool get isConnected;

  /// Connects for [conversationId]; the implementation obtains its own
  /// credentials. No-op when already connected; the caller single-flights.
  /// Throws [VoiceConnectCancelled] if [disconnect] or [dispose] supersedes
  /// it, or the session ends before it returns ([isConnected] is false).
  Future<void> connect(String conversationId);

  /// Ends the session for [cause] (the relay socket's close code).
  /// Idempotent: a session already ending keeps the first cause's code.
  /// Never emits on [remoteEnds]; supersedes an in-flight [connect].
  Future<void> disconnect(VoiceDisconnectCause cause);

  /// [MicEnableResult.notConnected] if there is no session or it ended
  /// meanwhile.
  Future<MicEnableResult> enableMicrophone();

  /// Mic-off. Throws the recorder's error when it could not be stopped,
  /// after the session has ended as a client-side failure (4104, no `end`;
  /// what was transcribed is flushed): the caller then ends the voice session
  /// too (as [VoiceDisconnectCause.failed]).
  Future<void> disableMicrophone();

  /// Supersedes in-flight work, releases everything (as a [disconnect] for
  /// [VoiceDisconnectCause.disposed]), then closes the streams. Safe to call
  /// twice.
  Future<void> dispose();
}
