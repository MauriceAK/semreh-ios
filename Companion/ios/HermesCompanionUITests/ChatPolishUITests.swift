import XCTest
import Vision

@MainActor
final class ChatPolishUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["fixtureBanner"].waitForExistence(timeout: 10))
        return app
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func checkComposer(_ app: XCUIApplication, action: String) {
        let plus = app.buttons["addAttachment"]
        let primary = app.buttons[action]
        XCTAssertTrue(plus.isHittable)
        XCTAssertTrue(primary.exists)
        for button in [plus, primary] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 12)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 12)
        }
        XCTAssertEqual(plus.frame.midY, primary.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(plus.frame.maxX, editor(app).frame.minX)
        XCTAssertLessThanOrEqual(editor(app).frame.maxX, primary.frame.minX)
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(primary.frame.maxY, app.keyboards.firstMatch.frame.minY)
        }
    }

    func testComposerGeometryAndPickerCancellation() {
        let app = launch(["--fixture-empty"])
        checkComposer(app, action: "sendMessage")
        capture(app, "polish-empty-chat")
        editor(app).tap()
        editor(app).typeText("A thought to keep while I choose a file")
        checkComposer(app, action: "sendMessage")
        capture(app, "polish-composer-keyboard")
        app.buttons["addAttachment"].tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Files"].exists)
        capture(app, "polish-attachment-menu")
        app.buttons["Files"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        capture(app, "polish-system-files-picker")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        let composerReady = NSPredicate { _, _ in
            self.editor(app).isHittable
                && app.buttons["addAttachment"].isHittable
                && app.buttons["sendMessage"].isHittable
                && app.buttons["sendMessage"].isEnabled
        }
        expectation(for: composerReady, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(editor(app).value as? String, "A thought to keep while I choose a file")
        checkComposer(app, action: "sendMessage")
        capture(app, "polish-composer-after-picker-cancel")
    }

    func testWorkingSteeringAndStopRemainReachable() {
        let app = launch(["--fixture-working"])
        XCTAssertTrue(app.buttons["stopAgent"].isHittable)
        checkComposer(app, action: "stopAgent")
        let working = app.staticTexts["workingIndicator"]
        XCTAssertTrue(working.exists)
        XCTAssertLessThan(working.frame.midX, app.frame.midX)
        XCTAssertLessThanOrEqual(working.frame.maxY, editor(app).frame.minY)
        XCTAssertFalse(app.staticTexts["Working…"].exists)
        capture(app, "polish-working-empty")
        editor(app).tap()
        editor(app).typeText("Keep going with this direction")
        checkComposer(app, action: "sendMessage")
        let stop = app.buttons["stopAgent"]
        XCTAssertTrue(stop.isHittable)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44)
        XCTAssertFalse(stop.frame.intersects(app.buttons["sendMessage"].frame))
        capture(app, "polish-working-direction")
        stop.tap()
        XCTAssertFalse(app.buttons["stopAgent"].exists)
        XCTAssertEqual(editor(app).value as? String, "Keep going with this direction")
        capture(app, "polish-stopped-draft")
    }

    func testMultilineAndAttachmentFailureGeometry() {
        let app = launch(["--fixture-multiline", "--fixture-attachment-failed"])
        editor(app).tap()
        checkComposer(app, action: "sendMessage")
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        capture(app, "polish-multiline-failed-attachment")
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
        checkComposer(app, action: "sendMessage")
        capture(app, "polish-multiline-draft")
    }

    func testReadingLatestAndFloatingChrome() {
        let app = launch()
        editor(app).tap()
        editor(app).typeText("A draft stays while reading")
        let table = app.tables["transcript"]
        table.swipeDown(velocity: .slow)
        table.swipeDown(velocity: .fast)
        let latest = app.buttons["latestMessages"]
        XCTAssertTrue(latest.isHittable)
        XCTAssertGreaterThanOrEqual(latest.frame.height, 44)
        XCTAssertEqual(latest.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertFalse(latest.staticTexts["Latest"].exists)
        XCTAssertGreaterThan(table.frame.maxY, latest.frame.maxY, "The transcript extends underneath floating controls.")
        XCTAssertLessThan(table.frame.minY, app.buttons["sessions"].frame.maxY)
        XCTAssertLessThanOrEqual(latest.frame.maxY, editor(app).frame.minY)
        capture(app, "polish-reading-history")
        latest.tap()
        XCTAssertTrue(app.textViews["message-fixture-9999"].isHittable)
        XCTAssertLessThanOrEqual(app.textViews["message-fixture-9999"].frame.maxY, editor(app).frame.minY)
        XCTAssertLessThanOrEqual(editor(app).frame.minY - app.textViews["message-fixture-9999"].frame.maxY, 32, "Latest must place the tail beside the composer, without a keyboard-sized gap.")
        XCTAssertEqual(editor(app).value as? String, "A draft stays while reading")
        XCTAssertFalse(latest.exists)
        capture(app, "polish-latest-restored")
    }

    func testMuseConversationMarkdownGlassUnderlapAndWorkingBubble() {
        let app = launch(["--fixture-muse", "--fixture-working", "--fixture-geometry"])
        let table = app.tables["transcript"]
        let working = app.staticTexts["workingIndicator"]
        XCTAssertTrue(working.waitForExistence(timeout: 5))
        XCTAssertLessThan(working.frame.midX, app.frame.midX / 2)
        XCTAssertLessThanOrEqual(working.frame.width, 80)
        XCTAssertLessThanOrEqual(working.frame.height, 48)
        XCTAssertLessThanOrEqual(working.frame.maxY, editor(app).frame.minY)
        XCTAssertEqual(working.label, "Hermes is working")
        checkComposer(app, action: "stopAgent")
        capture(app, "muse-working-floating-composer")

        editor(app).tap()
        editor(app).typeText("Keep my direction while I review the answer")
        checkComposer(app, action: "sendMessage")
        XCTAssertTrue(app.buttons["stopAgent"].isHittable)
        XCTAssertLessThanOrEqual(working.frame.maxY, editor(app).frame.minY)
        capture(app, "muse-working-keyboard-direction")
        app.buttons["stopAgent"].tap()
        XCTAssertTrue(working.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor(app).value as? String, "Keep my direction while I review the answer")

        table.swipeDown(velocity: .slow)
        let latest = app.buttons["latestMessages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertEqual(latest.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(latest.frame.width, 44)
        XCTAssertGreaterThanOrEqual(latest.frame.height, 44)
        XCTAssertFalse(latest.staticTexts["Latest"].exists)
        XCTAssertLessThan(table.frame.minY, app.buttons["sessions"].frame.minY)
        XCTAssertGreaterThan(table.frame.maxY, editor(app).frame.maxY)
        let markdown = app.textViews["message-muse-4"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 5))
        let rendered = markdown.value as? String ?? ""
        XCTAssertTrue(rendered.contains("A useful first pass"))
        XCTAssertTrue(rendered.contains("•\tRead comfortably:"))
        XCTAssertTrue(rendered.contains("1.\tTry a long conversation."))
        XCTAssertTrue(rendered.contains("let message ="))
        XCTAssertTrue(rendered.contains("<untrusted_tool_result>"))
        XCTAssertTrue(rendered.contains("{\"ok\": true}"))
        XCTAssertFalse(rendered.contains("**"))
        XCTAssertFalse(rendered.contains("```"))
        capture(app, "muse-markdown-under-floating-chrome")
        table.swipeDown(velocity: .slow)
        capture(app, "muse-reading-under-glass-header")
        latest.tap()
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
        let tail = app.textViews["message-muse-6"]
        XCTAssertTrue(tail.isHittable)
        XCTAssertLessThanOrEqual(tail.frame.maxY, editor(app).frame.minY)
        XCTAssertLessThanOrEqual(editor(app).frame.minY - tail.frame.maxY, 32)
        XCTAssertEqual(editor(app).value as? String, "Keep my direction while I review the answer")
        capture(app, "muse-latest-tail-above-composer")
    }

    func testLargeTextWorkingComposer() {
        let app = launch(["--fixture-working", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        editor(app).tap()
        editor(app).typeText("A larger draft")
        checkComposer(app, action: "sendMessage")
        XCTAssertTrue(app.buttons["stopAgent"].isHittable)
        capture(app, "polish-accessibility-working")
    }

    func testLargeTextAttachmentFailure() throws {
        let app = launch(["--fixture-attachment-failed", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        capture(app, "polish-accessibility-attachment-before-keyboard")
        editor(app).tap()
        editor(app).typeText("Keep my file draft")
        checkComposer(app, action: "sendMessage")
        capture(app, "polish-accessibility-two-line-draft")
        let visibleDraft = VNRecognizeTextRequest()
        visibleDraft.recognitionLevel = .accurate
        visibleDraft.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(editor(app).screenshot().image.cgImage)).perform([visibleDraft])
        let visibleLines = (visibleDraft.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(visibleLines.contains("Keep my"), "The first draft line must be visibly rendered, without clipping.")
        XCTAssertTrue(visibleLines.contains("file draft"), "The second draft line must remain visibly rendered above the keyboard.")
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachmentDetails-")).firstMatch
        XCTAssertLessThanOrEqual(details.frame.maxY, editor(app).frame.minY)
        XCTAssertLessThanOrEqual(app.staticTexts["agentStatus"].frame.maxY, editor(app).frame.minY)
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
        XCTAssertTrue(remove.isHittable)
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        capture(app, "polish-accessibility-attachment-keyboard")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachmentDetails-")).firstMatch.tap()
        XCTAssertTrue(app.alerts["Attachment needs attention"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Remove this attachment and choose it again.")).firstMatch.exists)
        capture(app, "polish-accessibility-attachment-details")
        let detailScroll = app.alerts.scrollViews.firstMatch
        if detailScroll.exists {
            detailScroll.swipeUp()
            capture(app, "polish-accessibility-attachment-details-end")
        }
        app.alerts.buttons["Remove file"].tap()
        XCTAssertEqual(editor(app).value as? String, "Keep my file draft")
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
    }

    func testAccessibilityLongDraftAndAttachmentStayInsideKeyboardViewport() {
        let app = launch(["--fixture-attachment-failed", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let draft = "Keep this complete draft while I review the attachment. Include the important context, preserve every detail, and leave this message unsent until I finish checking the conversation."
        editor(app).tap()
        editor(app).typeText(draft)
        capture(app, "muse-accessibility-long-draft-attachment-keyboard")
        XCTAssertEqual(editor(app).value as? String, draft)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The software keyboard must remain visible after typing the complete draft.")
        checkComposer(app, action: "sendMessage")
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachmentDetails-")).firstMatch
        let status = app.staticTexts["agentStatus"]
        XCTAssertGreaterThanOrEqual(details.frame.minY, status.frame.maxY)
        XCTAssertLessThanOrEqual(details.frame.maxY, editor(app).frame.minY)
        XCTAssertGreaterThanOrEqual(editor(app).frame.minY, status.frame.maxY)
        XCTAssertLessThanOrEqual(editor(app).frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertGreaterThanOrEqual(app.buttons["addAttachment"].frame.minY, app.frame.minY)
        XCTAssertGreaterThanOrEqual(app.buttons["sendMessage"].frame.minY, app.frame.minY)
    }

    func testApprovalWithKeyboard() {
        let app = launch(["--fixture-approval"])
        editor(app).tap()
        editor(app).typeText("A question before approving")
        checkComposer(app, action: "sendMessage")
        XCTAssertTrue(app.buttons["answer-deny"].isHittable)
        XCTAssertTrue(app.buttons["answer-allow"].isHittable)
        XCTAssertTrue(app.buttons["stopAgent"].isHittable)
        for choice in ["answer-deny", "answer-allow"] {
            let button = app.buttons[choice]
            XCTAssertLessThanOrEqual(button.frame.maxY, app.buttons["stopAgent"].frame.minY)
            XCTAssertGreaterThanOrEqual(button.frame.minY, app.tables["transcript"].frame.minY)
        }
        capture(app, "polish-approval-keyboard")
        app.scrollViews["requestDetails"].swipeUp()
        capture(app, "polish-approval-details-end")
        app.buttons["answer-deny"].tap()
        XCTAssertTrue(app.buttons["answer-deny"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor(app).value as? String, "A question before approving")
        capture(app, "polish-denied-draft")
    }

    func testNativePhotoPickerWhenSeeded() throws {
        guard ProcessInfo.processInfo.environment["COMPANION_TEST_PHOTO_SEEDED"] == "1" else {
            throw XCTSkip("Seed the isolated simulator photo library before this picker check.")
        }
        let app = launch(["--fixture-empty"])
        editor(app).tap()
        editor(app).typeText("Keep this draft with my photo")
        app.buttons["addAttachment"].tap()
        app.buttons["Photos"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        capture(app, "polish-system-photos-picker")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].firstMatch.tap()
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
        XCTAssertEqual(editor(app).value as? String, "Keep this draft with my photo")
        capture(app, "polish-picked-photo-draft")
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor(app).value as? String, "Keep this draft with my photo")
    }

    func testRealFileSendWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let session = environment["COMPANION_TEST_ATTACHMENT_SESSION"],
              let path = environment["COMPANION_TEST_ATTACHMENT_FILE"],
              let marker = environment["COMPANION_TEST_ATTACHMENT_MARKER"] else {
            throw XCTSkip("Requires an isolated session and synthetic attachment fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--session", session, "--attachment-file", path]
        app.launch()
        XCTAssertTrue(app.staticTexts["agentStatus"].waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label == %@", "Ready"), evaluatedWith: app.staticTexts["agentStatus"])
        waitForExpectations(timeout: 30)
        XCTAssertFalse(app.staticTexts["fixtureBanner"].exists)
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        let fixtureFiles = app.buttons.matching(NSPredicate(format: "label == %@", "Remove native-note.txt"))
        while fixtureFiles.count > 1 { fixtureFiles.firstMatch.tap() }
        editor(app).tap()
        if let draft = editor(app).value as? String, draft != editor(app).placeholderValue, !draft.isEmpty {
            editor(app).typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: draft.count))
        }
        editor(app).typeText("Read the attached document and reply with only its verification code.")
        checkComposer(app, action: "sendMessage")
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
        capture(app, "polish-real-file-before-send")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 15))
        let answer = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Hermes. " + marker)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 120))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse((editor(app).value as? String ?? "").contains("Read the attached"))
        capture(app, "polish-real-file-answer")
    }

}
