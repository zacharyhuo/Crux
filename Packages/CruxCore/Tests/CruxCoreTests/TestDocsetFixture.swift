import Foundation
import GRDB

struct TestSymbol: Sendable {
    let name: String
    let type: String
    let path: String
    let fragment: String?
    let container: String?

    init(
        _ name: String,
        type: String,
        path: String,
        fragment: String? = nil,
        container: String? = nil
    ) {
        self.name = name
        self.type = type
        self.path = path
        self.fragment = fragment
        self.container = container
    }
}

enum TestIndexSchema {
    case dash
    case zDash
    case incompatible
}

enum TestDocsetFixture {
    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CruxCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func create(
        in root: URL,
        name: String = "Python",
        identifier: String = "org.python.Python",
        version: String = "3.13",
        revision: Int = 2,
        schema: TestIndexSchema = .dash,
        symbols: [TestSymbol] = [TestSymbol("pprint", type: "Function", path: "library/pprint.html")],
        writeSymbolDocuments: Bool = true
    ) throws -> URL {
        let bundleURL = root.appending(path: "\(name).docset", directoryHint: .isDirectory)
        let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let resourcesURL = contentsURL.appending(path: "Resources", directoryHint: .isDirectory)
        let documentsURL = resourcesURL.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleShortVersionString": version,
            "DocSetPlatformFamily": name.lowercased(),
            "DashDocSetKeyword": name.lowercased(),
            "DashDocSetFamily": "dashtoc",
            "dashIndexFilePath": "index.html",
            "isJavaScriptEnabled": true,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appending(path: "Info.plist"))

        let aliases = name == "Python" ? ["py"] : []
        let metadata: [String: Any] = [
            "name": name,
            "title": "\(name) Documentation",
            "version": version,
            "revision": String(revision),
            "extra": ["keywords": aliases + [name.lowercased()]],
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try metadataData.write(to: bundleURL.appending(path: "meta.json"))

        try Data("<html>index</html>".utf8).write(to: documentsURL.appending(path: "index.html"))
        if writeSymbolDocuments {
            for symbol in symbols {
                let pageURL = documentsURL.appending(path: symbol.path)
                try FileManager.default.createDirectory(
                    at: pageURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("<html>\(symbol.name)</html>".utf8).write(to: pageURL)
            }
        }

        let databaseURL = resourcesURL.appending(path: "docSet.dsidx")
        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { db in
            switch schema {
            case .dash:
                try db.execute(sql: "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)")
                for symbol in symbols {
                    let path = symbol.fragment.map { "\(symbol.path)#\($0)" } ?? symbol.path
                    try db.execute(
                        sql: "INSERT INTO searchIndex(name, type, path) VALUES (?, ?, ?)",
                        arguments: [symbol.name, symbol.type, path]
                    )
                }
            case .zDash:
                try db.execute(sql: "CREATE TABLE ztokentype(z_pk INTEGER PRIMARY KEY, ztypename TEXT)")
                try db.execute(sql: "CREATE TABLE zfilepath(z_pk INTEGER PRIMARY KEY, zpath TEXT)")
                try db.execute(sql: "CREATE TABLE ztokenmetainformation(z_pk INTEGER PRIMARY KEY, zfile INTEGER, zanchor TEXT)")
                try db.execute(sql: "CREATE TABLE zcontainer(z_pk INTEGER PRIMARY KEY, zcontainername TEXT)")
                try db.execute(sql: "CREATE TABLE ztoken(z_pk INTEGER PRIMARY KEY, ztokenname TEXT, ztokentype INTEGER, zmetainformation INTEGER, zcontainer INTEGER)")
                for (offset, symbol) in symbols.enumerated() {
                    let key = offset + 1
                    try db.execute(sql: "INSERT INTO ztokentype VALUES (?, ?)", arguments: [key, symbol.type])
                    try db.execute(sql: "INSERT INTO zfilepath VALUES (?, ?)", arguments: [key, symbol.path])
                    try db.execute(
                        sql: "INSERT INTO zcontainer VALUES (?, ?)",
                        arguments: [key, symbol.container]
                    )
                    try db.execute(
                        sql: "INSERT INTO ztokenmetainformation VALUES (?, ?, ?)",
                        arguments: [key, key, symbol.fragment]
                    )
                    try db.execute(
                        sql: "INSERT INTO ztoken VALUES (?, ?, ?, ?, ?)",
                        arguments: [key, symbol.name, key, key, key]
                    )
                }
            case .incompatible:
                try db.execute(sql: "CREATE TABLE unrelated(value TEXT)")
            }
        }

        return bundleURL
    }
}
