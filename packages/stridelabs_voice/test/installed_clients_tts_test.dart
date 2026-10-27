import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'installed_clients/lumen_v2026_10_23/post_voice_tts.dart' as lumen;
import 'installed_clients/tapper_build_113/post_voice_tts.dart' as tapper;
import 'installed_clients/tapper_build_113/voice_limit.dart' as tapper;

/// The installed clients' speech requests against a revision-1 server (D1
/// §6.13, CR M-8): FROZEN, verbatim copies of lumen v2026.10.23's and
/// tapper build 113's top-level `postVoiceTts` (`test/installed_clients/`)
/// read a revision-1 answer — a `200` of `audio/mpeg` that also carries
/// `X-Voice-Tts-Max-Chars`, and a scoped `429` — as they read the old one.
/// An installed client cannot change, so an answer one of them reads
/// otherwise is a protocol break.
void main() {
  test('the frozen copies are the installed sources, byte for byte', () {
    for (final path in [
      'test/installed_clients/lumen_v2026_10_23/post_voice_tts.dart',
      'test/installed_clients/tapper_build_113/post_voice_tts.dart',
    ]) {
      final text = File(path).readAsStringSync();
      final recorded = RegExp(
        r'^// SHA-256: ([0-9a-f]{64})$',
        multiLine: true,
      ).firstMatch(text)!.group(1);
      const marker = '// ---- frozen below ----\n';
      final body = text.substring(text.indexOf(marker) + marker.length);
      expect(
        sha256.convert(utf8.encode(body)).toString(),
        recorded,
        reason: path,
      );
    }
  });

  final audio = Uint8List.fromList([0x49, 0x44, 0x33, 4, 5, 6]);

  test("both read a revision-1 200: the audio bytes, the new header "
      "ignored", () async {
    final server = _Revision1Server.audio(audio);
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example'))
      ..httpClientAdapter = server;
    expect(await lumen.postVoiceTts(dio, 'Hello.', voice: 'Hazel'), audio);
    expect(
      await tapper.postVoiceTts(
        dio,
        'Hello.',
        voice: 'Hazel',
        idempotencyKey: 'sentence-1',
        extra: {'tapper.session': 1},
      ),
      audio,
    );
    // Each sent what it always did: {text, voice}, and build 113 its key.
    expect(
      [for (final r in server.requests) r.data],
      [
        {'text': 'Hello.', 'voice': 'Hazel'},
        {'text': 'Hello.', 'voice': 'Hazel'},
      ],
    );
    expect(
      [for (final r in server.requests) r.headers['Idempotency-Key']],
      [null, 'sentence-1'],
    );
  });

  test('both read a revision-1 scoped 429 as before: its status and '
      "Retry-After, and build 113's VoiceLimit.fromBody its scope", () async {
    const body =
        '{"detail":"voice beta limit reached","scope":"user_month",'
        '"resets_at":"2026-11-01T00:00:00Z"}';
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example'))
      ..httpClientAdapter = _Revision1Server.limit(body);
    for (final send in <Future<Uint8List> Function()>[
      () => lumen.postVoiceTts(dio, 'Hello.', voice: 'Jason'),
      () => tapper.postVoiceTts(
        dio,
        'Hello.',
        voice: 'Jason',
        idempotencyKey: 'sentence-1',
      ),
    ]) {
      final error = await send().then<Object>(
        (_) => fail('it succeeded'),
        onError: (Object e) => e,
      );
      // What the installed speakers read: the status, `retry-after` (both
      // cooldowns) and, in build 113, the body (`_noticeLimit`).
      final response = (error as DioException).response!;
      expect(response.statusCode, 429);
      expect(response.headers.value('retry-after'), '86400');
      expect(
        tapper.VoiceLimit.fromBody(response.data),
        tapper.VoiceLimit(
          tapper.VoiceLimitScope.userMonth,
          DateTime.utc(2026, 11, 1),
        ),
      );
    }
  });
}

/// A transport answering `POST /voice/tts` as a revision-1 server does
/// (`PROTOCOL.md` §5.2): every response carries `X-Voice-Tts-Max-Chars`; a
/// `200` is `audio/mpeg` with `Cache-Control: no-store`; a `429` names its
/// scope.
class _Revision1Server implements HttpClientAdapter {
  _Revision1Server.audio(List<int> audio)
    : _status = 200,
      _body = audio,
      _headers = {
        Headers.contentTypeHeader: ['audio/mpeg'],
        'cache-control': ['no-store'],
      };

  _Revision1Server.limit(String body)
    : _status = 429,
      _body = utf8.encode(body),
      _headers = {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        'retry-after': ['86400'],
      };

  final int _status;
  final List<int> _body;
  final Map<String, List<String>> _headers;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(
      _body,
      _status,
      headers: {
        ..._headers,
        'x-voice-tts-max-chars': ['900'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
