import Foundation
import Observation
import XCTest
@testable import HermesMobile

@MainActor
final class ChatActivityPresentationTests: XCTestCase {
    func testToolNamesAreExactAllowlistAndNeverExposePrivateContent() {
        XCTAssertEqual(ChatActivityPhase.tool(named: "web_search"), .searching)
        XCTAssertEqual(ChatActivityPhase.tool(named: "search_files"), .searching)
        for name in ["read_file", "web_extract", "browser_snapshot", "browser_get_images", "browser_vision"] {
            XCTAssertEqual(ChatActivityPhase.tool(named: name), .reading)
        }
        for name in [nil, "terminal", "memory", "mcp__private_search", "read_file /private/secret", "Searching private notes"] {
            XCTAssertEqual(ChatActivityPhase.tool(named: name), .working)
        }
    }

    func testUnknownSpinnerTextCannotPublishHeaderOrTranscriptPerUpdate() {
        let vm = makeViewModel()
        emit(vm, "message.start")
        let revision = vm.transcriptRenderRevision
        let publications = ActivityPublicationCounter()
        withObservationTracking { _ = vm.headerActivityPhase } onChange: { publications.increment() }
        for index in 0..<100 {
            emit(vm, "thinking.delta", ["text": .string("Private decorative spinner \(index)")])
        }
        XCTAssertEqual(vm.headerActivityPhase, .working)
        XCTAssertEqual(publications.count, 0)
        XCTAssertEqual(vm.transcriptRenderRevision, revision)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertTrue(vm.liveReasoningText.isEmpty)
    }

    func testMixedInterimReasoningToolsAndFinalKeepExactBodiesAndCoarsePhases() {
        let vm = makeViewModel()
        emit(vm, "message.start")
        let interim = "Got it, looking into that. Café 👩🏽‍💻\n"
        let reasoning = "Actual provider reasoning, preserved separately."
        emit(vm, "reasoning.delta", ["text": .string(reasoning)])
        emit(vm, "message.interim", ["text": .string(interim), "already_streamed": .bool(true)])
        XCTAssertEqual(vm.messages.filter { $0.role == "assistant" }.compactMap(\.content), [interim])
        XCTAssertEqual(vm.headerActivityPhase, .working)

        emit(vm, "tool.start", tool(id: "search", name: "web_search"))
        XCTAssertEqual(vm.headerActivityPhase, .searching)
        emit(vm, "tool.start", tool(id: "read", name: "read_file"))
        XCTAssertEqual(vm.headerActivityPhase, .reading)
        emit(vm, "thinking.delta", ["text": .string("a decorative spinner")])
        XCTAssertEqual(vm.headerActivityPhase, .reading)
        emit(vm, "tool.complete", tool(id: "read", name: "read_file"))
        XCTAssertEqual(vm.headerActivityPhase, .searching, "An unfinished concurrent tool still owns activity")
        emit(vm, "tool.complete", tool(id: "search", name: "web_search"))
        XCTAssertEqual(vm.headerActivityPhase, .working)

        emit(vm, "message.delta", ["text": .string("Exact answer")])
        XCTAssertEqual(vm.headerActivityPhase, .replying)
        let publications = ActivityPublicationCounter()
        withObservationTracking { _ = vm.headerActivityPhase } onChange: { publications.increment() }
        for _ in 0..<40 { emit(vm, "message.delta", ["text": .string(".")]) }
        emit(vm, "thinking.delta", ["text": .string("random spinner")])
        XCTAssertEqual(publications.count, 0, "Received text and decorative spinner changes must not republish the header")
        emit(vm, "message.complete", ["status": .string("complete")])
        XCTAssertNil(vm.headerActivityPhase)
        XCTAssertNil(vm.displayedHeaderActivityPhase)
        XCTAssertEqual(vm.messages.filter { $0.role == "assistant" }.compactMap(\.content).filter { !$0.isEmpty },
                       [interim, "Exact answer" + String(repeating: ".", count: 40)])
        XCTAssertEqual(vm.messages.compactMap(\.reasoning).joined(), reasoning)
    }

    func testOnlyExplicitCompactionKindUsesSemanticStatusAndReadyClearsIt() async throws {
        let (vm, runtime, _, _) = try makeRuntimeFixture()
        try await runtime.connect()
        emit(vm, "status.update", ["kind": .string("compacting"), "text": .string("private history details")])
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .summarizing)
        let revision = vm.transcriptRenderRevision
        for kind in ["status", "process", "loop", "future"] {
            emit(vm, "status.update", ["kind": .string(kind), "text": .string("Reading private data")])
            XCTAssertEqual(vm.headerActivityPhase, .summarizing)
        }
        XCTAssertEqual(vm.transcriptRenderRevision, revision)
        emit(vm, "status.update", ["kind": .string("status"), "text": .string("ready")])
        XCTAssertNil(vm.headerActivityPhase)
        XCTAssertTrue(vm.messages.isEmpty)
        await runtime.stop()
    }

    func testIdleCompactionDisappearsWhenDisconnectedAndCannotReviveAcrossGeneration() async throws {
        let (vm, runtime, controller, transport) = try makeRuntimeFixture()
        try await runtime.connect()
        emit(vm, "status.update", ["kind": .string("compacting")])
        XCTAssertEqual(controller.runState, .idle)
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .summarizing)
        let publications = ActivityPublicationCounter()
        withObservationTracking { _ = vm.displayedHeaderActivityPhase } onChange: { publications.increment() }

        await transport.setConnectFailure(true)
        do {
            try await runtime.reconnect()
            XCTFail("Controlled reconnect must fail")
        } catch { }
        XCTAssertEqual(runtime.state, .disconnected)
        XCTAssertNil(vm.displayedHeaderActivityPhase, "Idle run state alone cannot keep a disconnected compaction visible")
        XCTAssertGreaterThan(publications.count, 0, "Runtime readiness must invalidate the observed header projection")
        await transport.setConnectFailure(false)
        try await runtime.reconnect()
        XCTAssertEqual(runtime.state, .ready)
        XCTAssertNil(vm.displayedHeaderActivityPhase, "A new connection cannot revive an old compaction status")

        emit(vm, "status.update", ["kind": .string("compacting")])
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .summarizing)
        controller.onResume?(nil)
        XCTAssertNil(vm.headerActivityPhase, "The owned authoritative resume retires previous activity")
        await runtime.stop()
    }

    func testHeldSubmitHasNoActivityBeforeAcknowledgementAndUnknownOutcomeStaysQuiet() async throws {
        for accepted in [true, false] {
            let submitted = expectation(description: "Controlled prompt reaches transport")
            let (vm, runtime, controller, transport) = try makeRuntimeFixture {
                submitted.fulfill()
            }
            let send = Task { try await controller.submit("Controlled prompt") }
            await fulfillment(of: [submitted], timeout: 2)
            XCTAssertEqual(controller.runState, .submitting)
            XCTAssertNil(vm.headerActivityPhase)
            XCTAssertNil(vm.displayedHeaderActivityPhase, "Dispatch alone is not evidence the bot is working")
            let publications = ActivityPublicationCounter()
            withObservationTracking { _ = vm.displayedHeaderActivityPhase } onChange: { publications.increment() }
            await transport.finishPrompt(accepted: accepted)
            do {
                try await send.value
                XCTAssertTrue(accepted)
            } catch { XCTAssertFalse(accepted) }
            XCTAssertEqual(controller.runState, accepted ? .running : .deliveryUnknown)
            XCTAssertEqual(vm.displayedHeaderActivityPhase, accepted ? .working : nil)
            XCTAssertGreaterThan(publications.count, 0)
            await runtime.stop()
        }
    }

    func testAuthoritativeRunningResumeAfterCompletedTurnRestoresHeaderWithoutMessageStartReplay() async throws {
        let (vm, runtime, controller, transport) = try makeRuntimeFixture(storedID: "activity-durable")
        try await runtime.connect()
        emit(vm, "message.start")
        emit(vm, "message.complete", ["status": .string("complete")])
        XCTAssertNil(vm.displayedHeaderActivityPhase)

        await transport.setResumeRunning(true)
        try await runtime.reconnect()
        XCTAssertEqual(controller.runState, .running)
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .working,
                       "An authoritative externally started turn cannot inherit the old header's terminal flag")
        emit(vm, "tool.start", tool(id: "resumed-read", name: "read_file"))
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .reading)
        await runtime.stop()
    }

    func testCompleteCancelledErrorAndNewTurnRetireActivityWithoutTranscriptStatus() {
        for status in ["complete", "cancelled", "interrupted"] {
            let vm = makeViewModel()
            emit(vm, "message.start")
            emit(vm, "thinking.delta", ["text": .string("do not publish this as chat")])
            emit(vm, "message.complete", ["status": .string(status)])
            XCTAssertNil(vm.headerActivityPhase, status)
            emit(vm, "message.complete", ["status": .string(status)])
            XCTAssertNil(vm.headerActivityPhase, "Duplicate completion stays idle")
            emit(vm, "message.start")
            XCTAssertEqual(vm.headerActivityPhase, .working)
            emit(vm, "error", ["message": .string("Controlled failure")])
            XCTAssertNil(vm.headerActivityPhase)
            XCTAssertTrue(vm.messages.isEmpty)
        }
    }

    func testRunningNonterminalErrorDoesNotSuppressLaterToolOrReplyActivity() async throws {
        let (vm, runtime, controller, transport) = try makeRuntimeFixture(storedID: "activity-durable")
        await transport.setResumeRunning(true)
        try await runtime.connect()
        XCTAssertEqual(controller.runState, .running)
        emit(vm, "tool.start", tool(id: "initial-read", name: "read_file"))
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .reading)

        emit(vm, "error", ["message": .string("Controlled recoverable tool error")])
        XCTAssertNil(vm.headerActivityPhase)
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .working,
                       "An error notification alone does not end the authoritative running turn")
        emit(vm, "tool.start", tool(id: "recovery-search", name: "web_search"))
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .searching)
        emit(vm, "message.delta", ["text": .string("Recovered reply")])
        XCTAssertEqual(vm.displayedHeaderActivityPhase, .replying)
        emit(vm, "message.complete", ["status": .string("complete")])
        XCTAssertNil(vm.displayedHeaderActivityPhase)
        XCTAssertEqual(vm.messages.filter { $0.role == "assistant" }.compactMap(\.content), ["Recovered reply"])
        await runtime.stop()
    }

    func testQuietPendingPreservesTruthfulDistinctDeliveryStates() {
        XCTAssertFalse(LocalMessageDelivery.sending.showsVisibleLabel)
        XCTAssertNotNil(LocalMessageDelivery.sending.label, "Accessibility still describes an unacknowledged send")
        XCTAssertFalse(LocalMessageDelivery.accepted.showsVisibleLabel)
        XCTAssertNil(LocalMessageDelivery.accepted.label)
        XCTAssertTrue(LocalMessageDelivery.notSent.showsVisibleLabel)
        XCTAssertTrue(LocalMessageDelivery.unconfirmed.showsVisibleLabel)
        XCTAssertNotEqual(LocalMessageDelivery.unconfirmed.label, LocalMessageDelivery.notSent.label)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(session: SessionSummary(sessionId: "activity-fixture", title: "Activity"),
                      server: URL(string: "https://example.test")!,
                      gatewayRuntimeProvider: { _ in throw DirectSessionError.invalidResponse })
    }

    private func makeRuntimeFixture(storedID: String? = nil, onPrompt: @escaping @Sendable () -> Void = {}) throws
        -> (ChatViewModel, HermesServerRuntime, GatewayConversationController, ActivityGatewayTransport) {
        let server = URL(string: "https://example.test")!
        let transport = ActivityGatewayTransport(onPrompt: onPrompt)
        let runtime = try HermesServerRuntime(origin: server) { _ in transport }
        let uncertainty = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = GatewayConversationController(runtime: runtime, storedID: storedID,
            promptUncertaintyStore: uncertainty) { id, _, _, _ in
                DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
            }
        let vm = ChatViewModel(session: SessionSummary(sessionId: storedID, title: "Activity"), server: server,
            gatewayRuntimeProvider: { _ in runtime }, promptUncertaintyStore: uncertainty,
            initialDirectConversation: controller)
        return (vm, runtime, controller, transport)
    }

    private func emit(_ vm: ChatViewModel, _ type: String, _ payload: [String: JSONValue] = [:]) {
        vm.handleDirectEventForTesting(HermesGatewayEvent(method: "event", type: type,
            sessionID: "activity-fixture", sequence: nil, payload: .object(payload), params: nil))
    }

    private func tool(id: String, name: String) -> [String: JSONValue] {
        ["tool_id": .string(id), "name": .string(name),
         "args": .object(["private": .string("never expose tool arguments")])]
    }
}

private actor ActivityGatewayTransport: HermesGatewayTransport {
    private let onPrompt: @Sendable () -> Void
    private var generation = 0
    private var connected = false
    private var failConnect = false
    private var resumeRunning = false
    private var pendingPrompt: CheckedContinuation<JSONValue?, Error>?

    init(onPrompt: @escaping @Sendable () -> Void) { self.onPrompt = onPrompt }
    func setConnectFailure(_ value: Bool) { failConnect = value }
    func setResumeRunning(_ value: Bool) { resumeRunning = value }
    func connect() async throws {
        if failConnect { throw HermesGatewayError.closed }
        generation += 1
        connected = true
    }
    func close() async { connected = false }
    func connectionIdentifier() async -> Int? { connected ? generation : nil }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        if method == "session.create" {
            return .object(["session_id": .string("activity-runtime"), "session_key": .string("activity-durable")])
        }
        if method == "session.resume" {
            return .object(["session_id": .string("activity-runtime"), "session_key": .string("activity-durable"),
                            "running": .bool(resumeRunning)])
        }
        if method == "prompt.submit" {
            return try await withCheckedThrowingContinuation { continuation in
                pendingPrompt = continuation
                onPrompt()
            }
        }
        throw DirectSessionError.invalidResponse
    }
    func finishPrompt(accepted: Bool) {
        if accepted { pendingPrompt?.resume(returning: .object(["status": .string("streaming")])) }
        else { pendingPrompt?.resume(throwing: HermesGatewayError.transport("Controlled lost acknowledgement")) }
        pendingPrompt = nil
    }
}

private final class ActivityPublicationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
