import CruxCore
import Foundation
import Testing

@testable import Crux

@MainActor
struct DocsetInstallChoiceTests {
    @Test
    func pendingChoiceResolvesExactReleaseWithoutInstallingAndRejectsUnavailableOrBusyTargets() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxChoice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try VersionedLibraryFixture.make(in: root).entry
        let latest = try #require(DocsetInstallChoice(entry: entry, policy: .latest, installed: nil, isBusy: false))
        #expect(latest.release?.version == "3.14.7")
        #expect(!latest.requiresReplacement)
        let old = try #require(DocsetInstallChoice(entry: entry, policy: .pinnedRelease(VersionedLibraryFixture.oldID), installed: nil, isBusy: false))
        #expect(old.release?.version == "3.13.9")
        #expect(old.release?.downloadURL.path.contains(VersionedLibraryFixture.oldID) == true)
        #expect(DocsetInstallChoice(entry: entry, policy: .pinnedRelease(String(repeating: "f", count: 64)), installed: nil, isBusy: false) == nil)
        #expect(DocsetInstallChoice(entry: entry, policy: .latest, installed: nil, isBusy: true) == nil)
    }

    @Test
    func replacementChoiceDistinguishesNoOpFromPolicyChangeOnSameVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxChoice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try VersionedLibraryFixture.make(in: root.appending(path: "fixtures"))
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "registry.sqlite"))
        let target = try DocsetInstallTarget(entry: fixture.entry, selection: .latest)
        let artifact = root.appending(path: "latest.tgz")
        try #require(fixture.downloads[target.release.downloadURL]).write(to: artifact)
        let transaction = DocsetReplacementTransaction(registry: registry, docsetsDirectory: root.appending(path: "Docsets"))
        let installed = try await transaction.perform(target: target, artifactAt: artifact)
        #expect(DocsetInstallChoice(entry: fixture.entry, policy: .latest, installed: installed, isBusy: false) == nil)
        let pin = try #require(DocsetInstallChoice(entry: fixture.entry, policy: .pinnedRelease(VersionedLibraryFixture.latestID), installed: installed, isBusy: false))
        #expect(pin.requiresReplacement)
        #expect(pin.policy == .pinnedRelease(VersionedLibraryFixture.latestID))
        #expect(try await registry.allInstalled() == [installed])
    }
}
