import XCTest

@MainActor
final class ConversationDrawerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture", "--fixture-top"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 10))
        return app
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func assertDrawerOpen(_ app: XCUIApplication) {
        let dismiss = app.buttons["dismissConversations"]
        let search = app.textFields["conversationSearch"]
        let viewport = app.windows.firstMatch.frame
        let expectedLeadingEdge = viewport.minX + min(viewport.width * 0.8, viewport.width - 56)
        let settled = NSPredicate { _, _ in
            dismiss.exists && abs(dismiss.frame.minX - expectedLeadingEdge) <= 1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 3), .completed)
        let searchIsHittable = search.isHittable
        if !searchIsHittable {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "drawer-search-failure-accessibility"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            capture(app, name: "drawer-search-failure")
        }
        XCTAssertTrue(searchIsHittable)
        XCTAssertFalse(editor(app).isHittable, "The covered chat input must not accept touches.")
        XCTAssertFalse(app.tables["transcript"].isHittable, "The covered transcript must not accept touches.")
        XCTAssertFalse(app.buttons["sessions"].isHittable, "The covered chat header must not accept touches.")
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(viewport.maxX - dismiss.frame.minX, 56)
        XCTAssertEqual(dismiss.frame.width, viewport.width, accuracy: 1)
        for identifier in ["drawerSettings", "newConversation"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertLessThanOrEqual(button.frame.maxX, dismiss.frame.minX)
        }
    }

    func testDrawerPreservesDraftReaderWidthAndSelectedSessionWithoutReload() throws {
        let app = launch()
        app.buttons["loadOlder"].tap()
        let table = app.tables["transcript"]
        table.swipeDown(velocity: .fast)
        table.swipeDown(velocity: .fast)
        let readingTop = app.staticTexts["fixtureBanner"].frame.maxY
        let readingBottom = editor(app).frame.minY
        let visibleRows = try table.snapshot().children.filter {
            $0.elementType == .cell && $0.frame.minY > readingTop && $0.frame.maxY < readingBottom
        }
        let earlierRow = visibleRows.flatMap { $0.children }.first {
            guard $0.elementType == .textView, $0.identifier.hasPrefix("message-fixture-"),
                  let number = Int($0.identifier.dropFirst("message-fixture-".count)) else { return false }
            return number < 9880
        }
        let id = try XCTUnwrap(earlierRow?.identifier, "Read a visible row from the loaded earlier page before opening the drawer.")
        let anchor = app.textViews[id]
        XCTAssertTrue(anchor.isHittable)
        let before = anchor.frame
        let width = table.frame.width
        let viewport = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(table.frame.minY, viewport.minY + 1)
        XCTAssertGreaterThanOrEqual(table.frame.maxY, viewport.maxY - 1)
        editor(app).tap()
        editor(app).typeText("Keep this drawer draft")
        app.buttons["sessions"].tap()
        assertDrawerOpen(app)
        capture(app, name: "drawer-open-with-preserved-draft")
        app.buttons["conversation-fixture-history"].tap()
        XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 3))
        XCTAssertEqual(editor(app).value as? String, "Keep this drawer draft")
        let restored = app.textViews[id]
        XCTAssertTrue(restored.exists)
        XCTAssertEqual(restored.frame.minY, before.minY, accuracy: 3)
        XCTAssertEqual(restored.frame.width, before.width, accuracy: 1)
        XCTAssertEqual(table.frame.width, width, accuracy: 1)
        XCTAssertLessThanOrEqual(table.frame.minY, viewport.minY + 1)
        XCTAssertGreaterThanOrEqual(table.frame.maxY, viewport.maxY - 1)
        capture(app, name: "drawer-restored-reader-and-draft")
    }

    func testDrawerSearchAndRealDestinations() {
        let app = launch()
        app.buttons["sessions"].tap()
        assertDrawerOpen(app)
        XCTAssertEqual(app.staticTexts["drawerTabsHeading"].label, "TABS")
        XCTAssertEqual(app.staticTexts["drawerSideChatsHeading"].label, "SIDE CHATS")
        XCTAssertLessThan(app.staticTexts["drawerTabsHeading"].frame.maxY, app.buttons["drawerMainChat"].frame.minY)
        XCTAssertLessThan(app.buttons["drawerControls"].frame.maxY, app.staticTexts["drawerSideChatsHeading"].frame.minY)
        XCTAssertTrue(app.buttons["conversation-fixture-history"].isSelected)
        capture(app, name: "drawer-open")
        let search = app.textFields["conversationSearch"]
        search.tap()
        search.typeText("No matching title")
        XCTAssertTrue(app.staticTexts["drawerEmpty"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["drawerEmpty"].label, "No conversations found")
        XCTAssertTrue(app.buttons["newConversation"].isHittable)
        XCTAssertTrue(app.buttons["drawerSettings"].isHittable)
        XCTAssertLessThanOrEqual(search.frame.maxY, app.keyboards.firstMatch.frame.minY)
        capture(app, name: "drawer-search-keyboard")
        app.buttons["drawerMainChat"].tap()
        XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 3))
        for (destination, title) in [("drawerControls", "Model & reasoning"), ("drawerActivity", "Follow-ups & updates"), ("drawerSettings", "Settings")] {
            app.buttons["sessions"].tap()
            assertDrawerOpen(app)
            XCTAssertTrue(app.buttons[destination].isHittable)
            app.buttons[destination].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            app.buttons[destination == "drawerSettings" ? "Cancel" : "Done"].tap()
            XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 3))
        }
        app.buttons["sessions"].tap()
        assertDrawerOpen(app)
        let dismiss = app.buttons["dismissConversations"]
        let visibleStrip = dismiss.frame.intersection(app.windows.firstMatch.frame)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visibleStrip.midX, dy: visibleStrip.midY)).tap()
        XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 3))
        XCTAssertTrue(editor(app).isHittable)
        capture(app, name: "drawer-search-restored-chat")
    }

    func testDrawerLongListScrollsBehindFixedFooterAndLastConversationRemainsReachable() {
        let app = launch(["--fixture-drawer-sessions"])
        app.buttons["sessions"].tap()
        assertDrawerOpen(app)
        let content = app.scrollViews["drawerContent"]
        let search = app.textFields["conversationSearch"]
        let settings = app.buttons["drawerSettings"]
        let compose = app.buttons["newConversation"]
        let footerFrame = search.frame
        XCTAssertGreaterThan(content.frame.maxY, search.frame.maxY,
                             "The scrolling list must continue underneath the floating footer.")
        XCTAssertTrue(app.buttons["conversation-fixture-drawer-0"].exists)
        capture(app, name: "drawer-long-list-floating-footer")
        let last = app.buttons["conversation-fixture-drawer-23"]
        for _ in 0..<12 {
            if last.exists && last.frame.maxY <= search.frame.minY && last.isHittable { break }
            content.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(last.frame.maxY, search.frame.minY,
                                 "The last conversation must scroll above the footer to remain selectable.")
        XCTAssertEqual(search.frame.minY, footerFrame.minY, accuracy: 1)
        XCTAssertEqual(search.frame.width, footerFrame.width, accuracy: 1)
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(compose.isHittable)
        capture(app, name: "drawer-last-conversation-above-footer")
        search.tap()
        search.typeText("No matching title")
        XCTAssertTrue(app.staticTexts["drawerEmpty"].waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(search.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(compose.isHittable)
        capture(app, name: "drawer-long-list-filtered-with-keyboard")
    }

    func testLargestTextDrawerControlsRemainReachableWithSearchKeyboard() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["sessions"].tap()
        assertDrawerOpen(app)
        let content = app.scrollViews["drawerContent"]
        let controls = app.buttons["drawerControls"]
        for _ in 0..<4 where !controls.isHittable { content.swipeUp() }
        XCTAssertTrue(controls.isHittable)
        controls.tap()
        XCTAssertTrue(app.navigationBars["Model & reasoning"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 3))
        app.buttons["sessions"].tap()
        assertDrawerOpen(app)
        let search = app.textFields["conversationSearch"]
        search.tap()
        search.typeText("No matching title")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["drawerSettings"].isHittable)
        XCTAssertTrue(app.buttons["newConversation"].isHittable)
        XCTAssertLessThanOrEqual(search.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertTrue(app.staticTexts["drawerEmpty"].exists)
        capture(app, name: "drawer-largest-text-search-keyboard")
        app.buttons["drawerSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 3))
        XCTAssertTrue(editor(app).isHittable)
        capture(app, name: "drawer-largest-text-restored-chat")
    }
}
