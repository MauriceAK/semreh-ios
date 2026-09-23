import XCTest
import UIKit
import UniformTypeIdentifiers
import Foundation
import CoreFoundation

final class LongChatScrollUITests: XCTestCase {
    func testFullChatActivityLabKeepsDistinctInlineStatusWithoutFloatingPill() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-full-activity-lab"]
        app.launch()

        let chat = app.otherElements["chat-detail:Activity full lab"]
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
        let advance = app.buttons["full-activity-advance"]
        let phase = app.staticTexts["full-activity-phase"]
        let thinking = app.buttons.matching(NSPredicate(format: "label == %@", "Thinking"))
        let additional = app.buttons.matching(NSPredicate(format: "label == %@", "Additional thinking"))
        let preparing = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "Semreh is preparing a response"
        ))
        let search = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search files"))
        let floating = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "Hermes is working"
        ))

        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        XCTAssertTrue(composer.exists && advance.isHittable)
        XCTAssertEqual(phase.label, "full activity phase 0")
        XCTAssertEqual(additional.count, 1, "Unattributed details should remain available separately.")
        XCTAssertEqual(thinking.count, 0, "Additional details must not impersonate the live turn.")
        XCTAssertEqual(preparing.count, 1, "The new run must not print a second Thinking label.")
        XCTAssertEqual(search.count, 0)
        XCTAssertEqual(floating.count, 0)

        // Hold the actual app scene through a full shine cycle. The UI test
        // checks stable AX geometry; a direct Simulator recording checks motion.
        let pendingFrame = preparing.firstMatch.frame
        let shineCycle = expectation(description: "Live status shines without row movement")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { shineCycle.fulfill() }
        wait(for: [shineCycle], timeout: 3)
        XCTAssertEqual(preparing.count, 1)
        XCTAssertEqual(preparing.firstMatch.frame.minY, pendingFrame.minY, accuracy: 1)
        XCTAssertEqual(preparing.firstMatch.frame.height, pendingFrame.height, accuracy: 1)

        advance.tap()
        XCTAssertEqual(phase.label, "full activity phase 1")
        XCTAssertEqual(additional.count, 1)
        XCTAssertEqual(thinking.count, 0)
        XCTAssertEqual(search.count, 1)
        XCTAssertEqual(floating.count, 0)

        advance.tap()
        XCTAssertEqual(phase.label, "full activity phase 2")
        XCTAssertEqual(additional.count, 1)
        XCTAssertEqual(thinking.count, 0)
        XCTAssertEqual(search.count, 1)
        XCTAssertEqual(floating.count, 0)
        XCTAssertTrue(composer.exists)
    }

    func testFullChatActivityAnchorsOlderThinkingBeforeNewTurnAndCurrentToolBesideResponse() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-full-activity-anchored-lab"]
        app.launch()

        let chat = app.otherElements["chat-detail:Activity full lab"]
        let advance = app.buttons["full-activity-advance"]
        let thinking = app.buttons.matching(NSPredicate(format: "label == %@", "Thinking"))
        let additional = app.buttons.matching(NSPredicate(format: "label == %@", "Additional thinking"))
        let currentUser = app.staticTexts["message-row:activity-full-current-user"]
        let currentResponse = app.staticTexts["message-row:activity-full-current-assistant"]
        let search = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search files"))
        let preparing = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "Semreh is preparing a response"
        ))

        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(additional.count, 0)
        XCTAssertEqual(preparing.count, 1, "The new turn must not show a second Thinking label.")
        XCTAssertTrue(currentUser.exists)
        XCTAssertLessThan(thinking.firstMatch.frame.maxY, currentUser.frame.minY,
                          "Old-turn reasoning must stay before the new user turn.")

        advance.tap()
        advance.tap()
        XCTAssertEqual(app.staticTexts["full-activity-phase"].label, "full activity phase 2")
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(search.count, 1)
        XCTAssertEqual(preparing.count, 0)
        XCTAssertTrue(currentResponse.exists)
        XCTAssertLessThan(thinking.firstMatch.frame.maxY, currentUser.frame.minY)
        XCTAssertLessThan(currentUser.frame.maxY, search.firstMatch.frame.minY)
        XCTAssertLessThan(search.firstMatch.frame.maxY, currentResponse.frame.minY)
        XCTAssertLessThan(currentResponse.frame.minY - search.firstMatch.frame.maxY, 40,
                          "The tool disclosure should stay adjacent to its own response.")
    }

    func testAppOwnedActivityHandoffKeepsOneDisclosureAndVisibleTranscript() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-activity-handoff-lab"]
        app.launch()

        let transcript = app.scrollViews["chat-transcript-scroll"]
        let advance = app.buttons["activity-handoff-advance"]
        let phase = app.staticTexts["activity-handoff-phase"]
        let prompt = app.staticTexts["message-row:activity-handoff-current-user"]
        let previousAnswer = app.staticTexts["message-row:activity-handoff-old-assistant"]
        let thinking = app.buttons.matching(NSPredicate(format: "label == %@", "Thinking"))
        let readFile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read file"))

        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        XCTAssertTrue(advance.isHittable && phase.exists)
        XCTAssertTrue(prompt.exists && previousAnswer.exists)
        XCTAssertEqual(phase.label, "activity phase 0")
        XCTAssertEqual(thinking.count, 1, "Retained and live reasoning should share one disclosure.")
        XCTAssertEqual(readFile.count, 1, "The completed read_file action should remain inline.")
        XCTAssertFalse(app.staticTexts["Semreh is preparing a response"].exists,
                       "The ordinary bare status should not duplicate retained activity.")

        let promptFrame = prompt.frame
        let answerFrame = previousAnswer.frame
        let thinkingFrame = thinking.firstMatch.frame
        let readFrame = readFile.firstMatch.frame
        let windowFrame = app.windows.firstMatch.frame
        for frame in [promptFrame, answerFrame, thinkingFrame, readFrame] {
            XCTAssertGreaterThanOrEqual(frame.minX, windowFrame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, windowFrame.maxX + 1)
        }

        // A direct Simulator video records the uninterrupted handoff. Do not
        // ask XCTest to draw hierarchy snapshots while live chunks are arriving.
        let leadIn = expectation(description: "Stable app-window video lead-in")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { leadIn.fulfill() }
        wait(for: [leadIn], timeout: 2)
        advance.tap()
        let settled = expectation(description: "Live chunks finish and retained activity remains")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(phase.label, "activity phase 4")
        XCTAssertTrue(prompt.isHittable && previousAnswer.exists)
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(readFile.count, 1)
        XCTAssertFalse(app.staticTexts["Semreh is preparing a response"].exists)
        XCTAssertEqual(prompt.frame.minY, promptFrame.minY, accuracy: 4,
                       "Collapsed activity updates should not jump the preceding prompt.")
        XCTAssertEqual(previousAnswer.frame.minY, answerFrame.minY, accuracy: 4)
        XCTAssertEqual(thinking.firstMatch.frame.minY, thinkingFrame.minY, accuracy: 4)
        XCTAssertEqual(readFile.firstMatch.frame.minY, readFrame.minY, accuracy: 4)
        for frame in [prompt.frame, previousAnswer.frame, thinking.firstMatch.frame, readFile.firstMatch.frame] {
            XCTAssertGreaterThanOrEqual(frame.minX, windowFrame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, windowFrame.maxX + 1)
        }
        let visibleHold = expectation(description: "Keep scene visible for direct video after handoff")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { visibleHold.fulfill() }
        wait(for: [visibleHold], timeout: 2)
    }

    func testMountedOutgoingMotionFromPopulatedBottomStaysNearComposer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-lab", "--chat-outgoing-motion-lab",
                               "--chat-outgoing-motion-populated"]
        app.launch()

        let transcript = app.scrollViews["chat-transcript-scroll"]
        let priorTail = app.staticTexts["message-row:motion-history-11"]
        let composer = app.textViews["chat-composer-input"]
        let inject = app.buttons["outgoing-motion-inject"]
        let marker = app.staticTexts["outgoing-motion-marker"]
        let outgoing = app.staticTexts["message-row:local-motion-1"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        XCTAssertTrue(priorTail.waitForExistence(timeout: 15) && priorTail.isHittable)
        XCTAssertTrue(composer.isHittable && inject.isHittable)
        XCTAssertEqual(marker.label, "motion marker 0")
        XCTAssertFalse(outgoing.exists)

        // Match the common send state: keyboard open and the old tail visible.
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(priorTail.isHittable)
        let ready = expectation(description: "Near-bottom viewport settles before video marker")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ready.fulfill() }
        wait(for: [ready], timeout: 2)

        let priorTailBottom = priorTail.frame.maxY
        let baselineGap = composer.frame.minY - priorTailBottom
        XCTAssertGreaterThanOrEqual(baselineGap, -4)
        XCTAssertLessThan(baselineGap, 180, "The synthetic history must be near the composer before injection.")

        inject.tap()
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10) && outgoing.isHittable)
        XCTAssertEqual(marker.label, "motion marker 1")
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:local-motion-1").count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:motion-history-11").count, 1)
        let outgoingGap = composer.frame.minY - outgoing.frame.maxY
        XCTAssertGreaterThanOrEqual(outgoingGap, -4)
        XCTAssertLessThan(outgoingGap, 180, "The new bubble must settle beside the composer, not at the transcript top.")
        XCTAssertLessThan(priorTail.frame.maxY, priorTailBottom + 4)
        XCTAssertGreaterThan(priorTail.frame.maxY, priorTailBottom - 200,
                             "Inserting one bubble must not jump the old tail by a viewport.")
    }

    func testMountedOutgoingMotionFixtureKeepsOneBubblePerLocalSend() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-lab", "--chat-outgoing-motion-lab"]
        app.launch()

        let transcript = app.scrollViews["chat-transcript-scroll"]
        let chat = app.otherElements["chat-detail:Outgoing motion lab"]
        let inject = app.buttons["outgoing-motion-inject"]
        let marker = app.staticTexts["outgoing-motion-marker"]
        let first = app.staticTexts["message-row:local-motion-1"]
        let second = app.staticTexts["message-row:local-motion-2"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        XCTAssertTrue(inject.waitForExistence(timeout: 10) && inject.isHittable)
        XCTAssertTrue(marker.exists)
        XCTAssertFalse(first.exists, "The mounted fixture starts with no outgoing row.")

        // Leave the app settled before injection so a separately started
        // app-window video can align its first 300 ms to the marker flip.
        let ready = expectation(description: "Mounted app-window video lead-in")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
        inject.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:local-motion-1").count, 1)
        XCTAssertEqual(marker.label, "motion marker 1")

        inject.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:local-motion-1").count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:local-motion-2").count, 1)
        XCTAssertEqual(marker.label, "motion marker 2")
        XCTAssertTrue(first.isHittable && second.isHittable)
    }

    func testNativeBottomEdgeManualTakeover20And120() {
        exerciseNativeBottomEdgeManualTakeover(singleSettlement: false)
    }

    func testNativeSingleSettlementManualTakeover20And120() {
        exerciseNativeBottomEdgeManualTakeover(singleSettlement: true)
    }

    private func exerciseNativeBottomEdgeManualTakeover(singleSettlement: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        for count in [20, 120] {
            app.terminate()
            app.launchArguments = ["--chat-performance-lab", "--representative-count=\(count)", "--native-baseline", "--native-bottom-edge", "--native-refinement-trace"]
            if singleSettlement { app.launchArguments.append("--native-edge-single-settlement") }
            app.launch()
            let scroll = app.scrollViews["native-baseline-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 15))
            app.buttons["native-baseline-jump"].tap()
            // Submit the real gesture immediately after tap. Phase logs decide
            // whether it overlapped animation; test success alone must not claim it.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2))
                .press(forDuration: 0.01, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.9)), withVelocity: .fast, thenHoldForDuration: 0)
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
            XCTAssertFalse(tail.isHittable, "Manual reading moves away from tail")
            let settled = expectation(description: "Observe no delayed native snap")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { settled.fulfill() }
            wait(for: [settled], timeout: 2)
            XCTAssertFalse(tail.isHittable, "Native bottom intent must not snap back after manual reading")
            attachScreenshot(named: "bottom-edge-manual-\(count)-single-settlement-\(singleSettlement)")
        }
    }

    func testNativeBaselineRepresentative20And120() {
        exerciseRepresentativeNativeControl(native: true)
    }

    func testProductionRepresentative20And120() {
        exerciseRepresentativeNativeControl(native: false)
    }

    private func exerciseRepresentativeNativeControl(native: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        for count in [20, 120] {
            app.terminate()
            app.launchArguments = ["--chat-performance-lab", "--representative-count=\(count)"]
            if native { app.launchArguments.append("--native-baseline") }
            app.launch()
            let scroll = app.scrollViews[native ? "native-baseline-scroll" : "chat-transcript-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 15))
            let arrow = app.buttons[native ? "native-baseline-jump" : scrollToLatestLabel]
            for cycle in 0..<2 {
                if cycle > 0 {
                    scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3))
                        .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.75)))
                }
                XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
                arrow.tap()
                let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
                assertHittable(tail, timeout: 10, message: "Representative\(count) native=\(native) cycle=\(cycle) reaches concrete tail")
                attachScreenshot(named: "representative-\(count)-native-\(native)-cycle-\(cycle)")
            }
        }
    }

    private let performanceLabArgument = "--chat-performance-lab"
    private let performanceCycleLabArgument = "--chat-performance-cycle-lab"
    private let performanceSignpostsArgument = "--chat-performance-signposts"
    private let performanceMetricProbeEnvironment = "SEMREH_CHAT_PERFORMANCE_METRIC_PROBE"
    private let performanceFrameCallbackProbeArgument = "--chat-performance-frame-callback-probe"
    private let performanceFrameCallbackProbeEnvironment = "SEMREH_CHAT_FRAME_CALLBACK_PROBE"
    private let appWidePerformanceMonitorArgument = "--chat-performance-app-wide-monitor"
    private let appWidePerformanceMonitorEnvironment = "SEMREH_CHAT_APP_WIDE_MONITOR_UI"
    private let birdPaletteLabArgument = "--bird-palette-visual-lab"
    private let birdPaletteLabEnvironment = "SEMREH_BIRD_PALETTE_LAB_UI"
    private let approvedLiveOrigin = "https://semreh-slice1-test.tailda8427.ts.net"
    private let approvedLiveHost = "semreh-slice1-test.tailda8427.ts.net"
    private let stockBackendSHA = "29112bef099274229cadff79cdff7bf7b99c4b77"
    private let developmentBackendSHA = "8c50f84522a755d40346e73701a6847fbdde20ec"
    private let stockCredentialsPath = "/Users/maurice/workspace/semreh-slice1-runtime/credentials.json"
    private let stockToolCwd = "/Users/maurice/workspace/semreh-slice1-runtime/tools"
    private let developmentCredentialsPath = "/Users/maurice/workspace/semreh-slice2-runtime/credentials.json"
    private let developmentToolCwd = "/Users/maurice/workspace/semreh-slice2-runtime/tools"
    private let chatIdentifier = "chat-detail:10,000-row performance lab"
    private let scrollToLatestLabel = "Scroll to latest message"
    private let endMarker = "End of 10,000-row conversation."
    private let clarificationSingleMarker = "SEMREH_BLOCKING_CLARIFY"
    private let clarificationMultiSelectMarker = "SEMREH_BLOCKING_CLARIFY_MULTI_SELECT"
    private let clarificationBatchMarker = "SEMREH_BLOCKING_CLARIFY_BATCH"
    private let clarificationCardIdentifier = "direct.clarification.card"
    private let clarificationCancelIdentifier = "direct.clarification.cancel"
    private let singleAnswerAcknowledgement = "SEMREH_SLICE3_CLARIFY_ACK_SINGLE_ANSWER"
    private let singleCancelAcknowledgement = "SEMREH_SLICE3_CLARIFY_ACK_SINGLE_CANCEL"
    private let batchCancelAcknowledgement = "SEMREH_SLICE3_CLARIFY_ACK_BATCH_CANCEL"
    private let multiSelectCancelAcknowledgement = "SEMREH_SLICE3_CLARIFY_ACK_MULTI_SELECT_CANCEL"
    private let blockingApprovalMarker = "SEMREH_BLOCKING_APPROVAL"
    private let blockingSecretMarker = "SEMREH_BLOCKING_SECRET"
    private let blockingApprovalDenyIdentifier = "approval-request-choice-deny"
    private let blockingSecretCancelIdentifier = "direct-sensitive-prompt-cancel"
    private let blockingApprovalAcknowledgement = "SEMREH_SLICE3_BLOCKING_ACK_APPROVAL_DENY"
    private let blockingSecretAcknowledgement = "SEMREH_SLICE3_BLOCKING_ACK_SECRET_CANCEL"
    private let tuiSeedMarker = "SEMREH_TUI_CROSS_CLIENT_1"
    private let slice1Acknowledgement = "SEMREH_SLICE1_ACK"
    private let uncertaintyDelayedPromptPrefix = "SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_PRE_ACK_LOSS_"
    private let uncertaintyNewPromptPrefix = "SEMREH_SLICE3_UNCERTAINTY_NEW_"
    private let uncertaintyBannerIdentifier = "direct-prompt-uncertainty-banner"
    private let uncertaintyAllowIdentifier = "direct-prompt-uncertainty-allow-new-message"

    @MainActor
    func testResponseMotionComponentsCompletion() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The component fixture is simulator-only.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--chat-response-motion-components-lab"]
        app.launch()
        let append = app.buttons["motion-lab-append"]
        let complete = app.buttons["motion-lab-complete"]
        XCTAssertTrue(append.waitForExistence(timeout: 10) && append.isHittable)
        append.tap()
        XCTAssertTrue(complete.isHittable)
        complete.tap()
        XCTAssertEqual(complete.label, "Restart")
        XCTAssertFalse(append.isEnabled)
        let completed = app.staticTexts["Response complete"]
        for _ in 0..<8 {
            if completed.exists && completed.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(completed.exists && completed.isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Component response completed — not production completion evidence"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testOptInBirdPaletteVisualLabScreenshots() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The bird palette visual lab is simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment[birdPaletteLabEnvironment] == "1" else {
            throw XCTSkip("The bird palette visual lab is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [birdPaletteLabArgument]
        app.launch()

        let title = app.staticTexts["Bird palette visual lab"]
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "The server-free bird palette visual lab must launch.")
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5),
                      "The bird palette lab must expose its bounded scroll surface.")

        let light = app.staticTexts["Light appearance"]
        XCTAssertTrue(light.waitForExistence(timeout: 5) && light.isHittable,
                       "The lab must show the light appearance first.")
        attachScreenshot(named: "bird-palette-visual-lab-light")

        let dark = app.staticTexts["Dark appearance"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5),
                      "The lab must include a dark appearance panel.")
        // Move to the bounded end so the dark screenshot contains all eight
        // palette rows rather than only the first rows after one swipe.
        for _ in 0..<3 {
            scrollView.swipeUp()
        }
        attachScreenshot(named: "bird-palette-visual-lab-dark")
    }

    @MainActor
    func testOptInProductionLocalOrganizerCRUDInSessionsAndControl() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("A3 production organizer UI smoke is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_A3_ORGANIZER_UI"] == "1" else {
            throw XCTSkip("A3 production organizer UI smoke is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == stockBackendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == stockCredentialsPath,
              environment["SEMREH_SLICE2_TOOL_CWD"] == stockToolCwd,
              let profile = environment["SEMREH_A2_PROFILE_NAME"], !profile.isEmpty,
              profile != "default",
              let selectedSentinel = environment["SEMREH_A2_SELECTED_SENTINEL"], !selectedSentinel.isEmpty,
              let defaultSentinel = environment["SEMREH_A2_DEFAULT_SENTINEL"], !defaultSentinel.isEmpty
        else {
            XCTFail("A3 opt-in fixture data must identify the exact stock HTTPS fixture, non-default profile, and sentinels.")
            return
        }

        let credentials = try readCredentials(at: stockCredentialsPath)
        let suffix = UUID().uuidString.prefix(8)
        let createdName = "A3 Group \(suffix)"
        let renamedName = "A3 Renamed \(suffix)"
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = []
        app.launch()
        defer { clearPasteboard() }

        prepareNormalSignIn(app: app)
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        if !app.textFields["onboarding-server-url"].exists {
            XCTAssertTrue(welcome.waitForExistence(timeout: 15), "Normal sign-out must return to Welcome.")
            let existingServer = app.buttons["Already have a server?"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5))
            existingServer.tap()
        }
        let serverURL = app.textFields["onboarding-server-url"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        replacePublicText(serverURL, with: approvedLiveOrigin, app: app)
        app.buttons["Test Connection"].tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        replacePublicText(username, with: credentials.username, app: app)
        pasteSecret(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()
        dismissKnownPasswordSavePrompt(app: app)
        waitForPostLoginDestination(app: app)

        addTeardownBlock { @MainActor in
            guard !app.secureTextFields["onboarding-password"].exists else { return }
            self.attachScreenshot(named: "a3-organizer-final")
            self.attachAccessibilitySnapshot(named: "a3-organizer-final-accessibility", app: app)
        }

        app.buttons["Sessions"].tap()
        XCTAssertTrue(app.staticTexts[selectedSentinel].waitForExistence(timeout: 20),
                      "Sessions must show the selected-profile sentinel before organizer interaction.")
        XCTAssertFalse(app.staticTexts[defaultSentinel].exists,
                       "Sessions must not show the default-profile sentinel.")
        let expandSessions = app.buttons["Expand projects"]
        XCTAssertTrue(expandSessions.waitForExistence(timeout: 10))
        expandSessions.tap()
        XCTAssertTrue(app.buttons["Collapse projects"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[createdName].exists, "The synthetic group must be absent before creation.")
        XCTAssertFalse(app.buttons[renamedName].exists, "The synthetic renamed group must be absent before creation.")

        app.buttons["Add project"].tap()
        XCTAssertTrue(app.navigationBars["New Project"].waitForExistence(timeout: 5))
        let newName = app.textFields["Project name"]
        XCTAssertTrue(newName.waitForExistence(timeout: 5))
        newName.tap()
        newName.typeText(createdName)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons[createdName].waitForExistence(timeout: 10))

        app.buttons["Control"].tap()
        let controlExpand = app.buttons["Expand projects"]
        if controlExpand.waitForExistence(timeout: 3) { controlExpand.tap() }
        XCTAssertTrue(app.buttons[createdName].waitForExistence(timeout: 10))
        app.buttons["Project actions for \(createdName)"].tap()
        XCTAssertTrue(app.buttons["Rename Project"].waitForExistence(timeout: 5))
        app.buttons["Rename Project"].tap()
        XCTAssertTrue(app.navigationBars["Rename Project"].waitForExistence(timeout: 5))
        replacePublicText(app.textFields["Project name"], with: renamedName, app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons[renamedName].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[createdName].exists)

        app.terminate()
        app.launch()
        waitForPostLoginDestination(app: app)
        app.buttons["Control"].tap()
        let relaunchExpand = app.buttons["Expand projects"]
        if relaunchExpand.waitForExistence(timeout: 3) { relaunchExpand.tap() }
        XCTAssertTrue(app.buttons[renamedName].waitForExistence(timeout: 10),
                      "The renamed local group must persist across one process relaunch.")

        app.buttons["Project actions for \(renamedName)"].tap()
        XCTAssertTrue(app.buttons["Delete Project"].waitForExistence(timeout: 5))
        app.buttons["Delete Project"].tap()
        let deleteDialog = app.sheets["Delete project?"]
        XCTAssertTrue(deleteDialog.waitForExistence(timeout: 5))
        deleteDialog.buttons["Delete"].tap()
        XCTAssertFalse(app.buttons[renamedName].waitForExistence(timeout: 3),
                       "UI cleanup must remove the synthetic local group.")
    }

    @MainActor
    func testOptInProductionNonDefaultProfileOwnsFirstControlAndSessionsSidebarLoad() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("A2 production UI smoke is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_A2_PROFILE_UI"] == "1" else {
            throw XCTSkip("A2 production UI smoke is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == stockBackendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == stockCredentialsPath,
              environment["SEMREH_SLICE2_TOOL_CWD"] == stockToolCwd,
              let profile = environment["SEMREH_A2_PROFILE_NAME"], !profile.isEmpty,
              profile != "default",
              let selectedSentinel = environment["SEMREH_A2_SELECTED_SENTINEL"], !selectedSentinel.isEmpty,
              let defaultSentinel = environment["SEMREH_A2_DEFAULT_SENTINEL"], !defaultSentinel.isEmpty
        else {
            XCTFail("A2 opt-in fixture data must identify the exact stock HTTPS fixture, profile, and sentinels.")
            return
        }

        let credentials = try readCredentials(at: stockCredentialsPath)
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = []
        app.launch()
        defer { clearPasteboard() }

        prepareNormalSignIn(app: app)
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        if !app.textFields["onboarding-server-url"].exists {
            XCTAssertTrue(welcome.waitForExistence(timeout: 15), "Normal sign-out must return to Welcome.")
            let existingServer = app.buttons["Already have a server?"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5))
            existingServer.tap()
        }
        let serverURL = app.textFields["onboarding-server-url"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        replacePublicText(serverURL, with: approvedLiveOrigin, app: app)
        app.buttons["Test Connection"].tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30), "The approved HTTPS origin must advertise username auth.")
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        replacePublicText(username, with: credentials.username, app: app)
        pasteSecret(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()
        dismissKnownPasswordSavePrompt(app: app)
        waitForPostLoginDestination(app: app)

        for tabName in ["Control", "Sessions"] {
            let tab = app.buttons[tabName]
            assertHittable(tab, timeout: 15, message: "The production shell must expose \(tabName).")
            tab.tap()
            do {
                let evidenceName = "a2-\(tabName.lowercased())-owned-profile-first-load"
                defer {
                    attachScreenshot(named: evidenceName)
                    attachAccessibilitySnapshot(named: "\(evidenceName)-accessibility", app: app)
                }

                // Control exposes utility/profile rows, not chat history.
                // Check first-load session ownership only on the Sessions surface,
                // before interacting with any profile picker.
                if tabName == "Sessions" {
                    XCTAssertTrue(app.staticTexts[selectedSentinel].waitForExistence(timeout: 20),
                                  "Sessions must publish the selected-profile-only row on its first load.")
                    XCTAssertFalse(app.staticTexts[defaultSentinel].exists,
                                   "Sessions must not publish the default-profile sentinel.")
                    continue
                }

                let profileDisclosure = app.buttons["Expand active profile picker"]
                XCTAssertTrue(profileDisclosure.waitForExistence(timeout: 15),
                              "\(tabName) must expose the collapsed active-profile disclosure.")
                profileDisclosure.tap()

                let activeProfile = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Active profile, \(profile),")
                ).firstMatch
                XCTAssertTrue(activeProfile.waitForExistence(timeout: 15),
                              "\(tabName) must identify the fixture profile as active without changing it.")
            }
        }
    }

    func testMuseComposerKeepsDraftAboveKeyboard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--composer-test-fresh-draft"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        // This DEBUG fixture starts with an empty draft without modifying
        // any persisted drafts from earlier simulator sessions.
        let clearedDraft = (composer.value as? String) ?? ""
        XCTAssertTrue(clearedDraft.isEmpty || clearedDraft == composer.placeholderValue)
        composer.typeText("A short draft\nwith a second line")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 1)
        XCTAssertTrue(app.buttons["Composer options"].isHittable)
        let send = app.buttons["Send"]
        let voice = app.buttons["Voice input"]
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(voice.isHittable)
        let twoLineSendY = send.frame.midY
        let twoLineVoiceY = voice.frame.midY
        XCTAssertLessThanOrEqual(abs(twoLineSendY - twoLineVoiceY), 3,
                                 "Send and microphone must share a stable baseline at two lines.")
        attachScreenshot(named: "muse-composer-keyboard-two-lines")

        composer.typeText("\nthird line\nfourth line")
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 1)
        XCTAssertGreaterThanOrEqual(composer.frame.height, 80,
                                    "Four draft lines should expand the text field instead of clipping it.")
        XCTAssertTrue(send.isHittable && voice.isHittable)
        XCTAssertLessThanOrEqual(abs(send.frame.midY - voice.frame.midY), 3,
                                 "The controls must stay aligned as the draft grows.")
        XCTAssertGreaterThan(send.frame.midY, twoLineSendY - 8,
                             "Growing the draft must not move the controls upward into the text.")
        attachScreenshot(named: "muse-composer-keyboard-four-lines")
        // No send: this fixture deliberately has no gateway or credentials.
    }

    func testTenThousandRowChatScrollsAndScrollToLatestReachesEndMarker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Do not inherit a unit-test host or a previous ordinary app launch.
        app.terminate()
        app.launchArguments = [performanceLabArgument]
        app.launch()

        let chat = app.otherElements[chatIdentifier]
        XCTAssertTrue(
            chat.waitForExistence(timeout: 15),
            "The server-free 10,000-row ChatView performance lab must launch."
        )
        attachScreenshot(named: "long-chat-before-scroll")
        // The SwiftUI grouping container need not itself expose a hit point;
        // interact with the actual transcript scroll view inside it.
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(transcript.isHittable, "The transcript scroll view must be interactive.")

        let scrollToLatest = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(
            scrollToLatest.waitForExistence(timeout: 10),
            "A restored mid-history viewport must expose the scroll-to-latest action."
        )

        // Exercise a real user scroll before using the recovery affordance. The
        // performance lab is deliberately static: this test proves lazy rendering
        // and bottom navigation only, not direct transport, sending, or tab routing.
        transcript.swipeUp()
        XCTAssertTrue(
            app.buttons[scrollToLatestLabel].waitForExistence(timeout: 5),
            "The scroll-to-latest action must remain available after a real swipe."
        )
        attachScreenshot(named: "long-chat-after-swipe")

        app.buttons[scrollToLatestLabel].tap()

        let endMarker = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", self.endMarker)
        ).firstMatch
        let reachedEnd = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: endMarker
        )
        wait(for: [reachedEnd], timeout: 25)
        XCTAssertTrue(
            endMarker.exists && endMarker.isHittable,
            "Tapping Scroll to latest message must make the deterministic end marker visible and hittable."
        )
        XCTAssertFalse(
            app.buttons[scrollToLatestLabel].waitForExistence(timeout: 2),
            "The scroll-to-latest action must clear after the viewport reaches the bottom."
        )
        attachScreenshot(named: "long-chat-after-scroll-to-latest")
    }

    func testTallMixedTranscriptRepeatedArrowReachesConcreteTail() {
        exerciseTallMixedTranscriptArrow(disableHighlighting: false)
    }

    func testFourTallMixedTranscriptColdManualArrowAndReopenDiagnostic() {
        continueAfterFailure = true
        let app = XCUIApplication()
        let terminalText = "End of four-row mixed conversation."

        for followsLatest in [false, true] {
            let args = ["--chat-performance-four-tall-lab", "--chat-viewport-diagnostic",
                        "--composer-test-fresh-draft"]
                + (followsLatest ? ["--chat-viewport-follow-latest-open"] : [])
            for visit in 1...2 {
                app.terminate()
                app.launchArguments = args
                print("FOUR_TALL_LAUNCH latest=\(followsLatest) visit=\(visit) epoch=\(Date().timeIntervalSince1970)")
                app.launch()
                let scroll = app.scrollViews["chat-transcript-scroll"]
                XCTAssertTrue(scroll.waitForExistence(timeout: 15))
                let firstRow = app.staticTexts["message-row:four-tall-message-0"]
                let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", terminalText)).firstMatch
                let firstReadable = followsLatest
                    ? tail.waitForExistence(timeout: 20) && tail.isHittable
                    : firstRow.waitForExistence(timeout: 20) && firstRow.isHittable
                print("FOUR_TALL_FIRST_READABLE latest=\(followsLatest) visit=\(visit) visible=\(firstReadable) epoch=\(Date().timeIntervalSince1970)")
                XCTAssertTrue(firstReadable, "Cold viewport must show its real selected row")
                guard visit == 1 else { continue }

                let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: followsLatest ? 0.25 : 0.82))
                let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: followsLatest ? 0.78 : 0.18))
                print("FOUR_TALL_MANUAL_BEGIN latest=\(followsLatest) epoch=\(Date().timeIntervalSince1970)")
                start.press(forDuration: 0.05, thenDragTo: end)
                print("FOUR_TALL_MANUAL_END latest=\(followsLatest) epoch=\(Date().timeIntervalSince1970)")
                let arrow = app.buttons[scrollToLatestLabel]
                XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
                if arrow.exists && arrow.isHittable {
                    print("FOUR_TALL_ARROW_TAP latest=\(followsLatest) epoch=\(Date().timeIntervalSince1970)")
                    arrow.tap()
                    let reachedTail = tail.waitForExistence(timeout: 20) && tail.isHittable
                    print("FOUR_TALL_ARROW_TAIL latest=\(followsLatest) visible=\(reachedTail) epoch=\(Date().timeIntervalSince1970)")
                    XCTAssertTrue(reachedTail, "Arrow must expose the real final rich source")
                }
            }
        }
        app.terminate()
    }

    func testFourTallCodePreviewOpensSelectableFullSource() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-four-tall-lab", "--chat-viewport-follow-latest-open",
                               "--chat-viewport-diagnostic", "--composer-test-fresh-draft"]
        print("FOUR_TALL_PREVIEW_LAUNCH epoch=\(Date().timeIntervalSince1970)")
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "End of four-row mixed conversation."
        )).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 20) && tail.isHittable,
                      "A previewed giant code block must not blank the cold real tail.")
        print("FOUR_TALL_PREVIEW_FIRST_READABLE epoch=\(Date().timeIntervalSince1970)")
        attachScreenshot(named: "four-tall-preview-cold-tail")

        let viewFull = app.buttons["view-full-code"].firstMatch
        for _ in 0..<8 where !viewFull.isHittable {
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.24))
                .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.78)))
        }
        XCTAssertTrue(viewFull.isHittable && viewFull.label.contains("View full code"),
                      "The compact code preview must expose an explicit full-source action.")
        viewFull.tap()
        let fullCode = app.textViews["full-code-text"]
        XCTAssertTrue(fullCode.waitForExistence(timeout: 10) && fullCode.isHittable)
        let source = fullCode.value as? String ?? ""
        XCTAssertTrue(source.contains("SEMREH_FOUR_TALL_CODE_END"),
                      "The selectable viewer must expose the actual last code line in AX.")
        XCTAssertEqual(source.components(separatedBy: "let value = Array(0..<1_000).reduce(0, +)").count - 1, 320)
        app.buttons["Copy full code"].tap()
        // The UI test runner cannot synchronously read the app's pasteboard on
        // this Simulator runtime. The production action assigns `content`
        // directly; the viewer's AX value above checks that full source.
        let sheetToolbar = app.navigationBars["Swift"]
        XCTAssertTrue(sheetToolbar.waitForExistence(timeout: 5))
        let enableWrap = sheetToolbar.buttons["Enable code line wrapping"]
        let disableWrap = sheetToolbar.buttons["Disable code line wrapping"]
        let inlineWrap = transcript.buttons["Enable code line wrapping"]
        XCTAssertFalse(inlineWrap.isHittable,
                       "The code block behind the modal sheet must not intercept its toolbar controls.")
        let initiallyWrapped = disableWrap.exists
        (initiallyWrapped ? disableWrap : enableWrap).tap()
        XCTAssertTrue((initiallyWrapped ? enableWrap : disableWrap).waitForExistence(timeout: 5))
        (initiallyWrapped ? enableWrap : disableWrap).tap()
        XCTAssertEqual(fullCode.value as? String, source,
                       "Wrap toggles must not change selectable code bytes.")
        fullCode.press(forDuration: 1)
        XCTAssertTrue(app.menuItems["Copy"].exists || app.buttons["Copy"].exists,
                      "The full-code text view must offer native text selection.")
        attachScreenshot(named: "four-tall-full-code-selection")

        app.buttons["Done"].tap()
        let dragStart = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.25))
        let dragEnd = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.78))
        print("FOUR_TALL_PREVIEW_MANUAL_BEGIN epoch=\(Date().timeIntervalSince1970)")
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        print("FOUR_TALL_PREVIEW_MANUAL_END epoch=\(Date().timeIntervalSince1970)")
        attachScreenshot(named: "four-tall-preview-after-manual-drag")
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
        print("FOUR_TALL_PREVIEW_ARROW_TAP epoch=\(Date().timeIntervalSince1970)")
        arrow.tap()
        XCTAssertTrue(tail.waitForExistence(timeout: 10) && tail.isHittable,
                      "Closing the full-code viewer must preserve the real transcript tail.")
        print("FOUR_TALL_PREVIEW_ARROW_TAIL epoch=\(Date().timeIntervalSince1970)")
        attachScreenshot(named: "four-tall-preview-return-tail")
    }

    func testTallMixedTranscriptWithoutHighlightingReachesConcreteTail() {
        exerciseTallMixedTranscriptArrow(disableHighlighting: true)
    }

    func testViewportPrototypeTallMixedRepeatedArrow() {
        exerciseTallMixedTranscriptArrow(disableHighlighting: false, prototype: true)
    }

    func testViewportPrototypeTenThousandRows() {
        exerciseViewportPrototypeTenThousandRows()
    }

    func testOptInStableViewportRepresentative120AndTenThousandRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for count in [120, 10_000] {
            app.terminate()
            app.launchArguments = [performanceLabArgument, "--chat-stable-viewport"]
            if count == 120 { app.launchArguments.append("--representative-count=120") }
            app.launch()
            let scroll = app.scrollViews["prototype-transcript-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 15), "Production-compiled viewport must be active in normal ChatView.")
            let arrow = app.buttons["Prototype scroll to latest"]
            XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
            arrow.tap()
            let marker = count == 120 ? "Representative conversation complete." : endMarker
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
            assertHittable(tail, timeout: 15, message: "Stable viewport must reach the concrete \(count)-row tail.")
            XCTAssertFalse(arrow.waitForExistence(timeout: 2))
            attachScreenshot(named: "stable-viewport-\(count)-tail")
        }
    }

    func testOptInSingleNativeRichRepresentativeRowIsMountedInChatView() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120", "--chat-stable-viewport", "--native-rich-row-prototype"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
        arrow.tap()
        let native = app.otherElements["native-rich-row-mounted"]
        XCTAssertTrue(native.waitForExistence(timeout: 15), "One native rich row must replace MarkdownUI in normal ChatView.")
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 15, message: "Native rich row must expose the concrete 120-row tail.")
        attachScreenshot(named: "native-rich-one-row-120-tail")
        let copy = native.buttons["Copy code"].firstMatch
        for _ in 0..<5 {
            if copy.isHittable { break }
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.28))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.76)))
        }
        if !copy.isHittable { print("NATIVE_RICH_AX_COPY \(native.debugDescription)") }
        XCTAssertTrue(copy.isHittable, "Code Copy must be reachable in the mounted native row.")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied code"].firstMatch.waitForExistence(timeout: 3))
        attachScreenshot(named: "native-rich-one-row-code-interaction")
        let codeLine = native.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        if !codeLine.isHittable { print("NATIVE_RICH_AX_LINE \(native.debugDescription)") }
        XCTAssertTrue(codeLine.isHittable, "Native code must expose its visible text for response actions.")
        codeLine.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let fullText = selection.value as? String ?? ""
        XCTAssertTrue(fullText.contains("## Response 119"))
        XCTAssertTrue(fullText.contains("Representative conversation complete."))
    }

    func testOptInDirectTwoRowsPreserveActionsAndDisclosureFallback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-two-row-proof",
                               "--native-rich-lifecycle-fixture"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        let assistant = app.otherElements.containing(.staticText, identifier: "message-row:representative-119")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        let outgoing = app.otherElements.containing(.staticText, identifier: "message-row:representative-118")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        if !assistant.waitForExistence(timeout: 15) { print("DIRECT_TWO_AX \(app.debugDescription)") }
        XCTAssertTrue(assistant.exists, "The rich assistant must mount as a direct row in real ChatView")
        XCTAssertTrue(outgoing.exists, "The adjacent outgoing bubble must mount directly")
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-119").count, 1,
                       "VoiceOver must not announce two response summaries")
        let tail = assistant.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 10, message: "Direct response tail must be visible")
        attachScreenshot(named: "direct-two-tail")
        let originalHeight = assistant.frame.height
        app.buttons["Refresh rows"].tap()
        XCTAssertTrue(assistant.exists, "Unchanged render-revision bump must not tear down a direct row")
        XCTAssertEqual(assistant.frame.height, originalHeight, accuracy: 0.1,
                       "Equivalent cache revision must not cause a second height motion")
        assertHittable(tail, timeout: 10, message: "Revision refresh must preserve the visible response")

        let copyCode = assistant.buttons["Copy code"]
        XCTAssertTrue(copyCode.exists, "Code Copy must be exposed in the direct row AX tree: \(assistant.debugDescription)")
        XCTAssertTrue(copyCode.isHittable, "Code Copy must be available; frame=\(copyCode.frame) row=\(assistant.frame) tree=\(assistant.debugDescription)")
        copyCode.tap()
        XCTAssertTrue(assistant.buttons["Copied code"].waitForExistence(timeout: 3))
        let codeLine = assistant.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(codeLine.isHittable)
        codeLine.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3),
                      "The direct row must preserve full-response Select Text")
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let selectedSource = selection.value as? String ?? ""
        XCTAssertTrue(selectedSource.contains("## Response 119"))
        XCTAssertTrue(selectedSource.contains("Representative conversation complete."))
        app.buttons["Done"].firstMatch.tap()

        let thinking = assistant.buttons["Thinking"]
        XCTAssertTrue(thinking.isHittable, "Collapsed thinking must have a real disclosure control")
        thinking.tap()
        XCTAssertFalse(assistant.exists, "Unsupported expanded detail must visibly fall back to the old row")
        let detail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Check the relevant evidence and explain the result.")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "Fallback must expand actual reasoning detail")
        let fallbackTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(fallbackTail, timeout: 10, message: "Disclosure fallback must preserve bottom reader anchor")
        attachScreenshot(named: "direct-two-expanded-thinking-fallback")
    }

    func testOptInBasicFirstVisibleRowsPreserveReadableActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "First readable response must mount native before the first frame")
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-1").count, 1)
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable)
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "A readable explanation with")).firstMatch.isHittable)
        for cell in ["Check", "State", "Rendering", "Ready"] {
            XCTAssertTrue(first.staticTexts[cell].exists, "Parsed table cell \(cell) must be visible and accessible")
        }
        let bodyCanvas = first.otherElements["native-rich-row"].firstMatch
        XCTAssertTrue(bodyCanvas.exists)
        XCTAssertFalse(bodyCanvas.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "| --- | --- |")).firstMatch.exists,
            "The table separator must not leak into visible body lines (the full-source AX summary stays intact)")
        attachScreenshot(named: "direct-basic-first-readable")

        let copyButtons = first.buttons.matching(identifier: "Copy code")
        XCTAssertEqual(copyButtons.count, 1, "The Swift block must retain its dedicated Copy control")
        XCTAssertTrue(copyButtons.element(boundBy: 0).isHittable)
        copyButtons.element(boundBy: 0).tap()
        XCTAssertTrue(first.buttons["Copied code"].waitForExistence(timeout: 3))

        let codeLine = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(codeLine.isHittable)
        codeLine.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let source = selection.value as? String ?? ""
        XCTAssertTrue(source.contains("## Response 1"))
        XCTAssertTrue(source.contains("| Check | State |"))
        XCTAssertTrue(source.contains("Continue the review."))
        app.buttons["Done"].firstMatch.tap()

        let thinking = first.buttons["Thinking"]
        XCTAssertTrue(thinking.isHittable)
        let collapsedHeight = first.frame.height
        let anchoredTop = first.frame.minY
        thinking.tap()
        XCTAssertTrue(first.exists, "Thinking expansion must retain the native row")
        let detailFirstLine = first.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Check the relevant evidence")).firstMatch
        let detailLastLine = first.staticTexts["result."]
        XCTAssertTrue(detailFirstLine.waitForExistence(timeout: 10),
                      "Expanded Thinking source must expose its first visible line to AX")
        XCTAssertTrue(detailLastLine.isHittable, "Expanded Thinking must expose its wrapped continuation")
        XCTAssertEqual(detailFirstLine.label + detailLastLine.label,
                       "Check the relevant evidence and explain the result.",
                       "AX line order must reconstruct the canonical reasoning source")
        XCTAssertGreaterThan(first.frame.height, collapsedHeight + 10)
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5,
                       "Disclosure must preserve the first visible row anchor")
        attachScreenshot(named: "direct-basic-native-thinking-expanded")
        first.buttons["Thinking"].tap()
        XCTAssertTrue(detailFirstLine.waitForNonExistence(timeout: 10))
        XCTAssertTrue(detailLastLine.waitForNonExistence(timeout: 10))
        XCTAssertEqual(first.frame.height, collapsedHeight, accuracy: 0.5,
                       "Repeating disclosure must return to the exact cached collapsed geometry")
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
            .press(forDuration: 0.06,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(first.frame.minY, anchoredTop - 30,
                          "Vertical drag inside the native response must move its parent transcript")
    }

    func testOptInPremountRichFirstRowSemanticAndInteractionGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-link-bidi"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-1").count, 1)
        let initialHeight = first.frame.height
        XCTAssertTrue(first.staticTexts["Response 1"].exists)
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "العربية تبدأ السطر")).firstMatch.exists)
        for cell in ["Check", "State", "Rendering", "Ready"] {
            XCTAssertTrue(first.staticTexts[cell].exists, "Direct-AST table cell \(cell) must retain AX")
        }
        XCTAssertTrue(first.buttons["Copy code"].exists)
        let link = first.links["Reference source"]
        XCTAssertTrue(link.exists, "Link must be independently discoverable by VoiceOver")
        XCTAssertTrue(link.isHittable, "Prepared link must be visible at its measured rect")
        link.tap() // The synthetic URL is intercepted by the DEBUG fixture, not opened externally.
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5,
                       "Link activation must not remount or refine the prepared row")
        attachScreenshot(named: "premount-rich-first-collapsed")

        let code = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(code.exists)
        code.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let source = selection.value as? String ?? ""
        XCTAssertTrue(source.contains("## Response 1"))
        XCTAssertTrue(source.contains("| Check | State |"))
        XCTAssertTrue(source.contains("[Reference source](https://example.invalid/reference)"))
        app.buttons["Done"].firstMatch.tap()

        let thinking = first.buttons["Thinking"]
        XCTAssertTrue(thinking.exists)
        thinking.tap()
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Check the relevant evidence")).firstMatch.exists)
        XCTAssertGreaterThan(first.frame.height, initialHeight + 10)
        attachScreenshot(named: "premount-rich-first-thinking")
        thinking.tap()
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
            .press(forDuration: 0.06,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(first.frame.minY, 0,
                          "Vertical drag on rich row must move the parent transcript")
    }

    func testOptInPremountRichFirstRowCombinedActivityAndGeometryGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-link-bidi",
                               "--native-direct-two-tool-first-fixture"]
        app.launch()
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15), "The first rich assistant must mount natively.")
        let initialHeight = first.frame.height
        let initialTop = first.frame.minY
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5,
                           "A premounted first row must not visibly swap heights while idle.")
        }
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-1").count, 1)
        XCTAssertTrue(first.staticTexts["Response 1"].exists)
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "العربية تبدأ السطر")).firstMatch.exists)
        for cell in ["Check", "State", "Rendering", "Ready"] {
            XCTAssertTrue(first.staticTexts[cell].exists, "The native table must expose \(cell).")
        }
        let link = first.links["Reference source"]
        XCTAssertTrue(link.isHittable)
        link.tap() // The DEBUG fixture intercepts this synthetic URL.
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        XCTAssertTrue(first.buttons["Copy code"].exists)
        let read = first.buttons["native-tool-action-first-action-read"]
        let search = first.buttons["native-tool-action-first-action-search"]
        XCTAssertTrue(read.isHittable && search.isHittable)
        XCTAssertTrue(first.buttons["Thinking"].isHittable)
        attachScreenshot(named: "native-one-row-combined-collapsed")

        first.buttons["Copy code"].tap()
        XCTAssertTrue(first.buttons["Copied code"].waitForExistence(timeout: 3))
        let code = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(code.isHittable)
        code.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let source = selection.value as? String ?? ""
        XCTAssertTrue(source.contains("## Response 1"))
        XCTAssertTrue(source.contains("| Check | State |"))
        XCTAssertTrue(source.contains("[Reference source](https://example.invalid/reference)"))
        app.buttons["Done"].firstMatch.tap()

        first.buttons["Thinking"].tap()
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Check the relevant evidence")).firstMatch.exists)
        XCTAssertGreaterThan(first.frame.height, initialHeight + 10)
        XCTAssertEqual(first.frame.minY, initialTop, accuracy: 0.5)
        first.buttons["Thinking"].tap()
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        read.tap()
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "fixtures/research.md")).firstMatch.exists)
        XCTAssertEqual(first.buttons.matching(identifier: "Copy code").count, 2)
        XCTAssertGreaterThan(first.frame.height, initialHeight + 20)
        XCTAssertEqual(first.frame.minY, initialTop, accuracy: 0.5)
        search.tap()
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "synthetic research question")).firstMatch.exists)
        XCTAssertGreaterThan(first.frame.height, initialHeight + 50)
        XCTAssertEqual(first.frame.minY, initialTop, accuracy: 0.5)
        attachScreenshot(named: "native-one-row-combined-activity-expanded")
        read.tap()
        search.tap()
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        XCTAssertEqual(first.frame.minY, initialTop, accuracy: 0.5)
        XCTAssertTrue(first.exists, "Disclosures must not fall back to a legacy host.")
    }

    func testDebugNativeRichGroupedParityAndPreviewCard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-link-bidi",
                               "--native-direct-two-tool-first-fixture", "--native-direct-parity-gate"]
        app.launch()
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let group = first.buttons["native-tool-action-__native_group__"]
        XCTAssertTrue(group.isHittable)
        XCTAssertEqual(group.label, "2 actions")
        XCTAssertEqual(group.value as? String, "Completed")
        XCTAssertFalse(first.buttons["native-tool-action-first-action-read"].exists)
        let preview = first.buttons["Link preview for example.invalid"]
        XCTAssertTrue(preview.exists, "The exact product preview host must mount in the native row")
        attachScreenshot(named: "native-grouped-parity-collapsed")
        group.tap()
        XCTAssertTrue(first.buttons["native-tool-action-first-action-read"].exists)
        XCTAssertTrue(first.buttons["native-tool-action-first-action-search"].exists)
        attachScreenshot(named: "native-grouped-parity-expanded")
        group.tap()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 0.12,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58)),
                   withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(preview.isHittable)
        attachScreenshot(named: "native-grouped-parity-preview")
    }

    func testOptInPremountRichFirstRowLongCodeWrapGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-wrap-long"]
        app.launch()
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        if first.buttons["Disable code line wrapping"].exists {
            first.buttons["Disable code line wrapping"].tap()
        }
        let enable = first.buttons["Enable code line wrapping"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        let unwrappedHeight = first.frame.height
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "FAR_END_MARKER")).firstMatch.exists)
        enable.tap()
        XCTAssertTrue(first.buttons["Disable code line wrapping"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(first.frame.height, unwrappedHeight + 50)
        attachScreenshot(named: "premount-rich-first-wrapped")
        first.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(first.buttons["Enable code line wrapping"].waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.height, unwrappedHeight, accuracy: 0.5,
                       "Alternate actor snapshot must return to its exact cached height")
    }

    func testOptInPremountFourRowWindowPreviewWrapAndWidth() {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-premount-window-gate",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-link-bidi",
                               "--native-direct-premount-rich-wrap-long"]
        app.launch()
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let initialWidth = first.frame.width
        let initialHeight = first.frame.height
        let preview = first.buttons["Link preview for example.invalid"]
        XCTAssertTrue(preview.exists, "The existing preview card must remain separately accessible")
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable,
                      "The synthetic preview tap must stay inside the chat fixture")
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable)
        attachScreenshot(named: "premount-window-preview-portrait")

        if first.buttons["Disable code line wrapping"].exists {
            first.buttons["Disable code line wrapping"].tap()
        }
        let enable = first.buttons["Enable code line wrapping"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        let unwrappedHeight = first.frame.height
        enable.tap()
        XCTAssertTrue(first.buttons["Disable code line wrapping"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(first.frame.height, unwrappedHeight + 50)
        XCTAssertTrue(preview.exists, "Wrap must retain the reserved preview card")
        first.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(first.buttons["Enable code line wrapping"].waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.height, unwrappedHeight, accuracy: 0.5)
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)

        func waitForWidth(_ predicate: (CGFloat) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if predicate(first.frame.width) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            return false
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForWidth { $0 > initialWidth + 100 })
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-1").count, 1)
        XCTAssertTrue(first.staticTexts["Response 1"].exists)
        XCTAssertTrue(preview.exists)
        attachScreenshot(named: "premount-window-preview-landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForWidth { $0 < initialWidth + 1 })
        let portraitDeadline = Date().addingTimeInterval(5)
        while abs(first.frame.height - initialHeight) >= 0.5 && Date() < portraitDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable)
        XCTAssertTrue(preview.exists)
        attachScreenshot(named: "premount-window-preview-return-portrait")
    }

    func testOptInFirstVisibleNativeToolActionsExpandIndependently() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic",
                               "--native-direct-two-tool-first-fixture"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let read = first.buttons["native-tool-action-first-action-read"]
        let search = first.buttons["native-tool-action-first-action-search"]
        XCTAssertTrue(read.isHittable)
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(read.label, "Read file")
        XCTAssertEqual(search.label, "Search web")
        XCTAssertEqual(read.value as? String, "Completed")
        XCTAssertEqual(first.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "native-tool-action-")).count, 2,
            "There must be one compact disclosure per action, not a duplicate group summary")
        let collapsedHeight = first.frame.height
        let anchoredTop = first.frame.minY
        attachScreenshot(named: "direct-two-tool-collapsed")

        read.tap()
        let path = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "fixtures/research.md")).firstMatch
        let readResult = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Read the synthetic research note.")).firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 10), "Read-file arguments must be native AX text")
        XCTAssertTrue(readResult.exists, "Read-file result must be native AX text")
        XCTAssertEqual(first.buttons.matching(identifier: "Copy code").count, 2,
                       "Tool detail and response code need separate Copy controls")
        first.buttons.matching(identifier: "Copy code").firstMatch.tap()
        XCTAssertTrue(first.buttons["Copied code"].waitForExistence(timeout: 3))
        XCTAssertGreaterThan(first.frame.height, collapsedHeight + 50)
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5)
        XCTAssertTrue(search.isHittable, "The second action must remain directly reachable")
        let afterReadHeight = first.frame.height
        search.tap()
        let query = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "synthetic research question")).firstMatch
        let searchResult = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Two synthetic source matches found.")).firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        XCTAssertTrue(searchResult.exists)
        XCTAssertTrue(path.exists, "Opening the second action must not discard the first")
        XCTAssertGreaterThan(first.frame.height, afterReadHeight + 50)
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5)
        attachScreenshot(named: "direct-two-tool-expanded")

        read.tap()
        XCTAssertTrue(path.waitForNonExistence(timeout: 10))
        XCTAssertTrue(query.exists, "The other action must stay expanded independently")
        search.tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 10))
        XCTAssertEqual(first.frame.height, collapsedHeight, accuracy: 0.5)
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.06,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(first.frame.minY, anchoredTop - 30,
                          "Vertical drag on a tool-rich row must move the transcript")
    }

    func testOptInDirectTwoRowsLongCodeWrapAndVerticalDrag() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-two-row-proof",
                               "--native-rich-wrap-fixture"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        app.buttons["Prototype scroll to latest"].tap()
        let assistant = app.otherElements.containing(.staticText, identifier: "message-row:representative-119")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 15))
        let tail = assistant.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 10, message: "Direct long-code tail must be present")
        if assistant.buttons["Disable code line wrapping"].exists {
            assistant.buttons["Disable code line wrapping"].tap()
        }
        let enable = assistant.buttons["Enable code line wrapping"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        let originalHeight = assistant.frame.height
        let codeLine = assistant.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "FAR_END_MARKER")).firstMatch
        XCTAssertTrue(codeLine.exists)
        func horizontalOffset() -> Int {
            let words = (enable.value as? String ?? "").split(separator: " ")
            return words.count > 2 ? (Int(words[2]) ?? -1) : -1
        }
        XCTAssertEqual(horizontalOffset(), 0)
        let start = assistant.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.58))
        let end = assistant.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.58))
        for _ in 0..<10 { start.press(forDuration: 0.06, thenDragTo: end) }
        XCTAssertGreaterThan(horizontalOffset(), 500,
                             "Horizontal pan must move the actual code scroller, not merely keep its button visible")
        XCTAssertTrue(enable.isHittable)
        attachScreenshot(named: "direct-two-long-code-panned")

        enable.tap()
        XCTAssertTrue(assistant.buttons["Disable code line wrapping"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(assistant.frame.height, originalHeight + 50,
                             "Wrap must grow the direct measured row")
        assertHittable(tail, timeout: 10, message: "Wrapped direct row must retain the bottom anchor")
        attachScreenshot(named: "direct-two-long-code-wrapped")
        assistant.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(assistant.buttons["Enable code line wrapping"].waitForExistence(timeout: 10))
        assertHittable(tail, timeout: 10, message: "Second toggle must keep the tail")
        let beforeVertical = tail.frame.minY
        assistant.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(forDuration: 0.06,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertGreaterThan(tail.frame.minY - beforeVertical, 30,
                             "Vertical drag inside direct code must move parent transcript")
    }

    func testOptInNativeRichLongCodeWrapPanAndSavedPreference() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let arguments = [performanceLabArgument, "--representative-count=120", "--chat-stable-viewport",
                         "--native-rich-row-prototype", "--native-rich-wrap-fixture"]
        app.launchArguments = arguments
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        let native = app.otherElements["native-rich-row-mounted"]
        XCTAssertTrue(native.waitForExistence(timeout: 15))
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 15, message: "Unwrapped long code must not hide the tail")

        // Persisted preference can be left enabled by a previous failed run.
        if native.buttons["Disable code line wrapping"].exists {
            native.buttons["Disable code line wrapping"].tap()
        }
        let enable = native.buttons["Enable code line wrapping"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        let unwrappedHeight = native.frame.height
        attachScreenshot(named: "native-rich-long-code-unwrapped-start")
        let longCodeLine = native.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "FAR_END_MARKER")).firstMatch
        XCTAssertTrue(longCodeLine.exists)
        let codeLineStartX = longCodeLine.frame.minX
        let start = native.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.56))
        let end = native.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.56))
        for _ in 0..<10 { start.press(forDuration: 0.06, thenDragTo: end) }
        XCTAssertLessThan(longCodeLine.frame.minX, codeLineStartX - 500,
                          "Mounted code AX geometry must shift with the visible horizontal pan")
        attachScreenshot(named: "native-rich-long-code-unwrapped-panned")
        XCTAssertTrue(enable.isHittable, "Horizontal code pan must leave header control reachable")

        enable.tap()
        let disable = native.buttons["Disable code line wrapping"]
        XCTAssertTrue(disable.waitForExistence(timeout: 10), "Preprepared wrapped snapshot must remain native")
        XCTAssertGreaterThan(native.frame.height, unwrappedHeight + 50, "Wrapped code must grow the measured row")
        assertHittable(tail, timeout: 10, message: "Wrap reflow must preserve bottom reader anchor")
        attachScreenshot(named: "native-rich-long-code-wrapped")
        let copy = native.buttons["Copy code"]
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(native.buttons["Copied code"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        app.buttons["Prototype scroll to latest"].tap()
        let reopened = app.otherElements["native-rich-row-mounted"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 15))
        XCTAssertTrue(reopened.buttons["Disable code line wrapping"].waitForExistence(timeout: 10),
                      "Reopen must honor persisted code wrapping")
        reopened.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(reopened.buttons["Enable code line wrapping"].waitForExistence(timeout: 10))
        assertHittable(tail, timeout: 10, message: "Second toggle must preserve bottom reader anchor")
        let beforeVertical = tail.frame.minY
        print("NATIVE_RICH_VERTICAL_BEFORE native=\(reopened.frame) scroll=\(scroll.frame) tailY=\(beforeVertical)")
        reopened.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(forDuration: 0.06, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .fast, thenHoldForDuration: 0)
        let afterVertical = tail.frame.minY
        print("NATIVE_RICH_VERTICAL_AFTER tailY=\(afterVertical)")
        XCTAssertGreaterThan(afterVertical - beforeVertical, 30,
                             "Vertical drag inside code must move the transcript rather than being captured by horizontal pan")
    }

    func testOptInAllRich120WrapStreamAndReopenState() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120", "--chat-stable-viewport",
                               "--native-rich-all-eligible-120", "--native-rich-lifecycle-fixture"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 15, message: "Native 120-row tail must arrive before lifecycle actions")
        let native = tail.descendants(matching: .other)
            .matching(identifier: "native-rich-row-mounted").firstMatch
        XCTAssertTrue(native.waitForExistence(timeout: 15), "Response 119 must mount its native row")
        if native.buttons["Disable code line wrapping"].exists {
            native.buttons["Disable code line wrapping"].tap()
        }
        native.buttons["Enable code line wrapping"].tap()
        XCTAssertTrue(native.buttons["Disable code line wrapping"].waitForExistence(timeout: 10))
        assertHittable(tail, timeout: 10, message: "Global wrap change must retain bottom anchor")
        native.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(native.buttons["Enable code line wrapping"].waitForExistence(timeout: 10))
        let codeLine = native.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(codeLine.isHittable)
        codeLine.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        XCTAssertTrue((selection.value as? String ?? "").contains("## Response 119"))
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Stream rich test turn"].tap()
        let streamEnd = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1")).firstMatch
        XCTAssertTrue(streamEnd.waitForExistence(timeout: 15), "Stream must retain its final durable text")
        XCTAssertEqual(app.buttons["Reopen rich chat"].value as? String, "122 rows")
        attachScreenshot(named: "native-rich-120-after-stream")
        app.buttons["Reopen rich chat"].tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["Reopen rich chat"].value as? String, "122 rows")
        if arrow.isHittable { arrow.tap() }
        assertHittable(streamEnd, timeout: 15, message: "Reopened retained ChatView must keep the streamed tail")
        attachScreenshot(named: "native-rich-120-after-reopen")
    }

    func testDebugHostedRich120NativeViewportMotionAndLifecycleGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-rich-lifecycle-fixture",
                               "--native-hosted-rich120-gate"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        print("SEMREH_HOSTED_RICH_ARROW_TAP at=\(Date())")
        arrow.tap()
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Representative conversation complete."
        )).firstMatch
        assertHittable(tail, timeout: 15, message: "Native host must reach actual rich response 119.")
        attachScreenshot(named: "hosted-rich-120-tail")
        XCTAssertTrue(app.buttons["Copy code"].firstMatch.exists, "Product Markdown code action must survive native hosting.")
        XCTAssertTrue(app.buttons["Stream rich test turn"].exists)
        app.buttons["Stream rich test turn"].tap()
        let streamEnd = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1"
        )).firstMatch
        XCTAssertTrue(streamEnd.waitForExistence(timeout: 15), "Streaming row must be mounted and readable.")
        attachScreenshot(named: "hosted-rich-120-streamed-tail")
        app.buttons["Reopen rich chat"].tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        if arrow.isHittable { arrow.tap() }
        assertHittable(streamEnd, timeout: 15, message: "Reopen must preserve streamed content and tail.")
        attachScreenshot(named: "hosted-rich-120-reopened-tail")
    }

    func testDebugDirectRich120ArrowStreamAndReopenMotionGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-target-first-immediate-diagnostic",
                               "--native-direct-premount-rich-one", "--native-direct-first-visible-basic",
                               "--native-direct-parity-gate", "--native-direct-body-cache-gate",
                               "--native-rich-lifecycle-fixture", "--native-hosted-rich120-gate"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        print("SEMREH_DIRECT_RICH120_ARROW_TAP at=\(Date())")
        arrow.tap()
        attachScreenshot(named: "direct-rich120-immediate-posttap")
        XCTAssertFalse(app.staticTexts["native-direct-arrow-unready"].exists,
                       "A cold far-arrow that cannot animate real prepared rows is NO-GO.")
        let tail = app.otherElements.containing(.staticText, identifier: "message-row:representative-119")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15),
                      "The far tail must be an actual native rich row, not a SwiftUI host or proxy.")
        XCTAssertTrue(tail.staticTexts["Response 119"].isHittable)
        XCTAssertTrue(tail.buttons["Copy code"].exists)
        attachScreenshot(named: "direct-rich120-tail")
        XCTAssertTrue(app.buttons["Stream rich test turn"].exists)
        print("SEMREH_DIRECT_RICH120_STREAM_TAP at=\(Date()) tailFrame=\(tail.frame)")
        app.buttons["Stream rich test turn"].tap()
        let streamed = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1")).firstMatch
        XCTAssertTrue(streamed.waitForExistence(timeout: 15))
        let outgoing = app.otherElements.containing(.staticText,
            identifier: "message-row:perf-stream-message-1-user")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        let assistant = app.otherElements.containing(.staticText,
            identifier: "message-row:perf-stream-message-1-assistant")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(outgoing.exists, "Appended outgoing row must remain native and accessible.")
        XCTAssertTrue(assistant.exists, "Appended assistant row must remain native and accessible.")
        XCTAssertTrue(streamed.isHittable, "Final observed stream bytes must be visibly readable.")
        let motionSettled = expectation(for: NSPredicate(
            format: "value CONTAINS %@", "stream motion settled"), evaluatedWith: scroll)
        wait(for: [motionSettled], timeout: 5)
        XCTAssertEqual(scroll.value as? String, "stream motion settled; unexpected moves 0",
                       "Only the viewport display link may move the unchanged old row while the stream grows.")
        XCTAssertTrue(tail.exists && tail.buttons["Copy code"].exists,
                      "The preceding rich row must remain mounted and source-accurate through stream growth.")
        print("SEMREH_DIRECT_RICH120_STREAM_READY at=\(Date()) tailFrame=\(tail.frame) assistantFrame=\(assistant.frame)")
        attachScreenshot(named: "direct-rich120-streamed")
        app.buttons["Reopen rich chat"].tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        if arrow.isHittable { arrow.tap() }
        XCTAssertTrue(streamed.waitForExistence(timeout: 15))
        XCTAssertTrue(streamed.isHittable, "Reopen arrow must visibly return to the native streamed tail.")
        attachScreenshot(named: "direct-rich120-reopened")
    }

    func testDebugDirectRich120StreamKeepsReaderAwayAnchored() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-target-first-immediate-diagnostic",
                               "--native-direct-premount-rich-one", "--native-direct-first-visible-basic",
                               "--native-direct-parity-gate", "--native-direct-body-cache-gate",
                               "--native-rich-lifecycle-fixture", "--native-hosted-rich120-gate"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let originalY = first.frame.minY
        app.buttons["Stream rich test turn"].tap()
        let count = expectation(for: NSPredicate(format: "value == %@", "122 rows"),
                                evaluatedWith: app.buttons["Reopen rich chat"])
        wait(for: [count], timeout: 15)
        XCTAssertEqual(first.frame.minY, originalY, accuracy: 1,
                       "Appending below an away reader must preserve the visible native row's screen position.")
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable)
        XCTAssertFalse((scroll.value as? String)?.contains("stream motion active") == true,
                       "An away reader must not enter automatic stream-follow motion.")
    }

    func testOptInStableViewportStreamsAndReopensLongChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-multi-lab", "--chat-stable-viewport"]
        app.launch()

        let scroll = app.scrollViews["prototype-transcript-scroll"]
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        let originalTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "End of 10,000-row conversation 1."
        )).firstMatch
        assertHittable(originalTail, timeout: 20, message: "Original long-chat tail must be present.")

        app.buttons["Stream test turn"].tap()
        let streamedTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1"
        )).firstMatch
        assertHittable(streamedTail, timeout: 20, message: "Appended stream must stay visible at the bottom.")
        scroll.swipeDown()
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        assertHittable(streamedTail, timeout: 20, message: "Arrow must return to appended stream.")

        app.buttons["Performance chat 2"].tap()
        XCTAssertTrue(app.otherElements["chat-detail:10,000-row performance lab 2"].waitForExistence(timeout: 15))
        app.buttons["Performance chat 1"].tap()
        XCTAssertTrue(app.otherElements["chat-detail:10,000-row performance lab 1"].waitForExistence(timeout: 15))
        assertHittable(streamedTail, timeout: 20, message: "Reopening must retain the streamed tail and viewport.")
        attachScreenshot(named: "stable-viewport-stream-reopen-tail")
    }

    func testViewportPrototypeCostProfile() {
        exerciseViewportPrototypeTenThousandRows(profilePause: true)
    }

    private func exerciseViewportPrototypeTenThousandRows(profilePause: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--chat-viewport-prototype"]
        app.launch()
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 15))
        // Give the external sampler time to attach. This is diagnostic only;
        // the offscreen final row is not created or prewarmed during the pause.
        if profilePause { Thread.sleep(forTimeInterval: 15) }
        for cycle in 1...2 {
            if cycle > 1 {
                let transcript = app.scrollViews["prototype-transcript-scroll"]
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.7)))
                XCTAssertTrue(arrow.waitForExistence(timeout: 5))
            }
            arrow.tap()
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", endMarker)).firstMatch
            assertHittable(tail, timeout: 10, message: "Prototype must reach the concrete 10,000-row tail, cycle \(cycle).")
            XCTAssertFalse(arrow.waitForExistence(timeout: 2))
        }
        attachScreenshot(named: "prototype-ten-thousand-tail")
        if profilePause { Thread.sleep(forTimeInterval: 8) }
    }

    func testPrototypeVirtualCodeTallRepeatedArrow() {
        exerciseTallMixedTranscriptArrow(disableHighlighting: false, prototype: true, virtualCode: true)
    }

    private func exerciseTallMixedTranscriptArrow(disableHighlighting: Bool, prototype: Bool = false, virtualCode: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-tall-lab"]
        if prototype { app.launchArguments.append("--chat-viewport-prototype") }
        if virtualCode { app.launchArguments.append("--viewport-virtual-code") }
        if disableHighlighting { app.launchArguments.append("--tail-geometry-no-highlight") }
        app.launch()
        XCTAssertTrue(app.otherElements["chat-detail:Tall mixed transcript lab"].waitForExistence(timeout: 15))
        let transcript = app.scrollViews[prototype ? "prototype-transcript-scroll" : "chat-transcript-scroll"]
        let arrow = app.buttons[prototype ? "Prototype scroll to latest" : scrollToLatestLabel]
        for cycle in 1...3 {
            if cycle > 1 {
                // Isolate the vertical transcript gesture from the nested
                // horizontally scrolling code block under the viewport center.
                let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3))
                let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.7))
                start.press(forDuration: 0.05, thenDragTo: end)
                attachScreenshot(named: "tall-mixed-after-outer-drag-\(cycle)")
            }
            XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
            arrow.tap()
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "End of tall mixed conversation.")).firstMatch
            assertHittable(tail, timeout: 10, message: "A tall mixed row must reach its actual end, cycle \(cycle).")
            XCTAssertFalse(arrow.waitForExistence(timeout: 2))
        }
        let codeText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "let measuredHeight = rows.reduce(0)")
        ).firstMatch
        XCTAssertTrue(codeText.exists, "Highlighted code must remain exposed as readable accessibility text.")
        if virtualCode { XCTAssertTrue(app.otherElements["prototype-virtual-code"].firstMatch.exists, "Candidate must actually be mounted.") }
        attachScreenshot(named: "tall-mixed-real-scroll-tail")
    }

    func testPrototypeHighlightedCodeSelectionBaseline() {
        exercisePrototypeCodeSelection(virtualCode: false)
    }

    func testPrototypeVirtualCodeFullSelection() {
        exercisePrototypeCodeSelection(virtualCode: true)
    }

    func testPrototypeVirtualCodeWrapAndOffscreenAccessibility() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-tall-lab", "--chat-viewport-prototype", "--viewport-virtual-code"]
        app.launch()
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 15))
        arrow.tap()
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "End of tall mixed conversation.")).firstMatch
        assertHittable(tail, timeout: 10, message: "Start at the concrete tall tail.")
        XCTAssertTrue(app.otherElements["prototype-virtual-code"].firstMatch.exists)
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "let measuredHeight = rows.reduce(0)"))
        XCTAssertGreaterThanOrEqual(lines.count, 96, "Offscreen logical lines must remain accessible.")
        let transcript = app.scrollViews["prototype-transcript-scroll"]
        let enable = app.buttons["Enable code line wrapping"]
        let disable = app.buttons["Disable code line wrapping"]
        for _ in 0..<9 {
            if enable.firstMatch.isHittable || disable.firstMatch.isHittable { break }
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8)))
        }
        let toggle = enable.firstMatch.isHittable ? enable.firstMatch : disable.firstMatch
        XCTAssertTrue(toggle.isHittable, "Reach the actual code header with reader gestures.")
        let initiallyWrapped = disable.firstMatch.isHittable
        toggle.tap()
        let reverse = initiallyWrapped ? enable.firstMatch : disable.firstMatch
        XCTAssertTrue(reverse.waitForExistence(timeout: 5) && reverse.isHittable,
                      "Wrapping must keep the code header at the reader's anchor.")
        attachScreenshot(named: "prototype-code-wrap-reader-anchor")
        reverse.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5) && toggle.isHittable)
        let copy = app.buttons["Copy code"].firstMatch
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["Copied code"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        arrow.tap()
        assertHittable(tail, timeout: 10, message: "Wrap/copy changes must not lose the actual tail.")
        XCTAssertFalse(arrow.waitForExistence(timeout: 2))
        attachScreenshot(named: "prototype-code-wrap-tail-return")
    }

    private func exercisePrototypeCodeSelection(virtualCode: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-tall-lab", "--chat-viewport-prototype"]
        if virtualCode { app.launchArguments.append("--viewport-virtual-code") }
        app.launch()
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 15))
        arrow.tap()
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "End of tall mixed conversation.")).firstMatch
        assertHittable(tail, timeout: 10, message: "Selection baseline needs the concrete tall tail.")
        if virtualCode { XCTAssertTrue(app.otherElements["prototype-virtual-code"].firstMatch.exists, "Candidate must actually be mounted.") }
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "let measuredHeight = rows.reduce(0)"))
        guard let visible = lines.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("A visible highlighted line is required for native selection inspection.")
        }
        visible.press(forDuration: 1)
        attachScreenshot(named: "prototype-code-selection-baseline")
        let copy = app.buttons["Copy"]
        XCTAssertTrue(copy.firstMatch.waitForExistence(timeout: 3), "Native code selection must offer Copy.")
        let select = app.buttons["Select Text"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.tap()
        let selectable = app.textViews["selectable-response-text"]
        XCTAssertTrue(selectable.waitForExistence(timeout: 3))
        let fullText = selectable.value as? String ?? ""
        XCTAssertTrue(fullText.contains("End of tall mixed conversation."))
        XCTAssertGreaterThan(fullText.components(separatedBy: "let measuredHeight = rows.reduce(0)").count, 90,
                             "Full logical code must remain selectable, not just visible lines.")
        attachScreenshot(named: "prototype-full-response-selection-baseline")
    }

    func testRepeatedScrollAwayAndArrowReturnKeepsEndMarkerReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument]
        app.launch()

        let chat = app.otherElements[chatIdentifier]
        XCTAssertTrue(chat.waitForExistence(timeout: 15),
                      "The server-free 10,000-row ChatView performance lab must launch.")
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let scrollToLatest = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 10))

        // Exercise more than one ordinary away/return cycle. This is a
        // correctness check for the public XCTest interaction path, not an
        // FPS or deceleration measurement.
        for cycle in 1...2 {
            transcript.swipeDown()
            XCTAssertTrue(
                scrollToLatest.waitForExistence(timeout: 10),
                "Scroll-to-latest must remain available after cycle \(cycle)'s swipe away."
            )
            scrollToLatest.tap()

            let endMarker = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", self.endMarker)
            ).firstMatch
            assertHittable(
                endMarker,
                timeout: 25,
                message: "Cycle \(cycle)'s arrow return must reveal the deterministic end marker."
            )
            XCTAssertFalse(
                scrollToLatest.waitForExistence(timeout: 2),
                "Cycle \(cycle)'s scroll-to-latest action must clear at the bottom."
            )
        }
    }

    func testSyntheticProductionOpenFlickAndArrow120And10kMixed() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for count in [120, 10_000] {
            app.terminate()
            app.launchArguments = [performanceLabArgument, "--chat-viewport-diagnostic"]
            if count == 120 {
                app.launchArguments.append("--representative-count=120")
            } else {
                app.launchArguments.append("--native-direct-mixed-rich-10k")
            }
            app.launch()

            let transcript = app.scrollViews["chat-transcript-scroll"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "message-row:"
            )).firstMatch.waitForExistence(timeout: 15), "The opened viewport must realize a message row.")
            attachScreenshot(named: "synthetic-production-\(count)-open")

            for _ in 0..<3 {
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.84))
                    .press(forDuration: 0.01,
                           thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            }
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "message-row:"
            )).firstMatch.waitForExistence(timeout: 15), "Fast flicks must leave a realized message row.")
            attachScreenshot(named: "synthetic-production-\(count)-after-fast-flick")

            let arrow = app.buttons[scrollToLatestLabel]
            XCTAssertTrue(arrow.waitForExistence(timeout: 15))
            arrow.tap()
            let marker = count == 120 ? "Representative conversation complete." : endMarker
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
            assertHittable(tail, timeout: 30, message: "\(count) rich-row arrow must expose its real tail.")
            attachScreenshot(named: "synthetic-production-\(count)-arrow-tail")
        }
    }

    func testDiagnosticColdNearTailOpenAndFarArrowUsesRealizedRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument, "--native-direct-mixed-rich-10k",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()

        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", endMarker
        )).firstMatch
        assertHittable(tail, timeout: 25, message: "Cold bottom restore must reveal the concrete 10k tail.")
        attachScreenshot(named: "cold-near-tail-open")

        app.terminate()

        let farApp = XCUIApplication()
        farApp.launchArguments = [performanceLabArgument, "--native-direct-mixed-rich-10k",
                                  "--chat-viewport-diagnostic", "--composer-test-fresh-draft"]
        farApp.launch()
        let farTranscript = farApp.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(farTranscript.waitForExistence(timeout: 20))
        let arrow = farApp.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 15))
        attachScreenshot(named: "saved-row-20-before-far-arrow")
        print("SEMREH_FAR_ARROW_TAP at=\(Date())")
        arrow.tap()
        let farTail = farApp.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", endMarker
        )).firstMatch
        assertHittable(farTail, timeout: 30, message: "Far arrow must reveal the concrete 10k tail.")
        attachScreenshot(named: "saved-row-20-after-far-arrow")
    }

    func testDebugBoundedTailWindowFarArrowRichTail() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument, "--native-direct-mixed-rich-10k",
                               "--chat-viewport-diagnostic", "--chat-debug-bounded-tail-window",
                               "--composer-test-fresh-draft"]
        app.launch()
        let scroll = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 20))
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        attachScreenshot(named: "bounded-saved-row-before-arrow")
        print("SEMREH_BOUNDED_FAR_ARROW_TAP at=\(Date())")
        arrow.tap()
        let farTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", endMarker
        )).firstMatch
        assertHittable(farTail, timeout: 20, message: "Bounded far arrow must show real 10k tail.")
        XCTAssertTrue(app.buttons["Copy code"].firstMatch.exists,
                      "Bounded tail must retain rich code actions.")
        attachScreenshot(named: "bounded-far-arrow-tail")
    }

    func testRepeatedMultiChatSwitchingRetainsEachOwnerAndMarker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-multi-lab"]
        app.launch()

        let firstChat = app.otherElements["chat-detail:10,000-row performance lab 1"]
        XCTAssertTrue(firstChat.waitForExistence(timeout: 20))

        let initialArrow = app.buttons[scrollToLatestLabel]
        guard initialArrow.waitForExistence(timeout: 10) else {
            attachScreenshot(named: "repeated-switch-initial-arrow-missing")
            attachAccessibilitySnapshot(
                named: "repeated-switch-initial-arrow-missing-ax",
                app: app
            )
            XCTFail("Chat 1 must initially restore away from the bottom before switching.")
            return
        }

        let switchButtons = (1...3).map { app.buttons["Performance chat \($0)"] }
        for button in switchButtons {
            XCTAssertTrue(button.waitForExistence(timeout: 5),
                          "Every performance chat switch must be exposed.")
            XCTAssertTrue(button.isHittable,
                          "Every performance chat switch must be hittable before the rapid sequence.")
        }

        // Deliberately issue a bounded burst without waiting for each ChatView
        // to settle. XCTest still synchronizes individual actions, so this
        // does not claim frame-level or exact deceleration timing; it catches
        // owner loss, stale selection, and fixture replacement under repeated
        // user-level switching.
        for chatNumber in [2, 3, 1, 3, 2, 1] {
            switchButtons[chatNumber - 1].tap()
        }

        // Verify each owner after the burst. Returning to the bottom makes the
        // check a stable-content assertion rather than an assertion about a
        // transient accessibility snapshot during navigation.
        for chatNumber in 1...3 {
            let switchButton = switchButtons[chatNumber - 1]
            switchButton.tap()
            XCTAssertTrue(switchButton.isSelected,
                          "Rapid switching must leave chat \(chatNumber) selected when revisited.")

            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            XCTAssertTrue(chat.waitForExistence(timeout: 15),
                          "Chat \(chatNumber) must remain the selected owner after rapid switching.")

            let scrollToLatest = app.buttons[scrollToLatestLabel]
            guard scrollToLatest.waitForExistence(timeout: 10) else {
                // A missing affordance is the signal under test here: capture
                // the selected owner, realized rows, and visible chrome before
                // failing so a restore-to-bottom race is distinguishable from
                // a stale ChatView or an accessibility lookup failure.
                let endMarker = app.staticTexts.matching(
                    NSPredicate(
                        format: "label CONTAINS[c] %@",
                        "End of 10,000-row conversation \(chatNumber)."
                    )
                ).firstMatch
                let endMarkerIsVisible = endMarker.exists && endMarker.isHittable
                attachScreenshot(
                    named: "repeated-switch-chat-\(chatNumber)-arrow-missing"
                )
                attachAccessibilitySnapshot(
                    named: "repeated-switch-chat-\(chatNumber)-arrow-missing-ax",
                    app: app
                )
                XCTFail("Chat \(chatNumber) must retain its restored away-from-bottom state (endMarkerHittable=\(endMarkerIsVisible)).")
                return
            }
            scrollToLatest.tap()

            let endMarker = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "End of 10,000-row conversation \(chatNumber).")
            ).firstMatch
            assertHittable(
                endMarker,
                timeout: 25,
                message: "Chat \(chatNumber) must retain its deterministic end marker after rapid switching."
            )
        }
    }

    func testOptInTwentyLongChatEnterBackSwitchCycles() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SEMREH_CHAT_PERFORMANCE_CYCLES"] == "1" else {
            throw XCTSkip("The 20-cycle long-chat performance trace is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceCycleLabArgument, performanceSignpostsArgument]
        app.launch()

        let cycleLab = app.descendants(matching: .any)["performance-cycle-lab"]
        XCTAssertTrue(
            cycleLab.waitForExistence(timeout: 15),
            "The opt-in server-free long-chat cycle lab must launch."
        )

        let cycleCount = 20
        var measurements = [
            "# fixture=2 chats x 10,000 rows; pattern=alternating enter/back visits",
            "# enter_ms is tap-to-chat-root-hittable; return_ms is Back-to-list-button-hittable",
            "# These are XCTest wall-clock timings including accessibility waits; use Instruments for hitches/FPS.",
            "# signposts=subsystem=com.maurice.semreh category=ChatPerformance names=ChatPerformancePhase,ChatPerformanceTransition",
            "cycle,chat,enter_ms,return_ms,total_ms"
        ]

        for cycle in 1...cycleCount {
            // Alternating owners ensures every visit opens a different long
            // chat than the preceding visit, matching the reported repro while
            // keeping both retained fixtures deterministic.
            let chatNumber = cycle.isMultiple(of: 2) ? 2 : 1
            let entry = app.buttons["performance-cycle-chat-\(chatNumber)"]
            assertHittable(
                entry,
                timeout: 15,
                message: "Cycle \(cycle) must expose long chat \(chatNumber) in the lab list."
            )

            let cycleStarted = Date()
            let enterStarted = Date()
            entry.tap()

            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            assertHittable(
                chat,
                timeout: 25,
                message: "Cycle \(cycle) must enter long chat \(chatNumber)."
            )
            let enterMilliseconds = Date().timeIntervalSince(enterStarted) * 1_000

            let back = app.buttons["Back"]
            assertHittable(
                back,
                timeout: 10,
                message: "Cycle \(cycle) must expose the custom chat Back button."
            )
            let returnStarted = Date()
            back.tap()
            assertHittable(
                entry,
                timeout: 20,
                message: "Cycle \(cycle) must return to the performance lab list."
            )
            let returnMilliseconds = Date().timeIntervalSince(returnStarted) * 1_000
            let totalMilliseconds = Date().timeIntervalSince(cycleStarted) * 1_000

            measurements.append(String(format: "%d,%d,%.1f,%.1f,%.1f", cycle, chatNumber,
                                       enterMilliseconds, returnMilliseconds, totalMilliseconds))
        }

        attachPlainText(
            measurements.joined(separator: "\n"),
            named: "long-chat-enter-back-20-cycle-timings"
        )
    }

    @MainActor
    func testOptInCycleLabFrameCallbackProbeReadback() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The DEBUG cycle-lab callback probe is Simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment[performanceFrameCallbackProbeEnvironment] == "1" else {
            throw XCTSkip("The cycle-lab callback timing probe is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            performanceCycleLabArgument,
            performanceSignpostsArgument,
            performanceFrameCallbackProbeArgument
        ]
        app.launch()

        let cycleLab = app.descendants(matching: .any)["performance-cycle-lab"]
        XCTAssertTrue(cycleLab.waitForExistence(timeout: 15))
        let start = app.buttons["frame-callback-probe-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10) && start.isHittable)

        let scope = XCTAttachment(string: [
            "fixture=DEBUG cycle lab; 2 synthetic conversations x 10,000 rows",
            "instrument=opt-in CADisplayLink callback timing on the app main run loop",
            "reported=callback count, estimated target-interval gaps, max and histogram p95/p99",
            "not_measured=presented pixels, GPU frame lifetime, physical FPS, or hitch pass/fail",
            "lifecycle=sample pauses and drops timing baseline while scene is inactive",
            "no_per_frame_state_or_logging=true"
        ].joined(separator: "\n"))
        scope.name = "Frame callback probe claim boundary"
        scope.lifetime = .keepAlways
        add(scope)

        start.tap()

        for chatNumber in 1...2 {
            let entry = app.buttons["performance-cycle-chat-\(chatNumber)"]
            assertHittable(
                entry,
                timeout: 15,
                message: "The callback sample must expose long chat \(chatNumber) in the lab list."
            )
            entry.tap()

            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            assertHittable(chat, timeout: 25, message: "The callback sample must enter chat \(chatNumber).")
            let transcript = app.scrollViews.firstMatch
            XCTAssertTrue(transcript.waitForExistence(timeout: 10) && transcript.isHittable)
            transcript.swipeDown()

            let scrollToLatest = app.buttons[scrollToLatestLabel]
            XCTAssertTrue(
                scrollToLatest.waitForExistence(timeout: 10) && scrollToLatest.isHittable,
                "A real swipe must expose Scroll to latest for chat \(chatNumber)."
            )
            scrollToLatest.tap()

            let endMarker = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "End of 10,000-row conversation \(chatNumber).")
            ).firstMatch
            assertHittable(endMarker, timeout: 25, message: "Arrow return must reveal chat \(chatNumber)'s tail.")

            let back = app.buttons["Back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
            back.tap()
            assertHittable(
                entry,
                timeout: 20,
                message: "The callback sample must return to the lab after chat \(chatNumber)."
            )
        }

        let stop = app.buttons["frame-callback-probe-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && stop.isHittable)
        stop.tap()

        let summary = app.staticTexts["chat-performance-frame-callback-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let report = summary.label
        XCTAssertTrue(report.contains("CADisplayLink main-run-loop callback timing only"))
        XCTAssertTrue(report.contains("estimated_missed_target_intervals="))
        XCTAssertTrue(report.contains("maximum_callback_gap_ms="))
        XCTAssertTrue(report.contains("p95_callback_gap_ms_upper_bin="))
        XCTAssertTrue(report.contains("p99_callback_gap_ms_upper_bin="))
        XCTAssertTrue(report.contains("histogram_storage_bins="))
        guard let callbackCountLine = report
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("callbacks=") })
        else {
            XCTFail("The callback report must include its aggregate callback count.")
            return
        }
        let callbackCountText = String(callbackCountLine.dropFirst("callbacks=".count))
        guard let callbackCount = Int(callbackCountText) else {
            XCTFail("The callback count must be a readable integer.")
            return
        }
        XCTAssertGreaterThan(callbackCount, 0, "The probe must sample callbacks, without a performance threshold.")
        attachPlainText(report, named: "long-chat-frame-callback-timing-summary")
    }

    @MainActor
    func testOptInAppWideCadenceMonitorReadback() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The DEBUG app-wide cadence monitor is Simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment[appWidePerformanceMonitorEnvironment] == "1" else {
            throw XCTSkip("The app-wide cadence monitor readback is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            performanceCycleLabArgument,
            performanceSignpostsArgument,
            appWidePerformanceMonitorArgument
        ]
        app.launch()

        let cycleLab = app.descendants(matching: .any)["performance-cycle-lab"]
        XCTAssertTrue(
            cycleLab.waitForExistence(timeout: 15),
            "The app-wide monitor must use the retained server-free cycle lab."
        )
        let stop = app.buttons["chat-performance-app-wide-monitor-stop"]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 10) && stop.isHittable,
            "The explicit opt-in monitor must expose its bounded stop/readout control."
        )

        for chatNumber in 1...2 {
            let entry = app.buttons["performance-cycle-chat-\(chatNumber)"]
            assertHittable(
                entry,
                timeout: 15,
                message: "The app-wide cadence sample must expose long chat \(chatNumber)."
            )
            entry.tap()

            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            assertHittable(chat, timeout: 25, message: "The app-wide sample must enter chat \(chatNumber).")
            let back = app.buttons["Back"]
            XCTAssertTrue(
                back.waitForExistence(timeout: 10) && back.isHittable,
                "The app-wide sample must expose Back for chat \(chatNumber)."
            )
            back.tap()
            assertHittable(
                entry,
                timeout: 20,
                message: "The app-wide sample must return to the lab after chat \(chatNumber)."
            )
        }

        // Scene sleep is a lifecycle boundary for the accumulator. This
        // exercises pause/rebase accounting without turning background time
        // into a fabricated callback gap; it is not a rendered-frame claim.
        XCUIDevice.shared.press(.home)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        app.activate()
        XCTAssertTrue(cycleLab.waitForExistence(timeout: 10))
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && stop.isHittable)

        stop.tap()
        let summary = app.staticTexts["chat-performance-app-wide-monitor-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let report = summary.label
        XCTAssertTrue(report.contains("CADisplayLink main-run-loop callback timing only"))
        XCTAssertTrue(report.contains("sample_duration_seconds="))
        XCTAssertTrue(report.contains("phase_marker_scope="))
        XCTAssertTrue(report.contains("p95_callback_gap_ms_upper_bin="))
        XCTAssertTrue(report.contains("p99_callback_gap_ms_upper_bin="))
        XCTAssertTrue(report.contains("interaction_duration_max_ms="))
        XCTAssertTrue(report.contains("phase_callback_timing_coverage="))
        XCTAssertTrue(report.contains("phase=entry phase_events=2"))
        XCTAssertTrue(report.contains("phase=back phase_events=2"))
        XCTAssertTrue(report.contains("phase=send"))
        XCTAssertTrue(report.contains("phase=scene_pause"))

        guard let callbackCountLine = report
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("callbacks=") })
        else {
            XCTFail("The app-wide report must include its aggregate callback count.")
            return
        }
        let callbackCountText = String(callbackCountLine.dropFirst("callbacks=".count))
        guard let callbackCount = Int(callbackCountText) else {
            XCTFail("The app-wide callback count must be a readable integer.")
            return
        }
        XCTAssertGreaterThan(callbackCount, 0, "The monitor must observe callbacks, without a smoothness threshold.")
        attachPlainText(report, named: "app-wide-cadence-timing-summary")
    }

    @MainActor
    func testOptInLongChatXCTestMetricCapabilityProbe() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The metric capability probe is Simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment[performanceMetricProbeEnvironment] == "1" else {
            throw XCTSkip("The long-chat XCTest metric capability probe is opt-in.")
        }
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("XCTHitchMetric requires iOS 26.0 or later.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceCycleLabArgument, performanceSignpostsArgument]
        app.launch()

        let cycleLab = app.descendants(matching: .any)["performance-cycle-lab"]
        XCTAssertTrue(
            cycleLab.waitForExistence(timeout: 15),
            "The metric probe must use the existing server-free two-chat cycle lab."
        )

        let options = XCTMeasureOptions()
        // XCTest runs one unrecorded warm-up and one measured iteration.
        // Each iteration visits both retained owners and includes a real swipe,
        // arrow return, and Back navigation.
        options.iterationCount = 1

        let metricNotes = XCTAttachment(string: [
            "fixture=DEBUG cycle lab; 2 synthetic conversations x 10,000 rows",
            "measured_iterations=1; XCTest discards one warm-up iteration",
            "requested=XCTHitchMetric(application), XCTCPUMetric(application), XCTMemoryMetric(application), navigationTransitionMetric, scrollingAndDecelerationMetric",
            "scope=presentation-only; app CPU is process aggregate, not main-thread CPU",
            "Simulator metric output only; do not interpret as physical FPS or device acceptance",
            "The numeric measurements must appear in the .xcresult performance results; missing values are not a pass"
        ].joined(separator: "\n"))
        metricNotes.name = "Long-chat XCTest metric probe scope"
        metricNotes.lifetime = .keepAlways
        add(metricNotes)

        measure(
            metrics: [
                XCTHitchMetric(application: app),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
                XCTOSSignpostMetric.navigationTransitionMetric,
                XCTOSSignpostMetric.scrollingAndDecelerationMetric
            ],
            options: options
        ) {
            for chatNumber in 1...2 {
                let entry = app.buttons["performance-cycle-chat-\(chatNumber)"]
                XCTAssertTrue(
                    entry.waitForExistence(timeout: 15) && entry.isHittable,
                    "The measured iteration must revisit chat \(chatNumber)'s seeded owner."
                )
                entry.tap()

                let chat = app.otherElements[
                    "chat-detail:10,000-row performance lab \(chatNumber)"
                ]
                assertHittable(
                    chat,
                    timeout: 25,
                    message: "The measured iteration must enter long chat \(chatNumber)."
                )

                let transcript = app.scrollViews.firstMatch
                XCTAssertTrue(transcript.waitForExistence(timeout: 5) && transcript.isHittable)
                transcript.swipeDown()

                let scrollToLatest = app.buttons[scrollToLatestLabel]
                XCTAssertTrue(
                    scrollToLatest.waitForExistence(timeout: 10) && scrollToLatest.isHittable,
                    "A real swipe away must expose Scroll to latest for chat \(chatNumber)."
                )
                scrollToLatest.tap()

                let endMarker = app.staticTexts.matching(
                    NSPredicate(
                        format: "label CONTAINS[c] %@",
                        "End of 10,000-row conversation \(chatNumber)."
                    )
                ).firstMatch
                assertHittable(
                    endMarker,
                    timeout: 25,
                    message: "Arrow return must reveal chat \(chatNumber)'s deterministic end marker."
                )
                XCTAssertFalse(
                    scrollToLatest.waitForExistence(timeout: 2),
                    "Scroll to latest must clear after the measured return."
                )

                let back = app.buttons["Back"]
                XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
                back.tap()
                assertHittable(
                    entry,
                    timeout: 20,
                    message: "The measured iteration must return to the cycle lab list."
                )
            }
        }
    }

    func testMultiChatPerformanceLabSwitchesStreamsAndScrolls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-multi-lab"]
        app.launch()

        let firstChat = app.otherElements["chat-detail:10,000-row performance lab 1"]
        XCTAssertTrue(firstChat.waitForExistence(timeout: 20))

        // Every fixture starts restored in the middle of a 10,000-row transcript.
        // Reach its existing tail before appending, then prove that the latest
        // streamed row survives a real away-from-bottom scroll and arrow return.
        exerciseMultiChat(app: app, chatNumber: 1, screenshotPrefix: "multi-chat-1")

        let switchToSecond = Date()
        app.buttons["Performance chat 2"].tap()
        let secondChat = app.otherElements["chat-detail:10,000-row performance lab 2"]
        XCTAssertTrue(secondChat.waitForExistence(timeout: 15))
        addTiming(named: "multi-chat-switch-to-chat-2", startedAt: switchToSecond)
        exerciseMultiChat(app: app, chatNumber: 2, screenshotPrefix: "multi-chat-2")

        let switchToThird = Date()
        app.buttons["Performance chat 3"].tap()
        let thirdChat = app.otherElements["chat-detail:10,000-row performance lab 3"]
        XCTAssertTrue(thirdChat.waitForExistence(timeout: 15))
        addTiming(named: "multi-chat-switch-to-chat-3", startedAt: switchToThird)
        exerciseMultiChat(app: app, chatNumber: 3, screenshotPrefix: "multi-chat-3")

        // Revisit all owners after streaming; switching must not recreate a
        // fixture or lose its appended latest marker.
        for chatNumber in 1...3 {
            app.buttons["Performance chat \(chatNumber)"].tap()
            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            XCTAssertTrue(chat.waitForExistence(timeout: 15))
            let marker = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_MULTI_CHAT_STREAM_1")
            ).firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 10),
                          "Chat \(chatNumber) must retain its streamed latest marker after switching.")
        }
    }

    private func exerciseMultiChat(app: XCUIApplication, chatNumber: Int, screenshotPrefix: String) {
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Chat \(chatNumber) must expose its transcript scroll view.")
        let scrollToLatest = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 10),
                      "Chat \(chatNumber) must restore with scroll-to-latest available.")

        let baseMarker = "End of 10,000-row conversation \(chatNumber)."
        let reachInitialBottom = Date()
        scrollToLatest.tap()
        let initialEnd = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", baseMarker)
        ).firstMatch
        assertHittable(initialEnd, timeout: 25,
                       message: "Chat \(chatNumber) must expose its original deterministic tail after arrow return.")
        XCTAssertFalse(scrollToLatest.waitForExistence(timeout: 2),
                       "Chat \(chatNumber) must clear the arrow at the original bottom.")
        addTiming(named: "\(screenshotPrefix)-reach-original-bottom", startedAt: reachInitialBottom)
        attachScreenshot(named: "\(screenshotPrefix)-original-bottom")

        let streamStart = Date()
        app.buttons["Stream test turn"].tap()
        let latestMarker = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_MULTI_CHAT_STREAM_1")
        ).firstMatch
        assertHittable(latestMarker, timeout: 15,
                       message: "Chat \(chatNumber) must expose its paced appended stream marker at the bottom.")
        addTiming(named: "\(screenshotPrefix)-stream-append", startedAt: streamStart)
        attachScreenshot(named: "\(screenshotPrefix)-streamed-bottom")

        let scrollAwayStart = Date()
        transcript.swipeDown()
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 10),
                      "Chat \(chatNumber) must show the arrow after scrolling away from its latest row.")
        scrollToLatest.tap()
        assertHittable(latestMarker, timeout: 25,
                       message: "Chat \(chatNumber) arrow return must reveal the newly appended latest marker.")
        XCTAssertFalse(scrollToLatest.waitForExistence(timeout: 2),
                       "Chat \(chatNumber) must clear the arrow after returning to the new bottom.")
        addTiming(named: "\(screenshotPrefix)-scroll-and-bottom-arrow", startedAt: scrollAwayStart)
        attachScreenshot(named: "\(screenshotPrefix)-new-bottom-after-arrow")
    }

    private func assertHittable(_ element: XCUIElement, timeout: TimeInterval, message: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(element.exists && element.isHittable, message)
    }

    @MainActor
    func testOptInLiveProductionLoginNewChatSend() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Live production UI smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] != nil
        else {
            throw XCTSkip("Live production UI smoke is opt-in.")
        }

        let stockBackend = environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock"
            && environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == stockBackendSHA
            && environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == stockCredentialsPath
            && environment["SEMREH_SLICE2_TOOL_CWD"] == stockToolCwd
        let developmentBackend = environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "development"
            && environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == developmentBackendSHA
            && environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == developmentCredentialsPath
            && environment["SEMREH_SLICE2_TOOL_CWD"] == developmentToolCwd
        guard stockBackend || developmentBackend else {
            XCTFail("Slice 2 UI backend mode is invalid.")
            return
        }
        guard stockBackend != developmentBackend else {
            XCTFail("Slice 2 UI backend mode is ambiguous.")
            return
        }
        let credentialsPath = stockBackend ? stockCredentialsPath : developmentCredentialsPath

        let credentials = try readCredentials(at: credentialsPath)
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = []
        app.launch()
        defer { clearPasteboard() }

        prepareNormalSignIn(app: app)
        let welcome = app.buttons["Get Started"]
        if !app.textFields["onboarding-server-url"].exists {
            XCTAssertTrue(welcome.waitForExistence(timeout: 15), "Normal sign-out must return to Welcome.")
            XCTAssertTrue(welcome.isHittable)
            welcome.tap()
        }

        let serverURL = app.textFields["onboarding-server-url"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        replacePublicText(serverURL, with: approvedLiveOrigin, app: app)
        app.buttons["Test Connection"].tap()

        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30), "The approved HTTPS origin must advertise username auth.")
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        attachScreenshot(named: "live-production-onboarding-password-form")
        replacePublicText(username, with: credentials.username, app: app)
        pasteSecret(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()
        dismissKnownPasswordSavePrompt(app: app)
        let personalize = app.navigationBars["Personalize"]
        if personalize.waitForExistence(timeout: 5) {
            dismissKnownPasswordSavePrompt(app: app)
            let skip = personalize.buttons["Skip"]
            XCTAssertTrue(skip.waitForExistence(timeout: 5) && skip.isHittable)
            skip.tap()
            XCTAssertFalse(personalize.waitForExistence(timeout: 1))
        }

        // The shell remembers the selected tab across normal sign-out/login.
        // Successful authentication need not land on Sessions automatically.
        if environment["SEMREH_SLICE3_UNCERTAINTY_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 uncertainty UI requires the pinned stock backend.")
                return
            }
            guard let storedID = environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"],
                  storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil,
                  let seedMarker = environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"],
                  seedMarker.range(of: "^SEMREH_SLICE3_PRE_ACK_SEED_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil
            else {
                XCTFail("Slice 3 uncertainty UI requires the exact pre-ACK seed session and marker.")
                return
            }
            try await waitForPromptUncertaintyEntryReadiness(app: app, seedMarker: seedMarker)
            try await exerciseOptInPromptUncertainty(
                app: app,
                storedID: storedID,
                seedMarker: seedMarker,
                credentials: credentials
            )
            return
        }

        // A persisted deep link can legitimately restore an authenticated chat
        // detail instead of the shell root. Return through that known chat's
        // navigation control before asserting the shell tabs.
        waitForPostLoginDestination(app: app)

        if environment["SEMREH_SLICE4_KANBAN_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 4 Kanban UI requires the pinned stock backend.")
                return
            }
            let control = app.buttons["Control"]
            assertHittable(control, timeout: 15,
                          message: "The authenticated production shell must expose Control.")
            control.tap()
            let kanban = app.buttons["Kanban"]
            assertHittable(kanban, timeout: 15,
                          message: "The production Control menu must expose the retained Kanban plugin.")
            kanban.tap()

            XCTAssertTrue(app.navigationBars["Kanban"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.scrollViews["KanbanStatusSelector"].waitForExistence(timeout: 30),
                          "The authenticated stock Board must reach compatible read-only content.")
            XCTAssertTrue(app.buttons["Switch Board"].exists,
                          "A live stock Board response must populate the Board selector.")
            XCTAssertFalse(app.staticTexts["The Kanban server is unavailable."].exists)
            XCTAssertFalse(app.staticTexts["This server's Kanban response is incompatible with Semreh."].exists)
            XCTAssertFalse(app.staticTexts["Loading Kanban"].exists)
            attachScreenshot(named: "slice4-kanban-stock-board-read-only")

            let backToControl = app.navigationBars["Kanban"].buttons["Back"]
            assertHittable(backToControl, timeout: 10,
                          message: "Kanban must preserve production back-navigation to Control.")
            backToControl.tap()
            let reopenedControl = app.buttons["Control"]
            assertHittable(reopenedControl, timeout: 10,
                          message: "Back-navigation must restore the production Control entrypoint.")
            reopenedControl.tap()
            let insights = app.buttons["Insights"]
            assertHittable(insights, timeout: 15,
                          message: "The production Control menu must expose retained Insights.")
            insights.tap()
            XCTAssertTrue(app.navigationBars["Usage Analytics"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts["Total Tokens"].waitForExistence(timeout: 30),
                          "The authenticated stock analytics response must render its summary cards.")
            XCTAssertTrue(app.staticTexts["Sessions"].exists)
            XCTAssertFalse(app.staticTexts["Could Not Load Analytics"].exists)
            XCTAssertFalse(app.staticTexts["Loading analytics..."].exists)
            attachScreenshot(named: "slice4-insights-stock-read-only")
            // Read-only production navigation check: do not select Cards, run
            // Dispatcher, create a Card, switch Boards, refresh, or mutate data.
            return
        }

        if let storedID = environment["SEMREH_SLICE4_GIT_UI_SESSION_ID"] {
            guard stockBackend,
                  storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Git UI verification requires the owned stock fixture and plain seeded ID.")
                return
            }
            try openSeededSession(app: app, storedID: storedID)
            assertHittable(app.staticTexts["SEMREH_SLICE4_GIT_UI_SEED"], timeout: 30,
                          message: "Open the owned Git fixture through the normal session deep link.")
            let gitMenu = app.buttons["Git actions"]
            assertHittable(gitMenu, timeout: 20, message: "The seeded repository must expose Git actions.")
            gitMenu.tap()
            XCTAssertTrue(app.buttons["Push"].waitForExistence(timeout: 10))
            for deferred in ["Fetch", "Pull", "Commit", "Commit & Push"] {
                XCTAssertFalse(app.buttons[deferred].exists, "Deferred action must not be offered: \(deferred)")
            }
            attachScreenshot(named: "slice4-git-supported-menu")
            let staging = app.buttons["Stage Changes…"]
            assertHittable(staging, timeout: 10, message: "Staging must remain reachable from production Git menu.")
            staging.tap()
            XCTAssertTrue(app.navigationBars["Stage Changes"].waitForExistence(timeout: 15))
            for deferred in ["Suggest message", "Commit", "Commit Selected", "Discard Changes"] {
                XCTAssertFalse(app.buttons[deferred].exists)
            }
            attachScreenshot(named: "slice4-git-staging-only")
            app.buttons["Done"].tap()
            // Read-only navigation check: never tap Push, stage, or branch writes.
            return
        }

        if environment["SEMREH_SLICE3_APP_KILL_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 app-kill UI requires the pinned stock backend.")
                return
            }
            guard let storedID = environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"],
                  storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Slice 3 app-kill UI requires a valid pre-seeded durable session ID.")
                return
            }
            let seedMarker = environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"] ?? tuiSeedMarker
            guard seedMarker.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Slice 3 app-kill UI requires a bounded synthetic seed marker.")
                return
            }
            try await exerciseOptInActiveAppKill(
                app: app,
                storedID: storedID,
                seedMarker: seedMarker,
                credentials: credentials
            )
            return
        }

        if environment["SEMREH_SLICE3_RELAUNCH_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 relaunch UI requires the pinned stock backend.")
                return
            }
            guard let storedID = environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"],
                  storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Slice 3 relaunch UI requires a valid pre-seeded durable session ID.")
                return
            }
            let seedMarker = environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"] ?? tuiSeedMarker
            guard seedMarker.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Slice 3 relaunch UI requires a bounded synthetic seed marker.")
                return
            }
            try exerciseOptInAppRelaunch(app: app, storedID: storedID, seedMarker: seedMarker)
            return
        }

        let sessionsTab = app.buttons["Sessions"]
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 10), "Successful login must reach the production shell.")
        sessionsTab.tap()
        let newSession = app.buttons["New chat"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15), "Sessions must expose New chat.")
        attachScreenshot(named: "live-production-authenticated-sessions")
        newSession.tap()

        let defaultBot = app.buttons["bot-profile:default"]
        if defaultBot.waitForExistence(timeout: 5) {
            XCTAssertTrue(defaultBot.isHittable)
            defaultBot.tap()
        }

        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        // SwiftUI propagates ChatView's identifier onto its UIKit text view.
        // Target the actual editable descendant observed in the AX hierarchy.
        let composers = app.descendants(matching: .any).matching(identifier: "chat-composer-input")
        let composer = composers.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composers.count, 1, "The open conversation must expose one composer.")
        composer.tap()
        composer.typeText("SEMREH_SLICE1_PROMPT")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()

        let acknowledgement = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_SLICE1_ACK")
        ).firstMatch
        let appeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: acknowledgement
        )
        await fulfillment(of: [appeared], timeout: 90)
        XCTAssertTrue(acknowledgement.exists && acknowledgement.isHittable)
        attachScreenshot(named: "live-production-chat-success")

        if environment["SEMREH_SLICE4_BTW_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 4 BTW UI requires the pinned stock backend.")
                return
            }
            // The deterministic ACK can arrive as a delta before the terminal
            // message.complete. BTW intentionally requires an idle main turn,
            // so wait for the production action control to leave Stop state.
            waitForIdle(app: app)
            exerciseOptInDirectBTWFlow(app: app, composer: composer)
            return
        }

        if environment["SEMREH_SLICE4_BACKGROUND_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 4 background UI requires the pinned stock backend.")
                return
            }
            waitForIdle(app: app)
            exerciseOptInDirectBackgroundFlow(app: app, composer: composer)
            return
        }

        if environment["SEMREH_SLICE4_BRANCH_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 4 branch UI requires the pinned stock backend.")
                return
            }
            exerciseOptInDirectBranchFlow(app: app, parentComposer: composer)
            return
        }

        if environment["SEMREH_SLICE3_ATTACHMENT_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 attachment UI requires the pinned stock backend.")
                return
            }
            exerciseOptInDirectAttachmentFlow(app: app)
        }

        if environment["SEMREH_SLICE3_FILE_PICKER_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 Files picker UI requires the pinned stock backend.")
                return
            }
            exerciseOptInFilePickerFlow(app: app)
            return
        }

        if environment["SEMREH_SLICE3_CLARIFICATION_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 clarification UI requires the pinned stock backend.")
                return
            }
            exerciseOptInClarificationFlow(app: app)
        }

        if environment["SEMREH_SLICE3_BLOCKING_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 blocking UI requires the pinned stock backend.")
                return
            }
            exerciseOptInBlockingFlow(app: app)
        }

        if let storedID = environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"] {
            XCTAssertNotNil(storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression))
            var link = URLComponents()
            link.scheme = "semreh"
            link.host = "session"
            link.queryItems = [URLQueryItem(name: "id", value: storedID)]
            app.open(try XCTUnwrap(link.url))
            let tuiPrompt = app.staticTexts[tuiSeedMarker]
            assertHittable(tuiPrompt, timeout: 30,
                          message: "The actual TUI-created transcript must open through the production deep link.")
            assertHittable(acknowledgement, timeout: 15,
                          message: "The TUI-created assistant reply must also be visible.")
            attachScreenshot(named: "live-tui-created-session-in-semreh")
        }
    }

    @MainActor
    private func exerciseOptInDirectBTWFlow(app: XCUIApplication, composer: XCUIElement) {
        let question = "SEMREH_SLICE4_BTW_UI_\(UUID().uuidString)"
        composer.tap()
        composer.typeText("/btw \(question)")

        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The production composer must allow the BTW command.")
        send.tap()

        let questionText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", question)
        ).firstMatch
        assertHittable(questionText, timeout: 45,
                       message: "The local BTW card must retain its unique question.")

        XCTAssertNotNil(
            correlatedCardAnswer(app: app, anchor: questionText, answerText: slice1Acknowledgement),
            "The same local BTW card must replace its placeholder with the final stock answer."
        )
        attachScreenshot(named: "slice4-btw-local-answer")
    }

    @MainActor
    private func exerciseOptInDirectBackgroundFlow(app: XCUIApplication, composer: XCUIElement) {
        let prompt = "BG_\(UUID().uuidString): reply exactly \(slice1Acknowledgement)"
        XCTAssertLessThanOrEqual(prompt.count, 80)
        composer.tap()
        composer.typeText("/background \(prompt)")
        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The production composer must allow the background command.")
        send.tap()

        let promptText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", prompt)).firstMatch
        assertHittable(promptText, timeout: 45, message: "The local Background card must retain its unique prompt.")
        XCTAssertNotNil(
            correlatedCardAnswer(app: app, anchor: promptText, answerText: slice1Acknowledgement),
            "The correlated Background card must show the expected stock answer."
        )
        attachScreenshot(named: "slice4-background-local-answer")
    }

    @MainActor
    private func correlatedCardAnswer(
        app: XCUIApplication,
        anchor: XCUIElement,
        answerText: String
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(90)
        var correlatedAnswer: XCUIElement?
        repeat {
            correlatedAnswer = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", answerText)
            ).allElementsBoundByIndex.first { answer in
                answer.exists && answer.isHittable
                    && answer.frame.minY >= anchor.frame.maxY
                    && answer.frame.minY - anchor.frame.maxY < 160
                    && abs(answer.frame.minX - anchor.frame.minX) < 40
            }
            if correlatedAnswer != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return correlatedAnswer
    }

    @MainActor
    private func exerciseOptInDirectBranchFlow(
        app: XCUIApplication,
        parentComposer: XCUIElement
    ) {
        let parentIdentifier = parentComposer.identifier
        XCTAssertTrue(parentIdentifier.hasPrefix("chat-detail:"))

        parentComposer.tap()
        parentComposer.typeText("/branch")
        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The production composer must allow the branch command.")
        send.tap()

        let deadline = Date().addingTimeInterval(45)
        var childComposer: XCUIElement?
        repeat {
            childComposer = app.textViews.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).allElementsBoundByIndex.first {
                $0.exists && $0.isHittable && $0.identifier != parentIdentifier
            }
            if childComposer != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        guard let childComposer else {
            XCTFail("The branch command must navigate to a distinct retained child chat.")
            return
        }

        let copiedDeadline = Date().addingTimeInterval(20)
        var copiedAcknowledgement: XCUIElement?
        repeat {
            copiedAcknowledgement = app.staticTexts.matching(
                NSPredicate(format: "label == %@", slice1Acknowledgement)
            ).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            if copiedAcknowledgement != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < copiedDeadline
        XCTAssertNotNil(copiedAcknowledgement, "The child must display the copied parent acknowledgement.")
        attachScreenshot(named: "slice4-branch-child-copied-history")

        let childPrompt = "SEMREH_SLICE4_BRANCH_CHILD_\(UUID().uuidString)"
        childComposer.tap()
        childComposer.typeText(childPrompt)
        assertHittable(send, timeout: 10, message: "The retained child composer must allow an independent turn.")
        send.tap()
        let childPromptElement = app.staticTexts.matching(
            NSPredicate(format: "label == %@", childPrompt)
        ).firstMatch
        assertHittable(childPromptElement, timeout: 20, message: "The exact child-only prompt must appear.")
        XCTAssertNotNil(
            waitForVisibleAcknowledgement(below: childPromptElement, app: app),
            "The child-only turn must complete with exactly one visible fixture acknowledgement."
        )
        attachScreenshot(named: "slice4-branch-child-independent-turn")

        let back = app.buttons["BackButton"]
        assertHittable(back, timeout: 10, message: "The child chat must provide production back navigation.")
        back.tap()
        let parentPrompt = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "SEMREH_SLICE1_PROMPT")
        ).firstMatch
        assertHittable(parentPrompt, timeout: 20, message: "Back navigation must restore the parent transcript.")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label == %@", childPrompt))
                .allElementsBoundByIndex.contains { $0.exists && $0.isHittable },
            "The independent child prompt must not appear in the parent transcript."
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label == %@", slice1Acknowledgement))
                .allElementsBoundByIndex.contains { $0.exists && $0.isHittable },
            "The parent acknowledgement must remain visible and unchanged."
        )
        attachScreenshot(named: "slice4-branch-parent-unchanged")
    }

    @MainActor
    private func exerciseOptInPromptUncertainty(
        app: XCUIApplication,
        storedID: String,
        seedMarker: String,
        credentials: DisposableCredentials
    ) async throws {
        let observer = try await RelaunchCanonicalObserver(
            origin: try XCTUnwrap(URL(string: approvedLiveOrigin)),
            credentials: credentials
        )
        defer { observer.invalidate() }

        try openPromptUncertaintySeedIfNeeded(app: app, storedID: storedID, seedMarker: seedMarker)
        let baseline = try await waitForCanonicalTranscript(
            observer: observer,
            storedID: storedID,
            timeout: 15
        ) { page in
            self.matchesPromptUncertaintyBaseline(page, storedID: storedID, seedMarker: seedMarker)
        }
        try await assertPromptUncertaintyTranscriptVisible(app: app, seedMarker: seedMarker)
        assertComposerEmpty(app: app)
        _ = try requirePromptUncertaintyControls(
            app: app,
            failureScreenshot: "slice3-uncertainty-warning-missing-before-relaunch",
            context: "The fresh fixture must expose its uncertainty warning before relaunch."
        )
        attachScreenshot(named: "slice3-uncertainty-before-relaunch")

        app.terminate()
        app.launchArguments = []
        app.launch()
        try await waitForPromptUncertaintyEntryReadiness(app: app, seedMarker: seedMarker)
        try openPromptUncertaintySeedIfNeeded(app: app, storedID: storedID, seedMarker: seedMarker)
        try await assertPromptUncertaintyTranscriptVisible(app: app, seedMarker: seedMarker)
        assertComposerEmpty(app: app)
        attachScreenshot(named: "slice3-uncertainty-after-relaunch")
        let afterRelaunch = try await observer.transcript(storedID: storedID)
        try assertPromptUncertaintyBaseline(afterRelaunch, storedID: storedID, seedMarker: seedMarker)
        XCTAssertTrue(afterRelaunch.rows.elementsEqual(baseline.rows, by: canonicalRowsEqual),
                      "Relaunch must preserve the exact four canonical seed rows.")

        let (warning, allowNewMessage) = try requirePromptUncertaintyControls(
            app: app,
            failureScreenshot: "slice3-uncertainty-warning-not-ready",
            context: "The recreated chat must expose its visible uncertainty heading and allow-new-message action."
        )
        allowNewMessage.tap()

        let confirmation = app.alerts["Allow a New Message?"]
        assertHittable(confirmation, timeout: 10,
                       message: "Allow-new-message must require an explicit confirmation.")
        XCTAssertTrue(confirmation.buttons["Allow a new message"].exists,
                      "The confirmation must name the explicit new-message action.")
        XCTAssertTrue(confirmation.buttons["Cancel"].exists,
                      "The allow-new-message confirmation must expose Cancel.")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 10),
                      "Cancelling the confirmation must preserve the uncertainty warning.")
        assertHittable(allowNewMessage, timeout: 10,
                       message: "Cancelling the confirmation must preserve the recovery action.")
        let afterConfirmationCancel = try await observer.transcript(storedID: storedID)
        try assertPromptUncertaintyBaseline(
            afterConfirmationCancel,
            storedID: storedID,
            seedMarker: seedMarker
        )
        XCTAssertTrue(afterConfirmationCancel.rows.elementsEqual(baseline.rows, by: canonicalRowsEqual),
                      "Cancelling the confirmation must preserve the exact canonical seed transcript.")
        attachScreenshot(named: "slice3-uncertainty-confirmation-cancelled")

        allowNewMessage.tap()
        let confirmed = app.alerts["Allow a New Message?"]
        assertHittable(confirmed, timeout: 10,
                       message: "The second allow-new-message attempt must still require confirmation.")
        XCTAssertTrue(confirmed.buttons["Allow a new message"].exists)
        confirmed.buttons["Allow a new message"].tap()

        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: warning
        )
        await fulfillment(of: [cleared], timeout: 20)
        XCTAssertFalse(warning.exists, "The uncertainty warning must clear after explicit confirmation.")
        XCTAssertFalse(allowNewMessage.exists, "The uncertainty action must clear after explicit confirmation.")
        assertComposerEmpty(app: app)

        let afterAbandon = try await observer.transcript(storedID: storedID)
        try assertPromptUncertaintyBaseline(afterAbandon, storedID: storedID, seedMarker: seedMarker)
        XCTAssertTrue(afterAbandon.rows.elementsEqual(baseline.rows, by: canonicalRowsEqual),
                      "Allowing a fresh message must not mutate the canonical seed transcript.")
        attachScreenshot(named: "slice3-uncertainty-after-abandon")

        let newPrompt = uncertaintyNewPromptPrefix + UUID().uuidString
        sendLivePrompt(newPrompt, app: app, screenshotPrefix: "slice3-uncertainty-new-message")
        let final = try await waitForCanonicalTranscript(
            observer: observer,
            storedID: storedID,
            timeout: 30
        ) { page in
            self.matchesPromptUncertaintyFinal(
                page,
                storedID: storedID,
                seedMarker: seedMarker,
                newPrompt: newPrompt
            )
        }
        try assertPromptUncertaintyFinal(
            final,
            storedID: storedID,
            seedMarker: seedMarker,
            newPrompt: newPrompt
        )
        XCTAssertTrue(final.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual),
                      "The fresh turn must preserve every original canonical row and ID.")
        waitForIdle(app: app)
        assertComposerEmpty(app: app)
        attachPlainText(newPrompt, named: "slice3-uncertainty-new-marker")
        attachScreenshot(named: "slice3-uncertainty-new-message-complete")
    }

    @MainActor
    private func exerciseOptInAppRelaunch(
        app: XCUIApplication,
        storedID: String,
        seedMarker: String
    ) throws {
        try openSeededSession(app: app, storedID: storedID)
        assertSeededTranscriptVisible(app: app, seedMarker: seedMarker, context: "before app termination")
        attachScreenshot(named: "slice3-relaunch-before-terminate")

        app.terminate()
        app.launchArguments = []
        app.launch()
        waitForPostLoginDestination(app: app)

        try openSeededSession(app: app, storedID: storedID)
        assertSeededTranscriptVisible(app: app, seedMarker: seedMarker, context: "after app relaunch")
        attachScreenshot(named: "slice3-relaunch-after-terminate")

        let uniquePrompt = "SEMREH_SLICE3_RELAUNCH_\(UUID().uuidString)"
        sendLivePrompt(uniquePrompt, app: app, screenshotPrefix: "slice3-relaunch-follow-up")
        waitForAcknowledgementCount(
            2,
            app: app,
            message: "The relaunch follow-up must add exactly one terminal fixture ACK."
        )
        waitForIdle(app: app)
        attachScreenshot(named: "slice3-relaunch-follow-up-complete")
    }

    @MainActor
    private func exerciseOptInActiveAppKill(
        app: XCUIApplication,
        storedID: String,
        seedMarker: String,
        credentials: DisposableCredentials
    ) async throws {
        try openSeededSession(app: app, storedID: storedID)
        assertSeededTranscriptVisible(app: app, seedMarker: seedMarker, context: "before app termination")
        let observer = try await RelaunchCanonicalObserver(
            origin: try XCTUnwrap(URL(string: approvedLiveOrigin)),
            credentials: credentials
        )
        defer { observer.invalidate() }
        let baseline = try await observer.transcript(storedID: storedID)
        try assertExactCanonicalRows(
            baseline,
            storedID: storedID,
            users: [seedMarker],
            assistants: [slice1Acknowledgement]
        )

        let uniquePrompt = "SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_APP_KILL_\(UUID().uuidString)"
        sendLivePrompt(uniquePrompt, app: app, screenshotPrefix: "slice3-app-kill-accepted")
        attachPlainText(uniquePrompt, named: "slice3-app-kill-marker")
        let accepted = try await waitForCanonicalTranscript(
            observer: observer,
            storedID: storedID,
            timeout: 8
        ) { page in
            self.matchesExactCanonicalRows(
                page,
                storedID: storedID,
                users: [seedMarker, uniquePrompt],
                assistants: [self.slice1Acknowledgement]
            )
        }
        XCTAssertTrue(accepted.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual))
        attachScreenshot(named: "slice3-app-kill-before-terminate")

        // This is the real XCTest process-death operation. No launch argument
        // resets the app's persisted server/auth state on the second launch.
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "The accepted run must outlive an actually terminated app process.")

        // A first still-incomplete read after termination removes the race where
        // the fixture could have completed just before XCTest killed the app.
        let firstPostKill = try await observer.transcript(storedID: storedID)
        XCTAssertEqual(app.state, .notRunning)
        try assertExactCanonicalRows(
            firstPostKill,
            storedID: storedID,
            users: [seedMarker, uniquePrompt],
            assistants: [slice1Acknowledgement]
        )
        XCTAssertTrue(firstPostKill.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual))

        let completedWhileDead = try await waitForCanonicalTranscript(
            observer: observer,
            storedID: storedID,
            timeout: 30,
            beforeEachRead: {
                XCTAssertEqual(app.state, .notRunning, "The app must remain dead until canonical completion.")
            }
        ) { page in
            self.matchesExactCanonicalRows(
                page,
                storedID: storedID,
                users: [seedMarker, uniquePrompt],
                assistants: [self.slice1Acknowledgement, self.slice1Acknowledgement]
            )
        }
        XCTAssertEqual(app.state, .notRunning)
        XCTAssertTrue(completedWhileDead.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual))

        app.launchArguments = []
        app.launch()
        waitForPostLoginDestination(app: app)

        try openSeededSession(app: app, storedID: storedID)
        assertSeededTranscriptVisible(app: app, seedMarker: seedMarker, context: "after app relaunch")
        let uniqueUserRows = app.staticTexts.matching(NSPredicate(format: "label == %@", uniquePrompt))
        XCTAssertEqual(uniqueUserRows.count, 1, "Relaunch must render the accepted prompt exactly once.")
        waitForAcknowledgementCount(
            2,
            app: app,
            message: "Relaunch must render exactly the seeded and recovered fixture ACKs."
        )
        waitForIdle(app: app)
        let composer = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let composerValue = (composer.value as? String) ?? ""
        XCTAssertTrue(
            composerValue.isEmpty || composerValue == composer.placeholderValue,
            "The submitted prompt must not return as a stale composer draft."
        )
        XCTAssertFalse(composerValue.contains(uniquePrompt))

        let finalCanonical = try await observer.transcript(storedID: storedID)
        try assertExactCanonicalRows(
            finalCanonical,
            storedID: storedID,
            users: [seedMarker, uniquePrompt],
            assistants: [slice1Acknowledgement, slice1Acknowledgement]
        )
        XCTAssertTrue(finalCanonical.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual))
        XCTAssertTrue(finalCanonical.rows.elementsEqual(completedWhileDead.rows, by: canonicalRowsEqual))
        attachScreenshot(named: "slice3-app-kill-recovered")
    }

    @MainActor
    private func waitForCanonicalTranscript(
        observer: RelaunchCanonicalObserver,
        storedID: String,
        timeout: TimeInterval,
        beforeEachRead: () -> Void = {},
        matches: (RelaunchCanonicalTranscript) -> Bool
    ) async throws -> RelaunchCanonicalTranscript {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            beforeEachRead()
            let page = try await observer.transcript(storedID: storedID)
            if matches(page) { return page }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw NSError(
            domain: "LongChatScrollUITests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Canonical transcript did not reach the exact expected state before the fixture deadline."]
        )
    }

    @MainActor
    private func assertExactCanonicalRows(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        users: [String],
        assistants: [String]
    ) throws {
        guard matchesExactCanonicalRows(page, storedID: storedID, users: users, assistants: assistants) else {
            throw NSError(
                domain: "LongChatScrollUITests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Canonical transcript did not contain the exact expected user/assistant rows."]
            )
        }
    }

    @MainActor
    private func matchesExactCanonicalRows(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        users: [String],
        assistants: [String]
    ) -> Bool {
        guard page.sessionID == storedID,
              page.rows.count == users.count + assistants.count else { return false }
        let durableIDs = page.rows.compactMap { canonicalDurableRowID($0["id"]) }
        guard durableIDs.count == page.rows.count,
              Set(durableIDs).count == durableIDs.count else { return false }
        let roles = page.rows.compactMap { $0["role"] as? String }
        let texts = page.rows.compactMap(canonicalRowText)
        var expectedRoles: [String] = []
        var expectedTexts: [String] = []
        for index in users.indices {
            expectedRoles.append("user")
            expectedTexts.append(users[index])
            if assistants.indices.contains(index) {
                expectedRoles.append("assistant")
                expectedTexts.append(assistants[index])
            }
        }
        return roles == expectedRoles && texts == expectedTexts
    }

    @MainActor
    private func canonicalDurableRowID(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return "s:" + string }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return nil }
        return "n:" + number.stringValue
    }

    @MainActor
    private func canonicalRowText(_ row: [String: Any]) -> String? {
        if let text = row["content"] as? String { return text }
        guard let blocks = row["content"] as? [[String: Any]] else { return nil }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    @MainActor
    private func canonicalRowsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(NSDictionary(dictionary: rhs))
    }

    @MainActor
    private func openSeededSession(app: XCUIApplication, storedID: String) throws {
        var link = URLComponents()
        link.scheme = "semreh"
        link.host = "session"
        link.queryItems = [URLQueryItem(name: "id", value: storedID)]
        app.open(try XCTUnwrap(link.url))
    }

    @MainActor
    private func assertSeededTranscriptVisible(
        app: XCUIApplication,
        seedMarker: String,
        context: String
    ) {
        let prompt = app.staticTexts.matching(
            NSPredicate(format: "label == %@", seedMarker)
        ).firstMatch
        assertHittable(
            prompt,
            timeout: 30,
            message: "The pre-seeded session must expose its marker (\(context))."
        )
        let acknowledgement = app.staticTexts.matching(
            NSPredicate(format: "label == %@", slice1Acknowledgement)
        ).firstMatch
        assertHittable(
            acknowledgement,
            timeout: 15,
            message: "The pre-seeded session must expose its terminal ACK (\(context))."
        )
    }

    @MainActor
    private func waitForPromptUncertaintyEntryReadiness(
        app: XCUIApplication,
        seedMarker: String
    ) async throws {
        let seed = app.staticTexts.matching(NSPredicate(format: "label == %@", seedMarker)).firstMatch
        let sessions = app.buttons["Sessions"]
        let knownBackButton = app.navigationBars.buttons["BackButton"]
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        let serverField = app.textFields["onboarding-server-url"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let onboardingIsAbsent = !welcome.exists && !serverField.exists
            if onboardingIsAbsent,
               (seed.exists && seed.isHittable
                || sessions.exists && sessions.isHittable
                || knownBackButton.exists && knownBackButton.isHittable) {
                attachScreenshot(named: "slice3-uncertainty-entry-ready")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        attachScreenshot(named: "slice3-uncertainty-entry-not-ready")
        XCTFail("Uncertainty recovery login must reach the exact seed, the Sessions shell, or a known restored chat without onboarding.")
        throw NSError(domain: "SemrehUncertaintyUI", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "The uncertainty recovery entry point was not ready; stopping before navigation assertions."
        ])
    }

    @MainActor
    private func openPromptUncertaintySeedIfNeeded(
        app: XCUIApplication,
        storedID: String,
        seedMarker: String
    ) throws {
        let seed = app.staticTexts.matching(NSPredicate(format: "label == %@", seedMarker)).firstMatch
        // Normal login/relaunch may already restore this exact synthetic chat.
        // XCUIApplication.open can launch a new process; don't add that distinct
        // cold-URL boundary to a test of an already-restored conversation.
        attachScreenshot(named: "slice3-uncertainty-before-ensure-chat")
        if seed.exists && seed.isHittable { return }
        let backButton = app.navigationBars.buttons["BackButton"]
        if backButton.exists && backButton.isHittable {
            let restoredChat = app.otherElements.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch
            backButton.tap()
            let leftRestoredChat = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: restoredChat
            )
            wait(for: [leftRestoredChat], timeout: 15)
            let sessions = app.buttons["Sessions"]
            guard !restoredChat.exists,
                  sessions.waitForExistence(timeout: 15), sessions.isHittable else {
                attachScreenshot(named: "slice3-uncertainty-restored-chat-back-failed")
                XCTFail("The known restored chat must navigate back to the Sessions shell before opening a different seed.")
                throw NSError(domain: "SemrehUncertaintyUI", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "The restored chat could not return to Sessions; stopping before the seed URL launch."
                ])
            }
        }
        try openSeededSession(app: app, storedID: storedID)
        attachScreenshot(named: "slice3-uncertainty-after-open-url")
    }

    @MainActor
    private func requirePromptUncertaintyControls(
        app: XCUIApplication,
        failureScreenshot: String,
        context: String
    ) throws -> (warning: XCUIElement, allowNewMessage: XCUIElement) {
        let warning = app.staticTexts[uncertaintyBannerIdentifier]
        let allowNewMessage = app.buttons[uncertaintyAllowIdentifier]
        guard warning.waitForExistence(timeout: 15), warning.isHittable,
              allowNewMessage.waitForExistence(timeout: 10), allowNewMessage.isHittable else {
            attachScreenshot(named: failureScreenshot)
            XCTFail(context)
            throw NSError(domain: "SemrehUncertaintyUI", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "The uncertainty warning controls were not ready; stopping before recovery actions."
            ])
        }
        return (warning, allowNewMessage)
    }

    @MainActor
    private func assertPromptUncertaintyTranscriptVisible(
        app: XCUIApplication,
        seedMarker: String
    ) async throws {
        let seed = app.staticTexts.matching(NSPredicate(format: "label == %@", seedMarker)).firstMatch
        let delayed = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", uncertaintyDelayedPromptPrefix)
        ).firstMatch
        let visible = NSPredicate(format: "exists == true AND hittable == true")
        await fulfillment(of: [
            XCTNSPredicateExpectation(predicate: visible, object: seed),
            XCTNSPredicateExpectation(predicate: visible, object: delayed)
        ], timeout: 15)
        guard seed.exists && seed.isHittable && delayed.exists && delayed.isHittable else {
            attachScreenshot(named: "slice3-uncertainty-missing-seed")
            throw NSError(domain: "SemrehUncertaintyUI", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The exact uncertainty chat was not visible; stopping before recovery actions."
            ])
        }
    }

    @MainActor
    private func assertComposerEmpty(app: XCUIApplication) {
        let composer = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15),
                      "The uncertainty chat must expose its production composer.")
        let value = (composer.value as? String) ?? ""
        XCTAssertTrue(value.isEmpty || value == composer.placeholderValue,
                      "The uncertainty recovery action must leave the composer empty.")
    }

    @MainActor
    private func matchesPromptUncertaintyBaseline(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        seedMarker: String
    ) -> Bool {
        guard page.sessionID == storedID, page.rows.count == 4 else { return false }
        let durableIDs = page.rows.compactMap { canonicalDurableRowID($0["id"]) }
        guard durableIDs.count == 4, Set(durableIDs).count == 4 else { return false }
        let roles = page.rows.compactMap { $0["role"] as? String }
        let texts = page.rows.compactMap(canonicalRowText)
        guard roles == ["user", "assistant", "user", "assistant"], texts.count == 4 else {
            return false
        }
        return texts[0] == seedMarker
            && texts[1] == slice1Acknowledgement
            && texts[2].hasPrefix(uncertaintyDelayedPromptPrefix)
            && texts[3] == slice1Acknowledgement
    }

    @MainActor
    private func assertPromptUncertaintyBaseline(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        seedMarker: String
    ) throws {
        guard matchesPromptUncertaintyBaseline(page, storedID: storedID, seedMarker: seedMarker) else {
            throw NSError(
                domain: "LongChatScrollUITests",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "The uncertainty seed transcript must contain exactly two canonical user/assistant pairs."]
            )
        }
    }

    @MainActor
    private func matchesPromptUncertaintyFinal(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        seedMarker: String,
        newPrompt: String
    ) -> Bool {
        guard page.sessionID == storedID, page.rows.count == 6 else { return false }
        let durableIDs = page.rows.compactMap { canonicalDurableRowID($0["id"]) }
        guard durableIDs.count == 6, Set(durableIDs).count == 6 else { return false }
        let roles = page.rows.compactMap { $0["role"] as? String }
        let texts = page.rows.compactMap(canonicalRowText)
        guard roles == ["user", "assistant", "user", "assistant", "user", "assistant"], texts.count == 6 else {
            return false
        }
        return texts[0] == seedMarker
            && texts[1] == slice1Acknowledgement
            && texts[2].hasPrefix(uncertaintyDelayedPromptPrefix)
            && texts[3] == slice1Acknowledgement
            && texts[4] == newPrompt
            && texts[5] == slice1Acknowledgement
    }

    @MainActor
    private func assertPromptUncertaintyFinal(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        seedMarker: String,
        newPrompt: String
    ) throws {
        guard matchesPromptUncertaintyFinal(page, storedID: storedID, seedMarker: seedMarker, newPrompt: newPrompt) else {
            throw NSError(
                domain: "LongChatScrollUITests",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "The uncertainty new-message turn must contain exactly three canonical user/assistant pairs."]
            )
        }
    }

    @MainActor
    private func waitForAcknowledgementCount(
        _ expected: Int,
        app: XCUIApplication,
        message: String
    ) {
        let deadline = Date().addingTimeInterval(90)
        let acknowledgements = app.staticTexts.matching(
            NSPredicate(format: "label == %@", slice1Acknowledgement)
        )
        while acknowledgements.count < expected && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(acknowledgements.count, expected, message)
    }

    @MainActor
    private func waitForVisibleAcknowledgement(
        below prompt: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval = 90
    ) -> XCUIElement? {
        let acknowledgements = app.staticTexts.matching(
            NSPredicate(format: "label == %@", slice1Acknowledgement)
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if prompt.exists && prompt.isHittable {
                if let acknowledgement = acknowledgements.allElementsBoundByIndex.first(where: {
                    $0.exists && $0.isHittable && $0.frame.minY >= prompt.frame.maxY
                }) {
                    let belowPrompt = acknowledgements.allElementsBoundByIndex.filter {
                        $0.exists && $0.isHittable && $0.frame.minY >= prompt.frame.maxY
                    }
                    XCTAssertEqual(
                        belowPrompt.count,
                        1,
                        "The new prompt must have exactly one visible fixture ACK below it."
                    )
                    return acknowledgement
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("The Files picker turn must expose a visible terminal ACK below its exact new prompt.")
        return nil
    }

    @MainActor
    private func exerciseOptInDirectAttachmentFlow(app: XCUIApplication) {
        let composers = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        )
        let composer = composers.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The production chat must expose its composer for attachment staging.")
        let chatDetailIdentifier = composer.identifier
        XCTAssertTrue(
            chatDetailIdentifier.hasPrefix("chat-detail:"),
            "The attachment flow must remain scoped to the actual production chat identifier."
        )

        composer.tap()
        pastePNG(knownPNGData, into: composer, app: app)

        let chip = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Open attachment '")
        ).firstMatch
        assertHittable(
            chip,
            timeout: 15,
            message: "Pasting a PNG through the native composer must expose an attachment chip."
        )
        attachScreenshot(named: "slice3-attachment-chip")
        let attachmentName = chip.label.replacingOccurrences(of: "Open attachment ", with: "")
        XCTAssertFalse(attachmentName.isEmpty, "The native attachment chip must expose its generated filename.")

        chip.tap()
        let previewTitle = app.navigationBars.staticTexts[attachmentName]
        XCTAssertTrue(
            previewTitle.waitForExistence(timeout: 10),
            "Opening the attachment chip must present the native memory preview."
        )
        let previewImage = app.images[attachmentName]
        XCTAssertTrue(
            previewImage.waitForExistence(timeout: 10),
            "The direct PNG preview must render from retained memory bytes."
        )
        let done = app.buttons["Done"]
        assertHittable(done, timeout: 5, message: "The attachment preview must expose Done.")
        done.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: previewImage
        )
        wait(for: [dismissed], timeout: 10)
        XCTAssertFalse(previewImage.exists, "Dismissing the attachment preview must return to the composer.")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Dismissing preview must retain the pending attachment chip.")

        let priorAcknowledgementCount = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_SLICE1_ACK")
        ).count
        let prompt = "SEMREH_SLICE3_ATTACHMENT_UI_PROMPT_\(UUID().uuidString)"
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The composer Send action must be available after attachment staging.")
        send.tap()

        // Stock canonical history appends its image reference to the user text.
        // Match this run's exact marker prefix, not a previous warm-up response.
        let marker = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", prompt, prompt + "\n")
        ).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "The unique attachment prompt must appear in the transcript.")
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            // The broad discovery query can now resolve to the new canonical
            // transcript cell. Check the exact original composer filename.
            object: app.buttons["Open attachment " + attachmentName]
        )
        wait(for: [cleared], timeout: 20)
        XCTAssertFalse(app.buttons["Open attachment " + attachmentName].exists,
                       "Sending must clear the staged attachment chip.")

        let acknowledgement = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_SLICE1_ACK")
        )
        let newAcknowledgement = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > %d", priorAcknowledgementCount),
            object: acknowledgement
        )
        wait(for: [newAcknowledgement], timeout: 90)
        XCTAssertGreaterThan(
            acknowledgement.count,
            priorAcknowledgementCount,
            "The attachment turn must produce a new terminal ACK beyond the warm-up response."
        )
        waitForIdle(app: app)
        let canonicalAttachment = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Open attachment upload_'")
        ).firstMatch
        XCTAssertTrue(canonicalAttachment.waitForExistence(timeout: 15),
                      "Canonical image references must become attachment cells.")
        if !canonicalAttachment.isHittable {
            app.scrollViews.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch.swipeDown()
        }
        assertHittable(canonicalAttachment, timeout: 10,
                       message: "The canonical attachment must be reachable in the transcript.")
        let canonicalName = canonicalAttachment.label.replacingOccurrences(of: "Open attachment ", with: "")
        canonicalAttachment.tap()
        let canonicalImage = app.images[canonicalName]
        XCTAssertTrue(canonicalImage.waitForExistence(timeout: 15),
                      "The canonical image preview must load through the authenticated stock media route.")
        attachScreenshot(named: "slice3-attachment-canonical-media-preview")
        app.buttons["Done"].tap()
        let canonicalDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: canonicalImage
        )
        wait(for: [canonicalDismissed], timeout: 10)
        XCTAssertFalse(app.buttons["discard-pending-upload"].exists,
                       "A normally completed known upload must not leave an unresolved-upload recovery banner.")
        attachPlainText(
            "\(chatDetailIdentifier)\n\(prompt)",
            named: "slice3-attachment-chat-title-and-marker"
        )
        attachScreenshot(named: "slice3-attachment-send-success")
    }

    @MainActor
    private func exerciseOptInFilePickerFlow(app: XCUIApplication) {
        let composers = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        )
        let composer = composers.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The production chat must expose its composer for Files picker attachment staging.")
        let textPrompt = "SEMREH_SLICE3_FILE_PICKER_TEXT_\(UUID().uuidString)"
        let pdfPrompt = "SEMREH_SLICE3_FILE_PICKER_PDF_\(UUID().uuidString)"
        attachPlainText("\(textPrompt)\n\(pdfPrompt)", named: "slice3-file-picker-prompts")

        exerciseFilePickerTurn(
            filename: "semreh-picker.txt",
            prompt: textPrompt,
            expectedText: "SEMREH_FILE_PICKER_TEXT_V1",
            expectedPDF: false,
            app: app,
            composer: composer
        )
        exerciseFilePickerTurn(
            filename: "semreh-picker.pdf",
            prompt: pdfPrompt,
            expectedText: nil,
            expectedPDF: true,
            app: app,
            composer: composer
        )
        XCTAssertFalse(
            app.buttons["discard-pending-upload"].exists,
            "Completed Files picker turns must not leave an unresolved-upload recovery banner."
        )
        attachScreenshot(named: "slice3-file-picker-roundtrip-complete")
    }

    @MainActor
    private func exerciseFilePickerTurn(
        filename: String,
        prompt: String,
        expectedText: String?,
        expectedPDF: Bool,
        app: XCUIApplication,
        composer: XCUIElement
    ) {
        let canonicalQuery = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Open attachment '")
        )
        let baselineCanonicalLabels = Set(canonicalQuery.allElementsBoundByIndex.map(\.label))
        guard openSyntheticFileFromDocumentPicker(filename: filename, app: app) else { return }

        let chip = app.buttons["Open attachment \(filename)"]
        assertHittable(
            chip,
            timeout: 20,
            message: "Selecting \(filename) through the production Files picker must expose its composer chip."
        )
        XCTAssertTrue(app.buttons["Remove attachment \(filename)"].exists)
        if expectedPDF {
            chip.tap()
            let localPDF = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "PDF document \(filename)")
            ).firstMatch
            guard localPDF.waitForExistence(timeout: 20), localPDF.isHittable else {
                attachAccessibilitySnapshot(named: "slice3-file-picker-local-pdf-not-found", app: app)
                attachScreenshot(named: "slice3-file-picker-local-pdf-not-found")
                XCTFail("The selected PDF must expose the local native PDF preview before sending.")
                return
            }
            let localDone = app.buttons["Done"]
            assertHittable(localDone, timeout: 10, message: "The local PDF preview must expose Done.")
            localDone.tap()
            assertHittable(chip, timeout: 10, message: "Closing the local PDF preview must retain the staged chip.")
        }
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The Files picker attachment turn must expose Send.")
        send.tap()

        let promptElement = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", prompt, prompt + "\n")
        ).firstMatch
        assertHittable(promptElement, timeout: 25, message: "The Files picker prompt must appear in the transcript.")
        let removeChip = app.buttons["Remove attachment \(filename)"]
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: removeChip
        )
        wait(for: [cleared], timeout: 20)
        XCTAssertFalse(removeChip.exists, "Sending \(filename) must clear its staged composer chip.")

        guard waitForVisibleAcknowledgement(below: promptElement, app: app) != nil else { return }
        waitForIdle(app: app)

        guard let canonical = waitForExactlyOneNewCanonicalAttachment(
            app: app,
            baselineLabels: baselineCanonicalLabels
        ) else { return }
        assertHittable(
            canonical,
            timeout: 25,
            message: "The server-returned \(filename) attachment must be reachable in the transcript."
        )
        let canonicalName = canonical.label.replacingOccurrences(of: "Open attachment ", with: "")
        canonical.tap()

        let previewElement: XCUIElement
        if let expectedText {
            let text = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", expectedText)
            ).firstMatch
            assertHittable(text, timeout: 20, message: "The returned text attachment must render its exact fixture content.")
            XCTAssertTrue(text.label.contains("Synthetic file used only for the isolated Semreh migration test."))
            previewElement = text
        } else if expectedPDF {
            let pageImage = app.images[canonicalName]
            assertHittable(pageImage, timeout: 20, message: "The sent PDF must return a native page-image preview.")
            previewElement = pageImage
        } else {
            XCTFail("The Files picker roundtrip must specify a preview assertion.")
            return
        }

        attachScreenshot(named: "slice3-file-picker-returned-\(filename)")
        attachPlainText(prompt, named: "slice3-file-picker-marker-\(filename)")
        let done = app.buttons["Done"]
        assertHittable(done, timeout: 10, message: "The Files picker attachment preview must expose Done.")
        done.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: previewElement
        )
        wait(for: [dismissed], timeout: 10)
        XCTAssertFalse(previewElement.exists, "Dismissing the Files picker preview must return to the composer/transcript.")
    }

    @MainActor
    private func waitForExactlyOneNewCanonicalAttachment(
        app: XCUIApplication,
        baselineLabels: Set<String>,
        timeout: TimeInterval = 25
    ) -> XCUIElement? {
        let canonicalQuery = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Open attachment '")
        )
        let newCanonicalQuery = canonicalQuery.matching(
            NSPredicate(format: "NOT (label IN %@)", Array(baselineLabels))
        )
        let returnedAttachmentAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: newCanonicalQuery
        )
        wait(for: [returnedAttachmentAppeared], timeout: timeout)
        let newCanonical = newCanonicalQuery.allElementsBoundByIndex
        XCTAssertEqual(
            newCanonical.count,
            1,
            "The one-page/file turn must add exactly one server-returned attachment cell beyond the prior transcript."
        )
        return newCanonical.first
    }

    @MainActor
    private func openSyntheticFileFromDocumentPicker(filename: String, app: XCUIApplication) -> Bool {
        let options = app.buttons["Composer options"]
        assertHittable(options, timeout: 10, message: "The production composer must expose Composer options.")
        options.tap()

        let attachFile = app.buttons["Attach File"]
        guard attachFile.waitForExistence(timeout: 10), attachFile.isHittable else {
            attachAccessibilitySnapshot(named: "slice3-file-picker-menu-not-found", app: app)
            XCTFail("Composer options must expose Attach File.")
            return false
        }
        attachFile.tap()

        // The first presentation normally opens Recents. Navigate through the
        // stock Browse/On My iPhone hierarchy; subsequent presentations may
        // remember the owned fixture folder, so both steps are conditional.
        let browse = app.buttons["Browse"]
        if browse.waitForExistence(timeout: 5) && browse.isHittable {
            browse.tap()
        }
        let onMyIPhone = app.buttons["On My iPhone"]
        if onMyIPhone.waitForExistence(timeout: 10) && onMyIPhone.isHittable {
            onMyIPhone.tap()
        }

        // Files hides extensions visually, but exposes basename/type in its
        // cell identifier (captured from the real system picker).
        let fileURL = URL(fileURLWithPath: filename)
        let file = app.cells["\(fileURL.deletingPathExtension().lastPathComponent), \(fileURL.pathExtension)"]
        // Files remembers the last directory after the first selection. If
        // the exact owned fixture is already visible, select it directly;
        // otherwise navigate through the seeded folder.
        if !file.waitForExistence(timeout: 5) {
            let folder = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "SemrehSyntheticFixtures")
            ).firstMatch
            guard folder.waitForExistence(timeout: 20), folder.isHittable else {
                attachAccessibilitySnapshot(named: "slice3-file-picker-folder-not-found", app: app)
                attachScreenshot(named: "slice3-file-picker-folder-not-found")
                XCTFail("The system Files picker must expose the owned synthetic fixture folder.")
                return false
            }
            folder.tap()
        }
        guard file.waitForExistence(timeout: 15), file.isHittable else {
            attachAccessibilitySnapshot(named: "slice3-file-picker-file-not-found", app: app)
            attachScreenshot(named: "slice3-file-picker-file-not-found")
            XCTFail("The system Files picker must expose \(filename).")
            return false
        }
        file.tap()

        let open = app.buttons["Open"]
        guard open.waitForExistence(timeout: 10), open.isHittable else {
            attachAccessibilitySnapshot(named: "slice3-file-picker-open-not-found", app: app)
            attachScreenshot(named: "slice3-file-picker-open-not-found")
            XCTFail("The system Files picker must expose Open after selecting \(filename).")
            return false
        }
        open.tap()
        let pickerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: file
        )
        wait(for: [pickerDismissed], timeout: 15)
        return true
    }

    @MainActor
    private func exerciseOptInClarificationFlow(app: XCUIApplication) {
        // The model fixture uses exact markers. Each response is followed by a
        // distinct ordinary turn so this test proves the blocking request was
        // released; a previous ACK alone is not evidence of terminal delivery.
        runSingleClarificationAnswer(app: app)
        runSingleClarificationCancel(app: app)
        runCancelOnlyClarification(
            marker: clarificationBatchMarker,
            question: "multi-question clarification",
            acknowledgement: batchCancelAcknowledgement,
            screenshotPrefix: "slice3-clarification-batch",
            app: app
        )
        runCancelOnlyClarification(
            marker: clarificationMultiSelectMarker,
            question: "multi-select clarification",
            acknowledgement: multiSelectCancelAcknowledgement,
            screenshotPrefix: "slice3-clarification-multi-select",
            app: app
        )
    }

    @MainActor
    private func exerciseOptInBlockingFlow(app: XCUIApplication) {
        runBlockingApprovalDenial(app: app)
        runBlockingSecretCancellation(app: app)
    }

    @MainActor
    private func runBlockingApprovalDenial(app: XCUIApplication) {
        sendLivePrompt(
            blockingApprovalMarker,
            app: app,
            screenshotPrefix: "slice3-blocking-approval-request"
        )
        let heading = app.staticTexts["Approval required"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 30),
            "The synthetic approval marker must expose the stock approval heading."
        )
        let deny = app.buttons[blockingApprovalDenyIdentifier]
        XCTAssertFalse(app.buttons["approval-request-skip-all"].exists,
                       "Direct approval must not offer the legacy bulk bypass.")
        assertHittable(
            deny,
            timeout: 15,
            message: "The synthetic approval overlay must expose its deny action."
        )
        attachScreenshot(named: "slice3-blocking-approval-request-card")
        deny.tap()
        waitForBlockingElementToClear(
            heading,
            button: deny,
            screenshotName: "slice3-blocking-approval-cleared"
        )
        waitForBlockingAcknowledgement(
            blockingApprovalAcknowledgement,
            app: app,
            screenshotName: "slice3-blocking-approval-follow-up-ack"
        )
    }

    @MainActor
    private func runBlockingSecretCancellation(app: XCUIApplication) {
        sendLivePrompt(
            blockingSecretMarker,
            app: app,
            screenshotPrefix: "slice3-blocking-secret-request"
        )
        let heading = app.staticTexts["Secret required"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 30),
            "The synthetic secret marker must expose the cancel-only heading."
        )
        let explanation = app.staticTexts[
            "This app cannot securely enter this value yet. Cancel to unblock the request without sending a secret."
        ]
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 10),
            "The secret prompt must explain that no secret entry is available."
        )
        XCTAssertEqual(
            app.textFields.count,
            0,
            "The secret cancellation prompt must not expose a regular text input field."
        )
        XCTAssertEqual(
            app.secureTextFields.count,
            0,
            "The secret cancellation prompt must not expose a secure input field."
        )
        let cancel = app.buttons[blockingSecretCancelIdentifier]
        assertHittable(
            cancel,
            timeout: 15,
            message: "The synthetic secret overlay must expose its explicit cancel action."
        )
        attachScreenshot(named: "slice3-blocking-secret-request-card")
        cancel.tap()
        waitForBlockingElementToClear(
            heading,
            button: cancel,
            screenshotName: "slice3-blocking-secret-cleared"
        )
        waitForBlockingAcknowledgement(
            blockingSecretAcknowledgement,
            app: app,
            screenshotName: "slice3-blocking-secret-follow-up-ack"
        )
    }

    @MainActor
    private func waitForBlockingElementToClear(
        _ element: XCUIElement,
        button: XCUIElement,
        screenshotName: String
    ) {
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        wait(for: [cleared], timeout: 30)
        XCTAssertFalse(element.exists, "The blocking prompt must clear after its response.")
        XCTAssertFalse(button.exists, "The blocking action must disappear after its response.")
        attachScreenshot(named: screenshotName)
    }

    @MainActor
    private func waitForBlockingAcknowledgement(
        _ acknowledgement: String,
        app: XCUIApplication,
        screenshotName: String
    ) {
        let terminal = app.staticTexts[acknowledgement]
        assertHittable(
            terminal,
            timeout: 90,
            message: "The blocking response must produce its unique terminal ACK."
        )
        waitForIdle(app: app)
        attachScreenshot(named: screenshotName)
    }

    @MainActor
    private func runSingleClarificationAnswer(app: XCUIApplication) {
        sendLivePrompt(
            clarificationSingleMarker,
            app: app,
            screenshotPrefix: "slice3-clarification-single-answer-request"
        )
        let card = waitForClarificationCard(app: app)
        assertSingleClarificationQuestion(in: card)
        let answer = card.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "answer")
        ).firstMatch
        assertHittable(answer, timeout: 10,
                       message: "Single clarification must expose its advertised answer choice.")
        answer.tap()
        waitForClarificationCardToClear(card,
                                        screenshotName: "slice3-clarification-single-answer-cleared")
        waitForNextTurnSuccess(
            prompt: "SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_ANSWER",
            acknowledgement: singleAnswerAcknowledgement,
            app: app
        )
    }

    @MainActor
    private func runSingleClarificationCancel(app: XCUIApplication) {
        sendLivePrompt(
            clarificationSingleMarker,
            app: app,
            screenshotPrefix: "slice3-clarification-single-cancel-request"
        )
        let card = waitForClarificationCard(app: app)
        assertSingleClarificationQuestion(in: card)
        let cancel = app.buttons[clarificationCancelIdentifier]
        assertHittable(cancel, timeout: 10,
                       message: "Single clarification must expose an explicit cancel action.")
        cancel.tap()
        waitForClarificationCardToClear(card,
                                        screenshotName: "slice3-clarification-single-cancel-cleared")
        waitForNextTurnSuccess(
            prompt: "SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_CANCEL",
            acknowledgement: singleCancelAcknowledgement,
            app: app
        )
    }

    @MainActor
    private func runCancelOnlyClarification(
        marker: String,
        question: String,
        acknowledgement: String,
        screenshotPrefix: String,
        app: XCUIApplication
    ) {
        sendLivePrompt(
            marker,
            app: app,
            screenshotPrefix: screenshotPrefix + "-request"
        )
        let card = waitForClarificationCard(app: app)
        let unsupportedQuestion = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", question)
        ).firstMatch
        XCTAssertTrue(
            unsupportedQuestion.waitForExistence(timeout: 5),
            "The unsupported clarification must render its cancel-only explanation."
        )
        let answer = card.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "answer")
        ).firstMatch
        XCTAssertFalse(answer.exists,
                       "Unsupported clarification must not expose an answer choice.")
        XCTAssertFalse(card.buttons["direct.clarification.submit"].exists,
                       "Unsupported clarification must not expose a submit action.")
        let cancel = app.buttons[clarificationCancelIdentifier]
        assertHittable(cancel, timeout: 10,
                       message: "Unsupported clarification must expose cancel-only dismissal.")
        attachScreenshot(named: screenshotPrefix + "-card")
        cancel.tap()
        waitForClarificationCardToClear(card,
                                        screenshotName: screenshotPrefix + "-cleared")
        waitForNextTurnSuccess(
            prompt: "SEMREH_SLICE3_CLARIFY_AFTER_" + marker,
            acknowledgement: acknowledgement,
            app: app
        )
    }

    @MainActor
    private func sendLivePrompt(
        _ prompt: String,
        app: XCUIApplication,
        screenshotPrefix: String
    ) {
        let composers = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        )
        let composer = composers.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The production chat must expose its composer.")
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send"]
        let sendDeadline = Date().addingTimeInterval(45)
        while (!send.exists || !send.isEnabled) && Date() < sendDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        assertHittable(send, timeout: 5, message: "The production chat Send action must be available.")
        send.tap()

        let marker = app.staticTexts.matching(
            NSPredicate(format: "label == %@", prompt)
        ).firstMatch
        XCTAssertTrue(
            marker.waitForExistence(timeout: 20),
            "The exact clarification marker must appear in the transcript."
        )
        attachScreenshot(named: screenshotPrefix + "-sent")
    }

    @MainActor
    private func waitForClarificationCard(app: XCUIApplication) -> XCUIElement {
        let card = app.otherElements[clarificationCardIdentifier]
        XCTAssertTrue(card.waitForExistence(timeout: 30),
                      "The direct clarification card must appear for the exact marker.")
        return card
    }

    @MainActor
    private func assertSingleClarificationQuestion(in card: XCUIElement) {
        let question = card.staticTexts["Choose a bounded fixture answer"]
        assertHittable(
            question,
            timeout: 10,
            message: "Single clarification must expose its exact readable question."
        )
    }

    @MainActor
    private func waitForClarificationCardToClear(
        _ card: XCUIElement,
        screenshotName: String
    ) {
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: card
        )
        wait(for: [cleared], timeout: 30)
        XCTAssertFalse(card.exists, "The clarification card must clear after its response.")
        attachScreenshot(named: screenshotName)
    }

    @MainActor
    private func waitForNextTurnSuccess(
        prompt: String,
        acknowledgement: String,
        app: XCUIApplication
    ) {
        sendLivePrompt(prompt, app: app, screenshotPrefix: "slice3-clarification-follow-up")
        let uniqueAcknowledgement = app.staticTexts[acknowledgement]
        assertHittable(uniqueAcknowledgement, timeout: 45,
                       message: "The clarification follow-up must produce its unique terminal ACK.")
        waitForIdle(app: app)
        attachScreenshot(named: "slice3-clarification-follow-up-complete")
    }

    @MainActor
    private func waitForIdle(app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let stop = app.buttons["Stop response"]
            let send = app.buttons["Send"]
            if !stop.exists && send.exists {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(app.buttons["Stop response"].exists,
                       "The response must settle instead of leaving a running response.")
        XCTAssertTrue(app.buttons["Send"].exists,
                      "An idle chat must restore the production Send action.")
    }

    private func waitForPostLoginDestination(app: XCUIApplication) {
        let sessions = app.buttons["Sessions"]
        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while !sessions.exists && !chat.exists && Date() < deadline {
            dismissKnownPasswordSavePrompt(app: app, timeout: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        // The password sheet can arrive after the authenticated destination has
        // already appeared in the hierarchy. Resolve that known overlay before
        // evaluating navigation hittability.
        dismissKnownPasswordSavePrompt(app: app)
        guard sessions.exists || chat.exists else {
            XCTFail("Successful login must expose Sessions or a known restored chat detail.")
            return
        }
        guard chat.exists else {
            XCTAssertTrue(sessions.isHittable, "The Sessions destination must be hittable after login.")
            return
        }

        let currentBackButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "Back")
        ).firstMatch
        let legacyBackButton = app.navigationBars.buttons["BackButton"]
        let backButton = currentBackButton.exists ? currentBackButton : legacyBackButton
        XCTAssertTrue(
            backButton.waitForExistence(timeout: 5),
            "A restored chat detail must expose its current Back control or legacy NavigationStack BackButton."
        )
        let navigationDeadline = Date().addingTimeInterval(5)
        while !backButton.isHittable && Date() < navigationDeadline {
            dismissKnownPasswordSavePrompt(app: app, timeout: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        dismissKnownPasswordSavePrompt(app: app, timeout: 0)
        XCTAssertTrue(backButton.isHittable, "The restored chat BackButton must be hittable.")
        guard backButton.exists && backButton.isHittable else { return }
        backButton.tap()

        let leftChat = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: chat
        )
        wait(for: [leftChat], timeout: 10)
        XCTAssertFalse(chat.exists, "BackButton must return from the restored chat detail to the shell.")
        dismissKnownPasswordSavePrompt(app: app)
    }

    private func prepareNormalSignIn(app: XCUIApplication) {
        let personalize = app.navigationBars["Personalize"]
        if personalize.exists {
            dismissKnownPasswordSavePrompt(app: app)
            let skip = personalize.buttons["Skip"]
            XCTAssertTrue(skip.waitForExistence(timeout: 5) && skip.isHittable)
            skip.tap()
        }
        let welcome = app.buttons["Get Started"]
        if welcome.waitForExistence(timeout: 5) && welcome.isHittable { return }
        // An expired cookie legitimately restores the existing Connect page,
        // rather than the first onboarding page or an authenticated shell.
        if app.staticTexts["Your session expired. Sign in again."].exists,
           app.textFields["onboarding-server-url"].exists {
            return
        }

        // Only dismiss known, non-auth startup surfaces. An unknown alert must
        // remain visible so the UI smoke reports the actual regression.
        let actionFailure = app.alerts["Session Action Failed"]
        if actionFailure.waitForExistence(timeout: 2) {
            XCTAssertTrue(actionFailure.buttons["OK"].exists)
            actionFailure.buttons["OK"].tap()
        }
        dismissKnownPasswordSavePrompt(app: app)

        let settings = app.buttons["Settings"]
        if !settings.waitForExistence(timeout: 5) {
            let customBack = app.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch
            let back = customBack.exists ? customBack : app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable,
                          "The authenticated app must be navigable back to the shell.")
            back.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 10) && settings.isHittable,
                      "The authenticated app must expose Settings.")
        settings.tap()

        let host = app.staticTexts[approvedLiveHost]
        XCTAssertTrue(host.waitForExistence(timeout: 15), "Settings must show the approved test server.")
        let signOut = app.buttons["Sign Out of This Server"]
        if !signOut.exists {
            let aboutAndStorage = app.staticTexts["About & Storage"]
            for _ in 0..<8 where !aboutAndStorage.isHittable {
                let scrollView = app.scrollViews.firstMatch
                XCTAssertTrue(scrollView.exists, "Settings must expose a bounded scroll path to About & Storage.")
                scrollView.swipeUp()
            }
            XCTAssertTrue(aboutAndStorage.waitForExistence(timeout: 5) && aboutAndStorage.isHittable)
            aboutAndStorage.tap()
        }
        let singleServerFootnote = app.staticTexts[
            "Signs out of the active server and returns to onboarding."
        ]
        for _ in 0..<8 where !singleServerFootnote.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(singleServerFootnote.waitForExistence(timeout: 5) && singleServerFootnote.isHittable,
                      "Refusing sign-out unless the disposable fixture is the only configured server.")
        for _ in 0..<8 where !signOut.isHittable {
            let scrollView = app.scrollViews.firstMatch
            XCTAssertTrue(scrollView.exists, "Settings must expose a bounded scroll path to sign out.")
            scrollView.swipeUp()
        }
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        XCTAssertTrue(signOut.isHittable)
        signOut.tap()

        let confirmation = app.alerts["Sign out of this server?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Sign Out"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 20), "Normal sign-out must return to Welcome.")
    }

    private func replacePublicText(_ field: XCUIElement, with value: String, app: XCUIApplication) {
        let existingValue = (field.value as? String) ?? ""
        if existingValue == value { return }
        field.tap()
        if !existingValue.isEmpty, existingValue != field.placeholderValue {
            field.press(forDuration: 1.0)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3), "Existing public URL text must be replaceable without appending.")
            selectAll.tap()
        }
        field.typeText(value)
    }

    private func dismissKnownPasswordSavePrompt(app: XCUIApplication, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for title in ["Save Password?", "Save This Password?"] {
                // The captured iOS hierarchy exposes a remote Sheet titled
                // "Save Password?". Scope Not Now to that exact known surface;
                // an unrelated alert or button must never be dismissed.
                for prompt in [app.sheets[title], app.alerts[title]] where prompt.exists {
                    let notNow = prompt.buttons["Not Now"]
                    let hittable = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == true AND hittable == true"),
                        object: notNow
                    )
                    XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed,
                                   "The known password-save prompt must expose a hittable Not Now button.")
                    guard notNow.exists && notNow.isHittable else { return }
                    notNow.tap()
                    let dismissed = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == false"), object: prompt
                    )
                    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                                   "Not Now must dismiss the known password-save prompt.")
                    return
                }
            }
            guard Date() < deadline else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
    }

    private struct DisposableCredentials: Decodable {
        let username: String
        let password: String
    }

    private struct RelaunchCanonicalTranscript {
        let sessionID: String
        let rows: [[String: Any]]
    }

    @MainActor
    private final class RelaunchCanonicalObserver {
        private let origin: URL
        private let session: URLSession

        init(origin: URL, credentials: DisposableCredentials) async throws {
            self.origin = origin
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = [:]
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            session = URLSession(
                configuration: configuration,
                delegate: RelaunchRedirectGuard(origin: origin),
                delegateQueue: nil
            )

            let body = try JSONSerialization.data(withJSONObject: [
                "provider": "basic",
                "username": credentials.username,
                "password": credentials.password,
                "next": "",
            ])
            let (data, response) = try await request(path: "/auth/password-login", method: "POST", body: body)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200..<300).contains(response.statusCode), payload?["ok"] as? Bool == true else {
                throw NSError(
                    domain: "LongChatScrollUITests",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Private canonical observer authentication failed."]
                )
            }
        }

        func invalidate() {
            session.invalidateAndCancel()
        }

        func transcript(storedID: String) async throws -> RelaunchCanonicalTranscript {
            var components = URLComponents()
            components.path = "/api/sessions/\(storedID)/messages"
            components.queryItems = [
                URLQueryItem(name: "profile", value: "default"),
                URLQueryItem(name: "include_compacted", value: "true"),
                URLQueryItem(name: "order", value: "oldest"),
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "offset", value: "0"),
            ]
            guard let path = components.string else {
                throw NSError(domain: "LongChatScrollUITests", code: 7)
            }
            let (data, response) = try await request(path: path, method: "GET")
            guard (200..<300).contains(response.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["session_id"] as? String,
                  let rows = object["messages"] as? [[String: Any]] else {
                throw NSError(
                    domain: "LongChatScrollUITests",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Canonical transcript response was invalid."]
                )
            }
            return RelaunchCanonicalTranscript(sessionID: sessionID, rows: rows)
        }

        private func request(
            path: String,
            method: String,
            body: Data? = nil
        ) async throws -> (Data, HTTPURLResponse) {
            guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
                  url.scheme == origin.scheme,
                  url.host == origin.host,
                  url.port == origin.port else {
                throw NSError(domain: "LongChatScrollUITests", code: 9)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "LongChatScrollUITests", code: 10)
            }
            return (data, http)
        }
    }

    private final class RelaunchRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let origin: URL

        init(origin: URL) {
            self.origin = origin
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let destination = request.url,
                  destination.scheme == origin.scheme,
                  destination.host == origin.host,
                  destination.port == origin.port else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private func readCredentials(at path: String) throws -> DisposableCredentials {
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == path else {
            throw NSError(domain: "LongChatScrollUITests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected disposable credentials path."])
        }
        let data = try Data(contentsOf: url)
        let credentials = try JSONDecoder().decode(DisposableCredentials.self, from: data)
        guard !credentials.username.isEmpty, !credentials.password.isEmpty else {
            throw NSError(domain: "LongChatScrollUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Disposable credentials are incomplete."])
        }
        return credentials
    }

    private func pasteSecret(_ value: String, into field: XCUIElement, app: XCUIApplication) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
        )
        field.tap()
        field.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Password must be entered through the local paste action.")
        paste.tap()
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) {
            allowPaste.tap()
        }
    }

    private func pastePNG(_ data: Data, into field: XCUIElement, app: XCUIApplication) {
        UIPasteboard.general.setItems(
            [[UTType.png.identifier: data]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
        )
        field.tap()
        field.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "The composer must expose the native Paste action for a PNG.")
        paste.tap()
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) {
            allowPaste.tap()
        }
    }

    private var knownPNGData: Data {
        // A visible synthetic tile makes screenshots useful evidence of actual
        // image rendering; a transparent single pixel only proves decoding.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
            .pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                UIColor.systemOrange.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                context.fill(CGRect(x: 32, y: 32, width: 32, height: 32))
            }
    }

    private func clearPasteboard() {
        UIPasteboard.general.setItems([], options: [.localOnly: true])
    }

    private func addTiming(named name: String, startedAt: Date) {
        let milliseconds = Date().timeIntervalSince(startedAt) * 1_000
        let text = String(format: "%@ duration_ms=%.1f", name, milliseconds)
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachAccessibilitySnapshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(
            data: Data(app.debugDescription.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachPlainText(_ text: String, named name: String) {
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDebugStrictNative10kColdFarArrowGate() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["SEMREH_STRICT_10K_GATE"] == "1" else {
            throw XCTSkip("The rejected strict 10k viewport diagnostic is opt-in.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-lab", "--native-direct-mixed-rich-10k",
                               "--chat-stable-viewport", "--native-direct-strict-10k-gate"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 20))
        let coldRow = app.staticTexts["message-row:perf-message-000020"]
        let coldAccessible = coldRow.waitForExistence(timeout: 2) && coldRow.isHittable
        print("SEMREH_STRICT_10K_COLD_AX row20=\(coldAccessible)")
        attachScreenshot(named: "strict-native-10k-cold")
        attachAccessibilitySnapshot(named: "strict-native-10k-cold-ax", app: app)
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
        print("SEMREH_STRICT_10K_TAP at=\(Date())")
        arrow.tap()
        attachScreenshot(named: "strict-native-10k-post-tap")
        XCTAssertTrue(coldAccessible,
                      "The saved row20 must be source-accurate and accessible at cold open.")
        XCTAssertFalse(app.staticTexts["native-direct-arrow-unready"].exists,
                       "The real-row corridor must be ready on the first cold far-arrow tap.")
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "End of 10,000-row conversation.")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15) && tail.isHittable,
                      "The far arrow must visibly reach the real source tail.")
        XCTAssertTrue(app.otherElements.containing(.staticText,
            identifier: "message-row:perf-message-009999")
            .matching(identifier: "native-direct-transcript-row").firstMatch.exists,
            "The far tail must remain a native row with its real accessibility tree.")
        attachScreenshot(named: "strict-native-10k-tail")
    }

}
