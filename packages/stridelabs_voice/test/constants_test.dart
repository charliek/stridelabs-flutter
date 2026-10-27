import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

/// The protocol's fixed values (`PROTOCOL.md`, revision 1) and the two rules
/// derived from them.
void main() {
  test("revision 1's defaults and limits", () {
    expect(kRelayEndFrame, '{"type":"end"}');
    expect(kDefaultRelaySampleRates, [24000, 16000]);
    expect(kDefaultRelayLeadMs, 5000);
    expect(kMinClientLead, const Duration(milliseconds: 500));
    expect(kPcmS16le, 'pcm_s16le');
    expect(kTtsMinTextChars, 600);
    expect(kTtsMaxCharsHeader, 'x-voice-tts-max-chars');
    expect(kIdempotencyKeyHeader, 'Idempotency-Key');
    expect(kAllowedAudioTypes, {'audio/mpeg': '.mp3'});
  });

  test("the client's lead is a second under the server's, at least 500 ms", () {
    for (final (leadMs, lead) in [
      (null, 4000), // an older server: lead_ms 5000
      (5000, 4000),
      (8000, 7000),
      (1600, 600),
      (1500, 500),
      (1200, 500),
      (1, 500),
    ]) {
      expect(
        clientLeadFor(leadMs),
        Duration(milliseconds: lead),
        reason: '$leadMs',
      );
    }
  });

  test('an allowed media type is read without its parameters, any case', () {
    for (final (contentType, type) in [
      ('audio/mpeg', 'audio/mpeg'),
      ('Audio/MPEG', 'audio/mpeg'),
      ('audio/mpeg; charset=binary', 'audio/mpeg'),
      (' audio/mpeg ;q=1', 'audio/mpeg'),
      ('audio/wav', null),
      ('audio/mpeg3', null),
      ('application/json', null),
      ('', null),
      (null, null),
    ]) {
      expect(allowedMediaType(contentType), type, reason: '$contentType');
    }
  });
}
