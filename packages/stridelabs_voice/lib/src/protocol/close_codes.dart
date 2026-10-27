import '../transport/voice_transport.dart';

/// The close codes the SERVER sends on the relay socket (`PROTOCOL.md`
/// §4.1). A server close that is none of these is a drop.
abstract final class RelayCloseCode {
  /// After `end`: the provider finished, or did not within the end grace.
  static const done = 1000;

  /// The server is going away; reconnect.
  static const goingAway = 1001;

  /// The client broke a rule (pacing, idle, a bad frame, …).
  static const policy = 1008;

  /// The provider failed, or the server could not charge the budget
  /// (preceded by `error{provider}` or `error{internal}`).
  static const error = 1011;

  /// The session cap (15 minutes); a new session may continue.
  static const sessionLimit = 4000;

  /// A newer session of the same user took over.
  static const superseded = 4001;

  /// A budget window is spent (preceded by `error{limit,scope,resets_at}`).
  static const limit = 4002;
}

/// The close codes this CLIENT sends: why it is leaving (`PROTOCOL.md`
/// §4.2). Advisory: the server records the code and acts on none of them.
abstract final class RelayClientCloseCode {
  /// Mic off: after `end`, or before capture began (nothing was said, so
  /// there is nothing to end).
  static const micOff = 1000;

  /// Left the conversation (its screen went away, or a sign-out).
  static const leftConversation = 4100;

  /// The app was paused or backgrounded.
  static const paused = 4101;

  /// The idle teardown (the mic off, nothing busy, for the grace).
  static const idle = 4102;

  /// The transport was disposed or replaced — and a socket replaced by one
  /// at another sample rate.
  static const disposedOrReplaced = 4103;

  /// A client-side failure: the relay never said `ready`, capture failed or
  /// stopped while the mic was on, a start failed, a recorder that could not
  /// be stopped at mic-off, an encoding this client cannot speak. Also this
  /// side's close of a socket the relay (or the network) already ended,
  /// which sends nothing.
  static const clientFailure = 4104;

  /// The code a [VoiceTransport.disconnect] for [cause] closes with.
  static int forCause(VoiceDisconnectCause cause) => switch (cause) {
    VoiceDisconnectCause.failed => clientFailure,
    VoiceDisconnectCause.leftConversation => leftConversation,
    VoiceDisconnectCause.paused => paused,
    VoiceDisconnectCause.idle => idle,
    VoiceDisconnectCause.disposed => disposedOrReplaced,
  };
}
