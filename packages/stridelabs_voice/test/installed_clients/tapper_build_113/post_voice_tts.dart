// FROZEN: a verbatim excerpt of an installed client's speech request, the
// test of `installed_clients_tts_test.dart`. Never edit it: every byte after
// the marker line is the source's, checked against this SHA-256.
// Source: tapper build 113 (commit ca691a2b83ee4c9b370c0c951287958bd63d2a54, release v2026.10.25)
//   apps/flutter_client/lib/api/api_client.dart, lines 375-402 (the
//   top-level postVoiceTts with its doc comment; the imports below are the
//   file's own two it needs)
// SHA-256: 91c3916c8e58e451c28a2daf17233c174e530cef3a24a16fd2f53175182e7c57
// Formatted as it was (the short style); its null-aware map element needs
// this package's language version, so formatting is off instead:
// ignore_for_file: type=lint
// dart format off
import 'dart:typed_data';

import 'package:dio/dio.dart';

// ---- frozen below ----
/// `POST /voice/tts` `{text, voice}` on [dio] → the `audio/mpeg` body, with
/// `Idempotency-Key: <idempotencyKey>` when one is given. [extra] is the
/// request's [RequestOptions.extra] (its session binding,
/// [ApiClient.requestBinding], on the app's Dio).
Future<Uint8List> postVoiceTts(Dio dio, String text,
    {required String voice,
    String? idempotencyKey,
    Map<String, dynamic>? extra}) async {
  final response = await dio.post<List<int>>(
    '/voice/tts',
    data: {'text': text, 'voice': voice},
    options: Options(
      responseType: ResponseType.bytes,
      extra: extra,
      headers: {'Idempotency-Key': ?idempotencyKey},
    ),
  );
  final body = response.data;
  if (body == null || body.isEmpty) {
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      type: DioExceptionType.badResponse,
      message: 'empty speech body',
    );
  }
  return body is Uint8List ? body : Uint8List.fromList(body);
}
