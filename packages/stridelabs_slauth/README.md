# stridelabs_slauth

OAuth2 authorization-code + PKCE (S256) client for StrideLabs native apps:
system-browser login, token exchange, refresh with rotation, at-rest token
storage, and a debug-only headless login.

slauth (Ory Hydra + Kratos) is the default and needs no extra wiring. Any other
provider plugs in through two seams: an [`AuthConfig`](lib/src/auth_config.dart)
for the browser half and a [`TokenEndpoint`](lib/src/token_endpoint.dart) for
the token half.

```yaml
dependencies:
  stridelabs_slauth:
    git:
      url: https://github.com/charliek/stridelabs-flutter.git
      ref: vX.Y.Z # a release tag that has this API, or a reviewed commit
      path: packages/stridelabs_slauth
```

## slauth (Hydra): the default

```dart
const config = SlauthConfig(
  baseUrl: 'https://auth.local.stridelabs.ai',
  clientId: 'myapp-mobile',
  audience: 'myapp', // explicit; never the client id
  redirectUri: 'myapp://auth/callback',
  postLogoutUri: 'myapp://auth/logout',
);

final auth = AuthService(config: config, store: defaultTokenStore(appName: 'myapp'));
```

`AuthService(config: ...)` talks to slauth's `/oauth2/token` through
[`HydraTokenEndpoint`](lib/src/token_endpoint.dart), exactly as before this
package grew the endpoint seam: the same form posts, the same timeouts, the same
"log out only on 400/401" rule.

## The browser half: `AuthConfig`

`AuthConfig` is what a login screen needs, whatever the provider:

| Member | Meaning |
| --- | --- |
| `clientId` | the OAuth2 client id |
| `redirectUri` | the registered redirect URI (sent again on the exchange) |
| `callbackUrlScheme` | the scheme the system browser intercepts (default: `redirectUri`'s) |
| `authorizeUrl(codeChallenge:, state:)` | the authorize URL for one attempt |
| `endSessionRequest(idTokenHint:)` | the RP-initiated logout step, or `null` for none (the default) |

`SlauthConfig` is the slauth implementation; its fields, constructor and the
`buildAuthorizeUrl` / `buildEndSessionUrl` functions are unchanged. A login
flow written against `AuthConfig`:

```dart
final pkce = Pkce.generate();
final state = Pkce.generateState();
final callback = await webAuth.authenticate(
  url: config.authorizeUrl(codeChallenge: pkce.challenge, state: state),
  callbackUrlScheme: config.callbackUrlScheme,
);
// Validate scheme/host/path, `state` (strict equality) and `error` first.
final ok = await auth.exchangeAuthorizationCode(
  callback.queryParameters['code']!,
  codeVerifier: pkce.verifier,
  redirectUri: config.redirectUri,
);
```

`exchangeAuthorizationCode` returns `true` only when the new session was
adopted (memory and store). It returns `false` when the exchange fails, and also
when a `logout()` (or another sign-in) lands while it is in flight and the new
tokens are discarded, so `true` can always be read as "signed in".

Another provider implements `AuthConfig` itself. WorkOS AuthKit, for example,
authorizes at `https://api.workos.com/user_management/authorize` (or
`https://<authkit-domain>/oauth2/authorize`) with `client_id`, `redirect_uri`,
`response_type=code`, `code_challenge`, `code_challenge_method=S256`, `state`
and `provider=authkit`, and has no end-session step (see the example in
[`auth_config.dart`](lib/src/auth_config.dart)).

## The token half: `TokenEndpoint`

```dart
abstract class TokenEndpoint {
  Future<TokenResponse> exchange(TokenExchangeRequest request); // code, codeVerifier, redirectUri
  Future<TokenResponse> refresh(String refreshToken);
}
```

An app whose tokens come from somewhere else (e.g. its own backend bridging
WorkOS) implements it and passes it to `AuthService.withEndpoint`:

```dart
final auth = AuthService.withEndpoint(
  endpoint: MyBackendTokenEndpoint(dio),
  store: defaultTokenStore(appName: 'myapp'),
  refreshRetry: const RefreshRetryPolicy(), // optional; off by default
);
```

`TokenResponse.fromJson` / `TokenResponse.fromBody` parse a standard OAuth2
token response (`access_token`, `refresh_token`, `id_token`, `expires_at` or
`expires_in`); `fromBody` also accepts a raw JSON string (Dio returns one when
the Content-Type sniff misses). `TokenResponse.refreshToken` is a
`RefreshTokenField` with three states: `RefreshTokenAbsent`,
`RefreshTokenPresent(value)` and `RefreshTokenBlank` (present but `null` or
`""`). When the upstream does not return an expiry, fill `expiresAt` yourself
(e.g. from the access token's `exp`); with no expiry, `isTokenExpired` is always
true and no proactive refresh is scheduled.

### Typed errors

Endpoints classify failures; `AuthService` decides what to do with them.

| Error | Meaning | On refresh |
| --- | --- | --- |
| `AuthUnauthorized` | the grant is dead | `logout()` (fires `onForceLogout`) |
| `AuthUnavailable` | a transient or upstream fault | session kept, memory and store |

Anything else an endpoint throws is treated as `AuthUnavailable`. A failed
exchange never logs out. `HydraTokenEndpoint` maps HTTP 400 and 401 to
`AuthUnauthorized`, and every other status (including 408 and 429), timeouts,
connection errors and malformed 2xx bodies to `AuthUnavailable`. It classifies
the status itself, before any error body is read, whatever the injected `Dio`'s
`validateStatus`: a 401 with an HTML or non-JSON body is still
`AuthUnauthorized`. Both errors carry only an HTTP status, a Dio error type and
a malformed-body flag, so their `toString()` is safe to log.

### Refresh outcomes

`refreshAccessToken()` keeps its `bool` result. `refreshSession()` says what
happened:

| `RefreshOutcome` | Meaning |
| --- | --- |
| `refreshed` | new tokens adopted |
| `unauthorized` | dead grant; logged out |
| `unavailable` | transient fault; session kept (retry scheduled if enabled) |
| `noSession` | no refresh token to use |
| `discarded` | the session ended (logout or a new sign-in) while the call was in flight, so its result was not applied; or the call was made after `dispose()`, so no request was sent (a refresh already in flight at `dispose()` is applied: see Disposal) |

Concurrent callers of either method share one endpoint call, as long as they
are refreshing the same session. A refresh is tied to the session whose tokens
it read: if a new sign-in replaces that session while the call is in flight
(even one that is still being saved to the store), the result is discarded.
It cannot overwrite the new session or log it out, and a refresh of the new
session gets its own call.

### Opt-in retry

`RefreshRetryPolicy` (default: 15 s doubling to a 5 min cap) makes an
`unavailable` refresh schedule a retry. The retries stop on any successful
refresh, on a dead grant, on `logout()` and on `dispose()`.
`hasPendingRefreshRetry` reports whether one is scheduled. With it, an
unavailable refresh at launch leaves the user signed in with a retry pending.
It is off unless you pass a policy.

### Disposal

`dispose()` is terminal. It cancels the proactive refresh timer and any pending
retry, and nothing re-arms them. After it, `refreshSession()` /
`refreshAccessToken()` make no request (`discarded` / `false`) and
`scheduleNextRefresh()` does nothing. A refresh already in flight still
completes and its result is applied: rotated tokens are persisted, because the
server has already revoked the old refresh token, and a dead grant still logs
out. It just schedules nothing.

## The refresh-token rule

What `AuthService` does with a token response's `refresh_token` field:

| Field | On refresh | On exchange / `storeTokens` (a new session) |
| --- | --- | --- |
| absent | keep the stored refresh token (memory and store) | no refresh token; any stored one is deleted |
| a value | replace it, written to the store before the access token | store it |
| `null` or `""` | upstream error: `unavailable`, nothing adopted (not even the access token) | the exchange returns `false` (`storeTokens` throws `FormatException`); nothing stored |

A new session also never inherits the previous session's id token or expiry:
absent fields delete the stored ones.

**Behaviour change.** Before this rule, a refresh response with a missing or
`null` `refresh_token` *deleted* the stored refresh token. Now a missing field
keeps it, and a `null`/empty one is an upstream error that leaves the session
untouched. Hydra always rotates the refresh token (with reuse detection), so for
slauth consumers the change is unobservable in practice.

## System browser: `WebAuthOptions`

`FlutterWebAuth2Impl` takes optional `WebAuthOptions`, passed through to
`flutter_web_auth_2`:

```dart
final webAuth = FlutterWebAuth2Impl(
  options: WebAuthOptions(preferEphemeral: true, useWebview: true),
);
```

Fields: `preferEphemeral`, `useWebview` (Linux/Windows), `timeout`,
`httpsHost`, `httpsPath`, `intentFlags`, `customTabsPackageOrder`,
`landingPageHtml`, `windowName`, `debugOrigin` and `silentAuth`. Unset fields
fall back to the plugin's defaults, so `const FlutterWebAuth2Impl()` (which uses
the `const WebAuthOptions.defaults`) makes the same call as before. The
`WebAuth` interface is unchanged.

`timeout` must be positive: `WebAuthOptions(timeout: Duration.zero)` throws an
`ArgumentError`. That is why the `WebAuthOptions` constructor is not `const`.
The plugin takes whole seconds, so a fractional timeout is rounded up
(500 ms becomes 1 s), never down to zero.

## Logging

`AuthService` logs failures with `debugPrint` as one redacted line: the
operation, the error class, the HTTP status and the Dio error type, e.g.
`[AuthService] refresh failed: AuthUnavailable status=503 dio=badResponse`. It
never logs a token, an authorization code, a PKCE verifier, a `state`, a
response body or an exception's `toString()`. `TokenExchangeRequest`,
`TokenResponse`, `RefreshTokenPresent` and `EndSessionRequest` redact their
`toString()` too.

## Storage

`TokenStore` with `SecureStorageTokenStore` (Android/iOS keychain/keystore),
`FileTokenStore` (desktop, `0600` files in a `0700` dir) and
`InMemoryTokenStore`; `defaultTokenStore(appName:)` picks per platform.

`NamespacedTokenStore(inner, namespace: 'x')` keeps every key under `x.` in
`inner`. On Android/iOS every build of an app shares one secure store under the
same `slauth_*` keys, so a dev build installed over a prod one (same application
id) restores the prod session. `defaultTokenStore(appName:, mobileNamespace:)`
opts out: with `mobileNamespace: 'myapp-dev'` the mobile keys become
`myapp-dev.slauth_*`. The default (`null`) keeps today's plain `slauth_*` keys,
so an app that already has sessions in the field is untouched; opting in later
signs that environment out once, as nothing is migrated. Desktop ignores it.

`restoreFromStorage()` (app start) only ever fills an empty in-memory session.
If a session is already in memory (a sign-in that finished first, or an earlier
restore), it leaves it alone and returns whether it is a usable access+refresh
pair, so an app awaiting it at startup sees `true` whenever it is signed in.

### What a restart can restore

Every write of a **new** session (sign-in, `storeTokens`) and every `logout()`
deletion pass is bracketed by a marker key, `slauth_write_in_progress`, kept in
the same store as the tokens. It is written before any token key is touched and
removed last, only once the token keys hold one whole session (or are all
gone). `restoreFromStorage()` restores nothing while the marker is present, in
the same process or after a restart. Such a pass could otherwise stop with the
previous account's keys next to the new one's. A marker that is already present
(left by an earlier pass that stopped) is kept as it is, never rewritten: on
iOS and macOS a failed keychain update deletes the item before re-adding it, so
a rewrite could erase it.

A refresh does not use the marker, and never removes one an earlier pass left.
It rewrites the same account's session with the rotated refresh token first.
Wherever it stops, the store holds that one account: at worst its old access
token with the new refresh token, which a restart restores and refreshes with
the new refresh token.

| What happened to the store | The tokens, from then on | After a restart |
| --- | --- | --- |
| The write completed | persisted | that session is restored |
| A sign-in's token write failed part-way | memory only; the token keys are cleared, best effort | nothing is restored, even if the clean-up failed too |
| The process died during a sign-in's write | | nothing is restored |
| A sign-in's marker could not be removed | memory only; the whole session stays on disk | nothing is restored |
| A sign-in's marker could not even be written | memory only; the write is skipped and the store keeps its previous complete session (or stays empty) | that previous session is restored |
| A refresh's token write failed part-way | memory only; the token keys are cleared, best effort | nothing, or (if the clean-up failed too) the same account's session. If its stored refresh token has since been rotated away in memory, that session's next refresh fails and the user signs in again |
| The process died during a refresh's write | | the same account's session; the next refresh uses the new refresh token if it was written |
| `logout()` could not delete every key | (signed out) | nothing is restored |
| The process died before `logout()`'s marker landed | (signed out) | the signed-out session is restored |
| `logout()` could neither write the marker nor delete the keys | (signed out) | the signed-out session is restored: nothing in the store can say otherwise. Within the same process, restore still refuses |

Nothing is restored when the store failed earlier in the same process, or when
a `logout()` or new sign-in lands before the store is read. "Nothing is
restored" means the user signs in again.

A store without the marker is trusted. That covers a completed write, and also
stores written by earlier versions of this package, which never write the
marker, so upgrading signs nobody out.

#### Limits

- **A logout is complete only once its storage pass has finished.** `logout()`
  clears memory at once, but its deletions queue behind any write already in
  progress. A crash before they run lets the restart restore the session that
  was being signed out. That includes a `logout()` that lands while a sign-in
  is removing its marker: if the process dies before the sign-in's own
  clean-up runs, the restart restores the new sign-in's session.
- **The store must be durable when a write or delete returns.** The table
  assumes that a write or delete reported as successful has reached storage.
  The iOS/macOS keychain behaves that way. The desktop store (`FileTokenStore`:
  one `0600` file per key, written to a temp file and atomically renamed)
  survives a process crash, but it does not `fsync`, so it gives no guarantee
  across a power loss. On Android, `flutter_secure_storage` persists through
  `SharedPreferences.apply()`, which reports success before the data is on
  disk. A hard crash shortly after a sign-in or logout that reported success
  can therefore come back with the previous state, including an unmarked
  previous session.
- **Downgrades.** Earlier versions of this package ignore the marker.
  Downgrading the app over a marked store can restore a mixed or signed-out
  session. In the other direction, a torn store written by an earlier version
  carries no marker, so it stays trusted after an upgrade.

## Debug-only headless login

`HeadlessLogin` drives Kratos password login and the PKCE redirect chain without
a browser, for local E2E. It throws if constructed in a release or profile
build. Persist its result with `AuthService.storeTokens`.

Every failure is a `HeadlessLoginException` whose message is safe to print. It
names the step (e.g. `authorize hop 2`, `token exchange`) plus, at most, an
HTTP status, a Dio error category, an error class or a registered OAuth2 error
code. It never includes a URL (the authorize URLs carry `state` and the PKCE
challenge), a response body, a callback value or another exception's text.
Network and JSON-decode errors are reduced to that form rather than passed
through.
