import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class SessionIdentityTests: XCTestCase {
    func testSessionRowDisplayTitlePreservesLongTitleAndFallsBackForBlankTitle() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let longTitle = "A very long planning title that needs to remain available from the session context menu"
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-long",
              "title": "\(longTitle)"
            }
            """.utf8)
        )
        let untitled = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-blank",
              "title": "   "
            }
            """.utf8)
        )

        XCTAssertEqual(SessionRowView.displayTitle(for: session), longTitle)
        XCTAssertEqual(SessionRowView.displayTitle(for: untitled), "Untitled Session")
    }

    func testSessionRowActiveStreamingUsesStreamingFlagOrActiveStreamID() {
        XCTAssertTrue(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "streaming", isStreaming: true)))
        XCTAssertTrue(
            SessionRowView.isActiveStreaming(
                SessionSummary(sessionId: "stream-id", activeStreamId: "stream-123", isStreaming: false)
            )
        )
    }

    func testSessionRowActiveStreamingIsFalseWhenNoActiveSignalExists() {
        XCTAssertFalse(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "idle")))
        XCTAssertFalse(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "finished", isStreaming: false)))
        XCTAssertFalse(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "empty-stream", activeStreamId: "")))
        XCTAssertFalse(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "blank-stream", activeStreamId: "   ")))
    }

    func testSessionRowActiveStreamingUsesLiveOwnerWhenListPayloadIsStale() {
        XCTAssertTrue(
            SessionRowView.isActiveStreaming(
                SessionSummary(sessionId: "owned-live", isStreaming: false),
                liveOwnerSessionIDs: ["owned-live"]
            )
        )
        XCTAssertFalse(
            SessionRowView.isActiveStreaming(
                SessionSummary(sessionId: "idle", isStreaming: false),
                liveOwnerSessionIDs: ["owned-live"]
            )
        )
    }

    func testSessionRowMetadataLabelUsesVisiblePartsAndWorkspaceBasename() {
        let session = SessionSummary(
            sessionId: "metadata",
            workspace: "/Users/example/hermes-mobile",
            messageCount: 2
        )

        XCTAssertEqual(
            SessionRowView.metadataLabel(for: session, showsMessageCount: true, showsWorkspace: true),
            "2 messages • hermes-mobile"
        )
        XCTAssertEqual(
            SessionRowView.metadataLabel(for: session, showsMessageCount: true, showsWorkspace: false),
            "2 messages"
        )
        XCTAssertEqual(
            SessionRowView.metadataLabel(for: session, showsMessageCount: false, showsWorkspace: true),
            "hermes-mobile"
        )
    }

    func testSessionRowMetadataLabelOmitsHiddenOrUnavailableParts() {
        let session = SessionSummary(
            sessionId: "metadata-empty",
            workspace: "   ",
            messageCount: -1
        )

        XCTAssertNil(SessionRowView.metadataLabel(for: session, showsMessageCount: true, showsWorkspace: true))
        XCTAssertNil(SessionRowView.metadataLabel(for: session, showsMessageCount: false, showsWorkspace: false))
    }

    func testSessionRowAccessibilityStateLabelsIncludeStreamingPinnedAndCachedState() {
        let session = SessionSummary(
            sessionId: "stateful",
            pinned: true,
            activeStreamId: "stream-123",
            isStreaming: false
        )

        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: session, isViewingCachedData: true),
            ["Streaming", "Pinned", "Cached"]
        )
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: SessionSummary(sessionId: "plain"), isViewingCachedData: false),
            []
        )
    }

    func testSessionSummaryFallbackIDIsDeterministicWithoutSessionID() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "title": "Older Session",
              "created_at": 1770000000
            }
            """.utf8)
        )

        XCTAssertEqual(session.id, "session-Older Session-1770000000.0")
        XCTAssertEqual(session.id, "session-Older Session-1770000000.0")
    }

    func testSessionDetailFallbackIDIsDeterministicWithoutSessionID() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let session = try decoder.decode(
            SessionDetail.self,
            from: Data("""
            {
              "title": "Legacy Session",
              "updated_at": 1770000100
            }
            """.utf8)
        )

        XCTAssertEqual(session.id, "session-Legacy Session-1770000100.0")
        XCTAssertEqual(session.id, "session-Legacy Session-1770000100.0")
    }
}

final class SessionSidebarDisclosureSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionSidebarDisclosureSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDisclosureStatesDefaultToCollapsedWhenUnset() {
        XCTAssertNil(defaults.object(forKey: SessionSidebarDisclosureSettings.profilesAreExpandedKey))
        XCTAssertNil(defaults.object(forKey: SessionSidebarDisclosureSettings.projectsAreExpandedKey))
        XCTAssertNil(defaults.object(forKey: SessionSidebarDisclosureSettings.scheduledSessionsAreExpandedKey))
        XCTAssertFalse(SessionSidebarDisclosureSettings.profilesAreExpanded(in: defaults))
        XCTAssertFalse(SessionSidebarDisclosureSettings.projectsAreExpanded(in: defaults))
        XCTAssertFalse(SessionSidebarDisclosureSettings.scheduledSessionsAreExpanded(in: defaults))
    }

    func testDisclosureStatesRoundTripThroughUserDefaults() {
        defaults.set(true, forKey: SessionSidebarDisclosureSettings.profilesAreExpandedKey)
        defaults.set(false, forKey: SessionSidebarDisclosureSettings.projectsAreExpandedKey)
        defaults.set(true, forKey: SessionSidebarDisclosureSettings.scheduledSessionsAreExpandedKey)

        XCTAssertTrue(SessionSidebarDisclosureSettings.profilesAreExpanded(in: defaults))
        XCTAssertFalse(SessionSidebarDisclosureSettings.projectsAreExpanded(in: defaults))
        XCTAssertTrue(SessionSidebarDisclosureSettings.scheduledSessionsAreExpanded(in: defaults))

        defaults.set(false, forKey: SessionSidebarDisclosureSettings.profilesAreExpandedKey)
        defaults.set(true, forKey: SessionSidebarDisclosureSettings.projectsAreExpandedKey)
        defaults.set(false, forKey: SessionSidebarDisclosureSettings.scheduledSessionsAreExpandedKey)

        XCTAssertFalse(SessionSidebarDisclosureSettings.profilesAreExpanded(in: defaults))
        XCTAssertTrue(SessionSidebarDisclosureSettings.projectsAreExpanded(in: defaults))
        XCTAssertFalse(SessionSidebarDisclosureSettings.scheduledSessionsAreExpanded(in: defaults))
    }
}

final class SessionRowDisplaySettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionRowDisplaySettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSubagentSessionsDefaultHiddenAndPersistStoredChoice() {
        XCTAssertFalse(SessionRowDisplaySettings.showsSubagentSessions(in: defaults))

        defaults.set(true, forKey: SessionRowDisplaySettings.showSubagentSessionsKey)
        XCTAssertTrue(SessionRowDisplaySettings.showsSubagentSessions(in: defaults))

        defaults.set(false, forKey: SessionRowDisplaySettings.showSubagentSessionsKey)
        XCTAssertFalse(SessionRowDisplaySettings.showsSubagentSessions(in: defaults))
    }
}

/// The avatar long-press server switcher's menu contents (#283). The switch
/// action itself is #17's `AuthManager.switchActiveServer`, covered by
/// `AuthManagerStateTests`; these cover the pure model that decides what the
/// menu shows and which server is marked active.
final class AvatarServerSwitcherModelTests: XCTestCase {
    private func makeAccount(id: String, displayName: String = "") -> ServerAccount {
        ServerAccount(
            id: id,
            urlString: id,
            displayName: displayName,
            initials: "",
            headerLogoColorHex: HeaderLogoColor.defaultHex,
            customHeadersRef: id,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testMarksTheActiveServerAmongMultipleAndPreservesOrder() {
        let model = AvatarServerSwitcherModel(
            servers: [
                makeAccount(id: "https://a.test", displayName: "Alpha"),
                makeAccount(id: "https://b.test", displayName: "Bravo")
            ],
            activeServerID: "https://b.test"
        )

        XCTAssertEqual(model.entries.map(\.id), ["https://a.test", "https://b.test"])
        XCTAssertEqual(model.entries.map(\.displayName), ["Alpha", "Bravo"])
        XCTAssertEqual(model.entries.map(\.isActive), [false, true])
        XCTAssertEqual(model.activeID, "https://b.test")
    }

    func testSingleServerIsMarkedActive() {
        // A single-server install still gets its one server marked active, so the
        // constant "Add Server…"/"Manage Servers" actions are reachable from the
        // same menu (#283 discoverability AC).
        let model = AvatarServerSwitcherModel(
            servers: [makeAccount(id: "https://only.test", displayName: "Only")],
            activeServerID: "https://only.test"
        )

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertTrue(model.entries[0].isActive)
        XCTAssertEqual(model.activeID, "https://only.test")
    }

    func testFallsBackToHostWhenDisplayNameIsEmpty() {
        let model = AvatarServerSwitcherModel(
            servers: [
                makeAccount(id: "https://hermes.example.com:8080", displayName: ""),
                makeAccount(id: "https://named.test", displayName: "Named")
            ],
            activeServerID: "https://hermes.example.com:8080"
        )

        XCTAssertEqual(model.entries[0].displayName, "hermes.example.com")
        XCTAssertEqual(model.entries[1].displayName, "Named")
    }

    func testNoEntryIsActiveWhenActiveIDMatchesNoServer() {
        let model = AvatarServerSwitcherModel(
            servers: [makeAccount(id: "https://a.test", displayName: "Alpha")],
            activeServerID: nil
        )

        XCTAssertFalse(model.entries.contains { $0.isActive })
        XCTAssertNil(model.activeID)
    }

    func testEntryCarriesItsAccountForTheSwitchAction() {
        let bravo = makeAccount(id: "https://b.test", displayName: "Bravo")
        let model = AvatarServerSwitcherModel(
            servers: [makeAccount(id: "https://a.test", displayName: "Alpha"), bravo],
            activeServerID: "https://a.test"
        )

        XCTAssertEqual(model.entries[1].account, bravo)
    }
}

final class SectionVisibilitySettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let allKeys = [
        SectionVisibilitySettings.tasksKey,
        SectionVisibilitySettings.kanbanKey,
        SectionVisibilitySettings.skillsKey,
        SectionVisibilitySettings.memoryKey,
        SectionVisibilitySettings.insightsKey,
        SectionVisibilitySettings.activeProfileKey,
        SectionVisibilitySettings.projectsKey,
        SectionVisibilitySettings.chatFilesKey,
        SectionVisibilitySettings.chatGitKey
    ]

    override func setUp() {
        super.setUp()
        suiteName = "SectionVisibilitySettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEverySectionDefaultsToVisibleWhenUnset() {
        for key in allKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should start unset")
            XCTAssertTrue(SectionVisibilitySettings.isVisible(key, in: defaults), "\(key) should default to visible")
        }
    }

    func testEachSectionRoundTripsThroughUserDefaults() {
        for key in allKeys {
            defaults.set(false, forKey: key)
            XCTAssertFalse(SectionVisibilitySettings.isVisible(key, in: defaults), "\(key) should read back as hidden")

            defaults.set(true, forKey: key)
            XCTAssertTrue(SectionVisibilitySettings.isVisible(key, in: defaults), "\(key) should read back as visible")
        }
    }

    func testKeysAreDistinctSoOneToggleCannotMoveAnother() {
        XCTAssertEqual(Set(allKeys).count, allKeys.count)
    }

    func testHidingOneSectionLeavesTheOthersVisible() {
        defaults.set(false, forKey: SectionVisibilitySettings.insightsKey)

        XCTAssertFalse(SectionVisibilitySettings.isVisible(SectionVisibilitySettings.insightsKey, in: defaults))
        for key in allKeys where key != SectionVisibilitySettings.insightsKey {
            XCTAssertTrue(SectionVisibilitySettings.isVisible(key, in: defaults), "\(key) should be unaffected")
        }
    }
}

final class SidebarSectionVisibilityTests: XCTestCase {
    func testShowAllShowsEverySection() {
        let visibility = SidebarSectionVisibility.showAll

        XCTAssertTrue(visibility.tasks)
        XCTAssertTrue(visibility.kanban)
        XCTAssertTrue(visibility.skills)
        XCTAssertTrue(visibility.memory)
        XCTAssertTrue(visibility.insights)
        XCTAssertTrue(visibility.activeProfile)
        XCTAssertTrue(visibility.projects)
        XCTAssertTrue(visibility.showsAnyUtilityLink)
    }

    func testUtilityLinkRowSurvivesWhileAnySingleLinkIsShown() {
        var visibility = SidebarSectionVisibility.showAll
        visibility.tasks = false
        visibility.kanban = false
        visibility.skills = false
        visibility.memory = false

        XCTAssertTrue(visibility.showsAnyUtilityLink)
    }

    func testUtilityLinkRowDropsOnlyWhenAllFiveAreHidden() {
        var visibility = SidebarSectionVisibility.showAll
        visibility.tasks = false
        visibility.kanban = false
        visibility.skills = false
        visibility.memory = false
        visibility.insights = false

        XCTAssertFalse(visibility.showsAnyUtilityLink)
    }

    func testProfileAndProjectRowsDoNotAffectTheUtilityLinkRow() {
        var visibility = SidebarSectionVisibility.showAll
        visibility.activeProfile = false
        visibility.projects = false

        XCTAssertTrue(visibility.showsAnyUtilityLink)
    }
}

final class MessagesSessionRowFormatterTests: XCTestCase {
    func testRowStateDistinguishesStreamingPendingAndIdle() {
        let streamingSession = SessionSummary(sessionId: "stream-1", isStreaming: true)
        let activeStreamSession = SessionSummary(sessionId: "stream-2", activeStreamId: "stream-abc")
        let pendingMessageSession = SessionSummary(sessionId: "pending-1", hasPendingUserMessage: true)
        let idleSession = SessionSummary(sessionId: "idle-1", messageCount: 5, isStreaming: false)

        XCTAssertEqual(MessagesSessionRowFormatter.rowState(for: streamingSession), .live)
        XCTAssertEqual(MessagesSessionRowFormatter.rowState(for: activeStreamSession), .live)
        XCTAssertEqual(MessagesSessionRowFormatter.rowState(for: pendingMessageSession), .live)
        XCTAssertEqual(MessagesSessionRowFormatter.rowState(for: idleSession), .idle)
    }

    func testRowStateUsesLiveOwnerSessionIDs() {
        let session = SessionSummary(sessionId: "live-owner-1", isStreaming: false)
        XCTAssertEqual(
            MessagesSessionRowFormatter.rowState(for: session, liveOwnerSessionIDs: ["live-owner-1"]),
            .live
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.rowState(for: session, liveOwnerSessionIDs: ["other-session"]),
            .idle
        )
    }

    func testRowStateBoundedFallbackLeavesUnreadAsIdleWithoutSyntheticServerFields() {
        // Upstream Hermes server and SessionSummary model do not track per-session unread
        // status or timestamps. An idle session safely returns .idle without synthetic unread state.
        let session = SessionSummary(sessionId: "normal-session", messageCount: 10)
        XCTAssertEqual(MessagesSessionRowFormatter.rowState(for: session), .idle)
    }

    func testPreviewTextPrioritizesLiveStreaming() {
        let streamingSession = SessionSummary(
            sessionId: "s1",
            workspace: "/Users/maurice/workspace/goku-ios",
            model: "claude-3-5-sonnet",
            messageCount: 12,
            isStreaming: true
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: streamingSession),
            "Streaming response…"
        )
    }

    func testPreviewTextPrioritizesPendingUserMessage() {
        let pendingSession = SessionSummary(
            sessionId: "s2",
            workspace: "/Users/maurice/workspace/goku-ios",
            model: "gpt-4o",
            messageCount: 3,
            hasPendingUserMessage: true
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: pendingSession),
            "Waiting for your message…"
        )
    }

    func testPreviewTextPrioritizesCronSubagentAndCliSessions() {
        let cronSession = SessionSummary(
            sessionId: "cron_daily_review",
            workspace: "/Users/maurice/workspace/goku-ios"
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: cronSession),
            "No message preview yet"
        )

        let cronWithoutWorkspace = SessionSummary(sessionId: "cron_plain")
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: cronWithoutWorkspace),
            "No message preview yet"
        )

        let subagentSession = SessionSummary(
            sessionId: "subagent-1",
            workspace: "/Users/maurice/workspace/goku-ios",
            sourceTag: "subagent"
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: subagentSession),
            "No message preview yet"
        )

        let cliSession = SessionSummary(
            sessionId: "cli-1",
            workspace: "/Users/maurice/workspace/goku-ios",
            isCliSession: true
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: cliSession),
            "No message preview yet"
        )
    }

    func testPreviewTextPrioritizesActiveModelOverGenericMessageCount() {
        let modelWithWorkspace = SessionSummary(
            sessionId: "m1",
            workspace: "/Users/maurice/workspace/goku-ios",
            model: "claude-3-5-sonnet",
            messageCount: 8
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: modelWithWorkspace),
            "No message preview yet"
        )

        let modelWithProfile = SessionSummary(
            sessionId: "m2",
            model: "gpt-4o",
            profile: "Chabby"
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: modelWithProfile),
            "No message preview yet"
        )

        let modelOnly = SessionSummary(
            sessionId: "m3",
            model: "gemini-2.0-flash"
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: modelOnly),
            "No message preview yet"
        )
    }

    func testPreviewTextPrefersProvidedLatestMessageOverMetadata() {
        let session = SessionSummary(
            sessionId: "latest-message",
            workspace: "/Users/example/hermes-mobile",
            model: "fixture-model",
            messageCount: 4
        )

        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(
                for: session,
                latestMessagePreview: "  The latest reply\n\nuses two lines.  "
            ),
            "The latest reply uses two lines."
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(
                for: session,
                latestMessagePreview: "The latest reply",
                liveOwnerSessionIDs: ["latest-message"],
                isUnread: true
            ),
            "The latest reply"
        )
    }

    func testPreviewTextBoundsLongLatestMessageAndKeepsMetadataFallback() {
        let longMessage = String(repeating: "x", count: 300)
        let bounded = MessagesSessionRowFormatter.normalizedLatestMessagePreview(longMessage)
        XCTAssertEqual(bounded?.count, 240)
        XCTAssertTrue(bounded?.hasSuffix("…") == true)

        let session = SessionSummary(
            sessionId: "no-latest-cache",
            workspace: "/Users/example/hermes-mobile",
            model: "fixture-model"
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: session),
            "No message preview yet"
        )
    }

    func testMessagesSessionDateFormattingUsesLocalClockYesterdayAndCompactOlderDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US_POSIX")

        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try date(2026, 9, 14, 16, 8)
        let localizedClock = MessagesSessionDateFormatter.localizedString(
            for: try date(2026, 9, 14, 9, 7),
            relativeTo: now,
            calendar: calendar,
            locale: locale
        )
        XCTAssertEqual(localizedClock.split(whereSeparator: \.isWhitespace).joined(separator: " "), "9:07 AM")
        XCTAssertEqual(
            MessagesSessionDateFormatter.localizedString(
                for: try date(2026, 9, 13, 22, 0),
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ),
            "Yesterday"
        )
        XCTAssertEqual(
            MessagesSessionDateFormatter.localizedString(
                for: try date(2026, 9, 12, 15, 0),
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ),
            "Sep 12"
        )
        XCTAssertEqual(
            MessagesSessionDateFormatter.localizedString(
                for: try date(2025, 9, 12, 15, 0),
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ),
            "Sep 12, 2025"
        )
    }

    func testPreviewTextSecondaryMetadataFallback() {
        let singleMessage = SessionSummary(
            sessionId: "f1",
            workspace: "/Users/maurice/workspace/goku-ios",
            messageCount: 1
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: singleMessage),
            "No message preview yet"
        )

        let multipleMessagesWithProfile = SessionSummary(
            sessionId: "f2",
            workspace: "/Users/maurice/workspace/goku-ios",
            messageCount: 5,
            profile: "Chabby"
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: multipleMessagesWithProfile),
            "No message preview yet"
        )

        let emptySession = SessionSummary(sessionId: "f3")
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: emptySession, isViewingCachedData: false),
            "No message preview yet"
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: emptySession, isViewingCachedData: true),
            "No message preview yet"
        )
    }

    func testNormalizedWorkspaceAndProfile() {
        XCTAssertEqual(
            MessagesSessionRowFormatter.normalizedWorkspace("/Users/maurice/workspace/goku-ios"),
            "goku-ios"
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.normalizedWorkspace("   simple-name   "),
            "simple-name"
        )
        XCTAssertNil(MessagesSessionRowFormatter.normalizedWorkspace("   "))
        XCTAssertNil(MessagesSessionRowFormatter.normalizedWorkspace(nil))

        XCTAssertEqual(
            MessagesSessionRowFormatter.normalizedProfile("  Work Profile  "),
            "Work Profile"
        )
        XCTAssertNil(MessagesSessionRowFormatter.normalizedProfile("   "))
        XCTAssertNil(MessagesSessionRowFormatter.normalizedProfile(nil))
    }
}

final class SessionReadStateStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let server = URL(string: "https://hermes.example.test")!

    override func setUp() {
        super.setUp()
        suiteName = "SessionReadStateStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstObservationSeedsExistingAgentHistoryAsRead() {
        let store = SessionReadStateStore(defaults: defaults)
        let session = SessionSummary(
            sessionId: "session-1",
            messageCount: 2,
            lastMessageAt: 100,
            userMessageCount: 1
        )

        XCTAssertTrue(SessionReadStateStore.hasAgentReplySignal(session))
        XCTAssertFalse(store.isUnread(for: session, server: server))
    }

    func testLaterAgentActivityBecomesUnreadAndOpeningClearsIt() {
        let store = SessionReadStateStore(defaults: defaults)
        let initial = SessionSummary(
            sessionId: "session-2",
            messageCount: 2,
            lastMessageAt: 100,
            userMessageCount: 1
        )
        let updated = SessionSummary(
            sessionId: "session-2",
            messageCount: 4,
            lastMessageAt: 200,
            userMessageCount: 2
        )

        XCTAssertFalse(store.isUnread(for: initial, server: server))
        XCTAssertTrue(store.isUnread(for: updated, server: server))

        store.markRead(updated, server: server)

        XCTAssertFalse(store.isUnread(for: updated, server: server))
    }

    func testReadMarkersAreIsolatedPerServer() {
        let store = SessionReadStateStore(defaults: defaults)
        let initial = SessionSummary(
            sessionId: "shared-id",
            messageCount: 2,
            lastMessageAt: 100,
            userMessageCount: 1
        )
        let updated = SessionSummary(
            sessionId: "shared-id",
            messageCount: 3,
            lastMessageAt: 200,
            userMessageCount: 1
        )
        let otherServer = URL(string: "https://other-hermes.example.test")!

        XCTAssertFalse(store.isUnread(for: initial, server: server))
        XCTAssertTrue(store.isUnread(for: updated, server: server))
        XCTAssertFalse(store.isUnread(for: updated, server: otherServer))
    }

    func testRowsDoNotClaimUnreadWithoutAgentReplyEvidence() {
        let store = SessionReadStateStore(defaults: defaults)
        let userOnly = SessionSummary(
            sessionId: "user-only",
            messageCount: 1,
            lastMessageAt: 300,
            userMessageCount: 1
        )

        XCTAssertFalse(SessionReadStateStore.hasAgentReplySignal(userOnly))
        XCTAssertFalse(store.isUnread(for: userOnly, server: server))
    }

    func testLiveStateWinsOverUnreadState() {
        let liveSession = SessionSummary(
            sessionId: "live-and-unread",
            messageCount: 4,
            isStreaming: true,
            userMessageCount: 2
        )
        let unreadSession = SessionSummary(
            sessionId: "unread",
            messageCount: 2,
            userMessageCount: 1
        )

        XCTAssertEqual(
            MessagesSessionRowFormatter.rowState(for: liveSession, isUnread: true),
            .live
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.rowState(for: unreadSession, isUnread: true),
            .unread
        )
        XCTAssertEqual(
            MessagesSessionRowFormatter.previewText(for: unreadSession, isUnread: true),
            "New agent reply"
        )
    }
}
