import XCTest
@testable import HermesMobile

@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: ComposerDraftStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ComposerDraftStoreTests.\(UUID().uuidString)")
        store = ComposerDraftStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.contains("suite") ? "" : "")
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testLeaveAndReopenRestoresTypedDraft() {
        store.save("half-written thought", server: server, sessionID: "session-a")

        XCTAssertEqual(
            store.load(server: server, sessionID: "session-a"),
            "half-written thought"
        )
    }

    func testDraftsAreIsolatedPerSession() {
        store.save("for A", server: server, sessionID: "session-a")
        store.save("for B", server: server, sessionID: "session-b")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "for A")
        XCTAssertEqual(store.load(server: server, sessionID: "session-b"), "for B")
    }

    func testDraftSurvivesANewStoreInstanceLikeAnAppRestart() {
        store.save("still here after relaunch", server: server, sessionID: "session-a")

        let relaunched = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a"),
            "still here after relaunch"
        )
    }

    func testClearingOrSendingRemovesTheDraft() {
        store.save("do not keep after send", server: server, sessionID: "session-a")
        store.clear(server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "")
    }

    func testPreAwaitClearRemovesSubmittedDraftWithoutTouchingAnotherSession() {
        // Store-level coverage for the write sequence used before a gated
        // send. This does not prove production call order or process-death
        // durability.
        store.save("A", server: server, sessionID: "session-a")
        store.save("B", server: server, sessionID: "session-b")

        store.save("", server: server, sessionID: "session-a")

        let freshStore = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(freshStore.load(server: server, sessionID: "session-a"), "")
        XCTAssertEqual(freshStore.load(server: server, sessionID: "session-b"), "B")
    }

    func testDefiniteFailureCanRestoreDraftAfterPreAwaitClear() {
        store.save("A", server: server, sessionID: "session-a")

        // Model the direct-send sequence: clear before the await, then
        // restore the submitted draft when the operation definitely fails.
        store.save("", server: server, sessionID: "session-a")
        store.save("A", server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "A")
    }

    func testEmptyOrWhitespaceOnlyDraftIsNotRestored() {
        store.save("   \n\t  ", server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "")
    }

    func testShareSheetDraftWinsOverAnEmptyStoredDraft() {
        XCTAssertEqual(
            ComposerDraftStore.resolvedDraft(initialDraft: "from share", storedDraft: ""),
            "from share"
        )
    }

    func testStoredDraftWinsWhenTheComposerWouldOtherwiseBeEmpty() {
        XCTAssertEqual(
            ComposerDraftStore.resolvedDraft(initialDraft: "", storedDraft: "cached"),
            "cached"
        )
    }
}

@MainActor
final class TranscriptRestoreStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: TranscriptRestoreStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TranscriptRestoreStoreTests.\(UUID().uuidString)")
        store = TranscriptRestoreStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testLeaveWhileReadingOlderSurvivesAppRestart() {
        store.save(
            TranscriptRestorePoint(followingLatest: false, visibleMessageID: "msg-where-i-left"),
            server: server,
            sessionID: "session-a"
        )

        let relaunched = TranscriptRestoreStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a"),
            TranscriptRestorePoint(followingLatest: false, visibleMessageID: "msg-where-i-left")
        )
    }

    func testFollowingLatestDoesNotKeepAStaleMessageID() {
        store.save(
            TranscriptRestorePoint(followingLatest: true, visibleMessageID: "msg-mid"),
            server: server,
            sessionID: "session-a"
        )

        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: store.load(server: server, sessionID: "session-a").followingLatest,
                lastVisibleMessageID: store.load(server: server, sessionID: "session-a").visibleMessageID
            ),
            .latest
        )
    }
}

#if DEBUG
@MainActor
final class ChatP09DiagnosticRestoreBootstrapTests: XCTestCase {
    func testCalibrationOneShotRejectsDuplicateAndWrongScopeRelease() {
        var state = ChatP09CalibrationState()
        let scope = UUID()
        XCTAssertFalse(state.finish(scope: scope, released: true))
        XCTAssertTrue(state.begin(scope: scope))
        XCTAssertFalse(state.begin(scope: scope))
        XCTAssertFalse(state.finish(scope: UUID(), released: true))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.finish(scope: scope, released: true))
        XCTAssertEqual(state.phase, .released)
        XCTAssertFalse(state.finish(scope: scope, released: true))
        XCTAssertFalse(state.begin(scope: scope))
    }

    func testCalibrationTimeoutAndCancellationAbortRatherThanRelease() {
        for _ in ["timeout", "scope_or_user_cancellation"] {
            var state = ChatP09CalibrationState()
            let scope = UUID()
            XCTAssertTrue(state.begin(scope: scope))
            XCTAssertTrue(state.finish(scope: scope, released: false))
            XCTAssertEqual(state.phase, .aborted)
            XCTAssertFalse(state.finish(scope: scope, released: true))
            XCTAssertFalse(state.begin(scope: scope))
        }
    }

    func testCalibrationNonceRequiresExactSeedFixture() {
        let nonce = UUID().uuidString
        let key = "SEMREH_P09_CALIBRATION_NONCE"
        let arguments = ["--chat-p09-seed-restore",
                         "--chat-p09-restore-server=https://semreh-slice1-test.tailda8427.ts.net",
                         "--chat-p09-restore-session=p09-test", "--chat-p09-restore-message=123"]
        XCTAssertEqual(ChatP09CalibrationState.nonce(arguments: arguments, environment: [key: nonce]), nonce)
        let server = URL(string: "https://semreh-slice1-test.tailda8427.ts.net")!
        XCTAssertTrue(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: server, sessionID: "p09-test"))
        XCTAssertFalse(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: server, sessionID: "other-session"))
        XCTAssertFalse(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: URL(string: "https://outside.example")!, sessionID: "p09-test"))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: [], environment: [key: nonce]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments, environment: [:]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments, environment: [key: "malformed"]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments.map { $0.replacingOccurrences(of: "semreh-slice1-test.tailda8427.ts.net", with: "outside.example") }, environment: [key: nonce]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments.map { $0.replacingOccurrences(of: "--chat-p09-seed-restore", with: "--chat-p09-cleanup-restore") }, environment: [key: nonce]))
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let server = URL(string: "https://semreh-slice1-test.tailda8427.ts.net")!
    private let sessionID = "p09-session-123"
    private let oldMessageID = "old-message-456"
    private let seededMessageID = "seed-message-789"

    override func setUp() {
        super.setUp()
        suiteName = "ChatP09DiagnosticRestoreBootstrapTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSeedRequestRequiresApprovedOriginAndCompleteCanonicalScope() {
        let valid = seedArguments()
        let request = ChatP09DiagnosticRestoreRequest.parse(arguments: valid)
        XCTAssertEqual(request?.operation, .seed)
        XCTAssertEqual(request?.server, server)
        XCTAssertEqual(request?.sessionID, sessionID)
        XCTAssertEqual(request?.visibleMessageID, seededMessageID)

        let invalidRequests: [[String]] = [
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)https://other.example",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)bad/session",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)bad/message"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(String(repeating: "x", count: 129))"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             ChatP09DiagnosticRestoreRequest.cleanupArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
        ]

        for arguments in invalidRequests {
            XCTAssertNil(
                ChatP09DiagnosticRestoreRequest.parse(arguments: arguments),
                "out-of-scope P09 arguments must fail closed: \(arguments)"
            )
        }
    }

    func testSeedAndCleanupRestoreOnlyTheExactPriorReaderPoint() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let unrelatedKey = "unrelated-setting"
        defaults.set("preserve-me", forKey: unrelatedKey)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        XCTAssertEqual(
            store.load(server: server, sessionID: sessionID),
            TranscriptRestorePoint(
                followingLatest: false,
                visibleMessageID: "transcript:row:\(seededMessageID)"
            )
        )
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "preserve-me")
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected,
            "a second seed must not overwrite the saved backup"
        )

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .restored
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "preserve-me")
    }

    func testDirectTranscriptRenderIdentityUsesTheProductionNamespace() {
        XCTAssertEqual(
            TranscriptRenderIdentity.directID(for: seededMessageID),
            "transcript:row:\(seededMessageID)"
        )
        XCTAssertNil(TranscriptRenderIdentity.directID(for: nil))
        XCTAssertNil(TranscriptRenderIdentity.directID(for: ""))
    }

    func testCleanupWithoutMatchingSeedDoesNotWipeTheRestorePoint() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .rejected
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
    }

    func testSeedWithoutPriorPointCleansBackToLatestWithoutLeavingBackup() {
        let store = TranscriptRestoreStore(defaults: defaults)
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), .followingLatest)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .restored
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), .followingLatest)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().keys.contains {
                $0.contains("chatP09.restore-backup")
            }
        )
    }

    func testNonDataBackupRejectsSeedWithoutReplacingIt() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)
        defaults.set("not-a-data-backup", forKey: backupKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
        XCTAssertEqual(defaults.string(forKey: backupKey), "not-a-data-backup")
    }

    func testNonDataPriorRestoreRejectsSeedWithoutReplacingIt() {
        defaults.set("not-a-data-restore", forKey: restoreKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected
        )
        XCTAssertEqual(defaults.string(forKey: restoreKey), "not-a-data-restore")
        XCTAssertNil(defaults.object(forKey: backupKey))
    }

    func testNonDataCleanupTargetRejectsWithoutOverwritingCurrentValue() {
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        defaults.set("later-corrupt-value", forKey: restoreKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .rejected
        )
        XCTAssertEqual(defaults.string(forKey: restoreKey), "later-corrupt-value")
        XCTAssertNotNil(defaults.object(forKey: backupKey))
    }

    private func seedArguments() -> [String] {
        [
            ChatP09DiagnosticRestoreRequest.seedArgument,
            "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
            "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
            "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)",
        ]
    }

    private func cleanupArguments() -> [String] {
        [
            ChatP09DiagnosticRestoreRequest.cleanupArgument,
            "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
            "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
        ]
    }

    private var restoreKey: String {
        "\(TranscriptRestoreStore.visibilityKeyPrefix)\(server.absoluteString)|\(sessionID)"
    }

    private var backupKey: String {
        "semreh.debug.chatP09.restore-backup.\(server.absoluteString)|\(sessionID)"
    }
}
#endif

@MainActor
final class LiveRunBookmarkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: LiveRunBookmarkStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LiveRunBookmarkStoreTests.\(UUID().uuidString)")
        store = LiveRunBookmarkStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testBookmarkSurvivesProcessDeath() {
        store.save(
            LiveRunBookmark(
                streamID: "stream-live",
                lastEventID: "42",
                liveReasoningText: "checking the lock",
                streamingAssistantMessageID: "msg-assistant",
                liveToolCalls: [
                    ToolCall(
                        id: "tool-1",
                        name: "read_file",
                        preview: "README.md",
                        args: nil,
                        isCompleted: false
                    )
                ]
            ),
            server: server,
            sessionID: "session-a"
        )

        let relaunched = LiveRunBookmarkStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.streamID,
            "stream-live"
        )
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.liveReasoningText,
            "checking the lock"
        )
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.liveToolCalls.first?.name,
            "read_file"
        )
    }

    func testFinishedRunClearsTheBookmark() {
        store.save(
            LiveRunBookmark(
                streamID: "stream-live",
                lastEventID: nil,
                liveReasoningText: "done",
                streamingAssistantMessageID: nil
            ),
            server: server,
            sessionID: "session-a"
        )
        store.remove(server: server, sessionID: "session-a")
        XCTAssertNil(store.load(server: server, sessionID: "session-a"))
    }
}
