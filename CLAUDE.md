# CLAUDE.md — stridelabs-flutter conventions

Conventions for working in this repository, for contributors and coding
agents. The [README](README.md) covers the packages, how to consume one,
releasing (pin-and-bump), local development and CI. Read it first.

## What this is

Shared Flutter/Dart packages for StrideLabs native apps, in `packages/`:
`stridelabs_slauth`, `stridelabs_drive` and `stridelabs_logging`. They are
not published to pub.dev. Consumers depend on them as git dependencies over
`https`, pinned to a release tag.

## What belongs here

These packages are shared by the StrideLabs apps that adopt them. Keep them
strong and following best practice across apps, but pragmatic: the library
must never be what holds an app's work back.

- **What earns a place.** Either reason is enough:
  1. it codifies a convention apps should share, such as auth, logging or
     agent-driving hooks;
  2. it is a specific capability two or more apps reuse, even when it is not
     a convention.

  Judge a reused client by its reuse, not by how specific it looks. Evidence
  from production apps outweighs evidence from experimental ones.
- **What stays in the app.** Code only one app needs stays in that app,
  written so it can be lifted later: an internal package with a narrow API,
  no dependency on the app's configuration, state management or types, and
  its own tests. Moving it here is then a copy, not a refactor.
- **Additive and opt-in.** A change made for one app must not limit another.
  New behaviour goes behind an option, a parameter that keeps today's default,
  or a separate entry point, and policy stays with the consumer.
  - A changed default that touches persisted state (secure-storage keys, file
    locations) needs a migration path, or every consumer's users are signed
    out.
  - Auth stays provider- and deployment-flexible (`TokenEndpoint`,
    `AuthConfig`): no baked-in hosting shape, issuer setup or transport.
- **Curate.** This repo follows the same rules. Patterns only one app uses,
  and complexity that exists to reproduce a legacy implementation rather than
  a standard, get trimmed. Prefer deleting code to adding machinery.
- **Contributing from an app.** An app that finds a general gap fixes it here,
  with CI green and a review. The app pins the merged commit (a SHA in `ref:`)
  until a release tag includes it. If the change would block the app's own
  milestone, the app implements it locally first and upstreams it in parallel.

## Releases

Follow the README's "Releasing (pin-and-bump)".
- **Before tagging:** check with the active consumers and with anyone who
  has unreleased work on `main`, and don't take a version number someone
  else has planned.
- **After tagging:** tell consumers the tag. Nothing moves until a consumer
  bumps its `ref:`.
