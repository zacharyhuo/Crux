import XCTest

final class SourceManagementUITests: XCTestCase {
    @MainActor func testBuiltInDefaultsAndHTTPConsentPreserveSourceIdentity() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-crux-ui-testing", "YES", "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let workspace = app.searchFields["reader-search-field"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["Manage Docsets"].waitForExistence(timeout: 8))
        app.buttons["Manage Docsets"].click()
        let settings = app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let sources = settings.radioButtons["Sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.click()
        let cruxID = "c6e34573-1b71-41b4-8be7-6fe0ed483001"
        let zealID = "c6e34573-1b71-41b4-8be7-6fe0ed483002"
        let crux = settings.switches["source-toggle-\(cruxID)"]
        let zeal = settings.switches["source-toggle-\(zealID)"]
        XCTAssertTrue(crux.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: crux.value ?? ""), "1")
        XCTAssertEqual(String(describing: zeal.value ?? ""), "0")
        XCTAssertFalse(settings.buttons["source-delete-\(cruxID)"].exists)
        XCTAssertFalse(settings.buttons["source-delete-\(zealID)"].exists)
        settings.buttons["source-add"].click()
        let name = element(in: app, prefix: "source-editor-name-")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        pasteText("Test Mirror", into: name)
        XCTAssertEqual(name.value as? String, "Test Mirror", app.debugDescription)
        let catalog = element(in: app, prefix: "source-editor-catalog-url-")
        pasteText("http://127.0.0.1:9/v1/docsets", into: catalog)
        XCTAssertEqual(catalog.value as? String, "http://127.0.0.1:9/v1/docsets", app.debugDescription)
        let root = element(in: app, prefix: "source-editor-download-root-url-")
        pasteText("http://127.0.0.1:9/d", into: root)
        XCTAssertEqual(root.value as? String, "http://127.0.0.1:9/d", app.debugDescription)
        root.typeKey(.tab, modifierFlags: [])
        let save = element(in: app, prefix: "source-editor-save-")
        XCTAssertTrue(save.waitForExistence(timeout: 3), "The sheet must not override its Save button's accessibility identity.")
        XCTAssertFalse(save.isEnabled, "HTTP must require explicit consent.")
        element(in: app, prefix: "source-editor-local-http-consent-").click()
        element(in: app, prefix: "source-editor-enabled-").click()
        XCTAssertTrue(save.isEnabled, app.debugDescription)
        save.click()
        XCTAssertTrue(settings.staticTexts["Test Mirror"].waitForExistence(timeout: 5))
        let row = settings.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'source-row-'")).allElementsBoundByIndex
            .first { $0.staticTexts["Test Mirror"].exists }
        let sourceRow = try XCTUnwrap(row)
        let id = String(sourceRow.identifier.dropFirst("source-row-".count))
        XCTAssertEqual(String(describing: settings.switches["source-toggle-\(id)"].value ?? ""), "0")
        settings.buttons["source-edit-\(id)"].click()
        let renamed = element(in: app, prefix: "source-editor-name-")
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        pasteText("Renamed Mirror", into: renamed)
        XCTAssertEqual(renamed.value as? String, "Renamed Mirror", app.debugDescription)
        renamed.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(element(in: app, prefix: "source-editor-local-http-consent-").exists)
        element(in: app, prefix: "source-editor-save-").click()
        XCTAssertTrue(settings.staticTexts["Renamed Mirror"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.descendants(matching: .any)["source-row-\(id)"].exists)
        // AX captures remain available when XCTest cannot screenshot an
        // external-display window; rendering is also checked separately.
        let attachment = XCTAttachment(string: settings.debugDescription)
        attachment.name = "Isolated Beta Sources accessibility tree"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor private func element(in app: XCUIApplication, prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor private func pasteText(_ text: String, into field: XCUIElement) {
        UITestClipboard.withText(text) {
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey("v", modifierFlags: .command)
        }
    }
}
