import Foundation
import Testing

@testable import CruxCore

@Suite(.serialized)
struct FullTextSearchPerformanceTests {
    @Test(.timeLimit(.minutes(1)))
    func searchP95StaysBelowTwoHundredFiftyMillisecondsAcrossTwentyDocsets() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var descriptors: [DocsetDescriptor] = []
        for docsetIndex in 0..<20 {
            let bundle = try TestDocsetFixture.create(
                in: root,
                name: "Docs\(docsetIndex)",
                identifier: "dev.crux.performance.\(docsetIndex)",
                symbols: []
            )
            let descriptor = try DocsetParser().parse(bundleAt: bundle)
            for pageIndex in 0..<40 {
                let page = descriptor.documentsURL.appending(path: "guide/page-\(pageIndex).html")
                try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("""
                    <html><title>Guide \(pageIndex)</title><body>
                    common performance needle docset \(docsetIndex) page \(pageIndex)
                    </body></html>
                    """.utf8).write(to: page)
            }
            descriptors.append(descriptor)
        }

        let service = try FullTextSearchService(databaseURL: root.appending(path: "FullText.sqlite"))
        for descriptor in descriptors {
            try await service.enable(for: descriptor)
            _ = try await service.index(descriptor)
        }

        var samples: [Double] = []
        for _ in 0..<60 {
            let start = ContinuousClock.now
            _ = try await service.search("performance needle", in: descriptors, limit: 300)
            samples.append(seconds(ContinuousClock.now - start))
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]

        #expect(p95 < 0.250, "Measured full-text p95 was \(p95) seconds")
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
