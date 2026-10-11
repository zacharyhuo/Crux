import XCTest

@MainActor
final class DocsetVersionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testVersionMenuDefaultsToLatestAndDoesNotDownloadOnSelection() throws {
        let app = launchFixture()
        let window = settings(in: app)
        let picker = versionPicker(in: window)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), window.debugDescription)
        XCTAssertTrue((picker.value as? String ?? "").contains("Latest"), picker.debugDescription)
        picker.click()
        let old = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "3.13.9")).firstMatch
        XCTAssertTrue(old.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "3.14.7")).firstMatch.exists)
        old.click()
        window.radioButtons["Installed"].click()
        XCTAssertTrue(window.staticTexts["No docsets are installed yet."].waitForExistence(timeout: 3), window.debugDescription)
    }

    func testInstalledVersionSwitchRequiresConfirmationAndKeepsOneSlot() throws {
        let app = launchFixture()
        let window = settings(in: app)
        installLatest(in: app)
        window.radioButtons["Installed"].click()
        let row = installedRow(in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        choose("3.13.9", in: app)
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "3.14.7")).firstMatch.exists)
        window.buttons["docset-switch-dev.crux/python"].click()
        XCTAssertTrue(window.sheets.firstMatch.buttons["Replace Version"].waitForExistence(timeout: 3), app.debugDescription)
        window.sheets.firstMatch.buttons["Cancel"].click()
        XCTAssertTrue((versionPicker(in: window).value as? String ?? "").contains("Latest"))
        choose("3.13.9", in: app)
        window.buttons["docset-switch-dev.crux/python"].click()
        window.sheets.firstMatch.buttons["Replace Version"].click()
        waitForInstalledVersion("3.13.9", in: window)
        XCTAssertEqual(window.descendants(matching: .any).matching(identifier: "installed-docset-dev.crux.python").count, 1)
        XCTAssertFalse(window.buttons["Update All"].isEnabled)
        choose("Latest", in: app)
        window.buttons["docset-switch-dev.crux/python"].click()
        window.sheets.firstMatch.buttons["Replace Version"].click()
        waitForInstalledVersion("3.14.7", in: window)
    }

    func testFailedVersionSwitchPreservesTheInstalledVersion() throws {
        let app = launchFixture(["-crux-fixture-failure"])
        let window = settings(in: app)
        installLatest(in: app)
        window.radioButtons["Installed"].click()
        choose("3.13.9", in: app)
        window.buttons["docset-switch-dev.crux/python"].click()
        window.sheets.firstMatch.buttons["Replace Version"].click()
        let retry = window.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Python,' AND label ENDSWITH ', Retry'")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5), window.debugDescription)
        waitForInstalledVersion("3.14.7", in: window)
        XCTAssertEqual(window.descendants(matching: .any).matching(identifier: "installed-docset-dev.crux.python").count, 1)
    }

    func testWithdrawnPendingVersionIsUnavailableInsteadOfFallingBackToLatest() throws {
        let app = launchFixture(["-crux-fixture-withdraw"])
        let window = settings(in: app)
        choose("3.13.9", in: app)
        window.staticTexts["Python"].firstMatch.click()
        window.buttons["Refresh Catalog"].click()
        let unavailable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (self.versionPicker(in: window).value as? String ?? "").contains("Unavailable")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unavailable], timeout: 5), .completed)
        XCTAssertFalse(window.buttons["catalog-install-selection"].isEnabled)
        choose("Latest", in: app)
        XCTAssertTrue(window.buttons["catalog-install-selection"].isEnabled)
    }

    func testBatchReplacementConfirmsEverySelectedFamily() throws {
        let app = launchFixture()
        let window = settings(in: app)
        // Use the list's native Select All shortcut, not picker state.
        let list = window.outlines.firstMatch
        list.click()
        list.typeKey("a", modifierFlags: .command)
        window.buttons["catalog-install-selection"].click()
        window.radioButtons["Installed"].click()
        XCTAssertTrue(installedRow(in: window).waitForExistence(timeout: 5))
        XCTAssertTrue(installedRow(in: window, family: "sample").waitForExistence(timeout: 5), window.debugDescription)
        window.radioButtons["Available"].click()
        choose("3.13.9", in: app)
        choose("3.13.9", family: "sample", in: app)
        window.staticTexts["Python"].firstMatch.click()
        XCUIElement.perform(withKeyModifiers: .command) {
            window.staticTexts["Sample"].firstMatch.click()
        }
        XCTAssertTrue((versionPicker(in: window).value as? String ?? "").contains("3.13.9"), window.debugDescription)
        XCTAssertTrue((versionPicker(in: window, family: "sample").value as? String ?? "").contains("3.13.9"), window.debugDescription)
        XCTAssertEqual(window.buttons["catalog-install-selection"].label, "Switch Version", window.debugDescription)
        window.buttons["catalog-install-selection"].click()
        XCTAssertTrue(window.sheets.firstMatch.buttons["Replace Version"].waitForExistence(timeout: 3), window.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "Python", "Sample")).firstMatch.exists)
        window.sheets.firstMatch.buttons["Cancel"].click()
        window.radioButtons["Installed"].click()
        waitForInstalledVersion("3.14.7", in: window)
        waitForInstalledVersion("3.14.7", family: "sample", in: window)
    }

    func testOfflineCatalogExplainsItsCachedState() throws {
        let app = launchFixture(["-crux-fixture-offline"])
        let window = settings(in: app)
        XCTAssertTrue(window.staticTexts["Showing the last successful catalog. Refresh when you are back online."].waitForExistence(timeout: 3))
        XCTAssertTrue(versionPicker(in: window).exists)
    }

    func testDocsetPrefixAndEmptyDeletePreserveSearchFocus() throws {
        let app = launchFixture()
        installLatest(in: app)
        let window = settings(in: app)
        let close = window.buttons["_XCUI:CloseWindow"]
        XCTAssertTrue(close.exists)
        close.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: window
        )], timeout: 3), .completed)
        let field = app.searchFields["reader-search-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.click()
        pasteIntoFocusedResponder("python:", in: app)
        let scope = app.descendants(matching: .any).matching(identifier: "reader-docset-scope").firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(field.value as? String, "")
        XCTAssertTrue(app.staticTexts["search-panel-title"].exists, "Selecting a prefix must keep the docset browser open.")
        // App-level paste proves selection retained focus without forcing it.
        pasteIntoFocusedResponder("newAPI", in: app)
        XCTAssertEqual(field.value as? String, "newAPI")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "newAPI")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(field.value as? String, "")
        XCTAssertTrue(scope.exists, "Deleting text must keep the selected docset.")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])
        let clearedScope = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: scope)
        XCTAssertEqual(XCTWaiter.wait(for: [clearedScope], timeout: 3), .completed)
        pasteIntoFocusedResponder("unknown:", in: app)
        XCTAssertEqual(field.value as? String, "unknown:")
        XCTAssertFalse(scope.exists)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        let docset = app.buttons["search-docset-dev.crux.python"]
        XCTAssertTrue(docset.waitForExistence(timeout: 3), app.debugDescription)
        docset.click()
        XCTAssertTrue(scope.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "")
        XCTAssertTrue(app.staticTexts["search-panel-title"].exists)
        pasteIntoFocusedResponder("newAPI", in: app)
        XCTAssertEqual(field.value as? String, "newAPI", "Manual selection must also return focus to the search field.")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: scope
        )], timeout: 3), .completed)
        pasteIntoFocusedResponder("continued", in: app)
        XCTAssertEqual(field.value as? String, "continued")
    }

    private func installLatest(in app: XCUIApplication) {
        let window = settings(in: app)
        window.staticTexts["Python"].firstMatch.click()
        window.buttons["catalog-install-selection"].click()
        window.radioButtons["Installed"].click()
        waitForInstalledVersion("3.14.7", in: window)
        window.radioButtons["Available"].click()
    }

    private func pasteIntoFocusedResponder(_ text: String, in app: XCUIApplication) {
        UITestClipboard.withText(text) { app.typeKey("v", modifierFlags: .command) }
    }

    private func choose(_ version: String, family: String = "python", in app: XCUIApplication) {
        versionPicker(in: settings(in: app), family: family).click()
        let option = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", version)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), app.debugDescription)
        option.click()
    }

    private func installedRow(in window: XCUIElement, family: String = "python") -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "installed-docset-dev.crux.\(family)").firstMatch
    }

    private func waitForInstalledVersion(_ version: String, family: String = "python", in window: XCUIElement) {
        let label = installedRow(in: window, family: family).staticTexts.matching(NSPredicate(format: "value CONTAINS %@", version)).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 8), window.debugDescription)
    }

    private func launchFixture(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES", "-crux-ui-testing", "-crux-version-fixture"] + flags
        app.launch()
        let download = app.buttons["Download Docsets"]
        XCTAssertTrue(download.waitForExistence(timeout: 8), app.debugDescription)
        download.click()
        XCTAssertTrue(settings(in: app).waitForExistence(timeout: 5))
        return app
    }

    private func settings(in app: XCUIApplication) -> XCUIElement {
        app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    }

    private func versionPicker(in window: XCUIElement, family: String = "python") -> XCUIElement {
        window.popUpButtons["docset-version-picker-dev.crux/\(family)"]
    }
}
