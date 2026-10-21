import XCTest

@MainActor
final class VoiceDictationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ scenario: String = "normal", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture", "--fixture-empty", "--voice-fixture", scenario] + extra
        app.launch()
        XCTAssertTrue(app.buttons["dictateMessage"].waitForExistence(timeout: 10))
        return app
    }
    private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "controlled-voice-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func checkTargets(_ app: XCUIApplication, _ names: [String]) {
        let buttons = names.map { app.buttons[$0] }
        for button in buttons {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width + 0.001, 44, "Allow only subpixel floating-point error around a 44-point target.")
            XCTAssertGreaterThanOrEqual(button.frame.height + 0.001, 44, "Allow only subpixel floating-point error around a 44-point target.")
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            if app.keyboards.firstMatch.exists { XCTAssertLessThanOrEqual(button.frame.maxY, app.keyboards.firstMatch.frame.minY) }
        }
        for index in buttons.indices {
            for other in buttons.indices where other > index { XCTAssertFalse(buttons[index].frame.intersects(buttons[other].frame)) }
        }
    }

    private func alertButton(_ alert: XCUIElement, _ label: String) -> XCUIElement {
        let matches = alert.buttons.matching(NSPredicate(format: "label == %@", label))
        let first = matches.firstMatch
        XCTAssertTrue(first.exists)
        let frame = first.frame
        for duplicate in matches.allElementsBoundByIndex.dropFirst() {
            let other = duplicate.frame
            XCTAssertEqual(other.minX, frame.minX, accuracy: 0.001, "An alert wrapper and child must represent the same visual control.")
            XCTAssertEqual(other.minY, frame.minY, accuracy: 0.001)
            XCTAssertEqual(other.width, frame.width, accuracy: 0.001)
            XCTAssertEqual(other.height, frame.height, accuracy: 0.001)
        }
        XCTAssertTrue(first.isHittable)
        XCTAssertGreaterThanOrEqual(frame.width + 0.001, 44)
        XCTAssertGreaterThanOrEqual(frame.height + 0.001, 44)
        return first
    }

    private func readAlertBody(_ app: XCUIApplication, alert: XCUIElement, message: String, name: String) {
        let exactMessage = NSPredicate(format: "label == %@", message)
        let body = alert.scrollViews.containing(exactMessage).firstMatch
        let text = body.staticTexts.matching(exactMessage).firstMatch
        XCTAssertTrue(body.exists)
        XCTAssertTrue(text.exists)
        capture(app, name + "-start")
        body.swipeUp()
        for _ in 0..<3 where text.frame.maxY > body.frame.maxY + 1 { body.swipeUp() }
        XCTAssertLessThanOrEqual(text.frame.maxY, body.frame.maxY + 1, "The end of the complete recovery explanation must be reachable.")
        XCTAssertGreaterThan(text.frame.maxY, body.frame.minY)
        capture(app, name + "-end")
    }

    func testRecordFinishEditsDraftWithoutSendingAndCancelPreservesDraft() {
        let app = launch()
        editor(app).tap()
        editor(app).typeText("Typed first")
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].waitForExistence(timeout: 5))
        checkTargets(app, ["cancelDictation", "finishDictation", "addAttachment"])
        XCTAssertFalse(app.buttons["sendMessage"].exists)
        capture(app, "recording")
        editor(app).tap()
        editor(app).typeText(" with an edit")
        app.buttons["finishDictation"].tap()
        XCTAssertTrue(app.buttons["dictateMessage"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor(app).value as? String, "Typed first with an edit A dictated thought ready to edit.")
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
        XCTAssertFalse(app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "You. Typed first")).firstMatch.exists)
        capture(app, "editable-final-draft")
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].waitForExistence(timeout: 5))
        app.buttons["cancelDictation"].tap()
        XCTAssertEqual(editor(app).value as? String, "Typed first with an edit A dictated thought ready to edit.")
    }

    func testCancelDuringFinalizationAndBackgroundPreserveDraft() {
        let app = launch("held-finalization")
        editor(app).tap()
        editor(app).typeText("Keep this")
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].waitForExistence(timeout: 5))
        app.buttons["finishDictation"].tap()
        let transcribing = app.staticTexts["voiceTranscribing"]
        XCTAssertTrue(transcribing.waitForExistence(timeout: 3))
        XCTAssertEqual(transcribing.label, "Transcribing…")
        XCTAssertTrue(transcribing.isHittable)
        capture(app, "held-transcribing-before-cancel")
        app.buttons["cancelDictation"].tap()
        XCTAssertEqual(editor(app).value as? String, "Keep this")
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["dictateMessage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["finishDictation"].exists)
        XCTAssertEqual(editor(app).value as? String, "Keep this")
        capture(app, "background-canceled")
    }

    func testDownloadAndPermissionRecoveryUseExplicitControls() {
        let app = launch("offline")
        editor(app).tap()
        editor(app).typeText("My draft")
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["downloadVoiceModel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["finishDictation"].exists)
        capture(app, "model-download-prompt")
        app.buttons["downloadVoiceModel"].tap()
        XCTAssertTrue(app.staticTexts["voiceError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["voiceError"].label.contains("storage"))
        XCTAssertEqual(editor(app).value as? String, "My draft")
        capture(app, "model-offline-error")
        app.terminate()
        let denied = launch("denied")
        denied.buttons["dictateMessage"].tap()
        XCTAssertTrue(denied.buttons["voiceSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(denied.buttons["finishDictation"].exists)
        capture(denied, "microphone-denied")
    }

    func testWorkingAgentStopRemainsSeparateAndAttachmentsSurvive() {
        let app = launch(extra: ["--fixture-working", "--fixture-attachment-failed"])
        editor(app).tap()
        editor(app).typeText("Keep the file")
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
        XCTAssertTrue(remove.exists)
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].waitForExistence(timeout: 5))
        checkTargets(app, ["cancelDictation", "finishDictation", "stopAgent"])
        app.buttons["stopAgent"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].exists)
        app.buttons["finishDictation"].tap()
        XCTAssertTrue(app.buttons["dictateMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(remove.exists)
        XCTAssertEqual(editor(app).value as? String, "Keep the file A dictated thought ready to edit.")
        capture(app, "agent-stopped-attachment-preserved")
    }

    func testOpeningConversationsCancelsRecordingBeforeItIsCovered() {
        let app = launch()
        editor(app).tap()
        editor(app).typeText("Keep this draft")
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].waitForExistence(timeout: 5))
        app.buttons["sessions"].tap()
        XCTAssertTrue(app.buttons["dismissConversations"].waitForExistence(timeout: 5))
        app.buttons["dismissConversations"].tap()
        XCTAssertTrue(app.buttons["dictateMessage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["finishDictation"].exists)
        XCTAssertEqual(editor(app).value as? String, "Keep this draft")
        capture(app, "drawer-canceled-recording")
    }

    func testChatSettingsSheetCancelsRecordingAndPreservesDraft() {
        let app = launch()
        editor(app).tap()
        editor(app).typeText("Keep my settings draft")
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].waitForExistence(timeout: 5))
        app.buttons["chatMenu"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture(app, "settings-covering-chat")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
        capture(app, "settings-dismissed-voice-state")
        XCTAssertTrue(app.buttons["dictateMessage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["finishDictation"].exists)
        XCTAssertEqual(editor(app).value as? String, "Keep my settings draft")
    }

    func testLargestTextRecoveryAlertsKeepFullCopyActionsAndDraft() {
        let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        let app = launch("offline", extra: largeText)
        editor(app).tap()
        editor(app).typeText("Keep my draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["dictateMessage"].tap()
        let download = app.alerts["Download speech model"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(download.staticTexts.matching(NSPredicate(format: "label == %@", "Download the English speech model to dictate on this iPhone. Audio stays on your device.")).firstMatch.exists)
        _ = alertButton(download, "Download")
        _ = alertButton(download, "Not now")
        readAlertBody(app, alert: download, message: "Download the English speech model to dictate on this iPhone. Audio stays on your device.", name: "largest-text-download-alert")
        alertButton(download, "Not now").tap()
        XCTAssertTrue(download.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor(app).value as? String, "Keep my draft")
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        alertButton(download, "Download").tap()
        let unavailable = app.alerts["Dictation unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        XCTAssertTrue(unavailable.staticTexts.matching(NSPredicate(format: "label == %@", "The speech model could not be prepared. Check your internet connection and available storage, then try again. Your draft is safe.")).firstMatch.exists)
        _ = alertButton(unavailable, "Dismiss")
        readAlertBody(app, alert: unavailable, message: "The speech model could not be prepared. Check your internet connection and available storage, then try again. Your draft is safe.", name: "largest-text-download-error-alert")
        alertButton(unavailable, "Dismiss").tap()
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor(app).value as? String, "Keep my draft")
        app.terminate()

        let denied = launch("denied", extra: largeText)
        editor(denied).tap()
        editor(denied).typeText("Keep this too")
        XCTAssertTrue(denied.keyboards.firstMatch.exists)
        denied.buttons["dictateMessage"].tap()
        let permission = denied.alerts["Dictation unavailable"]
        XCTAssertTrue(permission.waitForExistence(timeout: 5))
        XCTAssertTrue(permission.staticTexts.matching(NSPredicate(format: "label == %@", "Microphone access is off. Enable it for Hermes Companion in Settings to dictate.")).firstMatch.exists)
        _ = alertButton(permission, "Open Settings")
        _ = alertButton(permission, "Dismiss")
        readAlertBody(denied, alert: permission, message: "Microphone access is off. Enable it for Hermes Companion in Settings to dictate.", name: "largest-text-denied-alert")
        alertButton(permission, "Dismiss").tap()
        XCTAssertTrue(permission.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor(denied).value as? String, "Keep this too")
    }

    func testImmediateDownloadFailurePresentsRecoverableAlert() {
        let app = launch("instant-offline", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        editor(app).tap()
        editor(app).typeText("Keep the immediate draft")
        app.buttons["dictateMessage"].tap()
        let download = app.alerts["Download speech model"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        readAlertBody(app, alert: download, message: "Download the English speech model to dictate on this iPhone. Audio stays on your device.", name: "instant-download-prompt")
        alertButton(download, "Download").tap()
        let failure = app.alerts["Dictation unavailable"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.staticTexts.matching(NSPredicate(format: "label == %@", "The speech model could not be prepared. Check your internet connection and available storage, then try again. Your draft is safe.")).firstMatch.exists)
        _ = alertButton(failure, "Dismiss")
        readAlertBody(app, alert: failure, message: "The speech model could not be prepared. Check your internet connection and available storage, then try again. Your draft is safe.", name: "instant-download-failure")
        alertButton(failure, "Dismiss").tap()
        XCTAssertTrue(failure.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["finishDictation"].exists)
        XCTAssertEqual(editor(app).value as? String, "Keep the immediate draft")
    }

    func testLargeTextVoiceControlsRemainSeparate() {
        let app = launch(extra: ["--fixture-working", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        editor(app).tap()
        editor(app).typeText("A voice draft")
        checkTargets(app, ["dictateMessage", "sendMessage", "stopAgent", "addAttachment"])
        app.buttons["dictateMessage"].tap()
        XCTAssertTrue(app.buttons["finishDictation"].waitForExistence(timeout: 5))
        checkTargets(app, ["cancelDictation", "finishDictation", "stopAgent", "addAttachment"])
        capture(app, "large-text-recording")
        app.buttons["finishDictation"].tap()
        XCTAssertTrue(app.buttons["dictateMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue((editor(app).value as? String ?? "").contains("A dictated thought"))
        capture(app, "large-text-final-draft")
    }
}
