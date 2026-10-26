// FROZEN: a verbatim excerpt of an installed client's speech request, the
// test of `installed_clients_tts_test.dart`. Never edit it: every byte after
// the marker line is the source's, checked against this SHA-256.
// Source: lumen v2026.10.23 (commit 37494715848f7e6d09f2dc500e4309baced7d0ce)
//   apps/flutter_client/lib/api/api_client.dart, lines 274-295 (the
//   top-level postVoiceTts with its doc comment; the imports below are the
//   file's own two it needs)
// SHA-256: 3cc3b238481c7f86690ec076f82a8112d8578fc188fa75d73a8d51e85fa2a510
// ignore_for_file: type=lint
// dart format off
import 'dart:typed_data';

import 'package:dio/dio.dart';

// ---- frozen below ----
/// `POST /voice/tts` `{text, voice}` on [dio] → the `audio/mpeg` body.
Future<Uint8List> postVoiceTts(
  Dio dio,
  String text, {
  required String voice,
}) async {
  final response = await dio.post<List<int>>(
    '/voice/tts',
    data: {'text': text, 'voice': voice},
    options: Options(responseType: ResponseType.bytes),
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
