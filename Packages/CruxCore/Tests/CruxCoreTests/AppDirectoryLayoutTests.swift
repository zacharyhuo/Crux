import Foundation
import Testing

@testable import CruxCore

struct AppDirectoryLayoutTests {
    @Test
    func derivesStableApplicationDataLocations() {
        let root = URL(fileURLWithPath: "/Users/example/Library/Application Support/Crux")
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)

        #expect(layout.databaseURL.path == "/Users/example/Library/Application Support/Crux/Crux.sqlite")
        #expect(layout.cacheDirectory.path == "/Users/example/Library/Application Support/Crux/Cache")
        #expect(layout.sessionDirectory.path == "/Users/example/Library/Application Support/Crux/Session")
        #expect(layout.defaultDocsetsDirectory.path == "/Users/example/Library/Application Support/Crux/Docsets")
        #expect(layout.downloadsDirectory.path == "/Users/example/Library/Application Support/Crux/Downloads")
        #expect(
            layout.docsetsDirectory(customPath: "/Volumes/Docs/Crux").path == "/Volumes/Docs/Crux"
        )
        #expect(layout.docsetsDirectory(customPath: nil) == layout.defaultDocsetsDirectory)
    }
}
