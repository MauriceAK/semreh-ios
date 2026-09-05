import XCTest
import Observation
@testable import HermesMobile

@MainActor
final class OpenChatSessionStoreTests: XCTestCase {
    func testExistingGitModelLookupDoesNotInvalidateItsObservingView() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let session = SessionSummary(sessionId: "observed-existing-chat")
        let store = OpenChatSessionStore()
        let model = store.viewModel(session: session, server: server)
        let gitModel = store.gitAvailabilityViewModel(session: session, server: server, chatViewModel: model)
        let invalidation = XCTestExpectation(description: "LRU touch must not invalidate the view doing the lookup")
        invalidation.isInverted = true

        withObservationTracking {
            _ = store.gitAvailabilityViewModel(session: session, server: server, chatViewModel: model)
        } onChange: {
            invalidation.fulfill()
        }
        for _ in 0..<3 {
            XCTAssertTrue(store.gitAvailabilityViewModel(session: session, server: server, chatViewModel: model) === gitModel)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [invalidation], timeout: 0.01), .completed)
    }

    override func tearDown() {
        OpenChatSessionStore.shared.resetForTesting()
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testRepeatedOpenBackKeepsIdleRetentionBoundedPerServer() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore.shared

        for index in 0..<100 {
            _ = store.viewModel(
                session: SessionSummary(sessionId: "session-\(index)"),
                server: server
            )
        }

        let retainedSessionIDs = store.retainedSessionIDsForTesting(for: server)
        XCTAssertLessThanOrEqual(
            retainedSessionIDs.count,
            8,
            "The production retention cap should keep repeated open/back idle retention bounded."
        )
        XCTAssertEqual(retainedSessionIDs, (92..<100).map { "session-\($0)" })
    }

    @MainActor
    func testIdleRetentionEvictsLeastRecentlyUsedModelAfterReuse() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 2)
        )
        let first = store.viewModel(session: SessionSummary(sessionId: "session-first"), server: server)
        _ = store.viewModel(session: SessionSummary(sessionId: "session-second"), server: server)
        let reusedFirst = store.viewModel(session: SessionSummary(sessionId: "session-first"), server: server)
        _ = store.viewModel(session: SessionSummary(sessionId: "session-third"), server: server)

        XCTAssertTrue(reusedFirst === first)
        XCTAssertEqual(
            store.retainedSessionIDsForTesting(for: server),
            ["session-first", "session-third"]
        )
        XCTAssertFalse(store.retainedSessionIDsForTesting(for: server).contains("session-second"))
    }

    @MainActor
    func testActiveModelsArePreservedWhileIdleModelsAreEvicted() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 2)
        )
        let active = try makeViewModel(sessionID: "session-active", activeStreamID: "stream-active")
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "session-active"),
            server: server,
            creating: active
        )
        _ = store.viewModel(session: SessionSummary(sessionId: "session-idle-1"), server: server)
        _ = store.viewModel(session: SessionSummary(sessionId: "session-idle-2"), server: server)
        _ = store.viewModel(session: SessionSummary(sessionId: "session-idle-3"), server: server)
        _ = store.viewModel(session: SessionSummary(sessionId: "session-idle-4"), server: server)

        XCTAssertTrue(store.viewModel(session: SessionSummary(sessionId: "session-active"), server: server) === active)
        XCTAssertEqual(
            Set(store.retainedSessionIDsForTesting(for: server)),
            ["session-active", "session-idle-3", "session-idle-4"]
        )
        XCTAssertEqual(store.liveSessionIDs(for: server), ["session-active"])
        XCTAssertEqual(store.liveStreamIDs(for: server), ["stream-active"])
    }

    @MainActor
    func testActiveToIdleNotificationTrimsPreviouslyProtectedModel() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 1)
        )
        let active = try makeViewModel(sessionID: "session-active", activeStreamID: "stream-active") { request in
            apiTestJSONResponse("{\"ok\": true}", for: request)
        }
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "session-active"),
            server: server,
            creating: active
        )
        _ = store.viewModel(session: SessionSummary(sessionId: "session-idle-1"), server: server)
        _ = store.viewModel(session: SessionSummary(sessionId: "session-idle-2"), server: server)
        XCTAssertTrue(store.retainedSessionIDsForTesting(for: server).contains("session-active"))

        // The existing cancellation path clears activeStreamID. The explicit store
        // notification then makes the now-idle model eligible for deterministic LRU trim.
        let didCancel = await active.cancelActiveStream()
        XCTAssertTrue(didCancel)
        store.noteStreamingStateChanged()

        XCTAssertNil(active.activeStreamID)
        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["session-idle-2"])
    }

    @MainActor
    func testRetentionIsIsolatedPerServer() throws {
        let serverA = try XCTUnwrap(URL(string: "https://a.example.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 1)
        )
        let serverBModel = store.viewModel(session: SessionSummary(sessionId: "server-b-session"), server: serverB)
        _ = store.viewModel(session: SessionSummary(sessionId: "server-a-first"), server: serverA)
        _ = store.viewModel(session: SessionSummary(sessionId: "server-a-second"), server: serverA)

        XCTAssertEqual(store.retainedSessionIDsForTesting(for: serverA), ["server-a-second"])
        XCTAssertEqual(store.retainedSessionIDsForTesting(for: serverB), ["server-b-session"])
        XCTAssertTrue(store.viewModel(session: SessionSummary(sessionId: "server-b-session"), server: serverB) === serverBModel)
    }

    @MainActor
    func testEvictionStopsSessionEventSyncBeforeReleasingModel() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 1)
        )
        let eventClient = SpySSEStreamingClient()
        let evicted = try makeViewModel(sessionID: "session-evicted", sessionEventStreamClient: eventClient)
        evicted.startSessionEventSync()
        XCTAssertEqual(eventClient.startedURLs.count, 1)
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "session-evicted"),
            server: server,
            creating: evicted
        )

        _ = store.viewModel(session: SessionSummary(sessionId: "session-new"), server: server)

        XCTAssertEqual(eventClient.stopCount, 1)
        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["session-new"])
    }

    @MainActor
    func testAdoptedModelsRefreshRecencyWhenReadopted() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 2)
        )
        let first = try makeViewModel(sessionID: "adopted-first")
        let second = try makeViewModel(sessionID: "adopted-second")

        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "adopted-first"),
            server: server,
            creating: first
        )
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "adopted-second"),
            server: server,
            creating: second
        )
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "adopted-first"),
            server: server,
            creating: first
        )
        _ = store.viewModel(session: SessionSummary(sessionId: "adopted-third"), server: server)

        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["adopted-first", "adopted-third"])
    }

    @MainActor
    func testAdoptedModelsParticipateInBoundedLRURetention() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 1)
        )
        let first = try makeViewModel(sessionID: "adopted-first")
        let second = try makeViewModel(sessionID: "adopted-second")

        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "adopted-first"),
            server: server,
            creating: first
        )
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "adopted-second"),
            server: server,
            creating: second
        )

        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["adopted-second"])
        XCTAssertTrue(store.viewModel(session: SessionSummary(sessionId: "adopted-second"), server: server) === second)
    }

    @MainActor
    func testResetClearsRetainedModelsOrderingAndLiveState() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 2)
        )
        let eventClient = SpySSEStreamingClient()
        let retained = try makeViewModel(sessionID: "session-reset", sessionEventStreamClient: eventClient)
        retained.startSessionEventSync()
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "session-reset"),
            server: server,
            creating: retained
        )

        store.resetForTesting()

        XCTAssertEqual(eventClient.stopCount, 1)
        XCTAssertEqual(store.retainedViewModelCountForTesting(for: server), 0)
        XCTAssertTrue(store.liveSessionIDs(for: server).isEmpty)
        XCTAssertTrue(store.liveStreamIDs(for: server).isEmpty)
        XCTAssertEqual(store.liveOwnershipGeneration, 0)
        XCTAssertFalse(store.viewModel(session: SessionSummary(sessionId: "session-reset"), server: server) === retained)
    }

    @MainActor
    func testActivatedGatewaySharesDisconnectedRuntimeWithoutConnecting() async throws {
        let server = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let store = OpenChatSessionStore.shared
        store.activateGateway(server: server)

        let first = try await store.runtime(for: server, client: APIClient(baseURL: server))
        let second = try await store.runtime(for: server, client: APIClient(baseURL: server))

        XCTAssertTrue(first === second)
        XCTAssertEqual(first.state, .disconnected)
        await first.stop()
        store.activateGateway(server: nil)
    }

    @MainActor
    func testInactiveAndStaleGatewayOriginsAreRejected() async throws {
        let serverA = try XCTUnwrap(URL(string: "https://gateway-a.example.test"))
        let serverB = try XCTUnwrap(URL(string: "https://gateway-b.example.test"))
        let store = OpenChatSessionStore.shared

        do {
            _ = try await store.runtime(for: serverA, client: APIClient(baseURL: serverA))
            XCTFail("An inactive origin must not create a runtime.")
        } catch let error as DirectSessionError {
            XCTAssertEqual(error, .stopped)
        }

        store.activateGateway(server: serverA)
        let oldRuntime = try await store.runtime(for: serverA, client: APIClient(baseURL: serverA))
        store.activateGateway(server: serverB)

        do {
            _ = try await store.runtime(for: serverA, client: APIClient(baseURL: serverA))
            XCTFail("A stale origin must not reacquire the active runtime.")
        } catch let error as DirectSessionError {
            XCTAssertEqual(error, .stopped)
        }

        let newRuntime = try await store.runtime(for: serverB, client: APIClient(baseURL: serverB))
        XCTAssertEqual(oldRuntime.state, .stopped)
        XCTAssertEqual(newRuntime.state, .disconnected)
        await newRuntime.stop()
        store.activateGateway(server: nil)
    }

    @MainActor
    func testCanonicalRekeyRedirectsAncestorToOneRetainedOwner() async throws {
        let server = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let store = OpenChatSessionStore.shared
        store.activateGateway(server: server)

        let ancestor = SessionSummary(sessionId: nil, title: "draft", createdAt: 1, profile: "alpha")
        let model = store.viewModel(session: ancestor, server: server)
        let ancestorKeyID = ancestor.id
        model.onDirectCanonicalID?("canonical-alpha")

        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["canonical-alpha"])
        let reopened = store.viewModel(session: ancestor, server: server)
        XCTAssertTrue(reopened === model)
        XCTAssertNotEqual(ancestorKeyID, "canonical-alpha")
        XCTAssertEqual(store.retainedViewModelCountForTesting(for: server), 1)

        await model.disposeDirectConversation()
        store.activateGateway(server: nil)
    }

    @MainActor
    func testSameSessionIDInDifferentProfilesHasSeparateOwners() throws {
        let server = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let store = OpenChatSessionStore.shared
        store.activateGateway(server: server)

        let alpha = store.viewModel(
            session: SessionSummary(sessionId: "same-session", profile: "alpha"),
            server: server
        )
        let beta = store.viewModel(
            session: SessionSummary(sessionId: "same-session", profile: "beta"),
            server: server
        )

        XCTAssertFalse(alpha === beta)
        XCTAssertTrue(
            store.viewModel(
                session: SessionSummary(sessionId: "same-session", profile: "alpha"),
                server: server
            ) === alpha
        )
        XCTAssertEqual(store.retainedViewModelCountForTesting(for: server), 2)

        store.activateGateway(server: nil)
    }

    @MainActor
    func testStoreReusesTheSameViewModelForTheSameServerAndSession() throws {
        let first = try makeViewModel(sessionID: "session-abc")
        let reused = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: try XCTUnwrap(URL(string: "https://example.test")),
            creating: first
        )
        let second = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: try XCTUnwrap(URL(string: "https://example.test"))
        )

        XCTAssertTrue(reused === first)
        XCTAssertTrue(second === first)
        XCTAssertTrue(second.wasReusedFromOpenSessionStore)
    }

    @MainActor
    func testStoreReusesGitAvailabilityViewModelAcrossRepeatedRequests() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let session = SessionSummary(sessionId: "session-git")
        let store = OpenChatSessionStore.shared
        let chatViewModel = store.viewModel(session: session, server: server)
        let first = store.gitAvailabilityViewModel(
            session: session,
            server: server,
            chatViewModel: chatViewModel
        )

        for _ in 0..<100 {
            let reused = store.gitAvailabilityViewModel(
                session: session,
                server: server,
                chatViewModel: chatViewModel
            )
            XCTAssertTrue(reused === first)
        }
    }

    @MainActor
    func testGitAvailabilityViewModelsAreIsolatedByServerAndSession() throws {
        let serverA = try XCTUnwrap(URL(string: "https://a.example.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.example.test"))
        let store = OpenChatSessionStore.shared
        let sessionA = SessionSummary(sessionId: "session-a")
        let sessionB = SessionSummary(sessionId: "session-b")
        let chatA = store.viewModel(session: sessionA, server: serverA)
        let chatB = store.viewModel(session: sessionB, server: serverB)

        let auxiliaryA = store.gitAvailabilityViewModel(
            session: sessionA,
            server: serverA,
            chatViewModel: chatA
        )
        let auxiliaryB = store.gitAvailabilityViewModel(
            session: sessionB,
            server: serverB,
            chatViewModel: chatB
        )

        XCTAssertFalse(auxiliaryA === auxiliaryB)
        XCTAssertTrue(
            store.gitAvailabilityViewModel(
                session: sessionA,
                server: serverA,
                chatViewModel: chatA
            ) === auxiliaryA
        )
    }

    @MainActor
    func testGitAvailabilityViewModelEvictionAndResetReleaseAuxiliaryEntry() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 1)
        )
        weak var evictedAuxiliary: GitWorkspaceAvailabilityViewModel?

        do {
            let session = SessionSummary(sessionId: "session-evicted")
            let chatViewModel = store.viewModel(session: session, server: server)
            evictedAuxiliary = store.gitAvailabilityViewModel(
                session: session,
                server: server,
                chatViewModel: chatViewModel
            )
        }

        _ = store.viewModel(
            session: SessionSummary(sessionId: "session-retained"),
            server: server
        )
        XCTAssertNil(evictedAuxiliary)

        weak var resetAuxiliary: GitWorkspaceAvailabilityViewModel?
        do {
            let session = SessionSummary(sessionId: "session-reset")
            let chatViewModel = store.viewModel(session: session, server: server)
            resetAuxiliary = store.gitAvailabilityViewModel(
                session: session,
                server: server,
                chatViewModel: chatViewModel
            )
        }
        store.resetForTesting()
        XCTAssertNil(resetAuxiliary)
    }

    @MainActor
    func testStoreRetentionDoesNotStartSessionEventSync() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let viewModel = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            sessionEventStreamClient: streamClient
        )

        // Store retention alone must not open a background event stream.
        // Always-on streams for every retained chat caused main-thread disk
        // I/O and transcript reloads (build 19 lag regression).
        XCTAssertEqual(streamClient.startedURLs.count, 0)
        XCTAssertTrue(viewModel.usesDirectGateway)

        // Direct gateway conversations use the shared gateway runtime; they must
        // never fall back to the legacy WebUI session-event SSE lifecycle.
        viewModel.startSessionEventSync()
        XCTAssertEqual(streamClient.startedURLs.count, 0)
        XCTAssertEqual(streamClient.stopCount, 0)

        viewModel.stopSessionEventSync()
        XCTAssertEqual(streamClient.startedURLs.count, 0)
        XCTAssertEqual(streamClient.stopCount, 0)

        // Reuse and retention eviction preserve the same no-SSE invariant.
        let reused = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            sessionEventStreamClient: streamClient
        )
        XCTAssertTrue(reused === viewModel)
        reused.startSessionEventSync()
        reused.stopSessionEventSync()

        for index in 0..<100 {
            _ = OpenChatSessionStore.shared.viewModel(
                session: SessionSummary(sessionId: "retained-\(index)"),
                server: server
            )
        }

        XCTAssertEqual(streamClient.startedURLs.count, 0)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    @MainActor
    func testOfficialSidecarDoesNotStartWebUISessionEventStream() async throws {
        let streamClient = SpySSEStreamingClient()
        let capabilities = #"{"features":{"session_resources":true,"session_chat":true,"session_chat_streaming":true},"endpoints":{"sessions":{"method":"GET","path":"/api/sessions"},"session_create":{"method":"POST","path":"/api/sessions"},"session":{"method":"GET","path":"/api/sessions/{session_id}"},"session_messages":{"method":"GET","path":"/api/sessions/{session_id}/messages"},"session_chat_stream":{"method":"POST","path":"/api/sessions/{session_id}/chat/stream"}}}"#
        let viewModel = try makeViewModel(
            sessionID: "official-session",
            sessionEventStreamClient: streamClient,
            usesOfficialContinuity: true,
            handler: { request in
                apiTestJSONResponse(capabilities, for: request)
            }
        )

        viewModel.startSessionEventSync()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(streamClient.startedURLs.count, 0)
    }

    @MainActor
    func testCursorPersistenceIsDebouncedAcrossStreamingBursts() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "goku.session-event-debounce-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let cursorStore = SessionEventCursorStore(defaults: defaults)
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )

        coordinator.start()
        let connection = streamClient.startedURLs.count - 1
        // Burst of events: in-memory dedupe advances immediately, but no
        // synchronous UserDefaults write happens per event.
        for index in 0..<10 {
            streamClient.emit(.token("chunk \(index)"), lastEventID: "session-abc:\(10 + index)", onConnection: connection)
        }
        XCTAssertNil(cursorStore.load(server: server, profile: nil, sessionID: "session-abc"))

        // Stop flushes the coalesced state once.
        coordinator.stop()
        XCTAssertEqual(
            cursorStore.load(server: server, profile: nil, sessionID: "session-abc"),
            "session-abc:19"
        )
        let seenIDs = cursorStore.loadSeenEventIDs(server: server, profile: nil, sessionID: "session-abc")
        XCTAssertEqual(seenIDs.last, "session-abc:19")
    }

    @MainActor
    func testOpaqueEventIDsAdvanceInServerDeliveryOrder() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "goku.session-event-order-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let cursorStore = SessionEventCursorStore(defaults: defaults)
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )
        coordinator.start()
        let connection = streamClient.startedURLs.count - 1
        streamClient.emit(.token("first"), lastEventID: "journal:10", onConnection: connection)
        // Event IDs are opaque. Even though this looks numerically lower, the
        // server delivered it later, so it becomes the resume point.
        streamClient.emit(.token("second"), lastEventID: "journal:8", onConnection: connection)
        coordinator.stop()

        XCTAssertEqual(
            cursorStore.load(server: server, profile: nil, sessionID: "session-abc"),
            "journal:8"
        )
    }

    @MainActor
    func testSidebarRefreshReconcilesOpenTranscriptFromCanonicalServer() async throws {
        var sessionFetches = 0
        let viewModel = try makeViewModel(sessionID: "session-abc") { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionFetches += 1
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Sent from TUI", "message_id": "tui-1", "timestamp": 1770000000},
                  {"role": "assistant", "content": "Canonical response", "message_id": "assistant-1", "timestamp": 1770000001}
                ]
              }
            }
            """, for: request)
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        let refreshed = await OpenChatSessionStore.shared.refreshOpenSessions(for: server)

        XCTAssertEqual(refreshed, 1)
        XCTAssertEqual(sessionFetches, 1)
        XCTAssertEqual(viewModel.messages.map(\.content), ["Sent from TUI", "Canonical response"])
    }

    @MainActor
    func testStoreKeepsDistinctViewModelsForDifferentSessions() throws {
        let alpha = try makeViewModel(sessionID: "session-alpha")
        let beta = try makeViewModel(sessionID: "session-beta")
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-alpha"),
            server: server,
            creating: alpha
        )
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-beta"),
            server: server,
            creating: beta
        )

        XCTAssertFalse(alpha === beta)
        XCTAssertEqual(
            OpenChatSessionStore.shared.viewModel(
                session: SessionSummary(sessionId: "session-alpha"),
                server: server
            ) === alpha,
            true
        )
    }

    @MainActor
    func testStoreBoundsInactiveConversationRetentionByRecency() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let first = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-0"),
            server: server
        )

        for index in 1...12 {
            _ = OpenChatSessionStore.shared.viewModel(
                session: SessionSummary(sessionId: "session-\(index)"),
                server: server
            )
        }

        XCTAssertEqual(
            OpenChatSessionStore.shared.retainedSessionCountForTesting,
            OpenChatSessionStore.maxRetainedIdleSessionCount
        )
        let reopenedFirst = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-0"),
            server: server
        )
        XCTAssertFalse(reopenedFirst === first, "The least-recent inactive model should be evicted")
    }

    @MainActor
    func testLeaveDoesNotSuspendALiveRunAndReopenDoesNotNeedSessionFetch() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionFetchCount = 0
        let viewModel = try makeViewModel(sessionID: "session-abc", streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                sessionFetchCount += 1
                XCTFail("Warm reopen must not wait on /api/session to know the run is live.")
                return apiTestJSONResponse("{}", for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("Partial live answer."), lastEventID: "session-abc:4")
        streamClient.emit(
            .toolStarted(ToolStreamEvent(
                eventType: "tool.started",
                name: "search_files",
                preview: "searching",
                args: nil,
                duration: nil,
                isError: nil,
                stableID: "tool-1"
            )),
            lastEventID: "session-abc:5"
        )
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertFalse(viewModel.liveToolCalls.isEmpty)

        ChatNavigationLifecycle.applyViewDisappear(to: viewModel)
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)

        let reopened = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server
        )
        XCTAssertTrue(reopened === viewModel)
        XCTAssertTrue(reopened.hasPreservedLiveRun)
        XCTAssertTrue(reopened.hasPreservedTranscript)
        XCTAssertFalse(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: reopened.hasPreservedTranscript
            )
        )
        XCTAssertEqual(reopened.activeStreamID, "stream-123")
        XCTAssertEqual(reopened.liveToolCalls.first?.id, "tool-1")
        XCTAssertEqual(sessionFetchCount, 0)
    }

    @MainActor
    func testSidebarPulseUsesLiveOwnerEvenWhenListPayloadIsIdle() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(sessionID: "session-abc", streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let idleListRow = SessionSummary(sessionId: "session-abc", isStreaming: false)
        XCTAssertTrue(
            SessionRowView.isActiveStreaming(
                idleListRow,
                liveOwnerSessionIDs: OpenChatSessionStore.shared.liveSessionIDs(for: server)
            )
        )
        XCTAssertEqual(
            OpenChatSessionStore.shared.liveStreamIDs(for: server),
            ["stream-123"]
        )
    }

    func testColdOpenAdoptsListStreamIDBeforeSessionFetch() throws {
        let viewModel = try makeViewModel(
            sessionID: "session-abc",
            activeStreamID: "stream-from-list"
        )

        XCTAssertEqual(viewModel.activeStreamID, "stream-from-list")
        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertTrue(viewModel.hasPreservedLiveRun)
        XCTAssertFalse(viewModel.hasPreservedTranscript)
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: viewModel.hasPreservedTranscript
            )
        )
        XCTAssertFalse(viewModel.isEstablishingConnection)
    }

    func testColdOpenWithoutKnownStreamDoesNotFlashConnectingOnCachePaint() throws {
        let viewModel = try makeViewModel(sessionID: "session-abc")
        viewModel.markConversationConnectionInProgress()

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isEstablishingConnection)

        viewModel.markConnectionVisiblySlowForTesting()
        XCTAssertTrue(viewModel.isEstablishingConnection)
    }

    func testKnownListStreamReconnectsWithoutWaitingOnSessionFetch() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionFetchCount = 0
        var statusFetchCount = 0
        let viewModel = try makeViewModel(
            sessionID: "session-abc",
            activeStreamID: "stream-from-list",
            streamClient: streamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                statusFetchCount += 1
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "replay_available": true
                }
                """, for: request)
            case "/api/session":
                sessionFetchCount += 1
                XCTFail("Known list stream must attach before /api/session.")
                return apiTestJSONResponse("{}", for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(statusFetchCount, 1)
        XCTAssertEqual(sessionFetchCount, 0)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.activeStreamID, "stream-from-list")
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
    }

    @MainActor
    func testKnownListStreamAttachesBeforeTranscriptReloadWhenReplayIsUnavailable() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionFetchCount = 0
        let viewModel = try makeViewModel(
            sessionID: "session-abc",
            activeStreamID: "stream-from-list",
            streamClient: streamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "replay_available": false
                }
                """, for: request)
            case "/api/session":
                sessionFetchCount += 1
                XCTAssertEqual(
                    streamClient.startedURLs.count,
                    1,
                    "The live SSE must attach before a lock-bound transcript reload."
                )
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(sessionFetchCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.activeStreamID, "stream-from-list")
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
    }

    @MainActor
    func testRememberedRestorePointSurvivesLeaveAndReopen() throws {
        let viewModel = try makeViewModel(sessionID: "session-abc")
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        viewModel.rememberTranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: "msg-where-i-left"
        )

        let reopened = OpenChatSessionStore.shared.viewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server
        )

        XCTAssertTrue(reopened === viewModel)
        XCTAssertEqual(
            reopened.transcriptRestoreTarget,
            .message(id: "msg-where-i-left")
        )
        XCTAssertFalse(reopened.savedFollowingLatest)
    }

    @MainActor
    func testSessionEventCoordinatorUsesIndependentDurableCursor() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "semreh.session-event-tests-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test/"))
        let streamClient = SpySSEStreamingClient()
        let cursorStore = SessionEventCursorStore(defaults: defaults)
        cursorStore.save(
            eventID: "stream-A:9",
            server: server,
            profile: "work",
            sessionID: "session-abc"
        )
        var appliedSnapshots = 0
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: "work",
            streamClient: streamClient,
            userDefaults: defaults
        )
        coordinator.onSnapshot = { snapshot in
            appliedSnapshots += 1
            XCTAssertEqual(snapshot.sessionId, "session-abc")
            return true
        }

        coordinator.start()
        XCTAssertEqual(streamClient.startedURLs.last?.path, "/api/sessions/session-abc/events")
        XCTAssertEqual(streamClient.resumeEventIDs.last ?? nil, "stream-A:9")

        streamClient.emit(.token("journal event"), lastEventID: "stream-A:10")
        // Persistence is debounced: the in-memory cursor advanced but the disk
        // mirror has not been written yet.
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            "stream-A:9"
        )

        // A reconnect prefers the fresher in-memory cursor over the stale disk row.
        coordinator.start()
        XCTAssertEqual(streamClient.resumeEventIDs.last ?? nil, "stream-A:10")

        streamClient.emit(.token("duplicate event"), lastEventID: "stream-A:10", onConnection: streamClient.startedURLs.count - 1)
        coordinator.stop()
        // Stop flushes the coalesced cursor once.
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            "stream-A:10"
        )

        coordinator.start()
        let liveConnection = streamClient.startedURLs.count - 1
        streamClient.emit(.token("new stream event"), lastEventID: "stream-B:1", onConnection: liveConnection)
        streamClient.emit(.token("old stream replay"), lastEventID: "stream-A:10", onConnection: liveConnection)
        streamClient.emit(.token("opaque one"), lastEventID: "opaque-1", onConnection: liveConnection)
        streamClient.emit(.token("opaque two"), lastEventID: "opaque-2", onConnection: liveConnection)
        streamClient.emit(.token("opaque replay"), lastEventID: "opaque-1", onConnection: liveConnection)
        // Dedupe state is in-memory; the disk mirror still holds the flushed value.
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            "stream-A:10"
        )
        coordinator.stop()
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            "opaque-2"
        )

        // Reconnect, then receive a snapshot (recovery boundary): the stale
        // cursor and dedupe state are discarded and must not be re-persisted.
        coordinator.start()
        let recoveryConnection = streamClient.startedURLs.count - 1
        streamClient.emit(
            .sessionSnapshot(SessionSummary(sessionId: "session-abc", title: "Updated")),
            lastEventID: nil,
            onConnection: recoveryConnection
        )

        XCTAssertEqual(appliedSnapshots, 1)
        XCTAssertEqual(
            cursorStore.load(server: server, profile: "work", sessionID: "session-abc"),
            nil
        )
        coordinator.stop()
        coordinator.start()
        XCTAssertNil(streamClient.resumeEventIDs.last ?? nil)
        XCTAssertNil(
            cursorStore.load(server: server, profile: "other", sessionID: "session-abc")
        )
    }

    @MainActor
    func testSessionEventCoordinatorReconnectsAfterTerminalAndStopCancelsRetry() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "semreh.session-event-reconnect-tests-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )
        var delivered: [SSEEvent] = []
        coordinator.onEvent = { delivered.append($0) }

        coordinator.start()
        streamClient.emit(.streamEnd, lastEventID: "stream-A:10")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.resumeEventIDs.last ?? nil, "stream-A:10")
        XCTAssertEqual(delivered, [.streamEnd])

        coordinator.stop()
        streamClient.emit(.transportError("late"), lastEventID: nil, onConnection: 1)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }

    @MainActor
    func testSessionEventCoordinatorReconnectsAfterAcceptedSnapshotWithoutCursor() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "semreh.session-event-snapshot-reconnect-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )
        coordinator.onSnapshot = { _ in true }

        coordinator.start()
        streamClient.emit(
            .sessionSnapshot(SessionSummary(sessionId: "session-abc", title: "Recovered")),
            lastEventID: "journal:42"
        )

        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertNil(streamClient.resumeEventIDs.last ?? nil)
        coordinator.stop()
    }

    @MainActor
    func testRejectedSnapshotDoesNotClearDurableCursor() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "semreh.session-event-rejected-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let cursorStore = SessionEventCursorStore(defaults: defaults)
        cursorStore.save(
            eventID: "journal:41",
            server: server,
            profile: nil,
            sessionID: "session-abc"
        )
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )
        coordinator.onSnapshot = { _ in false }

        coordinator.start()
        streamClient.emit(
            .sessionSnapshot(SessionSummary(sessionId: "session-abc", title: "Rejected")),
            lastEventID: "journal:42"
        )
        coordinator.stop()

        XCTAssertEqual(
            cursorStore.load(server: server, profile: nil, sessionID: "session-abc"),
            "journal:41"
        )
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testOverlappingOpenSessionRefreshesShareOneCanonicalLoad() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = try makeViewModel(sessionID: "session-abc") { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Canonical", "message_id": "canonical-1", "timestamp": 1770000000}
                ]
              }
            }
            """, for: request)
        }
        _ = OpenChatSessionStore.shared.adoptedViewModel(
            session: SessionSummary(sessionId: "session-abc"),
            server: server,
            creating: viewModel
        )

        let first = Task { @MainActor in
            await OpenChatSessionStore.shared.refreshOpenSessions(for: server)
        }
        let second = Task { @MainActor in
            await OpenChatSessionStore.shared.refreshOpenSessions(for: server)
        }

        let firstCount = await first.value
        let secondCount = await second.value
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(viewModel.messages.map(\.content), ["Canonical"])
    }

    @MainActor
    func testSyntheticSessionDoesNotStartSessionEventSync() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: nil),
            server: server,
            sessionEventStreamClient: streamClient
        )

        viewModel.startSessionEventSync()

        XCTAssertTrue(streamClient.startedURLs.isEmpty)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    @MainActor
    func testSessionEventCoordinatorDropsCallbackFromReplacedConnection() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "semreh.session-event-stale-tests-\(UUID().uuidString)"))
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let streamClient = SpySSEStreamingClient()
        var appliedSnapshots = 0
        let coordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: "session-abc",
            profile: nil,
            streamClient: streamClient,
            userDefaults: defaults
        )
        coordinator.onSnapshot = { _ in
            appliedSnapshots += 1
            return true
        }

        coordinator.start()
        coordinator.start()
        streamClient.emit(
            .sessionSnapshot(SessionSummary(sessionId: "session-abc")),
            lastEventID: "stale",
            onConnection: 0
        )
        XCTAssertEqual(appliedSnapshots, 0)

        streamClient.emit(
            .sessionSnapshot(SessionSummary(sessionId: "session-abc")),
            lastEventID: "current",
            onConnection: 1
        )
        XCTAssertEqual(appliedSnapshots, 1)
    }

    @MainActor
    func makeViewModel(
        sessionID: String,
        activeStreamID: String? = nil,
        streamClient: SSEStreamingClient? = nil,
        sessionEventStreamClient: SSEStreamingClient? = nil,
        usesOfficialContinuity: Bool = false,
        handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) throws -> ChatViewModel {
        if let handler {
            MockURLProtocol.requestHandler = handler
        } else {
            MockURLProtocol.requestHandler = { request in
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let officialClient = usesOfficialContinuity
            ? OfficialHermesContinuityClient(
                baseURL: try XCTUnwrap(URL(string: "https://official.example.test")),
                session: urlSession,
                customHeaderProvider: { [] }
            )
            : nil
        let client = APIClient(
            baseURL: server,
            session: urlSession,
            officialContinuityClient: officialClient
        )
        let resolvedStreamClient = streamClient ?? SpySSEStreamingClient()
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: sessionID, activeStreamId: activeStreamID),
            server: server,
            client: client,
            streamClient: resolvedStreamClient,
            approvalStreamClient: SpySSEStreamingClient(),
            clarifyStreamClient: SpySSEStreamingClient(),
            sessionEventStreamClient: sessionEventStreamClient ?? SpySSEStreamingClient(),
            listenAudioSession: SpyListenAudioSession(),
            listenRemoteControlCenter: SpyListenRemoteControlCenter()
        )
        if let spy = resolvedStreamClient as? SpySSEStreamingClient {
            spy.flushPendingStreamingContent = { [weak viewModel] in
                viewModel?.flushPendingStreamingContent()
            }
        }
        return viewModel
    }
}

private final class SpySSEStreamingClient: SSEStreamingClient {
    private(set) var startedURLs: [URL] = []
    private(set) var resumeEventIDs: [String?] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?
    private var eventHandlers: [@MainActor (SSEEvent, String?) -> Void] = []
    var automaticallyFlushPendingStreamingContent = true
    var flushPendingStreamingContent: (() -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        start(url: url, resumeFrom: nil, onEvent: onEvent)
    }

    func start(
        url: URL,
        resumeFrom eventID: String?,
        onEvent: @escaping @MainActor (SSEEvent) -> Void
    ) {
        start(url: url, resumeFrom: eventID) { event, _ in
            onEvent(event)
        }
    }

    func start(
        url: URL,
        resumeFrom eventID: String?,
        onEventWithID onEvent: @escaping @MainActor (SSEEvent, String?) -> Void
    ) {
        startedURLs.append(url)
        resumeEventIDs.append(eventID)
        lastEventID = eventID
        eventHandlers.append(onEvent)
    }

    func stop() {
        stopCount += 1
    }

    @MainActor
    func emit(
        _ event: SSEEvent,
        lastEventID: String? = nil,
        onConnection index: Int? = nil
    ) {
        self.lastEventID = lastEventID
        let handler = index.flatMap { eventHandlers.indices.contains($0) ? eventHandlers[$0] : nil }
            ?? eventHandlers.last
        handler?(event, lastEventID)
        if automaticallyFlushPendingStreamingContent {
            flushPendingStreamingContent?()
        }
    }
}

private final class SpyListenAudioSession: ListenAudioSessionControlling {
    func activate() {}
    func deactivate() {}
}

@MainActor
private final class SpyListenRemoteControlCenter: ListenRemoteControlControlling {
    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        changePlaybackPosition: @escaping @MainActor (TimeInterval) -> Void
    ) {}

    func update(_ snapshot: ListenNowPlayingSnapshot) {}
    func clear() {}
}
