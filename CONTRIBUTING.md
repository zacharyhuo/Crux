# Contributing to Crux

Crux is an early preview. Work on `develop/v1` unless the maintainer asks for a
different branch, and keep changes focused enough to review and test. Read
[README.md](README.md) for the build prerequisites and [AGENTS.md](AGENTS.md)
for the repository's development safety rules.

## Before changing behavior

Describe the user-visible problem, expected behavior and affected source boundary
in your issue or pull request. For an established behavior or dependency change,
agree on the contract with the maintainer before implementation and update the
public description with the code. Local planning notes may exist in a developer's
checkout; contributors do not need private documents to understand a proposed change.

Crux owns the macOS reader, library, search and installation. Recipes, builders
and documentation publication belong in [crux-docset](https://github.com/zacharyhuo/crux-docset).
Server contracts and proposed backend work belong in
[crux-server](https://github.com/zacharyhuo/crux-server). Preserve the separate
Zeal raw-array and Crux versioned catalog contracts.

## Build prerequisites

Use macOS 26+, Apple Silicon and an Xcode toolchain with Swift 6.2+ and the macOS
26 SDK. Build the pinned native dependency from the repository root first:

```sh
./scripts/build-libarchive-xcframework.sh --build
```

CruxCore requires `Artifacts/CLibArchive.xcframework`; it is not committed or
optional. The script pins libarchive 3.8.9 and verifies its source archive. Changing
the source pin, Swift dependency or archive policy needs an explicit explanation
and updated provenance. Do not substitute an untracked Homebrew binary.

## Testing without touching a user's library

Use the shared `Crux Beta` scheme for development and generated-docset GUI tests.
Its bundle identifier is `com.zacharyhuo.Crux.Beta`, with BetaDebug/BetaRelease
configurations. Production and Beta share source; keep differences limited to
branding, build configuration and data isolation.

```sh
swift test --package-path Packages/CruxCore

xcodebuild test \
  -project Crux.xcodeproj \
  -scheme 'Crux Beta' \
  -configuration BetaDebug \
  -destination 'platform=macOS' \
  -derivedDataPath build/BetaTests \
  CODE_SIGN_IDENTITY=-
```

Core fixtures must allocate disposable directories. App-hosted/UI tests must use
the existing isolated Debug/XCTest runtime. Do not launch, quit or replace the
user's production app for Beta tests, or copy production preferences, libraries
or security-scoped bookmarks into Beta. A fixture-gated test that skips is not
evidence that the corresponding acceptance passed.

Add focused regressions for parsing, search, archive safety and replacement
behavior. Native interaction changes need a Beta UI check where practical.
Performance changes should run the optimized search gates listed in the README.
Application-update tooling has its own checks:

```sh
node --test tools/app-updates/test/*.test.mjs
git diff --check
```

State which checks ran and what they establish. Public hosting, sandboxed update
installation, relaunch, Gatekeeper and notarization need their own acceptance;
local fixtures do not cover those release conditions.

## Review and source attribution

Preserve unrelated work in a shared checkout. Stage only the files you intend to
submit. Keep comments about why a decision exists rather than narrating syntax,
and update both READMEs when a documented user-facing capability changes.

For copied or adapted code, fixtures, icons or documentation, identify the exact
upstream version, source and applicable terms, and retain the required notices.
Behavioral reference and wire-format compatibility should be described as such.
Do not copy GPL-covered Zeal implementation code and describe it as original MIT
code. See [PROVENANCE.md](PROVENANCE.md) for the reviewed boundary.

Contributions to Crux-owned code use the [MIT license](LICENSE). Contributors
must have the rights to submit their changes; a coauthor trailer does not
substitute for a rights record.
Generated documentation and sibling repositories retain their own terms.

Do not commit generated docsets, build caches, private keys, tokens or user data.
Report security concerns through the guidance in [SECURITY.md](SECURITY.md).
