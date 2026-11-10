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

## Android App Link callback (https, opt-in)

By default the callback is a custom scheme (`myapp://auth/callback`), which
any installed app can also claim, so slauth screens it with a consent page on
every sign-in. An https redirect that Android verifies as the app's App Link
can't be claimed by another app, so slauth can let it through silently. Opt
in per build; nothing changes for an app that keeps its custom scheme.

1. **Register** the https redirect for the client in slauth (its `app_links`
   block), and publish `/.well-known/assetlinks.json` on the link's host
   naming the package and each signing certificate's SHA-256.
2. **Sign in with it.** Set `redirectUri` to the link, and build the browser
   options from it:
   ```dart
   final redirect = Uri.parse(config.redirectUri); // https://host/app/myapp/callback
   final webAuth = FlutterWebAuth2Impl(
     options: WebAuthOptions.forRedirect(redirect),
   );
   await webAuth.authenticate(
     url: config.authorizeUrl(codeChallenge: challenge, state: state),
     callbackUrlScheme: config.callbackUrlScheme, // 'https'
   );
   ```
   `forRedirect` sets `httpsHost` and `httpsPath` from an https redirect and
   returns the base options unchanged for any other scheme, so one code path
   serves both builds. It refuses an https redirect with no host, a trailing
   dot, userinfo, a port, a query, a fragment, or no path beyond `/`.
   `FlutterWebAuth2Impl` refuses an `https` `callbackUrlScheme` without both
   values; the plugin would otherwise launch `https` as a custom scheme and
   never return.
3. **Declare the filter** on the plugin's `CallbackActivity`, in its own
   `<intent-filter>`, beside the custom-scheme one:
   ```xml
   <activity
       android:name="com.linusu.flutter_web_auth_2.CallbackActivity"
       android:exported="true">
     <intent-filter android:label="flutter_web_auth_2">
       <action android:name="android.intent.action.VIEW" />
       <category android:name="android.intent.category.DEFAULT" />
       <category android:name="android.intent.category.BROWSABLE" />
       <data android:scheme="myapp" android:host="auth" android:path="/callback" />
     </intent-filter>
     <intent-filter android:autoVerify="true">
       <action android:name="android.intent.action.VIEW" />
       <category android:name="android.intent.category.DEFAULT" />
       <category android:name="android.intent.category.BROWSABLE" />
       <data android:scheme="https" android:host="auth.example.com"
             android:path="/app/myapp/callback" />
     </intent-filter>
   </activity>
   ```
   Name the exact callback with `android:path`. **Never** `pathPrefix`,
   `pathPattern` or a host-only filter: on a shared host (the auth domain) a
   broader filter would also capture its password-recovery and verification
   mail links. Don't add the plugin's optional `ACTION_SEND` text/plain filter
   either: it lets any app hand `CallbackActivity` a callback URL.

How the callback comes back: in a browser with Auth Tab support (androidx
browser 1.9's `AuthTabIntent`), the browser itself checks the app's link and
returns the redirect to the plugin; a failed check fails the sign-in. In other
browsers the redirect leaves the Custom Tab as an App Link and reaches
`CallbackActivity` through the filter above, which Android only routes to a
verified app (API 31+; older versions may show a chooser). Either way,
check the callback's scheme, host, path and `state` as you do for a custom
scheme.

Keep `postLogoutUri` on the custom scheme: logout has no consent step, and
`forRedirect` only describes the sign-in redirect. Desktop and iOS keep the
custom scheme (`LoopbackWebAuth` below for desktop).

## Desktop: `LoopbackWebAuth` (opt-in)

On desktop, `flutter_web_auth_2` has no OS secure browser. Its default is an
embedded webview window (not the user's browser, so no saved logins or
passkeys), and its `useWebview: false` server mode cancels a pending sign-in
whenever the app regains focus (which going to the browser and back does), lets
the last request to its server win (a favicon fetch included), and builds the
result from request headers.

`LoopbackWebAuth` is a `WebAuth` for that case: the native-app loopback redirect
of [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252#section-7.3). It opens the
authorize URL in the user's default browser (`url_launcher`) and waits for the
redirect on an `HttpServer` it binds on `127.0.0.1:<port>` itself:

```dart
final webAuth = LoopbackWebAuth(
  redirect: Uri.parse('http://127.0.0.1:8765/auth/callback'), // registered with the provider
  landingPageHtml: myLandingPage, // optional; defaultLandingPageHtml otherwise
);
final callback = await webAuth.authenticate(
  url: config.authorizeUrl(codeChallenge: pkce.challenge, state: state),
  callbackUrlScheme: webAuth.redirect.toString(), // the redirect itself
);
// ...then validate the callback and exchange the code, as for any WebAuth.
```

Nothing selects it for you: `FlutterWebAuth2Impl` is unchanged, and the app
decides on which platforms to use it (it is proven on Linux).

- **The redirect** must be `http://127.0.0.1:<port>/<path>`, a port from 1024
  to 65535 (no root needed), with no user info, query or fragment
  (`LoopbackWebAuth.isLoopbackRedirect`); anything else throws `ArgumentError`.
  The port is fixed, so it can be registered with the provider.
- **What it accepts:** exactly one request, a `GET` for the redirect's path
  whose query has exactly one `state`, equal to the authorize URL's. That
  request gets the landing page (`text/html; charset=utf-8`, `no-store`, a 2 s
  bound) and the sign-in completes with the configured redirect plus that
  query, never anything taken from `Host` or `X-Forwarded-*`. Everything else
  gets a 404 (400 for a query that does not decode) and the server keeps
  listening. One attempt at a time: a newer `authenticate` cancels the pending
  one. The port is released on every outcome before the future settles.
- **`InteractiveWebAuth`:** `cancel()` ends the pending sign-in (a plain
  `PlatformException(code: 'CANCELED')`); `reopen()` opens the same authorize
  URL again while it keeps waiting. No app-lifecycle observer: refocusing the
  app changes nothing.
- **Typed failures**, each a `LoopbackAuthFailure` (a `PlatformException`
  carrying `hostPort`): `LoopbackPortBusy` (the port is held, by another
  program or another window of the app), `LoopbackNoBrowser` (the launcher
  failed or the browser check said no) and `LoopbackTimeout` (`timeout`,
  default 5 minutes). Their messages never carry the authorize URL.
- **Seams:** `BrowserLauncher` (default `launchInDefaultBrowser`),
  `BrowserCheck` (asked before each launch) and `DeadlineTimerFactory` (tests).
  With the default launcher on Linux the check defaults to
  `linuxDefaultBrowserCheck`: `url_launcher_linux` reports success even when no
  application handles the URL, so it asks `gio mime` (or `xdg-mime`) in a
  separate process, bounded to 2 s, and only a definite "no default" stops the
  launch. Elsewhere, or with an injected launcher, there is no check unless you
  pass one.
- **The landing page:** `defaultLandingPageHtml` is a neutral page ("Return to
  the app to finish signing in"). An app passes its own to name itself; keep it
  self-contained (no script, no external resource, a `data:` icon so the
  browser asks for no favicon) and never claim success, since the app has yet
  to validate the callback and exchange the code.
- **What stays in the app:** the provider's config (client id, authorize URL,
  the registered redirect and its port), the callback validation (destination,
  `state` strictly equal, at most one `state`/`code`/`error`, an `error`
  mapped before any exchange), the landing page's wording, the messages for
  each failure, and the choice of platforms.

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
signs that environment out once, as nothing is migrated. Desktop ignores it: its
directory comes from `appName`, so an app whose environments share one desktop
`appName` keeps its own wrapper that namespaces desktop too.

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

`HeadlessLogin` signs in with one `POST /api/v1/account/login` (JSON
`{email, password}`, which sets the session cookie) and then drives the PKCE
redirect chain without a browser, for local E2E. It throws if constructed in a
release or profile build. Persist its result with `AuthService.storeTokens`.

If a hop lands on slauth's consent page (`/consent?flow=...`, shown to
first-party custom-scheme clients on every authorize), it approves the request
through `POST /api/v1/oauth/consent/accept` (`{flow}`) without asking anyone,
then carries on. The page itself is never fetched.

**Origin.** slauth requires the auth UI's exact `Origin` (and a JSON content
type) on both POSTs, so `HeadlessLogin` sends `SlauthConfig.baseUrl`'s origin.
That assumes `baseUrl`'s origin equals slauth's `AUTH_UI_URL` origin, which holds
for local slauth (prox, `native-stack.sh`) and both deployed environments. A
`baseUrl` that reaches slauth through a different host fails at the login step
with `login failed: badResponse (HTTP 403)`.

**Needs slauth at or after N7.** v0.3.0 has no fallback to the `/.ory` shim:
against an older slauth the login POST fails with a 4xx, such as `login failed:
badResponse (HTTP 405)` from an N6-era slauth, whose fallback refuses the POST.

Every failure is a `HeadlessLoginException` whose message is safe to print. It
names the step (e.g. `authorize hop 2`, `consent accept`, `token exchange`) plus, at most, an
HTTP status, a Dio error category, an error class or a registered OAuth2 error
code. It never includes a URL (the authorize URLs carry `state` and the PKCE
challenge), a consent flow handle, a response body, a callback value or another exception's text.
Network and JSON-decode errors are reduced to that form rather than passed
through.

`test/headless_login_live_test.dart` runs the flow against a real
N7 slauth; it's skipped unless `SLAUTH_LIVE_BASE` is set.
