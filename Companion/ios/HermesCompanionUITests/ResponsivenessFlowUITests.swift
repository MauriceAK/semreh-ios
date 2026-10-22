import CoreFoundation
import XCTest

@MainActor
final class ResponsivenessFlowUITests: XCTestCase {
    private var app: XCUIApplication?
    private var baseURL = ""
    private var token = ""
    private var label = ""
    private var controlID = ""
    private var captureEnabled = true
    private var teardownStarted = false
    private var configuration: [String: Any] = [:]
    private var additionalTrialLabels: [String] = []

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["COMPANION_TEST_RESPONSE"] != nil else {
            throw XCTSkip("Select this workload with COMPANION_TEST_RESPONSE=1 and a private local fixture configuration.")
        }
        XCTAssertEqual(environment["COMPANION_TEST_RESPONSE"], "1")
        baseURL = try XCTUnwrap(environment["COMPANION_TEST_RESPONSE_URL"])
        token = try XCTUnwrap(environment["COMPANION_TEST_RESPONSE_TOKEN"])
        label = try XCTUnwrap(environment["COMPANION_TEST_RESPONSE_LABEL"])
        captureEnabled = environment["COMPANION_TEST_RESPONSE_CAPTURE"] != "0"
        let url = try XCTUnwrap(URLComponents(string: baseURL))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        controlID = UUID().uuidString
    }

    override func tearDown() async throws {
        guard !teardownStarted else { return }
        teardownStarted = true
        guard !configuration.isEmpty else { return }
        defer { app?.terminate() }
        if let app, app.state == .runningForeground {
            capture(app, "response-final-state")
            if captureEnabled { await finishCapture() }
        }
        let report = try await controlAsync("/" + label, body: ["action": "finalize"])
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "response-workload-report.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        for additionalLabel in additionalTrialLabels {
            let report = try await controlAsync("/" + additionalLabel, body: ["action": "finalize"])
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "response-replacement-report.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSendAtLatestWithEarlyAcceptanceAndHeldHTTP() throws {
        try exerciseSend("send-latest")
    }

    func testSendWhileReadingHistoryWithEarlyAcceptanceAndHeldHTTP() throws {
        try exerciseSend("send-reader")
    }

    func testSendDuringExistingWorkWithEarlyAcceptanceAndHeldHTTP() throws {
        try exerciseSend("send-working")
    }

    func testFixedStreamWhileTypingReplacementDraft() throws {
        let app = try launch("stream-typing")
        try submit(app)
        let expectedDraft = try text("draft")
        editor(app).tap()
        let before = try action("stream")
        XCTAssertEqual(count(before, "http_receipts"), 0)
        let started = try waitForReport { self.count($0, "stream_chunks") > 0 }
        XCTAssertLessThan(count(started, "stream_chunks"), number(started, "expected_stream_chunks"))
        editor(app).typeText(expectedDraft)
        XCTAssertEqual(editor(app).value as? String, expectedDraft)
        let typed = try report()
        XCTAssertGreaterThan(count(typed, "stream_chunks"), count(started, "stream_chunks"), "The server must deliver more fixed chunks during actual XCTest typing.")
        XCTAssertLessThan(count(typed, "stream_chunks"), number(typed, "expected_stream_chunks"), "The typing interval must overlap an unfinished stream.")
        // Accessibility polling during the stream can contend with app rendering.
        let completed = try waitForReport { self.count($0, "assistant_completions") == 1 }
        XCTAssertEqual(count(completed, "http_receipts"), 0)
        _ = try action("release-http")
        let answer = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Hermes. ", "RESPONSE_STREAM_COMPLETE")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        waitUntilReady(app)
        XCTAssertEqual(answer.label, "Hermes. " + (try text("answer")))
        XCTAssertEqual(editor(app).value as? String, expectedDraft)
        XCTAssertEqual(count(completed, "stream_chunks"), number(completed, "expected_stream_chunks"))
        XCTAssertEqual(count(completed, "stream_utf8_bytes"), number(completed, "expected_stream_utf8_bytes"))
        assertCanonical(completed, sent: true)
        assertQuiet(app)
        capture(app, "response-stream-with-draft")
    }

    func testBackgroundForegroundKeepsHistoryAndDraftQuietly() throws {
        let app = try launch("foreground")
        let draft = try text("draft")
        editor(app).tap()
        editor(app).typeText(draft)
        let tail = app.textViews["message-" + (try text("tail_id"))]
        XCTAssertTrue(tail.isHittable)
        let initial = try report()
        _ = try action("hold-snapshots")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        _ = try waitForReport { self.number($0, "active_websockets") == 0 }
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let held = try waitForReport { self.count($0, "held_snapshot_requests") > 0 }
        XCTAssertEqual(count(held, "snapshot_responses"), count(initial, "snapshot_responses"))
        XCTAssertTrue(tail.isHittable, "Warm history must remain visible while foreground synchronization is held.")
        XCTAssertEqual(editor(app).value as? String, draft)
        assertQuiet(app)
        capture(app, "response-foreground-with-snapshot-held")
        _ = try action("release-snapshots")
        waitUntilReady(app)
        let final = try waitForReport { self.count($0, "snapshot_responses") > self.count(initial, "snapshot_responses") }
        XCTAssertEqual(count(final, "websockets_opened") - count(initial, "websockets_opened"), 1)
        XCTAssertEqual(number(final, "active_websockets"), 1)
        XCTAssertEqual(editor(app).value as? String, draft)
        assertCanonical(final, sent: false)
        assertQuiet(app)
    }

    func testColdRelaunchShowsCachedHistoryBeforeSnapshotReturns() throws {
        let app = try launch("cold-cache")
        let draft = try text("draft")
        editor(app).tap()
        editor(app).typeText(draft)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        _ = try waitForReport { self.number($0, "active_websockets") == 0 }
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        let initial = try action("hold-snapshots")
        app.launchArguments = launchArguments()
        app.launch()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 10))
        let held = try waitForReport { self.count($0, "held_snapshot_requests") > 0 }
        let tail = app.textViews["message-" + (try text("tail_id"))]
        XCTAssertTrue(tail.waitForExistence(timeout: 5), "Candidate must restore canonical history before the held network snapshot. Baseline without a history cache is expected to fail this assertion.")
        XCTAssertTrue(tail.isHittable)
        XCTAssertEqual(editor(app).value as? String, draft)
        XCTAssertEqual(held["snapshots_held"] as? Bool, true)
        XCTAssertEqual(count(held, "snapshot_responses"), count(initial, "snapshot_responses"))
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled, "Cached content cannot authorize a send before fresh synchronization.")
        assertQuiet(app)
        capture(app, "response-cold-cache-before-network")
        _ = try action("release-snapshots")
        waitUntilReady(app)
        let final = try waitForReport { self.count($0, "snapshot_responses") > self.count(initial, "snapshot_responses") }
        XCTAssertEqual(editor(app).value as? String, draft)
        assertCanonical(final, sent: false)
        assertQuiet(app)
    }

    func testHistoryScrollLatestAndDraft() throws {
        let app = try launch("history")
        let table = app.tables["transcript"]
        XCTAssertEqual(table.cells.count, 120)
        let draft = try text("draft")
        editor(app).tap()
        editor(app).typeText(draft)
        table.swipeDown(velocity: .slow)
        table.swipeDown(velocity: .fast)
        let latest = app.buttons["latestMessages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.tap()
        wait(for: NSPredicate(format: "exists == false"), element: latest, timeout: 10)
        let tail = app.textViews["message-" + (try text("tail_id"))]
        XCTAssertTrue(tail.isHittable)
        XCTAssertLessThanOrEqual(tail.frame.maxY, editor(app).frame.minY)
        XCTAssertEqual(editor(app).value as? String, draft)
        assertCanonical(try report(), sent: false)
        assertQuiet(app)
        capture(app, "response-history-latest")
    }

    func testAuthorizationFailureCanPairReplacementHost() throws {
        captureEnabled = false
        let app = try launch("auth-recovery")
        let oldTail = app.textViews["message-" + (try text("tail_id"))]
        XCTAssertTrue(oldTail.exists)
        editor(app).tap()
        editor(app).typeText(try text("prompt"))
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        let uncertain = app.descendants(matching: .any)["uncertainAction"]
        XCTAssertTrue(uncertain.waitForExistence(timeout: 5))
        _ = try action("show-old-request")
        XCTAssertTrue(app.staticTexts["OLD_AUTH_REQUEST"].waitForExistence(timeout: 5))
        let initial = try report()
        XCTAssertEqual(count(initial, "uncertain_receipts"), 1)
        XCTAssertEqual(count(initial, "command_requests"), 1)
        XCTAssertEqual(count(initial, "http_receipts"), 1)
        _ = try action("invalidate-grant")
        let repair = app.buttons["repairHostConnection"]
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        XCTAssertFalse(app.staticTexts["OLD_AUTH_REQUEST"].exists)
        let failed = try waitForReport { self.count($0, "failed_snapshot_requests") == 1 && self.number($0, "active_websockets") == 0 }
        XCTAssertEqual(count(failed, "websockets_opened") - count(initial, "websockets_opened"), 1)
        XCTAssertEqual(count(failed, "controlled_http_failures"), 1)
        XCTAssertEqual(number(failed, "controlled_failure_status"), try XCTUnwrap(Int(ProcessInfo.processInfo.environment["COMPANION_TEST_RESPONSE_AUTH_STATUS"] ?? "401")))
        let settled = Date().addingTimeInterval(3.2)
        repeat {
            XCTAssertEqual(count(try report(), "failed_snapshot_requests"), 1, "An authorization failure must stop the automatic connection loop.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < settled
        capture(app, "response-auth-repair-required")
        repair.tap()
        let invitation = app.descendants(matching: .any).matching(identifier: "invitation").firstMatch
        XCTAssertTrue(invitation.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(repair.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.tables["transcript"].cells.count, 120, "Cancel must retain the previous grant's history and uncertain outgoing row.")
        XCTAssertTrue(uncertain.exists)
        XCTAssertEqual(editor(app).value as? String, try text("prompt"))
        XCTAssertEqual(count(try report(), "pair_requests"), 1)

        let replacementLabel = label + "-replacement"
        let replacement = try control("", body: ["label": replacementLabel, "workload": "auth-replacement", "stored_rows": 120])
        additionalTrialLabels.append(replacementLabel)
        _ = try control("/" + replacementLabel, body: ["action": "hold-snapshots"])
        repair.tap()
        XCTAssertTrue(invitation.waitForExistence(timeout: 5))
        invitation.tap()
        invitation.typeText(try XCTUnwrap(replacement["invitation"] as? String))
        app.buttons["pair"].tap()
        wait(for: NSPredicate(format: "exists == false"), element: invitation, timeout: 15)
        _ = try waitForReport(label: replacementLabel) { self.count($0, "held_snapshot_requests") == 1 }
        assertOldGrantAbsent(app)
        XCTAssertEqual(app.tables["transcript"].cells.count, 0, "Replacement pairing must not display cached rows from the old grant while its own read is held.")
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        _ = try control("/" + replacementLabel, body: ["action": "release-snapshots"])
        waitUntilReady(app)
        let replacementTail = app.textViews["message-" + (try XCTUnwrap(replacement["tail_id"] as? String))]
        XCTAssertTrue(replacementTail.waitForExistence(timeout: 10))
        XCTAssertTrue(replacementTail.label.contains("REPLACEMENT."))
        XCTAssertEqual(app.tables["transcript"].cells.count, 120)
        assertOldGrantAbsent(app)
        assertQuiet(app)
        let ready = try waitForReport(label: replacementLabel) { self.number($0, "active_websockets") == 1 }
        assertCanonical(ready, sent: false)
        XCTAssertEqual(count(ready, "pair_requests"), 1)
        let old = try report()
        XCTAssertEqual(count(old, "failed_snapshot_requests"), 1)
        XCTAssertEqual(count(old, "command_requests"), 1)
        XCTAssertEqual(count(old, "errors"), 0)
        XCTAssertEqual(number(old, "active_websockets"), 0)
        capture(app, "response-replacement-grant-loaded")
    }

    func testTemporaryUnavailableHostRemainsRetryable() throws {
        captureEnabled = false
        let app = try launch("temporary-unavailable")
        let tail = app.textViews["message-" + (try text("tail_id"))]
        _ = try action("unavailable")
        _ = try waitForReport { self.count($0, "failed_snapshot_requests") >= 2 }
        XCTAssertTrue(app.descendants(matching: .any)["connectionError"].exists)
        XCTAssertTrue(app.buttons["Reconnect"].exists)
        XCTAssertFalse(app.buttons["repairHostConnection"].exists)
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        XCTAssertTrue(tail.exists)
        _ = try action("restore-availability")
        waitUntilReady(app)
        let ready = try waitForReport { self.number($0, "active_websockets") == 1 }
        XCTAssertGreaterThanOrEqual(count(ready, "http_503"), 2)
        XCTAssertEqual(count(ready, "pair_requests"), 1)
        XCTAssertTrue(tail.exists)
        assertCanonical(ready, sent: false)
        assertQuiet(app)
        capture(app, "response-temporary-unavailable-recovered")
    }

    private func assertOldGrantAbsent(_ app: XCUIApplication) {
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "OLD-AUTH.", "RESPONSE_SEND_CHECK")).count, 0)
        XCTAssertFalse(app.staticTexts["OLD_AUTH_REQUEST"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["uncertainAction"].exists)
        XCTAssertFalse(app.buttons["repairHostConnection"].exists)
        XCTAssertTrue((editor(app).value as? String ?? "").isEmpty || editor(app).value as? String == editor(app).placeholderValue)
    }

    private func exerciseSend(_ workload: String) throws {
        let app = try launch(workload)
        if workload == "send-working" {
            _ = try action("working")
            XCTAssertTrue(app.staticTexts["workingIndicator"].waitForExistence(timeout: 5))
        }
        editor(app).tap()
        editor(app).typeText(try text("prompt"))
        if workload == "send-reader" {
            app.tables["transcript"].swipeDown(velocity: .slow)
            app.tables["transcript"].swipeDown(velocity: .fast)
            XCTAssertTrue(app.buttons["latestMessages"].waitForExistence(timeout: 5))
        }
        capture(app, "response-before-send")
        try submit(app, draftAlreadyEntered: true)
        let outgoing = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "You. ", "RESPONSE_SEND_CHECK")).firstMatch
        XCTAssertTrue(outgoing.waitForExistence(timeout: 5))
        XCTAssertTrue(outgoing.isHittable, "Actual Send must expose its outgoing row, including when the reader was away from latest.")
        XCTAssertLessThanOrEqual(outgoing.frame.maxY, editor(app).frame.minY)
        XCTAssertTrue(app.staticTexts["workingIndicator"].waitForExistence(timeout: 5))
        let draft = try text("draft")
        editor(app).tap()
        editor(app).typeText(draft)
        XCTAssertEqual(editor(app).value as? String, draft)
        let held = try report()
        XCTAssertEqual(count(held, "ws_receipts"), 1)
        XCTAssertEqual(count(held, "http_receipts"), 0)
        XCTAssertEqual(app.staticTexts["agentStatus"].label, "Working")
        XCTAssertTrue(app.staticTexts["workingIndicator"].isHittable)
        capture(app, "response-accepted-before-http")
        _ = try action("complete")
        _ = try action("release-http")
        waitUntilReady(app)
        let final = try waitForReport { self.count($0, "http_receipts") == 1 }
        XCTAssertEqual(editor(app).value as? String, draft)
        let answer = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Hermes. ", "RESPONSE_COMPLETE")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        XCTAssertEqual(answer.label, "Hermes. " + (try text("answer")))
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "You. ", "RESPONSE_SEND_CHECK")).count, 1)
        assertCanonical(final, sent: true)
        assertQuiet(app)
    }

    private func launch(_ workload: String) throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let storedRows = Int(environment["COMPANION_TEST_RESPONSE_STORED_ROWS"] ?? "120")
        XCTAssertTrue(storedRows == 120 || storedRows == 10000)
        let authStatus = Int(environment["COMPANION_TEST_RESPONSE_AUTH_STATUS"] ?? "401")
        XCTAssertTrue(authStatus == 401 || authStatus == 403)
        configuration = try control("", body: ["label": label, "workload": workload, "stored_rows": try XCTUnwrap(storedRows), "auth_status": try XCTUnwrap(authStatus)])
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = launchArguments() + ["--invitation", try text("invitation")]
        app.launch()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["fixtureBanner"].exists)
        waitUntilReady(app)
        XCTAssertTrue(app.staticTexts["response-workload"].exists)
        XCTAssertTrue(app.textViews["message-" + (try text("tail_id"))].waitForExistence(timeout: 10))
        let initial = try waitForReport { self.number($0, "active_websockets") == 1 }
        assertCanonical(initial, sent: false)
        return app
    }

    private func launchArguments() -> [String] {
        var result = ["--session", "response-history"]
        guard captureEnabled else { return result }
        result += ["--chat-performance", "--chat-performance-label", label, "--chat-performance-control", controlID]
        if ProcessInfo.processInfo.environment["COMPANION_TEST_RESPONSE_STAGES"] == "1" {
            result.append("--chat-performance-stages")
        }
        return result
    }

    private func submit(_ app: XCUIApplication, draftAlreadyEntered: Bool = false) throws {
        if !draftAlreadyEntered {
            editor(app).tap()
            editor(app).typeText(try text("prompt"))
        }
        XCTAssertEqual(editor(app).value as? String, try text("prompt"))
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
        app.buttons["sendMessage"].tap()
        wait(for: NSPredicate(format: "value == '' OR value == placeholderValue"), element: editor(app), timeout: 8)
        let accepted = try waitForReport { self.count($0, "ws_receipts") == 1 }
        XCTAssertEqual(count(accepted, "http_receipts"), 0, "The real WebSocket acceptance must clear the submitted draft while its HTTP response remains held.")
    }

    private func assertCanonical(_ report: [String: Any], sent: Bool) {
        XCTAssertEqual(count(report, "errors"), 0)
        XCTAssertEqual(count(report, "command_requests"), sent ? 1 : 0)
        XCTAssertEqual(count(report, "unique_commands"), sent ? 1 : 0)
        XCTAssertEqual(count(report, "deduplicated_requests"), 0)
        XCTAssertEqual(number(report, "canonical_rows"), number(report, "seed_stored_rows") + (sent ? 2 : 0))
        XCTAssertEqual(number(report, "canonical_unique_ids"), number(report, "canonical_rows"))
        XCTAssertEqual(number(report, "submitted_matches"), sent ? 1 : 0)
        XCTAssertEqual(number(report, "answer_matches"), sent ? 1 : 0)
    }

    private func assertQuiet(_ app: XCUIApplication) {
        XCTAssertFalse(app.descendants(matching: .any)["connectionError"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["uncertainAction"].exists)
        XCTAssertFalse(app.buttons["Dismiss status"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }

    private func waitUntilReady(_ app: XCUIApplication) {
        wait(for: NSPredicate(format: "label == %@", "Ready"), element: app.staticTexts["agentStatus"], timeout: 20)
    }

    private func wait(for predicate: NSPredicate, element: XCUIElement, timeout: TimeInterval) {
        let condition = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed)
    }

    private func text(_ key: String) throws -> String { try XCTUnwrap(configuration[key] as? String) }
    private func number(_ object: [String: Any], _ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
    private func count(_ object: [String: Any], _ key: String) -> Int { number(object["counts"] as? [String: Any] ?? [:], key) }
    private func report() throws -> [String: Any] { try control("/" + label) }
    private func action(_ value: String) throws -> [String: Any] { try control("/" + label, body: ["action": value]) }

    private func waitForReport(label trialLabel: String? = nil, _ predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let value = try control("/" + (trialLabel ?? label))
            if predicate(value) { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("The controlled host did not reach its expected workload state.")
        return try control("/" + (trialLabel ?? label))
    }

    private func control(_ suffix: String, body: [String: Any]? = nil) throws -> [String: Any] {
        let completed = expectation(description: "Controlled fixture response")
        var result: Result<[String: Any], Error>?
        let task = Task { @MainActor in
            defer { completed.fulfill() }
            do { result = .success(try await controlAsync(suffix, body: body)) }
            catch { result = .failure(error) }
        }
        defer { task.cancel() }
        wait(for: [completed], timeout: 12)
        return try XCTUnwrap(result).get()
    }

    private func controlAsync(_ suffix: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: baseURL + "/control/trials" + suffix)))
        request.timeoutInterval = 10
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ResponseFixture", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func finishCapture() async {
        let exported = expectation(description: "Response capture export acknowledged")
        let observer = Unmanaged.passUnretained(exported).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = "org.hermescompanion.performance.exported." + controlID
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<XCTestExpectation>.fromOpaque(observer).takeUnretainedValue().fulfill()
        }, name as CFString, nil, .deliverImmediately)
        defer { CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(rawValue: name as CFString), nil) }
        CFNotificationCenterPostNotification(center, CFNotificationName(rawValue: ("org.hermescompanion.performance.finish." + controlID) as CFString), nil, nil, true)
        let result = await XCTWaiter.fulfillment(of: [exported], timeout: 10)
        XCTAssertEqual(result, .completed)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
