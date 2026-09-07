import XCTest
import UIKit
import UniformTypeIdentifiers

final class LongChatScrollUITests: XCTestCase {
    private let performanceLabArgument = "--chat-performance-lab"
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
    func testOptInLiveProductionLoginNewChatSend() throws {
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
        username.tap()
        username.typeText(credentials.username)
        pasteSecret(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()
        dismissKnownPasswordSavePrompt(app: app)

        // A persisted deep link can legitimately restore an authenticated chat
        // detail instead of the shell root. Return through that known chat's
        // navigation control before asserting the shell tabs.
        waitForPostLoginDestination(app: app)

        // The shell remembers the selected tab across normal sign-out/login.
        // Successful authentication need not land on Sessions automatically.
        let sessionsTab = app.buttons["Sessions"]
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 10), "Successful login must reach the production shell.")
        sessionsTab.tap()
        let newSession = app.buttons["New session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15), "Sessions must expose New session.")

        // Exercise the production shell startup path before creating a chat.
        app.buttons["Control"].tap()
        XCTAssertTrue(app.staticTexts["Control"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts["Session Action Failed"].exists)
        XCTAssertFalse(app.staticTexts["Projects"].waitForExistence(timeout: 2),
                       "The normal startup path must not expose a failed Projects section.")
        app.buttons["Sessions"].tap()
        XCTAssertTrue(newSession.waitForExistence(timeout: 15))
        newSession.tap()

        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        // SwiftUI propagates ChatView's identifier onto its UIKit text view.
        // Target the actual editable descendant observed in the AX hierarchy.
        let composers = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        )
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
        wait(for: [appeared], timeout: 90)
        XCTAssertTrue(acknowledgement.exists && acknowledgement.isHittable)
        attachScreenshot(named: "live-production-chat-success")

        if environment["SEMREH_SLICE3_ATTACHMENT_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 attachment UI requires the pinned stock backend.")
                return
            }
            exerciseOptInDirectAttachmentFlow(app: app)
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
            let tuiPrompt = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_TUI_CROSS_CLIENT_1")
            ).firstMatch
            assertHittable(tuiPrompt, timeout: 30,
                          message: "The actual TUI-created transcript must open through the production deep link.")
            assertHittable(acknowledgement, timeout: 15,
                          message: "The TUI-created assistant reply must also be visible.")
            attachScreenshot(named: "live-tui-created-session-in-semreh")
        }
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
            if !stop.exists {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(app.buttons["Stop response"].exists,
                       "Clarification follow-up must settle instead of leaving a running response.")
    }

    private func waitForPostLoginDestination(app: XCUIApplication) {
        let sessions = app.buttons["Sessions"]
        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while !sessions.exists && !chat.exists && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard sessions.exists || chat.exists else {
            XCTFail("Successful login must expose Sessions or a known restored chat detail.")
            return
        }
        guard chat.exists else { return }

        let backButton = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(
            backButton.waitForExistence(timeout: 5),
            "A restored chat detail must expose its known NavigationStack BackButton."
        )
        XCTAssertTrue(backButton.isHittable, "The restored chat BackButton must be hittable.")
        guard backButton.exists && backButton.isHittable else { return }
        backButton.tap()

        let leftChat = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: chat
        )
        wait(for: [leftChat], timeout: 10)
        XCTAssertFalse(chat.exists, "BackButton must return from the restored chat detail to the shell.")
    }

    private func prepareNormalSignIn(app: XCUIApplication) {
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        if welcome.waitForExistence(timeout: 5) { return }
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

        let you = app.buttons["You"]
        if !you.waitForExistence(timeout: 5) {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "The authenticated app must be navigable back to the shell.")
            back.tap()
        }
        XCTAssertTrue(you.waitForExistence(timeout: 10), "The authenticated app must expose the You surface.")
        you.tap()

        let host = app.staticTexts[approvedLiveHost]
        XCTAssertTrue(host.waitForExistence(timeout: 15), "The You surface must show the approved test server.")
        let signOut = app.buttons["Sign Out of This Server"]
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

    private func dismissKnownPasswordSavePrompt(app: XCUIApplication) {
        for title in ["Save Password?", "Save This Password?"] {
            // iOS can present this as a remote sheet, not an AX alert.
            let prompt = app.staticTexts[title]
            if prompt.waitForExistence(timeout: 1) {
                let notNow = app.buttons["Not Now"]
                XCTAssertTrue(notNow.exists)
                notNow.tap()
                return
            }
        }
    }

    private struct DisposableCredentials: Decodable {
        let username: String
        let password: String
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
}
