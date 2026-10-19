import CoreFoundation
import XCTest

@MainActor
final class PerformanceFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRealHistoryDiagnosticWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let session = environment["COMPANION_TEST_HISTORY_SESSION"],
              let label = environment["COMPANION_TEST_PERFORMANCE_LABEL"] else {
            throw XCTSkip("Requires a paired isolated scrollable history session and unique diagnostic label.")
        }
        let controlID = UUID().uuidString
        let app = launch(session: session, label: label, controlID: controlID)
        let table = app.tables["transcript"]
        let rowCount = table.cells.count
        XCTAssertGreaterThanOrEqual(rowCount, 20, "The short control must be scrollable; two rows cannot exercise Latest.")
        XCTAssertLessThanOrEqual(rowCount, 500)
        let newest = table.cells.element(boundBy: rowCount - 1).textViews.firstMatch.identifier
        XCTAssertTrue(newest.hasPrefix("message-"))
        XCTAssertLessThanOrEqual(app.textViews[newest].frame.maxY, table.frame.maxY, "Initial layout must expose the true canonical tail.")
        replaceDraft(app, with: "Typing a real draft while reading older messages")
        table.swipeDown(velocity: .slow)
        table.swipeDown(velocity: .fast)
        XCTAssertEqual(editor(app).value as? String, "Typing a real draft while reading older messages")
        let latest = app.buttons["latestMessages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "Both comparison sides must perform Latest navigation.")
        XCTAssertTrue(latest.isHittable)
        latest.tap()
        let returned = NSPredicate(format: "exists == false")
        expectation(for: returned, evaluatedWith: latest)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.textViews[newest].isHittable, "Latest must return to the actual newest canonical row.")
        XCTAssertLessThanOrEqual(app.textViews[newest].frame.maxY, table.frame.maxY, "Latest must expose the complete canonical tail.")
        editor(app).tap()
        editor(app).typeText(" and returning to the latest")
        XCTAssertEqual(editor(app).value as? String, "Typing a real draft while reading older messages and returning to the latest")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture(app, name: "real-history-diagnostic")
        attachScope("Real gateway history workload. Initial loaded rows=\(rowCount). Typed draft preserved; two scroll gestures; required Latest returned to initial canonical tail. Local timings exclude XCTest duration. Label=\(label).")
        finishCapture(controlID: controlID)
    }

    func testRealStreamingWhileTypingWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let session = environment["COMPANION_TEST_STREAM_SESSION"],
              let label = environment["COMPANION_TEST_PERFORMANCE_LABEL"] else {
            throw XCTSkip("Requires a paired isolated stream session and unique diagnostic label; sends one real Hermes prompt.")
        }
        let controlID = UUID().uuidString
        let app = launch(session: session, label: label, controlID: controlID)
        let marker = "PERF_COMPLETE_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        let prompt = "Controlled interface timing check. Do not use tools. Write exactly 50 numbered lines about everyday organization. Each line must contain 18 to 24 words. Write the full list, with no introduction. Finish with \(marker) on a separate line."
        replaceDraft(app, with: prompt)
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["workingIndicator"].waitForExistence(timeout: 10))
        let partial = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Hermes. ")).firstMatch
        XCTAssertTrue(partial.waitForExistence(timeout: 120), "Wait for actual streamed content before concurrent typing.")
        XCTAssertTrue(app.staticTexts["workingIndicator"].exists)
        let draft = "Keep this unsent draft responsive while the assistant streams its answer."
        editor(app).tap()
        editor(app).typeText(draft)
        XCTAssertEqual(editor(app).value as? String, draft)
        let answer = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Hermes. ", String(marker))).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 180), "The real assistant must complete its unique response marker.")
        waitUntilReady(app, timeout: 30)
        XCTAssertEqual(editor(app).value as? String, draft)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "uncertainAction").firstMatch.exists)
        capture(app, name: "real-stream-typing-diagnostic")
        attachScope("One real Hermes prompt requested 50 numbered lines and terminal marker \(marker). An unsent draft remained intact through completion. Concurrent overlap must additionally pass the stream-typing JSON evaluator; these UI assertions alone do not prove overlap or frame rate. Label=\(label).")
        finishCapture(controlID: controlID)
    }

    private func launch(session: String, label: String, controlID: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--session", session, "--chat-performance", "--chat-performance-label", label,
                               "--chat-performance-control", controlID]
        app.launch()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["fixtureBanner"].exists)
        waitUntilReady(app, timeout: 30)
        return app
    }

    private func waitUntilReady(_ app: XCUIApplication, timeout: TimeInterval) {
        expectation(for: NSPredicate(format: "label == %@", "Ready"), evaluatedWith: app.staticTexts["agentStatus"])
        waitForExpectations(timeout: timeout)
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }

    private func replaceDraft(_ app: XCUIApplication, with text: String) {
        let field = editor(app)
        field.tap()
        if let existing = field.value as? String, existing != field.placeholderValue, !existing.isEmpty {
            field.press(forDuration: 1.1)
            let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3), "Use the native editing menu to replace the complete saved draft.")
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    private func finishCapture(controlID: String) {
        let exported = expectation(description: "Diagnostic export acknowledged")
        let observer = Unmanaged.passUnretained(exported).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let exportedName = "org.hermescompanion.performance.exported." + controlID
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<XCTestExpectation>.fromOpaque(observer).takeUnretainedValue().fulfill()
        }, exportedName as CFString, nil, .deliverImmediately)
        defer {
            CFNotificationCenterRemoveObserver(center, observer,
                CFNotificationName(rawValue: exportedName as CFString), nil)
        }
        CFNotificationCenterPostNotification(center,
            CFNotificationName(rawValue: ("org.hermescompanion.performance.finish." + controlID) as CFString),
            nil, nil, true)
        wait(for: [exported], timeout: 10)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScope(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "performance-workload-scope"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
