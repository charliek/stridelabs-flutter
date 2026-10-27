import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

import 'support/tts_server.dart';

/// [RelayTtsClient]: `POST /voice/tts` (`PROTOCOL.md` §5) on an app's Dio,
/// over a fake transport that answers as a revision-1 server, and over a
/// real socket for the transport rule.
void main() {
  group('POST /voice/tts', () {
    test('sends {text, voice} and returns the audio bytes', () async {
      final server = ScriptedTtsServer([
        TtsAnswer.audio([0x49, 0x44, 0x33]),
      ]);
      final clip = await RelayTtsClient(
        dioOver(server),
      ).request('Hello.', voice: 'Hazel', idempotencyKey: 'k-1').send();
      expect(clip.bytes, Uint8List.fromList([0x49, 0x44, 0x33]));
      expect(clip.mediaType, 'audio/mpeg');
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://api.example/voice/tts');
      expect(request.data, {'text': 'Hello.', 'voice': 'Hazel'});
      expect(request.responseType, ResponseType.bytes);
    });

    test("sends the sentence's Idempotency-Key on every send", () async {
      final server = ScriptedTtsServer([
        TtsAnswer.status(503, retryAfter: '5'),
        TtsAnswer.audio(),
      ]);
      final request = RelayTtsClient(
        dioOver(server),
      ).request('Hello.', voice: 'Hazel', idempotencyKey: 'sentence-1');
      await failureOf(request.send());
      await request.send();
      expect(
        [for (final r in server.requests) r.headers[kIdempotencyKeyHeader]],
        ['sentence-1', 'sentence-1'],
      );
    });

    for (final status in [401, 413, 415, 422, 429, 502, 503]) {
      test('$status throws (the speaker goes text-only)', () async {
        final error = await failureOf(
          RelayTtsClient(
            dioOver(ScriptedTtsServer([TtsAnswer.status(status)])),
          ).request('Hello.', voice: 'Jason', idempotencyKey: 'k').send(),
        );
        expect(
          error,
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            status,
          ),
        );
      });
    }

    test("a 429's body reaches the speaker as JSON bytes it reads the scope "
        'from', () async {
      const body =
          '{"detail":"voice beta limit reached","scope":"user_day",'
          '"resets_at":"2026-10-25T00:00:00Z"}';
      final error = await failureOf(
        RelayTtsClient(
          dioOver(ScriptedTtsServer([TtsAnswer.status(429, body: body)])),
        ).request('Hello.', voice: 'Jason', idempotencyKey: 'k').send(),
      );
      expect(
        VoiceLimit.fromBody((error as DioException).response?.data),
        VoiceLimit(VoiceLimitScope.userDay, DateTime.utc(2026, 10, 25)),
      );
    });

    test('an empty 200 throws', () async {
      final error = await failureOf(
        RelayTtsClient(
          dioOver(ScriptedTtsServer([TtsAnswer.audio(const [])])),
        ).request('Hello.', voice: 'Jason', idempotencyKey: 'k').send(),
      );
      expect(
        error,
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      );
    });
  });

  group('the response watch', () {
    test(
      'RelayTtsClient installs ResponseHeadersWatch once on a reused Dio',
      () async {
        final server = ScriptedTtsServer([
          TtsAnswer.audio(),
          TtsAnswer.audio(),
        ]);
        final dio = dioOver(server);
        RelayTtsClient(dio);
        final watch = dio.httpClientAdapter;
        expect(watch, isA<ResponseHeadersWatch>());
        // A second client on the same Dio (a rebuilt provider) keeps it.
        final client = RelayTtsClient(dio);
        expect(dio.httpClientAdapter, same(watch));
        await client.request('Hi.', voice: 'Jason', idempotencyKey: 'k').send();
        // The transport saw the request once, watched once.
        expect(server.requests, hasLength(1));
        expect(server.requests.single.extra[kResponseWatched], isTrue);
      },
    );

    test('each send starts from fresh options: a refused retry never reports '
        "the first send's head", () async {
      final server = ScriptedTtsServer([
        TtsAnswer.status(401, retryAfter: '17', maxChars: '800'),
        TtsAnswer.refused(),
      ]);
      final request = RelayTtsClient(
        dioOver(server),
      ).request('Hi.', voice: 'Jason', idempotencyKey: 'k');
      final first = await failureOf(request.send()) as DioException;
      expect(responseHead(first), (
        status: 401,
        retryAfter: '17',
        maxTextChars: 800,
      ));
      final second = await failureOf(request.send()) as DioException;
      expect(responseHead(second), isNull);
      expect(isTransportFailure(second), isTrue);
      expect(
        second.requestOptions,
        isNot(same(first.requestOptions)),
        reason: 'new options per send',
      );
    });
  });

  group("the client's own status rule, whatever the app Dio's", () {
    // A refusal read as audio would skip the sentence (UnsupportedAudioType)
    // instead of cooling down, refreshing or noticing the limit.
    for (final (status, retryAfter) in [
      (401, null),
      (429, '120'),
      (503, '5'),
    ]) {
      test('a $status is a DioException with its response, under an app '
          'validateStatus that accepts everything', () async {
        final server = ScriptedTtsServer([
          TtsAnswer.status(status, retryAfter: retryAfter, maxChars: '900'),
        ]);
        final seenAsErrors = <int?>[];
        final dio =
            Dio(
                BaseOptions(
                  baseUrl: 'https://api.example',
                  validateStatus: (_) => true,
                ),
              )
              ..httpClientAdapter = server
              ..interceptors.add(
                InterceptorsWrapper(
                  onError: (error, handler) {
                    seenAsErrors.add(error.response?.statusCode);
                    handler.next(error);
                  },
                ),
              );
        final error = await failureOf(
          RelayTtsClient(
            dio,
          ).request('Hi.', voice: 'Jason', idempotencyKey: 'k').send(),
        );
        expect(
          error,
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badResponse)
              .having((e) => e.response?.statusCode, 'status', status),
        );
        expect(responseHead(error as DioException), (
          status: status,
          retryAfter: retryAfter,
          maxTextChars: 900,
        ));
        expect(seenAsErrors, [
          status,
        ], reason: "the app's interceptors see it as the error it is");
      });
    }

    test(
      'a refusal an app interceptor resolves is still a DioException',
      () async {
        final server = ScriptedTtsServer([
          TtsAnswer.status(503, retryAfter: '5'),
        ]);
        final dio = dioOver(server)
          ..interceptors.add(
            InterceptorsWrapper(
              onError: (error, handler) => handler.resolve(error.response!),
            ),
          );
        final error = await failureOf(
          RelayTtsClient(
            dio,
          ).request('Hi.', voice: 'Jason', idempotencyKey: 'k').send(),
        );
        expect(
          error,
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            503,
          ),
        );
        expect(responseHead(error as DioException)?.retryAfter, '5');
      },
    );
  });

  group('the extras', () {
    test('read once per request; every send carries them and the no-replay '
        'flag, to the app interceptor and the transport', () async {
      var reads = 0;
      final seenByInterceptor = <Map<String, Object?>>[];
      final server = ScriptedTtsServer([
        TtsAnswer.refused(),
        TtsAnswer.audio(),
        TtsAnswer.audio(),
      ]);
      final dio = dioOver(server)
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seenByInterceptor.add(Map.of(options.extra));
              handler.next(options);
            },
          ),
        );
      final client = RelayTtsClient(
        dio,
        extras: () => {'app.session': ++reads},
      );
      final first = client.request('One.', voice: 'Jason', idempotencyKey: 'a');
      expect(reads, 1);
      expect(first.extras, {'app.session': 1});
      await failureOf(first.send());
      await first.send();
      expect(reads, 1, reason: 'not read again by a send');
      final second = client.request(
        'Two.',
        voice: 'Jason',
        idempotencyKey: 'b',
      );
      await second.send();
      expect(reads, 2, reason: 'each sentence reads its own');
      expect([for (final e in seenByInterceptor) e['app.session']], [1, 1, 2]);
      for (final extra in [
        ...seenByInterceptor,
        for (final r in server.requests) r.extra,
      ]) {
        expect(extra[kNoAuthReplayExtra], isTrue);
      }
      expect(
        () => first.extras['app.session'] = 9,
        throwsUnsupportedError,
        reason: 'the sentence keeps the values it was made with',
      );
    });

    test('none given: the flag alone', () async {
      final server = ScriptedTtsServer([TtsAnswer.audio()]);
      final request = RelayTtsClient(
        dioOver(server),
      ).request('One.', voice: 'Jason', idempotencyKey: 'a');
      expect(request.extras, isEmpty);
      await request.send();
      expect(server.requests.single.extra[kNoAuthReplayExtra], isTrue);
    });
  });

  group('typed audio', () {
    for (final contentType in [
      'audio/mpeg',
      'Audio/MPEG',
      'audio/mpeg; charset=binary',
    ]) {
      test('a 200 of "$contentType" is an audio/mpeg clip', () async {
        final clip = await RelayTtsClient(
          dioOver(ScriptedTtsServer([TtsAnswer.audio(kAudio, contentType)])),
        ).request('Hi.', voice: 'Jason', idempotencyKey: 'k').send();
        expect(clip.mediaType, 'audio/mpeg');
        expect(clip.bytes, kAudio);
      });
    }

    for (final (contentType, reported) in <(List<String>?, String?)>[
      (['audio/wav'], 'audio/wav'),
      (['Audio/WAV; codecs=1'], 'audio/wav'),
      (['application/json'], 'application/json'),
      (null, null),
      (['audio/mpeg', 'audio/mpeg'], null),
    ]) {
      test(
        'a 200 of $contentType is refused as UnsupportedAudioType',
        () async {
          final error = await failureOf(
            RelayTtsClient(
              dioOver(
                ScriptedTtsServer([
                  TtsAnswer(200, body: kAudio, contentTypes: contentType),
                ]),
              ),
            ).request('Hi.', voice: 'Jason', idempotencyKey: 'k').send(),
          );
          expect(
            error,
            isA<UnsupportedAudioType>().having(
              (e) => e.mediaType,
              'mediaType',
              reported,
            ),
          );
        },
      );
    }
  });

  group('the advertised text bound', () {
    for (final (header, bound) in <(String?, int?)>[
      (null, null),
      ('600', 600),
      ('1200', 1200),
      ('599', null),
      ('-1200', null),
      ('1200.5', null),
      ('lots', null),
    ]) {
      test('X-Voice-Tts-Max-Chars $header: $bound on the clip, the refusal '
          'and the failure', () async {
        final client = RelayTtsClient(
          dioOver(
            ScriptedTtsServer([
              TtsAnswer.audio(kAudio, 'audio/mpeg', header),
              TtsAnswer(
                200,
                body: kAudio,
                contentTypes: ['audio/wav'],
                maxChars: header,
              ),
              TtsAnswer.status(429, retryAfter: '9', maxChars: header),
            ]),
          ),
        );
        final request = client.request(
          'Hi.',
          voice: 'Jason',
          idempotencyKey: 'k',
        );
        expect((await request.send()).maxTextChars, bound);
        final refused = await failureOf(request.send());
        expect((refused as UnsupportedAudioType).maxTextChars, bound);
        final failed = await failureOf(request.send());
        expect(responseHead(failed as DioException)?.maxTextChars, bound);
      });
    }
  });

  group('through a real socket', () {
    late HttpServer server;
    late Dio dio;
    late void Function(HttpRequest request) answer;
    late List<String?> keys;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      keys = [];
      server.listen((request) {
        keys.add(request.headers.value(kIdempotencyKeyHeader));
        answer(request);
      });
      dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
    });

    tearDown(() => server.close(force: true));

    test('a revision-1 200 is the clip and its bound', () async {
      answer = (request) async {
        await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..headers.set(kTtsMaxCharsHeader, '900')
          ..headers.set('cache-control', 'no-store')
          ..add(kAudio);
        await request.response.close();
      };
      final clip = await RelayTtsClient(
        dio,
      ).request('Hi.', voice: 'Jason', idempotencyKey: 'k-9').send();
      expect(clip.bytes, kAudio);
      expect(clip.mediaType, 'audio/mpeg');
      expect(clip.maxTextChars, 900);
      expect(keys, ['k-9']);
    });

    test('a broken body keeps its Retry-After through a real Dio', () async {
      answer = (request) async {
        await utf8.decoder.bind(request).join();
        // The head and a first chunk, then the connection is cut.
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 503 Service Unavailable\r\n'
          'content-type: application/json\r\n'
          'retry-after: 5\r\n'
          '$kTtsMaxCharsHeader: 900\r\n'
          'content-length: 100\r\n'
          '\r\n'
          '{"detail":',
        );
        await socket.flush();
        socket.destroy();
      };
      final error = await failureOf(
        RelayTtsClient(
          dio,
        ).request('Hi.', voice: 'Jason', idempotencyKey: 'k').send(),
      );
      expect((error as DioException).response, isNull);
      expect(responseHead(error), (
        status: 503,
        retryAfter: '5',
        maxTextChars: 900,
      ));
      expect(isTransportFailure(error), isFalse);
    });

    test('a connection closed before any header is a transport failure '
        'through a real Dio', () async {
      answer = (request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      };
      final error = await failureOf(
        RelayTtsClient(
          dio,
        ).request('Hi.', voice: 'Jason', idempotencyKey: 'k').send(),
      );
      expect(responseHead(error as DioException), isNull);
      expect(isTransportFailure(error), isTrue, reason: '$error');
    });
  });
}

final kAudio = Uint8List.fromList([0x49, 0x44, 0x33, 7, 8]);
