import XCTest
import AppKit

final class CruxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeTabUsesTheNewPrimaryActions() throws {
        let app = launchApp()

        let welcomeTitle = app.staticTexts["welcome-title"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(welcomeTitle.label, "Welcome to Crux")
        XCTAssertTrue(app.buttons["Download Docsets"].exists)
        XCTAssertTrue(app.buttons["Manage Docsets"].exists)
        XCTAssertFalse(app.staticTexts["Pick a symbol from the search results to start reading."].exists)
    }

    @MainActor
    func testEveryTabOwnsASeparateWorkspaceBarWithSearchAndNavigation() throws {
        let app = launchApp()

        let searchField = app.searchFields.firstMatch
        let workspaceBar = app.groups["reader-workspace-bar"]
        XCTAssertTrue(
            workspaceBar.waitForExistence(timeout: 5),
            "Expected a per-tab workspace bar below the top-level tabs. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(workspaceBar.frame.intersects(searchField.frame))
        XCTAssertEqual(searchField.frame.height, 38, accuracy: 1)
        XCTAssertEqual(
            searchField.frame.midY,
            app.groups["reader-navigation-actions"].frame.midY,
            accuracy: 1
        )
        XCTAssertEqual(
            searchField.frame.midY,
            app.groups["reader-actions"].frame.midY,
            accuracy: 1
        )
        XCTAssertFalse(
            workspaceBar.menuButtons["Search across every installed docset"].exists,
            "All Docsets must use the search field's native icon instead of rendering a duplicate scope button."
        )
        XCTAssertLessThanOrEqual(
            searchField.frame.width,
            560,
            "Search must remain a compact principal action instead of consuming the full toolbar."
        )
        XCTAssertLessThanOrEqual(
            abs(searchField.frame.midX - workspaceBar.frame.midX),
            80,
            "The search field must stay visually centered in its per-tab workspace bar."
        )
        XCTAssertTrue(workspaceBar.buttons["Back"].exists)
        XCTAssertTrue(workspaceBar.buttons["Forward"].exists)
        XCTAssertTrue(workspaceBar.buttons["Home"].exists)
        for title in ["Back", "Forward", "Home"] {
            XCTAssertGreaterThanOrEqual(
                workspaceBar.buttons[title].frame.width,
                28,
                "Each navigation action needs its own comfortable pointer target."
            )
        }
        XCTAssertFalse(workspaceBar.buttons["Close Tab"].exists)
        XCTAssertFalse(workspaceBar.buttons["New Tab"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Aligned workspace search and actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSingleTabHidesItsTabStripUntilCommandTCreatesAnotherTab() throws {
        let app = launchApp()
        let tabStrip = app.scrollViews["workspace-tab-strip"]
        XCTAssertFalse(tabStrip.exists, "One tab must not reserve a visible tab strip.")
        XCTAssertFalse(
            app.buttons.matching(identifier: "workspace-tab-new").firstMatch.exists,
            "While the strip is hidden, Command-T must be the only New Tab affordance."
        )

        app.typeKey("t", modifierFlags: .command)
        let secondTabAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                tabStrip.groups.matching(identifier: "workspace-tab-item").count == 2
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [secondTabAppeared], timeout: 5), .completed)
        let multiTabNewTab = app.buttons.matching(identifier: "workspace-tab-new").firstMatch
        XCTAssertTrue(multiTabNewTab.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            abs(multiTabNewTab.frame.width - multiTabNewTab.frame.height),
            10,
            "The multi-tab New Tab action may retain a wider hit area around its circular glass control."
        )
    }

    @MainActor
    func testWorkspaceSearchIsCenteredAndContainedWithinToolbar() throws {
        let app = launchApp()
        let window = app.windows.firstMatch
        let originalWidth = window.frame.width
        if originalWidth < 900 {
            resizeWindow(window, toWidth: 1000)
        }
        defer {
            if originalWidth < 900 {
                resizeWindow(window, toWidth: originalWidth)
            }
        }

        let navigationActions = app.groups["reader-navigation-actions"]
        let searchField = app.searchFields.matching(identifier: "reader-search-field").firstMatch
        let readerActions = app.groups["reader-actions"]
        let workspaceBar = app.groups["reader-workspace-bar"]

        XCTAssertTrue(navigationActions.waitForExistence(timeout: 5))
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(readerActions.waitForExistence(timeout: 5))
        XCTAssertTrue(workspaceBar.waitForExistence(timeout: 5))

        // Native search-field drawing/accessibility bounds differ from the
        // SwiftUI wrapper's bounds. Compare the actual field's center, not
        // equal top/bottom edges of unlike accessibility groups.
        let fieldFrame = searchField.frame
        let barFrame = workspaceBar.frame
        XCTAssertEqual(fieldFrame.height, 38, accuracy: 1)
        XCTAssertEqual(fieldFrame.midY, navigationActions.frame.midY, accuracy: 1)
        XCTAssertEqual(fieldFrame.midY, readerActions.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(fieldFrame.width, 0)
        XCTAssertGreaterThanOrEqual(fieldFrame.minX, barFrame.minX - 1)
        XCTAssertLessThanOrEqual(fieldFrame.maxX, barFrame.maxX + 1)
        XCTAssertGreaterThanOrEqual(fieldFrame.minY, barFrame.minY - 1)
        XCTAssertLessThanOrEqual(fieldFrame.maxY, barFrame.maxY + 1)

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Centered native search within workspace bounds"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNavigationGroupKeepsTheSameLeadingInsetWithOneOrMultipleTabs() throws {
        let app = launchApp()
        let navigationActions = app.groups["reader-navigation-actions"]
        XCTAssertTrue(navigationActions.waitForExistence(timeout: 5))
        let singleTabLeadingEdge = navigationActions.frame.minX

        app.typeKey("t", modifierFlags: .command)
        let tabStrip = app.scrollViews["workspace-tab-strip"]
        let secondTabAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                tabStrip.groups.matching(identifier: "workspace-tab-item").count == 2
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [secondTabAppeared], timeout: 5), .completed)

        let multiTabNavigationActions = app.groups["reader-navigation-actions"]
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(multiTabNavigationActions.frame.minX - singleTabLeadingEdge) <= 1
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [settled], timeout: 3),
            .completed,
            "The per-tab navigation group must not shift horizontally when the tab count changes."
        )
    }

    @MainActor
    func testTopTabStripAppearsForMultipleTabsAndHidesAgainForOne() throws {
        let app = launchApp()

        let tabStrip = app.scrollViews["workspace-tab-strip"]
        XCTAssertFalse(tabStrip.exists)

        app.typeKey("t", modifierFlags: .command)
        let secondTabAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                tabStrip.groups.matching(identifier: "workspace-tab-item").count == 2
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [secondTabAppeared], timeout: 5), .completed)
        let firstTabItem = tabStrip.groups.matching(identifier: "workspace-tab-item").firstMatch
        let firstTab = firstTabItem.buttons.matching(identifier: "workspace-tab").firstMatch
        let closeTab = firstTabItem.buttons.matching(identifier: "workspace-tab-close").firstMatch
        let newTab = app.buttons.matching(identifier: "workspace-tab-new").firstMatch
        XCTAssertEqual(tabStrip.groups.matching(identifier: "workspace-tab-item").count, 2)
        XCTAssertTrue(firstTabItem.exists)
        XCTAssertTrue(firstTab.exists)
        XCTAssertTrue(closeTab.exists, "Every tab must expose its own close button.")
        XCTAssertTrue(
            closeTab.label.contains(firstTab.label),
            "Each close action must name the tab it will close for VoiceOver."
        )
        XCTAssertTrue(newTab.exists)
        XCTAssertGreaterThan(
            closeTab.frame.midX,
            firstTab.frame.midX,
            "The close action must be rendered at the right side of its own tab."
        )
        XCTAssertLessThanOrEqual(closeTab.frame.maxX, firstTabItem.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(closeTab.frame.minX, firstTabItem.frame.minX - 1)
        XCTAssertGreaterThan(
            newTab.frame.minX,
            firstTabItem.frame.maxX,
            "New Tab must be outside the tab items and fixed at the trailing end of the strip."
        )
        XCTAssertLessThan(
            abs(app.windows.firstMatch.frame.maxX - newTab.frame.maxX),
            24,
            "New Tab must remain at the far trailing edge of the custom titlebar."
        )

        XCTAssertEqual(tabStrip.buttons.matching(identifier: "workspace-tab-close").count, 2)
        let secondTabItem = tabStrip.groups.matching(identifier: "workspace-tab-item").element(boundBy: 1)
        XCTAssertEqual(
            firstTabItem.frame.width,
            secondTabItem.frame.width,
            accuracy: 2,
            "Sibling glass tab cards must use a consistent width."
        )
        XCTAssertLessThanOrEqual(
            firstTabItem.frame.width,
            280,
            "Glass tab cards must stay compact instead of stretching across the window."
        )
        XCTAssertLessThan(
            firstTabItem.frame.minX - app.windows.firstMatch.frame.minX,
            32,
            "The leading tab card must align with the native traffic-light margin, without a second manual offset."
        )
        XCTAssertGreaterThan(
            firstTabItem.frame.midY,
            app.windows.firstMatch.frame.minY + 30,
            "Tabs belong on their own row below the native traffic-light titlebar."
        )

        tabStrip.buttons.matching(identifier: "workspace-tab-close").firstMatch.click()
        let oneTabRemains = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !tabStrip.exists
                    && !app.buttons.matching(identifier: "workspace-tab-new").firstMatch.exists
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [oneTabRemains], timeout: 3),
            .completed,
            "Closing back to one tab must remove the tab strip and its New Tab button."
        )
        XCTAssertTrue(app.staticTexts["welcome-title"].exists)
    }

    @MainActor
    func testMainWindowCannotResizeBelowItsMinimumSize() throws {
        let app = launchApp()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let originalSize = window.frame.size
        attemptResizeWindow(window, to: CGSize(width: 620, height: 500))
        defer { attemptResizeWindow(window, to: originalSize) }

        XCTAssertEqual(
            window.frame.width,
            856,
            accuracy: 1,
            "The main window must not resize below its 856-point minimum width."
        )
        XCTAssertEqual(
            window.frame.height,
            692,
            accuracy: 1,
            "The main window must not resize below its 692-point minimum height."
        )
    }

    @MainActor
    func testOverflowingTabStripKeepsTheNewTabActionVisibleAtMinimumWindowWidth() throws {
        let app = launchApp()
        createAdditionalTabs(3, in: app)

        let window = app.windows.firstMatch
        let tabStrip = app.scrollViews["workspace-tab-strip"]
        let newTab = app.buttons.matching(identifier: "workspace-tab-new").firstMatch
        XCTAssertTrue(tabStrip.waitForExistence(timeout: 5))
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))

        let originalSize = window.frame.size
        attemptResizeWindow(window, to: CGSize(width: 620, height: originalSize.height))
        defer { attemptResizeWindow(window, to: originalSize) }

        XCTAssertEqual(window.frame.width, 856, accuracy: 1)
        XCTAssertLessThanOrEqual(
            newTab.frame.maxX,
            window.frame.maxX - 8,
            "New Tab must remain visible at the trailing edge of the minimum-width window."
        )
        XCTAssertTrue(newTab.isHittable)
    }

    @MainActor
    func testSelectedTabRemainsVisibleWhenTheTitlebarStripOverflows() throws {
        let app = launchApp()
        createAdditionalTabs(6, in: app)

        let tabStrip = app.scrollViews["workspace-tab-strip"]
        XCTAssertTrue(tabStrip.waitForExistence(timeout: 5))
        let selectedTab = tabStrip.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND selected == true",
                "workspace-tab"
            )
        ).firstMatch

        let selectedTabBecameVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard selectedTab.exists else { return false }
                let itemFrame = selectedTab.frame
                let stripFrame = tabStrip.frame
                return itemFrame.minX >= stripFrame.minX - 1
                    && itemFrame.maxX <= stripFrame.maxX + 1
                    && selectedTab.isHittable
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selectedTabBecameVisible], timeout: 3),
            .completed,
            "The newly selected tab must automatically scroll into the visible titlebar strip."
        )
    }

    @MainActor
    func testTitlebarEdgesResizeInsteadOfDragging() throws {
        let app = launchApp()
        let window = app.windows.firstMatch
        prepareWindowForTitlebarTest(window, in: app)
        let original = window.frame
        let rightEdge = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: original.width - 1, dy: 14))
        rightEdge.press(forDuration: 0.1, thenDragTo: rightEdge.withOffset(CGVector(dx: 50, dy: 0)))
        XCTAssertGreaterThan(window.frame.width - original.width, 35, "The upper-right edge must resize, not move, the window")
        XCTAssertEqual(window.frame.minX, original.minX, accuracy: 3)
        XCTAssertEqual(window.frame.minY, original.minY, accuracy: 3)
        let beforeTopResize = window.frame
        let topEdge = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: beforeTopResize.width / 2, dy: 1))
        topEdge.press(forDuration: 0.1, thenDragTo: topEdge.withOffset(CGVector(dx: 0, dy: -30)))
        XCTAssertGreaterThan(window.frame.height - beforeTopResize.height, 20)
        XCTAssertEqual(window.frame.maxY, beforeTopResize.maxY, accuracy: 3)
        let beforeCorner = window.frame
        let corner = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: beforeCorner.width - 1, dy: 1))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -25, dy: 25)))
        XCTAssertGreaterThan(beforeCorner.width - window.frame.width, 15)
        XCTAssertGreaterThan(beforeCorner.height - window.frame.height, 15)
        XCTAssertEqual(window.frame.minX, beforeCorner.minX, accuracy: 3)
        XCTAssertEqual(window.frame.maxY, beforeCorner.maxY, accuracy: 3)
    }

    @MainActor
    func testZoomStaysOnEachWindowsCurrentDisplay() throws {
        let screens = NSScreen.screens
        try XCTSkipIf(screens.count < 2, "Requires two connected displays")
        let primaryTop = try XCTUnwrap(screens.first).frame.maxY
        let app = launchApp()
        let window = app.windows.firstMatch
        for screen in screens {
            let visible = screen.visibleFrame
            let display = CGRect(x: visible.minX, y: primaryTop - visible.maxY,
                                 width: visible.width, height: visible.height)
            attemptResizeWindow(window, to: CGSize(width: 900, height: 700))
            let frame = window.frame
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 200, dy: 14))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(
                dx: display.minX + 40 - frame.minX,
                dy: max(display.minY + 40, 40) - frame.minY
            )))
            XCTAssertTrue(display.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)))
            let original = window.frame
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 200, dy: 14)).doubleClick()
            let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.framesDiffer(window.frame, original)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 3), .completed,
                           "screen=\(screen.localizedName) target=\(display) before=\(original) after=\(window.frame)")
            XCTAssertEqual(window.frame.minX, display.minX, accuracy: 2, "screen=\(screen.localizedName) target=\(display) actual=\(window.frame)")
            // Activating a display can reveal its auto-hidden menu bar after
            // the runner queried visibleFrame. The native zoom must fill the
            // remaining area and keep all four edges on this display.
            XCTAssertGreaterThanOrEqual(window.frame.minY, display.minY - 2)
            XCTAssertLessThanOrEqual(window.frame.minY, display.minY + 40)
            XCTAssertEqual(window.frame.width, display.width, accuracy: 2)
            XCTAssertEqual(window.frame.maxY, display.maxY, accuracy: 2)
            if window.frame.minY < 0 {
                // XCTest cannot reliably synthesize negative global pointer
                // coordinates. Use AppKit's Zoom menu for the restore step.
                app.menuBars.menuBarItems["Window"].click()
                app.menuItems["Zoom"].click()
            } else {
                window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: 200, dy: 14)).doubleClick()
            }
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !self.framesDiffer(window.frame, original)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        }
        // Leave the next test on the primary display, where its titlebar has
        // positive global coordinates that XCTest can target reliably.
        let frame = window.frame
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 200, dy: 14))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(
            dx: 100 - frame.minX, dy: 100 - frame.minY
        )))
    }

    @MainActor
    func testNativeTopStripDragsAndZoomsWithoutVisibleTitle() throws {
        let app = launchApp()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        prepareWindowForTitlebarTest(window, in: app)
        resizeWindowForZoomTest(window)
        let beforeDrag = window.frame
        let top = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 200, dy: 14))
        top.press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(dx: 40, dy: 30)))
        // AppKit may adjust a drag near display edges or the menu bar.
        XCTAssertGreaterThan(window.frame.minX - beforeDrag.minX, 20)
        XCTAssertGreaterThan(window.frame.minY - beforeDrag.minY, 15)
        let original = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 200, dy: 14)).doubleClick()
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.framesDiffer(window.frame, original)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 3), .completed)
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 200, dy: 14)).doubleClick()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.framesDiffer(window.frame, original)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
    }

    @MainActor
    func testWorkspaceAndTabBarsDoNotManageTheWindow() throws {
        let app = launchApp()
        let window = app.windows.firstMatch
        for tabCount in 1...2 {
            if tabCount == 2 {
                app.typeKey("t", modifierFlags: .command)
                XCTAssertTrue(app.groups["workspace-titlebar"].waitForExistence(timeout: 5))
            }
            let original = window.frame
            let workspace = app.groups["reader-workspace-bar"].coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 150, dy: 26))
            workspace.doubleClick()
            workspace.press(forDuration: 0.1, thenDragTo: workspace.withOffset(CGVector(dx: 60, dy: 40)))
            XCTAssertFalse(framesDiffer(window.frame, original))
            if tabCount == 2 {
                let tabs = app.groups["workspace-titlebar"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
                tabs.doubleClick()
                tabs.press(forDuration: 0.1, thenDragTo: tabs.withOffset(CGVector(dx: 60, dy: 40)))
                XCTAssertFalse(framesDiffer(window.frame, original))
            }
        }
    }

    @MainActor
    func testNativeTitlebarHonorsDisabledDoubleClickPreference() throws {
        let app = launchApp(doubleClickAction: "None")
        let window = app.windows.firstMatch
        let original = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 200, dy: 14)).doubleClick()
        XCTAssertFalse(framesDiffer(window.frame, original))
    }

    @MainActor
    func testNativeTitlebarDoubleClicksSettleOnceAndRestoreRepeatedly() throws {
        let app = launchApp()
        let window = app.windows.firstMatch
        resizeWindowForZoomTest(window)
        let original = window.frame
        for _ in 0..<3 {
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 200, dy: 14)).doubleClick()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.framesDiffer(window.frame, original)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
            let zoomed = window.frame
            let bounced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.framesDiffer(window.frame, zoomed)
            }, object: nil)
            bounced.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [bounced], timeout: 1), .completed)
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 200, dy: 14)).doubleClick()
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !self.framesDiffer(window.frame, original)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        }
    }

    @MainActor
    func testMovingAWideWindowFromLargeDisplayToSmallDisplayKeepsZoomWithinScreen() throws {
        let screens = NSScreen.screens.sorted { $0.frame.width < $1.frame.width }
        try XCTSkipIf(screens.count < 2, "Requires two displays")
        let small = try XCTUnwrap(screens.first)
        let large = try XCTUnwrap(screens.last)
        try XCTSkipIf(large.frame.width - small.frame.width < 100, "Requires different display widths")
        let primaryTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let app = launchApp()
        let window = app.windows.firstMatch
        func move(to screen: NSScreen) {
            let current = window.frame
            let top = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 200, dy: 14))
            top.press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(
                dx: screen.frame.minX + 40 - current.minX,
                dy: max(40, primaryTop - screen.visibleFrame.maxY + 40) - current.minY
            )))
        }
        attemptResizeWindow(window, to: CGSize(width: 900, height: 700))
        move(to: large)
        attemptResizeWindow(window, to: CGSize(width: small.frame.width + 150, height: 700))
        XCTAssertGreaterThan(window.frame.width, small.frame.width)
        move(to: small)
        for click in 0..<2 {
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 200, dy: 14)).doubleClick()
            let bounds = CGRect(x: small.frame.minX, y: primaryTop - small.frame.maxY,
                                width: small.frame.width, height: small.frame.height)
            XCTAssertLessThanOrEqual(window.frame.width, bounds.width + 2)
            XCTAssertLessThanOrEqual(window.frame.height, bounds.height + 2)
            if click == 0 {
                XCTAssertGreaterThanOrEqual(window.frame.minX, bounds.minX - 2)
                XCTAssertGreaterThanOrEqual(window.frame.minY, bounds.minY - 2)
                XCTAssertLessThanOrEqual(window.frame.maxX, bounds.maxX + 2)
                XCTAssertLessThanOrEqual(window.frame.maxY, bounds.maxY + 2)
            }
            // Restore may preserve the user's partially offscreen drag
            // position, but must never restore the large display's width.
        }
    }

    @MainActor
    func testFocusingAnEmptySearchFieldPresentsTheDocsetBrowser() throws {
        let app = launchApp()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.click()

        let panelTitle = app.staticTexts["search-panel-title"]
        XCTAssertTrue(
            panelTitle.waitForExistence(timeout: 3),
            "Focusing an empty search field must immediately show the Docsets menu. Tree:\n\(app.debugDescription)"
        )
        XCTAssertGreaterThan(
            panelTitle.frame.minY,
            searchField.frame.maxY,
            "The structured search panel must open below the search field, matching the Dash interaction."
        )
        XCTAssertEqual(searchField.value as? String, "")
    }

    @MainActor
    func testSearchFieldReopensItsPanelAfterAnOutsideClickResignsFocus() throws {
        let app = launchApp()
        let searchField = app.searchFields.firstMatch
        let welcomeTitle = app.staticTexts["welcome-title"]
        let panelTitle = app.staticTexts["search-panel-title"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5))

        for _ in 0..<2 {
            searchField.click()
            XCTAssertTrue(
                panelTitle.waitForExistence(timeout: 3),
                "Every explicit search-field click must present the structured menu."
            )

            welcomeTitle.click()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: panelTitle
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [dismissed], timeout: 3),
                .completed,
                "Clicking elsewhere in the app must dismiss the menu and release search focus."
            )
        }
    }

    @MainActor
    func testClickingSearchTextMovesTheCaretAndPresentsThePanel() throws {
        let app = launchApp()
        let searchField = app.searchFields.firstMatch
        let panelTitle = app.staticTexts["search-panel-title"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        let query = "mmmmmmmmmmmm"
        searchField.typeText(query)
        XCTAssertTrue(panelTitle.waitForExistence(timeout: 3))

        // Click inside the text, well away from the search and clear buttons.
        let textPosition = searchField.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 60, dy: searchField.frame.height / 2))
        textPosition.click()
        XCTAssertTrue(panelTitle.waitForExistence(timeout: 3))
        searchField.typeText("X")
        let edited = try XCTUnwrap(searchField.value as? String)
        XCTAssertEqual(edited.replacingOccurrences(of: "X", with: ""), query)
        XCTAssertFalse(edited.hasPrefix("X"), "Clicking text must place the caret inside the query.")
        XCTAssertFalse(edited.hasSuffix("X"), "Opening the panel must not leave the caret at the end.")

        app.staticTexts["welcome-title"].click()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: panelTitle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
        textPosition.click()
        XCTAssertTrue(panelTitle.waitForExistence(timeout: 3))
        searchField.typeText("Y")
        let reopened = try XCTUnwrap(searchField.value as? String)
        XCTAssertEqual(reopened.replacingOccurrences(of: "Y", with: ""), edited)
        XCTAssertFalse(reopened.hasPrefix("Y"))
        XCTAssertFalse(reopened.hasSuffix("Y"))
    }

    @MainActor
    func testTypingInSearchPresentsTheDashStyleSuggestionMenu() throws {
        let app = launchApp()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.click()
        searchField.typeText("equals")

        let panelTitle = app.staticTexts["search-panel-title"]
        XCTAssertTrue(
            panelTitle.waitForExistence(timeout: 5),
            "Typing must present the structured search menu below the search field. Tree:\n\(app.debugDescription)"
        )
        XCTAssertEqual(searchField.value as? String, "equals")
    }

    @MainActor
    func testViewMenuDoesNotExposeSystemWindowTabbing() throws {
        let app = launchApp()
        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()

        XCTAssertFalse(viewMenu.menus.menuItems["Show Tab Bar"].exists)
        XCTAssertFalse(viewMenu.menus.menuItems["Show All Tabs"].exists)
    }

    @MainActor
    func testWelcomeActionsOpenTheRequestedDocsetsSettingsSection() throws {
        let app = launchApp()
        let download = app.buttons["Download Docsets"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.click()

        let settings = settingsWindow(in: app)
        XCTAssertTrue(
            settings.waitForExistence(timeout: 5),
            "Expected Settings after the Welcome action. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            settings.groups["settings-root"].waitForExistence(timeout: 5),
            "Settings must keep one stable root instead of switching to a separate Docsets page."
        )
        XCTAssertTrue(
            settings.groups["settings-navigation"].exists,
            "General, Docsets, and Privacy must share one persistent settings navigation row."
        )
        XCTAssertTrue(
            settings.radioButtons["Available"].waitForExistence(timeout: 5),
            "Expected the Available subsection. Tree:\n\(settings.debugDescription)"
        )
        XCTAssertEqual(settings.radioButtons["Available"].value as? Int, 1)
        XCTAssertTrue(
            settings.groups["docsets-action-bar"].buttons["Import Docset…"].exists,
            "Expected a visible Import title in the unified Docsets action row. Tree:\n\(settings.debugDescription)"
        )
        XCTAssertTrue(settings.groups["available-action-bar"].buttons["Refresh Catalog"].exists)
        XCTAssertTrue(settings.groups["available-action-bar"].buttons["Download"].exists)
        XCTAssertFalse(settings.toolbars.buttons["Import Docset…"].exists)
        XCTAssertFalse(settings.toolbars.buttons["Refresh Catalog"].exists)
        XCTAssertFalse(settings.toolbars.buttons["Download"].exists)
    }

    @MainActor
    func testSettingsUsesThreePersistentCardButtonsForPrimarySections() throws {
        let app = launchApp()
        app.buttons["Manage Docsets"].click()

        let settings = settingsWindow(in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Expected Settings window.")

        let general = settings.buttons["settings-navigation-general"]
        let docsets = settings.buttons["settings-navigation-docsets"]
        let privacy = settings.buttons["settings-navigation-privacy"]

        for button in [general, docsets, privacy] {
            XCTAssertTrue(
                button.waitForExistence(timeout: 5),
                "Every primary Settings section must use its own persistent icon card. Tree:\n\(settings.debugDescription)"
            )
            XCTAssertGreaterThanOrEqual(button.frame.height, 52)
        }

        XCTAssertEqual(general.frame.size, docsets.frame.size)
        XCTAssertEqual(docsets.frame.size, privacy.frame.size)
        XCTAssertTrue(docsets.isSelected)

        general.click()
        XCTAssertTrue(general.isSelected)
        XCTAssertTrue(settings.staticTexts["Docset folder"].waitForExistence(timeout: 3))

        privacy.click()
        XCTAssertTrue(privacy.isSelected)
        XCTAssertTrue(
            settings.staticTexts["Remote Resources"].waitForExistence(timeout: 3),
            "Expected Privacy content after selecting its card. Tree:\n\(settings.debugDescription)"
        )
    }

    @MainActor
    func testFileMenuContainsOnlyWorkspaceCommandsFromTheRemovedLibraryEntries() throws {
        let app = launchApp()
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()

        XCTAssertTrue(fileMenu.menus.menuItems["New Tab"].exists)
        XCTAssertTrue(fileMenu.menus.menuItems["Close Tab"].exists)
        XCTAssertFalse(fileMenu.menus.menuItems["Library"].exists)
        XCTAssertFalse(fileMenu.menus.menuItems["Import Docset…"].exists)
        XCTAssertFalse(fileMenu.menus.menuItems["Check for Updates"].exists)
        XCTAssertFalse(fileMenu.menus.menuItems["Refresh Library"].exists)
    }

    @MainActor
    func testInstalledSettingsHasUpdateAndDeleteActionsButNoFullTextToggle() throws {
        let app = launchApp()
        app.buttons["Manage Docsets"].click()

        let settings = settingsWindow(in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Expected Settings window.")
        let installed = settings.radioButtons["Installed"]
        XCTAssertTrue(installed.waitForExistence(timeout: 5), "Expected Installed subsection.")
        select(installed)

        XCTAssertTrue(
            settings.groups["installed-action-bar"].buttons["Check for Updates"].exists,
            "Expected the Installed update-check action with a visible title."
        )
        XCTAssertTrue(
            settings.groups["installed-action-bar"].buttons["Update All"].exists,
            "Expected the Installed update-all action with a visible title."
        )
        XCTAssertTrue(settings.groups["installed-action-bar"].buttons["Refresh Library"].exists)
        XCTAssertFalse(settings.toolbars.buttons["Check for Updates"].exists)
        XCTAssertFalse(settings.toolbars.buttons["Update All"].exists)
        XCTAssertFalse(
            settings.switches["Enable full-text search"].exists,
            "Installed must not expose full-text controls."
        )
        XCTAssertTrue(
            settings.groups["docsets-action-bar"].buttons["Import Docset…"].exists,
            "Expected the Import action in the unified settings content."
        )
    }

    @MainActor
    private func launchApp(doubleClickAction: String = "Maximize") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleActionOnDoubleClick", doubleClickAction,
            "-crux-ui-testing",
        ]
        app.launch()
        waitUntilWorkspaceIsReady(app)
        return app
    }

    @MainActor
    private func waitUntilWorkspaceIsReady(_ app: XCUIApplication) {
        let searchField = app.searchFields.matching(identifier: "reader-search-field").firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 8),
            "The workspace did not finish bootstrapping. Tree:\n\(app.debugDescription)"
        )
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: searchField
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabled], timeout: 5),
            .completed,
            "The workspace remained disabled after bootstrap."
        )
    }

    @MainActor
    private func createAdditionalTabs(_ count: Int, in app: XCUIApplication) {
        guard count > 0 else { return }

        var remaining = count
        if !app.buttons.matching(identifier: "workspace-tab-new").firstMatch.exists {
            app.typeKey("t", modifierFlags: .command)
            remaining -= 1
        }

        let newTab = app.buttons.matching(identifier: "workspace-tab-new").firstMatch
        XCTAssertTrue(
            newTab.waitForExistence(timeout: 5),
            "The custom titlebar must always expose the trailing New Tab action."
        )

        for _ in 0..<remaining {
            XCTAssertTrue(newTab.isHittable)
            newTab.click()
        }
    }

    @MainActor
    private func settingsWindow(in app: XCUIApplication) -> XCUIElement {
        app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    }

    @MainActor
    private func select(_ segment: XCUIElement) {
        segment.click()
        let selected = NSPredicate(format: "value == 1")
        let expectation = XCTNSPredicateExpectation(predicate: selected, object: segment)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    @MainActor
    private func resizeWindowForZoomTest(_ window: XCUIElement) {
        let initialFrame = window.frame
        // AppKit persists the window frame between UI-test launches. Use a
        // deterministic width with enough genuine titlebar whitespace instead
        // of repeatedly shrinking the last test's frame.
        let targetWidth: CGFloat = initialFrame.width >= 950 ? 850 : 1_000
        resizeWindow(window, toWidth: targetWidth)

        let resized = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.framesDiffer(window.frame, initialFrame)
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [resized], timeout: 3),
            .completed,
            "The UI test must begin from a non-zoomed window frame."
        )
    }

    @MainActor
    private func resizeWindow(_ window: XCUIElement, toWidth width: CGFloat) {
        let initialFrame = window.frame
        attemptResizeWindow(
            window,
            to: CGSize(width: width, height: initialFrame.height)
        )

        let resized = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(window.frame.width - width) < 60 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 3), .completed)
    }

    @MainActor
    private func prepareWindowForTitlebarTest(_ window: XCUIElement, in app: XCUIApplication) {
        // A restored window can be on a display above the primary display.
        // XCTest cannot reliably click those negative global coordinates.
        // Move it using the native menu, then leave room for edge resizing.
        if window.frame.minY < 0, let primary = NSScreen.screens.first {
            app.menuBars.menuBarItems["Window"].click()
            let move = app.menuItems["Move to \(primary.localizedName)"]
            XCTAssertTrue(move.exists)
            move.click()
        }
        attemptResizeWindow(window, to: CGSize(width: 1_000, height: 750))
        let frame = window.frame
        let top = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 200, dy: 14))
        top.press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(
            dx: 100 - frame.minX, dy: 100 - frame.minY
        )))
    }

    @MainActor
    private func attemptResizeWindow(_ window: XCUIElement, to size: CGSize) {
        let initialFrame = window.frame
        let resizeHandle = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: initialFrame.width - 3, dy: initialFrame.height - 3))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: size.width, dy: size.height))
        resizeHandle.click(forDuration: 0.1, thenDragTo: target)
    }

    private func framesDiffer(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) > 2 || abs(lhs.minY - rhs.minY) > 2
            || abs(lhs.width - rhs.width) > 2 || abs(lhs.height - rhs.height) > 2
    }

}
