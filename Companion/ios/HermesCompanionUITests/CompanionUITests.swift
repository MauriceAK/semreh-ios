import XCTest
import Vision

@MainActor
final class CompanionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["fixtureBanner"].waitForExistence(timeout: 10))
        return app
    }
    func testLongHistoryTypingAndStreaming() {
        let app = launch()
        let transcript = app.tables["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.tap()
        composer.typeText("Explore a useful idea")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["stopAgent"].waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Keep the draft while I read")
        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        XCTAssertEqual(composer.value as? String, "Keep the draft while I read")
        app.buttons["stopAgent"].tap()
        XCTAssertTrue(app.buttons["sendMessage"].exists)
        attach(app, "long-history-keyboard")
    }
    func testControlsReadBackAndQuietHours() {
        let app = launch()
        app.buttons["chatMenu"].tap()
        app.buttons["Model & reasoning"].tap()
        app.buttons["reasoningPicker"].tap()
        app.buttons["reasoning-high"].tap()
        XCTAssertEqual(app.staticTexts["effectiveReasoning"].label, "Reasoning, high")
        app.buttons["chooseModel"].tap()
        app.buttons["model-fixture:fixture-other"].tap()
        XCTAssertEqual(app.staticTexts["effectiveModel"].label, "Model, fixture-other")
        app.buttons["Done"].tap()
        app.buttons["chatMenu"].tap()
        app.buttons["Settings"].tap()
        let quiet = app.switches["quietHours"]
        quiet.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(quiet.value as? String, "1")
        XCTAssertTrue(app.datePickers["quietStart"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["savePreferences"].isHittable)
        attach(app, "quiet-hours")
        app.buttons["savePreferences"].tap()
        app.buttons["chatMenu"].tap()
        app.buttons["Settings"].tap()
        XCTAssertEqual(app.switches["quietHours"].value as? String, "1")
        XCTAssertTrue(app.datePickers["quietStart"].exists)
        if !app.datePickers["quietEnd"].exists { app.swipeUp() }
        XCTAssertTrue(app.datePickers["quietEnd"].exists)
    }
    func testApprovalResolvesAndCannotBeAnsweredTwice() {
        let app = launch(["--fixture-approval"])
        XCTAssertTrue(app.buttons["answer-deny"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["answer-deny"].isHittable)
        XCTAssertTrue(app.buttons["answer-allow"].isHittable)
        attach(app, "approval")
        app.buttons["answer-deny"].tap()
        XCTAssertFalse(app.buttons["answer-deny"].exists)
        XCTAssertTrue(app.staticTexts["Fixture request resolved."].exists)
    }
    func testOlderPagePreservesVisibleMessage() {
        let app = launch(["--fixture-top"])
        let anchor = app.textViews["message-fixture-9880"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        let frame = anchor.frame
        app.buttons["loadOlder"].tap()
        XCTAssertTrue(anchor.exists)
        XCTAssertEqual(anchor.frame.minY, frame.minY, accuracy: 3)
        XCTAssertTrue(app.buttons["latestMessages"].exists)
        attach(app, "older-history-anchor")
        app.buttons["latestMessages"].tap()
        XCTAssertTrue(app.textViews["message-fixture-9999"].isHittable)
    }
    func testLongCodePreservesNewlinesAndEnd() throws {
        let app = launch(["--fixture-long-code"])
        let code = app.textViews["message-fixture-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertTrue((code.value as? String ?? "").contains("let line200 = 200"))
        XCTAssertTrue((code.value as? String ?? "").contains("Code ends here."))
        XCTAssertTrue((code.value as? String ?? "").contains("let line1 = 1 // a readable source line\nlet line2 = 2"))
        attach(app, "long-code-bottom")
        XCTAssertTrue(try visibleText(app).contains("Code ends here."))
        for _ in 0..<12 { app.tables["transcript"].swipeDown(velocity: .fast) }
        attach(app, "long-code-top")
        XCTAssertTrue(try visibleText(app).contains("A code example."))
        app.buttons["latestMessages"].tap()
        attach(app, "long-code-returned-bottom")
        XCTAssertTrue(try visibleText(app).contains("Code ends here."))
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.tap()
        composer.typeText("Keep this draft")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        composer.typeText(" while reading")
        XCTAssertEqual(composer.value as? String, "Keep this draft while reading")
    }
    func testRemoteCancellationRemovesActionableRequest() {
        let app = launch(["--fixture-approval", "--fixture-cancel-request"])
        XCTAssertTrue(app.buttons["answer-deny"].waitForExistence(timeout: 3))
        let absent = NSPredicate(format: "exists == false")
        expectation(for: absent, evaluatedWith: app.buttons["answer-deny"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Fixture request canceled on the host."].exists)
        attach(app, "request-canceled")
    }
    func testReconnectPreservesDraftAndDoesNotRepeatSend() {
        let app = launch(["--fixture-reconnect"])
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.tap()
        composer.typeText("A draft survives")
        XCTAssertTrue(app.staticTexts["Reconnecting. Your draft stays here."].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        XCTAssertTrue(app.staticTexts["Fixture connection restored. No command was replayed."].waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "A draft survives")
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
        attach(app, "recovered-draft")
    }
    func testFiveLongHistoryLaunchMeasurements() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        let app = XCUIApplication()
        measure(metrics: [XCTClockMetric()], options: options) {
            app.launchArguments = ["--fixture"]
            app.launch()
            XCTAssertTrue(app.staticTexts["fixtureBanner"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.tables["transcript"].exists)
            app.terminate()
        }
    }
    func testHostWithoutPushReportsSetupRequirement() {
        let app = launch(["--fixture-no-push"])
        app.buttons["chatMenu"].tap()
        app.buttons["Settings"].tap()
        XCTAssertEqual(app.staticTexts["hostAlertsUnavailable"].label, "Phone alerts need setup on your Hermes host. In-app updates are available.")
        attach(app, "host-alerts-setup")
    }
    func testRealHistoryWorkloadWhenSessionProvided() throws {
        guard let sessionID = ProcessInfo.processInfo.environment["COMPANION_TEST_HISTORY_SESSION"] else {
            throw XCTSkip("Provide a paired isolated history session for the real workload.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--session", sessionID]
        let started = Date()
        app.launch()
        XCTAssertTrue(app.tables["transcript"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["fixtureBanner"].exists)
        let ready = NSPredicate(format: "label == %@", "Ready")
        expectation(for: ready, evaluatedWith: app.staticTexts["agentStatus"])
        waitForExpectations(timeout: 30)
        let openSeconds = Date().timeIntervalSince(started)
        let loadedRows = app.tables["transcript"].cells.count
        XCTAssertGreaterThan(loadedRows, 0)
        XCTAssertLessThanOrEqual(loadedRows, 500)
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        var metrics: [any XCTMetric] = [XCTClockMetric(), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics, options: options) {
            let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
            if let text = composer.value as? String, text != composer.placeholderValue {
                composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
            }
            composer.typeText("A draft remains usable while reading")
            app.tables["transcript"].swipeDown(velocity: .fast)
            app.tables["transcript"].swipeDown(velocity: .fast)
            XCTAssertEqual(composer.value as? String, "A draft remains usable while reading")
            composer.tap()
            composer.typeText(" more")
            XCTAssertEqual(composer.value as? String, "A draft remains usable while reading more")
            XCTAssertTrue(app.keyboards.firstMatch.exists)

        }
        let record = XCTAttachment(string: "Automation-observed launch-to-ready seconds=\(openSeconds). Accessible transcript rows=\(loadedRows). One running-process scroll/type trial. Clock includes UI automation settling. App memory excludes launch. No command sent.")
        record.name = "real-history-workload-scope"
        record.lifetime = .keepAlways
        add(record)
        attach(app, "real-history-workload")
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        if let text = composer.value as? String, text != composer.placeholderValue {
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        }
        app.terminate()
    }
    func testPairingAndRealHostWhenInvitationProvided() throws {
        guard let invitation = ProcessInfo.processInfo.environment["COMPANION_TEST_INVITATION"] else { throw XCTSkip("Provide a one-use real host invitation to run real pairing.") }
        let app = XCUIApplication()
        app.launchArguments = ["--invitation", invitation]
        if let sessionID = ProcessInfo.processInfo.environment["COMPANION_TEST_SESSION"] { app.launchArguments += ["--session", sessionID] }
        app.launch()
        XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["fixtureBanner"].exists)
        attach(app, "real-host-paired")
        app.buttons["sessions"].tap()
        app.buttons["newConversation"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.tap()
        composer.typeText("Reply with exactly COMPANION_SIMULATOR_OK. Do not use tools.")
        app.buttons["sendMessage"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Hermes. COMPANION_SIMULATOR_OK")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 90))
        attach(app, "real-host-response")
    }
    private func visibleText(_ app: XCUIApplication) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
