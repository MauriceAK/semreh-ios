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
