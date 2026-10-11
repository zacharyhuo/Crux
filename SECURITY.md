# Security

Crux is an early preview. Report problems against the current development source
or a specific preview build, including its version and bundle identity. There is
no promised maintenance window for older previews.

## Reporting a vulnerability

If GitHub offers **Report a vulnerability** for this repository, use that private
channel. Otherwise, contact the maintainer through a private contact method listed
on [the maintainer's profile](https://github.com/zacharyhuo) and ask for a disclosure
channel before sending exploit details. Do not put credentials, user paths,
private documentation or a working exploit into a public issue.

Include the affected commit/build, macOS version, reproduction steps, expected
behavior and impact. A minimal synthetic docset or archive is useful. Remove
tokens, security-scoped bookmarks and private source material from the evidence.
No response deadline or bug bounty is promised.

## Documentation and download trust

Docsets contain publisher-controlled HTML, scripts, SQLite data and assets. Use
sources you trust. Crux validates bundle structure and file containment; those
checks do not establish a publisher's identity, redistribution rights or safety
of the page content.

Sources use strict HTTPS by default. The source model being integrated also has
an explicit local-HTTP permission for `localhost`, loopback and private IP
literals, including IPv6 ULA; public HTTP and arbitrary HTTP hostnames are rejected.
An HTTPS request cannot redirect to HTTP under either policy. Versioned Crux releases add SHA-256 and byte-count
checks, bundle identity validation and recoverable replacement. Legacy Zeal
entries and ordinary Dash feeds do not gain that exact-release integrity
contract by using the same installer. A catalog hash still depends on trust in
the catalog publisher.

Archive extraction has path, entry-type and expansion limits. Local HTML runs in
WKWebView; JavaScript is enabled when metadata permits it and defaults to enabled
when the flag is absent. Remote HTTPS page resources are enabled by default,
with a global switch and per-docset blocking controls. Disable remote resources
when you need a stricter offline boundary. These controls do not audit page scripts.

The document server binds to `127.0.0.1` and uses a per-launch token in document
paths, with containment checks and response security headers. It is a local
reader service, not the proposed crux-server backend or a defense against a
compromised local account.

## Application updates

Sparkle application updates have a separate trust chain from docset updates.
Configured builds use public verification keys; release infrastructure holds the
private keys. Unconfigured builds disable updates. Never embed GitHub tokens or
private signing keys in an app, feed or catalog to fetch a private repository.

Ad-hoc signatures and Sparkle signatures do not provide Apple Developer ID or
notarization. Public HTTPS, real installation/relaunch and optional notarized
delivery require release acceptance. The [Sparkle release guide](tools/app-updates/README.md)
describes the pipeline and its remaining limits.

## Safe reproduction

Use Crux Beta (`com.zacharyhuo.Crux.Beta`) and disposable test data. Keep production
preferences, libraries and bookmarks out of the test. Do not alter system trust,
remove quarantine or replace an installed user app as a routine reproduction step.
