import XCTest

/// Focused UI tests for the remote browser workspace, driven through the
/// BrowserLab fixture. The fixture auto-grants control and acknowledges
/// commands, so these tests exercise the real state machine end to end.
final class BrowserLabUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @discardableResult
    private func revealPanelElement(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let panel = app.scrollViews["lab.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), file: file, line: line)

        // Tests can leave the independently scrolling lab panel at either end.
        // Search in both directions so later controls and readback values remain
        // reachable without relying on a particular simulator viewport height.
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                return element
            }
            panel.swipeUp()
        }
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                return element
            }
            panel.swipeDown()
        }

        XCTFail("panel element is not hittable: \(element)", file: file, line: line)
        return element
    }

    private func tapPanelElement(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        revealPanelElement(element, file: file, line: line).tap()
    }

    private func waitForLabel(
        _ element: XCUIElement,
        toEqual expected: String,
        timeout: TimeInterval = 10
    ) {
        let predicate = NSPredicate(format: "label == %@", expected)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    /// The simulated-session banner is always visible.
    func testSimulatedSessionBannerIsAlwaysVisible() {
        XCTAssertTrue(app.staticTexts["lab.banner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["lab.banner"].label.contains("SIMULATED"))
    }

    /// Connect -> watch -> take control -> manual with remote input enabled.
    func testTakeControlFlow() {
        app.buttons["lab.connect"].tap()

        let status = app.staticTexts["browser.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))

        let takeControl = app.buttons["browser.takeControl"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()

        let inControl = NSPredicate(format: "label CONTAINS 'in control'")
        expectation(for: inControl, evaluatedWith: status, handler: nil)
        waitForExpectations(timeout: 10)

        // Manual footer controls appear only with control held.
        XCTAssertTrue(app.buttons["browser.keyboard"].exists)
        XCTAssertTrue(app.buttons["browser.fit"].exists)
    }

    /// Keyboard draft: type locally, Insert sends committed text exactly
    /// once, and the draft clears after the fixture acknowledges.
    func testKeyboardDraftInsert() {
        app.buttons["lab.connect"].tap()
        let takeControl = app.buttons["browser.takeControl"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()

        let status = app.staticTexts["browser.status"]
        let inControl = NSPredicate(format: "label CONTAINS 'in control'")
        expectation(for: inControl, evaluatedWith: status, handler: nil)
        waitForExpectations(timeout: 10)

        app.buttons["browser.keyboard"].tap()
        let editor = app.textViews["browser.draftEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let expectedText = "Hello café 👨‍👩‍👧‍👦"
        editor.typeText(expectedText)

        // Insert via the keyboard toolbar when the software keyboard is up,
        // otherwise via the sheet's Insert button.
        let keyboardInsert = app.buttons["browser.insertTextKeyboard"]
        if keyboardInsert.waitForExistence(timeout: 3) {
            keyboardInsert.tap()
        } else {
            app.buttons["browser.insertText"].tap()
        }

        // The fixture acknowledges; the draft clears after confirmation.
        // Poll the value: an empty text view reports "" or nil.
        let deadline = Date().addingTimeInterval(10)
        var draftValue: String? = "unset"
        while Date() < deadline {
            draftValue = editor.value as? String
            if draftValue == nil || draftValue == "" { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(
            draftValue == nil || draftValue == "",
            "draft was not cleared after acknowledgement (value: \(draftValue ?? "nil"))"
        )

        app.buttons["Done"].tap()

        let insertedText = revealPanelElement(app.staticTexts["lab.lastInsertedText"])
        waitForLabel(insertedText, toEqual: expectedText)
        let insertCount = revealPanelElement(app.staticTexts["lab.insertedTextCount"])
        waitForLabel(insertCount, toEqual: "1")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(insertCount.label, "1", "fixture must accept the Unicode insertion exactly once")
    }

    func testLostTextAcknowledgementCannotDuplicateOrClearDraft() {
        app.buttons["lab.connect"].tap()
        let takeControl = app.buttons["browser.takeControl"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        XCTAssertTrue(app.buttons["browser.keyboard"].waitForExistence(timeout: 10))

        tapPanelElement(app.buttons["lab.loseNextAck"])
        app.buttons["browser.keyboard"].tap()
        let editor = app.textViews["browser.draftEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let expectedText = "Hello café 👨‍👩‍👧‍👦"
        editor.tap()
        editor.typeText(expectedText)
        let insertButton = app.buttons["browser.insertTextKeyboard"]
        if insertButton.waitForExistence(timeout: 3) {
            insertButton.tap()
        } else {
            app.buttons["browser.insertText"].tap()
        }

        let unconfirmed = app.staticTexts["browser.draftStatus"]
        XCTAssertTrue(unconfirmed.waitForExistence(timeout: 10))
        XCTAssertTrue(unconfirmed.label.contains("Delivery unconfirmed"))
        XCTAssertEqual(editor.value as? String, expectedText)

        // A second press cannot resend an ambiguous commit.
        if insertButton.exists {
            insertButton.tap()
        } else {
            app.buttons["browser.insertText"].tap()
        }
        app.buttons["Done"].tap()
        let insertCount = revealPanelElement(app.staticTexts["lab.insertedTextCount"])
        waitForLabel(insertCount, toEqual: "1")
        let insertedText = revealPanelElement(app.staticTexts["lab.lastInsertedText"])
        waitForLabel(insertedText, toEqual: expectedText)
    }

    func testReadOnlyAndResumeUnknownStatesAreReachable() {
        app.buttons["lab.connect"].tap()
        let status = app.staticTexts["browser.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))

        let controlSupported = app.switches["lab.controlSupported"]
        tapPanelElement(controlSupported)
        XCTAssertEqual(controlSupported.value as? String, "0")
        let readOnly = NSPredicate(format: "label CONTAINS 'Read-only'")
        expectation(for: readOnly, evaluatedWith: status, handler: nil)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["browser.takeControl"].exists)

        tapPanelElement(controlSupported)
        XCTAssertEqual(controlSupported.value as? String, "1")
        let takeControl = app.buttons["browser.takeControl"]
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        takeControl.tap()
        XCTAssertTrue(app.buttons["browser.resume"].waitForExistence(timeout: 10))

        tapPanelElement(app.buttons["lab.loseNextAck"])
        app.buttons["browser.resume"].tap()
        let unknown = NSPredicate(format: "label CONTAINS 'Resume status unknown'")
        expectation(for: unknown, evaluatedWith: status, handler: nil)
        waitForExpectations(timeout: 10)

        tapPanelElement(app.buttons["lab.freshObservation"])
        let watching = NSPredicate(format: "label CONTAINS 'Watching Hermes'")
        expectation(for: watching, evaluatedWith: status, handler: nil)
        waitForExpectations(timeout: 10)
    }

    /// Disconnecting shields the last frame as stale.
    func testStaleFrameShieldOnDisconnect() {
        app.buttons["lab.connect"].tap()
        XCTAssertTrue(app.staticTexts["browser.status"].waitForExistence(timeout: 10))

        tapPanelElement(app.buttons["lab.frames"])
        // Let a couple of synthetic frames arrive.
        sleep(2)

        app.buttons["lab.disconnect"].tap()
        XCTAssertTrue(
            app.staticTexts["browser.staleFrameShield"].waitForExistence(timeout: 10)
        )
    }
}
