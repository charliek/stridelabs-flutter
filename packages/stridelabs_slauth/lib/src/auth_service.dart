import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:jwt_decoder/jwt_decoder.dart';

import 'slauth_config.dart';
import 'token_store.dart';

/// How far before expiry the proactive refresh timer fires. Deliberately larger
/// than the 30-second [isTokenExpired] buffer so the timer fires before the
/// token appears "expired" to other code.
const _refreshMargin = Duration(seconds: 60);

/// Manages the full JWT token lifecycle for slauth authentication: PKCE code
/// exchange, refresh with rotation, persistence via a [TokenStore], and logout.
class AuthService {
  final Dio _dio;
  final TokenStore _store;
  final SlauthConfig _config;

  String? _accessToken;
  String? _refreshToken;
  // Kept for use as id_token_hint on RP-initiated logout.
  String? _idToken;
  DateTime? _expiresAt;

  // Lock to prevent concurrent refresh attempts.
  Completer<bool>? _refreshLock;

  // Proactive refresh timer — fires before token expiry.
  Timer? _refreshTimer;

  // Incremented on logout; checked in _storeTokens to discard in-flight refresh
  // results that arrive after the user logged out.
  int _generation = 0;

  // Track whether the store is usable (a locked-down/absent keychain may throw).
  bool _storageAvailable = true;

  // Serializes ALL token-store disk writes/deletes across _storeTokens and
  // logout. Without it, a stale exchange/refresh can pass _storeTokens' pre-write
  // generation check, yield on an `await _store.write`, and — while logout bumps
  // the generation and a newer login persists generation-1 tokens — resume and
  // reach the post-write cleanup, whose _deleteAllTokenKeys() would then wipe the
  // NEWER session's keys. Holding this lock across each write/delete pass makes
  // those passes atomic w.r.t. one another, so the generation checks are decisive.
  Future<void> _ioLock = Future<void>.value();

  /// Run [action] with exclusive access to the token store, serialized against
  /// every other [_synchronized] section. Not reentrant — never call it from
  /// inside another [_synchronized] block (the post-write cleanup in
  /// [_storeTokens] calls [_deleteAllTokenKeys] directly for that reason).
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final run = _ioLock.then((_) => action());
    _ioLock = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Called when auth is forcefully cleared (e.g. refresh token expired). Wired
  /// by the app's auth notifier to propagate logout to app state.
  void Function()? onForceLogout;

  static const _httpTimeout = Duration(seconds: 10);

  static const _keyAccessToken = 'slauth_access_token';
  static const _keyRefreshToken = 'slauth_refresh_token';
  static const _keyIdToken = 'slauth_id_token';
  static const _keyExpiresAt = 'slauth_expires_at';

  AuthService({required SlauthConfig config, TokenStore? store, Dio? dio})
    : _config = config,
      _store = store ?? defaultTokenStore(),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: config.baseUrl,
              connectTimeout: _httpTimeout,
              receiveTimeout: _httpTimeout,
            ),
          );

  /// Current access token, or null if not authenticated.
  String? get accessToken => _accessToken;

  /// Whether we have a non-null access token.
  bool get isAuthenticated => _accessToken != null;

  /// Whether the access token is expired (with 30s buffer).
  bool get isTokenExpired {
    if (_expiresAt == null) return true;
    return DateTime.now().isAfter(
      _expiresAt!.subtract(const Duration(seconds: 30)),
    );
  }

  /// Whether a refresh token is available (not cleared by logout).
  bool get hasRefreshToken => _refreshToken != null;

  /// The OIDC ID token, for use as id_token_hint on RP-initiated logout.
  String? get idToken => _idToken;

  /// Extract the user id (`sub`) from the JWT access token.
  String? get userId {
    if (_accessToken == null) return null;
    try {
      return JwtDecoder.decode(_accessToken!)['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Store tokens from an already-parsed token response — used by the code
  /// exchange, refresh, and the debug-only headless login (whose response has
  /// the same shape). Public so out-of-band callers (headless login) can persist
  /// without a second network round-trip.
  ///
  /// Snapshots the current generation at call time: if [logout] runs before this
  /// completes, the result is discarded (memory + disk) rather than resurrecting
  /// a signed-out session.
  Future<void> storeTokens(Map<String, dynamic> data) =>
      _storeTokens(data, _generation);

  /// Exchange an OAuth2 authorization code (+ PKCE verifier) for tokens by
  /// calling slauth's token endpoint directly. This is a public client (no
  /// secret) — the PKCE verifier authenticates the exchange.
  Future<bool> exchangeAuthorizationCode(
    String code, {
    required String codeVerifier,
    required String redirectUri,
  }) async {
    // Snapshot BEFORE the network round-trip: if logout() runs while the
    // exchange is in flight, _storeTokens discards the (now-stale) result.
    final gen = _generation;
    try {
      final response = await _dio.post(
        '/oauth2/token',
        data: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'client_id': _config.clientId,
          'code_verifier': codeVerifier,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          // Force a JSON decode: when Hydra's Content-Type comes back without
          // the exact `application/json` Dio sniffs for (e.g. behind a proxy),
          // Dio falls through to ResponseType.plain and hands back a raw String;
          // the downstream cast then throws and the exchange fails spuriously.
          responseType: ResponseType.json,
        ),
      );
      await _storeTokens(_decodeTokenResponse(response.data), gen);
      return true;
    } catch (e, st) {
      debugPrint('[AuthService] exchangeAuthorizationCode threw: $e');
      debugPrint('[AuthService] stack:\n$st');
      if (e is DioException) {
        debugPrint(
          '[AuthService] dio.type=${e.type} '
          'status=${e.response?.statusCode} body=${e.response?.data}',
        );
      }
      return false;
    }
  }

  /// Refresh the access token using the stored refresh token.
  ///
  /// Uses a [Completer] lock to deduplicate concurrent refresh attempts (e.g.
  /// multiple 401s arriving at once). On refresh-token expiry/revocation
  /// (400 invalid_grant / 401), calls [logout] and returns false; transient
  /// (5xx / network) errors return false without forcing logout.
  Future<bool> refreshAccessToken() async {
    if (_refreshLock != null) {
      return _refreshLock!.future;
    }
    if (_refreshToken == null) {
      return false;
    }

    // Snapshot BEFORE the network round-trip: if logout() runs while the
    // refresh is in flight, _storeTokens discards the (now-stale) result rather
    // than silently re-authenticating a signed-out user.
    final gen = _generation;
    _refreshLock = Completer<bool>();
    try {
      final response = await _dio.post(
        '/oauth2/token',
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': _refreshToken,
          'client_id': _config.clientId,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          // Critical here: Hydra rotates the refresh token on every success AND
          // has reuse-detection. If a 200 is dropped on the floor (String vs
          // Map), the old token is already revoked and the next refresh dies
          // with 400, forcing a full re-login. See _decodeTokenResponse.
          responseType: ResponseType.json,
        ),
      );
      await _storeTokens(_decodeTokenResponse(response.data), gen);
      _refreshLock!.complete(true);
      return true;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400 || status == 401) {
        await logout();
      }
      _refreshLock!.complete(false);
      return false;
    } catch (e, st) {
      debugPrint('[AuthService] refreshAccessToken threw (non-Dio): $e');
      debugPrint('[AuthService] stack:\n$st');
      _refreshLock!.complete(false);
      return false;
    } finally {
      _refreshLock = null;
    }
  }

  /// Restore tokens from the store on app start. Returns true if a usable
  /// access+refresh pair was found.
  Future<bool> restoreFromStorage() async {
    try {
      final accessToken = await _store.read(_keyAccessToken);
      final refreshToken = await _store.read(_keyRefreshToken);
      final idToken = await _store.read(_keyIdToken);
      final expiresAtStr = await _store.read(_keyExpiresAt);

      if (accessToken == null || refreshToken == null) return false;

      _accessToken = accessToken;
      _refreshToken = refreshToken;
      _idToken = idToken;
      if (expiresAtStr != null) {
        _expiresAt = DateTime.tryParse(expiresAtStr);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Clear all tokens from memory and the store.
  Future<void> logout({bool notify = true}) async {
    _generation++;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _accessToken = null;
    _refreshToken = null;
    _idToken = null;
    _expiresAt = null;
    // Serialized against _storeTokens so a concurrent stale write can't slip
    // between our deletions and leave a resurrectable pair on disk.
    await _synchronized(_deleteAllTokenKeys);
    if (notify) {
      onForceLogout?.call();
    }
  }

  /// Delete all four token keys from the store. Each deletion is independently
  /// best-effort (its own try/catch) so a single failure never leaves a partial
  /// (still-usable) session behind on disk — all four are always attempted.
  Future<void> _deleteAllTokenKeys() async {
    for (final key in const [
      _keyAccessToken,
      _keyRefreshToken,
      _keyIdToken,
      _keyExpiresAt,
    ]) {
      try {
        await _store.delete(key);
      } catch (_) {
        // Best effort — store might be unavailable for this key.
      }
    }
  }

  /// Arm the proactive refresh timer for the current token.
  void scheduleNextRefresh() => _scheduleRefresh();

  /// Cancel the refresh timer and release resources.
  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_expiresAt == null) return;

    var delay = _expiresAt!.difference(DateTime.now()) - _refreshMargin;
    if (delay.isNegative) delay = Duration.zero;

    // Always via a Timer (even Duration.zero) to break the synchronous chain
    // refreshAccessToken → _storeTokens → _scheduleRefresh.
    _refreshTimer = Timer(delay, () => refreshAccessToken());
  }

  /// Normalize Dio's `response.data` into a Map. Dio usually auto-decodes JSON,
  /// but if the upstream Content-Type sniff fails it hands back a raw String —
  /// fall back to a JSON parse so the call site works either way.
  Map<String, dynamic> _decodeTokenResponse(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String) {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return parsed;
    }
    throw FormatException(
      'Unexpected token response shape: ${raw.runtimeType}',
    );
  }

  /// Persist and adopt a token response. [gen] is the generation snapshot taken
  /// by the caller BEFORE its network round-trip began; if [logout] has bumped
  /// the generation since, the result is stale (the user signed out mid-flight)
  /// and is discarded from both memory and disk.
  Future<void> _storeTokens(Map<String, dynamic> data, int gen) async {
    final accessToken = data['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const FormatException(
        'Missing or invalid access_token in token response',
      );
    }

    final refreshToken = data['refresh_token'] as String?;
    // Refresh responses omit id_token; keep the one from the code exchange.
    final idToken = data['id_token'] as String? ?? _idToken;
    DateTime? expiresAt;
    final expiresAtStr = data['expires_at'] as String?;
    if (expiresAtStr != null) {
      expiresAt = DateTime.tryParse(expiresAtStr);
    } else {
      final expiresIn = data['expires_in'] as int?;
      if (expiresIn != null) {
        expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
      }
    }

    // The disk writes + generation checks run under _ioLock so logout's delete
    // pass (and a newer login's writes) cannot interleave with ours: a stale op
    // either holds the lock through its whole write pass, or it acquires the lock
    // after the newer generation is visible and bails at the pre-write check.
    await _synchronized(() async {
      // Check the snapshot BEFORE any persist write: if logout ran while the
      // network call was in flight, never touch disk (or memory) — otherwise a
      // late-arriving refresh would write tokens after logout's deletions and
      // resurrect the session on next launch.
      if (_generation != gen) return;

      if (_storageAvailable) {
        try {
          // Persist the rotated refresh token BEFORE the access token: a crash
          // between the writes must never leave the OLD (now-revoked) refresh
          // token paired with a new access token, which would trip Hydra's
          // reuse-detection and force a logout on next startup.
          if (refreshToken != null) {
            await _store.write(_keyRefreshToken, refreshToken);
          } else {
            await _store.delete(_keyRefreshToken);
          }
          await _store.write(_keyAccessToken, accessToken);
          if (idToken != null) {
            await _store.write(_keyIdToken, idToken);
          }
          if (expiresAt != null) {
            await _store.write(_keyExpiresAt, expiresAt.toIso8601String());
          }
        } catch (_) {
          _storageAvailable = false;
          debugPrint(
            '[AuthService] token store unavailable — tokens in memory only',
          );
        }
      }

      // Re-check AFTER the writes: if logout landed mid-write, our writes may
      // have hit disk after logout's deletions. Undo them (best-effort) so the
      // disk can't outlive logout, and don't adopt the tokens into memory.
      // Called directly (not via _synchronized) — we already hold the lock.
      if (_generation != gen) {
        await _deleteAllTokenKeys();
        return;
      }

      _accessToken = accessToken;
      _refreshToken = refreshToken;
      _idToken = idToken;
      _expiresAt = expiresAt;

      _scheduleRefresh();
    });
  }
}
