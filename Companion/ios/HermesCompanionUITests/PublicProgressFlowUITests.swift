import Vision
import XCTest

@MainActor
final class PublicProgressFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testOneRealPublicProgressTurnWithDelayedReceiptWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let session = environment["COMPANION_TEST_PUBLIC_SESSION"],
              let prompt = environment["COMPANION_TEST_PUBLIC_PROMPT"],
              let commentary = environment["COMPANION_TEST_PUBLIC_COMMENTARY"],
              let marker = environment["COMPANION_TEST_PUBLIC_MARKER"] else {
            throw XCTSkip("Requires a fresh isolated official-gateway session and owned delayed-response helper. Sends exactly one real prompt.")
        }
        let app = launch(session: session)
        XCTAssertEqual(app.tables["transcript"].cells.count, 0, "Do not replay a session that already contains a turn.")
        XCTAssertFalse(app.staticTexts["workingIndicator"].exists)
        let composer = editor(app)
        composer.tap()
        composer.typeText(prompt)
        XCTAssertEqual(composer.value as? String, prompt)
        app.buttons["sendMessage"].tap()
        let outgoing = app.textViews.matching(NSPredicate(format: "label == %@", "You. " + prompt))
        XCTAssertTrue(outgoing.firstMatch.exists, "The submitted user bubble must already exist at the first observation after Send.")
        XCTAssertEqual(outgoing.count, 1)
        capture(app, "public-progress-first-observation-after-send")
        let working = app.staticTexts["workingIndicator"]
        XCTAssertTrue(working.waitForExistence(timeout: 15))
        XCTAssertTrue(outgoing.firstMatch.exists, "Working dots must never replace or precede the submitted row.")
        XCTAssertEqual(outgoing.count, 1, "The early WebSocket receipt must not duplicate the local row.")
        capture(app, "public-progress-working-with-outgoing-row")
        let progress = assistant(app, exact: commentary)
        XCTAssertTrue(progress.waitForExistence(timeout: 120), "The actual model must emit its requested public commentary. Missing emission is a failed live proof, not a synthetic pass.")
        capture(app, "public-progress-actual-intermediate-message")
        let draft = "Keep this draft while the arithmetic completes."
        composer.tap()
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        let final = assistant(app, containing: marker)
        XCTAssertTrue(final.waitForExistence(timeout: 180))
        waitUntilReady(app)
        XCTAssertTrue(progress.exists, "Public commentary must survive final-answer reconciliation.")
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertFalse(working.exists)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "uncertainAction").firstMatch.exists)
        assertFormattedFinal(final)
        if app.buttons["latestMessages"].exists { app.buttons["latestMessages"].tap() }
        try captureVisibleMarker(app, marker: marker, name: "public-progress-final-markdown")
        app.terminate()
        app.launchArguments = ["--session", session]
        app.launch()
        waitUntilReady(app)
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        XCTAssertTrue(final.waitForExistence(timeout: 15))
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertEqual(editor(app).value as? String, draft)
        assertFormattedFinal(final)
        capture(app, "public-progress-reloaded-canonical-history")
        attachScope("One actual native Hermes turn with a helper-delayed HTTP response. The first XCTest observation and working state both contain one outgoing row. Actual public commentary survives final completion and reload. Root must additionally inspect the continuous recording and raw event chronology. XCTest polling does not establish subframe ordering, latency or FPS.")
    }

    func testControlledCanonicalPublicCommentaryWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let session = environment["COMPANION_TEST_PUBLIC_HISTORY_SESSION"],
              let commentary = environment["COMPANION_TEST_PUBLIC_HISTORY_COMMENTARY"],
              let marker = environment["COMPANION_TEST_PUBLIC_HISTORY_MARKER"],
              let privateMarker = environment["COMPANION_TEST_PUBLIC_PRIVATE_MARKER"],
              let toolMarker = environment["COMPANION_TEST_PUBLIC_TOOL_MARKER"] else {
            throw XCTSkip("Requires separately labeled synthetic canonical history served by the official isolated gateway. Sends no model turn.")
        }
        let app = launch(session: session)
        let progress = assistant(app, exact: commentary)
        let final = assistant(app, containing: marker)
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        XCTAssertTrue(final.waitForExistence(timeout: 15))
        XCTAssertEqual(app.tables["transcript"].cells.count, 3)
        for forbidden in [privateMarker, toolMarker, "<think>"] {
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "label CONTAINS %@", forbidden)).firstMatch.exists)
        }
        assertFormattedFinal(final)
        try captureVisibleMarker(app, marker: marker, name: "controlled-official-public-commentary-history")
        app.terminate()
        app.launchArguments = ["--session", session]
        app.launch()
        waitUntilReady(app)
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        XCTAssertTrue(final.waitForExistence(timeout: 15))
        XCTAssertEqual(app.tables["transcript"].cells.count, 3)
        for forbidden in [privateMarker, toolMarker, "<think>"] {
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "label CONTAINS %@", forbidden)).firstMatch.exists)
        }
        capture(app, "controlled-official-commentary-history-reloaded")
        attachScope("Controlled synthetic rows were written through official SessionDB, then projected by the unmodified official Hermes gateway. Its display_commentary remains visible while seeded reasoning, tool payload and hidden rows remain absent. This read-only native check does not prove a model emitted commentary.")
    }

    private func launch(session: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--session", session]
        if let invitation = ProcessInfo.processInfo.environment["COMPANION_TEST_INVITATION"] {
            app.launchArguments += ["--invitation", invitation]
        }
        app.launch()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["fixtureBanner"].exists)
        waitUntilReady(app)
        return app
    }

    private func waitUntilReady(_ app: XCUIApplication) {
        expectation(for: NSPredicate(format: "label == %@", "Ready"), evaluatedWith: app.staticTexts["agentStatus"])
        waitForExpectations(timeout: 30)
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }

    private func assistant(_ app: XCUIApplication, exact text: String) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "label == %@", "Hermes. " + text)).firstMatch
    }

    private func assistant(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Hermes. ", text)).firstMatch
    }

    private func assertFormattedFinal(_ final: XCUIElement) {
        expectation(for: NSPredicate(format: "value CONTAINS %@ AND NOT value CONTAINS %@ AND NOT value CONTAINS %@",
            "17 × 19 = 323", "**", "##"), evaluatedWith: final)
        waitForExpectations(timeout: 10)
    }

    private func captureVisibleMarker(_ app: XCUIApplication, marker: String, name: String) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.image.cgImage)).perform([request])
        func normalized(_ text: String) -> String {
            // Vision can read a Latin C glyph as the visually identical Cyrillic capital Es.
            text.uppercased().replacingOccurrences(of: "\u{0421}", with: "C")
                .filter { $0.isLetter || $0.isNumber }
        }
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let diagnostic = XCTAttachment(string: recognized.map { text in
            text + "\n" + text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        }.joined(separator: "\n\n"))
        diagnostic.name = name + "-ocr"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTAssertTrue(recognized.contains {
            normalized($0).contains(normalized(marker))
        }, "The final marker must appear in actual screenshot pixels, not only the accessibility tree.")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScope(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "public-progress-proof-scope"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
