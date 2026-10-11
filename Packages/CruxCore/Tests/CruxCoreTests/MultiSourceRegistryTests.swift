import Foundation
import Testing
@testable import CruxCore

struct MultiSourceRegistryTests {
    @Test func sourceAwareScanDoesNotInstallASecondLocalVersion() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try TestDocsetFixture.create(in: root, name: "PythonA", version: "3.14")
        let second = try TestDocsetFixture.create(in: root, name: "PythonB", version: "3.13")
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        try await registry.initializeSources()
        let original = try await registry.register(bundleAt: first, assignRuntimeID: true)
        let report = try await registry.scanAndRegister(docsetsDirectory: root, assignRuntimeIDs: true)
        let records = try await registry.allInstalled()
        #expect(records.count == 1)
        #expect(records.first?.identifier == original.identifier)
        #expect(records.first?.descriptor.bundleURL == first)
        #expect(report.failures.map(\.bundleURL) == [second])
        #expect(FileManager.default.fileExists(atPath: second.path), "Alternate user files must not be deleted.")
    }

    @Test func registryRejectsDuplicateLocalOriginIdentityEvenThroughUpsert() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try TestDocsetFixture.create(in: root, name: "PythonA", version: "3.14")
        let second = try TestDocsetFixture.create(in: root, name: "PythonB", version: "3.13")
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        _ = try await registry.register(bundleAt: first, assignRuntimeID: true)
        let before = try await registry.allInstalled()
        let duplicate = InstalledDocset(descriptor: try DocsetParser().parse(bundleAt: second), source: .localImport,
            advertisedVersion: DocsetVersion(version: "3.13", revision: nil),
            sourceConfigurationID: DocsetSourceConfiguration.localID, sourceName: "Local Imports")
        await #expect(throws: DocsetReplacementError.conflictingInstall) { try await registry.upsert(duplicate) }
        #expect(try await registry.allInstalled() == before)
    }

    @Test func concurrentRegistrationConvergesOnOneRuntimeIDAndPath() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let identifiers = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await registry.register(bundleAt: bundle, assignRuntimeID: true).identifier } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(Set(identifiers).count == 1)
        #expect(try await registry.allInstalled().count == 1)
    }

    @Test func scanDoesNotAdoptAnUncommittedManagedBundle() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root, name: "crux-" + String(repeating: "a", count: 64))
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let result = try await registry.scanAndRegister(docsetsDirectory: root, assignRuntimeIDs: true)
        #expect(result.registered.isEmpty)
        #expect(result.failures.count == 1)
        #expect(try await registry.allInstalled().isEmpty)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
    }
    @Test func scanningSameBundleIDAtTwoPathsDoesNotOverwriteFirstInstallation() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try TestDocsetFixture.create(in: root, name: "PythonA")
        let second = try TestDocsetFixture.create(in: root, name: "PythonB")
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let original = try await registry.register(bundleAt: first)
        let another = try await registry.register(bundleAt: second)
        #expect(original.identifier != another.identifier)
        let records = try await registry.allInstalled()
        #expect(records.count == 2)
        #expect(records.contains { $0.descriptor.bundleURL == first })
        #expect(records.contains { $0.descriptor.bundleURL == second })
        _ = try await registry.scanAndRegister(docsetsDirectory: root)
        #expect(try await registry.allInstalled().count == 2)
    }
}
