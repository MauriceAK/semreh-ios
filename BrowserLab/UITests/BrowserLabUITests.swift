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
        editor.typeText("hello lab")

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

        // Readback shows the accepted insertText command.
        let lastCommand = app.staticTexts["lab.lastCommand"]
        XCTAssertTrue(lastCommand.waitForExistence(timeout: 5))
        let sawInsert = NSPredicate(format: "label CONTAINS 'insertText'")
        expectation(for: sawInsert, evaluatedWith: lastCommand, handler: nil)
        waitForExpectations(timeout: 10)
    }

    /// Disconnecting shields the last frame as stale.
    func testStaleFrameShieldOnDisconnect() {
        app.buttons["lab.connect"].tap()
        XCTAssertTrue(app.staticTexts["browser.status"].waitForExistence(timeout: 10))

        app.buttons["lab.frames"].tap()
        // Let a couple of synthetic frames arrive.
        sleep(2)

        app.buttons["lab.disconnect"].tap()
        XCTAssertTrue(
            app.staticTexts["Frame may be stale"].waitForExistence(timeout: 10)
        )
    }
}
