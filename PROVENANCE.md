# Code and documentation provenance

Crux is a SwiftUI/AppKit client for Dash-compatible documentation bundles. Zeal
is a behavior and compatibility reference. Dash plist keys, SQLite table names,
catalog fields and libarchive C calls are format or API vocabulary; shared use
of them does not establish that an implementation was copied.

## Scope of the review

A bounded review on 2026-10-09 compared Crux's current parsing, symbol search,
catalog, extraction, installation and update paths with local Zeal source at
commit `25ad56c62e0095493e67d1d209054a079069101a`. The review found no identified
copy or translation of Zeal implementation code in those paths. It does not
establish independent authorship of every file or settle contributor rights.

The implementations have material differences:

- Crux parses plists with Foundation and reads docset indexes through GRDB.
  Its ZDash queries join the original tables without creating Zeal's persistent
  `searchIndex` view or modifying the docset index.
- Crux ranks exact, prefix, substring and subsequence matches with stable tie
  breaks. Zeal's reviewed implementation uses a weighted dynamic-programming
  score and backtracking through its `zealScore` SQLite function.
- Crux wraps libarchive streaming reads in a Swift bridge and enforces extraction
  policy in Swift. Its versioned install path verifies the artifact and uses a
  recoverable filesystem/registry transaction.

These findings concern [DocsetParser](Packages/CruxCore/Sources/CruxCore/DocsetParser.swift),
[symbol indexes](Packages/CruxCore/Sources/CruxCore/DocsetSymbolIndex.swift),
[search ranking](Packages/CruxCore/Sources/CruxCore/SymbolSearchService.swift),
[catalog parsing](Packages/CruxCore/Sources/CruxCore/CatalogClient.swift),
[the archive bridge](Packages/CruxCore/Sources/ArchiveBridge/LibArchiveReader.swift),
[extraction](Packages/CruxCore/Sources/CruxCore/ArchiveExtractor.swift) and
[replacement](Packages/CruxCore/Sources/CruxCore/DocsetReplacementTransaction.swift).
Zeal's corresponding source carries GPL-3.0-or-later terms. Future copied or
adapted code must identify its origin and receive a separate license review.

## Dependencies, contributors and supplied content

GRDB, SwiftSoup, Sparkle and the pinned libarchive build retain their upstream
terms and notices. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records their
versions and use. Binary packaging must preserve the notices for what it ships.

Crux-owned code in the current source tree is distributed under the
[MIT license](LICENSE). Git author and coauthor records help trace changes, but
automatically inserted tool-attribution trailers do not establish a human code
contribution. New external contributions and copied implementations require their
own provenance and license review. Historical prototypes and earlier releases
keep their original terms and are outside this bounded current-source review.

The application license does not cover publisher-owned docset pages, examples,
fonts, scripts or artwork. The crux-docset repository retains source/notice records
for upstream content and fixtures, including Spring source evidence and official
icons. That material keeps its own terms. Build success and matching checksums
do not replace licensing approval or public distribution acceptance.

Using Zeal's catalog protocol does not grant permission to host or redistribute
its supplied documentation. Review service and publisher terms before enabling
a source or publishing a mirror. The licenses of crux-docset and crux-server are
separate decisions.
