import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../protocol/constants.dart';
import 'transport_failure_stub.dart'
    if (dart.library.io) 'transport_failure_io.dart'
    as platform;
import 'tts_headers.dart';

/// [RequestOptions.extra]: `true` once [ResponseHeadersWatch] has handed the
/// request to the transport, so whether its response headers arrived is
/// known ([kResponseHeadersReceived]).
const String kResponseWatched = 'stridelabs_voice.responseWatched';

/// [RequestOptions.extra]: whether the response's status line and headers
/// arrived (set by [ResponseHeadersWatch]: `false` when the request goes
/// out, `true` once the transport returns the response).
const String kResponseHeadersReceived =
    'stridelabs_voice.responseHeadersReceived';

/// [RequestOptions.extra]: the response's status code, kept once its
/// headers arrived ([ResponseHeadersWatch]).
const String kResponseStatus = 'stridelabs_voice.responseStatus';

/// [RequestOptions.extra]: the response's `Retry-After` header (its first
/// value; absent when it had none), kept once its headers arrived.
const String kResponseRetryAfter = 'stridelabs_voice.responseRetryAfter';

/// [RequestOptions.extra]: the text bound the response advertised
/// (`X-Voice-Tts-Max-Chars`, read as `PROTOCOL.md` §5.3 says: absent unless
/// one decimal integer of at least 600), kept once its headers arrived.
const String kResponseMaxTextChars = 'stridelabs_voice.responseMaxTextChars';

/// An [HttpClientAdapter] that records, on each request's
/// [RequestOptions.extra], whether the response's headers arrived — and,
/// once they did, its status, its `Retry-After` and its advertised text
/// bound ([responseHead]), which a failure while reading the body would
/// otherwise lose.
///
/// Dio's own failure says nothing reliable about it: a body that breaks
/// while it is being read (a truncated `200`, a `503` whose connection
/// drops mid-body) fails as [DioExceptionType.unknown] with NO
/// [DioException.response], exactly like a connection reset before any
/// answer. The adapter's `fetch` returns when the status line and headers
/// are in (the body still streaming), so it is the boundary that knows.
///
/// `RelayTtsClient` installs one on the Dio it is given (once: a Dio whose
/// adapter already is one keeps it).
class ResponseHeadersWatch implements HttpClientAdapter {
  ResponseHeadersWatch(this._inner);

  final HttpClientAdapter _inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Every field is this attempt's: options a replay reuses must not carry
    // the previous attempt's status or `Retry-After`.
    clearResponseHead(options);
    options.extra[kResponseWatched] = true;
    options.extra[kResponseHeadersReceived] = false;
    final response = await _inner.fetch(options, requestStream, cancelFuture);
    options.extra[kResponseHeadersReceived] = true;
    options.extra[kResponseStatus] = response.statusCode;
    for (final MapEntry(:key, :value) in response.headers.entries) {
      switch (key.toLowerCase()) {
        case 'retry-after' when value.isNotEmpty:
          options.extra[kResponseRetryAfter] = value.first;
        case kTtsMaxCharsHeader:
          final bound = ttsMaxCharsOf(value);
          if (bound != null) options.extra[kResponseMaxTextChars] = bound;
      }
    }
    return response;
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Forgets what [ResponseHeadersWatch] recorded on [options] (whether it
/// watched them, and the response's headers, status, `Retry-After` and text
/// bound). Called as each attempt starts — by `RelayTtsClient` before each
/// send, at the head of an app's interceptor chain, and again at the
/// transport — so a replay that reuses the options and is refused before it
/// reaches the transport, or reaches it and fails before any header, never
/// reports the previous attempt's response.
void clearResponseHead(RequestOptions options) {
  options.extra
    ..remove(kResponseWatched)
    ..remove(kResponseHeadersReceived)
    ..remove(kResponseStatus)
    ..remove(kResponseRetryAfter)
    ..remove(kResponseMaxTextChars);
}

/// The status, `Retry-After` and advertised text bound
/// (`X-Voice-Tts-Max-Chars`, null unless usable) of the response [error]
/// ended in: Dio's [DioException.response] when it kept one, else what
/// [ResponseHeadersWatch] recorded when the headers arrived and the body
/// then broke (a truncated `503 Retry-After: 5` keeps its cooldown); `null`
/// when no response headers arrived (or none were watched).
({int status, String? retryAfter, int? maxTextChars})? responseHead(
  DioException error,
) {
  final response = error.response;
  final status = response?.statusCode;
  if (response != null && status != null) {
    final headers = response.headers;
    return (
      status: status,
      retryAfter: headers['retry-after']?.firstOrNull,
      maxTextChars: ttsMaxCharsOf(headers[kTtsMaxCharsHeader]),
    );
  }
  final extra = error.requestOptions.extra;
  final kept = extra[kResponseStatus];
  if (extra[kResponseHeadersReceived] != true || kept is! int) return null;
  return (
    status: kept,
    retryAfter: extra[kResponseRetryAfter] as String?,
    maxTextChars: extra[kResponseMaxTextChars] as int?,
  );
}

/// Whether [error] is the connection to the server failing before any
/// response arrived: refused, reset, or lost before a status line — the one
/// transport failure the reply speaker sends a sentence again on
/// (`PROTOCOL.md` §5.3).
///
/// Only a request the [ResponseHeadersWatch] watched, and whose headers it
/// saw NOT arrive, can be one: a response whose body broke after its
/// headers (whatever its status: a `503` with `Retry-After` keeps its
/// cooldown) is the server's answer, and a request whose transport was not
/// watched is never taken for one (nothing says no headers came). Then
/// never a timeout (a slow server is not a lost one: the connect, send and
/// receive timeouts), never a cancellation or a bad certificate. On
/// `dart:io` a [DioExceptionType.unknown] counts only when its cause is the
/// socket's (`SocketException`, `HttpException`: a reset, or a connection
/// closed before the headers); on the web, where voice does not run, only
/// [DioExceptionType.connectionError] does.
bool isTransportFailure(Object error) {
  if (error is! DioException || error.response != null) return false;
  final extra = error.requestOptions.extra;
  if (extra[kResponseWatched] != true ||
      extra[kResponseHeadersReceived] != false) {
    return false;
  }
  return switch (error.type) {
    DioExceptionType.connectionError => true,
    DioExceptionType.unknown => platform.isConnectionLost(error.error),
    _ => false,
  };
}
