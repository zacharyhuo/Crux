#if !DEBUG
import Foundation
import Testing

@testable import CruxCore

@Suite(.serialized)
struct SymbolSearchPerformanceTests {
    @Test(.timeLimit(.minutes(2)))
    func keepsWarmSearchP95BelowOneHundredMillisecondsAcrossTwentyDocsets() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ordinarySymbols = (0..<4_999).map { index in
            TestSymbol("OrdinarySymbol\(index)", type: "Class", path: "symbols/\(index).html")
        }
        var descriptors: [DocsetDescriptor] = []
        for index in 0..<20 {
            let bundle = try TestDocsetFixture.create(
                in: root,
                name: "Benchmark\(index)",
                identifier: "dev.crux.benchmark.\(index)",
                symbols: ordinarySymbols + [
                    TestSymbol("NeedleSymbol\(index)", type: "Class", path: "needle/\(index).html"),
                ],
                writeSymbolDocuments: false
            )
            descriptors.append(try DocsetParser().parse(bundleAt: bundle))
        }

        let service = SymbolSearchService()
        _ = try await service.search("NeedleSymbol", in: descriptors, limit: 100)

        let clock = ContinuousClock()
        var durations: [Duration] = []
        for _ in 0..<20 {
            let start = clock.now
            let results = try await service.search("NeedleSymbol", in: descriptors, limit: 100)
            durations.append(start.duration(to: clock.now))
            #expect(results.count == 20)
        }

        let sortedDurations = durations.sorted()
        let p95 = sortedDurations[18]
        #expect(p95 < .milliseconds(100), "Warm symbol-search p95 was \(p95).")
    }
}
#endif
