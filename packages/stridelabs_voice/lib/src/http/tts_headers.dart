import '../protocol/constants.dart';

/// The text bound a TTS response advertised (`PROTOCOL.md` §5.2, §5.3): its
/// `X-Voice-Tts-Max-Chars` [values] when there is exactly one, a decimal
/// integer of at least [kTtsMinTextChars]; null for anything else (no
/// header, two, a sign, a fraction, an out-of-range number, a value under
/// 600), which a client reads as 600.
///
/// Package-internal (not exported): the TTS client and the response watch
/// read the header through this one rule.
int? ttsMaxCharsOf(List<String>? values) {
  if (values == null || values.length != 1) return null;
  final text = values.single.trim();
  if (!_decimal.hasMatch(text)) return null;
  final value = int.tryParse(text);
  return value != null && value >= kTtsMinTextChars ? value : null;
}

final _decimal = RegExp(r'^[0-9]+$');

/// The media type of a `Content-Type` [value]: its parameters dropped,
/// trimmed and lower-cased; null when there is none.
String? mediaTypeOf(String? value) {
  final type = value?.split(';').first.trim().toLowerCase();
  return type == null || type.isEmpty ? null : type;
}
