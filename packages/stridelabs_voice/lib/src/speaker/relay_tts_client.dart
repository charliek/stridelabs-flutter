import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../http/transport_failure.dart';
import '../http/tts_headers.dart';
import '../protocol/constants.dart';
import 'reply_tts.dart';

/// [RequestOptions.extra]: this request is never replayed or refreshed by
/// the app's auth interceptor. Every TTS attempt carries it: the reply
/// speaker owns the sentence's one retry, its refresh and its deadline
/// (`TtsAuth`), so a `401` refreshes once, not twice.
const String kNoAuthReplayExtra = 'stridelabs_voice.noAuthReplay';

/// [ReplyTts] over `POST /voice/tts` (`PROTOCOL.md` §5) on an app's [Dio]:
/// its base URL, its interceptors (the bearer token) and its transport.
///
/// Each sentence's [request] reads [extras] once, and each of its sends
/// POSTs `{text, voice}` with its `Idempotency-Key`, `ResponseType.bytes`
/// and `RequestOptions.extra = {...extras, kNoAuthReplayExtra: true}`, on
/// fresh options (so no response metadata survives from an earlier
/// attempt). A `200` must be one of `kAllowedAudioTypes` (else
/// [UnsupportedAudioType]) with a non-empty body (else a
/// [DioExceptionType.badResponse]). Any other status is a [DioException]
/// with its response, whatever the app Dio's own `validateStatus` (or an
/// interceptor resolving an error) would allow: only a `2xx` is read as
/// audio. Each response's `X-Voice-Tts-Max-Chars` is read on
/// success into [ReplyClip.maxTextChars], and on a failure by
/// [responseHead].
class RelayTtsClient implements ReplyTts {
  /// Installs [ResponseHeadersWatch] on [dio], idempotently (an adapter that
  /// already is one is kept), so [isTransportFailure] can tell that no
  /// headers arrived, and a body broken after its headers keeps its status
  /// and `Retry-After`.
  ///
  /// [path] is joined to the Dio's base URL as Dio joins it (by
  /// concatenation, so the leading `/` works with or without a trailing one
  /// on the base).
  RelayTtsClient(this._dio, {this._path = '/voice/tts', this._extras}) {
    if (_dio.httpClientAdapter is! ResponseHeadersWatch) {
      _dio.httpClientAdapter = ResponseHeadersWatch(_dio.httpClientAdapter);
    }
  }

  final Dio _dio;
  final String _path;
  final Map<String, Object?> Function()? _extras;

  @override
  ReplyTtsRequest request(
    String text, {
    required String voice,
    required String idempotencyKey,
  }) => _RelayTtsRequest(
    this,
    text,
    voice,
    idempotencyKey,
    Map.unmodifiable(_extras?.call() ?? const <String, Object?>{}),
  );
}

/// A `2xx`: the only answer read as audio.
bool _isSuccess(int? status) => status != null && status >= 200 && status < 300;

class _RelayTtsRequest implements ReplyTtsRequest {
  _RelayTtsRequest(
    this._client,
    this._text,
    this._voice,
    this._key,
    this.extras,
  );

  final RelayTtsClient _client;
  final String _text;
  final String _voice;
  final String _key;

  @override
  final Map<String, Object?> extras;

  @override
  Future<ReplyClip> send() async {
    final dio = _client._dio;
    final options =
        Options(
          method: 'POST',
          responseType: ResponseType.bytes,
          headers: {kIdempotencyKeyHeader: _key},
          extra: {...extras, kNoAuthReplayExtra: true},
          // Never the app Dio's own rule: a refusal is always a
          // DioException, which its cooldown, refresh and limit notice read.
          validateStatus: _isSuccess,
        ).compose(
          dio.options,
          _client._path,
          data: {'text': _text, 'voice': _voice},
        );
    clearResponseHead(options);
    final response = await dio.fetch<List<int>>(options);
    // An app interceptor may still resolve a refusal into a response.
    final status = response.statusCode;
    if (!_isSuccess(status)) {
      throw DioException.badResponse(
        statusCode: status ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );
    }
    final headers = response.headers;
    final maxTextChars = ttsMaxCharsOf(headers[kTtsMaxCharsHeader]);
    final contentTypes = headers[Headers.contentTypeHeader];
    final contentType = contentTypes?.length == 1 ? contentTypes!.single : null;
    final mediaType = allowedMediaType(contentType);
    if (mediaType == null) {
      throw UnsupportedAudioType(
        mediaTypeOf(contentType),
        maxTextChars: maxTextChars,
      );
    }
    final body = response.data;
    if (body == null || body.isEmpty) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'empty speech body',
      );
    }
    return ReplyClip(
      body is Uint8List ? body : Uint8List.fromList(body),
      mediaType,
      maxTextChars: maxTextChars,
    );
  }
}
