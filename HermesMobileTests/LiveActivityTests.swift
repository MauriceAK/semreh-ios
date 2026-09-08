import XCTest
@testable import HermesMobile

@MainActor
final class LiveActivityTests: XCTestCase {
    func testSanitizesLiveActivityText() {
        let title = AgentRunActivitySanitizer.sessionTitle("  A very long Hermes session title with\nmultiple lines and extra words  ")
        let activity = AgentRunActivitySanitizer.activityLine("Reading /Users/example/project/Secrets.swift\nwith details")
        let excerpt = AgentRunActivitySanitizer.responseExcerpt(String(repeating: "A", count: 180))

        XCTAssertFalse(title.contains("\n"))
        XCTAssertLessThanOrEqual(title.count, AgentRunActivitySanitizer.maximumSessionTitleCharacters)
        XCTAssertFalse(activity.contains("\n"))
        XCTAssertLessThanOrEqual(activity.count, AgentRunActivitySanitizer.maximumActivityCharacters)
        XCTAssertLessThanOrEqual(excerpt.count, AgentRunActivitySanitizer.maximumExcerptCharacters)
    }

    func testMapsToolNamesToSafeStatuses() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityStateReducer.initialState(
            sessionID: "session-abc",
            sessionTitle: "Build fixes",
            startedAt: startedAt
        )

        let command = AgentRunActivityStateReducer.toolStarted(name: "shell_command", state: state)
        XCTAssertEqual(command.status, .runningCommand)
        XCTAssertEqual(command.currentActivity, "Running command")

        let search = AgentRunActivityStateReducer.toolStarted(name: "ripgrep_search", state: state)
        XCTAssertEqual(search.status, .searchingFiles)
        XCTAssertEqual(search.currentActivity, "Searching files")

        let generic = AgentRunActivityStateReducer.toolStarted(name: "apply_patch", state: state)
        XCTAssertEqual(generic.status, .usingTool)
        XCTAssertEqual(generic.currentActivity, "Using apply patch")
    }

    func testElapsedTimeFormatterUsesStableClockLabels() {
        let startedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            "00:00"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 106)
            ),
            "00:06"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 190)
            ),
            "01:30"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 3_761)
            ),
            "1:01:01"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 99)
            ),
            "00:00"
        )
    }

    func testLiveActivityReusePolicyRequiresMatchingSessionAndStream() {
        XCTAssertTrue(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-1"
            )
        )
        XCTAssertTrue(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: " stream-1 ",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-1"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: nil,
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "other-session",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
    }

    func testActiveLiveActivityStatesCarryRenderableText() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 106)
        let initial = AgentRunActivityStateReducer.initialState(
            sessionID: "session-abc",
            sessionTitle: "Active render",
            startedAt: startedAt
        )
        let states = [
            initial,
            AgentRunActivityStateReducer.reasoning("Thinking through the plan", state: initial, now: later),
            AgentRunActivityStateReducer.toolStarted(name: "ripgrep_search", state: initial, now: later),
            AgentRunActivityStateReducer.toolCompleted(state: initial, now: later),
            AgentRunActivityStateReducer.waitingForApproval(state: initial, now: later),
            AgentRunActivityStateReducer.waitingForClarification(state: initial, now: later),
            AgentRunActivityStateReducer.appendingToken("Hello", to: initial, now: later),
            AgentRunActivityStateReducer.settingInterimAssistant("Drafting the answer", on: initial, now: later)
        ]

        for state in states {
            XCTAssertFalse(state.isFinal)
            XCTAssertFalse(state.sessionTitle.isEmpty)
            XCTAssertFalse(state.currentActivity.isEmpty)
            XCTAssertGreaterThanOrEqual(state.updatedAt, state.startedAt)
            XCTAssertFalse(
                AgentRunElapsedTimeFormatter.label(
                    startedAt: state.startedAt,
                    updatedAt: state.updatedAt
                ).isEmpty
            )
        }
    }

    func testUpdatingSessionTitlePreservesLiveActivityState() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Untitled Session",
            status: .searchingFiles,
            currentActivity: "Searching files",
            responseExcerpt: "Looking through the repo.",
            startedAt: startedAt,
            updatedAt: startedAt,
            isStale: true
        )

        let updated = AgentRunActivityStateReducer.updatingSessionTitle(
            "Generated repo audit title",
            state: state,
            now: Date(timeIntervalSince1970: 130)
        )

        XCTAssertEqual(updated.sessionTitle, "Generated repo audit title")
        XCTAssertEqual(updated.status, .searchingFiles)
        XCTAssertEqual(updated.currentActivity, "Searching files")
        XCTAssertEqual(updated.responseExcerpt, "Looking through the repo.")
        XCTAssertEqual(updated.startedAt, startedAt)
        XCTAssertEqual(updated.updatedAt, Date(timeIntervalSince1970: 130))
        XCTAssertTrue(updated.isStale)
    }

    func testBuildsAndParsesSessionDeepLink() throws {
        let url = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: "session-abc"))
        let scheme = HermesDeepLink.scheme

        XCTAssertEqual(url.scheme, scheme)
        XCTAssertEqual(url.host, "session")
        XCTAssertEqual(HermesDeepLink.sessionID(from: url), "session-abc")
        XCTAssertEqual(HermesDeepLink.sessionID(from: URL(string: "\(scheme)://session/session-xyz")!), "session-xyz")
        XCTAssertNil(HermesDeepLink.sessionID(from: HermesShareDraft.openURL))
    }

    func testSessionDeepLinkURLPercentEncodesSessionID() throws {
        let sessionID = "session & /?=✓"
        let url = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: sessionID))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.scheme, HermesDeepLink.scheme)
        XCTAssertEqual(url.host, "session")
        XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "id", value: sessionID)])
        XCTAssertFalse(url.absoluteString.contains(sessionID))
    }

    func testChatViewModelLiveActivityLifecycleUsesInjectedManager() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: nil)
        ])
        await fixture.emit("reasoning.delta", payload: ["text": .string("I should inspect failures.")])
        await fixture.emit("tool.start", payload: ["name": .string("shell_command")])
        await fixture.emit("message.delta", payload: ["text": .string("Done.")])
        await fixture.emit("tool.complete", payload: ["name": .string("shell_command")])
        await fixture.emit("message.complete", payload: ["status": .string("complete")])

        XCTAssertEqual(manager.updates, [
            .reasoning("I should inspect failures."),
            .toolStarted(name: "shell_command"),
            .toolCompleted
        ])
        XCTAssertEqual(manager.ends.last, SpyAgentLiveActivityManager.End(
            status: .complete,
            activity: "Response complete",
            errorSummary: nil
        ))
        XCTAssertNil(fixture.viewModel.activeStreamID)
        XCTAssertEqual(fixture.viewModel.responseCompletionHapticTrigger, 1)
        await fixture.runtime.stop()
    }

    func testChatViewModelSuppressesLiveActivityResponseExcerptsByDefault() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        await fixture.emit("message.delta", payload: ["text": .string("Private token.")])
        await fixture.emit("message.interim", payload: ["text": .string("Private interim."), "already_streamed": .bool(false)])
        fixture.viewModel.flushPendingStreamingContent()

        XCTAssertTrue(manager.updates.isEmpty)
        XCTAssertTrue(fixture.viewModel.messages.contains { $0.content?.contains("Private token.") == true })
        await fixture.runtime.stop()
    }

    func testChatViewModelCanOptIntoLiveActivityResponseExcerpts() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        fixture.viewModel.setShowsLiveActivityResponseExcerpts(true)
        await fixture.emit("message.start")
        await fixture.emit("message.delta", payload: ["text": .string("Visible token.")])
        await fixture.emit("message.interim", payload: ["text": .string("Visible interim."), "already_streamed": .bool(false)])

        XCTAssertEqual(manager.updates, [
            .token("Visible token."),
            .interimAssistant("Visible interim.")
        ])
        await fixture.runtime.stop()
    }

    func testDisablingLiveActivityResponseExcerptsClearsActiveExcerpt() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        fixture.viewModel.setShowsLiveActivityResponseExcerpts(true)
        await fixture.emit("message.start")
        await fixture.emit("message.delta", payload: ["text": .string("Visible token.")])
        fixture.viewModel.setShowsLiveActivityResponseExcerpts(false)

        XCTAssertEqual(manager.updates, [
            .token("Visible token."),
            .clearResponseExcerpt
        ])
        await fixture.runtime.stop()
    }

    func testFollowupMessageStartsNewLiveActivityAfterCompletedResponse() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        await fixture.emit("message.delta", payload: ["text": .string("First answer.")])
        await fixture.emit("message.complete", payload: ["status": .string("complete")])

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(fixture.viewModel.activeStreamID)
        await fixture.emit("message.start")

        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: nil),
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: nil)
        ])
        await fixture.runtime.stop()
    }

    // Retired WebUI status-refresh coverage maps to the direct recovery tests below:
    // completion/text convergence -> testDirectIdleRecoveryEndsWithoutClaimingSuccessAndAllowsFollowup
    // unknown/running/read failure -> testDirectRecoveryRequiresExplicitIdleAndSuccessfulCanonicalRead

    func testDirectIdleRecoveryEndsWithoutClaimingSuccessAndAllowsFollowup() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        await fixture.emit("message.delta", payload: ["text": .string("Partial answer")])
        fixture.viewModel.flushPendingStreamingContent()
        XCTAssertEqual(fixture.viewModel.messages.compactMap(\.content), ["Partial answer"])
        fixture.transcript.messages = [
            ChatMessage(role: "user", content: "Original prompt", timestamp: 1,
                messageId: "1"),
            ChatMessage(role: "assistant", content: "Complete durable answer", timestamp: 2,
                messageId: "2")
        ]
        XCTAssertEqual(manager.starts.count, 1)
        fixture.transport.setRunning(false)

        try await fixture.runtime.reconnect()
        _ = await fixture.viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(manager.ends, [.init(status: .ended, activity: "No longer running", errorSummary: nil)])
        XCTAssertEqual(fixture.viewModel.messages.compactMap(\.content),
            ["Original prompt", "Complete durable answer"])
        XCTAssertEqual(fixture.viewModel.messages.compactMap(\.messageId), ["1", "2"])
        XCTAssertFalse(fixture.viewModel.messages.contains { $0.content == "Partial answer" })
        XCTAssertEqual(fixture.transport.methods(), ["session.resume", "session.resume"])
        XCTAssertFalse(fixture.transport.methods().contains("prompt.submit"))
        XCTAssertNil(fixture.viewModel.activeStreamID)
        try await fixture.runtime.reconnect()
        XCTAssertEqual(manager.ends.count, 1, "Repeated idle recovery cannot finalize twice")

        await fixture.emit("message.start")
        XCTAssertEqual(manager.starts.count, 2)
        await fixture.emit("message.complete", payload: ["status": .string("complete")])
        XCTAssertEqual(manager.ends.last?.status, .complete)
        await fixture.runtime.stop()
    }

    func testDirectRecoveryAndTerminalCannotEndSiblingActivity() async throws {
        let manager = SpyAgentLiveActivityManager()
        let first = try await makeDirectActivityFixture(manager: manager, sessionID: "first")
        let sibling = try await makeDirectActivityFixture(manager: manager, sessionID: "sibling")
        await first.emit("message.start")
        await sibling.emit("message.start")
        first.transport.setRunning(false)
        try await first.runtime.reconnect()
        XCTAssertTrue(manager.ends.isEmpty)

        await first.emit("message.start")
        await sibling.emit("message.start")
        await first.emit("message.complete", payload: ["status": .string("cancelled")])
        XCTAssertTrue(manager.ends.isEmpty)
        await sibling.emit("message.complete", payload: ["status": .string("cancelled")])
        XCTAssertEqual(manager.ends.map(\.status), [.cancelled])
        await first.runtime.stop()
        await sibling.runtime.stop()
    }

    func testBufferedTerminalWinsOverNeutralIdleRecovery() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        fixture.transport.setRunning(false)
        fixture.transport.emitTerminalOnResume()
        fixture.transcript.beforeRead = {
            fixture.transcript.beforeRead = nil
            for _ in 0..<1000 {
                if fixture.runtime.bufferedEventCountForTesting > 0 { break }
                await Task.yield()
            }
            XCTAssertEqual(fixture.runtime.bufferedEventCountForTesting, 1)
            // The canonical read is still behind the reconnect barrier here.
            XCTAssertTrue(manager.ends.isEmpty)
        }

        try await fixture.runtime.reconnect()
        fixture.transcript.beforeRead = nil

        XCTAssertEqual(manager.ends.map(\.status), [.complete])
        await fixture.runtime.stop()
    }

    func testDirectRecoveryRequiresExplicitIdleAndSuccessfulCanonicalRead() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        fixture.transport.setRunning(nil)
        try await fixture.runtime.reconnect()
        XCTAssertTrue(manager.ends.isEmpty)
        fixture.transport.setRunning(true)
        try await fixture.runtime.reconnect()
        XCTAssertTrue(manager.ends.isEmpty)

        fixture.transport.setRunning(false)
        fixture.transcript.fails = true
        do {
            try await fixture.runtime.reconnect()
            XCTFail("Canonical read failure must fail recovery")
        } catch { }
        XCTAssertTrue(manager.ends.isEmpty)
        fixture.transcript.fails = false
        fixture.transcript.canonicalID = "different-session"
        do {
            try await fixture.runtime.reconnect()
            XCTFail("Changed canonical identity must invalidate the recovered binding")
        } catch { }
        XCTAssertTrue(manager.ends.isEmpty)
        await fixture.runtime.stop()
    }

    func testDirectRecoveryCannotEndActivityAfterOwnerInvalidation() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        fixture.viewModel.invalidateDirectConversation()
        fixture.transport.setRunning(false)

        try await fixture.runtime.reconnect()

        XCTAssertTrue(manager.ends.isEmpty)
        await fixture.runtime.stop()
    }

    func testEndedActivityIsFinalNeutralAndPreservesExcerpt() throws {
        let initial = AgentRunActivityStateReducer.initialState(sessionID: "session", sessionTitle: "Work")
        let responding = AgentRunActivityStateReducer.appendingToken("Partial answer", to: initial)
        let ended = AgentRunActivityStateReducer.final(
            status: .ended, activity: "No longer running", state: responding
        )
        XCTAssertTrue(ended.isFinal)
        XCTAssertFalse(ended.isStale)
        XCTAssertNil(ended.errorSummary)
        XCTAssertEqual(ended.responseExcerpt, "Partial answer")
        XCTAssertEqual(ended.status.title, "Ended")
        XCTAssertEqual(ended.status.compactTitle, "Ended")
        XCTAssertEqual(try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(ended)), ended)
    }

    private func makeDirectActivityFixture(
        manager: SpyAgentLiveActivityManager,
        sessionID: String = "session-abc"
    ) async throws -> DirectActivityFixture {
        let server = try XCTUnwrap(URL(string: "https://activity.example.test"))
        let transport = DirectActivityTransport(sessionID: sessionID)
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink)
            return transport
        }
        let transcript = DirectActivityTranscript()
        let controller = GatewayConversationController(
            runtime: runtime, storedID: sessionID, profile: "default",
            loadTranscript: { id, _, _, _ in
                await transcript.beforeRead?()
                if transcript.fails { throw DirectSessionError.invalidResponse }
                return DirectHermesTranscriptPage(
                    sessionID: transcript.canonicalID ?? id,
                    messages: transcript.messages,
                    pagination: nil
                )
            }
        )
        try await controller.open()
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: sessionID, title: "Live work"),
            server: server, liveActivityManager: manager,
            gatewayRuntimeProvider: { _ in runtime }, initialDirectConversation: controller
        )
        return DirectActivityFixture(viewModel: viewModel, runtime: runtime, transport: transport, transcript: transcript)
    }

    func testFinalLiveActivityStateKeepsExcerptVisible() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Live work",
            status: .responding,
            currentActivity: "Writing response",
            responseExcerpt: "Here is the answer.",
            startedAt: startedAt,
            updatedAt: startedAt
        )

        let finalState = AgentRunActivityStateReducer.final(
            status: .complete,
            activity: "Response complete",
            state: state,
            now: Date(timeIntervalSince1970: 120)
        )

        XCTAssertEqual(finalState.status, .complete)
        XCTAssertEqual(finalState.currentActivity, "Response complete")
        XCTAssertEqual(finalState.responseExcerpt, "Here is the answer.")
        XCTAssertTrue(finalState.isFinal)
        XCTAssertFalse(finalState.isStale)
    }

    func testClearingLiveActivityExcerptRemovesRenderableText() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Live work",
            status: .responding,
            currentActivity: "Writing response",
            responseExcerpt: "Sensitive answer text.",
            startedAt: startedAt,
            updatedAt: startedAt
        )

        let cleared = AgentRunActivityStateReducer.clearingResponseExcerpt(
            state: state,
            now: Date(timeIntervalSince1970: 130)
        )

        XCTAssertEqual(cleared.status, .responding)
        XCTAssertEqual(cleared.currentActivity, "Writing response")
        XCTAssertTrue(cleared.responseExcerpt.isEmpty)
        XCTAssertEqual(cleared.startedAt, startedAt)
        XCTAssertEqual(cleared.updatedAt, Date(timeIntervalSince1970: 130))
    }

    // #246 follow-up (PR #266 #3): the orphan reconciler must defer to a stream
    // whose SSE is live in this process. The manager tracks that ownership via the
    // lifecycle calls the coordinator already makes — set on `start`, cleared on
    // `markStale` (suspend/trouble) and `end` (finalize) — and
    // `orphanedActivities()` skips the tracked stream. This verifies the
    // ownership lifecycle directly (the ActivityKit-backed list isn't reachable in
    // unit tests, but the gate it consults is).
    @MainActor
    func testActiveConnectedStreamIDTracksLiveConnectionLifecycle() {
        let manager = AgentLiveActivityManager()

        // A live SSE connection claims the stream so the reconciler leaves it alone.
        manager.start(sessionID: "session-1", sessionTitle: "Title", streamID: "stream-abc")
        XCTAssertEqual(manager.activeConnectedStreamID, "stream-abc")

        // Suspension / transport trouble releases the claim — the suspended stream is
        // eligible for server-truth reconciliation again.
        manager.markStale()
        XCTAssertNil(manager.activeConnectedStreamID)

        // Reconnecting the same stream re-claims it.
        manager.start(sessionID: "session-1", sessionTitle: "Title", streamID: "stream-abc")
        XCTAssertEqual(manager.activeConnectedStreamID, "stream-abc")

        // Finalizing the run releases the claim.
        manager.end(status: .complete, activity: "Response complete")
        XCTAssertNil(manager.activeConnectedStreamID)
    }
}

@MainActor
private final class DirectActivityTranscript {
    var fails = false
    var canonicalID: String?
    var messages: [ChatMessage] = []
    var beforeRead: (@MainActor () async -> Void)?
}

@MainActor
private struct DirectActivityFixture {
    let viewModel: ChatViewModel
    let runtime: HermesServerRuntime
    let transport: DirectActivityTransport
    let transcript: DirectActivityTranscript

    func emit(_ type: String, payload: [String: JSONValue] = [:]) async {
        transport.emit(type, payload: payload)
        // The runtime delivers transport callbacks on its buffered event task.
        for _ in 0..<40 { await Task.yield() }
    }
}

private final class DirectActivityTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: String
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var running: Bool? = false
    private var generation = 0
    private var sequence = 0
    private var terminalOnResume = false
    private var recordedMethods: [String] = []

    init(sessionID: String) { self.sessionID = sessionID }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }
    func setRunning(_ value: Bool?) { lock.withLock { running = value } }
    func methods() -> [String] { lock.withLock { recordedMethods } }
    func emitTerminalOnResume() { lock.withLock { terminalOnResume = true } }
    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async { }
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { recordedMethods.append(method) }
        guard method == "session.resume" else { return .object([:]) }
        let shouldEmit = lock.withLock {
            let value = terminalOnResume
            terminalOnResume = false
            return value
        }
        if shouldEmit { emit("message.complete", payload: ["status": .string("complete")]) }
        return lock.withLock {
            var fields: [String: JSONValue] = [
                "session_id": .string("runtime-\(sessionID)"),
                "session_key": .string(sessionID)
            ]
            if let running { fields["running"] = .bool(running) }
            return .object(fields)
        }
    }
    func emit(_ type: String, payload: [String: JSONValue]) {
        let delivery = lock.withLock { () -> ((@Sendable (HermesGatewayEvent) -> Void)?, HermesGatewayEvent) in
            sequence += 1
            return (sink, HermesGatewayEvent(
                method: "event", type: type, sessionID: "runtime-\(sessionID)", sequence: sequence,
                payload: .object(payload), params: nil, connectionGeneration: generation
            ))
        }
        delivery.0?(delivery.1)
    }
}

private final class SpyAgentLiveActivityManager: AgentLiveActivityManaging {
    struct Start: Equatable {
        let sessionID: String
        let sessionTitle: String
        let streamID: String?
    }

    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var starts: [Start] = []
    private(set) var updates: [AgentLiveActivityEvent] = []
    private(set) var didMarkStale = false
    private(set) var ends: [End] = []
    private var directOwner: UUID?

    func start(sessionID: String, sessionTitle: String, streamID: String?) {
        directOwner = nil
        starts.append(Start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID))
    }

    func startDirect(owner: UUID, sessionID: String, sessionTitle: String) {
        start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: nil)
        directOwner = owner
    }

    func endDirect(owner: UUID, status: AgentRunActivityStatus, activity: String, errorSummary: String?) -> Bool {
        guard directOwner == owner else { return false }
        end(status: status, activity: activity, errorSummary: errorSummary)
        return true
    }

    func update(_ event: AgentLiveActivityEvent) {
        updates.append(event)
    }

    func markStale() {
        didMarkStale = true
    }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        directOwner = nil
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}
