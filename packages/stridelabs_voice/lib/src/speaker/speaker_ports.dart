import '../playback/reply_audio_player.dart';
import '../playback/reply_clip_files.dart';
import 'reply_tts.dart';
import 'tts_auth.dart';

/// One event of a turn's reply stream, as the reply speaker reads it. The
/// app maps its own events (those with a turn id) onto these, in order.
sealed class SpeakerTurnEvent {
  const SpeakerTurnEvent(this.turnId);

  final String turnId;
}

/// The reply so far within one model response: CUMULATIVE (it restarts
/// with each response after a tool round).
final class SpeakerPartial extends SpeakerTurnEvent {
  const SpeakerPartial(super.turnId, this.cumulativeText);

  final String cumulativeText;
}

/// The reply's final text.
final class SpeakerFinal extends SpeakerTurnEvent {
  const SpeakerFinal(super.turnId, this.text);

  final String text;
}

/// A tool round ran (the app's tool card): the current model response is
/// over.
final class SpeakerToolBoundary extends SpeakerTurnEvent {
  const SpeakerToolBoundary(super.turnId);
}

/// The turn was committed.
final class SpeakerTurnCommitted extends SpeakerTurnEvent {
  const SpeakerTurnCommitted(super.turnId);
}

/// The turn's stream is done.
final class SpeakerTurnDone extends SpeakerTurnEvent {
  const SpeakerTurnDone(super.turnId);
}

/// The turn failed: it shows no reply, and none is spoken.
final class SpeakerTurnFailed extends SpeakerTurnEvent {
  const SpeakerTurnFailed(super.turnId);
}

/// Any other event of the turn (a state change, say): the turn is seen.
final class SpeakerTurnSeen extends SpeakerTurnEvent {
  const SpeakerTurnSeen(super.turnId);
}

/// A change of the app's audio-response setting.
enum SpeechModeChange {
  /// Speech is never wanted now: the reply playing stops, whatever it is.
  off,

  /// Something eligibility reads changed: the reply playing is checked
  /// again ([SpeakerPorts.isEligible]) and stops if it no longer is.
  changed,
}

/// Everything the reply speaker reads from the app: its event streams, its
/// settings and its seams, each a stream or a function read when needed (so
/// a change applies at once). The speaker writes nothing back but its own
/// `ReplySpeaker.playing` and `ReplySpeaker.limitNotices`, which the app
/// mirrors.
class SpeakerPorts {
  const SpeakerPorts({
    required this.turnEvents,
    required this.cancelledTurns,
    required this.speechModeChanges,
    required this.userSpeechStarts,
    required this.micOff,
    required this.clipFiles,
    required this.activeTurnId,
    required this.isEligible,
    required this.interruptByVoice,
    required this.tts,
    required this.voice,
    required this.playerFactory,
    required this.captureLive,
    this.ttsAuth,
  });

  /// Every event of every turn, in order (after the app's display handled
  /// it).
  final Stream<SpeakerTurnEvent> turnEvents;

  /// Turns the app's coordinator cancelled (preempted, reset, a
  /// conversation switch): their audio stops at once.
  final Stream<String> cancelledTurns;

  /// The audio-response setting changed.
  final Stream<SpeechModeChange> speechModeChanges;

  /// The user started speaking (a barge-in, when [interruptByVoice]).
  final Stream<void> userSpeechStarts;

  /// The mic went off: the focus a reply kept for the live capture goes
  /// back.
  final Stream<void> micOff;

  /// Where each sentence's audio is kept while it plays.
  final ReplyClipFiles clipFiles;

  /// The turn the app's coordinator is running now, if any: a pause, a
  /// leave or a teardown silences it even before it sent anything.
  final String? Function() activeTurnId;

  /// Whether [turnId]'s reply is spoken now: the app's coordinator started
  /// it, and its audio mode (and, say, its platform) speaks it. Read for
  /// every event.
  final bool Function(String turnId) isEligible;

  /// "Interrupt by voice": the user's speech stops the reply.
  final bool Function() interruptByVoice;

  /// The sentences' speech.
  final ReplyTts tts;

  /// The voice to speak in: an id from the APP's catalog.
  final String Function() voice;

  /// Builds the player, on the speaker's first clip.
  final ReplyAudioPlayer Function() playerFactory;

  /// Whether the mic's capture is live (the player then keeps what of the
  /// audio session the capture needs, `ReplyAudioPlayer.release`).
  final bool Function() captureLive;

  /// The token handling for TTS. With null the speaker never refreshes: no
  /// refresh ahead, and a `401` gives the sentence up. An app that exempts
  /// TTS from its interceptor's replay (`kNoAuthReplayExtra`) should supply
  /// a [TtsAuth], so a `401` still leads to a refresh.
  final TtsAuth? ttsAuth;
}
