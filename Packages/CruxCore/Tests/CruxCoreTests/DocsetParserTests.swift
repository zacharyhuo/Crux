import Foundation
import Testing

@testable import CruxCore

struct DocsetParserTests {
    @Test
    func readsOptionalSupplyIdentityWithoutTurningALocalImportIntoATrustedCatalogInstall() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root, identifier: "dev.crux.python")
        let legacy = try DocsetParser().parse(bundleAt: bundle)
        #expect(legacy.supplyMetadata == nil)
        let metadataURL = bundle.appending(path: "meta.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        object.merge([
            "sourceId": "dev.crux", "familyId": "python", "variantId": "python-3-13-en",
            "versionLine": "3.13", "language": "en", "identifier": "dev.crux.python",
            "bundleName": "Python", "releaseId": String(repeating: "1", count: 64),
        ]) { _, new in new }
        try JSONSerialization.data(withJSONObject: object).write(to: metadataURL)
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let metadata = try #require(descriptor.supplyMetadata)
        #expect(metadata.sourceId == "dev.crux")
        #expect(metadata.familyId == "python")
        #expect(metadata.variantId == "python-3-13-en")
        #expect(metadata.releaseId == String(repeating: "1", count: 64))
        let imported = InstalledDocset(descriptor: descriptor, source: .localImport,
                                       advertisedVersion: DocsetVersion(descriptor: descriptor))
        #expect(imported.source == .localImport)
        #expect(imported.selectionPolicy == .latest)
        var pinned = imported
        pinned.selectionPolicy = .pinnedRelease(metadata.releaseId)
        #expect(try JSONDecoder().decode(InstalledDocset.self, from: JSONEncoder().encode(pinned)) == pinned)

        // An old persisted record contains neither supply identity nor a policy.
        var stored = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(imported)) as? [String: Any])
        stored.removeValue(forKey: "selectionPolicy")
        var oldDescriptor = try #require(stored["descriptor"] as? [String: Any])
        oldDescriptor.removeValue(forKey: "supplyMetadata")
        stored["descriptor"] = oldDescriptor
        let restored = try JSONDecoder().decode(InstalledDocset.self, from: JSONSerialization.data(withJSONObject: stored))
        #expect(restored.descriptor == legacy)
        #expect(restored.selectionPolicy == .latest)
    }

    @Test
    func rejectsPartialOrUnsafeSupplyMetadata() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root)
        let metadataURL = bundle.appending(path: "meta.json")
        try Data(#"{"sourceId":"dev.crux","familyId":"python"}"#.utf8).write(to: metadataURL)
        #expect(throws: (any Error).self) { try DocsetParser().parse(bundleAt: bundle) }

        try FileManager.default.removeItem(at: metadataURL)
        let outside = root.appending(path: "metadata.json")
        try Data(#"{"name":"Untrusted"}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: metadataURL, withDestinationURL: outside)
        #expect(throws: DocsetParseError.unsafeComponent(metadataURL)) { try DocsetParser().parse(bundleAt: bundle) }
    }

    @Test
    func javaScriptDefaultsToEnabledAndHonorsExplicitMetadata() throws {
        let cases: [(plist: Bool?, metadata: Bool?, expected: Bool)] = [
            (nil, nil, true), (true, nil, true), (false, nil, false),
            (nil, true, true), (nil, false, false),
            (true, false, false), (false, true, true),
        ]
        for testCase in cases {
            let root = try TestDocsetFixture.makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = try TestDocsetFixture.create(in: root)
            let plistURL = bundle.appending(path: "Contents/Info.plist")
            var plist = try #require(PropertyListSerialization.propertyList(
                from: Data(contentsOf: plistURL), format: nil
            ) as? [String: Any])
            plist["isJavaScriptEnabled"] = testCase.plist
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: plistURL)

            let metadataURL = bundle.appending(path: "meta.json")
            if let enabled = testCase.metadata {
                try JSONSerialization.data(withJSONObject: ["extra": ["isJavaScriptEnabled": enabled]])
                    .write(to: metadataURL)
            } else {
                // Imported docsets, including Java SE25, can have neither flag nor meta.json.
                try FileManager.default.removeItem(at: metadataURL)
            }

            let descriptor = try DocsetParser().parse(bundleAt: bundle)
            #expect(descriptor.isJavaScriptEnabled == testCase.expected,
                    "plist: \(String(describing: testCase.plist)), metadata: \(String(describing: testCase.metadata))")
        }
    }

    @Test
    func parsesDashMetadataAndPaths() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root)

        let descriptor = try DocsetParser().parse(bundleAt: bundle)

        #expect(descriptor.identifier == "org.python.Python")
        #expect(descriptor.name == "Python")
        #expect(descriptor.displayName == "Python Documentation")
        #expect(descriptor.version == "3.13")
        #expect(descriptor.revision == 2)
        #expect(descriptor.keywords == ["python", "py"])
        #expect(descriptor.indexSchema == .dash)
        #expect(descriptor.indexPagePath == "index.html")
        #expect(descriptor.isJavaScriptEnabled)
        #expect(descriptor.documentsURL.lastPathComponent == "Documents")
        #expect(descriptor.indexURL.lastPathComponent == "docSet.dsidx")
    }

    @Test
    func recognizesLegacyZDashSchemaWithoutMutatingItsDatabase() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root, schema: .zDash)
        let indexURL = bundle.appending(path: "Contents/Resources/docSet.dsidx")
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: indexURL.path)

        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: indexURL.path)

        #expect(descriptor.indexSchema == .zDash)
        #expect(attributesAfter[.modificationDate] as? Date == attributesBefore[.modificationDate] as? Date)
    }

    @Test
    func rejectsMalformedPlistsAndIncompatibleIndexes() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let malformed = try TestDocsetFixture.create(in: root, name: "Malformed")
        try Data("not a plist".utf8).write(to: malformed.appending(path: "Contents/Info.plist"))
        #expect(throws: DocsetParseError.malformedInfoPlist(malformed.appending(path: "Contents/Info.plist"))) {
            try DocsetParser().parse(bundleAt: malformed)
        }

        let incompatible = try TestDocsetFixture.create(in: root, name: "Broken", schema: .incompatible)
        #expect(throws: DocsetParseError.incompatibleIndex(incompatible.appending(path: "Contents/Resources/docSet.dsidx"))) {
            try DocsetParser().parse(bundleAt: incompatible)
        }
    }

    @Test
    func doesNotAcceptAnIndexPageSymlinkThatEscapesDocuments() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root)
        let documentsURL = bundle.appending(path: "Contents/Resources/Documents")
        let indexURL = documentsURL.appending(path: "index.html")
        let outsideURL = root.appending(path: "outside.html")
        try Data("outside".utf8).write(to: outsideURL)
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createSymbolicLink(at: indexURL, withDestinationURL: outsideURL)

        let descriptor = try DocsetParser().parse(bundleAt: bundle)

        #expect(descriptor.indexPagePath == nil)
    }

    @Test
    func rejectsADocumentsDirectorySymlinkOutsideTheBundle() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root)
        let documentsURL = bundle.appending(path: "Contents/Resources/Documents")
        let outsideURL = root.appending(path: "outside-documents", directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: documentsURL)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: documentsURL, withDestinationURL: outsideURL)

        do {
            _ = try DocsetParser().parse(bundleAt: bundle)
            Issue.record("Expected the parser to reject an escaping Documents symlink")
        } catch let DocsetParseError.unsafeComponent(componentURL) {
            #expect(componentURL.standardizedFileURL.path == documentsURL.standardizedFileURL.path)
        } catch {
            Issue.record("Expected unsafeComponent, received: \(error)")
        }
    }

    @Test
    func rejectsADocsetWhoseBundleRootIsASymbolicLink() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realBundle = try TestDocsetFixture.create(in: root, name: "Real")
        let linkedBundle = root.appending(path: "Linked.docset", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedBundle, withDestinationURL: realBundle)

        do {
            _ = try DocsetParser().parse(bundleAt: linkedBundle)
            Issue.record("Expected the parser to reject a symbolic-link bundle root")
        } catch let DocsetParseError.unsafeComponent(componentURL) {
            #expect(componentURL.standardizedFileURL == linkedBundle.standardizedFileURL)
        } catch {
            Issue.record("Expected unsafeComponent, received: \(error)")
        }
    }
}
