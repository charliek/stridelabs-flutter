# stridelabs-flutter

Shared Flutter/Dart packages for StrideLabs native apps, extracted from the
slaudio mobile app so multiple apps can depend on one implementation.

## Packages

| Package | What it is |
| --- | --- |
| [`packages/stridelabs_slauth`](packages/stridelabs_slauth) | slauth (Ory Hydra + Kratos) OAuth2 PKCE client: system-browser login, token exchange, refresh with rotation, at-rest token storage (keychain on mobile, `0600` files on desktop), and a debug-only headless password login for local E2E driving. |
| [`packages/stridelabs_drive`](packages/stridelabs_drive) | Debug-only agent-driving helpers built on [Marionette](https://pub.dev/packages/marionette_flutter): binding bootstrap, `flutter test` detection, and the greppable `MSTATE`/`MRESULT` drive-state log contract. Tree-shakes out of release builds. |
| [`packages/stridelabs_logging`](packages/stridelabs_logging) | Namespaced app logging: a `debugPrint` wrapper that tags each line with a subsystem area (`[area] message`), plus a crash-sink seam for a future crash-reporting backend. |

## Consuming a package

These packages are **not published to pub.dev**. Depend on them as git
dependencies pinned to a release tag, from the app's `pubspec.yaml`:

```yaml
dependencies:
  stridelabs_slauth: {git: {url: git@github.com:charliek/stridelabs-flutter.git, ref: v0.1.0, path: packages/stridelabs_slauth}}
```

The `path:` selects the package subdirectory within this monorepo; `ref:` pins
the release tag. Do the same for `stridelabs_drive` / `stridelabs_logging`
(adjust the `path:`).

## Releasing (pin-and-bump)

This repo follows the same convention as
[stridelabs-python](https://github.com/charliek/stridelabs-python): consumers
pin to an immutable tag and bump deliberately.

1. Land your change on `main` (CI green).
2. Bump the affected package's `version:` in its `pubspec.yaml`.
3. Tag the release on `main` and push the tag:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
4. In each consuming app, bump the `ref:` in its git dependency to the new tag
   and run `flutter pub get`. Nothing moves until a consumer bumps, so an
   in-flight app is never disrupted by a new release.

## Local development

To iterate on a package and a consuming app together, temporarily point the
app's dependency at a local checkout with a path dependency (instead of the git
dependency), then run `flutter pub get`:

```yaml
dependencies:
  stridelabs_slauth:
    path: ../stridelabs-flutter/packages/stridelabs_slauth
```

Revert to the git dependency (pinned to a tag) before committing the app.

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs a matrix over the
three package directories on every push to `main` and every PR, checking each
with `dart format --set-exit-if-changed`, `flutter analyze`, and `flutter test`
on Flutter 3.44.6.
