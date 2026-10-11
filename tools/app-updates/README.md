# Sparkle application updates

Crux and Crux Beta share Sparkle 2.10.0 and the same updater implementation.
This is application delivery, not the `crux-docset` supply pipeline.

## Channels and signing

| Channel | Bundle | Tag | Signed feed on `app-updates` |
| --- | --- | --- | --- |
| stable | `com.zacharyhuo.Crux` | `vVERSION` | `stable/appcast.xml` |
| beta | `com.zacharyhuo.Crux.Beta` | `beta-vVERSION-bBUILD` | `beta/appcast.xml` |

`CFBundleVersion` must be a positive integer and strictly increase within its
channel. `CFBundleShortVersionString` must match the tag and cannot go backwards.
The feed and ZIP are both Ed25519 signed. ZIP assets are read back from GitHub
and checked before the feed is promoted. Old releases remain available.
The current ledger is bounded to 500 records and 1 MiB; the signed feed is bounded
to 4 MiB. Exceeding these limits fails closed and requires a reviewed history
retention migration; no existing releases are silently deleted.

Set repository variables `SPARKLE_STABLE_PUBLIC_KEY` and
`SPARKLE_BETA_PUBLIC_KEY`. Create two protected environments, `crux-app-stable`
and `crux-app-beta`; each has its OWN environment Secret named
`SPARKLE_PRIVATE_KEY`, with different values. Do NOT use Repository Secrets for
these keys (or legacy `SPARKLE_STABLE_PRIVATE_KEY` / `SPARKLE_BETA_PRIVATE_KEY`).
Each channel needs its OWN key pair. Private Secrets contain a base64 32-byte
Ed25519 seed; only public keys enter app bundles.
The scripts always pass `--ed-key-file`; they never fall back to a personal Keychain.

Each environment must have a required human reviewer and exactly one selected
deployment policy: branch `main`, not a tag or wildcard. Protect `main` as well.
Missing/unreadable protection metadata fails closed before a signing job starts;
the pipeline never creates an unprotected environment as a fallback. Running
`node tools/app-updates/readiness.mjs` with your existing repository-admin `gh`
session audits names/policies only, including misplaced repository credentials;
it never retrieves private key values. Run it before initial activation and after
changing credential configuration.

Generate each pair with `node tools/app-updates/keys.mjs --directory ABSOLUTE_NEW_DIRECTORY`.
Choose a protected directory OUTSIDE the repository; the command refuses to
overwrite an existing directory and prints only the public key. Back up the
private file securely, then enter it into the channel's Environment Secrets without pasting it into
chat or a commit. Do not regenerate deployed channel keys as a routine release
step: existing clients trust their original key. Rotation needs a separate plan.

The release workflow defaults to `adhoc`, usable without paid Apple membership.
It still requires the Sparkle keys. Ad-hoc signatures and EdDSA are NOT Apple
Developer ID or notarization, and do not guarantee Gatekeeper acceptance of an
internet-downloaded app. No security policy changes or quarantine removal are
performed by these scripts.

Ad-hoc builds must select `CRUX_CODE_SIGN_ENTITLEMENTS=Crux/Crux-AdHoc.entitlements`.
This Crux-target setting avoids changing dependency and test-runner entitlements.
This adds only the application-scoped library-validation exception needed to load
Sparkle without a Team ID; hardened runtime and App Sandbox stay enabled. Local
Release/BetaRelease builds also set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` to
exclude debugger access. `package-release.sh` checks the signed app and framework
policy in addition to signature integrity. This static check does not replace
actually launching the final installed build.

Developer ID candidates use `Crux/Crux.entitlements`, without the local exception;
packaging requires matching app/framework Team IDs. Never use the ad-hoc entitlement
override for certificate-backed distribution.

For optional `developer-id`, select that workflow input. Configure the existing
Developer ID certificate/password, runner Keychain password, development team,
and App Store Connect notary key/id/issuer Secrets inside the selected protected
environment, never as global repository signing credentials. The no-key builder
archives ad-hoc; the trusted signing runner imports the certificate and exports
with the explicit team ID, resigning Sparkle's nested helpers, then notarizes/staples app and DMG.
This mode requires paid Apple membership and needs real credential-backed acceptance.

## Release and notes lifecycle

Tag push only builds a no-key candidate. To publish, dispatch **Release** from
`main` with an existing tag from main history. The builder checks out the exact
source SHA, tests and archives arm64 with read-only permissions and no signing
credentials. It hands over a fixed artifact ID plus payload SHA-256 and receipt
bound to source SHA, automation SHA, run/attempt, channel and public key.

A separate hosted signing runner waits for environment approval, executes only
the trusted workflow SHA's tools (never candidate source, `Package.swift` or
candidate executables), verifies receipt/tar structure/app identity, and fetches
the official Sparkle signing SDK at a fixed URL/checksum without package resolution.
Only the final step materializes that environment's private key, cleaning it on
exit. It packages ZIP/DMG, writes `update-build.json`, publishes assets and promotes
the signed feed through a single Git tree/ref update. First promotion additionally
requires the full Release job's local approved plan, candidate receipt and payload.
The publisher binds these to the main Release workflow, source/automation SHA,
run, channel, tag, public key and payload digest. These are trusted runner inputs
already checked against the fixed candidate artifact ID and builder outputs by
the receipt/unpack step; copies attached to a Release or fields in
`update-build.json` cannot provide that authority. The original build attempt
is checked by that unpack step, including when only failed signing jobs rerun.
Actions are full-SHA pinned.
No force push or asset replacement.
If an asset is corrupt, a key is mismatched, or the feed changed concurrently,
the existing feed stays unchanged. A published Release is immutable for this
pipeline: rerunning a build does not overwrite it.

`description sparkle:format="markdown"` contains the exact selected Release
body, not `/releases/latest` or GitHub page HTML. The ledger records Release ID,
tag, body digest and archive identity. Sparkle renders headings, lists, code,
links and Chinese natively. An empty body has an explicit fallback and the exact
Release link. Both executable updates and embedded notes are signed.

Editing a published GitHub Release triggers a no-key **Request app update notes
refresh** job, which forwards only a validated tag through `repository_dispatch`.
The actual **Refresh app update notes** workflow runs on main and waits for the
same channel environment approval (including for notes edits). It downloads the original
ZIP named by the selected tag and takes the executable identity, hash, signature
and signing provenance from the existing immutable ledger entry. It never uses
downloaded `update-build.json` for notes identity or approval. Before the key-bearing
step, a no-key publisher check verifies that ledger entry, the archive signature
and digest, and the ZIP's actual bundle ID/version/build/channel key and updater
policy. It reads only a bounded Info.plist in memory using the existing artifact
and candidate checks; it does not extract or execute the downloaded app. ZIP
duplicates (including case/Unicode aliases), traversal, unindexed payloads,
symlink plist/parents, alternate Unicode-path fields and ZIP64 fail closed.
The final publisher repeats the checks before signing the feed and refreshes the
exact Release Markdown without rebuilding or increasing the build number.

The signed appcast also contains a digest of the complete channel ledger,
including signing provenance that is not displayed in RSS. Before reusing
history, both publishers verify the previous feed with the configured public key
and bind the ledger to its signed bytes at the same immutable Git ref. Editing
`state.json`, recalculating a notes digest, or removing the prior feed cannot
acquire signing authority. Legacy ledgers without this signed binding require
a separately reviewed recovery/migration; the normal release and notes paths
fail closed rather than trusting or silently resetting that history.

The notes workflow can retry a notes update for an already-promoted Release.
It cannot perform a first promotion when that Release ID is absent from the
ledger: the legacy unsigned metadata cannot prove which source/package was
originally approved. Recovery requires the owner to run the full **Release**
workflow from `main`, with its candidate/source verification and channel approval.
Because this pipeline refuses to overwrite an existing Release, an already
uploaded but unpromoted legacy Release requires a reviewed new tag/build and
another full main-gated release. Do not recover by editing JSON, manually seeding
the ledger, bypassing the gate, or replacing the old assets. This intentionally
trades legacy first-promotion retry convenience for a provable approval boundary.
Both publishers serialize
through the same concurrency group and refuse concurrent ref overwrites.
Their `queue: max` retains up to 100 pending runs; unlike the default single
pending slot, a later notes request does not replace an earlier queued release.

Environment safeguards reduce accidental/untrusted-code exposure; they do not
make GitHub, the reviewer account, runner image or upstream signing tool immune
to compromise. Keep strong account authentication and encrypted key backups.
Approval must cover the exact source/receipt, not just a successful CI badge.

Public distribution needs anonymous HTTPS access to the `app-updates` branch
and Release assets. A private repository does not provide that to ordinary
Sparkle clients. Do not embed GitHub credentials in an app. Keeping development
private does not block local implementation/testing; switch hosting/access when
activating public releases.

Unconfigured local builds intentionally disable updates. A release build receives
its public key through `SPARKLE_PUBLIC_ED_KEY`. Old builds without Sparkle/key
configuration require one manual bootstrap installation; this feature cannot
retroactively auto-update an already-installed old app.

## Verification

From the repository root:

```sh
node --test tools/app-updates/test/*.test.mjs
xcodebuild -project Crux.xcodeproj -scheme 'Crux Beta' -configuration BetaDebug \
  -derivedDataPath build/SparkleAcceptance -destination 'platform=macOS' \
  -only-testing:CruxTests CODE_SIGN_IDENTITY=- test
```

GitHub's current documented `concurrency.queue: max` is newer than actionlint
v1.7.12's schema. For that pinned linter only, use the narrow compatibility filter
`-ignore '^unexpected key "queue" for "concurrency" section\.'`; the workflow AST
regression independently checks `queue=max` and `cancel-in-progress=false`.
Other diagnostics must still fail. Real GitHub schema/job acceptance remains a
separate activation check; do not report the unfiltered linter as passing.

For the opt-in real Sparkle engine fixture, build BetaRelease in the same derived
directory, then run `test/acceptance.mjs` with `--base-app` pointing to that built
`Crux Beta.app`, `--sdk build/SparkleAcceptance/SourcePackages`, and `--output`
pointing to a NEW absolute directory under this repository's
`build/SparkleAcceptance/`. It creates ephemeral test keys and uniquely identified
Beta copies; no user app is launched, terminated, or installed. It uses only
loopback HTTP for the transport fixture. Production URLs remain HTTPS-only.

The fixture compiles the pinned SDK's own CLI, tests archive/feed tampering and
valid installation, and renders the real standard notes UI offscreen without
activating a window. `native-notes.m` uses pinned private UI inspection only in
the test adapter; no private Sparkle APIs are used by production Crux.

`test/security-acceptance.mjs --output NEW_ABSOLUTE_BUILD_DIRECTORY` additionally
archives a disposable Beta, exercises candidate transport/receipt/tar checks,
downloads the checksum-pinned real signer, signs ZIP/DMG and rejects a tampered
payload before extraction. Its CI identifiers are simulated, not proof of an
actual GitHub approval or cross-job run. It uses only new ephemeral test keys.

These checks do not certify real GitHub HTTPS, sandboxed application-to-installer
communication, app relaunch, quarantine/Gatekeeper behavior, Developer ID, or
notarization. Those remain a separate keyed Beta publication/acceptance step.

References: [Sparkle integration](https://sparkle-project.org/documentation/programmatic-setup/),
[sandbox and signing](https://sparkle-project.org/documentation/sandboxing/),
[publishing](https://sparkle-project.org/documentation/publishing/),
[Apple Developer ID](https://developer.apple.com/developer-id/).
