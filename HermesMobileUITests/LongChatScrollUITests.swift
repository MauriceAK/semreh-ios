import XCTest
import UIKit
import UniformTypeIdentifiers
import Foundation
import CoreFoundation

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
    private let tuiSeedMarker = "SEMREH_TUI_CROSS_CLIENT_1"
    private let slice1Acknowledgement = "SEMREH_SLICE1_ACK"
    private let uncertaintyDelayedPromptPrefix = "SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_PRE_ACK_LOSS_"
    private let uncertaintyNewPromptPrefix = "SEMREH_SLICE3_UNCERTAINTY_NEW_"
    private let uncertaintyBannerIdentifier = "direct-prompt-uncertainty-banner"
    private let uncertaintyAllowIdentifier = "direct-prompt-uncertainty-allow-new-message"

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
        await fulfillment(of: [appeared], timeout: 90)
        XCTAssertTrue(acknowledgement.exists && acknowledgement.isHittable)
        attachScreenshot(named: "live-production-chat-success")

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
}
