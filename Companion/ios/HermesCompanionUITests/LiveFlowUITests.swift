import XCTest

@MainActor
final class LiveFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testFollowUpCompletesWithAppClosedAndRestoresConversation() throws {
        try followUp(appClosed: true)
    }

    func testForegroundFollowUpOpensNewResultConversation() throws {
        try followUp(appClosed: false)
    }

    func testRealChatClearsAcceptedDraft() throws {
        guard ProcessInfo.processInfo.environment["COMPANION_TEST_LIVE_FLOW"] == "1" else {
            throw XCTSkip("Requires a paired isolated Hermes host.")
        }
        let app = XCUIApplication()
        app.launch()
        waitUntilReady(app)
        app.buttons["sessions"].tap()
        app.buttons["newConversation"].tap()
        waitUntilReady(app)
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.tap()
        composer.typeText("Reply with exactly COMPANION_ACCEPTED_OK. Do not use tools.")
        app.buttons["sendMessage"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Hermes. COMPANION_ACCEPTED_OK")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 90))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse((composer.value as? String ?? "").contains("Reply with exactly"))
        XCTAssertFalse(app.staticTexts["Delivery is uncertain"].exists)
        capture(app, "real-chat-accepted")
    }

    private func followUp(appClosed: Bool) throws {
        guard ProcessInfo.processInfo.environment["COMPANION_TEST_LIVE_FLOW"] == "1" else {
            throw XCTSkip("Requires a paired isolated Hermes host and an owned task cleanup check.")
        }
        let app = XCUIApplication()
        app.launch()
        waitUntilReady(app)
        app.buttons["sessions"].tap()
        app.buttons["newConversation"].tap()
        waitUntilReady(app)
        app.buttons["chatMenu"].tap()
        app.buttons["Model & reasoning"].tap()
        XCTAssertTrue(app.staticTexts["effectiveModel"].waitForExistence(timeout: 10))
        let originalModel = app.staticTexts["effectiveModel"].label
        XCTAssertFalse(originalModel.contains("fixture"))
        if !appClosed, let alternate = ProcessInfo.processInfo.environment["COMPANION_TEST_ALTERNATE_MODEL"],
           let provider = ProcessInfo.processInfo.environment["COMPANION_TEST_MODEL_PROVIDER"] {
            XCTAssertTrue(originalModel.hasPrefix("Model, "))
            for model in [alternate, String(originalModel.dropFirst("Model, ".count))] {
                app.buttons["chooseModel"].tap()
                let search = app.searchFields.firstMatch
                search.tap()
                search.typeText(model)
                app.buttons["model-" + provider + ":" + model].tap()
                let effective = NSPredicate(format: "label == %@", "Model, " + model)
                expectation(for: effective, evaluatedWith: app.staticTexts["effectiveModel"])
                waitForExpectations(timeout: 30)
                XCTAssertFalse(app.alerts.firstMatch.exists)
                XCTAssertFalse(app.searchFields.firstMatch.exists)
            }
        }
        app.buttons["reasoningPicker"].tap()
        app.buttons["reasoning-low"].tap()
        let changed = NSPredicate(format: "label == %@", "Reasoning, low")
        expectation(for: changed, evaluatedWith: app.staticTexts["effectiveReasoning"])
        waitForExpectations(timeout: 20)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture(app, "real-effective-controls")
        app.buttons["Done"].tap()
        app.buttons["chatMenu"].tap()
        app.buttons["Follow-ups & updates"].tap()
        app.buttons["newFollowUp"].tap()
        let name = "Native verification " + UUID().uuidString.prefix(8)
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText(String(name))
        let instruction = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@", "What to watch, what matters, and when to tell you")).firstMatch
        instruction.tap()
        instruction.typeText("Reply with exactly COMPANION_NATIVE_FOLLOWUP_OK. Do not use any tools.")
        let schedule = app.textFields["Schedule"]
        schedule.tap()
        if let value = schedule.value as? String { schedule.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        schedule.typeText(ISO8601DateFormatter().string(from: Date().addingTimeInterval(30)))
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[String(name)].waitForExistence(timeout: 20))
        capture(app, "real-follow-up-created")
        let receipt = XCTAttachment(string: "Owned isolated job name: \(name). Scheduled through the native form. App closed during execution: \(appClosed).")
        receipt.name = "owned-native-follow-up"
        receipt.lifetime = .keepAlways
        add(receipt)
        if appClosed {
            app.terminate()
            try waitForCompletedHostResult(String(name), app: app)
            app.launch()
            waitUntilReady(app)
            app.buttons["chatMenu"].tap()
            app.buttons["Follow-ups & updates"].tap()
        }
        app.segmentedControls["activitySection"].buttons["Updates"].tap()
        let result = app.buttons.containing(.staticText, identifier: String(name)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 120))
        result.tap()
        XCTAssertTrue(app.staticTexts["COMPANION_NATIVE_FOLLOWUP_OK"].waitForExistence(timeout: 20))
        capture(app, "real-proactive-result")
        app.buttons["Open conversation"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Hermes. COMPANION_NATIVE_FOLLOWUP_OK")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.tap()
        composer.typeText("A private draft stays with this conversation")
        app.terminate()
        app.launch()
        waitUntilReady(app)
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "A private draft stays with this conversation")
        capture(app, "real-relaunch-restored")
    }

    func testInjectedNotificationOpensCanonicalResult() throws {
        guard ProcessInfo.processInfo.environment["COMPANION_TEST_PUSH"] == "1" else {
            throw XCTSkip("Requires a paired host and an externally injected simulator notification for a real update.")
        }
        let app = XCUIApplication()
        app.launch()
        waitUntilReady(app)
        app.buttons["chatMenu"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Enable iPhone notifications"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.buttons["Allow"].waitForExistence(timeout: 3) { springboard.alerts.buttons["Allow"].tap() }
        app.buttons["Cancel"].tap()
        XCUIDevice.shared.press(.home)
        try openInjectedPush("COMPANION_PUSH_CHECK", springboard: springboard)
        XCTAssertTrue(app.staticTexts["COMPANION_NATIVE_FOLLOWUP_OK"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["answer-allow"].exists)
        capture(app, "injected-push-result")
        if let secondTitle = ProcessInfo.processInfo.environment["COMPANION_TEST_PUSH_SECOND_TITLE"] {
            try openInjectedPush("COMPANION_PUSH_SECOND", springboard: springboard)
            XCTAssertTrue(app.staticTexts[secondTitle].waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts["COMPANION_NATIVE_FOLLOWUP_OK"].exists)
            capture(app, "second-push-while-activity-open")
            try openInjectedPush("COMPANION_PUSH_STALE", springboard: springboard)
            XCTAssertTrue(app.staticTexts["Result unavailable"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.buttons["Open conversation"].exists)
            XCTAssertFalse(app.buttons["answer-allow"].exists)
            capture(app, "stale-push-read-only")
        }
    }

    private func openInjectedPush(_ marker: String, springboard: XCUIApplication) throws {
        let title = marker + (ProcessInfo.processInfo.environment["COMPANION_TEST_PUSH_SUFFIX"] ?? "")
        XCTContext.runActivity(named: "Await " + title) { _ in }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.01))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8)))
        let notification = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        let arrived = notification.waitForExistence(timeout: 60)
        if !arrived {
            let hierarchy = XCTAttachment(string: springboard.debugDescription)
            hierarchy.name = "notification-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(arrived)
        notification.tap()
        if notification.exists && notification.isHittable {
            let hierarchy = XCTAttachment(string: springboard.debugDescription)
            hierarchy.name = "expanded-notification-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let open = notification.buttons["Open"]
            XCTAssertTrue(open.waitForExistence(timeout: 3))
            open.tap()
        }
    }

    private func waitUntilReady(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["sessions"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["companion-beta-test"].exists)
        let ready = NSPredicate(format: "label == %@", "Ready")
        expectation(for: ready, evaluatedWith: app.staticTexts["agentStatus"])
        waitForExpectations(timeout: 30)
        XCTAssertFalse(app.staticTexts["fixtureBanner"].exists)
    }

    private func waitForCompletedHostResult(_ title: String, app: XCUIApplication) throws {
        let environment = ProcessInfo.processInfo.environment
        let base = try XCTUnwrap(environment["COMPANION_TEST_READBACK_URL"])
        let token = try XCTUnwrap(environment["COMPANION_TEST_READBACK_TOKEN"])
        XCTAssertEqual(app.state, .notRunning)
        let completed = expectation(description: "Independent test observer reads the canonical result while the app is terminated")
        let observer = Task { @MainActor in
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline && !Task.isCancelled {
                var request = URLRequest(url: URL(string: base + "/v1/updates")!)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let updates = object["updates"] as? [[String: Any]],
                   let update = updates.first(where: { $0["title"] as? String == title }),
                   let id = update["id"] as? String {
                    request.url = URL(string: base + "/v1/updates/" + id)
                    if let (detail, response) = try? await URLSession.shared.data(for: request),
                       (response as? HTTPURLResponse)?.statusCode == 200,
                       let object = try? JSONSerialization.jsonObject(with: detail) as? [String: Any],
                       object["text"] as? String == "COMPANION_NATIVE_FOLLOWUP_OK" {
                        completed.fulfill()
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { observer.cancel() }
        waitForExpectations(timeout: 185)
        XCTAssertEqual(app.state, .notRunning)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
