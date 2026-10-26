/// The app's token handling for the reply speaker's TTS requests (optional:
/// `SpeakerPorts.ttsAuth`). TTS is exempt from an app interceptor's generic
/// `401` replay and refresh (`kNoAuthReplayExtra`), so the speaker owns
/// both: it refreshes ahead of a sentence whose token is about to expire,
/// and after a `401` sends the sentence once more, under the same
/// `Idempotency-Key` (`PROTOCOL.md` §5.3). A `503` never refreshes,
/// whatever its body.
abstract interface class TtsAuth {
  /// Refreshes when the token is expired or expires within 30 s (slauth's
  /// fixed buffer), unless the app's own refresh retry is pending (then it
  /// starts none and answers true: the send goes out with the held token,
  /// and a real expiry comes back as a `401`). False: no unexpired token is
  /// held afterwards (signed out, or the refresh failed and the old token
  /// has expired). Never throws.
  Future<bool> refreshAhead();

  /// After a `401`, for the sentence whose request carried [extras]: true
  /// only when a refresh SUCCEEDED (or the held token is already newer than
  /// the one the sentence carried). Refreshes only the session the sentence
  /// was sent under; starts no refresh while the app's own refresh retry is
  /// pending (answers false). Single-flight with the app's other refreshes.
  /// Never throws.
  Future<bool> refreshAfterUnauthorized(Map<String, Object?> extras);
}
