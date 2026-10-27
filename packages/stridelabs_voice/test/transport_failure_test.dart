import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_voice/stridelabs_voice.dart';

import 'support/tts_server.dart';

/// [isTransportFailure]: the one failure the reply speaker sends a sentence
/// again on is the connection failing before any response HEADERS arrived
/// — known only at the transport ([ResponseHeadersWatch]). And
/// [responseHead]: what a response said (status, `Retry-After`, the
/// advertised text bound) even when its body broke.
void main() {
  group('through a real Dio over a watched fake transport', () {
    /// The failure `POST /voice/tts` ends in when the transport answers
    /// [answer].
    Future<Object> failureThrough(TtsAnswer answer) => failureOf(
      dioOver(
        ResponseHeadersWatch(ScriptedTtsServer([answer])),
      ).post<List<int>>(
        '/voice/tts',
        data: {'text': 'Hello.', 'voice': 'Jason'},
        options: Options(responseType: ResponseType.bytes),
      ),
    );

    test('refused, or reset before any header: a transport failure', () async {
      for (final MapEntry(key: what, value: answer) in _noHeaders.entries) {
        final error = await failureThrough(answer);
        expect(isTransportFailure(error), isTrue, reason: '$what: $error');
      }
    });

    for (final status in [200, 429, 503]) {
      test('a $status whose body broke after its headers: never', () async {
        final error = await failureThrough(_bodyLost(status));
        expect(error, isA<DioException>());
        expect(
          (error as DioException).response,
          isNull,
          reason: 'Dio drops the response: no evidence on its own',
        );
        expect(error.type, DioExceptionType.unknown);
        expect(error.error, isA<HttpException>());
        expect(isTransportFailure(error), isFalse);
      });
    }

    test('the same failures on an UNWATCHED transport: never', () async {
      for (final MapEntry(key: what, value: answer) in _noHeaders.entries) {
        final error = await failureOf(
          dioOver(ScriptedTtsServer([answer])).post<List<int>>('/voice/tts'),
        );
        expect(
          isTransportFailure(error),
          isFalse,
          reason: 'nothing says no headers came: $what',
        );
      }
    });

    test('a body broken after its headers keeps its status, Retry-After and '
        'advertised bound', () async {
      final error = await failureThrough(_bodyLost(503));
      expect(responseHead(error as DioException), (
        status: 503,
        retryAfter: '5',
        maxTextChars: 900,
      ));
    });
  });

  // Options a replay reuses carry the previous attempt's record; each
  // attempt starts from none.
  test("a reused request's truncated 503 reports its own head, never the "
      "previous attempt's Retry-After or bound", () async {
    final dio = dioOver(
      ResponseHeadersWatch(
        ScriptedTtsServer([
          TtsAnswer.status(401, retryAfter: '17', maxChars: '800'),
          TtsAnswer.status(503, bodyLost: true),
        ]),
      ),
    );
    final options = RequestOptions(
      baseUrl: 'https://api.example',
      path: '/voice/tts',
      method: 'POST',
      responseType: ResponseType.bytes,
    );
    final first = await failureOf(dio.fetch<List<int>>(options));
    expect(responseHead(first as DioException), (
      status: 401,
      retryAfter: '17',
      maxTextChars: 800,
    ));
    // The interceptor's replay: the SAME options, sent again.
    final second = await failureOf(dio.fetch<List<int>>(options));
    expect((second as DioException).response, isNull, reason: 'truncated');
    expect(responseHead(second), (
      status: 503,
      retryAfter: null,
      maxTextChars: null,
    ));
  });

  test('clearResponseHead forgets every recorded field', () {
    final options = RequestOptions(
      path: '/voice/tts',
      extra: {
        kResponseWatched: true,
        kResponseHeadersReceived: true,
        kResponseStatus: 503,
        kResponseRetryAfter: '5',
        kResponseMaxTextChars: 900,
        'app.binding': 1,
      },
    );
    clearResponseHead(options);
    expect(options.extra, {'app.binding': 1});
  });

  group('responseHead on a response Dio kept', () {
    DioException answered(Map<String, List<String>> headers) {
      final options = RequestOptions(path: '/voice/tts');
      return DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response<Object?>(
          requestOptions: options,
          statusCode: 429,
          headers: Headers.fromMap(headers),
        ),
      );
    }

    test('the advertised bound: one decimal integer of at least 600', () {
      for (final (values, bound) in <(List<String>?, int?)>[
        (null, null),
        (['600'], 600),
        (['1200'], 1200),
        ([' 900 '], 900),
        (['599'], null),
        (['0'], null),
        (['-900'], null),
        (['+900'], null),
        (['900.0'], null),
        (['9e2'], null),
        (['0x384'], null),
        ([''], null),
        (['twelve hundred'], null),
        (['99999999999999999999999'], null),
        (['900', '1200'], null),
      ]) {
        final head = responseHead(answered({kTtsMaxCharsHeader: ?values}));
        expect(head?.maxTextChars, bound, reason: '$values');
        expect(head?.status, 429);
      }
    });

    test('two Retry-After values: the first, as the watch keeps it', () {
      final head = responseHead(
        answered({
          'retry-after': ['120', '30'],
        }),
      );
      expect(head?.retryAfter, '120');
    });
  });

  group('the classifier, on failures built by hand', () {
    final watched = RequestOptions(
      path: '/voice/tts',
      extra: {kResponseWatched: true, kResponseHeadersReceived: false},
    );

    DioException failure(
      DioExceptionType type, {
      Object? cause,
      int? status,
      RequestOptions? options,
    }) => DioException(
      requestOptions: options ?? watched,
      type: type,
      error: cause,
      response: status == null
          ? null
          : Response<Object?>(
              requestOptions: options ?? watched,
              statusCode: status,
            ),
    );

    test('refused or reset before the headers: a transport failure', () {
      for (final error in [
        failure(
          DioExceptionType.connectionError,
          cause: const SocketException('Connection refused'),
        ),
        failure(DioExceptionType.connectionError),
        failure(
          DioExceptionType.unknown,
          cause: const SocketException('Connection reset by peer'),
        ),
        failure(
          DioExceptionType.unknown,
          cause: const HttpException(
            'Connection closed before full header was received',
          ),
        ),
      ]) {
        expect(isTransportFailure(error), isTrue, reason: '$error');
      }
    });

    test('a response, a slow server, a refusal unsent: never', () {
      for (final error in <Object>[
        for (final status in [401, 422, 429, 500, 502, 503])
          failure(DioExceptionType.badResponse, status: status),
        // A response that arrived, whatever the type says.
        failure(
          DioExceptionType.unknown,
          cause: const SocketException('reset'),
          status: 200,
        ),
        // Headers in, then the body lost.
        failure(
          DioExceptionType.unknown,
          cause: const HttpException('closed while receiving data'),
          options: RequestOptions(
            path: '/voice/tts',
            extra: {kResponseWatched: true, kResponseHeadersReceived: true},
          ),
        ),
        // Never watched (refused by an interceptor before the transport).
        failure(
          DioExceptionType.connectionError,
          options: RequestOptions(path: '/voice/tts'),
        ),
        failure(DioExceptionType.receiveTimeout),
        failure(DioExceptionType.sendTimeout),
        failure(DioExceptionType.connectionTimeout),
        failure(DioExceptionType.cancel),
        failure(DioExceptionType.badCertificate),
        // An app's interceptor refusing the request unsent (tapper's
        // session check, say).
        failure(DioExceptionType.unknown, cause: const _RefusedUnsent()),
        failure(DioExceptionType.unknown),
        failure(DioExceptionType.unknown, cause: const FormatException('x')),
        StateError('not a Dio failure'),
        'timeout',
      ]) {
        expect(isTransportFailure(error), isFalse, reason: '$error');
      }
    });
  });
}

/// An app's own refusal of a request before it was sent.
class _RefusedUnsent implements Exception {
  const _RefusedUnsent();
}

/// No response headers at all: refused, or a reset before any.
const _noHeaders = {
  'refused': TtsAnswer.refused(),
  'reset before any header': TtsAnswer.reset(),
};

/// [status] and its headers (`Retry-After: 5` unless a `200`, a bound of
/// 900), then a body that breaks after its first bytes.
TtsAnswer _bodyLost(int status) => TtsAnswer.status(
  status,
  retryAfter: status == 200 ? null : '5',
  maxChars: '900',
  bodyLost: true,
);
