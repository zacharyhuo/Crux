import AppKit
import CryptoKit
import CruxCore
import Foundation
import Testing
import WebKit

@testable import Crux

private final class SpringAcceptanceBundleMarker: NSObject {}

/// Opt-in real candidate checks, without frontmost windows or input automation.
/// Stage the generated bundle at CruxTests/Spring_Framework.docset before building.
@MainActor
@Suite(.serialized)
struct SpringRuntimeAcceptanceTests {
    nonisolated private static var supplyCatalog: URL? {
        Bundle(for: SpringAcceptanceBundleMarker.self).url(forResource: "SpringAcceptanceCatalog", withExtension: "json")
    }

    /// Only the remote transport is substituted. Catalog parsing, transfer queue,
    /// checksum checking, extraction, slot replacement, registry and reader are real.
    @Test(.enabled(if: supplyCatalog != nil), .timeLimit(.minutes(3)))
    func realArchivesReplaceOneSlotAndRejectCorruptUpdates() async throws {
        try #require(AppIdentity.current.isBeta)
        try #require(CruxAppRuntimeConfiguration.resolve().isUITesting)
        let bundle = Bundle(for: SpringAcceptanceBundleMarker.self)
        let entries = try CatalogEntry.parseList(Data(contentsOf: #require(Self.supplyCatalog)), provider: .versioned(
            catalogURL: URL(string: "https://spring-acceptance.invalid/catalog.json")!, sourceId: "dev.crux"))
        let entry = try #require(entries.first)
        let latest = try entry.resolve(.latest)
        let family = try #require(entry.releaseFamily)
        let old = try #require(family.releases.first { $0.id != latest.id })
        try #require(latest.version == "7.0.9" && latest.revision == 2)
        try #require(old.version == "7.0.9" && old.revision == 1)
        let oldBytes = try Data(contentsOf: #require(bundle.url(forResource: "SpringAcceptanceOld", withExtension: "tgz")))
        let newBytes = try Data(contentsOf: #require(bundle.url(forResource: "SpringAcceptanceNew", withExtension: "tgz")))
        let downloads = SpringArchiveTransport(files: [old.artifact.url: oldBytes, latest.artifact.url: newBytes])
        let root = FileManager.default.temporaryDirectory.appending(path: "SpringSupply-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = ReaderPreferences(defaults: defaults)
        preferences.allowsRemoteResources = false
        preferences.restoresLastSession = false
        let model = AppModel(preferences: preferences, layout: AppDirectoryLayout(applicationSupportDirectory: root),
                             catalogClient: SpringAcceptanceCatalog(entry: entry), downloadClient: downloads,
                             usesBackgroundDownloads: false, releaseChecker: nil)
        await model.bootstrap()
        do {
            try #require(model.installed.isEmpty)
            await model.installCatalogEntry(entry)
            try await wait("default latest installation") {
                try #require(model.libraryError == nil, "Library: \(String(describing: model.libraryError))")
                for job in model.transferJobs {
                    if case let .failed(message) = job.status { throw SupplyFailure(message: message) }
                }
                return model.installed.first?.installTarget?.release.id == latest.id
            }
            let installed = try #require(model.installed.first)
            try #require(installed.selectionPolicy == .latest)
            try verifyPackagedFiles(installed.descriptor)
            try #require(DocsetIconResolver.image(for: installed.descriptor) != nil)
            let location = ReaderLocation(docsetIdentifier: installed.identifier,
                relativePath: "api/javadoc-api/org/springframework/beans/factory/BeanFactory.html")
            model.open(location)
            let tab = try #require(model.selectedTab)
            try await wait("installed reader") { !tab.webView.isLoading && tab.webView.title?.contains("BeanFactory") == true }
            await model.installCatalogEntry(entry, selection: .pinnedRelease(old.id))
            try await wait("pinned old release") { model.installed.first?.installTarget?.release.id == old.id }
            let pinned = try #require(model.installed.first)
            try #require(pinned.selectionPolicy == .pinnedRelease(old.id))
            try #require(model.availableUpdates.isEmpty)
            let jobs = model.transferJobs.count
            await model.updateAllDocsets()
            try #require(model.transferJobs.count == jobs)
            try #require(model.installed.count == 1)
            try #require(pinned.descriptor.bundleURL == installed.descriptor.bundleURL)
            try #require(!FileManager.default.fileExists(atPath: pinned.descriptor.bundleURL.appending(path: "Contents/Resources/Documents/licenses/crux-third-party/PRISM-LICENSE.txt").path))
            await downloads.setCorrupt(true)
            await model.installCatalogEntry(entry)
            try await wait("corrupt download rejected") {
                model.transferJobs.contains { if case .failed = $0.status { true } else { false } }
            }
            try #require(model.installed == [pinned])
            // WebKit updates the location title after navigation. Compare the
            // stable navigation identity, not the initial empty display title.
            try #require(model.selectedTab?.id == tab.id)
            try #require(tab.currentLocation?.isSamePage(as: location) == true && tab.currentLocation?.fragment == location.fragment)
            let registry = try DocsetRegistry(databaseURL: model.layout.databaseURL)
            try #require(try await registry.allInstalled() == [pinned])
            let results = try await SymbolSearchService().search("BeanFactory", in: model.docsets, limit: 1000)
            try #require(results.contains { $0.name == "org.springframework.beans.factory.BeanFactory" })
            await downloads.setCorrupt(false)
            await model.installCatalogEntry(entry)
            try await wait("replace with latest") { model.installed.first?.installTarget?.release.id == latest.id }
            try #require(model.installed.count == 1 && model.docsets.count == 1)
            let replaced = try #require(model.installed.first)
            try #require(replaced.selectionPolicy == .latest)
            try #require(replaced.descriptor.bundleURL == installed.descriptor.bundleURL)
            try #require(model.selectedTab?.id == tab.id)
            try #require(tab.currentLocation?.isSamePage(as: location) == true && tab.currentLocation?.fragment == location.fragment)
            try await wait("replacement reader reloaded") { !tab.webView.isLoading && tab.webView.title?.contains("BeanFactory") == true }
            try verifyPackagedFiles(replaced.descriptor)
            try #require(try await registry.allInstalled() == [replaced])
            let folders = try FileManager.default.contentsOfDirectory(atPath: model.layout.defaultDocsetsDirectory.path)
            try #require(folders.filter { $0.hasSuffix(".docset") }.count == 1)
            Attachment.record(Data("Spring 7.0.9: real archives revision 2 -> pinned 1 -> corrupt 2 rejected -> 2; one slot; all packaged file hashes verified; no network performed".utf8), named: "Spring supply acceptance.txt")
            await model.shutdown()
        } catch {
            Attachment.record(Data(String(describing: model.transferJobs).utf8), named: "Spring supply jobs.txt")
            await model.shutdown()
            throw error
        }
    }

    private func verifyPackagedFiles(_ descriptor: DocsetDescriptor) throws {
        let resources = descriptor.bundleURL.appending(path: "Contents/Resources")
        let documents = resources.appending(path: "Documents")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resources.appending(path: "spring-assets/manifest.json"))) as? [String: Any])
        let files = try #require(manifest["files"] as? [[String: Any]])
        try #require(files.count == 11_648)
        for file in files {
            let relative = try #require(file["path"] as? String)
            try #require(!relative.hasPrefix("/") && !relative.split(separator: "/").contains(".."))
            let bytes = try Data(contentsOf: documents.appending(path: relative))
            let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try #require(checksum == file["sha256"] as? String, "Installed asset changed: \(relative)")
        }
        try #require(files.contains { $0["path"] as? String == "licenses/crux-third-party/PRISM-LICENSE.txt" })
        for name in ["icon.png", "icon@2x.png"] {
            try #require(NSImage(contentsOf: descriptor.bundleURL.appending(path: name)) != nil)
        }
    }

    nonisolated private static var candidate: URL? {
        Bundle(for: SpringAcceptanceBundleMarker.self)
            .url(forResource: "Spring_Framework", withExtension: "docset")
    }

    @Test(.enabled(if: candidate != nil), .timeLimit(.minutes(3)))
    func offlineCandidateInteractions() async throws {
        try #require(AppIdentity.current.isBeta, "Real docsets must only run in Beta")
        try #require(CruxAppRuntimeConfiguration.resolve().isUITesting)
        let source = try #require(Self.candidate)
        let root = FileManager.default.temporaryDirectory.appending(path: "SpringRuntime-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        try FileManager.default.createDirectory(at: layout.defaultDocsetsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: layout.defaultDocsetsDirectory.appending(path: "Spring_Framework.docset"))
        let preferences = ReaderPreferences(defaults: defaults)
        preferences.allowsRemoteResources = false
        preferences.restoresLastSession = false
        let model = AppModel(preferences: preferences, layout: layout)
        await model.bootstrap()
        do {
            try #require(model.startupError == nil)
            try #require(model.libraryError == nil)
            let descriptor = try #require(model.docsets.first { $0.bundleIdentifier == "dev.crux.spring-framework" }, "Scan failures: \(model.scanFailures)")
            #expect(model.docsets.count == 1)
            let tab = try #require(model.selectedTab)
            let web = tab.webView
            web.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
            web.configuration.userContentController.addUserScript(WKUserScript(source: """
                window.cruxAcceptanceErrors = [];
                addEventListener('error', e => cruxAcceptanceErrors.push(e.message || 'resource:' + (e.target.src || e.target.href)), true);
                addEventListener('unhandledrejection', e => cruxAcceptanceErrors.push(String(e.reason)));
                addEventListener('securitypolicyviolation', e => cruxAcceptanceErrors.push('CSP:' + e.violatedDirective + ':' + e.blockedURI));
                const originalError = console.error.bind(console);
                console.error = (...args) => {cruxAcceptanceErrors.push('console:' + args.map(String).join(' ')); originalError(...args);};
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))

            let symbols = try await SymbolSearchService().search("BeanFactory", in: model.docsets, limit: 1000)
            try #require(symbols.contains { $0.name == "org.springframework.beans.factory.BeanFactory" })
            tab.search.updateQuery("BeanFactory")
            try await wait("client symbol search") { !tab.search.results.isEmpty }
            try #require(tab.search.results.contains { $0.name == "org.springframework.beans.factory.BeanFactory" })

            func open(_ path: String) async throws {
                model.open(ReaderLocation(docsetIdentifier: descriptor.identifier, relativePath: path))
                try await wait("load \(path)") {
                    !web.isLoading && tab.currentLocation?.relativePath == path && web.url?.path.hasSuffix(path) == true
                }
                try await condition(web, "document.readyState === 'complete'", label: "DOM ready \(path)")
            }

            try await open("index.html")
            try #require(try await web.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "Spring Framework 7.0.9")
            try await open("api/javadoc-api/index.html")
            try await condition(web, "typeof typeSearchIndex !== 'undefined' && typeof memberSearchIndex !== 'undefined'", label: "Javadoc dynamic search indexes")
            try await condition(web, "!document.querySelector('#search-input').disabled", label: "Javadoc search enabled")
            _ = try await web.evaluateJavaScript("document.querySelector('#search-input').value = 'BeanFactory'; document.querySelector('#search-input').dispatchEvent(new Event('input', {bubbles:true}))")
            try await condition(web, "document.querySelectorAll('.ui-menu-item').length > 0", label: "Javadoc search results")
            Attachment.record(try await snapshot(web), named: "Javadoc initial DOM.json")
            try await assertNoRuntimeErrors(web)
            _ = try await web.evaluateJavaScript("[...document.querySelectorAll('.ui-menu-item')].find(x => x.querySelector('.search-result-label')?.textContent === 'BeanFactory').querySelector('div').click()")
            try await wait("Javadoc selected result navigation") {
                !web.isLoading && tab.currentLocation?.relativePath == "api/javadoc-api/org/springframework/beans/factory/BeanFactory.html"
            }
            _ = try await web.evaluateJavaScript("document.querySelector('#method-summary-table-tab3').click()")
            try #require(try await web.evaluateJavaScript("document.querySelector('#method-summary-table-tab3').getAttribute('aria-selected')") as? String == "true")
            try await assertNoRuntimeErrors(web)

            try await open("api/kdoc-api/index.html")
            try await condition(web, "document.querySelectorAll('#sideMenu .toc--link').length > 0", label: "Dokka fetched navigation")
            let expanded = try await web.evaluateJavaScript("document.querySelector('#sideMenu button').getAttribute('aria-expanded')") as? String
            _ = try await web.evaluateJavaScript("document.querySelector('#sideMenu button').click()")
            try #require(try await web.evaluateJavaScript("document.querySelector('#sideMenu button').getAttribute('aria-expanded')") as? String != expanded)
            try await condition(web, "document.querySelector('#pages-search') !== null", label: "Dokka search component")
            _ = try await web.evaluateJavaScript("document.querySelector('#pages-search').click()")
            try await condition(web, "document.querySelector('[data-test-custom=ring-select-popup-filter-input]') !== null", label: "Dokka search popup")
            _ = try await web.evaluateJavaScript("""
                (() => {const input = document.querySelector('[data-test-custom=ring-select-popup-filter-input]');
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, 'CoWebFilter');
                input.dispatchEvent(new Event('input', {bubbles:true}));})()
                """)
            try await condition(web, "document.querySelector('.template-description')?.textContent.includes('CoWebFilter') === true", label: "Dokka broad query applied")
            _ = try await web.evaluateJavaScript("document.querySelector('.ReactVirtualized__Grid').scrollTop = 0; document.querySelector('.ReactVirtualized__Grid').dispatchEvent(new Event('scroll'))")
            try await condition(web, "[...document.querySelectorAll('.template-description')].some(x => x.textContent === 'org.springframework.web.server.CoWebFilter')", label: "Dokka class result at list start")
            Attachment.record(try await snapshot(web), named: "Dokka broad search DOM.json")
            _ = try await web.evaluateJavaScript("""
                (() => {const input = document.querySelector('[data-test-custom=ring-select-popup-filter-input]');
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, 'org.springframework.web.server.CoWebFilter.CoWebFilter');
                input.dispatchEvent(new Event('input', {bubbles:true}));})()
                """)
            try await condition(web, "[...document.querySelectorAll('.template-description')].some(x => x.textContent === 'org.springframework.web.server.CoWebFilter.CoWebFilter')", label: "Dokka filtered constructor result")
            Attachment.record(try await snapshot(web), named: "Dokka navigation DOM.json")
            try await assertNoRuntimeErrors(web)
            _ = try await web.evaluateJavaScript("[...document.querySelectorAll('.template-description')].find(x => x.textContent === 'org.springframework.web.server.CoWebFilter.CoWebFilter').click()")
            try await wait("Dokka selected result navigation") {
                !web.isLoading && tab.currentLocation?.relativePath == "api/kdoc-api/spring-web/org.springframework.web.server/-co-web-filter/-co-web-filter.html"
            }
            try await condition(web, "document.querySelector('#content').innerText.includes('CoWebFilter')", label: "Dokka target content")
            try await assertNoRuntimeErrors(web)

            try await open("reference/core/beans/context-introduction.html")
            try #require(try await web.evaluateJavaScript("document.querySelector('nav details').open") as? Bool == false)
            _ = try await web.evaluateJavaScript("document.querySelector('nav summary').click()")
            try #require(try await web.evaluateJavaScript("document.querySelector('nav details').open") as? Bool == true)
            _ = try await web.evaluateJavaScript("document.querySelector('nav summary').click()")
            try #require(try await web.evaluateJavaScript("document.querySelector('nav details').open") as? Bool == false)
            try #require(try await web.evaluateJavaScript("document.querySelectorAll('.Crux-missingApiNotice').length") as? Int == 2)
            _ = try await web.evaluateJavaScript("document.querySelector('.Crux-codeExample summary').click()")
            try #require(try await web.evaluateJavaScript("document.querySelector('.Crux-codeExample').open") as? Bool == false)
            Attachment.record(try await snapshot(web), named: "Reference DOM.json")
            try await assertNoRuntimeErrors(web)
            _ = try await web.evaluateJavaScript("document.querySelector('main a[href*=\"api/javadoc-api/\"]').click()")
            try await wait("reference to API navigation") {
                !web.isLoading && tab.currentLocation?.relativePath == "api/javadoc-api/org/springframework/context/ApplicationContext.html"
            }
            try #require(web.url?.host() == "127.0.0.1")
            tab.goBack()
            try await wait("return to reference") {
                !web.isLoading && tab.currentLocation?.relativePath == "reference/core/beans/context-introduction.html"
            }
            await model.shutdown()
        } catch {
            if let web = model.selectedTab?.webView, let data = try? await snapshot(web) {
                Attachment.record(data, named: "Failure DOM.json")
            }
            await model.shutdown()
            throw error
        }
    }

    private func condition(_ web: WKWebView, _ expression: String, label: String) async throws {
        try await wait(label) { try await web.evaluateJavaScript(expression) as? Bool == true }
    }

    private func assertNoRuntimeErrors(_ web: WKWebView) async throws {
        let errors = try await web.evaluateJavaScript("window.cruxAcceptanceErrors") as? [String]
        try #require(errors == [])
        try #require(try await web.evaluateJavaScript("performance.getEntriesByType('resource').every(x => new URL(x.name).origin === location.origin || x.name.startsWith('data:'))") as? Bool == true)
    }

    private func wait(_ label: String, _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AcceptanceTimeout(step: label)
    }

    private func snapshot(_ web: WKWebView) async throws -> Data {
        let json = try await web.evaluateJavaScript("""
            JSON.stringify({url: location.pathname, title: document.title,
              errors: window.cruxAcceptanceErrors || [],
              inputs: [...document.querySelectorAll('input')].map(x => ({id:x.id,placeholder:x.placeholder,disabled:x.disabled})),
              resources: performance.getEntriesByType('resource').map(x => ({name:new URL(x.name).pathname,origin:new URL(x.name).origin,status:x.responseStatus})),
              body: document.body.innerText.slice(0,12000)})
            """)
        return Data(try #require(json as? String).utf8)
    }
}

private struct AcceptanceTimeout: Error { let step: String }
private struct SupplyFailure: Error { let message: String }

private struct SpringAcceptanceCatalog: CatalogClient {
    let entry: CatalogEntry
    func cachedSnapshot() async -> CatalogSnapshot? { CatalogSnapshot(entries: [entry], fetchedAt: .now, isFromCache: true) }
    func fetch(forceRefresh: Bool) async throws -> CatalogSnapshot { CatalogSnapshot(entries: [entry], fetchedAt: .now, isFromCache: false) }
}

private actor SpringArchiveTransport: DownloadClient {
    let files: [URL: Data]
    private var corrupt = false
    init(files: [URL: Data]) { self.files = files }
    func setCorrupt(_ value: Bool) { corrupt = value }
    func download(from url: URL, to destinationURL: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard let data = files[url] else { throw URLError(.resourceUnavailable) }
        try (corrupt ? Data("deliberately corrupt archive".utf8) : data).write(to: destinationURL)
    }
}
