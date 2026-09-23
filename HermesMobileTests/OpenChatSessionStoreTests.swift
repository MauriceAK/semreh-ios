import XCTest
import Observation
@testable import HermesMobile

@MainActor
private final class SelectedHistoryLoadRecorder {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

private actor SelectedHistoryLoadGate {
    private var releaseWaiter: CheckedContinuation<Bool, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func waitForRelease() async -> Bool {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        guard releaseWaiter == nil else { return }
        await withCheckedContinuation { continuation in startWaiter = continuation }
    }

    func release() {
        releaseWaiter?.resume(returning: true)
        releaseWaiter = nil
    }
}

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
    func testActiveModelsArePreservedWhileIdleModelsAreEvicted() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 2)
        )
        let fixture = try await makeDirectBranchViewModel(
            session: SessionSummary(sessionId: "session-active"), server: server, running: true
        )
        let active = fixture.viewModel
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
        XCTAssertEqual(store.liveStreamIDs(for: server), [])
        await fixture.runtime.stop()
    }

    @MainActor
    func testActiveToIdleNotificationTrimsPreviouslyProtectedModel() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 1)
        )
        let fixture = try await makeDirectBranchViewModel(
            session: SessionSummary(sessionId: "session-active"), server: server, running: true
        )
        let active = fixture.viewModel
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "session-active"),
            server: server,
            creating: active
        )
        _ = store.viewModel(session: SessionSummary(sessionId: "session-idle-1"), server: server)
        _ = store.viewModel(session: SessionSummary(sessionId: "session-idle-2"), server: server)
        XCTAssertTrue(store.retainedSessionIDsForTesting(for: server).contains("session-active"))

        // Direct interruption requires a terminal receipt and idle status before
        // the owner becomes eligible for deterministic LRU eviction.
        let didCancel = await active.cancelActiveStream()
        XCTAssertTrue(didCancel)
        store.noteStreamingStateChanged()

        XCTAssertNil(active.activeStreamID)
        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["session-idle-2"])
        await fixture.runtime.stop()
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

    func testRejectedDirectInterruptKeepsRunningOwnerAndReportsUnconfirmedStop() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let fixture = try await makeDirectBranchViewModel(
            session: SessionSummary(sessionId: "session-active"), server: server,
            running: true, rejectsInterrupt: true
        )
        let activeID = try XCTUnwrap(fixture.viewModel.activeStreamID)

        let cancelled = await fixture.viewModel.cancelActiveStream()

        XCTAssertFalse(cancelled)
        XCTAssertEqual(fixture.viewModel.activeStreamID, activeID)
        XCTAssertEqual(fixture.controller.runState, .stopping)
        XCTAssertEqual(fixture.viewModel.sendErrorMessage, "Hermes has not confirmed that the response stopped.")
        await fixture.runtime.stop()
    }

    func testCancelWithoutDirectRuntimeDoesNotUseLegacyHTTPCancel() async throws {
        let viewModel = try makeViewModel(sessionID: "legacy-fixture", activeStreamID: "legacy-stream") { request in
            XCTFail("Cancellation must not reach legacy HTTP: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        let cancelled = await viewModel.cancelActiveStream()

        XCTAssertFalse(cancelled)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.sendErrorMessage, "Hermes has not confirmed that the response stopped.")
    }

    @MainActor
    func testEvictionClearsDirectConversationVisibilityBeforeReleasingModel() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 1)
        )
        let session = SessionSummary(sessionId: "session-evicted", profile: "default")
        let fixture = try await makeDirectBranchViewModel(session: session, server: server)
        let evicted = fixture.viewModel
        evicted.startSessionEventSync()
        XCTAssertTrue(fixture.controller.isVisible)
        _ = store.adoptedViewModel(session: session, server: server, creating: evicted)

        _ = store.viewModel(session: SessionSummary(sessionId: "session-new"), server: server)

        XCTAssertFalse(fixture.controller.isVisible)
        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["session-new"])
        await fixture.runtime.stop()
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
    func testDirectBranchAdoptionRetainsParentAndReusesBoundChild() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore()
        store.activateGateway(server: server)
        let parent = store.viewModel(session: SessionSummary(sessionId: "parent"), server: server)
        let childSession = SessionSummary(sessionId: "child", profile: "default")
        let childFixture = try await makeDirectBranchViewModel(session: childSession, server: server)
        let child = childFixture.viewModel
        defer { Task { await childFixture.runtime.stop() } }
        let handoff = DirectBranchHandoff(
            session: childSession,
            viewModel: child,
            origin: server,
            profile: "default",
            identity: UUID()
        )

        XCTAssertTrue(store.adoptBranch(handoff) === child)
        store.releaseUnadoptedBranch(handoff)
        XCTAssertNotNil(child.directBranchIdentity)
        XCTAssertTrue(store.viewModel(session: childSession, server: server) === child)
        XCTAssertTrue(store.viewModel(session: SessionSummary(sessionId: "parent"), server: server) === parent)

        child.onDirectCanonicalID?("child-tip")
        XCTAssertTrue(store.viewModel(session: SessionSummary(sessionId: "child-tip", profile: "default"), server: server) === child)
        XCTAssertTrue(store.viewModel(session: childSession, server: server) === child)
        XCTAssertTrue(store.viewModel(session: SessionSummary(sessionId: "parent"), server: server) === parent)
    }

    @MainActor
    func testDirectBranchCollisionRejectsWithoutReplacingExistingOwner() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore()
        store.activateGateway(server: server)
        let childSession = SessionSummary(sessionId: "collision-child", profile: "work")
        let incumbent = store.viewModel(session: childSession, server: server)
        let childFixture = try await makeDirectBranchViewModel(session: childSession, server: server)
        let child = childFixture.viewModel
        defer { Task { await childFixture.runtime.stop() } }
        let handoff = DirectBranchHandoff(
            session: childSession,
            viewModel: child,
            origin: server,
            profile: "work",
            identity: UUID()
        )

        XCTAssertNil(store.adoptBranch(handoff))
        store.releaseUnadoptedBranch(handoff)
        XCTAssertNil(child.directBranchIdentity)
        XCTAssertTrue(store.viewModel(session: childSession, server: server) === incumbent)
    }

    @MainActor
    func testDirectBranchRejectsWrongOriginProfileAndReplayedIdentity() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let otherServer = try XCTUnwrap(URL(string: "https://other.example.test"))
        let store = OpenChatSessionStore()
        store.activateGateway(server: server)
        let childSession = SessionSummary(sessionId: "scoped-child", profile: "work")
        let childFixture = try await makeDirectBranchViewModel(session: childSession, server: server)
        let child = childFixture.viewModel
        defer { Task { await childFixture.runtime.stop() } }
        let identity = UUID()

        XCTAssertNil(store.adoptBranch(DirectBranchHandoff(
            session: childSession,
            viewModel: child,
            origin: otherServer,
            profile: "work",
            identity: UUID()
        )))
        XCTAssertNil(store.adoptBranch(DirectBranchHandoff(
            session: childSession,
            viewModel: child,
            origin: server,
            profile: "default",
            identity: UUID()
        )))

        let accepted = DirectBranchHandoff(
            session: childSession,
            viewModel: child,
            origin: server,
            profile: "work",
            identity: identity
        )
        XCTAssertTrue(store.adoptBranch(accepted) === child)

        let replayedSession = SessionSummary(sessionId: "another-child", profile: "work")
        let replayedFixture = try await makeDirectBranchViewModel(
            session: replayedSession,
            server: server
        )
        defer { Task { await replayedFixture.runtime.stop() } }
        let replayedForDifferentSession = DirectBranchHandoff(
            session: replayedSession,
            viewModel: replayedFixture.viewModel,
            origin: server,
            profile: "work",
            identity: identity
        )
        XCTAssertNil(store.adoptBranch(replayedForDifferentSession))
        XCTAssertTrue(store.viewModel(session: childSession, server: server) === child)
    }

    @MainActor
    func testDirectBranchEvictionRemovesOnlyTheBranchOwner() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 1)
        )
        store.activateGateway(server: server)
        let childSession = SessionSummary(sessionId: "evicted-child")
        let childFixture = try await makeDirectBranchViewModel(session: childSession, server: server)
        let child = childFixture.viewModel
        defer { Task { await childFixture.runtime.stop() } }
        XCTAssertNotNil(store.adoptBranch(DirectBranchHandoff(
            session: childSession,
            viewModel: child,
            origin: server,
            profile: "default",
            identity: UUID()
        )))
        let other = store.viewModel(session: SessionSummary(sessionId: "retained-other"), server: server)

        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["retained-other"])
        XCTAssertTrue(store.viewModel(session: SessionSummary(sessionId: "retained-other"), server: server) === other)
    }

    @MainActor
    func testResetClearsRetainedModelsOrderingAndLiveState() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore(
            retentionPolicy: OpenChatSessionStoreRetentionPolicy(maxIdleViewModelsPerServer: 2)
        )
        let session = SessionSummary(sessionId: "session-reset", profile: "default")
        let fixture = try await makeDirectBranchViewModel(session: session, server: server)
        let retained = fixture.viewModel
        retained.startSessionEventSync()
        XCTAssertTrue(fixture.controller.isVisible)
        _ = store.adoptedViewModel(session: session, server: server, creating: retained)

        store.resetForTesting()

        XCTAssertFalse(fixture.controller.isVisible)
        XCTAssertEqual(store.retainedViewModelCountForTesting(for: server), 0)
        XCTAssertTrue(store.liveSessionIDs(for: server).isEmpty)
        XCTAssertTrue(store.liveStreamIDs(for: server).isEmpty)
        XCTAssertEqual(store.liveOwnershipGeneration, 0)
        XCTAssertFalse(store.viewModel(session: session, server: server) === retained)
        await fixture.runtime.stop()
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
    func testForegroundRecoverySharesOneForceReconnect() async throws {
        let server = try XCTUnwrap(URL(string: "https://foreground.example.test"))
        let store = OpenChatSessionStore()
        let transport = ForegroundRecoveryTransport()
        let runtime = try makeForegroundRuntime(transport)
        try await runtime.connect()
        store.activateGateway(server: server)
        store.installGatewayRuntimeForTesting(runtime, for: server)
        await transport.blockConnection(2)

        let first = Task { await store.recoverGatewayOnForeground(for: server) }
        await transport.waitForConnection(2)
        let second = Task { await store.recoverGatewayOnForeground(for: server) }
        await Task.yield()
        await transport.releaseConnection(2)

        let firstResult = await first.value
        let secondResult = await second.value
        let connectionCount = await transport.connectionCount()
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(runtime.state, .ready)

        await runtime.stop()
        store.activateGateway(server: nil)
    }

    @MainActor
    func testForegroundRecoveryReturnsConnectivityFailureAndCanRetry() async throws {
        let server = try XCTUnwrap(URL(string: "https://foreground-failure.example.test"))
        let store = OpenChatSessionStore()
        let transport = ForegroundRecoveryTransport()
        let runtime = try makeForegroundRuntime(transport)
        try await runtime.connect()
        store.activateGateway(server: server)
        store.installGatewayRuntimeForTesting(runtime, for: server)
        await transport.failNextConnections(1)

        let failure = await store.recoverGatewayOnForeground(for: server)
        XCTAssertNotNil(failure)
        XCTAssertEqual(runtime.state, .disconnected)

        let retryResult = await store.recoverGatewayOnForeground(for: server)
        XCTAssertNil(retryResult)
        XCTAssertEqual(runtime.state, .ready)
        await runtime.stop()
        store.activateGateway(server: nil)
    }

    @MainActor
    func testForegroundRecoveryReplacesReadyButStaleSocket() async throws {
        let server = try XCTUnwrap(URL(string: "https://foreground-stale.example.test"))
        let store = OpenChatSessionStore()
        let transport = ForegroundRecoveryTransport()
        let runtime = try makeForegroundRuntime(transport)
        try await runtime.connect()
        store.activateGateway(server: server)
        store.installGatewayRuntimeForTesting(runtime, for: server)
        await transport.markConnectionStale()

        let result = await store.recoverGatewayOnForeground(for: server)
        let connectionCount = await transport.connectionCount()
        XCTAssertNil(result)
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(runtime.state, .ready)
        await runtime.stop()
        store.activateGateway(server: nil)
    }

    @MainActor
    func testForegroundRecoveryCannotReviveStoppedOrOldServerRuntime() async throws {
        let serverA = try XCTUnwrap(URL(string: "https://foreground-a.example.test"))
        let serverB = try XCTUnwrap(URL(string: "https://foreground-b.example.test"))
        let store = OpenChatSessionStore()
        let transport = ForegroundRecoveryTransport()
        let runtime = try makeForegroundRuntime(transport)
        try await runtime.connect()
        store.activateGateway(server: serverA)
        store.installGatewayRuntimeForTesting(runtime, for: serverA)
        await runtime.stop()

        let stopped = await store.recoverGatewayOnForeground(for: serverA)
        let stoppedConnectionCount = await transport.connectionCount()
        XCTAssertEqual(stopped as? DirectSessionError, .stopped)
        XCTAssertEqual(stoppedConnectionCount, 1)

        store.activateGateway(server: serverB)
        let staleResult = await store.recoverGatewayOnForeground(for: serverA)
        let staleConnectionCount = await transport.connectionCount()
        XCTAssertNil(staleResult)
        XCTAssertEqual(staleConnectionCount, 1)
        store.activateGateway(server: nil)
    }

    @MainActor
    func testForegroundRecoveryCannotReviveAfterInFlightServerSwitchOrLogout() async throws {
        let serverA = try XCTUnwrap(URL(string: "https://foreground-in-flight-a.example.test"))
        let serverB = try XCTUnwrap(URL(string: "https://foreground-in-flight-b.example.test"))

        for destination in [serverB, nil] as [URL?] {
            let store = OpenChatSessionStore()
            let transport = ForegroundRecoveryTransport()
            let runtime = try makeForegroundRuntime(transport)
            try await runtime.connect()
            store.activateGateway(server: serverA)
            store.installGatewayRuntimeForTesting(runtime, for: serverA)
            await transport.blockConnection(2)

            let recovery = Task { await store.recoverGatewayOnForeground(for: serverA) }
            await transport.waitForConnection(2)
            store.activateGateway(server: destination)
            // Force reconnect closes the old socket once before connect #2;
            // wait for the teardown close as well before releasing connect #2.
            await transport.waitForClose(2)
            await transport.releaseConnection(2)

            _ = await recovery.value
            let connectionCount = await transport.connectionCount()
            XCTAssertEqual(runtime.state, .stopped)
            XCTAssertEqual(connectionCount, 2)
            if let destination {
                let currentRuntime = try await store.runtime(for: destination, client: APIClient(baseURL: destination))
                XCTAssertTrue(currentRuntime !== runtime)
            }
            await runtime.stop()
            store.activateGateway(server: nil)
        }
    }

    private func makeForegroundRuntime(_ transport: ForegroundRecoveryTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: URL(string: "https://foreground.example.test")!) { _ in transport }
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
        let git = store.gitAvailabilityViewModel(session: ancestor, server: server, chatViewModel: model)
        let ancestorKeyID = ancestor.id
        model.onDirectCanonicalID?("canonical-alpha")

        XCTAssertEqual(store.retainedSessionIDsForTesting(for: server), ["canonical-alpha"])
        let reopened = store.viewModel(session: ancestor, server: server)
        XCTAssertTrue(reopened === model)
        let reopenedGit = store.gitAvailabilityViewModel(session: ancestor, server: server, chatViewModel: reopened)
        XCTAssertTrue(reopenedGit === git)
        XCTAssertEqual(reopenedGit.bindingForTesting.sessionID, "canonical-alpha")
        XCTAssertEqual(reopenedGit.bindingForTesting.profile, "alpha")
        XCTAssertEqual(reopenedGit.requestSession.sessionId, "canonical-alpha")
        XCTAssertEqual(reopenedGit.requestSession.profile, "alpha")
        XCTAssertNotEqual(ancestorKeyID, "canonical-alpha")
        XCTAssertEqual(store.retainedViewModelCountForTesting(for: server), 1)

        await model.disposeDirectConversation()
        store.activateGateway(server: nil)
    }

    @MainActor
    func testGitModelCreatedAfterCanonicalAliasUsesConfirmedDurableBinding() async throws {
        let server = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let store = OpenChatSessionStore.shared
        store.activateGateway(server: server)
        let draft = SessionSummary(sessionId: nil, title: "draft", createdAt: 2, profile: "alpha")
        let chat = store.viewModel(session: draft, server: server)
        chat.onDirectCanonicalID?("canonical-late")

        let git = store.gitAvailabilityViewModel(session: draft, server: server, chatViewModel: chat)

        XCTAssertEqual(git.bindingForTesting.sessionID, "canonical-late")
        XCTAssertEqual(git.bindingForTesting.profile, "alpha")
        XCTAssertEqual(git.requestSession.sessionId, "canonical-late")
        XCTAssertEqual(git.requestSession.profile, "alpha")
        await chat.disposeDirectConversation()
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
    func testStoreRetentionAndVisibilityKeepColdDirectConversationsUnbound() throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let session = SessionSummary(sessionId: "session-abc")
        let viewModel = OpenChatSessionStore.shared.viewModel(session: session, server: server)

        XCTAssertTrue(viewModel.usesDirectGateway)
        XCTAssertNil(viewModel.directBranchIdentity)
        viewModel.startSessionEventSync()
        viewModel.stopSessionEventSync()
        XCTAssertNil(viewModel.directBranchIdentity)

        let reused = OpenChatSessionStore.shared.viewModel(session: session, server: server)
        XCTAssertTrue(reused === viewModel)
        reused.startSessionEventSync()
        reused.stopSessionEventSync()
        for index in 0..<100 {
            _ = OpenChatSessionStore.shared.viewModel(
                session: SessionSummary(sessionId: "retained-\(index)"), server: server
            )
        }
        XCTAssertNil(viewModel.directBranchIdentity)
    }

    @MainActor
    func testSidebarRefreshReconcilesOpenTranscriptFromCanonicalServer() async throws {
        var sessionFetches = 0
        let (viewModel, runtime) = try makeDirectRefreshViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            sessionFetches += 1
            return apiTestJSONResponse("""
            {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Sent from TUI", "id": 1, "timestamp": 1770000000},
                  {"role": "assistant", "content": "Canonical response", "id": 2, "timestamp": 1770000001}
                ]
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
        await viewModel.disposeDirectConversation()
        await runtime.stop()
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

    func testColdOpenWithoutKnownStreamDoesNotFlashConnectingOnCachePaint() throws {
        let viewModel = try makeViewModel(sessionID: "session-abc")
        viewModel.markConversationConnectionInProgress()

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isEstablishingConnection)

        viewModel.markConnectionVisiblySlowForTesting()
        XCTAssertTrue(viewModel.isEstablishingConnection)
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
    func testOverlappingOpenSessionRefreshesShareOneCanonicalLoad() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        var sessionFetches = 0
        let (viewModel, runtime) = try makeDirectRefreshViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            sessionFetches += 1
            return apiTestJSONResponse("""
            {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Canonical", "id": 1, "timestamp": 1770000000}
                ]
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
        XCTAssertEqual(sessionFetches, 1)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testListRefreshOnlyLoadsSelectedRetainedConversation() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore()
        let first = SessionSummary(sessionId: "first", profile: "default")
        let second = SessionSummary(sessionId: "second", profile: "default")
        let otherProfile = SessionSummary(sessionId: "first", profile: "research")
        let firstModel = store.viewModel(session: first, server: server)
        let secondModel = store.viewModel(session: second, server: server)
        _ = store.viewModel(session: otherProfile, server: server)
        let calls = SelectedHistoryLoadRecorder()

        store.markRetainedHistoriesStale(for: server, profile: "default")
        XCTAssertEqual(calls.ids, [], "Refreshing the list must not load offscreen histories")
        XCTAssertTrue(store.hasStaleHistoryForTesting(session: first, server: server))
        XCTAssertTrue(store.hasStaleHistoryForTesting(session: second, server: server))
        XCTAssertFalse(store.hasStaleHistoryForTesting(session: otherProfile, server: server))

        let firstLoaded = await store.refreshStaleHistoryIfNeeded(
            for: firstModel, session: first, server: server,
            loader: { model, _ in calls.record(model === firstModel ? "first" : "wrong"); return true }
        )
        XCTAssertTrue(firstLoaded)
        XCTAssertEqual(calls.ids, ["first"])
        XCTAssertFalse(store.hasStaleHistoryForTesting(session: first, server: server))
        XCTAssertTrue(store.hasStaleHistoryForTesting(session: second, server: server))

        let duplicate = await store.refreshStaleHistoryIfNeeded(
            for: firstModel, session: first, server: server,
            loader: { _, _ in calls.record("duplicate"); return true }
        )
        XCTAssertFalse(duplicate)
        XCTAssertEqual(calls.ids, ["first"])

        let secondLoaded = await store.refreshStaleHistoryIfNeeded(
            for: secondModel, session: second, server: server,
            loader: { model, _ in calls.record(model === secondModel ? "second" : "wrong"); return true }
        )
        XCTAssertTrue(secondLoaded)
        XCTAssertEqual(calls.ids, ["first", "second"])
    }

    func testNewerSelectedRefreshWaitsForCancelledOldGeneration() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let store = OpenChatSessionStore()
        let session = SessionSummary(sessionId: "first", profile: "default")
        let model = store.viewModel(session: session, server: server)
        let gate = SelectedHistoryLoadGate()
        let calls = SelectedHistoryLoadRecorder()
        store.markRetainedHistoriesStale(for: server, profile: "default")

        let old = Task { @MainActor in
            await store.refreshStaleHistoryIfNeeded(
                for: model, session: session, server: server,
                loader: { _, _ in
                    calls.record("old-start")
                    let result = await gate.waitForRelease()
                    calls.record("old-end")
                    return result // Deliberately ignores cancellation like a late server result.
                }
            )
        }
        await gate.waitUntilStarted()
        store.markRetainedHistoriesStale(for: server, profile: "default")
        let newer = Task { @MainActor in
            await store.refreshStaleHistoryIfNeeded(
                for: model, session: session, server: server,
                loader: { _, _ in calls.record("new-start"); return true }
            )
        }
        await gate.release()

        let oldResult = await old.value
        let newerResult = await newer.value
        XCTAssertFalse(oldResult, "The old result must not consume a newer generation")
        XCTAssertTrue(newerResult)
        XCTAssertEqual(calls.ids, ["old-start", "old-end", "new-start"])
        XCTAssertFalse(store.hasStaleHistoryForTesting(session: session, server: server))
    }

    @MainActor
    private func makeDirectRefreshViewModel(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> (ChatViewModel, HermesServerRuntime) {
        MockURLProtocol.requestHandler = handler
        let server = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let runtime = try HermesServerRuntime(origin: server) { sink in
            BranchIdentityTransport(sink: sink)
        }
        return (ChatViewModel(
            session: SessionSummary(sessionId: "session-abc", profile: "default"),
            server: server, client: client, gatewayRuntimeProvider: { _ in runtime }
        ), runtime)
    }

    @MainActor
    func testDraftVisibilityDoesNotCreateDirectRuntime() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        var runtimeRequests = 0
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: nil),
            server: server,
            gatewayRuntimeProvider: { _ in
                runtimeRequests += 1
                throw DirectSessionError.stopped
            }
        )

        viewModel.startSessionEventSync()
        viewModel.stopSessionEventSync()
        await Task.yield()

        XCTAssertTrue(viewModel.usesDirectGateway)
        XCTAssertNil(viewModel.directBranchIdentity)
        XCTAssertEqual(runtimeRequests, 0)
    }


    @MainActor
    func makeViewModel(
        sessionID: String,
        activeStreamID: String? = nil,
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
        let client = APIClient(
            baseURL: server,
            session: urlSession
        )
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: sessionID, activeStreamId: activeStreamID),
            server: server,
            client: client,
            listenAudioSession: SpyListenAudioSession(),
            listenRemoteControlCenter: SpyListenRemoteControlCenter()
        )
        return viewModel
    }

    @MainActor
    private struct DirectBranchFixture {
        let viewModel: ChatViewModel
        let runtime: HermesServerRuntime
        let controller: GatewayConversationController
    }

    @MainActor
    private func makeDirectBranchViewModel(
        session: SessionSummary,
        server: URL,
        running: Bool = false,
        rejectsInterrupt: Bool = false
    ) async throws -> DirectBranchFixture {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: server,
            session: URLSession(configuration: configuration)
        )
        let runtime = try HermesServerRuntime(origin: server) { sink in
            BranchIdentityTransport(running: running, rejectsInterrupt: rejectsInterrupt, sink: sink)
        }
        let controller = GatewayConversationController(
            runtime: runtime,
            storedID: session.sessionId,
            profile: session.profile ?? "default",
            loadTranscript: { id, _, _, _ in
                DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
            }
        )
        try await controller.open()
        let viewModel = ChatViewModel(
            session: session,
            server: server,
            client: client,
            gatewayRuntimeProvider: { _ in runtime },
            initialDirectConversation: controller
        )
        let boundIdentity = try XCTUnwrap(viewModel.directBranchIdentity)
        XCTAssertEqual(boundIdentity.origin, server)
        XCTAssertEqual(boundIdentity.profile, session.profile ?? "default")
        XCTAssertEqual(boundIdentity.sessionID, session.sessionId)
        return DirectBranchFixture(viewModel: viewModel, runtime: runtime, controller: controller)
    }
}

private struct BranchIdentityTransport: HermesGatewayTransport, @unchecked Sendable {
    var running = false
    var rejectsInterrupt = false
    var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    func connect() async throws { }
    func close() async { }
    func connectionIdentifier() async -> Int? { 1 }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        if method == "session.interrupt" {
            guard !rejectsInterrupt else { throw DirectSessionError.stopUnconfirmed }
            guard case .object(let fields) = params,
                  case .string(let runtimeID) = fields["session_id"] else {
                throw DirectSessionError.invalidResponse
            }
            sink?(HermesGatewayEvent(
                method: "event", type: "message.complete", sessionID: runtimeID,
                sequence: 1, payload: .object(["status": .string("cancelled")]),
                params: nil, connectionGeneration: 1
            ))
            return .object(["status": .string("interrupted")])
        }
        if method == "session.status" {
            return .object(["output": .string("Agent Running: No")])
        }
        guard method == "session.resume" else { return .object([:]) }
        guard case .object(let fields) = params,
              case .string(let storedID) = fields["session_id"] else {
            throw DirectSessionError.invalidResponse
        }
        return .object([
            "session_id": .string("runtime-\(storedID)"),
            "session_key": .string(storedID),
            "running": .bool(running)
        ])
    }
}

private actor ForegroundRecoveryTransport: HermesGatewayTransport {
    private var connections = 0
    private var closes = 0
    private var activeConnection: Int?
    private var staleConnection = false
    private var failuresRemaining = 0
    private var blockedConnections: Set<Int> = []
    private var blockedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var connectionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var closeWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func connect() async throws {
        connections += 1
        let number = connections
        let waiters = connectionWaiters.keys.filter { $0 <= number }
        for expected in waiters {
            connectionWaiters.removeValue(forKey: expected)?.forEach { $0.resume() }
        }
        if blockedConnections.contains(number) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                blockedWaiters[number, default: []].append(continuation)
            }
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw HermesGatewayError.transport("foreground fixture")
        }
        activeConnection = number
        staleConnection = false
    }

    func close() async {
        closes += 1
        activeConnection = nil
        let waiters = closeWaiters.keys.filter { $0 <= closes }
        for expected in waiters {
            closeWaiters.removeValue(forKey: expected)?.forEach { $0.resume() }
        }
    }

    func connectionIdentifier() async -> Int? {
        guard !staleConnection else { return nil }
        return activeConnection
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        .object(["ok": .bool(true)])
    }

    func blockConnection(_ number: Int) { blockedConnections.insert(number) }

    func releaseConnection(_ number: Int) {
        blockedConnections.remove(number)
        blockedWaiters.removeValue(forKey: number)?.forEach { $0.resume() }
    }

    func waitForConnection(_ number: Int) async {
        guard connections < number else { return }
        await withCheckedContinuation { connectionWaiters[number, default: []].append($0) }
    }

    func waitForClose(_ number: Int) async {
        guard closes < number else { return }
        await withCheckedContinuation { closeWaiters[number, default: []].append($0) }
    }

    func failNextConnections(_ count: Int) { failuresRemaining = count }

    func markConnectionStale() { staleConnection = true }

    func connectionCount() -> Int { connections }
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
