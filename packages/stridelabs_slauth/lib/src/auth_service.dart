import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:jwt_decoder/jwt_decoder.dart';

import 'auth_errors.dart';
import 'slauth_config.dart';
import 'token_endpoint.dart';
import 'token_store.dart';

/// How far before expiry the proactive refresh timer fires. Deliberately larger
/// than the 30-second [AuthService.isTokenExpired] buffer so the timer fires
/// before the token appears "expired" to other code.
const _refreshMargin = Duration(seconds: 60);

/// The outcome of [AuthService.refreshSession].
enum RefreshOutcome {
  /// New tokens were adopted (memory and store).
  refreshed,

  /// The grant is dead ([AuthUnauthorized]): the session was cleared via
  /// [AuthService.logout], which fired `onForceLogout`.
  unauthorized,

  /// A transient or upstream fault ([AuthUnavailable], any other endpoint
  /// error, or a null/empty `refresh_token` in the response): nothing was
  /// adopted and the session is kept, in memory and in the store. If a
  /// [RefreshRetryPolicy] is set, a retry is now scheduled.
  unavailable,

  /// There was no session to refresh (no refresh token).
  noSession,

  /// The session this refresh belonged to ended while the call was in flight
  /// ([AuthService.logout], or a new session from a code exchange or
  /// [AuthService.storeTokens]), so its result was not applied. The current
  /// state is whatever that logout/new session left.
  ///
  /// Also returned, without any request, by a refresh called after
  /// [AuthService.dispose].
  discarded,
}

/// Opt-in retry of a refresh that ended [RefreshOutcome.unavailable].
///
/// Attempt `n` (0-based) waits `initialDelay * 2^n`, capped at [maxDelay]; the
/// retries continue at [maxDelay] until one refresh succeeds or is
/// unauthorized, or until [AuthService.logout] / [AuthService.dispose].
class RefreshRetryPolicy {
  const RefreshRetryPolicy({
    this.initialDelay = const Duration(seconds: 15),
    this.maxDelay = const Duration(minutes: 5),
  });

  /// Delay before the first retry. Values under one second are raised to one
  /// second.
  final Duration initialDelay;

  /// Cap on the delay between retries. Values under one second are raised to
  /// one second.
  final Duration maxDelay;

  /// The delay before retry number [attempt] (0-based).
  Duration delayForAttempt(int attempt) {
    const floor = Duration(seconds: 1);
    final cap = maxDelay < floor ? floor : maxDelay;
    var delay = initialDelay < floor ? floor : initialDelay;
    for (var i = 0; i < attempt && delay < cap; i++) {
      delay *= 2;
    }
    return delay > cap ? cap : delay;
  }
}

/// One refresh's result, as seen by both entry points: [RefreshOutcome] for
/// [AuthService.refreshSession], and [succeeded] (the endpoint returned a
/// usable response) for the legacy bool of [AuthService.refreshAccessToken].
typedef _RefreshResult = ({RefreshOutcome outcome, bool succeeded});

/// Manages the full JWT token lifecycle: PKCE code exchange, refresh with
/// rotation, persistence via a [TokenStore], and logout — against any
/// [TokenEndpoint] ([HydraTokenEndpoint], slauth's `/oauth2/token`, by
/// default).
///
/// Refresh-token rule (a token response's `refresh_token` field):
///
/// | Field | On refresh | On exchange / [storeTokens] (a new session) |
/// | --- | --- | --- |
/// | absent | keep the stored refresh token | no refresh token; any stored one is deleted |
/// | a value | replace it (written before the access token) | store it |
/// | `null` or `''` | upstream error: [RefreshOutcome.unavailable], nothing adopted | fails, nothing stored |
class AuthService {
  final TokenEndpoint _endpoint;
  final TokenStore _store;
  final RefreshRetryPolicy? _retryPolicy;

  String? _accessToken;
  String? _refreshToken;
  // Kept for use as id_token_hint on RP-initiated logout.
  String? _idToken;
  DateTime? _expiresAt;

  // Deduplicates concurrent refreshes from BOTH entry points (refreshSession
  // and refreshAccessToken): callers arriving while one is in flight for the
  // SAME in-memory session share it. _refreshLockGen is the session
  // generation that refresh snapshotted; a caller whose session has since
  // been replaced starts its own refresh instead of inheriting a stale result.
  Completer<_RefreshResult>? _refreshLock;
  int _refreshLockGen = 0;

  // Proactive refresh timer — fires before token expiry.
  Timer? _refreshTimer;

  // Opt-in retry after an unavailable refresh (see RefreshRetryPolicy).
  Timer? _retryTimer;
  int _retryAttempt = 0;

  // Session identity. Incremented on logout AND when a new session's adoption
  // begins (exchange, storeTokens). Exchange/refresh snapshot a generation
  // before their network call; _adopt discards a result whose snapshot is
  // stale, so a refresh that lands after the user logged out (or signed in as
  // a new session) can neither resurrect the old session nor overwrite the
  // new one.
  int _generation = 0;

  // The generation the IN-MEMORY tokens were published under. Always written
  // in the same synchronous step as the tokens themselves (_adopt's
  // publication, restoreFromStorage), so a refresh that snapshots
  // (_refreshToken, _sessionGeneration) can never pair one session's token
  // with another session's generation.
  //
  // It differs from _generation only while a new session is being persisted:
  // _adopt claims the new generation BEFORE its store writes (so in-flight
  // refreshes of the old session are discarded), but publishes the new tokens
  // to memory only AFTER them. In that window memory still holds the old
  // session's tokens, tagged with the old generation, so a refresh started
  // there is stale by construction and is discarded — it can neither
  // overwrite the new session (success) nor log it out (unauthorized).
  int _sessionGeneration = 0;

  // Terminal: set by dispose(). Refreshes no longer start, and nothing (a
  // late in-flight completion included) re-arms the proactive or retry timer.
  bool _disposed = false;

  // Track whether the store is usable (a locked-down/absent keychain may throw).
  // Once false it stays false: tokens are memory-only for the rest of the
  // process, and restoreFromStorage never trusts the store again.
  bool _storageAvailable = true;

  // Storage provenance, in this process: the generation whose session the
  // store holds, as one consistent, fully written pass (or as a fully
  // completed logout deletion: known-empty). Null when that is unknown: a
  // write pass is in progress, stopped part-way on an error, or was undone by
  // a concurrent logout, or a logout could not delete every key. Only ever
  // changed under _ioLock. restoreFromStorage publishes the store only when
  // this equals the current generation. A fresh process starts at 0
  // (= _generation) and relies on the persisted _keyWriteInProgress marker
  // instead (see there).
  //
  // The marker makes this redundant whenever the marker could be written; it
  // still covers, within the process, a logout that could neither write the
  // marker nor delete the token keys.
  int? _persistedGeneration = 0;

  // Serializes ALL token-store disk writes/deletes across _adopt and logout
  // (and restoreFromStorage's read pass, so it never sees half a write pass).
  // Without it, a stale exchange/refresh can pass _adopt's pre-write
  // generation check, yield on an `await _store.write`, and — while logout
  // bumps the generation and a newer login persists generation-1 tokens —
  // resume and reach the post-write cleanup, whose _deleteAllTokenKeys() would
  // then wipe the NEWER session's keys. Holding this lock across each
  // write/delete pass makes those passes atomic w.r.t. one another, so the
  // generation checks are decisive.
  Future<void> _ioLock = Future<void>.value();

  /// Run [action] with exclusive access to the token store, serialized against
  /// every other [_synchronized] section. Not reentrant — never call it from
  /// inside another [_synchronized] block (the post-write cleanup in [_adopt]
  /// calls [_deleteAllTokenKeys] directly for that reason).
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final run = _ioLock.then((_) => action());
    _ioLock = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Called when auth is forcefully cleared (e.g. refresh token expired). Wired
  /// by the app's auth notifier to propagate logout to app state.
  void Function()? onForceLogout;

  static const _keyAccessToken = 'slauth_access_token';
  static const _keyRefreshToken = 'slauth_refresh_token';
  static const _keyIdToken = 'slauth_id_token';
  static const _keyExpiresAt = 'slauth_expires_at';

  /// Persisted "write pass in progress" marker, in the same store (and so the
  /// same per-app namespace) as the token keys. Every NEW-session write pass
  /// (exchange, storeTokens) and every logout deletion pass writes it BEFORE
  /// touching a token key and deletes it LAST, only once the token keys hold
  /// one whole session (or are all gone). restoreFromStorage restores nothing
  /// while it is present, in this process or any later one: such a pass that
  /// stopped part-way (an error, a crash, a clean-up that failed too) is never
  /// restored as a stale or mixed-account session. A store without it (a
  /// completed pass, or one written by an earlier version of this package) is
  /// trusted as before.
  ///
  /// Refresh passes neither write nor delete it: they rewrite the same
  /// session, refresh token first, so an interrupted one leaves a restorable
  /// pair of one identity (see _adopt).
  static const _keyWriteInProgress = 'slauth_write_in_progress';

  /// slauth/Hydra: tokens via [HydraTokenEndpoint] at `config.baseUrl`. Pass
  /// [dio] to inject the HTTP client (tests); [refreshRetry] opts into retrying
  /// unavailable refreshes (off by default).
  AuthService({
    required SlauthConfig config,
    TokenStore? store,
    Dio? dio,
    RefreshRetryPolicy? refreshRetry,
  }) : this.withEndpoint(
         endpoint: HydraTokenEndpoint(config: config, dio: dio),
         store: store,
         refreshRetry: refreshRetry,
       );

  /// Any token service: [endpoint] performs the exchange and refresh calls and
  /// classifies failures ([AuthUnauthorized] / [AuthUnavailable]); this class
  /// owns everything else (storage, rotation, dedup, timers, logout).
  /// [refreshRetry] opts into retrying unavailable refreshes (off by default).
  AuthService.withEndpoint({
    required this._endpoint,
    TokenStore? store,
    RefreshRetryPolicy? refreshRetry,
  }) : _store = store ?? defaultTokenStore(),
       _retryPolicy = refreshRetry;

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

  /// Whether a retry of an unavailable refresh is scheduled (only ever true
  /// with a [RefreshRetryPolicy]).
  bool get hasPendingRefreshRetry => _retryTimer?.isActive ?? false;

  /// Extract the user id (`sub`) from the JWT access token.
  String? get userId {
    if (_accessToken == null) return null;
    try {
      return JwtDecoder.decode(_accessToken!)['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Store tokens from an already-parsed token response map — for out-of-band
  /// callers (the debug-only headless login) that already hold a token
  /// response, so they can persist without a second network round-trip.
  ///
  /// Adopts the response as a **new session** (the exchange rule): an absent
  /// `refresh_token` deletes any stored one. Throws a [FormatException] (and
  /// stores nothing) when `access_token` is missing/empty, a field has the
  /// wrong type, or `refresh_token` is present but null/empty.
  ///
  /// Snapshots the current generation at call time: if [logout] runs before this
  /// completes, the result is discarded (memory + disk) rather than resurrecting
  /// a signed-out session.
  Future<void> storeTokens(Map<String, dynamic> data) async {
    final gen = _generation;
    final response = TokenResponse.fromJson(data);
    if (_isBlank(response.refreshToken)) {
      throw const FormatException(
        'Token response has a null or empty refresh_token',
      );
    }
    await _adopt(response, gen, newSession: true);
  }

  /// Exchange an OAuth2 authorization code (+ PKCE verifier) for tokens via the
  /// [TokenEndpoint], and adopt them as a new session.
  ///
  /// Returns true only when the new session was adopted (memory and store).
  /// Returns false (storing nothing) on any endpoint failure, when the
  /// response's `refresh_token` is present but null/empty, or when the result
  /// was discarded because [logout] (or another new session) landed while the
  /// exchange was in flight. Never logs out.
  Future<bool> exchangeAuthorizationCode(
    String code, {
    required String codeVerifier,
    required String redirectUri,
  }) async {
    // Snapshot BEFORE the network round-trip: if logout() runs while the
    // exchange is in flight, _adopt discards the (now-stale) result.
    final gen = _generation;
    try {
      final response = await _endpoint.exchange(
        TokenExchangeRequest(
          code: code,
          codeVerifier: codeVerifier,
          redirectUri: redirectUri,
        ),
      );
      if (_isBlank(response.refreshToken)) {
        debugPrint(
          '[AuthService] exchangeAuthorizationCode failed: '
          'null or empty refresh_token in the token response',
        );
        return false;
      }
      final adopted = await _adopt(response, gen, newSession: true);
      if (!adopted) {
        // Callers treat true as "signed in": never report a session that a
        // concurrent logout (or a newer session) discarded.
        debugPrint(
          '[AuthService] exchangeAuthorizationCode discarded: the session '
          'changed while the exchange was in flight',
        );
      }
      return adopted;
    } catch (e) {
      _logFailure('exchangeAuthorizationCode', e);
      return false;
    }
  }

  /// Refresh the session and say what happened (see [RefreshOutcome]), so an
  /// app can tell "kept but stale" ([RefreshOutcome.unavailable]) from "signed
  /// out" ([RefreshOutcome.unauthorized]) without inspecting internals.
  ///
  /// Concurrent calls to this and [refreshAccessToken] share one endpoint call.
  Future<RefreshOutcome> refreshSession() async => (await _refresh()).outcome;

  /// Refresh the access token using the stored refresh token.
  ///
  /// Returns true when the endpoint returned new tokens (even if a concurrent
  /// [logout] then discarded them), false otherwise. On a dead grant
  /// ([AuthUnauthorized]: Hydra 400 invalid_grant / 401) it calls [logout];
  /// on a transient fault ([AuthUnavailable]: 5xx, network, malformed body) it
  /// keeps the session. [refreshSession] gives the typed outcome.
  ///
  /// Concurrent calls to this and [refreshSession] share one endpoint call
  /// (e.g. multiple 401s arriving at once).
  Future<bool> refreshAccessToken() async => (await _refresh()).succeeded;

  Future<_RefreshResult> _refresh() async {
    if (_disposed) {
      return (outcome: RefreshOutcome.discarded, succeeded: false);
    }
    final inFlight = _refreshLock;
    if (inFlight != null && _refreshLockGen == _sessionGeneration) {
      return inFlight.future;
    }
    final refreshToken = _refreshToken;
    if (refreshToken == null) {
      return (outcome: RefreshOutcome.noSession, succeeded: false);
    }

    // Snapshot BEFORE the network round-trip: if logout() runs while the
    // refresh is in flight, _adopt discards the (now-stale) result rather than
    // silently re-authenticating a signed-out user.
    //
    // The generation is the one the in-memory tokens carry, read together with
    // the token: never _generation, which a new session's adoption bumps
    // before its tokens reach memory (see _sessionGeneration).
    final gen = _sessionGeneration;
    final lock = Completer<_RefreshResult>();
    _refreshLock = lock;
    _refreshLockGen = gen;
    try {
      final result = await _performRefresh(refreshToken, gen);
      lock.complete(result);
      return result;
    } catch (e) {
      // _performRefresh handles every failure itself; this is a backstop so
      // the waiters on the lock can never hang.
      _logFailure('refresh', e);
      const result = (outcome: RefreshOutcome.unavailable, succeeded: false);
      lock.complete(result);
      return result;
    } finally {
      if (identical(_refreshLock, lock)) _refreshLock = null;
    }
  }

  Future<_RefreshResult> _performRefresh(String refreshToken, int gen) async {
    final TokenResponse response;
    try {
      response = await _endpoint.refresh(refreshToken);
    } on AuthUnauthorized catch (e) {
      _logFailure('refresh', e);
      // Only end the session this refresh belonged to: if it already ended
      // (logout, or a new session was adopted), a logout now would sign out
      // the user's NEW session.
      if (_generation != gen) {
        return (outcome: RefreshOutcome.discarded, succeeded: false);
      }
      await logout();
      return (outcome: RefreshOutcome.unauthorized, succeeded: false);
    } catch (e) {
      // AuthUnavailable, or anything else a custom endpoint threw: transient.
      _logFailure('refresh', e);
      return _keepSession(gen);
    }

    if (_isBlank(response.refreshToken)) {
      // A rotated-but-empty refresh token is an upstream fault, not "no
      // refresh token": adopt nothing (not even the access token), keep the
      // stored session.
      debugPrint(
        '[AuthService] refresh failed: null or empty refresh_token in the '
        'token response (treated as unavailable; session kept)',
      );
      return _keepSession(gen);
    }

    final bool adopted;
    try {
      adopted = await _adopt(response, gen, newSession: false);
    } catch (e) {
      _logFailure('refresh', e);
      return _keepSession(gen);
    }
    return adopted
        ? (outcome: RefreshOutcome.refreshed, succeeded: true)
        : (outcome: RefreshOutcome.discarded, succeeded: true);
  }

  /// An unavailable refresh: keep the session and (opt-in) schedule a retry —
  /// unless the session already ended while the call was in flight.
  _RefreshResult _keepSession(int gen) {
    if (_generation != gen) {
      return (outcome: RefreshOutcome.discarded, succeeded: false);
    }
    _scheduleRetry();
    return (outcome: RefreshOutcome.unavailable, succeeded: false);
  }

  /// Restore the session the store holds, on app start. Returns true if the
  /// service then holds a usable access+refresh pair.
  ///
  /// Restore only ever fills an EMPTY in-memory session. If a session is
  /// already in memory (a sign-in that completed first, or an earlier
  /// restore), it is left untouched, nothing is read, and the result says
  /// whether that session is a usable access+refresh pair. So an app that
  /// awaits this at startup sees true whenever it is in fact signed in.
  ///
  /// Otherwise it restores nothing and returns false when:
  /// - the store is marked mid-write: a new session's write pass, or a
  ///   [logout]'s deletions, stopped part-way, in this process or an earlier
  ///   one (an error, a crash, or a clean-up that failed too);
  /// - [logout] or a new session lands before the store has been read;
  /// - the store failed earlier in this process (tokens are memory-only from
  ///   then on);
  /// - within this process, the store is not known to hold one consistent
  ///   session of the current sign-in (e.g. a [logout] could neither mark the
  ///   store nor delete its keys).
  ///
  /// An unmarked store left by a previous process (including one written by
  /// an earlier version of this package, which never marks) is trusted.
  Future<bool> restoreFromStorage() async {
    final gen = _generation;
    // Everything runs under _ioLock: the checks and reads see one settled
    // state (never half of a write pass), and the publication below is
    // atomic with the session identity it is tagged with.
    return _synchronized(() async {
      if (_accessToken != null || _refreshToken != null) {
        return _accessToken != null && _refreshToken != null;
      }
      if (_generation != gen) return false;
      if (!_storageAvailable) return false;
      if (_persistedGeneration != gen) return false;
      try {
        // A pass (in this process or an earlier one) stopped part-way.
        if (await _store.read(_keyWriteInProgress) != null) return false;
        final accessToken = await _store.read(_keyAccessToken);
        final refreshToken = await _store.read(_keyRefreshToken);
        final idToken = await _store.read(_keyIdToken);
        final expiresAtStr = await _store.read(_keyExpiresAt);

        if (accessToken == null || refreshToken == null) return false;
        if (_generation != gen) return false;

        _accessToken = accessToken;
        _refreshToken = refreshToken;
        _idToken = idToken;
        if (expiresAtStr != null) {
          _expiresAt = DateTime.tryParse(expiresAtStr);
        }
        _sessionGeneration = gen;
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  /// Clear all tokens from memory and the store, and cancel the refresh timer
  /// and any pending refresh retry.
  Future<void> logout({bool notify = true}) async {
    final gen = ++_generation;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _cancelRetry();
    _accessToken = null;
    _refreshToken = null;
    _idToken = null;
    _expiresAt = null;
    // Serialized against _adopt so a concurrent stale write can't slip
    // between our deletions and leave a resurrectable pair on disk.
    await _synchronized(() async {
      // Mark the store first (best effort): if a deletion then fails, the
      // signed-out session left behind is not restored, now or after a restart.
      // If marking fails, the deletions below are still attempted.
      await _ensureMarked();
      final cleared = await _deleteAllTokenKeys();
      // Known-empty for this generation only if every key is gone; a key that
      // could not be deleted may still hold the signed-out session, so the
      // marker then stays.
      var known = false;
      if (cleared) {
        try {
          await _store.delete(_keyWriteInProgress);
          known = true;
        } catch (_) {
          // The marker stays: restore refuses an (empty) store. Harmless.
        }
      }
      _persistedGeneration = known ? gen : null;
    });
    if (notify) {
      onForceLogout?.call();
    }
  }

  /// Delete all four token keys from the store. Each deletion is independently
  /// best-effort (its own try/catch) so a single failure never leaves a partial
  /// (still-usable) session behind on disk — all four are always attempted.
  /// Returns whether every deletion succeeded.
  Future<bool> _deleteAllTokenKeys() async {
    var cleared = true;
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
        cleared = false;
      }
    }
    return cleared;
  }

  /// Arm the proactive refresh timer for the current token (a no-op after
  /// [dispose]).
  void scheduleNextRefresh() => _scheduleRefresh();

  /// Stop the service for good: cancel the refresh timer and any pending
  /// refresh retry, and keep them from ever being armed again.
  ///
  /// Terminal. Afterwards [refreshSession] / [refreshAccessToken] make no
  /// request (they return [RefreshOutcome.discarded] / false) and
  /// [scheduleNextRefresh] does nothing. A refresh already in flight still
  /// completes: its result is applied as usual (rotated tokens are persisted,
  /// a dead grant logs out), but it schedules neither a retry nor the
  /// proactive refresh.
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _cancelRetry();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_disposed || _expiresAt == null) return;

    var delay = _expiresAt!.difference(DateTime.now()) - _refreshMargin;
    if (delay.isNegative) delay = Duration.zero;

    // Always via a Timer (even Duration.zero) to break the synchronous chain
    // refreshAccessToken → _adopt → _scheduleRefresh.
    _refreshTimer = Timer(delay, () => refreshAccessToken());
  }

  void _scheduleRetry() {
    final policy = _retryPolicy;
    if (_disposed || policy == null || _refreshToken == null) return;
    _retryTimer?.cancel();
    final delay = policy.delayForAttempt(_retryAttempt);
    _retryAttempt++;
    debugPrint(
      '[AuthService] refresh unavailable; retry $_retryAttempt in '
      '${delay.inSeconds}s',
    );
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(refreshSession());
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
  }

  /// Make sure the in-progress marker is present, WITHOUT ever rewriting one
  /// that already is: a failed rewrite can erase it (flutter_secure_storage
  /// on iOS/macOS answers a failed keychain update by deleting the item and
  /// re-adding it), exposing whatever an earlier stopped pass left. Returns
  /// whether the store is known to be marked. If the marker cannot even be
  /// read, it is not written either (false): an unreadable store may hold one.
  Future<bool> _ensureMarked() async {
    try {
      if (await _store.read(_keyWriteInProgress) != null) return true;
    } catch (_) {
      return false;
    }
    try {
      await _store.write(_keyWriteInProgress, '1');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The token store threw during a write pass: tokens are memory-only for
  /// the rest of the process (see _storageAvailable).
  void _storeFailed() {
    _storageAvailable = false;
    debugPrint('[AuthService] token store unavailable — tokens in memory only');
  }

  static bool _isBlank(RefreshTokenField field) =>
      field is RefreshTokenBlank ||
      (field is RefreshTokenPresent && field.value.isEmpty);

  /// Redacted failure log: the operation, the error's class, and (when known)
  /// the HTTP status and Dio error type — nothing else. Never an exception's
  /// `toString()` (it can embed response bodies, URLs carrying codes, or
  /// tokens), never a body, a token, a code, a verifier or a `state`.
  static void _logFailure(String operation, Object error) {
    final String detail;
    if (error is AuthEndpointException) {
      detail =
          '${error.kind} status=${error.statusCode} '
          'dio=${error.dioType?.name}'
          '${error.malformedResponse ? ' malformed-response' : ''}';
    } else if (error is DioException) {
      detail =
          'DioException status=${error.response?.statusCode} '
          'dio=${error.type.name}';
    } else {
      detail = '${error.runtimeType}';
    }
    debugPrint('[AuthService] $operation failed: $detail');
  }

  /// Persist and adopt a token response under the refresh-token rule (see the
  /// class doc). [gen] is the generation snapshot taken by the caller BEFORE
  /// its network round-trip began; if [logout] (or a newer session) has bumped
  /// the generation since, the result is stale and is discarded from both
  /// memory and disk. Returns whether the tokens were adopted.
  ///
  /// [newSession] selects the exchange rule (true) or the refresh rule (false).
  /// Callers reject a blank (null/empty) `refresh_token` before calling.
  Future<bool> _adopt(
    TokenResponse response,
    int gen, {
    required bool newSession,
  }) async {
    final accessToken = response.accessToken;
    if (accessToken.isEmpty) {
      throw const FormatException(
        'Missing or invalid access_token in token response',
      );
    }
    final refreshField = response.refreshToken;
    final String? newRefreshToken = switch (refreshField) {
      RefreshTokenPresent(:final value) when value.isNotEmpty => value,
      RefreshTokenAbsent() => null,
      _ => throw const FormatException(
        'Token response has a null or empty refresh_token',
      ),
    };
    final expiresAt = response.expiresAt;

    var adopted = false;
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

      // A new session supersedes whatever was there: bump the generation so a
      // refresh of the OLD session still in flight is discarded when it lands.
      final current = newSession ? ++_generation : gen;

      // Refresh responses usually omit id_token; keep the current one. A new
      // session never inherits the previous session's id token.
      final idToken = newSession
          ? response.idToken
          : (response.idToken ?? _idToken);

      if (_storageAvailable) {
        // Until this pass completes, the store holds no one session for sure.
        _persistedGeneration = null;
        // 1. A NEW session's pass marks the store mid-write BEFORE touching
        //    any token key (see _keyWriteInProgress): stopped part-way, it
        //    could leave the previous account's keys beside the new one's.
        //    If even the marker cannot be written, skip the pass: the store
        //    keeps whatever complete session it held, untouched. A marker
        //    already present (an earlier pass stopped part-way) is kept as
        //    is, never rewritten (see _ensureMarked).
        //
        //    A refresh pass is not marked, and never touches a marker an
        //    earlier pass left: it rewrites the SAME session, refresh token
        //    first, so wherever it stops the store holds one identity (at
        //    worst the old access token with the new refresh token), which a
        //    restart restores and refreshes with the new refresh token.
        var proceed = true;
        if (newSession && !await _ensureMarked()) {
          _storeFailed();
          proceed = false;
        }
        // 2. The token keys.
        var written = false;
        if (proceed) {
          try {
            // Persist the rotated refresh token BEFORE the access token: a crash
            // between the writes must never leave the OLD (now-revoked) refresh
            // token paired with a new access token, which would trip Hydra's
            // reuse-detection and force a logout on next startup.
            if (newRefreshToken != null) {
              await _store.write(_keyRefreshToken, newRefreshToken);
            } else if (newSession) {
              // A new session must never inherit a previous session's refresh
              // token. (On refresh, an absent field keeps the stored one.)
              await _store.delete(_keyRefreshToken);
            }
            await _store.write(_keyAccessToken, accessToken);
            if (idToken != null) {
              await _store.write(_keyIdToken, idToken);
            } else if (newSession) {
              await _store.delete(_keyIdToken);
            }
            if (expiresAt != null) {
              await _store.write(_keyExpiresAt, expiresAt.toIso8601String());
            } else if (newSession) {
              await _store.delete(_keyExpiresAt);
            }
            written = true;
          } catch (_) {
            _storeFailed();
            // The pass stopped part-way. Clear the token keys (best effort).
            // A new session's marker stays, so whatever the clean-up leaves
            // (the previous session, part of this one, or a mix) is never
            // restored, in this process or after a restart. A refresh pass
            // can only have left this same session's keys.
            await _deleteAllTokenKeys();
          }
        }
        // 3. A new session removes its marker LAST, once the store holds the
        //    session whole. Not if a logout landed during the token writes:
        //    the undo below clears the token keys, and logout's own pass then
        //    decides about the marker. (A logout landing while the marker is
        //    being removed is caught by the undo too, but a crash before the
        //    undo leaves the whole session restorable: a logout is complete
        //    only once its own storage pass has run.)
        if (written && _generation == current) {
          if (!newSession) {
            _persistedGeneration = current;
          } else {
            try {
              await _store.delete(_keyWriteInProgress);
              _persistedGeneration = current;
            } catch (_) {
              // The session stays on disk, whole, but marked: it is not
              // restored after a restart (the user signs in again).
              _storeFailed();
            }
          }
        }
      }

      // Re-check AFTER the writes: if logout landed mid-write, our writes may
      // have hit disk after logout's deletions. Undo them (best-effort) so the
      // disk can't outlive logout, and don't adopt the tokens into memory.
      // Called directly (not via _synchronized) — we already hold the lock.
      if (_generation != current) {
        await _deleteAllTokenKeys();
        // Undone, perhaps not completely: logout's own (queued) deletion pass
        // decides whether the store is known-empty.
        _persistedGeneration = null;
        return;
      }

      // Publish to memory in ONE synchronous step, tagged with the generation
      // these tokens belong to (see _sessionGeneration).
      _accessToken = accessToken;
      if (newRefreshToken != null) {
        _refreshToken = newRefreshToken;
      } else if (newSession) {
        _refreshToken = null;
      }
      _idToken = idToken;
      _expiresAt = expiresAt;
      _sessionGeneration = current;

      _cancelRetry();
      _scheduleRefresh();
      adopted = true;
    });
    return adopted;
  }
}
