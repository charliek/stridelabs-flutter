import 'dart:typed_data';

/// Speech for the sentences of a reply (`POST /voice/tts`, `PROTOCOL.md`
/// §5). [RelayTtsClient] is the implementation over an app's Dio.
abstract interface class ReplyTts {
  /// One sentence's speech request, made NOW: its extras are read now, once
  /// ([ReplyTtsRequest.extras]), and every attempt it sends carries
  /// [idempotencyKey], so the server charges the sentence once however often
  /// it is sent. [voice] is an id from the APP's voice catalog (§6), never a
  /// provider's name.
  ReplyTtsRequest request(
    String text, {
    required String voice,
    required String idempotencyKey,
  });
}

/// One sentence's speech ([ReplyTts.request]).
abstract interface class ReplyTtsRequest {
  /// The app's extras, evaluated once when the request was made: every
  /// attempt carries these values (tapper's session binding rides them), and
  /// a `TtsAuth` refresh after a `401` is scoped by them.
  Map<String, Object?> get extras;

  /// One attempt: the sentence's audio. Throws on anything else: a
  /// [UnsupportedAudioType] for a `200` in a type this client does not play,
  /// a `DioException` for a refusal or a network failure. May be called
  /// twice (the reply speaker's one retry), with the same key and extras.
  Future<ReplyClip> send();
}

/// One sentence's audio: its bytes, their media type (one of
/// `kAllowedAudioTypes`), and the text bound the response advertised.
class ReplyClip {
  const ReplyClip(this.bytes, this.mediaType, {this.maxTextChars});

  final Uint8List bytes;

  /// The response's media type, parameters dropped and lower-cased
  /// (`audio/mpeg`).
  final String mediaType;

  /// The response's `X-Voice-Tts-Max-Chars` when it was one decimal integer
  /// of at least 600; null otherwise (a client then reads 600).
  final int? maxTextChars;
}

/// A `200` whose audio is in a type this client does not play
/// (`PROTOCOL.md` §5.3, typed audio): the reply speaker skips that sentence
/// and the reply goes on.
class UnsupportedAudioType implements Exception {
  const UnsupportedAudioType(this.mediaType, {this.maxTextChars});

  /// The response's media type (parameters dropped, lower-cased); null when
  /// it named none.
  final String? mediaType;

  /// As [ReplyClip.maxTextChars]: the refusal is a response too.
  final int? maxTextChars;

  @override
  String toString() =>
      'UnsupportedAudioType: ${mediaType ?? 'no media type'} is not a '
      'type this client plays';
}
