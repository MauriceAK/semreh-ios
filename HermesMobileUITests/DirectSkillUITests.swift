import XCTest
import UIKit
import UniformTypeIdentifiers

final class DirectSkillUITests: XCTestCase {
    private let origin = "https://semreh-slice1-test.tailda8427.ts.net"
    private let personalPilotOrigin = "https://maumac.tailda8427.ts.net:8443"
    private let credentialsPath = "/Users/maurice/workspace/semreh-slice1-runtime/credentials.json"
    private let backendSHA = "29112bef099274229cadff79cdff7bf7b99c4b77"
    private let skill = "semreh-fixture-empty-secret"
    private let interimHeadingMarker = "SEMREH_INTERIM_HEADING_TOOL_V1"
    private let interimHeadingText = "SEMREH_INTERIM_HEADING_VISIBLE_V1"
    private let interimFinalText = "SEMREH_INTERIM_FINAL_VISIBLE_V1"

    @MainActor
    func testOptInProductionLifecyclePhase() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Production lifecycle verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["SEMREH_LIFECYCLE_UI_PHASE"] else {
            throw XCTSkip("Production lifecycle verification is opt-in.")
        }
        guard ["finish", "stop", "steer", "background", "terminate", "automatic-restore"].contains(phase),
              environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            return XCTFail("Lifecycle verification requires one known phase and the contained pinned stock fixture.")
        }

        let credentials = try readCredentials()
        let observer = try await LifecycleCanonicalObserver(
            origin: try XCTUnwrap(URL(string: origin)), credentials: credentials
        )
        defer { observer.invalidate() }
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        defer { UIPasteboard.general.items = [] }
        let composer = try openContainedNewChat(app: app)
        let warmup = "SEMREH_LIFECYCLE_WARMUP_\(UUID().uuidString)"
        send(warmup, through: composer, app: app)
        waitForIdle(app: app)
        let storedID: String
        do {
            storedID = try await observer.discoverStoredID(uniquePrompt: warmup)
        } catch {
            let diagnostic = XCTAttachment(
                string: "Lifecycle durable discovery failed for the unique synthetic warmup. \(error.localizedDescription)"
            )
            diagnostic.name = "Sanitized lifecycle durable-discovery failure"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
            throw error
        }
        let baseline = try await waitForCanonical(observer: observer, storedID: storedID) {
            self.exactCanonicalPairs($0, users: [warmup])
        }
        if phase == "automatic-restore" {
            // Select the durable existing conversation before termination. A new
            // draft's navigation identity is separate from first-send adoption.
            var link = URLComponents()
            link.scheme = "semreh"
            link.host = "session"
            link.queryItems = [URLQueryItem(name: "id", value: storedID)]
            app.open(try XCTUnwrap(link.url))
            let selectedComposer = app.textViews.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chat-detail:")
            ).firstMatch
            XCTAssertTrue(selectedComposer.waitForExistence(timeout: 30))
            XCTAssertTrue(containing(warmup, app: app).waitForExistence(timeout: 20))
            waitForVisibleACKCount(1, app: app)
            let selectedDetail = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chat-detail:")
            ).firstMatch
            XCTAssertTrue(selectedDetail.waitForExistence(timeout: 10))
            let selectedDetailID = selectedDetail.identifier
            // This gate isolates existing-chat viewport restoration. Completion
            // while away and explicit send-next remain separate lifecycle gates.
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
            app.launch()
            let restoredComposer = app.textViews.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chat-detail:")
            ).firstMatch
            XCTAssertTrue(restoredComposer.waitForExistence(timeout: 30),
                          "Plain launch must restore the selected existing conversation.")
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: selectedDetailID)
                .firstMatch.waitForExistence(timeout: 10),
                "Plain launch must preserve the pre-termination chat detail identity.")
            XCTAssertTrue(containing(warmup, app: app).waitForExistence(timeout: 20))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Automatically restored existing chat before interaction"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            waitForVisibleACKCount(1, app: app)
            XCTAssertTrue(containing(warmup, app: app).isHittable)
            _ = try await waitForCanonical(observer: observer, storedID: storedID) {
                self.exactCanonicalPairs($0, users: [warmup])
            }
            return
        }

        switch phase {
        case "finish":
            let next = try sendUniqueCompleted("SEMREH_LIFECYCLE_AFTER_FINISH", composer: composer, app: app)
            _ = try await waitForCanonical(observer: observer, storedID: storedID) {
                self.exactCanonicalPairs($0, users: [warmup, next])
            }
        case "stop":
            let interrupted = "SEMREH_INTERRUPT_FIXTURE SEMREH_LIFECYCLE_STOP_\(UUID().uuidString)"
            send(interrupted, through: composer, app: app)
            let stop = app.buttons["Stop response"]
            XCTAssertTrue(stop.waitForExistence(timeout: 10) && stop.isHittable)
            stop.tap()
            waitForIdle(app: app)
            let next = try sendUniqueCompleted("SEMREH_LIFECYCLE_AFTER_STOP", composer: composer, app: app)
            _ = try await waitForCanonical(observer: observer, storedID: storedID) { page in
                self.hasStableBaseline(page, baseline: baseline)
                    && self.canonicalOccurrences(page, role: "user", text: interrupted) == 1
                    && self.canonicalOccurrences(page, role: "user", text: next) == 1
                    && self.canonicalTexts(page, role: "user") == [warmup, interrupted, next]
                    && self.canonicalOccurrences(page, role: "assistant", text: "SEMREH_SLICE1_ACK") == 2
            }
        case "steer":
            let original = "SEMREH_INTERRUPT_FIXTURE SEMREH_LIFECYCLE_STEER_ORIGINAL_\(UUID().uuidString)"
            send(original, through: composer, app: app)
            XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 10))
            let marker = "SEMREH_LIFECYCLE_STEER_\(UUID().uuidString)"
            send("/steer \(marker)", through: composer, app: app)
            XCTAssertTrue(containing("Steering hint queued by Hermes.", app: app).waitForExistence(timeout: 15),
                          "The pinned delayed fixture must expose Hermes' queued steer disposition.")
            waitForIdle(app: app)
            _ = try await waitForCanonical(observer: observer, storedID: storedID) {
                self.exactCanonicalPairs($0, users: [warmup, original, marker])
            }
            let next = try sendUniqueCompleted("SEMREH_LIFECYCLE_AFTER_STEER", composer: composer, app: app)
            _ = try await waitForCanonical(observer: observer, storedID: storedID) {
                self.exactCanonicalPairs($0, users: [warmup, original, marker, next])
            }
        case "background":
            let marker = "SEMREH_INTERRUPT_FIXTURE SEMREH_LIFECYCLE_BACKGROUND_\(UUID().uuidString)"
            send(marker, through: composer, app: app)
            XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 10))
            XCTAssertEqual(exactCount(marker, app: app), 1)
            XCUIDevice.shared.press(.home)
            let backgroundDeadline = Date().addingTimeInterval(5)
            while app.state == .runningForeground && Date() < backgroundDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            XCTAssertNotEqual(app.state, .runningForeground)
            let acceptedWhileBackgrounded = try await observer.transcript(storedID: storedID)
            XCTAssertTrue(
                exactAcceptedWithoutAssistant(acceptedWhileBackgrounded, baseline: baseline, prompt: marker),
                "The delayed prompt must still be accepted but incomplete after entering the background."
            )
            _ = try await waitForCanonical(observer: observer, storedID: storedID, beforeRead: {
                XCTAssertNotEqual(app.state, .runningForeground)
            }) { self.exactCanonicalPairs($0, users: [warmup, marker]) }
            app.activate()
            XCTAssertTrue(containing(marker, app: app).waitForExistence(timeout: 20))
            waitForVisibleACKCount(2, app: app)
            let foregroundComposer = app.textViews.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch
            XCTAssertTrue(foregroundComposer.waitForExistence(timeout: 20))
            let next = try sendUniqueCompleted("SEMREH_LIFECYCLE_AFTER_BACKGROUND",
                                               composer: foregroundComposer, app: app)
            _ = try await waitForCanonical(observer: observer, storedID: storedID) {
                self.exactCanonicalPairs($0, users: [warmup, marker, next])
            }
        case "terminate":
            let marker = "SEMREH_INTERRUPT_FIXTURE SEMREH_LIFECYCLE_TERMINATE_\(UUID().uuidString)"
            send(marker, through: composer, app: app)
            XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 10))
            XCTAssertEqual(exactCount(marker, app: app), 1)
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
            let acceptedWhileTerminated = try await observer.transcript(storedID: storedID)
            XCTAssertTrue(
                exactAcceptedWithoutAssistant(acceptedWhileTerminated, baseline: baseline, prompt: marker),
                "The delayed prompt must still be accepted but incomplete immediately after termination."
            )
            _ = try await waitForCanonical(observer: observer, storedID: storedID, beforeRead: {
                XCTAssertEqual(app.state, .notRunning)
            }) { self.exactCanonicalPairs($0, users: [warmup, marker]) }
            app.launch()
            dismissKnownPasswordSavePrompt(app, timeout: 3)
            let sessions = app.buttons["Sessions"]
            let restoredChat = app.otherElements.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch
            let destinationDeadline = Date().addingTimeInterval(45)
            while !sessions.exists && !restoredChat.exists && Date() < destinationDeadline {
                dismissKnownPasswordSavePrompt(app, timeout: 0)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            XCTAssertTrue(sessions.exists || restoredChat.exists,
                          "Cold launch must restore an authenticated production destination before exact reentry.")
            var link = URLComponents()
            link.scheme = "semreh"
            link.host = "session"
            link.queryItems = [URLQueryItem(name: "id", value: storedID)]
            app.open(try XCTUnwrap(link.url))
            let reopenedComposer = app.textViews.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch
            XCTAssertTrue(reopenedComposer.waitForExistence(timeout: 30))
            XCTAssertTrue(containing(marker, app: app).waitForExistence(timeout: 20))
            XCTAssertEqual(exactCount(marker, app: app), 1)
            waitForVisibleACKCount(2, app: app)
            let next = try sendUniqueCompleted("SEMREH_LIFECYCLE_AFTER_TERMINATE",
                                               composer: reopenedComposer, app: app)
            _ = try await waitForCanonical(observer: observer, storedID: storedID) {
                self.exactCanonicalPairs($0, users: [warmup, marker, next])
            }
        default:
            XCTFail("Unreachable lifecycle phase")
        }
    }

    @MainActor
    func testOptInProductionStopThenResend() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Production Stop/re-send verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_STABILIZATION_UI"] == "1" else {
            throw XCTSkip("Production Stop/re-send verification is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            return XCTFail("Stop/re-send verification requires the contained pinned stock fixture.")
        }

        let credentials = try readCredentials()
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        defer { UIPasteboard.general.items = [] }
        dismissKnownPasswordSavePrompt(app, timeout: 1)

        let server = app.textFields["onboarding-server-url"]
        if !(server.waitForExistence(timeout: 4) && server.isHittable) {
            let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
            guard welcome.waitForExistence(timeout: 5) && welcome.isHittable else {
                return XCTFail("Refusing to sign out or navigate an authenticated non-fixture account.")
            }
            let existingServer = app.buttons["Already have a server?"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5) && existingServer.isHittable)
            existingServer.tap()
            XCTAssertTrue(server.waitForExistence(timeout: 5) && server.isHittable)
        }
        replace(server, with: origin, app: app)
        let testConnection = app.buttons["Test Connection"]
        XCTAssertTrue(testConnection.waitForExistence(timeout: 5) && testConnection.isHittable)
        testConnection.tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        replace(username, with: credentials.username, app: app)
        paste(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()

        let sessions = app.buttons["Sessions"]
        let restoredChat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        let destinationDeadline = Date().addingTimeInterval(45)
        while !sessions.exists && !restoredChat.exists && Date() < destinationDeadline {
            dismissKnownPasswordSavePrompt(app, timeout: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        dismissKnownPasswordSavePrompt(app, timeout: 3)
        if restoredChat.exists {
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(sessions.waitForExistence(timeout: 30) && sessions.isHittable)
        sessions.tap()
        let newSession = app.buttons["New session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15) && newSession.isHittable)
        newSession.tap()

        let composer = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20) && composer.isHittable)
        send("SEMREH_INTERRUPT_FIXTURE", through: composer, app: app)
        let stop = app.buttons["Stop response"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && stop.isHittable)
        stop.tap()
        waitForIdle(app: app)

        let benignMarker = "SEMREH_STABILIZATION_AFTER_STOP_\(UUID().uuidString)"
        send(benignMarker, through: composer, app: app)
        let acknowledgement = containing("SEMREH_SLICE1_ACK", app: app)
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 45) && acknowledgement.isHittable)
        waitForIdle(app: app)
        XCTAssertTrue(composer.exists && composer.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Production Stop then re-send final state"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOptInProductionInterimHeadingSurvivesFinalAndCanonicalReopen() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Production interim-heading verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_STABILIZATION_UI"] == "1" else {
            throw XCTSkip("Production interim-heading verification is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            return XCTFail("Interim-heading verification requires the contained pinned stock fixture.")
        }

        let credentials = try readCredentials()
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        defer { UIPasteboard.general.items = [] }
        dismissKnownPasswordSavePrompt(app, timeout: 1)

        let server = app.textFields["onboarding-server-url"]
        if !(server.waitForExistence(timeout: 4) && server.isHittable) {
            let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
            guard welcome.waitForExistence(timeout: 5) && welcome.isHittable else {
                return XCTFail("Refusing to sign out or navigate an authenticated non-fixture account.")
            }
            let existingServer = app.buttons["Already have a server?"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5) && existingServer.isHittable)
            existingServer.tap()
            XCTAssertTrue(server.waitForExistence(timeout: 5) && server.isHittable)
        }
        replace(server, with: origin, app: app)
        let testConnection = app.buttons["Test Connection"]
        XCTAssertTrue(testConnection.waitForExistence(timeout: 5) && testConnection.isHittable)
        testConnection.tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        replace(username, with: credentials.username, app: app)
        paste(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()

        let sessions = app.buttons["Sessions"]
        let restoredChat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        let destinationDeadline = Date().addingTimeInterval(45)
        while !sessions.exists && !restoredChat.exists && Date() < destinationDeadline {
            dismissKnownPasswordSavePrompt(app, timeout: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        dismissKnownPasswordSavePrompt(app, timeout: 3)
        if restoredChat.exists {
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(sessions.waitForExistence(timeout: 30) && sessions.isHittable)
        sessions.tap()
        let newSession = app.buttons["New session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15) && newSession.isHittable)
        newSession.tap()

        let composer = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20) && composer.isHittable)
        send(interimHeadingMarker, through: composer, app: app)

        let interimHeading = containing(interimHeadingText, app: app)
        // The blocking approval overlay deliberately intercepts background
        // touches. The transcript must remain rendered, not tappable through it.
        XCTAssertTrue(
            interimHeading.waitForExistence(timeout: 30)
                && !interimHeading.frame.isEmpty
                && app.frame.intersects(interimHeading.frame),
            "The Markdown heading must be visible while the tool is still awaiting approval."
        )
        let beforeApproval = XCTAttachment(screenshot: app.screenshot())
        beforeApproval.name = "Interim heading while approval blocks transcript touches"
        beforeApproval.lifetime = .keepAlways
        add(beforeApproval)
        let approveOnce = app.buttons["approval-request-choice-once"]
        XCTAssertTrue(approveOnce.waitForExistence(timeout: 15) && approveOnce.isHittable)
        approveOnce.tap()

        let final = containing(interimFinalText, app: app)
        XCTAssertTrue(final.waitForExistence(timeout: 45) && final.isHittable)
        waitForIdle(app: app)
        XCTAssertTrue(interimHeading.exists && interimHeading.isHittable)
        XCTAssertTrue(final.exists && final.isHittable)

        // Give this specific conversation a unique durable identity assertion.
        // Older fixture chats have the same heading/final text, so those alone
        // could falsely pass if navigation selected an older session.
        let reopenMarker = "SEMREH_INTERIM_REOPEN_\(UUID().uuidString)"
        send(reopenMarker, through: composer, app: app)
        XCTAssertTrue(containing("SEMREH_SLICE1_ACK", app: app).waitForExistence(timeout: 30))
        waitForIdle(app: app)

        app.terminate()
        app.launch()
        dismissKnownPasswordSavePrompt(app, timeout: 3)
        // Cold launch legitimately returns to Sessions. This fixture is the
        // only writer, and its title is the deterministic ACK; open the newest
        // row, then prove identity using the unique marker rather than its title.
        XCTAssertTrue(sessions.waitForExistence(timeout: 30))
        sessions.tap()
        let latestFixtureSession = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "SEMREH_SLICE1_ACK")
        ).firstMatch
        XCTAssertTrue(latestFixtureSession.waitForExistence(timeout: 15) && latestFixtureSession.isHittable)
        latestFixtureSession.tap()
        let reopenedChat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(reopenedChat.waitForExistence(timeout: 30))
        XCTAssertTrue(containing(reopenMarker, app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(containing(interimHeadingText, app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(containing(interimFinalText, app: app).waitForExistence(timeout: 30))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Production interim heading and distinct final after canonical reopen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOptInPersonalPilotBootstrapOnly() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Personal pilot bootstrap verification is simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment["SEMREH_PERSONAL_BOOTSTRAP_UI"] == "1" else {
            throw XCTSkip("Personal pilot bootstrap verification is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launch()
        dismissKnownPasswordSavePrompt(app, timeout: 1)
        let server = app.textFields["onboarding-server-url"]
        if !(server.waitForExistence(timeout: 4) && server.isHittable) {
            try signOutIfNeeded(app)
            let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
            XCTAssertTrue(welcome.waitForExistence(timeout: 15) && welcome.isHittable)
            let existingServer = app.buttons["Already have a server?"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5) && existingServer.isHittable)
            existingServer.tap()
            XCTAssertTrue(server.waitForExistence(timeout: 5) && server.isHittable)
        }
        replace(server, with: personalPilotOrigin, app: app)
        let testConnection = app.buttons["Test Connection"]
        XCTAssertTrue(testConnection.waitForExistence(timeout: 5) && testConnection.isHittable)
        testConnection.tap()

        let status = app.staticTexts["Connection ok. Password required."]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        for _ in 0..<3 where !status.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(status.isHittable)
        XCTAssertTrue(app.textFields["onboarding-username"].exists)
        XCTAssertTrue(app.secureTextFields["onboarding-password"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Personal pilot bootstrap login form"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOptInProductionLoginNewChatSkillListAndShortcutDetail() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Direct skill UI verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE4_SKILL_UI"] == "1" else {
            throw XCTSkip("Direct skill UI verification is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            return XCTFail("Direct skill UI verification requires the contained pinned stock fixture.")
        }

        let credentials = try readCredentials()
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        defer { UIPasteboard.general.items = [] }
        dismissKnownPasswordSavePrompt(app, timeout: 1)
        try signOutIfNeeded(app)
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        if welcome.waitForExistence(timeout: 15) && welcome.isHittable {
            let getStarted = app.buttons["Get Started"]
            XCTAssertTrue(getStarted.waitForExistence(timeout: 5) && getStarted.isHittable); getStarted.tap()
            XCTAssertTrue(app.staticTexts["What you get"].waitForExistence(timeout: 5))
            let setUp = app.buttons["Set Up"]
            XCTAssertTrue(setUp.waitForExistence(timeout: 5) && setUp.isHittable); setUp.tap()

            let guidance = app.staticTexts["Prepare your Hermes server"]
            XCTAssertTrue(guidance.waitForExistence(timeout: 5) && guidance.isHittable)
            XCTAssertTrue(containing("Use first-party Hermes", app: app).exists)
            XCTAssertTrue(containing("dedicated authenticated HTTPS", app: app).exists)
            XCTAssertFalse(app.alerts["Copy the setup prompt first"].exists)
            let guidanceScreenshot = XCTAttachment(screenshot: app.screenshot())
            guidanceScreenshot.name = "First-party Hermes server guidance"
            guidanceScreenshot.lifetime = .keepAlways
            add(guidanceScreenshot)

            let guidanceContinue = app.buttons["Continue"]
            XCTAssertTrue(guidanceContinue.waitForExistence(timeout: 5) && guidanceContinue.isHittable); guidanceContinue.tap()
            let tailscale = app.staticTexts["Install Tailscale on iPhone"]
            XCTAssertTrue(tailscale.waitForExistence(timeout: 5) && tailscale.isHittable)
            XCTAssertFalse(app.alerts["Copy the setup prompt first"].exists)
            let tailscaleContinue = app.buttons["Continue"]
            XCTAssertTrue(tailscaleContinue.waitForExistence(timeout: 5) && tailscaleContinue.isHittable); tailscaleContinue.tap()
        } else {
            return XCTFail("Sign-out did not return to the visible onboarding welcome page.")
        }
        let server = app.textFields["onboarding-server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 5) && server.isHittable)
        replace(server, with: origin, app: app)
        app.buttons["Test Connection"].tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        replace(username, with: credentials.username, app: app)
        paste(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()
        let sessions = app.buttons["Sessions"]
        let restoredChat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        let destinationDeadline = Date().addingTimeInterval(45)
        while !sessions.exists && !restoredChat.exists && Date() < destinationDeadline {
            dismissKnownPasswordSavePrompt(app, timeout: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        // The system prompt can arrive after the destination enters the hierarchy.
        dismissKnownPasswordSavePrompt(app, timeout: 3)
        if restoredChat.exists {
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            dismissKnownPasswordSavePrompt(app, timeout: 1)
            back.tap()
        }
        dismissKnownPasswordSavePrompt(app, timeout: 1)
        XCTAssertTrue(sessions.waitForExistence(timeout: 30) && sessions.isHittable)
        sessions.tap()
        XCTAssertTrue(app.buttons["New session"].waitForExistence(timeout: 15))
        app.buttons["New session"].tap()
        let composer = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))

        send("/skills", through: composer, app: app)
        XCTAssertTrue(containing("Available skills:", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(containing(skill, app: app).exists)
        XCTAssertFalse(app.staticTexts["Could Not Load Skills"].exists)
        XCTAssertFalse(containing("No skills are configured on the server.", app: app).exists)

        send("/\(skill)", through: composer, app: app)
        XCTAssertTrue(containing("Skill invocation is temporarily unavailable in direct Hermes mode.", app: app)
            .waitForExistence(timeout: 30))
        XCTAssertTrue(containing("browse installed skills with", app: app).exists)
        XCTAssertTrue(containing(skill, app: app).exists)
        XCTAssertTrue(containing("Disposable empty-value secret callback fixture.", app: app).exists)
        XCTAssertFalse(containing("Enter the disposable fixture value", app: app).exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Production skill list and shortcut detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func containing(_ value: String, app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", value)).firstMatch
    }

    @MainActor
    private func openContainedNewChat(app: XCUIApplication) throws -> XCUIElement {
        let credentials = try readCredentials()
        dismissKnownPasswordSavePrompt(app, timeout: 1)
        try prepareContainedSignIn(app: app)
        let server = app.textFields["onboarding-server-url"]
        if !(server.waitForExistence(timeout: 4) && server.isHittable) {
            let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
            guard welcome.waitForExistence(timeout: 5) && welcome.isHittable else {
                XCTFail("Refusing to sign out or navigate an authenticated non-fixture account.")
                throw NSError(domain: "DirectSkillUITests", code: 3)
            }
            let existingServer = app.buttons["Already have a server?"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5) && existingServer.isHittable)
            existingServer.tap()
            XCTAssertTrue(server.waitForExistence(timeout: 5) && server.isHittable)
        }
        replace(server, with: origin, app: app)
        let testConnection = app.buttons["Test Connection"]
        XCTAssertTrue(testConnection.waitForExistence(timeout: 5) && testConnection.isHittable)
        testConnection.tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        replace(username, with: credentials.username, app: app)
        paste(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()

        let sessions = app.buttons["Sessions"]
        let restoredChat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while !sessions.exists && !restoredChat.exists && Date() < deadline {
            dismissKnownPasswordSavePrompt(app, timeout: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        dismissKnownPasswordSavePrompt(app, timeout: 3)
        if restoredChat.exists {
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(sessions.waitForExistence(timeout: 30) && sessions.isHittable)
        sessions.tap()
        let newSession = app.buttons["New session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15) && newSession.isHittable)
        newSession.tap()
        let composer = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20) && composer.isHittable)
        return composer
    }

    @MainActor
    private func prepareContainedSignIn(app: XCUIApplication) throws {
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        if welcome.waitForExistence(timeout: 5) || app.textFields["onboarding-server-url"].exists { return }
        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        if chat.exists {
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }
        let you = app.buttons["You"]
        XCTAssertTrue(you.waitForExistence(timeout: 10) && you.isHittable)
        you.tap()
        XCTAssertTrue(app.staticTexts["semreh-slice1-test.tailda8427.ts.net"].waitForExistence(timeout: 15),
                      "Refusing to sign out an authenticated server other than the contained fixture.")
        let signOut = app.buttons["Sign Out of This Server"]
        if !signOut.exists {
            let appSettings = app.staticTexts["App & maintenance"]
            for _ in 0..<8 where !appSettings.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(appSettings.waitForExistence(timeout: 5) && appSettings.isHittable)
            appSettings.tap()
        }
        for _ in 0..<8 where !signOut.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(signOut.waitForExistence(timeout: 5) && signOut.isHittable)
        signOut.tap()
        let confirmation = app.alerts["Sign out of this server?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Sign Out"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 20))
    }

    @MainActor
    private func sendUniqueCompleted(
        _ prefix: String,
        composer: XCUIElement,
        app: XCUIApplication
    ) throws -> String {
        let marker = "\(prefix)_\(UUID().uuidString)"
        send(marker, through: composer, app: app)
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 20))
        XCTAssertEqual(exactCount(marker, app: app), 1, "The prompt must render exactly once.")
        waitForIdle(app: app)
        XCTAssertEqual(exactCount(marker, app: app), 1, "Completion must not duplicate the durable prompt.")
        return marker
    }

    private func exactCount(_ value: String, app: XCUIApplication) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label == %@", value)).count
    }

    @MainActor
    private func waitForCanonical(
        observer: LifecycleCanonicalObserver,
        storedID: String,
        timeout: TimeInterval = 45,
        beforeRead: () -> Void = {},
        matches: ([[String: Any]]) -> Bool
    ) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            beforeRead()
            let page = try await observer.transcript(storedID: storedID)
            if matches(page) { return page }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "DirectSkillUITests", code: 6,
                      userInfo: [NSLocalizedDescriptionKey: "Canonical transcript did not reach the exact lifecycle state."])
    }

    private func exactCanonicalPairs(_ rows: [[String: Any]], users: [String]) -> Bool {
        guard rows.count == users.count * 2 else { return false }
        for (index, user) in users.enumerated() {
            guard rows[index * 2]["role"] as? String == "user",
                  canonicalText(rows[index * 2]) == user,
                  rows[index * 2 + 1]["role"] as? String == "assistant",
                  canonicalText(rows[index * 2 + 1]) == "SEMREH_SLICE1_ACK" else { return false }
        }
        return canonicalIDsAreUnique(rows)
    }

    private func hasStableBaseline(_ rows: [[String: Any]], baseline: [[String: Any]]) -> Bool {
        guard rows.count >= baseline.count else { return false }
        return zip(rows.prefix(baseline.count), baseline).allSatisfy {
            NSDictionary(dictionary: $0.0).isEqual(NSDictionary(dictionary: $0.1))
        } && canonicalIDsAreUnique(rows)
    }

    private func exactAcceptedWithoutAssistant(
        _ rows: [[String: Any]],
        baseline: [[String: Any]],
        prompt: String
    ) -> Bool {
        guard rows.count == baseline.count + 1,
              hasStableBaseline(rows, baseline: baseline),
              rows.last?["role"] as? String == "user",
              rows.last.flatMap({ canonicalText($0) }) == prompt else { return false }
        return canonicalOccurrences(rows, role: "assistant", text: "SEMREH_SLICE1_ACK") == 1
    }

    private func canonicalOccurrences(_ rows: [[String: Any]], role: String, text: String) -> Int {
        rows.filter { $0["role"] as? String == role && canonicalText($0) == text }.count
    }

    private func canonicalTexts(_ rows: [[String: Any]], role: String) -> [String] {
        rows.filter { $0["role"] as? String == role }.compactMap(canonicalText)
    }

    private func canonicalText(_ row: [String: Any]) -> String? {
        if let text = row["content"] as? String { return text }
        guard let blocks = row["content"] as? [[String: Any]] else { return nil }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    private func canonicalIDsAreUnique(_ rows: [[String: Any]]) -> Bool {
        let ids = rows.compactMap { row -> String? in
            if let value = row["id"] as? String, !value.isEmpty { return "s:\(value)" }
            if let value = row["id"] as? NSNumber { return "n:\(value.stringValue)" }
            return nil
        }
        return ids.count == rows.count && Set(ids).count == ids.count
    }

    @MainActor
    private func waitForVisibleACKCount(_ expected: Int, app: XCUIApplication) {
        let acknowledgements = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "SEMREH_SLICE1_ACK")
        )
        let deadline = Date().addingTimeInterval(30)
        while acknowledgements.count != expected && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(acknowledgements.count, expected,
                       "Foreground reconciliation must render both exact fixture answers.")
        XCTAssertTrue(acknowledgements.element(boundBy: expected - 1).isHittable,
                      "The recovered assistant answer must be visibly rendered before send-next.")
    }

    private func send(_ text: String, through composer: XCUIElement, app: XCUIApplication) {
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    @MainActor
    private func waitForIdle(app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if !app.buttons["Stop response"].exists && app.buttons["Send"].exists { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(app.buttons["Stop response"].exists)
        XCTAssertTrue(app.buttons["Send"].exists)
    }

    private func signOutIfNeeded(_ app: XCUIApplication) throws {
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        if welcome.waitForExistence(timeout: 4) && welcome.isHittable { return }
        let you = app.buttons["You"]
        if !you.waitForExistence(timeout: 5) {
            let knownBack = app.navigationBars.buttons["BackButton"]
            let back = knownBack.exists ? knownBack : app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        XCTAssertTrue(you.waitForExistence(timeout: 10)); you.tap()
        let signOut = app.buttons["Sign Out of This Server"]
        for _ in 0..<8 where !signOut.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(signOut.isHittable); signOut.tap()
        let confirmation = app.alerts["Sign out of this server?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Sign Out"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 20))
    }

    private func replace(_ field: XCUIElement, with value: String, app: XCUIApplication) {
        let existing = (field.value as? String) ?? ""
        field.tap()
        if !existing.isEmpty, existing != field.placeholderValue {
            field.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap()
        }
        field.typeText(value)
    }

    private func paste(_ value: String, into field: XCUIElement, app: XCUIApplication) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        field.tap(); field.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        let allow = app.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    private func dismissKnownPasswordSavePrompt(_ app: XCUIApplication, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for title in ["Save Password?", "Save This Password?"] {
                for prompt in [app.sheets[title], app.alerts[title]] where prompt.exists {
                    let notNow = prompt.buttons["Not Now"]
                    XCTAssertTrue(notNow.waitForExistence(timeout: 5) && notNow.isHittable)
                    guard notNow.exists && notNow.isHittable else { return }
                    notNow.tap()
                    let dismissed = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == false"), object: prompt
                    )
                    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
                    return
                }
            }
            guard Date() < deadline else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
    }

    private func readCredentials() throws -> Credentials {
        let url = URL(fileURLWithPath: credentialsPath)
        guard url.resolvingSymlinksInPath().path == credentialsPath else {
            throw NSError(domain: "DirectSkillUITests", code: 1)
        }
        let value = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: url))
        guard !value.username.isEmpty, !value.password.isEmpty else {
            throw NSError(domain: "DirectSkillUITests", code: 2)
        }
        return value
    }

    private final class LifecycleCanonicalObserver: @unchecked Sendable {
        private let origin: URL
        private let session: URLSession

        init(origin: URL, credentials: Credentials) async throws {
            self.origin = origin
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = [:]
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            session = URLSession(
                configuration: configuration,
                delegate: LifecycleRedirectGuard(origin: origin),
                delegateQueue: nil
            )

            let body = try JSONSerialization.data(withJSONObject: [
                "provider": "basic", "username": credentials.username,
                "password": credentials.password, "next": "",
            ])
            let (data, response) = try await request(path: "/auth/password-login", method: "POST", body: body)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200..<300).contains(response.statusCode), payload?["ok"] as? Bool == true else {
                throw NSError(domain: "DirectSkillUITests", code: 7)
            }
        }

        func invalidate() { session.invalidateAndCancel() }

        func discoverStoredID(uniquePrompt: String) async throws -> String {
            let deadline = Date().addingTimeInterval(45)
            var lastCandidateCount = 0
            while Date() < deadline {
                var components = URLComponents()
                components.path = "/api/sessions"
                components.queryItems = [
                    URLQueryItem(name: "profile", value: "default"),
                    URLQueryItem(name: "limit", value: "20"),
                    URLQueryItem(name: "offset", value: "0"),
                    URLQueryItem(name: "order", value: "recent"),
                    URLQueryItem(name: "archived", value: "exclude"),
                ]
                let (data, response) = try await request(path: try XCTUnwrap(components.string), method: "GET")
                guard (200..<300).contains(response.statusCode),
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sessions = payload["sessions"] as? [[String: Any]],
                      sessions.count <= 120 else {
                    throw NSError(domain: "DirectSkillUITests", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "Bounded session discovery response was invalid."])
                }
                lastCandidateCount = sessions.count
                var matches: [String] = []
                for candidate in sessions {
                    guard let storedID = candidate["id"] as? String,
                          storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$",
                                         options: .regularExpression) != nil else {
                        throw NSError(domain: "DirectSkillUITests", code: 12,
                                      userInfo: [NSLocalizedDescriptionKey: "Session discovery returned an invalid identity shape."])
                    }
                    let rows = try await transcript(storedID: storedID)
                    if Self.isExactWarmup(rows, prompt: uniquePrompt) { matches.append(storedID) }
                }
                if matches.count == 1 { return matches[0] }
                if matches.count > 1 {
                    throw NSError(domain: "DirectSkillUITests", code: 13,
                                  userInfo: [NSLocalizedDescriptionKey: "Unique warmup matched multiple durable sessions."])
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NSError(domain: "DirectSkillUITests", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "No exact warmup match in \(lastCandidateCount) bounded candidates."])
        }

        func transcript(storedID: String) async throws -> [[String: Any]] {
            var components = URLComponents()
            components.path = "/api/sessions/\(storedID)/messages"
            components.queryItems = [
                URLQueryItem(name: "profile", value: "default"),
                URLQueryItem(name: "include_compacted", value: "true"),
                URLQueryItem(name: "order", value: "oldest"),
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "offset", value: "0"),
            ]
            let (data, response) = try await request(path: try XCTUnwrap(components.string), method: "GET")
            guard (200..<300).contains(response.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["session_id"] as? String == storedID,
                  let rows = payload["messages"] as? [[String: Any]] else {
                throw NSError(domain: "DirectSkillUITests", code: 8)
            }
            return rows
        }

        private static func isExactWarmup(_ rows: [[String: Any]], prompt: String) -> Bool {
            guard rows.count == 2,
                  rows[0]["role"] as? String == "user",
                  text(rows[0]) == prompt,
                  rows[1]["role"] as? String == "assistant",
                  text(rows[1]) == "SEMREH_SLICE1_ACK" else { return false }
            let ids = rows.compactMap { row -> String? in
                if let value = row["id"] as? String, !value.isEmpty { return "s:\(value)" }
                if let value = row["id"] as? NSNumber { return "n:\(value.stringValue)" }
                return nil
            }
            return ids.count == 2 && Set(ids).count == 2
        }

        private static func text(_ row: [String: Any]) -> String? {
            if let text = row["content"] as? String { return text }
            guard let blocks = row["content"] as? [[String: Any]] else { return nil }
            return blocks.compactMap { block in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()
        }

        private func request(path: String, method: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
            guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
                  url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else {
                throw NSError(domain: "DirectSkillUITests", code: 9)
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "DirectSkillUITests", code: 10)
            }
            return (data, http)
        }

    }

    private final class LifecycleRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let origin: URL

        init(origin: URL) { self.origin = origin }

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

    private struct Credentials: Decodable { let username: String; let password: String }
}
