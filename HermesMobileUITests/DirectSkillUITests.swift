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
    func testOptInPreviewShellVisualSurfaces() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Preview shell visual verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_PREVIEW_SHELL_UI"] == "1",
              environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            throw XCTSkip("Preview shell verification requires opt-in and the contained pinned stock fixture.")
        }

        let app = XCUIApplication()
        app.launch()
        let back = app.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch
        let sessions = app.buttons["Sessions"]
        // A restored detail legitimately hides the tab bar. Return through the
        // actual Back control before deciding authentication setup is required.
        if back.waitForExistence(timeout: 5), back.isHittable {
            back.tap()
        }
        if !sessions.waitForExistence(timeout: 5) {
            _ = try openContainedNewChat(app: app)
        }
        if back.waitForExistence(timeout: 8), back.isHittable {
            back.tap()
        }

        XCTAssertTrue(sessions.waitForExistence(timeout: 15) && sessions.isHittable)
        sessions.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
        let filters = app.buttons["Session filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5) && filters.isHittable)
        retainPreviewScreenshot("Preview shell Sessions", app: app)

        print("SEMREH_FILTER_FRAME \(filters.frame)")
        filters.tap()
        let pinnedOnly = app.switches["Pinned only"]
        XCTAssertTrue(pinnedOnly.waitForExistence(timeout: 5))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        app.swipeUp()
        XCTAssertTrue(pinnedOnly.waitForExistence(timeout: 5) && pinnedOnly.isHittable)
        print("SEMREH_PINNED_ONLY_FRAME \(pinnedOnly.frame)")
        retainPreviewScreenshot("Preview shell filters expanded before pinned toggle", app: app)
        // SwiftUI exposes the whole settings row as the switch element. Tap the
        // visible trailing control rather than the row's label/empty center.
        pinnedOnly.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        XCTAssertEqual(pinnedOnly.value as? String, "1")
        retainPreviewScreenshot("Preview shell filters after pinned toggle", app: app)
        let filtersNavigationBar = app.navigationBars["Filters"]
        filtersNavigationBar.buttons["Clear"].tap()
        XCTAssertEqual(pinnedOnly.value as? String, "0")
        filtersNavigationBar.buttons["Done"].tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 5))

        let bots = app.buttons["Bots"]
        XCTAssertTrue(bots.isHittable); bots.tap()
        let botRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bot-profile:"))
        XCTAssertTrue(botRows.firstMatch.waitForExistence(timeout: 10))
        retainPreviewScreenshot("Preview shell Bots", app: app)

        let details = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "bot-profile-info:"
        )).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5) && details.isHittable)
        details.tap()
        let viewSessions = app.buttons["bot-details-view-sessions"]
        XCTAssertTrue(viewSessions.waitForExistence(timeout: 5) && viewSessions.isHittable)
        viewSessions.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))

        bots.tap()
        XCTAssertTrue(botRows.firstMatch.waitForExistence(timeout: 10))

        let activity = app.buttons["Activity"]
        XCTAssertTrue(activity.isHittable); activity.tap()
        XCTAssertTrue(app.navigationBars["Tasks"].waitForExistence(timeout: 10))
        retainPreviewScreenshot("Preview shell Activity", app: app)

        sessions.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Back"].exists,
                       "Returning to Sessions from another tab must show the root list, not reopen the last chat.")
    }

    @MainActor
    func testOptInPreviewSessionPinRoundTrip() throws {
        continueAfterFailure = false
        try requirePreviewShellFixture()
        let app = XCUIApplication()
        app.launch()
        returnToPreviewSessionsRoot(app)

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SEMREH_SLICE1_ACK #")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10) && row.isHittable)
        let originalLabel = row.label
        XCTAssertFalse(originalLabel.isEmpty)
        let title = originalLabel.split(separator: ",", maxSplits: 1).first.map(String.init) ?? originalLabel
        row.swipeRight()
        let pin = app.buttons["Pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5) && pin.isHittable)
        pin.tap()
        let pinnedMatches = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
        let pinned = pinnedMatches.firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 10) && pinned.isHittable)
        XCTAssertEqual(pinnedMatches.count, 1,
                       "A pinned chat must appear once, not remain duplicated in ordinary history.")
        retainPreviewScreenshot("Preview pinned session strip", app: app)
        pinned.press(forDuration: 1.0)
        let unpin = app.buttons["Unpin"]
        XCTAssertTrue(unpin.waitForExistence(timeout: 5) && unpin.isHittable)
        unpin.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testOptInPreviewChatControlsAndComposer() throws {
        continueAfterFailure = false
        try requirePreviewShellFixture()
        let app = XCUIApplication()
        app.launch()
        returnToPreviewSessionsRoot(app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SEMREH_SLICE1_ACK #")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10) && row.isHittable); row.tap()

        let details = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "View details for ")).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10) && details.isHittable); details.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        retainPreviewScreenshot("Preview bot header details", app: app)
        app.navigationBars.firstMatch.buttons["Done"].tap()

        let controls = app.buttons.matching(NSPredicate(format: "label == %@", "Chat controls")).firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5) && controls.isHittable); controls.tap()
        XCTAssertTrue(app.navigationBars["Chat controls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Models"].exists)
        XCTAssertTrue(app.staticTexts["Custom endpoint"].exists,
                      "Opening Chat controls must expose actual model choices directly.")
        XCTAssertTrue(app.sliders.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Context usage unavailable"].exists || app.progressIndicators["Context used"].exists)
        retainPreviewScreenshot("Preview chat sliders and context", app: app)
        app.navigationBars["Chat controls"].buttons["Done"].tap()

        let options = app.buttons["Chat options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5) && options.isHittable); options.tap()
        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5) && files.isHittable); files.tap()
        let filesNavigationBar = app.navigationBars["Files"]
        XCTAssertTrue(filesNavigationBar.waitForExistence(timeout: 10))
        retainPreviewScreenshot("Preview chat Files", app: app)
        filesNavigationBar.buttons.firstMatch.tap()

        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10) && composer.isHittable)
        let marker = "SEMREH_COMPOSER_MOTION_\(UUID().uuidString)"
        composer.tap(); composer.typeText("\(marker)\nsecond line")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        retainPreviewScreenshot("Preview multiline composer keyboard on", app: app)
        let sendButton = app.buttons["Send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5) && sendButton.isHittable); sendButton.tap()
        waitForIdle(app: app)
        XCTAssertTrue(containing(marker, app: app).waitForExistence(timeout: 10))
        retainPreviewScreenshot("Preview multiline send settled", app: app)
    }

    @MainActor
    func testOptInPreviewExistingToolActivityDisclosure() throws {
        continueAfterFailure = false
        try requirePreviewShellFixture()
        let app = XCUIApplication()
        app.launch()
        returnToPreviewSessionsRoot(app)
        let search = app.otherElements["Search sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5) && search.isHittable); search.tap()
        let field = app.textFields["Search sessions"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(interimHeadingMarker)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SEMREH_SLICE1_ACK")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20) && result.isHittable); result.tap()
        XCTAssertTrue(containing(interimHeadingText, app: app).waitForExistence(timeout: 20))
        let completedActivities = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", Completed"))
        let completedActivity = completedActivities.firstMatch
        XCTAssertTrue(completedActivity.waitForExistence(timeout: 10) && completedActivity.isHittable)
        XCTAssertEqual(completedActivities.count, 1)
        retainPreviewScreenshot("Preview compact completed activity", app: app)
        completedActivity.tap()
        XCTAssertEqual(completedActivities.count, 2,
                       "Expanding the activity group must reveal its completed child action row.")
        XCTAssertTrue(completedActivities.firstMatch.isSelected)
        retainPreviewScreenshot("Preview expanded completed activity", app: app)
    }

    private func requirePreviewShellFixture() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Preview shell verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_PREVIEW_SHELL_UI"] == "1",
              environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            throw XCTSkip("Preview shell verification requires the contained pinned stock fixture.")
        }
    }

    private func returnToPreviewSessionsRoot(_ app: XCUIApplication) {
        let back = app.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch
        if back.waitForExistence(timeout: 5), back.isHittable { back.tap() }
        let sessions = app.buttons["Sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 10) && sessions.isHittable)
        sessions.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPublicPreviewProductionSurfaces() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Public preview verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_LIFECYCLE_UI_PHASE"] == "automatic-restore",
              environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            throw XCTSkip("Public preview verification requires the contained pinned stock fixture.")
        }
        let credentials = try readCredentials()
        let observer = try await LifecycleCanonicalObserver(
            origin: try XCTUnwrap(URL(string: origin)), credentials: credentials
        )
        defer { observer.invalidate() }
        let activeProfileBefore = try await observer.activeProfile()
        let defaultProfileBefore = try await observer.defaultProfile()
        let app = XCUIApplication()
        app.launch()
        defer { UIPasteboard.general.items = [] }
        _ = try openContainedNewChat(app: app)
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable); back.tap()
        XCTAssertTrue(app.buttons["Sessions"].waitForExistence(timeout: 10))
        retainPreviewScreenshot("Public preview Chats light", app: app)
        let search = app.otherElements["Search sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5) && search.isHittable); search.tap()
        let searchField = app.textFields["Search sessions"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5)); searchField.tap(); searchField.typeText("fixture")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let closeSearch = app.buttons["Close search"]
        XCTAssertTrue(closeSearch.waitForExistence(timeout: 5) && closeSearch.isHittable); closeSearch.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        app.swipeUp()
        XCTAssertTrue(app.cells.allElementsBoundByIndex.contains(where: \.isHittable),
                      "A visible chat row must remain interactive after scrolling.")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let bots = app.buttons["New chat"]
        XCTAssertTrue(bots.waitForExistence(timeout: 10) && bots.isHittable); bots.tap()
        XCTAssertTrue(app.staticTexts["Your bots"].waitForExistence(timeout: 20))
        let profileButton = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@",
            "bot-profile:", "bot-profile:default"
        )).firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 20) && profileButton.isHittable)
        let profileName = String(profileButton.identifier.dropFirst("bot-profile:".count))
        XCTAssertFalse(profileName.isEmpty)
        XCTAssertNotEqual(profileName, "default", "Preview routing must exercise a non-default fixture profile.")
        retainPreviewScreenshot("Public preview new chat bot picker", app: app)
        profileButton.tap()
        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15) && composer.isHittable)
        let marker = "SEMREH_PREVIEW_PROFILE_\(UUID().uuidString)"
        send(marker, through: composer, app: app); waitForIdle(app: app)
        let storedID = try await observer.discoverStoredID(uniquePrompt: marker, profile: profileName)
        _ = try await waitForCanonical(observer: observer, storedID: storedID, profile: profileName) {
            self.exactCanonicalPairs($0, users: [marker])
        }
        retainPreviewScreenshot("Public preview compact composer keyboard off", app: app)
        let intelligence = app.buttons["Model, reasoning and usage"]
        XCTAssertTrue(intelligence.waitForExistence(timeout: 10) && intelligence.isHittable); intelligence.tap()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Model"].exists)
        XCTAssertTrue(app.staticTexts["Reasoning"].exists)
        XCTAssertTrue(app.staticTexts["Context usage"].exists)
        retainPreviewScreenshot("Public preview intelligence controls", app: app)
        app.tap()
        let chatOptions = app.buttons["Chat options"]
        XCTAssertTrue(chatOptions.waitForExistence(timeout: 10) && chatOptions.isHittable)
        XCTAssertFalse(app.buttons["Choose workspace path"].exists,
                       "Workspace controls must not remain in a bottom composer strip.")
        XCTAssertFalse(app.buttons["Choose profile"].exists,
                       "Profile controls must not remain in a bottom composer strip.")
        chatOptions.tap()
        let chooseWorkspace = app.buttons["Choose workspace path"]
        XCTAssertTrue(chooseWorkspace.waitForExistence(timeout: 5) && chooseWorkspace.isHittable); chooseWorkspace.tap()
        XCTAssertTrue(app.navigationBars["Choose Workspace"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        XCTAssertTrue(chatOptions.waitForExistence(timeout: 5) && chatOptions.isHittable); chatOptions.tap()
        let chooseProfile = app.buttons["Choose profile"]
        XCTAssertTrue(chooseProfile.waitForExistence(timeout: 5) && chooseProfile.isHittable); chooseProfile.tap()
        let defaultProfile = app.buttons["Default"]
        XCTAssertTrue(defaultProfile.waitForExistence(timeout: 5) && defaultProfile.isHittable); defaultProfile.tap()
        XCTAssertTrue(app.alerts["Start New Session?"].waitForExistence(timeout: 5))
        XCTAssertTrue(containing("keeps the current transcript", app: app).exists)
        app.alerts["Start New Session?"].buttons["Cancel"].tap()
        retainPreviewScreenshot("Public preview chat header and composer", app: app)
        let activeProfileAfter = try await observer.activeProfile()
        let defaultProfileAfter = try await observer.defaultProfile()
        XCTAssertEqual(activeProfileAfter, activeProfileBefore,
                       "Selecting a bot must not mutate the server active profile.")
        XCTAssertEqual(defaultProfileAfter, defaultProfileBefore,
                       "Selecting a bot must not mutate the server startup-default profile.")

        XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable); back.tap()
        let activity = app.buttons["Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10) && activity.isHittable); activity.tap()
        XCTAssertTrue(app.navigationBars["Tasks"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Scheduled work · Profile:")).firstMatch.exists)
        retainPreviewScreenshot("Public preview Activity light", app: app)
        let account = app.buttons["Account and settings"]
        XCTAssertTrue(account.waitForExistence(timeout: 10) && account.isHittable); account.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Tools"].exists)
        retainPreviewScreenshot("Public preview Settings light", app: app)
        app.buttons["Done"].tap()

        app.terminate()
        app.launchArguments = ["-AppleInterfaceStyle", "Dark"]
        app.launch()
        let restoredDetailBack = app.buttons["BackButton"]
        if restoredDetailBack.waitForExistence(timeout: 10) && restoredDetailBack.isHittable {
            restoredDetailBack.tap()
        }
        XCTAssertTrue(app.buttons["Sessions"].waitForExistence(timeout: 15))
        retainPreviewScreenshot("Public preview Chats dark", app: app)
        let darkAccount = app.buttons["Account and settings"]
        XCTAssertTrue(darkAccount.waitForExistence(timeout: 10) && darkAccount.isHittable); darkAccount.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        retainPreviewScreenshot("Public preview Settings dark", app: app)
        let tools = app.buttons["Tools"]
        XCTAssertTrue(tools.isHittable); tools.tap()
        let manageServers = app.buttons["Manage Servers"]
        XCTAssertTrue(manageServers.waitForExistence(timeout: 10) && manageServers.isHittable); manageServers.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let nestedBack = app.navigationBars["Settings"].buttons.firstMatch
        XCTAssertTrue(nestedBack.isHittable); nestedBack.tap()
        XCTAssertTrue(app.staticTexts["Tools"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        app.terminate()
        app.launchArguments = []
        app.launch()

        try signOutIfNeeded(app)
        let welcome = containing("Your Hermes companion", app: app)
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        retainPreviewScreenshot("Public preview onboarding light", app: app)
        app.buttons["Need help connecting?"].tap()
        XCTAssertTrue(app.navigationBars["Connection help"].waitForExistence(timeout: 10))
        retainPreviewScreenshot("Public preview connection help light", app: app)
        app.buttons["Done"].tap()
        app.terminate()
        app.launchArguments = ["-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        retainPreviewScreenshot("Public preview onboarding dark", app: app)
        app.buttons["Need help connecting?"].tap()
        XCTAssertTrue(app.navigationBars["Connection help"].waitForExistence(timeout: 10))
        retainPreviewScreenshot("Public preview connection help dark", app: app)
    }

    private func retainPreviewScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testOptInProductionLongAutomaticRestore() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Long automatic-restore verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_LONG_RESTORE_UI"] == "1",
              environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            throw XCTSkip("Long restore verification requires the contained pinned stock fixture.")
        }

        let observer = try await LifecycleCanonicalObserver(
            origin: try XCTUnwrap(URL(string: origin)), credentials: try readCredentials()
        )
        defer { observer.invalidate() }
        let app = XCUIApplication()
        let fixture: (storedID: String, rows: [[String: Any]])
        if let existing = try await observer.discoverLongStoredSession(minimumRows: 20) {
            fixture = existing
        } else {
            app.launch()
            let composer = try openContainedNewChat(app: app)
            let prefix = "SEMREH_LONG_RESTORE_\(UUID().uuidString)"
            var prompts = ["\(prefix)_01"]
            send(prompts[0], through: composer, app: app)
            waitForIdle(app: app)
            let storedID = try await observer.discoverStoredID(uniquePrompt: prompts[0])
            _ = try await waitForCanonical(observer: observer, storedID: storedID) {
                self.exactCanonicalPairs($0, users: prompts)
            }
            for index in 2...10 {
                prompts.append(String(format: "%@_%02d", prefix, index))
                send(prompts.last!, through: composer, app: app)
                waitForIdle(app: app)
                _ = try await waitForCanonical(observer: observer, storedID: storedID) {
                    self.exactCanonicalPairs($0, users: prompts)
                }
            }
            let rows = try await observer.transcript(storedID: storedID, limit: 100)
            guard rows.count >= 20 else {
                XCTFail("The bounded production-UI seed did not create a 20-row transcript.")
                throw NSError(domain: "DirectSkillUITests", code: 25)
            }
            fixture = (storedID, rows)
        }
        var visibleTail = Array(fixture.rows.filter { row in
            guard let content = canonicalText(row) else { return false }
            return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.suffix(2))
        guard visibleTail.count == 2 else {
            throw XCTSkip("The qualifying transcript did not have two visible canonical tail rows.")
        }

        var link = URLComponents()
        link.scheme = "semreh"
        link.host = "session"
        link.queryItems = [URLQueryItem(name: "id", value: fixture.storedID)]

        if app.state != .runningForeground { app.launch() }
        app.open(try XCTUnwrap(link.url))
        let selectedTailText = try XCTUnwrap(canonicalText(visibleTail[0]))
        let selectedTail = app.staticTexts.matching(
            NSPredicate(format: "label == %@", selectedTailText)
        ).firstMatch
        XCTAssertTrue(selectedTail.waitForExistence(timeout: 30),
                      "Production deep link must display the selected long transcript tail.")
        let selectedDetail = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat-detail:")
        ).firstMatch
        XCTAssertTrue(selectedDetail.waitForExistence(timeout: 20))
        try assertAccessibleTranscriptRows(
            visibleTail, in: selectedDetail, context: "selected long chat before termination"
        )

        let transcript = selectedDetail.descendants(matching: .scrollView)
            .matching(identifier: "chat-transcript-scroll").firstMatch
        let tailRow = transcript.descendants(matching: .any)
            .matching(identifier: try XCTUnwrap(accessibleTranscriptRow(visibleTail[0])).identifier)
            .firstMatch
        tailRow.press(forDuration: 1.1)
        let copyAction = app.buttons["Copy"]
        XCTAssertTrue(copyAction.waitForExistence(timeout: 5) && copyAction.isHittable,
                      "The canonical row container must retain its message context menu.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()

        for launchNumber in 1...3 {
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
            app.launch()
            let restoredDetail = app.descendants(matching: .any).matching(
                identifier: selectedDetail.identifier
            ).firstMatch
            XCTAssertTrue(restoredDetail.waitForExistence(timeout: 30),
                          "Long chat plain launch \(launchNumber) must restore the same detail.")
            try assertAccessibleTranscriptRows(
                visibleTail,
                in: restoredDetail,
                context: "long automatic restore \(launchNumber) before interaction"
            )
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Long automatic restore \(launchNumber) before interaction"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testOptInPhoneNavigationLifecycleAndPagingRegression() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Phone regression verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_PHONE_REGRESSION_UI"] == "1" else {
            throw XCTSkip("Phone regression verification is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            return XCTFail("Phone regression verification requires the contained pinned stock fixture.")
        }

        let observer = try await LifecycleCanonicalObserver(
            origin: try XCTUnwrap(URL(string: origin)), credentials: try readCredentials()
        )
        defer { observer.invalidate() }
        guard let longFixture = try await observer.discoverLongStoredSession(minimumRows: 20) else {
            throw XCTSkip("The approved fixture needs one existing populated long transcript.")
        }
        var longRows = longFixture.rows
        XCTAssertGreaterThanOrEqual(longRows.count, min(100, longRows.count))
        let firstCanonicalID = try XCTUnwrap(accessibleTranscriptRow(longRows[0])).identifier
        let lastCanonicalID = try XCTUnwrap(accessibleTranscriptRow(longRows[longRows.count - 1])).identifier
        let discoveryAttachment = XCTAttachment(
            string: "sample_rows=\(min(100, longRows.count))\nfull_rows=\(longRows.count)\nfirst=\(firstCanonicalID)\nlast=\(lastCanonicalID)"
        )
        discoveryAttachment.name = "Phone regression bounded long fixture discovery"
        discoveryAttachment.lifetime = .keepAlways
        add(discoveryAttachment)

        let app = XCUIApplication()
        app.launch()
        defer { UIPasteboard.general.items = [] }
        let shortComposer = try openContainedNewChat(app: app)
        let shortMarker = try sendUniqueCompleted(
            "SEMREH_PHONE_NAV_SHORT", composer: shortComposer, app: app
        )
        let shortStoredID = try await observer.discoverStoredID(uniquePrompt: shortMarker)

        let shortBack = chatBackButton(app: app)
        XCTAssertTrue(shortBack.waitForExistence(timeout: 10) && shortBack.isHittable)
        let backStart = Date()
        shortBack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let sessionsRoot = app.navigationBars["Sessions"]
        XCTAssertTrue(sessionsRoot.waitForExistence(timeout: 5),
                      "One center tap on Back must reach the Sessions root.")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch.exists)
        var timings = ["back_center_seconds=\(Date().timeIntervalSince(backStart))"]
        defer {
            let timingAttachment = XCTAttachment(string: timings.joined(separator: "\n"))
            timingAttachment.name = "Phone regression bounded transition timings"
            timingAttachment.lifetime = .keepAlways
            add(timingAttachment)
        }

        for tab in ["Bots", "Activity", "Sessions"] {
            let control = app.buttons[tab]
            XCTAssertTrue(control.waitForExistence(timeout: 10) && control.isHittable)
            let start = Date()
            control.tap()
            let destination: XCUIElement
            switch tab {
            case "Bots": destination = app.navigationBars["Bots"]
            case "Activity": destination = app.navigationBars["Tasks"]
            default: destination = app.navigationBars["Sessions"]
            }
            XCTAssertTrue(destination.waitForExistence(timeout: 10),
                          "\(tab) must settle on its root destination.")
            timings.append("tab_\(tab.lowercased())_seconds=\(Date().timeIntervalSince(start))")
        }
        let tabScreenshot = XCTAttachment(screenshot: app.screenshot())
        tabScreenshot.name = "Phone regression native tab artwork and Sessions root"
        tabScreenshot.lifetime = .keepAlways
        add(tabScreenshot)

        if environment["SEMREH_PHONE_REGRESSION_CORE_ONLY"] != "1" {
            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10) && settings.isHittable)
            settings.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10) && done.isHittable)
            let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
            settingsScreenshot.name = "Phone regression Settings index full sheet"
            settingsScreenshot.lifetime = .keepAlways
            add(settingsScreenshot)
            for destinationName in ["Appearance", "Connections"] {
            let destinationRow = app.buttons[destinationName]
            XCTAssertTrue(destinationRow.waitForExistence(timeout: 10) && destinationRow.isHittable)
            destinationRow.tap()
            let navigationBar = app.navigationBars[destinationName]
            XCTAssertTrue(navigationBar.waitForExistence(timeout: 10),
                          "Settings destination \(destinationName) must expose native navigation chrome.")
            XCTAssertTrue(done.exists && done.isHittable,
                          "The Settings sheet Done control must remain available in \(destinationName).")
            if destinationName == "Appearance" {
                let theme = app.buttons["Theme"]
                XCTAssertTrue(theme.waitForExistence(timeout: 5) && theme.isHittable)
                theme.tap()
                let systemTheme = app.buttons["System"]
                XCTAssertTrue(systemTheme.waitForExistence(timeout: 5) && systemTheme.isHittable)
                systemTheme.tap()

                let accent = app.buttons["Accent"]
                XCTAssertTrue(accent.waitForExistence(timeout: 5) && accent.isHittable)
                accent.tap()
                let violet = app.buttons["Violet"]
                XCTAssertTrue(violet.waitForExistence(timeout: 5) && violet.isHittable)
                violet.tap()

                let tintActions = app.switches["Tint New Chat & Send"]
                XCTAssertTrue(tintActions.waitForExistence(timeout: 5) && tintActions.isHittable)
                if (tintActions.value as? String) != "1" { tintActions.tap() }
                let appearanceScreenshot = XCTAttachment(screenshot: app.screenshot())
                appearanceScreenshot.name = "Phone regression Semreh System Violet appearance selection"
                appearanceScreenshot.lifetime = .keepAlways
                add(appearanceScreenshot)
            }
            let destinationBack = navigationBar.buttons.firstMatch
            XCTAssertTrue(destinationBack.waitForExistence(timeout: 5) && destinationBack.isHittable)
            destinationBack.tap()
            XCTAssertTrue(app.buttons[destinationName].waitForExistence(timeout: 10),
                          "One native Back tap must return from \(destinationName) to Settings.")
            }
            done.tap()
            XCTAssertFalse(done.waitForExistence(timeout: 5))
        }

        var shortLink = URLComponents()
        shortLink.scheme = "semreh"
        shortLink.host = "session"
        shortLink.queryItems = [URLQueryItem(name: "id", value: shortStoredID)]
        app.open(try XCTUnwrap(shortLink.url))
        XCTAssertTrue(containing(shortMarker, app: app).waitForExistence(timeout: 20))
        let violetChatScreenshot = XCTAttachment(screenshot: app.screenshot())
        violetChatScreenshot.name = "Phone regression Violet chat bubble and composer tint"
        violetChatScreenshot.lifetime = .keepAlways
        add(violetChatScreenshot)

        var link = URLComponents()
        link.scheme = "semreh"
        link.host = "session"
        link.queryItems = [URLQueryItem(name: "id", value: longFixture.storedID)]
        let openStart = Date()
        app.open(try XCTUnwrap(link.url))
        let detail = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat-detail:")
        ).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        var visibleTail = Array(longRows.suffix(2))
        try assertAccessibleTranscriptRows(
            visibleTail, in: detail, context: "long chat after mixed navigation before interaction"
        )
        timings.append("open_long_seconds=\(Date().timeIntervalSince(openStart))")

        // Extend the retained real history only as far as the direct gateway's
        // 120-row boundary requires. This cannot turn paging into a no-op or an
        // unbounded fixture-generation loop.
        if longRows.count <= 120 {
            let seedTurns = (121 - longRows.count + 1) / 2
            XCTAssertLessThanOrEqual(seedTurns, 50, "Fixture paging setup must remain bounded.")
            let longComposer = app.descendants(matching: .any)
                .matching(identifier: "chat-composer-input").firstMatch
            XCTAssertTrue(longComposer.waitForExistence(timeout: 10) && longComposer.isHittable)
            for index in 0..<seedTurns {
                let marker = "SEMREH_PHONE_PAGE_SEED_\(index)_\(UUID().uuidString)"
                let baseline = longRows
                send(marker, through: longComposer, app: app)
                waitForIdle(app: app)
                longRows = try await observer.waitForLongTranscript(storedID: longFixture.storedID) { rows in
                    self.hasStableBaseline(rows, baseline: baseline)
                        && rows.count == baseline.count + 2
                        && rows[rows.count - 2]["role"] as? String == "user"
                        && self.canonicalText(rows[rows.count - 2]) == marker
                        && rows.last?["role"] as? String == "assistant"
                        && rows.last.flatMap({ self.canonicalText($0) }) == "SEMREH_SLICE1_ACK"
                }
            }
            XCTAssertGreaterThan(longRows.count, 120)
            visibleTail = Array(longRows.suffix(2))
            timings.append("paging_seed_turns=\(seedTurns)")
        }

        let busyMarker = "SEMREH_INTERRUPT_FIXTURE SEMREH_PHONE_BUSY_BACK_\(UUID().uuidString)"
        let busyBaseline = longRows
        let busyComposer = app.descendants(matching: .any)
            .matching(identifier: "chat-composer-input").firstMatch
        send(busyMarker, through: busyComposer, app: app)
        XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 10))
        let busyBack = chatBackButton(app: app)
        XCTAssertTrue(busyBack.waitForExistence(timeout: 5) && busyBack.isHittable)
        let busyBackStart = Date()
        busyBack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5),
                      "One center Back tap must leave a busy, heavily populated chat.")
        timings.append("busy_back_seconds=\(Date().timeIntervalSince(busyBackStart))")
        longRows = try await observer.waitForLongTranscript(storedID: longFixture.storedID) { rows in
            self.hasStableBaseline(rows, baseline: busyBaseline)
                && rows.count == busyBaseline.count + 2
                && self.canonicalText(rows[rows.count - 2]) == busyMarker
                && rows.last.flatMap({ self.canonicalText($0) }) == "SEMREH_SLICE1_ACK"
        }
        app.open(try XCTUnwrap(link.url))
        visibleTail = Array(longRows.suffix(2))
        try assertAccessibleTranscriptRows(
            visibleTail, in: detail, context: "busy long chat warm reentry before interaction"
        )
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        app.launch()
        app.open(try XCTUnwrap(link.url))
        visibleTail = Array(longRows.suffix(2))
        try assertAccessibleTranscriptRows(
            visibleTail, in: detail, context: "busy long chat reentry before interaction"
        )

        XCUIDevice.shared.press(.home)
        let backgroundDeadline = Date().addingTimeInterval(5)
        while app.state == .runningForeground && Date() < backgroundDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNotEqual(app.state, .runningForeground)
        let foregroundStart = Date()
        app.activate()
        try assertAccessibleTranscriptRows(
            visibleTail, in: detail, context: "long chat after background and foreground before interaction"
        )
        timings.append("foreground_long_seconds=\(Date().timeIntervalSince(foregroundStart))")

        let transcript = detail.descendants(matching: .scrollView)
            .matching(identifier: "chat-transcript-scroll").firstMatch
        let anchor = try XCTUnwrap(accessibleTranscriptRow(longRows[longRows.count - 120]))
        let anchorElement = transcript.descendants(matching: .any).matching(identifier: anchor.identifier).firstMatch
        let oldest = try XCTUnwrap(accessibleTranscriptRow(longRows[0]))
        let oldestElement = transcript.descendants(matching: .any).matching(identifier: oldest.identifier).firstMatch
        XCTAssertFalse(oldestElement.exists,
                       "Cold reentry must begin with the canonical 120-row tail before paging.")
        let loadOlder = app.buttons["Load older messages"]
        for _ in 0..<15 where !anchorElement.isHittable { transcript.swipeDown() }
        XCTAssertTrue(anchorElement.waitForExistence(timeout: 10) && anchorElement.isHittable)
        let anchorY = anchorElement.frame.midY
        let pagingStart = Date()
        // Automatic near-top prefetch is the production path. If it has not
        // started after reaching the boundary, use the visible manual control;
        // either path must realize a genuinely older canonical row.
        if !oldestElement.waitForExistence(timeout: 3) {
            XCTAssertTrue(loadOlder.waitForExistence(timeout: 5) && loadOlder.isHittable)
            loadOlder.tap()
        }
        XCTAssertTrue(oldestElement.waitForExistence(timeout: 20),
                      "Paging must prepend a canonical row older than the initial 120-row tail.")
        XCTAssertTrue(anchorElement.waitForExistence(timeout: 20) && anchorElement.isHittable)
        let anchorDisplacement = abs(anchorElement.frame.midY - anchorY)
        XCTAssertLessThanOrEqual(anchorDisplacement, 80,
                                 "Loading older history must preserve the visible anchor position.")
        timings.append("paging_seconds=\(Date().timeIntervalSince(pagingStart))")
        timings.append("paging_anchor_displacement_points=\(anchorDisplacement)")

        let scrollToLatest = app.buttons["Scroll to latest message"]
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 10) && scrollToLatest.isHittable)
        let farLatestStart = Date()
        scrollToLatest.tap()
        try assertAccessibleTranscriptRows(
            visibleTail, in: detail, context: "far-history return to latest"
        )
        timings.append("far_history_to_latest_seconds=\(Date().timeIntervalSince(farLatestStart))")
        let nearTail = transcript.descendants(matching: .any)
            .matching(identifier: try XCTUnwrap(accessibleTranscriptRow(visibleTail[0])).identifier).firstMatch
        XCTAssertTrue(nearTail.waitForExistence(timeout: 5) && nearTail.isHittable)
        let nearTailY = nearTail.frame.midY
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
            .press(forDuration: 0.35,
                   thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52)))
        XCTAssertTrue(nearTail.exists)
        let nearDisplacement = abs(nearTail.frame.midY - nearTailY)
        XCTAssertGreaterThan(nearDisplacement, 0)
        XCTAssertLessThanOrEqual(nearDisplacement, 640,
                                 "Near-bottom motion gate must stay inside the product animation band.")
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 10) && scrollToLatest.isHittable)
        let nearLatestStart = Date()
        scrollToLatest.tap()
        try assertAccessibleTranscriptRows(
            visibleTail, in: detail, context: "near-bottom return to latest"
        )
        timings.append("near_bottom_to_latest_seconds=\(Date().timeIntervalSince(nearLatestStart))")
        timings.append("near_bottom_displacement_points=\(nearDisplacement)")

        app.open(try XCTUnwrap(shortLink.url))
        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20) && composer.isHittable)
        XCTAssertTrue(containing(shortMarker, app: app).waitForExistence(timeout: 20),
                      "Switching chats must render the selected transcript before the next send.")
        let stopBaseline = try await observer.transcript(storedID: shortStoredID, limit: 100)
        let interrupted = "SEMREH_INTERRUPT_FIXTURE SEMREH_PHONE_STOP_\(UUID().uuidString)"
        send(interrupted, through: composer, app: app)
        let stop = app.buttons["Stop response"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && stop.isHittable)
        XCTAssertEqual(exactCount(interrupted, app: app), 1)
        stop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let stoppingLabels = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Stopping response...")
        )
        let observedStopping = stoppingLabels.firstMatch.waitForExistence(timeout: 0.5)
        if observedStopping {
            XCTAssertEqual(stoppingLabels.count, 1,
                           "Stopping must not be duplicated in the transcript overlay.")
        }
        timings.append("stopping_label_observed=\(observedStopping)")
        waitForIdle(app: app)
        _ = try await observer.waitForLongTranscript(storedID: shortStoredID) { rows in
            self.exactAcceptedWithoutAssistant(rows, baseline: stopBaseline, prompt: interrupted)
        }
        try await Task.sleep(for: .seconds(16))
        let durableStoppedRows = try await observer.transcript(storedID: shortStoredID, limit: 100)
        XCTAssertTrue(
            exactAcceptedWithoutAssistant(
                durableStoppedRows, baseline: stopBaseline, prompt: interrupted
            ),
            "Cancellation must remain durable beyond the deterministic fixture response deadline."
        )
        XCTAssertEqual(exactCount(interrupted, app: app), 1)
        XCTAssertFalse(app.staticTexts["Loading messages"].exists)
        let stoppedScreenshot = XCTAttachment(screenshot: app.screenshot())
        stoppedScreenshot.name = "Phone regression final stopped short chat"
        stoppedScreenshot.lifetime = .keepAlways
        add(stoppedScreenshot)

        let finalBack = chatBackButton(app: app)
        XCTAssertTrue(finalBack.waitForExistence(timeout: 5) && finalBack.isHittable)
        finalBack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        if environment["SEMREH_PHONE_REGRESSION_CORE_ONLY"] != "1" {
            let settings = app.buttons["Settings"]
            let done = app.buttons["Done"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5) && settings.isHittable)
            settings.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
            XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 5))
            app.buttons["Appearance"].tap()
            XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["Theme"].value as? String, "System")
            XCTAssertEqual(app.buttons["Accent"].value as? String, "Violet")
            app.buttons["Accent"].tap()
            XCTAssertTrue(app.buttons["Warm"].waitForExistence(timeout: 5) && app.buttons["Warm"].isHittable)
            app.buttons["Warm"].tap()
            let finalTintActions = app.switches["Tint New Chat & Send"]
            if (finalTintActions.value as? String) == "1" { finalTintActions.tap() }
            app.navigationBars["Appearance"].buttons.firstMatch.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
            done.tap()
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Phone regression restored Warm System settings root"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOptInPhoneSettingsAppearanceRegression() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Phone Settings verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_PHONE_SETTINGS_UI"] == "1" else {
            throw XCTSkip("Phone Settings verification is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            return XCTFail("Phone Settings verification requires the contained pinned stock fixture.")
        }

        let app = XCUIApplication()
        app.launch()
        defer { UIPasteboard.general.items = [] }
        let back = chatBackButton(app: app)
        if back.waitForExistence(timeout: 5), back.isHittable { back.tap() }
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
        let activityTab = app.buttons["Activity"]
        XCTAssertTrue(activityTab.waitForExistence(timeout: 5) && activityTab.isHittable)
        activityTab.tap()
        retainPhoneScreenshot("Phone Tasks loading themed canvas", app: app)
        XCTAssertTrue(app.navigationBars["Tasks"].waitForExistence(timeout: 10))
        retainPhoneScreenshot("Phone Tasks settled themed canvas", app: app)
        let sessionsTab = app.buttons["Sessions"]
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 5) && sessionsTab.isHittable)
        sessionsTab.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5) && settings.isHittable)
        settings.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10) && done.isHittable)
        retainPhoneScreenshot("Phone Settings corrected full sheet canvas", app: app)

        let appearance = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Appearance,")
        ).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5) && appearance.isHittable)
        appearance.tap()
        let appearanceBar = app.navigationBars["Appearance"]
        XCTAssertTrue(appearanceBar.waitForExistence(timeout: 10))
        XCTAssertTrue(done.exists && done.isHittable)
        retainPhoneScreenshot("Phone Settings full Appearance destination", app: app)
        let themePicker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Theme,")
        ).firstMatch
        let accentPicker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Accent,")
        ).firstMatch
        XCTAssertTrue(themePicker.exists && themePicker.isHittable)
        themePicker.tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        retainPhoneScreenshot("Phone Settings forced Dark Appearance", app: app)
        themePicker.tap()
        XCTAssertTrue(app.buttons["System"].waitForExistence(timeout: 5))
        app.buttons["System"].tap()
        XCTAssertTrue(accentPicker.exists && accentPicker.isHittable)
        accentPicker.tap()
        XCTAssertTrue(app.buttons["Violet"].waitForExistence(timeout: 5))
        app.buttons["Violet"].tap()
        let tintActions = app.switches["Tint New Chat & Send"]
        XCTAssertTrue(tintActions.waitForExistence(timeout: 5) && tintActions.isHittable)
        if (tintActions.value as? String) != "1" { tintActions.tap() }
        retainPhoneScreenshot("Phone Settings System Violet selected", app: app)
        let appearanceBack = appearanceBar.buttons.firstMatch
        XCTAssertTrue(appearanceBack.waitForExistence(timeout: 5) && appearanceBack.isHittable)
        appearanceBack.tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))

        let connections = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Connections,")
        ).firstMatch
        XCTAssertTrue(connections.waitForExistence(timeout: 5) && connections.isHittable)
        connections.tap()
        let connectionsBar = app.navigationBars["Connections"]
        XCTAssertTrue(connectionsBar.waitForExistence(timeout: 10))
        XCTAssertTrue(done.exists && done.isHittable)
        let connectionsBack = connectionsBar.buttons.firstMatch
        XCTAssertTrue(connectionsBack.waitForExistence(timeout: 5) && connectionsBack.isHittable)
        connectionsBack.tap()
        XCTAssertTrue(connections.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertFalse(done.waitForExistence(timeout: 5))

        let composer = try openContainedNewChat(app: app)
        _ = try sendUniqueCompleted("SEMREH_PHONE_VIOLET", composer: composer, app: app)
        retainPhoneScreenshot("Phone Settings Violet chat bubble and composer tint", app: app)
        let chatBack = chatBackButton(app: app)
        XCTAssertTrue(chatBack.waitForExistence(timeout: 5) && chatBack.isHittable)
        chatBack.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        let restoredChatBack = chatBackButton(app: app)
        if restoredChatBack.waitForExistence(timeout: 5), restoredChatBack.isHittable {
            restoredChatBack.tap()
        }
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.staticTexts["System"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Violet"].waitForExistence(timeout: 5))
        XCTAssertEqual(tintActions.value as? String, "1")
        accentPicker.tap()
        XCTAssertTrue(app.buttons["Warm"].waitForExistence(timeout: 5))
        app.buttons["Warm"].tap()
        if (tintActions.value as? String) == "1" { tintActions.tap() }
        appearanceBar.buttons.firstMatch.tap()
        done.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOptInPhoneOnboardingAppearanceAndContainedLogin() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Phone onboarding verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_PHONE_ONBOARDING_UI"] == "1" else {
            throw XCTSkip("Phone onboarding verification is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            return XCTFail("Phone onboarding verification requires the contained pinned stock fixture.")
        }

        let credentials = try readCredentials()
        let app = XCUIApplication()
        app.launch()
        defer { UIPasteboard.general.items = [] }

        // This helper refuses to sign out unless the exact contained fixture host
        // is visible. Normal sign-out clears only that disposable fixture's local
        // auth material; no app-container reset, uninstall, or test auth bypass.
        try prepareExclusiveContainedFixtureSignOut(app: app)
        let welcome = containing("Your Hermes companion", app: app)
        XCTAssertTrue(welcome.waitForExistence(timeout: 15) && welcome.isHittable)
        retainPhoneScreenshot("Phone onboarding Welcome", app: app)

        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5) && getStarted.isHittable)
        getStarted.tap()
        XCTAssertTrue(containing("Make it yours", app: app).waitForExistence(timeout: 10))

        let darkTheme = app.buttons["Dark"]
        XCTAssertTrue(darkTheme.waitForExistence(timeout: 5) && darkTheme.isHittable)
        darkTheme.tap()
        let violetAccent = app.buttons["Violet accent"]
        XCTAssertTrue(violetAccent.waitForExistence(timeout: 5) && violetAccent.isHittable)
        violetAccent.tap()
        XCTAssertTrue(
            containing("Preview using Dark appearance and Violet accent", app: app)
                .waitForExistence(timeout: 5)
        )
        retainPhoneScreenshot("Phone onboarding Appearance Dark Violet", app: app)

        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5) && continueButton.isHittable)
        continueButton.tap()
        let server = app.textFields["onboarding-server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 10) && server.isHittable)
        retainPhoneScreenshot("Phone onboarding Connect manual and QR choices", app: app)

        let scan = app.buttons["Scan setup code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5) && scan.isHittable)
        scan.tap()
        XCTAssertTrue(containing("Scan your server address", app: app).waitForExistence(timeout: 5))
        XCTAssertTrue(containing("Scanning does not connect or sign in", app: app).exists)
        let enterInstead = app.buttons["Enter an address instead"]
        XCTAssertTrue(enterInstead.waitForExistence(timeout: 5) && enterInstead.isHittable)
        retainPhoneScreenshot("Phone onboarding QR scanner manual fallback", app: app)
        enterInstead.tap()
        XCTAssertTrue(server.waitForExistence(timeout: 5) && server.isHittable)

        replace(server, with: origin, app: app)
        let testConnection = app.buttons["Test Connection"]
        XCTAssertTrue(testConnection.waitForExistence(timeout: 5) && testConnection.isHittable)
        testConnection.tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        replace(username, with: credentials.username, app: app)
        paste(credentials.password, into: password, app: app)
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5) && connect.isHittable)
        connect.tap()

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
            let back = chatBackButton(app: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(sessions.waitForExistence(timeout: 30) && sessions.isHittable)
        sessions.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
        retainPhoneScreenshot("Phone onboarding authenticated contained fixture", app: app)

        let bots = app.buttons["Bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 5) && bots.isHittable)
        bots.tap()
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        let botRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bot-profile:")
        )
        XCTAssertGreaterThan(botRows.count, 0, "The fixture must expose at least one flat server profile.")
        XCTAssertTrue(app.staticTexts["Your Team"].exists)
        retainPhoneScreenshot("Phone onboarding Bots flat fixture profiles", app: app)

        app.terminate()
        app.launch()
        let coldDestinationDeadline = Date().addingTimeInterval(30)
        while !sessions.exists && !app.navigationBars["Sessions"].exists
            && !app.otherElements.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch.exists
            && Date() < coldDestinationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        // Capture the actual cold-restored production destination before any
        // interaction. This is visual evidence for the persisted appearance's
        // next consumer; Settings readback below independently checks the value.
        retainPhoneScreenshot("Phone onboarding cold Dark Violet production consumer", app: app)

        let coldChat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        if coldChat.exists {
            let back = chatBackButton(app: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(sessions.waitForExistence(timeout: 15) && sessions.isHittable)
        sessions.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5) && settings.isHittable)
        settings.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10) && done.isHittable)
        let appearance = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Appearance,")
        ).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5) && appearance.isHittable)
        appearance.tap()
        XCTAssertTrue(app.staticTexts["Dark"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Violet"].waitForExistence(timeout: 5))
        retainPhoneScreenshot("Phone onboarding cold Appearance readback", app: app)
        let settingsTheme = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Theme,")
        ).firstMatch
        let settingsAccent = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Accent,")
        ).firstMatch
        settingsTheme.tap()
        XCTAssertTrue(app.buttons["System"].waitForExistence(timeout: 5))
        app.buttons["System"].tap()
        settingsAccent.tap()
        XCTAssertTrue(app.buttons["Warm"].waitForExistence(timeout: 5))
        app.buttons["Warm"].tap()
        let settingsTint = app.switches["Tint New Chat & Send"]
        if (settingsTint.value as? String) == "1" { settingsTint.tap() }
        app.navigationBars["Appearance"].buttons.firstMatch.tap()
        done.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOptInPhoneTasksLoadingAndBotsReturnRegression() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Phone tab loading verification is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_PHONE_TAB_LOADING_UI"] == "1" else {
            throw XCTSkip("Phone tab loading verification is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == backendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == credentialsPath else {
            return XCTFail("Phone tab loading verification requires the contained pinned stock fixture.")
        }

        let app = XCUIApplication()
        app.launch()
        let sessions = app.buttons["Sessions"]
        let restoredChat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        if restoredChat.waitForExistence(timeout: 5) {
            let back = chatBackButton(app: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(sessions.waitForExistence(timeout: 15) && sessions.isHittable)

        let activity = app.buttons["Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5) && activity.isHittable)
        activity.tap()
        XCTAssertTrue(app.navigationBars["Tasks"].waitForExistence(timeout: 10))
        retainPhoneScreenshot("Phone current Tasks immediate loading surface", app: app)
        let loadingActivity = app.staticTexts["Loading activity"]
        XCTAssertTrue(loadingActivity.waitForNonExistence(timeout: 30))
        XCTAssertTrue(
            containing("Scheduled work", app: app).exists
                || containing("Activity unavailable", app: app).exists
        )
        retainPhoneScreenshot("Phone current Tasks settled surface", app: app)

        let bots = app.buttons["Bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 5) && bots.isHittable)
        bots.tap()
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        retainPhoneScreenshot("Phone current Bots immediate loading surface", app: app)
        let botRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bot-profile:")
        )
        XCTAssertTrue(botRows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Loading bots"].exists)
        retainPhoneScreenshot("Phone current Bots settled Your Team", app: app)

        sessions.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
        bots.tap()
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        XCTAssertTrue(botRows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Loading bots"].exists)
        retainPhoneScreenshot("Phone current Bots return remains loaded", app: app)
    }

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
            let selectedComposer = app.descendants(matching: .any)
                .matching(identifier: "chat-composer-input").firstMatch
            XCTAssertTrue(selectedComposer.waitForExistence(timeout: 30))
            let selectedDetail = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chat-detail:")
            ).firstMatch
            XCTAssertTrue(selectedDetail.waitForExistence(timeout: 10))
            try assertAccessibleTranscriptRows(
                baseline,
                in: selectedDetail,
                context: "selected existing chat before termination"
            )
            let selectedDetailID = selectedDetail.identifier
            // This gate isolates existing-chat viewport restoration. Completion
            // while away and explicit send-next remain separate lifecycle gates.
            for launchNumber in 1...3 {
                app.terminate()
                XCTAssertEqual(app.state, .notRunning)
                app.launch()
                let restoredComposer = app.descendants(matching: .any)
                    .matching(identifier: "chat-composer-input").firstMatch
                XCTAssertTrue(restoredComposer.waitForExistence(timeout: 30),
                              "Plain launch \(launchNumber) must restore the selected existing conversation.")
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: selectedDetailID)
                    .firstMatch.waitForExistence(timeout: 10),
                    "Plain launch \(launchNumber) must preserve the pre-termination chat detail identity.")
                let restoredDetail = app.descendants(matching: .any).matching(identifier: selectedDetailID).firstMatch
                try assertAccessibleTranscriptRows(
                    baseline,
                    in: restoredDetail,
                    context: "automatic restore \(launchNumber) before interaction"
                )
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Automatic restore \(launchNumber) before interaction"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
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
            let foregroundComposer = app.descendants(matching: .any)
                .matching(identifier: "chat-composer-input").firstMatch
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
            let reopenedComposer = app.descendants(matching: .any)
                .matching(identifier: "chat-composer-input").firstMatch
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
            let welcome = containing("Your Hermes companion", app: app)
            guard welcome.waitForExistence(timeout: 5) && welcome.isHittable else {
                return XCTFail("Refusing to sign out or navigate an authenticated non-fixture account.")
            }
            let existingServer = app.buttons["Get Started"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5) && existingServer.isHittable)
            existingServer.tap()
            advanceOnboardingAppearanceIfNeeded(app: app)
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
        let newSession = app.buttons["New chat"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15) && newSession.isHittable)
        newSession.tap()

        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat-composer-input").firstMatch
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
            let welcome = containing("Your Hermes companion", app: app)
            guard welcome.waitForExistence(timeout: 5) && welcome.isHittable else {
                return XCTFail("Refusing to sign out or navigate an authenticated non-fixture account.")
            }
            let existingServer = app.buttons["Get Started"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5) && existingServer.isHittable)
            existingServer.tap()
            advanceOnboardingAppearanceIfNeeded(app: app)
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
        let newSession = app.buttons["New chat"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15) && newSession.isHittable)
        newSession.tap()

        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat-composer-input").firstMatch
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
            let welcome = containing("Your Hermes companion", app: app)
            XCTAssertTrue(welcome.waitForExistence(timeout: 15) && welcome.isHittable)
            let existingServer = app.buttons["Get Started"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5) && existingServer.isHittable)
            existingServer.tap()
            advanceOnboardingAppearanceIfNeeded(app: app)
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
        let welcome = containing("Your Hermes companion", app: app)
        if welcome.waitForExistence(timeout: 15) && welcome.isHittable {
            let help = app.buttons["Need help connecting?"]
            XCTAssertTrue(help.waitForExistence(timeout: 5) && help.isHittable); help.tap()
            XCTAssertTrue(app.navigationBars["Connection help"].waitForExistence(timeout: 5))
            XCTAssertTrue(containing("Use first-party Hermes", app: app).exists)
            XCTAssertTrue(containing("dedicated authenticated HTTPS", app: app).exists)
            let guidanceScreenshot = XCTAttachment(screenshot: app.screenshot())
            guidanceScreenshot.name = "First-party Hermes server guidance"
            guidanceScreenshot.lifetime = .keepAlways
            add(guidanceScreenshot)
            app.buttons["Done"].tap()

            let getStarted = app.buttons["Get Started"]
            XCTAssertTrue(getStarted.waitForExistence(timeout: 5) && getStarted.isHittable); getStarted.tap()
            advanceOnboardingAppearanceIfNeeded(app: app)
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
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 15))
        app.buttons["New chat"].tap()
        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat-composer-input").firstMatch
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
    private func chatBackButton(app: XCUIApplication) -> XCUIElement {
        // The current chat header owns Back outside the hidden navigation bar.
        // Keep the native navigation-bar selector as a compatibility fallback
        // for destinations that still expose the legacy stack button.
        // ChatView's container identifier is intentionally inherited by its
        // descendants, so subscript lookup may prefer that identifier over the
        // visible button label. Match the button role and exact label directly.
        let customBack = app.buttons.matching(
            NSPredicate(format: "label == %@", "Back")
        ).firstMatch
        if customBack.exists { return customBack }
        return app.navigationBars.buttons["BackButton"]
    }

    @MainActor
    private func openContainedNewChat(app: XCUIApplication) throws -> XCUIElement {
        let credentials = try readCredentials()
        dismissKnownPasswordSavePrompt(app, timeout: 1)
        try prepareContainedSignIn(app: app)
        let server = app.textFields["onboarding-server-url"]
        if !(server.waitForExistence(timeout: 4) && server.isHittable) {
            let welcome = containing("Your Hermes companion", app: app)
            guard welcome.waitForExistence(timeout: 5) && welcome.isHittable else {
                XCTFail("Refusing to sign out or navigate an authenticated non-fixture account.")
                throw NSError(domain: "DirectSkillUITests", code: 3)
            }
            let existingServer = app.buttons["Get Started"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5) && existingServer.isHittable)
            existingServer.tap()
            advanceOnboardingAppearanceIfNeeded(app: app)
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
            let back = chatBackButton(app: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(sessions.waitForExistence(timeout: 30) && sessions.isHittable)
        sessions.tap()
        let newSession = app.buttons["New chat"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15) && newSession.isHittable)
        newSession.tap()
        let defaultBot = app.buttons["bot-profile:default"]
        if defaultBot.waitForExistence(timeout: 5) {
            XCTAssertTrue(defaultBot.isHittable)
            defaultBot.tap()
        }
        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20) && composer.isHittable)
        return composer
    }

    @MainActor
    private func prepareContainedSignIn(app: XCUIApplication) throws {
        let welcome = containing("Your Hermes companion", app: app)
        if welcome.waitForExistence(timeout: 5) || app.textFields["onboarding-server-url"].exists { return }
        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        if chat.exists {
            let back = chatBackButton(app: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
            RunLoop.main.run(until: Date().addingTimeInterval(0.75))
            let remainingChat = app.otherElements.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch
            XCTAssertFalse(
                remainingChat.exists,
                "Back tap must return to the Sessions root without restoring the same chat."
            )
        }
        if !app.staticTexts["Settings"].exists {
            let you = app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
            XCTAssertTrue(you.waitForExistence(timeout: 10) && you.isHittable)
            you.tap()
        }
        XCTAssertTrue(app.staticTexts["semreh-slice1-test.tailda8427.ts.net"].waitForExistence(timeout: 15),
                      "Refusing to sign out an authenticated server other than the contained fixture.")
        let signOut = containedSignOutButton(app)
        signOut.tap()
        let confirmation = app.alerts["Sign out of this server?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Sign Out"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 20))
    }

    @MainActor
    private func prepareExclusiveContainedFixtureSignOut(app: XCUIApplication) throws {
        let welcome = containing("Your Hermes companion", app: app)
        if welcome.waitForExistence(timeout: 5) && welcome.isHittable { return }

        XCTAssertFalse(
            app.textFields["onboarding-server-url"].exists,
            "Refusing to modify authentication from an unproven onboarding state."
        )

        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        if chat.exists {
            let back = chatBackButton(app: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
            back.tap()
        }

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10) && settings.isHittable)
        settings.tap()
        XCTAssertTrue(
            app.staticTexts["semreh-slice1-test.tailda8427.ts.net"].waitForExistence(timeout: 15),
            "Refusing to sign out an authenticated server other than the contained fixture."
        )

        let aboutAndStorage = app.staticTexts["About & Storage"]
        for _ in 0..<8 where !aboutAndStorage.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(aboutAndStorage.waitForExistence(timeout: 5) && aboutAndStorage.isHittable)
        aboutAndStorage.tap()

        let singleServerFootnote = app.staticTexts[
            "Signs out of the active server and returns to onboarding."
        ]
        for _ in 0..<8 where !singleServerFootnote.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(
            singleServerFootnote.waitForExistence(timeout: 5) && singleServerFootnote.isHittable,
            "Refusing sign-out unless the contained fixture is the only configured server."
        )

        let signOut = app.buttons["Sign Out of This Server"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5) && signOut.isHittable)
        signOut.tap()
        let confirmation = app.alerts["Sign out of this server?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Sign Out"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 20) && welcome.isHittable)
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
        profile: String = "default",
        timeout: TimeInterval = 45,
        beforeRead: () -> Void = {},
        matches: ([[String: Any]]) -> Bool
    ) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            beforeRead()
            let page = try await observer.transcript(storedID: storedID, profile: profile)
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

    private struct AccessibleTranscriptRow {
        let identifier: String
        let label: String
    }

    @MainActor
    private func assertAccessibleTranscriptRows(
        _ rows: [[String: Any]],
        in detail: XCUIElement,
        context: String
    ) throws {
        let expected = rows.compactMap(accessibleTranscriptRow)
        guard expected.count == rows.count else {
            XCTFail("\(context) must expose a stable canonical ID for every visible row.")
            throw NSError(domain: "DirectSkillUITests", code: 17)
        }

        let transcript = detail.descendants(matching: .scrollView)
            .matching(identifier: "chat-transcript-scroll")
            .firstMatch
        guard transcript.waitForExistence(timeout: 10) else {
            XCTFail("\(context) must expose the canonical transcript scroll container.")
            throw NSError(domain: "DirectSkillUITests", code: 18)
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let allPresent = expected.allSatisfy { row in
                transcript.descendants(matching: .any).matching(identifier: row.identifier).count == 1
            }
            if allPresent { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        for row in expected {
            let matches = transcript.descendants(matching: .any).matching(identifier: row.identifier)
            guard matches.count == 1 else {
                XCTFail("\(context) must expose exactly one AX row for \(row.identifier).")
                throw NSError(domain: "DirectSkillUITests", code: 19)
            }
            let element = matches.firstMatch
            guard element.waitForExistence(timeout: 5) else {
                XCTFail("\(context) must expose the \(row.identifier) AX row.")
                throw NSError(domain: "DirectSkillUITests", code: 20)
            }
            guard element.label == row.label else {
                XCTFail("\(context) AX row must identify its truthful role and content.")
                throw NSError(domain: "DirectSkillUITests", code: 21)
            }
            guard element.isHittable else {
                XCTFail("\(context) AX row must be visible and hittable before interaction.")
                throw NSError(domain: "DirectSkillUITests", code: 22)
            }
        }
    }

    private func accessibleTranscriptRow(_ row: [String: Any]) -> AccessibleTranscriptRow? {
        guard let messageID = canonicalMessageID(row),
              let role = row["role"] as? String,
              let content = canonicalText(row) else { return nil }
        return AccessibleTranscriptRow(
            identifier: "message-row:\(messageID)",
            label: accessibleTranscriptRowLabel(role: role, content: content)
        )
    }

    private func accessibleTranscriptRowLabel(role: String, content: String) -> String {
        let roleLabel: String
        switch role {
        case "user": roleLabel = "User"
        case "assistant": roleLabel = "Assistant"
        case "local_assistant": roleLabel = "Semreh"
        case "local_notice": roleLabel = "Notice"
        default: roleLabel = "Message"
        }

        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "\(roleLabel) message" }
        return "\(roleLabel) message: \(text)"
    }

    private func canonicalMessageID(_ row: [String: Any]) -> String? {
        if let value = row["id"] as? String, !value.isEmpty { return value }
        if let value = row["id"] as? NSNumber { return value.stringValue }
        return nil
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
            let composer = app.descendants(matching: .any)
                .matching(identifier: "chat-composer-input").firstMatch
            if !app.buttons["Stop response"].exists && composer.isHittable
                && (app.buttons["Send"].exists || app.buttons["Voice input"].exists) { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(app.buttons["Stop response"].exists)
        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(app.buttons["Send"].exists || app.buttons["Voice input"].exists)
    }

    private func signOutIfNeeded(_ app: XCUIApplication) throws {
        let welcome = containing("Your Hermes companion", app: app)
        if welcome.waitForExistence(timeout: 4) && welcome.isHittable { return }
        let you = app.buttons["Account and settings"]
        if !app.staticTexts["Settings"].exists && !you.waitForExistence(timeout: 5) {
            let knownBack = app.navigationBars.buttons["BackButton"]
            let back = knownBack.exists ? knownBack : app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        if !app.staticTexts["Settings"].exists {
            XCTAssertTrue(you.waitForExistence(timeout: 10)); you.tap()
        }
        let signOut = containedSignOutButton(app)
        signOut.tap()
        let confirmation = app.alerts["Sign out of this server?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Sign Out"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 20))
    }

    @MainActor
    private func advanceOnboardingAppearanceIfNeeded(app: XCUIApplication) {
        let appearance = app.staticTexts["Make it yours"]
        guard appearance.waitForExistence(timeout: 5) else { return }
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5) && continueButton.isHittable)
        continueButton.tap()
    }

    private func containedSignOutButton(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.staticTexts["semreh-slice1-test.tailda8427.ts.net"].waitForExistence(timeout: 15),
                      "Refusing to sign out an authenticated server other than the contained fixture.")
        let signOut = app.buttons["Sign Out of This Server"]
        if !signOut.exists {
            let appSettings = app.staticTexts["About & Storage"]
            for _ in 0..<8 where !appSettings.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(appSettings.waitForExistence(timeout: 5) && appSettings.isHittable)
            appSettings.tap()
        }
        for _ in 0..<8 where !signOut.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(signOut.waitForExistence(timeout: 5) && signOut.isHittable)
        return signOut
    }

    private func retainPhoneScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

        func activeProfile() async throws -> String? {
            let (data, response) = try await request(path: "/api/profiles/active", method: "GET")
            guard (200..<300).contains(response.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "DirectSkillUITests", code: 15)
            }
            return payload["current"] as? String
        }

        func defaultProfile() async throws -> String? {
            let (data, response) = try await request(path: "/api/profiles", method: "GET")
            guard (200..<300).contains(response.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profiles = payload["profiles"] as? [[String: Any]] else {
                throw NSError(domain: "DirectSkillUITests", code: 16)
            }
            return profiles.first(where: { $0["is_default"] as? Bool == true })?["name"] as? String
        }

        func discoverStoredID(uniquePrompt: String, profile: String = "default") async throws -> String {
            let deadline = Date().addingTimeInterval(45)
            var lastCandidateCount = 0
            while Date() < deadline {
                var components = URLComponents()
                components.path = "/api/sessions"
                components.queryItems = [
                    URLQueryItem(name: "profile", value: profile),
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
                    let rows = try await transcript(storedID: storedID, profile: profile)
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

        func discoverLongStoredSession(
            minimumRows: Int,
            profile: String = "default"
        ) async throws -> (storedID: String, rows: [[String: Any]])? {
            var components = URLComponents()
            components.path = "/api/sessions"
            components.queryItems = [
                URLQueryItem(name: "profile", value: profile),
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "order", value: "recent"),
                URLQueryItem(name: "archived", value: "exclude"),
            ]
            let (data, response) = try await request(
                path: try XCTUnwrap(components.string), method: "GET"
            )
            guard (200..<300).contains(response.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessions = payload["sessions"] as? [[String: Any]],
                  sessions.count <= 20 else {
                throw NSError(domain: "DirectSkillUITests", code: 23)
            }

            var best: (storedID: String, rows: [[String: Any]])?
            for candidate in sessions {
                guard let storedID = candidate["id"] as? String,
                      storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$",
                                     options: .regularExpression) != nil else {
                    throw NSError(domain: "DirectSkillUITests", code: 24)
                }
                let rows = try await transcript(storedID: storedID, profile: profile, limit: 100)
                guard rows.count >= minimumRows else { continue }
                let ids = rows.compactMap { row -> String? in
                    if let value = row["id"] as? String, !value.isEmpty { return value }
                    if let value = row["id"] as? NSNumber { return value.stringValue }
                    return nil
                }
                guard ids.count == rows.count, Set(ids).count == ids.count else { continue }
                if best == nil || rows.count > best!.rows.count {
                    best = (storedID, rows)
                }
            }
            guard let best else { return nil }
            let fullRows = try await fullTranscript(storedID: best.storedID)
            guard fullRows.count >= best.rows.count else {
                throw NSError(domain: "DirectSkillUITests", code: 25)
            }
            return (best.storedID, fullRows)
        }

        func waitForLongTranscript(
            storedID: String,
            predicate: ([[String: Any]]) -> Bool
        ) async throws -> [[String: Any]] {
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                let rows = try await fullTranscript(storedID: storedID)
                if predicate(rows) { return rows }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NSError(domain: "DirectSkillUITests", code: 26)
        }

        func transcript(
            storedID: String,
            profile: String = "default",
            limit: Int = 20,
            offset: Int = 0
        ) async throws -> [[String: Any]] {
            var components = URLComponents()
            components.path = "/api/sessions/\(storedID)/messages"
            components.queryItems = [
                URLQueryItem(name: "profile", value: profile),
                URLQueryItem(name: "include_compacted", value: "true"),
                URLQueryItem(name: "order", value: "oldest"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
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

        private func fullTranscript(
            storedID: String,
            profile: String = "default"
        ) async throws -> [[String: Any]] {
            var rows: [[String: Any]] = []
            for offset in stride(from: 0, through: 400, by: 100) {
                let page = try await transcript(
                    storedID: storedID, profile: profile, limit: 100, offset: offset
                )
                rows.append(contentsOf: page)
                if page.count < 100 { break }
            }
            guard rows.count <= 500 else { throw NSError(domain: "DirectSkillUITests", code: 27) }
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
