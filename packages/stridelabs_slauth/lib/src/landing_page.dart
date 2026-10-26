/// The page [LoopbackWebAuth] serves to the browser for the accepted sign-in
/// callback unless the app passes its own (`landingPageHtml`), with
/// `Content-Type: text/html; charset=utf-8`.
///
/// It says only what is true at that moment: the callback reached the app,
/// which has still to validate it and exchange the code, so it never claims
/// success. Self-contained by design: inline CSS only, no script, no external
/// resource, and a `data:` icon so the browser makes no `/favicon.ico`
/// request. It is a constant, so it cannot echo the query. It deliberately
/// does not call `history.replaceState`: the address bar keeps the code,
/// which is short-lived, single-use and bound to the PKCE verifier that only
/// the app holds.
///
/// An app's own page should keep the same properties; it typically names the
/// app instead of "the app".
library;

import 'loopback_web_auth.dart' show LoopbackWebAuth;

/// [LoopbackWebAuth]'s default landing page: a neutral, minimal HTML document.
const String defaultLandingPageHtml = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="data:,">
<title>Sign-in</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  main { max-width: 32rem; padding: 2rem; text-align: center; }
  p { margin: 0; font-size: 1.125rem; line-height: 1.6; }
</style>
</head>
<body>
<main>
<p>Return to the app to finish signing in. You can close this tab.</p>
</main>
</body>
</html>
''';
