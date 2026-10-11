import Foundation
import GRDB

/// Parses a fully expanded `.docset` bundle without modifying its contents.
public struct DocsetParser: Sendable {
    public init() {}

    public func parse(bundleAt inputURL: URL) throws -> DocsetDescriptor {
        let bundleURL = inputURL.standardizedFileURL
        // Resolving paths for containment is not enough here: accepting a
        // symlink as the bundle root would preserve that link when an import is
        // copied or activated, potentially changing its target afterwards.
        guard !isSymbolicLink(bundleURL) else {
            throw DocsetParseError.unsafeComponent(bundleURL)
        }
        let artifact = try DocsetArtifact.detect(at: bundleURL)
        guard case .bundle = artifact else {
            throw DocsetParseError.notADocsetBundle(bundleURL)
        }

        let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let resourcesURL = contentsURL.appending(path: "Resources", directoryHint: .isDirectory)
        let documentsURL = resourcesURL.appending(path: "Documents", directoryHint: .isDirectory)
        let indexURL = resourcesURL.appending(path: "docSet.dsidx", directoryHint: .notDirectory)
        let infoPlistURL = infoPlistURL(in: contentsURL)

        guard let infoPlistURL else {
            throw DocsetParseError.missingComponent(contentsURL.appending(path: "Info.plist"))
        }
        guard isDirectory(documentsURL) else {
            throw DocsetParseError.missingComponent(documentsURL)
        }
        guard isRegularFile(indexURL) else {
            throw DocsetParseError.missingComponent(indexURL)
        }
        for componentURL in [contentsURL, resourcesURL, documentsURL, infoPlistURL, indexURL] {
            guard isContained(componentURL, within: bundleURL) else {
                throw DocsetParseError.unsafeComponent(componentURL)
            }
        }

        let plist = try readInfoPlist(at: infoPlistURL)
        let metadata = try readMetadata(at: bundleURL.appending(path: "meta.json", directoryHint: .notDirectory))
        let schema = try inspectIndex(at: indexURL)

        let fallbackName = bundleURL.deletingPathExtension().lastPathComponent
        let plistName = stringValue(plist["CFBundleName"])
        let name = nonempty(metadata.name) ?? nonempty(plistName) ?? fallbackName
        let displayName = nonempty(metadata.title) ?? nonempty(plistName) ?? name.replacingOccurrences(of: "_", with: " ")
        let identifier = nonempty(stringValue(plist["CFBundleIdentifier"])) ?? normalizedIdentifier(name)
        let version = nonempty(metadata.version) ?? nonempty(stringValue(plist["CFBundleShortVersionString"]))

        var keywords: [String] = []
        for key in ["DocSetPlatformFamily", "DashDocSetPluginKeyword", "DashDocSetKeyword", "DashDocSetFamily"] {
            guard let value = nonempty(stringValue(plist[key])) else { continue }
            if key == "DashDocSetFamily", value.localizedCaseInsensitiveContains("dashtoc") {
                continue
            }
            appendNormalized(value, to: &keywords)
        }
        for keyword in metadata.keywords {
            appendNormalized(keyword, to: &keywords)
        }

        let plistIndexPath = nonempty(stringValue(plist["dashIndexFilePath"]))
        let indexPagePath = existingSafeDocumentPath(
            candidates: [plistIndexPath, nonempty(metadata.indexFilePath), "index.html"],
            documentsURL: documentsURL
        )
        // Many docsets (including Javadoc) omit this optional flag even though
        // their tabs, search and disclosure controls depend on page scripts.
        // Missing metadata is not an opt-out; keep honoring explicit values.
        let plistJavaScript = boolValue(plist["isJavaScriptEnabled"]) ?? true

        return DocsetDescriptor(
            identifier: identifier,
            name: name,
            displayName: displayName,
            version: version,
            revision: metadata.revision,
            keywords: keywords,
            bundleURL: bundleURL,
            documentsURL: documentsURL,
            indexURL: indexURL,
            indexSchema: schema,
            indexPagePath: indexPagePath,
            isJavaScriptEnabled: metadata.isJavaScriptEnabled ?? plistJavaScript,
            supplyMetadata: metadata.supplyMetadata
        )
    }

    private func infoPlistURL(in contentsURL: URL) -> URL? {
        let canonical = contentsURL.appending(path: "Info.plist", directoryHint: .notDirectory)
        if isRegularFile(canonical) { return canonical }

        // Some historical docsets shipped the invalid lowercase spelling.
        let lowercase = contentsURL.appending(path: "info.plist", directoryHint: .notDirectory)
        return isRegularFile(lowercase) ? lowercase : nil
    }

    private func readInfoPlist(at url: URL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw DocsetParseError.malformedInfoPlist(url)
            }
            return dictionary
        } catch is DocsetParseError {
            throw DocsetParseError.malformedInfoPlist(url)
        } catch {
            throw DocsetParseError.malformedInfoPlist(url)
        }
    }

    private func inspectIndex(at url: URL) throws -> DocsetIndexSchema {
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            return try database.read { db in
                if try db.tableExists("searchIndex"),
                   try hasColumns(["name", "type", "path"], in: "searchIndex", database: db) {
                    return .dash
                }

                let zDashTables: [(String, Set<String>)] = [
                    ("ztoken", ["ztokenname", "ztokentype", "zmetainformation"]),
                    ("ztokentype", ["z_pk", "ztypename"]),
                    ("ztokenmetainformation", ["z_pk", "zfile", "zanchor"]),
                    ("zfilepath", ["z_pk", "zpath"]),
                ]
                for (table, columns) in zDashTables {
                    guard try db.tableExists(table),
                          try hasColumns(columns, in: table, database: db) else {
                        throw DocsetParseError.incompatibleIndex(url)
                    }
                }
                return .zDash
            }
        } catch let error as DocsetParseError {
            throw error
        } catch {
            throw DocsetParseError.incompatibleIndex(url)
        }
    }

    private func hasColumns(
        _ requiredColumns: Set<String>,
        in table: String,
        database: Database
    ) throws -> Bool {
        let actualColumns = Set(try database.columns(in: table).map { $0.name.lowercased() })
        return requiredColumns.isSubset(of: actualColumns)
    }

    private func readMetadata(at url: URL) throws -> Metadata {
        guard !isSymbolicLink(url) else { throw DocsetParseError.unsafeComponent(url) }
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile != true || (values.fileSize ?? 0) > 1_048_576 {
            throw DocsetParseError.malformedMetadata(url)
        }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Metadata()
        }

        let extra = object["extra"] as? [String: Any]
        let supply: DocsetSupplyMetadata?
        if ["sourceId", "familyId", "variantId", "releaseId"].contains(where: { object[$0] != nil }) {
            do {
                supply = try JSONDecoder().decode(DocsetSupplyMetadata.self, from: data)
                try supply?.validate()
            } catch {
                throw DocsetParseError.malformedMetadata(url)
            }
        } else {
            supply = nil
        }
        let revision: Int?
        if let number = object["revision"] as? NSNumber {
            revision = number.intValue
        } else if let string = object["revision"] as? String {
            revision = Int(string)
        } else {
            revision = nil
        }

        return Metadata(
            name: object["name"] as? String,
            title: object["title"] as? String,
            version: object["version"] as? String,
            revision: revision,
            keywords: extra?["keywords"] as? [String] ?? [],
            indexFilePath: extra?["indexFilePath"] as? String,
            isJavaScriptEnabled: extra?["isJavaScriptEnabled"] as? Bool,
            supplyMetadata: supply
        )
    }

    private func existingSafeDocumentPath(candidates: [String?], documentsURL: URL) -> String? {
        let resolvedDocumentsURL = documentsURL.resolvingSymlinksInPath().standardizedFileURL
        for candidate in candidates.compactMap({ $0 }) {
            let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
            guard !candidate.hasPrefix("/"),
                  !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                continue
            }
            let fileURL = documentsURL
                .appending(path: candidate, directoryHint: .notDirectory)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard fileURL.path.hasPrefix(resolvedDocumentsURL.path + "/"), isRegularFile(fileURL) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isContained(_ url: URL, within rootURL: URL) -> Bool {
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return resolvedURL.path.hasPrefix(resolvedRoot.path + "/")
    }

    private func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedIdentifier(_ value: String) -> String {
        let pieces = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return pieces.isEmpty ? "docset" : pieces.joined(separator: "-")
    }

    private func appendNormalized(_ value: String, to values: inout [String]) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.isEmpty, !values.contains(normalized) {
            values.append(normalized)
        }
    }
}

private struct Metadata {
    var name: String?
    var title: String?
    var version: String?
    var revision: Int?
    var keywords: [String] = []
    var indexFilePath: String?
    var isJavaScriptEnabled: Bool?
    var supplyMetadata: DocsetSupplyMetadata?
}

public enum DocsetParseError: Error, Equatable, LocalizedError, Sendable {
    case notADocsetBundle(URL)
    case missingComponent(URL)
    case malformedInfoPlist(URL)
    case malformedMetadata(URL)
    case incompatibleIndex(URL)
    case unsafeComponent(URL)

    public var errorDescription: String? {
        switch self {
        case let .notADocsetBundle(url):
            "\(url.lastPathComponent) is not an expanded .docset bundle."
        case let .missingComponent(url):
            "The docset is missing \(url.lastPathComponent)."
        case let .malformedInfoPlist(url), let .malformedMetadata(url):
            "The docset metadata at \(url.path) is malformed."
        case let .incompatibleIndex(url):
            "The symbol index at \(url.path) does not use a supported Dash or ZDash schema."
        case let .unsafeComponent(url):
            "The docset component at \(url.path) resolves outside its bundle."
        }
    }
}
