import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart' show fail;
import 'package:stridelabs_voice/stridelabs_voice.dart';

import 'speaker_fakes.dart' show kFakeMp3;

// A scripted `POST /voice/tts` transport under a real Dio, shared by the
// client's, the transport rule's and the speaker's tests. Test-only: it
// stays out of `testing.dart`.

/// A Dio on `https://api.example` over [adapter].
Dio dioOver(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.example'))
      ..httpClientAdapter = adapter;

/// What [future] failed with; the test fails when it succeeded.
Future<Object> failureOf(Future<Object?> future) =>
    future.then<Object>((_) => fail('it succeeded'), onError: (Object e) => e);

enum _Failure { refused, reset }

/// One scripted answer of [ScriptedTtsServer].
class TtsAnswer {
  const TtsAnswer(
    this.status, {
    this.body = const [],
    this.contentTypes,
    this.retryAfter,
    this.maxChars,
    this.bodyLost = false,
  }) : _failure = null;

  const TtsAnswer._fails(this._failure)
    : status = 0,
      body = const [],
      contentTypes = null,
      retryAfter = null,
      maxChars = null,
      bodyLost = false;

  /// A `200` of [contentType] carrying [body], advertising [maxChars].
  factory TtsAnswer.audio([
    List<int> body = kFakeMp3,
    String contentType = 'audio/mpeg',
    String? maxChars,
  ]) => TtsAnswer(
    200,
    body: body,
    contentTypes: [contentType],
    maxChars: maxChars,
  );

  /// A refusal with a JSON [body] (`{"detail":"x"}` unless given).
  factory TtsAnswer.status(
    int status, {
    String? body,
    String? retryAfter,
    String? maxChars,
    bool bodyLost = false,
  }) => TtsAnswer(
    status,
    body: utf8.encode(body ?? '{"detail":"x"}'),
    contentTypes: [Headers.jsonContentType],
    retryAfter: retryAfter,
    maxChars: maxChars,
    bodyLost: bodyLost,
  );

  /// No connection.
  const TtsAnswer.refused() : this._fails(_Failure.refused);

  /// The connection reset before any header.
  const TtsAnswer.reset() : this._fails(_Failure.reset);

  final int status;
  final List<int> body;
  final List<String>? contentTypes;
  final String? retryAfter;
  final String? maxChars;

  /// The status line and headers arrive, then the body breaks after its
  /// first bytes.
  final bool bodyLost;
  final _Failure? _failure;
}

/// A transport answering `POST /voice/tts` as a revision-1 server, one
/// scripted [TtsAnswer] per request; records each request's options.
class ScriptedTtsServer implements HttpClientAdapter {
  ScriptedTtsServer(this.answers);

  final List<TtsAnswer> answers;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final answer = answers[requests.length - 1];
    switch (answer._failure) {
      case _Failure.refused:
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Connection refused',
          error: const SocketException('Connection refused'),
        );
      case _Failure.reset:
        throw const SocketException('Connection reset by peer');
      case null:
    }
    final headers = {
      Headers.contentTypeHeader: ?answer.contentTypes,
      if (answer.retryAfter case final retryAfter?) 'retry-after': [retryAfter],
      if (answer.maxChars case final maxChars?) kTtsMaxCharsHeader: [maxChars],
    };
    if (!answer.bodyLost) {
      return ResponseBody.fromBytes(
        answer.body,
        answer.status,
        headers: headers,
      );
    }
    final body = StreamController<Uint8List>()
      ..add(Uint8List.fromList(answer.body))
      ..addError(const HttpException('Connection closed while receiving data'));
    unawaited(body.close());
    return ResponseBody(body.stream, answer.status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}
