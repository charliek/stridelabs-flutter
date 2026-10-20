import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

const testConfig = SlauthConfig(
  baseUrl: 'https://auth.test',
  clientId: 'slaudio-mobile',
  audience: 'slaudio',
  redirectUri: 'slaudio://auth/callback',
  postLogoutUri: 'slaudio://auth/logout',
);

const kAccess = 'slauth_access_token';
const kRefresh = 'slauth_refresh_token';
const kId = 'slauth_id_token';
const kExpires = 'slauth_expires_at';
const kMarker = 'slauth_write_in_progress';

String makeJwt(String sub) {
  const header = 'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0';
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","email":"t@t"}'))
      .replaceAll('=', '');
  return '$header.$payload.';
}

/// A TokenStore that records every operation, in order, as `write:<key>` /
/// `delete:<key>`; optionally throws on writes or deletes, and optionally
/// suspends a read, write or delete (before it applies) on an async hook, to
/// park a caller mid-I/O (a hook that throws fails that operation).
class RecordingStore implements TokenStore {
  final Map<String, String> data = {};
  final List<String> ops = [];
  Object? writeError;
  Object? deleteError;
  Future<void> Function(String key)? beforeRead;
  Future<void> Function(String key)? beforeWrite;
  Future<void> Function(String key)? beforeDelete;

  /// Keys whose writes fail DESTRUCTIVELY: the existing value is removed, then
  /// the write throws. Models flutter_secure_storage on iOS/macOS, which
  /// answers a failed keychain update by deleting the item and re-adding it
  /// (and the re-add can fail too).
  bool Function(String key)? destructiveWriteFailure;

  @override
  Future<String?> read(String key) async {
    final hook = beforeRead;
    if (hook != null) await hook(key);
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    ops.add('write:$key');
    final hook = beforeWrite;
    if (hook != null) await hook(key);
    if (destructiveWriteFailure?.call(key) ?? false) {
      data.remove(key);
      throw StateError('update failed; item deleted; re-add failed');
    }
    final error = writeError;
    if (error != null) throw error;
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    ops.add('delete:$key');
    final hook = beforeDelete;
    if (hook != null) await hook(key);
    final error = deleteError;
    if (error != null) throw error;
    data.remove(key);
  }
}

/// A programmable [TokenEndpoint] that counts calls and records arguments.
class FakeEndpoint extends TokenEndpoint {
  FakeEndpoint({this.onExchange, this.onRefresh});

  Future<TokenResponse> Function(TokenExchangeRequest request)? onExchange;
  Future<TokenResponse> Function(String refreshToken)? onRefresh;

  final List<TokenExchangeRequest> exchanges = [];
  final List<String> refreshes = [];

  @override
  Future<TokenResponse> exchange(TokenExchangeRequest request) {
    exchanges.add(request);
    final handler = onExchange;
    if (handler == null) throw StateError('unexpected exchange');
    return handler(request);
  }

  @override
  Future<TokenResponse> refresh(String refreshToken) {
    refreshes.add(refreshToken);
    final handler = onRefresh;
    if (handler == null) throw StateError('unexpected refresh');
    return handler(refreshToken);
  }
}

TokenResponse tokens(
  String access, {
  RefreshTokenField refresh = const RefreshTokenAbsent(),
  String? id,
  DateTime? expiresAt,
}) => TokenResponse(
  accessToken: access,
  refreshToken: refresh,
  idToken: id,
  expiresAt: expiresAt,
);

DateTime inOneDay() => DateTime.now().add(const Duration(days: 1));

/// Seed [store] with a complete session (as a previous run would have left it)
/// and restore it into [svc].
Future<void> seedSession(
  AuthService svc,
  RecordingStore store, {
  String access = 'a0',
  String refresh = 'r0',
  String? id = 'id0',
  DateTime? expiresAt,
}) async {
  store.data[kAccess] = access;
  store.data[kRefresh] = refresh;
  if (id != null) store.data[kId] = id;
  store.data[kExpires] = (expiresAt ?? inOneDay()).toIso8601String();
  final ok = await svc.restoreFromStorage();
  if (!ok) throw StateError('seedSession: restore failed');
  store.ops.clear();
}

/// A captured outbound Dio request: options plus the encoded body.
class CapturedRequest {
  CapturedRequest(this.options, this.body);
  final RequestOptions options;
  final String body;
}

/// Dio adapter answering every request from [responder], recording requests.
class ScriptedAdapter implements HttpClientAdapter {
  ScriptedAdapter(this.responder);

  final FutureOr<ResponseBody> Function(RequestOptions options) responder;
  final List<CapturedRequest> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    requests.add(CapturedRequest(options, utf8.decode(bytes)));
    return responder(options);
  }
}

ResponseBody jsonBody(Object? json, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(json),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );

ResponseBody rawBody(
  String body,
  int status, {
  String contentType = 'application/json',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    'content-type': [contentType],
  },
);

Dio dioWith(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: testConfig.baseUrl))..httpClientAdapter = adapter;

/// A one-shot barrier for a [RecordingStore] hook: the first call parks until
/// [release]; [entered] completes when it does. Later calls pass straight
/// through.
class Barrier {
  final _entered = Completer<void>();
  final _release = Completer<void>();
  var _armed = true;

  Future<void> get entered => _entered.future;

  void release() => _release.complete();

  Future<void> call(String _) async {
    if (!_armed) return;
    _armed = false;
    _entered.complete();
    await _release.future;
  }
}
