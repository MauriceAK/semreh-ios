import XCTest
@testable import HermesMobile

@MainActor
final class ChatViewModelGoalTests: APIClientTestCase {
    func testGoalSendSubmitsServerMessageExactlyOnceAndKeepsDisplayNotices() async throws {
        let fixture = try await makeFixture(mode: .send, currentProfile: "work")
        await fixture.viewModel.uploadAttachment(data: Data("draft".utf8), filename: "draft.txt")
        let accepted = await fixture.viewModel.submitGoal(args: "resume")

        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.transport.methods.filter { $0 == "command.dispatch" }.count, 1)
        XCTAssertEqual(fixture.transport.methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertEqual(fixture.transport.submittedTexts, ["[Continuing toward your standing goal] next"])
        XCTAssertTrue(fixture.viewModel.messages.contains { $0.role == "local_notice" && $0.content == "Goal resumed" })
        XCTAssertTrue(fixture.viewModel.messages.contains { $0.role == "local_notice" && $0.content == "/goal resume" })
        XCTAssertTrue(fixture.viewModel.hasActivatedGoalCommand)
        XCTAssertEqual(fixture.viewModel.directPendingAttachments.map(\.displayFilename), ["draft.txt"])
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }

    func testGoalExecOutputDoesNotSubmitPrompt() async throws {
        let fixture = try await makeFixture(mode: .output("No active goal."), currentProfile: "work")
        let accepted = await fixture.viewModel.submitGoal(args: "status")
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.transport.methods.filter { $0 == "command.dispatch" }.count, 1)
        XCTAssertFalse(fixture.transport.methods.contains("prompt.submit"))
        XCTAssertTrue(fixture.viewModel.messages.contains {
            $0.role == "local_assistant" && $0.content == "No active goal."
        })
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }

    func testRunningPauseReturnsOutputWithoutPromptOrInterruptingCurrentStream() async throws {
        let fixture = try await makeFixture(mode: .output("Goal paused."), currentProfile: "work")
        fixture.transport.emitRunning()
        for _ in 0..<20 where fixture.controller.runState != .running {
            await Task.yield()
        }

        let accepted = await fixture.viewModel.submitGoal(args: "pause")

        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.transport.methods.filter { $0 == "command.dispatch" }.count, 1)
        XCTAssertFalse(fixture.transport.methods.contains("prompt.submit"))
        XCTAssertEqual(fixture.controller.runState, .running)
        XCTAssertTrue(fixture.viewModel.messages.contains {
            $0.role == "local_assistant" && $0.content == "Goal paused."
        })
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }

    func testRunningProfileMismatchRefusesBeforeCommandAndNeverSends() async throws {
        let fixture = try await makeFixture(mode: .send, currentProfile: "other")
        let accepted = await fixture.viewModel.submitGoal(args: "resume")
        XCTAssertFalse(accepted)
        XCTAssertFalse(fixture.transport.methods.contains { $0.hasPrefix("command.") || $0 == "prompt.submit" })
        XCTAssertTrue(fixture.viewModel.goalErrorMessage?.contains("not the profile running Hermes") == true)
        XCTAssertFalse(fixture.viewModel.hasActivatedGoalCommand)
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }

    func testBoundGoalStatusNoticeIsVisibleExactlyOnce() async throws {
        let fixture = try await makeFixture(mode: .output("unused"), currentProfile: "work")
        let event = HermesGatewayEvent(method: "event", type: "status.update",
            sessionID: "runtime-session", sequence: 41,
            payload: .object(["kind": .string("goal"), "text": .string("Goal turn 2 continues")]),
            params: nil, connectionGeneration: 1)
        fixture.viewModel.handleDirectEventForTesting(event)
        fixture.viewModel.handleDirectEventForTesting(event)
        XCTAssertEqual(fixture.viewModel.messages.filter {
            $0.role == "local_notice" && $0.content == "Goal turn 2 continues"
        }.count, 1)
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }

    func testReconnectDuringProfileReadRefusesBeforeDispatch() async throws {
        let gate = VMGoalHTTPGate()
        let fixture = try await makeFixture(mode: .send, currentProfile: "work", profileGate: gate)
        let submission = Task { await fixture.viewModel.submitGoal(args: "resume") }
        defer { gate.release() }
        guard await gate.waitUntilEntered() else {
            XCTFail("The active-profile request did not reach its bounded test gate")
            fixture.viewModel.invalidateDirectConversation()
            return
        }
        fixture.transport.emitClosed()
        for _ in 0..<20 { await Task.yield() }
        try await fixture.runtime.connect()
        gate.release()

        let accepted = await submission.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(fixture.transport.methods.contains { $0.hasPrefix("command.") || $0 == "prompt.submit" })
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }

    func testGoalCanBeFirstDraftActionWithoutPlaceholderPrompt() async throws {
        let fixture = try await makeFixture(
            mode: .output("Goal accepted."), currentProfile: "work", sessionID: nil,
            workspace: "/fixture/project", model: "fixture-model", provider: "fixture-provider",
            reasoning: "high"
        )
        let accepted = await fixture.viewModel.submitGoal(args: "Ship it")
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.transport.methods.filter { $0 == "session.create" }.count, 1)
        XCTAssertFalse(fixture.transport.methods.contains("prompt.submit"))
        let creation = try XCTUnwrap(fixture.transport.creationFields)
        XCTAssertEqual(creation["cwd"], .string("/fixture/project"))
        XCTAssertEqual(creation["model"], .string("fixture-model"))
        XCTAssertEqual(creation["provider"], .string("fixture-provider"))
        XCTAssertEqual(creation["reasoning_effort"], .string("high"))
        XCTAssertEqual(creation["profile"], .string("work"))
        XCTAssertEqual(creation["close_on_disconnect"], .bool(false))
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }

    func testStaleScopeAfterGoalDispatchReportsUnknownWithoutRetry() async throws {
        let fixture = try await makeFixture(mode: .staleAfterDispatch, currentProfile: "work")
        let accepted = await fixture.viewModel.submitGoal(args: "resume")
        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.transport.methods.filter { $0 == "command.dispatch" }.count, 1)
        XCTAssertFalse(fixture.transport.methods.contains("prompt.submit"))
        XCTAssertTrue(fixture.viewModel.goalErrorMessage?.contains("outcome is unknown") == true)
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }

    private func makeFixture(
        mode: VMGoalTransport.Mode,
        currentProfile: String,
        profileGate: VMGoalHTTPGate? = nil,
        sessionID: String? = "stored-session",
        workspace: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        reasoning: String? = nil
    ) async throws -> (
        viewModel: ChatViewModel, runtime: HermesServerRuntime, transport: VMGoalTransport,
        controller: GatewayConversationController
    ) {
        let transport = VMGoalTransport(mode: mode)
        let server = try XCTUnwrap(URL(string: "https://goal-vm.example.test"))
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink); return transport
        }
        let uncertaintyStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = GatewayConversationController(
            runtime: runtime,
            storedID: sessionID,
            profile: "work",
            promptUncertaintyStore: uncertaintyStore
        ) {
            id, _, _, _ in DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
        try await controller.open()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/active")
            profileGate?.enterAndWait()
            return apiTestJSONResponse("{\"active\":\"work\",\"current\":\"\(currentProfile)\"}", for: request)
        }
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: sessionID, title: "Goal", workspace: workspace,
                model: model, modelProvider: provider, reasoningEffort: reasoning, profile: "work"),
            server: server,
            client: client,
            liveActivityManager: VMGoalNoopLiveActivityManager(),
            gatewayRuntimeProvider: { _ in runtime },
            directAttachmentRecoveryMarkerStore: DirectGatewayAttachmentRecoveryMarkerStore(
                rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("VMGoal-\(UUID().uuidString)")
            ),
            promptUncertaintyStore: uncertaintyStore,
            initialDirectConversation: controller
        )
        return (viewModel, runtime, transport, controller)
    }
}

private final class VMGoalTransport: HermesGatewayTransport, @unchecked Sendable {
    enum Mode { case output(String), send, staleAfterDispatch }
    private let lock = NSLock()
    private let mode: Mode
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var generation = 0
    private var requestedMethods: [String] = []
    private var prompts: [String] = []
    var methods: [String] { lock.withLock { requestedMethods } }
    var submittedTexts: [String] { lock.withLock { prompts } }
    var creationFields: [String: JSONValue]? { lock.withLock { creation } }
    private var creation: [String: JSONValue]?

    init(mode: Mode) { self.mode = mode }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) { lock.withLock { self.sink = sink } }
    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async {}
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { requestedMethods.append(method) }
        switch method {
        case "session.create":
            lock.withLock { creation = params?.gatewayFields }
            return .object(["session_id": .string("runtime-created"), "session_key": .string("stored-created")])
        case "session.resume":
            return .object(["session_id": .string("runtime-session"), "session_key": .string("stored-session"), "running": .bool(false)])
        case "command.resolve":
            return .object(["canonical": .string("goal")])
        case "command.dispatch":
            switch mode {
            case .output(let text): return .object(["type": .string("exec"), "output": .string(text)])
            case .send:
                return .object(["type": .string("send"), "notice": .string("Goal resumed"),
                    "message": .string("[Continuing toward your standing goal] next"), "display": .string("/goal resume")])
            case .staleAfterDispatch:
                emitClosed()
                for _ in 0..<20 { await Task.yield() }
                return .object(["type": .string("exec"), "output": .string("stale")])
            }
        case "prompt.submit":
            let text = params?.gatewayFields["text"]?.gatewayString ?? ""
            lock.withLock { prompts.append(text) }
            return .object(["status": .string("streaming"), "session_id": .string("runtime-session")])
        default:
            return .object([:])
        }
    }

    func emitClosed() {
        let delivery = lock.withLock { (sink, generation) }
        delivery.0?(HermesGatewayEvent(method: "local", type: "transport.closed", sessionID: nil,
            sequence: 98, payload: .object([:]), params: nil, connectionGeneration: delivery.1))
    }

    func emitRunning() {
        let delivery = lock.withLock { (sink, generation) }
        delivery.0?(HermesGatewayEvent(method: "event", type: "message.start", sessionID: "runtime-session",
            sequence: 1, payload: .object([:]), params: nil, connectionGeneration: delivery.1))
    }

}

private final class VMGoalHTTPGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func enterAndWait() {
        condition.lock(); entered = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitUntilEntered() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !isEntered(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isEntered()
    }
    private func isEntered() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@MainActor
private final class VMGoalNoopLiveActivityManager: AgentLiveActivityManaging {
    func start(sessionID: String, sessionTitle: String, streamID: String?) {}
    func update(_ event: AgentLiveActivityEvent) {}
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}
