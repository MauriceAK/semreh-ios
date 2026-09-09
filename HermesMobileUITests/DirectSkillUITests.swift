import XCTest
import UIKit
import UniformTypeIdentifiers

final class DirectSkillUITests: XCTestCase {
    private let origin = "https://semreh-slice1-test.tailda8427.ts.net"
    private let personalPilotOrigin = "https://maumac.tailda8427.ts.net:8443"
    private let credentialsPath = "/Users/maurice/workspace/semreh-slice1-runtime/credentials.json"
    private let backendSHA = "29112bef099274229cadff79cdff7bf7b99c4b77"
    private let skill = "semreh-fixture-empty-secret"

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

    private func send(_ text: String, through composer: XCUIElement, app: XCUIApplication) {
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
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

    private struct Credentials: Decodable { let username: String; let password: String }
}
