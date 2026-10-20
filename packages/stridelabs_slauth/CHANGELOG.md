# Changelog

## Unreleased

A provider-neutral auth core (lumen plan 001, SF1). slauth/Hydra stays the
default: apps that construct `AuthService(config: SlauthConfig, …)` keep
today's behaviour apart from the items under "Changed" and "Security".

### Added
- `TokenEndpoint` (`exchange(TokenExchangeRequest{code, codeVerifier, redirectUri})`,
  `refresh(refreshToken)`), `TokenResponse`, `RefreshTokenField` (absent / present /
  blank); `HydraTokenEndpoint` = slauth `/oauth2/token` with unchanged form posts.
- `AuthService.withEndpoint(endpoint:, store:, refreshRetry:)`.
- Typed errors `AuthUnauthorized` (dead grant → logout) and `AuthUnavailable`
  (transient → session kept), base `AuthEndpointException`.
- `AuthService.refreshSession()` → `RefreshOutcome` (refreshed / unauthorized /
  unavailable / noSession / discarded); concurrent callers refreshing the same
  session share one call with `refreshAccessToken()`.
- Opt-in `RefreshRetryPolicy` (15 s doubling to 5 min) for unavailable refreshes;
  `hasPendingRefreshRetry`.
- Provider-neutral `AuthConfig` + `EndSessionRequest`; `SlauthConfig` implements it.
- `WebAuthOptions` (+ `const WebAuthOptions.defaults`), passed through
  `FlutterWebAuth2Impl(options:)`.

### Changed
- **Refresh-token rule.** On refresh, a missing `refresh_token` now KEEPS the stored
  token (it used to delete it), and `null`/`""` is an upstream error (unavailable,
  nothing adopted). On exchange/`storeTokens`, a missing one gives a session with no
  refresh token (any old one is deleted), and `null`/`""` fails (`storeTokens` throws
  `FormatException`). Unobservable for Hydra, which always rotates.
- A new session never inherits the previous session's id token or expiry.
- **Session identity:** a refresh is tied to the session whose tokens it read. If a
  new sign-in or logout replaces that session while the call is in flight, including
  while the new session is still being written to the store, its result is
  discarded: it can neither overwrite the new session nor log it out. A dead grant
  arriving after the session ended no longer calls `logout()` again.
- `exchangeAuthorizationCode()` returns `false` (not `true`) when a logout or newer
  sign-in discarded its result in flight.
- **Write-in-progress marker.** Every new-session store write (exchange,
  `storeTokens`) and every logout deletion pass is bracketed by a persisted marker
  key, `slauth_write_in_progress`, in the same store: written before any token key,
  removed last once the store holds one whole session (or nothing), and never
  rewritten when already present. `restoreFromStorage()` restores nothing while the
  marker is present, in the same process or after a restart, so such a pass that
  stopped part-way (a failed write, a failed clean-up, a crash) is never restored as
  a stale or mixed-account session; the user signs in again. If even the marker
  cannot be written, the sign-in is memory-only and the store keeps its previous
  complete session (restored after a restart). Refresh writes don't use the marker
  (and never remove one): they rewrite the same account, rotated refresh token
  first, so an interrupted refresh leaves that account restorable with the new
  refresh token. Stores without the marker (written by earlier versions) are trusted
  as before, so upgrading signs nobody out.
  - **Limits:** this assumes a store write/delete is durable when it returns: true
    for the iOS/macOS keychain and (short of power loss: no fsync) the desktop file
    store, but Android's `flutter_secure_storage` persists asynchronously
    (`SharedPreferences.apply()`), so a hard crash shortly after a reported sign-in
    or logout can come back with the previous state. A logout is complete only once
    its storage pass has run (a crash before it, including before its marker lands,
    can restore the signed-out session). Downgrading to an earlier version, which
    ignores the marker, can restore a mixed or signed-out session, and a torn store
    written by an earlier version stays trusted after an upgrade.
- `restoreFromStorage()` only ever fills an empty in-memory session: with a session
  already in memory it reads nothing and returns whether that session is a usable
  access+refresh pair. It also restores nothing once the store has failed in this
  process, when a logout or new sign-in lands before the store is read, or
  (in-process) after a logout that could neither mark the store nor delete its keys.
- A token-store write that fails part-way now also clears the token keys (best
  effort); tokens stay in memory only for the rest of the process, as before.
- `dispose()` is terminal: afterwards refreshes make no request (discarded / false)
  and nothing re-arms the proactive or retry timer; a refresh in flight at dispose
  still persists its result but schedules nothing.
- `HydraTokenEndpoint` classifies the HTTP status itself (per-request
  `validateStatus`, error bodies never decoded): 400/401 are `AuthUnauthorized` even
  with a permissive injected Dio or a non-JSON error body.
- `WebAuthOptions.timeout` is rounded UP to whole seconds (500 ms → 1 s);
  zero/negative throws `ArgumentError`, so the `WebAuthOptions` constructor is not
  `const` (use `WebAuthOptions.defaults` for a const instance).

### Security
- Redacted logs: no exceptions, stack traces or token-endpoint bodies (the code
  exchange used to print `body=…`). Each failure line carries only the operation,
  the error class, the HTTP status and the Dio error type.
- `HeadlessLoginException` messages no longer contain the authorize URL (state,
  PKCE challenge), response bodies, callback values (only registered OAuth2 error
  codes) or wrapped Dio/JSON exception text; network and decode errors are reduced
  to step + HTTP status + Dio category / error class.

## 0.1.0

Initial release (extracted from the slaudio mobile app).
