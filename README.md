<p align="center">
  <img src="Crux/AppIcon.icon/Assets/crux-light.png" alt="Crux app icon" width="128" height="128">
</p>
<h1 align="center">Crux</h1>
<p align="center">A native macOS reader for offline developer documentation.</p>
<p align="center"><a href="README.zh-CN.md">简体中文</a> · English</p>

## Early Preview

Crux is an open-source SwiftUI/AppKit reader for Dash-compatible docsets. You can
install documentation, search symbols and read local pages in a tabbed workspace.
The project also provides a codebase for learning Swift and native macOS development.

This is an early preview. Client features, documentation supply and application
delivery have different acceptance stages. Public anonymous downloads and keyed
Sparkle releases still need rollout acceptance; local tests and private release
records do not establish that public hosting is ready.

## Why Crux

When you need an API signature or a reference page while coding, an installed
docset keeps that lookup available without a network connection. Crux brings
symbol search and HTML documentation into a native macOS workspace, with keyboard
commands, per-tab history and a library you control.

Crux reads the Dash docset format and uses Zeal as a compatibility and behavior
reference. The client, docset builders and proposed server live in separate
repositories so readers can work with local bundles without running a backend.

## Features

These features have implementations and focused tests in the current source tree:

- Import expanded `.docset` bundles and supported archives; discover and install
  catalog entries, subscribe to Dash XML feeds, and manage download progress.
- Add, rename, enable or disable documentation sources. With multiple sources
  enabled, the library groups entries by source and identifies their origin.
- Search Dash and legacy ZDash symbol indexes, filter by docset or symbol type,
  and browse related results. Entering a recognized `prefix:` selects that docset.
- Enable full-text indexing per docset, with grouped page results and indexing progress.
- Read local HTML with tabs, back/forward history, page search, a table of contents,
  zoom and optional session restoration.
- Choose a library directory and migrate installed docsets. Control remote page
  resources globally or per docset; offline completeness depends on the bundle's content.
- Select exact releases, pin an older release or follow the latest recommendation
  when a versioned source provides verified artifacts. Replacement checks SHA-256,
  byte count and bundle identity before activating the new version.
- Use English or Simplified Chinese. Crux Beta uses the same source with a separate
  bundle identity and data namespace.
- Check for application updates through Sparkle. Configured release builds support
  signed feeds, signed archives and release notes; unconfigured local builds disable updates.

## Documentation sources

The versioned Crux catalog and the legacy Zeal catalog use separate contracts.
Sources settings use **Crux enabled and Zeal disabled by default**. The source
model and settings are implemented and have passed isolated native Beta checks.
You can add custom Zeal-compatible catalogs and Dash XML feeds alongside the
built-in versioned Crux catalog. Each configured source has an identity separate
from the publisher's `sourceId`.

Crux keeps one installed version of each docset from a given source. Updates and
version changes replace that installation; another source can provide its own
copy of the same docset. New versioned downloads default to the latest recommended
release. Disabling or deleting a source leaves its installed documentation
available offline without assigning it to a newly added source.

Sources use HTTPS by default. The model also provides an explicit local-HTTP
policy for `localhost`, loopback and private IP literals, including IPv6 ULA.
It rejects HTTP on public addresses or arbitrary hostnames and rejects HTTPS-to-HTTP
redirects. Policy tests and real loopback transfers have passed; private-network
and IPv6 deployment checks remain environment-specific.

Crux's own supply comes from [crux-docset](https://github.com/zacharyhuo/crux-docset).
Its Python builder, validation and publication pipeline exist, and the repository
records private release acceptance. Public anonymous catalog, feed and archive
access remains an acceptance step. A private GitHub repository requires
authentication; Crux does not embed GitHub tokens to make it accessible.
See the [consumer contract](https://github.com/zacharyhuo/crux-docset/blob/develop/v1/contracts/crux-consumer.md)
for release identity, integrity and publication rules.

Zeal is an optional compatibility source. Its catalog is a raw JSON array at
`https://api.zealdocs.org/v1/docsets`; downloads use the separate
`https://go.zealdocs.org/d/{sourceId}/{name}/latest` route. Those entries do not
provide Crux's verified release history. Service access and redistribution rights
need their own review. The [Zeal-compatible contract](https://github.com/zacharyhuo/crux-server/blob/develop/v1/contracts/zeal-compatible-catalog.md)
documents that boundary without implying a deployed server.

You can also import a local bundle or subscribe to a publisher's HTTPS Dash feed.
Check that publisher's terms before redistributing its documentation or artwork.

## Development

### Requirements

- macOS 26 or later and an Apple Silicon Mac. The Xcode project targets arm64;
  Intel builds are not supported.
- Xcode with the macOS 26 SDK and Swift 6.2 or later. CruxCore declares
  `swift-tools-version: 6.2`; the app uses Swift 6 language mode. The project
  records Xcode 26.6 creation/upgrade metadata.
- Apple command-line build tools, including `make`, `curl` and `tar`.
  Node.js 24 is used for the application-update tooling checks.

### Build the required native dependency

From the repository root, run this **before any app build or CruxCore test**:

```sh
./scripts/build-libarchive-xcframework.sh --build
```

The script downloads and verifies libarchive **3.8.9**, pinned to commit
`27cbc7827172698143e440801fc0ba39ccb4f1f5` and source SHA-256
`888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde`.
It builds the arm64 static `Artifacts/CLibArchive.xcframework`, its ZIP and
`Artifacts/libarchive-build.json`. The binary target is required and is not
checked into Git. `--verify-source` checks the download only; it does not build
the dependency. Users of the packaged app do not need Homebrew.

Swift dependencies are pinned in the package manifests and `Package.resolved`.

### Build and test in isolation

Open `Crux.xcodeproj` and select the shared **Crux Beta** scheme, or run:

```sh
xcodebuild build \
  -project Crux.xcodeproj \
  -scheme 'Crux Beta' \
  -configuration BetaDebug \
  -destination 'platform=macOS' \
  -derivedDataPath build/Beta \
  CODE_SIGN_IDENTITY=- \
  CRUX_CODE_SIGN_ENTITLEMENTS=Crux/Crux-AdHoc.entitlements

swift test --package-path Packages/CruxCore

# Optimized 20-docset search p95 gates.
swift test -c release --package-path Packages/CruxCore \
  --filter SymbolSearchPerformanceTests
swift test -c release --package-path Packages/CruxCore \
  --filter FullTextSearchPerformanceTests

xcodebuild test \
  -project Crux.xcodeproj \
  -scheme 'Crux Beta' \
  -configuration BetaDebug \
  -destination 'platform=macOS' \
  -derivedDataPath build/BetaTests \
  CODE_SIGN_IDENTITY=-

node --test tools/app-updates/test/*.test.mjs
```

For locally signed builds, use `Crux/Crux-AdHoc.entitlements` so Sparkle can load
without an Apple Team ID. This keeps App Sandbox and hardened runtime enabled.
Local Release/BetaRelease packages also need `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`.
Certificate-backed distribution uses the standard `Crux/Crux.entitlements` instead.
Always launch the final package: signature integrity alone does not prove it starts.

Generated-docset GUI tests must use `com.zacharyhuo.Crux.Beta`. Core tests use
disposable directories; Debug app-hosted/UI tests allocate fresh storage and
preferences through the existing test runtime. Keep production libraries,
preferences and security-scoped bookmarks out of Beta fixtures. Opt-in acceptance
tests that skip without a fixture have not passed acceptance.

Keep the desktop unlocked and avoid keyboard/mouse input during native UI tests.
Sources and prefix tests paste fixed fixture text to avoid input-method changes;
they preserve clipboard data without logging it and restore it unless another
application has changed the clipboard. Sources tests retain an accessibility-tree
attachment; visual checks are separate because XCTest can fail to capture
external-display windows.

macOS UI tests may need Xcode or the invoking terminal allowed under **System
Settings → Privacy & Security → Developer Tools**. `DevToolsSecurity` calls this
policy developer mode; macOS has no separate System Settings toggle with that name.
Building a test target does not require changing that host policy.

### Application releases

The [Sparkle release guide](tools/app-updates/README.md) covers separate stable/Beta
keys, protected release environments, ZIP/DMG packaging and signed Release notes.
A free Apple account or an ad-hoc signature does not provide Developer ID signing
or notarization. The optional Developer ID/notarization path requires paid Apple
membership and credential-backed acceptance.

Public updates require anonymous HTTPS access to the appcast and Release assets.
Private sources cannot serve ordinary anonymous clients. Keep private signing keys
in release infrastructure and ship only public verification keys. Older builds
without Sparkle configuration need a manual bootstrap installation.

### Repository layout

- `Crux/`: native scenes, reader, library, search and localized resources.
- `Packages/CruxCore/`: parsing, search, transfers and installation, with Core tests.
- `CruxTests/` and `CruxUITests/`: isolated integration and UI tests.
- `scripts/`: dependency builds, the Beta launcher and packaging.
- `tools/app-updates/`: Sparkle publishing and acceptance tooling.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and
[PROVENANCE.md](PROVENANCE.md) for contribution, trust and source-origin boundaries.

## Roadmap

| Area | Status |
| --- | --- |
| Local reader, library, symbol search, optional full text and exact-release replacement | Implemented; continue preview regression and usability work |
| Multi-source management with Crux enabled and Zeal disabled by default | Implemented; isolated native Beta acceptance completed |
| Public documentation supply and signed application updates | Pipeline code exists; anonymous HTTPS and real release acceptance remain |
| Menu bar quick access | Planned; the current app menu commands are already implemented |
| Local documentation-generation agent | Planned; existing CLI builders run in crux-docset |
| Wider documentation supply | Python pipeline exists; Go/Spring adapters remain experimental and need separate qualification |
| Self-hosted catalog and orchestration server | Contracts and research only in crux-server; no Java service or deployment yet |

## License

Crux-owned source code is licensed under the [MIT license](LICENSE).
This applies to the current client source, not to the licenses of earlier releases.

Dependencies and referenced projects retain their own terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [PROVENANCE.md](PROVENANCE.md).
An application license does not relicense docset content, upstream artwork or
sibling repositories.
