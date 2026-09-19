import XCTest
@testable import HermesMobile

@MainActor
final class ChatViewModelSkillTests: APIClientTestCase {
    func testInstalledSkillInvocationIsTemporarilyUnavailableWithoutCreatingOrSending() async throws {
        let fixture = try await makeFixture(mode: .invocation, currentProfile: "work")
        await fixture.viewModel.uploadAttachment(data: Data("draft".utf8), filename: "draft.txt")

        let result = await fixture.viewModel.executeSkillShortcutCommand(name: "review-code", args: "this patch")

        guard case .unsupported(let message) = result else { return XCTFail("Expected temporary refusal") }
        XCTAssertTrue(message.contains("temporarily unavailable"))
        XCTAssertFalse(fixture.transport.methods.contains { $0 == "session.create" || $0.hasPrefix("command.") || $0 == "prompt.submit" })
        XCTAssertTrue(fixture.viewModel.messages.isEmpty)
        XCTAssertEqual(fixture.viewModel.directPendingAttachments.map(\.displayFilename), ["draft.txt"])
        await cleanup(fixture)
    }

    func testSkillsCommandInvocationIsAlsoUnavailableWithoutDispatch() async throws {
        let fixture = try await makeFixture(mode: .output, currentProfile: "work")
        let result = await fixture.viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "skills")), args: "review-code status")
        guard case .unsupported(let message) = result else { return XCTFail("Expected temporary refusal") }
        XCTAssertTrue(message.contains("temporarily unavailable"))
        XCTAssertFalse(fixture.transport.methods.contains { $0 == "session.create" || $0.hasPrefix("command.") || $0 == "prompt.submit" })
        await cleanup(fixture)
    }

    func testUnknownShortcutUsesFreshScopedDiscoveryAndDoesNotDispatch() async throws {
        let fixture = try await makeFixture(mode: .invocation, currentProfile: "work")
        let result = await fixture.viewModel.executeSkillShortcutCommand(name: "missing", args: "hello")
        XCTAssertNil(result)
        XCTAssertTrue(fixture.transport.methods.filter { $0.hasPrefix("command.") }.isEmpty)
        XCTAssertEqual(fixture.requests.paths, ["/api/skills?profile=work"])
        await cleanup(fixture)
    }

    func testDirectSkillsQueryStillReturnsScopedReadOnlyResults() async throws {
        let fixture = try await makeFixture(mode: .invocation, currentProfile: "work")
        let result = await fixture.viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "skills")), args: "review")
        guard case .executed(let message) = result else { return XCTFail("Expected catalog result") }
        XCTAssertTrue(message?.contains("Review Code") == true)
        XCTAssertFalse(fixture.transport.methods.contains { $0 == "session.create" || $0.hasPrefix("command.") || $0 == "prompt.submit" })
        XCTAssertEqual(fixture.requests.paths, ["/api/skills?profile=work"])
        await cleanup(fixture)
    }

    func testDirectSkillDetailDoesNotAdvertiseInvocation() async throws {
        let fixture = try await makeFixture(mode: .invocation, currentProfile: "other")
        let result = await fixture.viewModel.executeSkillShortcutCommand(name: "review-code", args: "")
        guard case .executed(let message) = result else { return XCTFail("Expected local detail") }
        XCTAssertTrue(message?.contains("temporarily unavailable") == true)
        XCTAssertFalse(message?.contains("Send `/review-code <message>`") == true)
        XCTAssertFalse(fixture.transport.methods.contains { $0.hasPrefix("command.") || $0 == "prompt.submit" })
        await cleanup(fixture)
    }

    func testDelayedCatalogInvalidationDropsSuggestionsAndSingleflightRefusesBusy() async throws {
        let gate = VMSkillCatalogGate()
        let fixture = try await makeFixture(mode: .invocation, currentProfile: "work", catalogGate: gate)
        let first = Task {
            await fixture.viewModel.executeSkillShortcutCommand(name: "review-code", args: "this patch")
        }
        defer { gate.release() }
        guard await gate.waitUntilEntered() else { return XCTFail("Catalog request did not reach gate") }

        let busy = await fixture.viewModel.executeSkillShortcutCommand(name: "review-code", args: "other")
        guard case .unsupported(let message) = busy else { return XCTFail("Expected definite busy refusal") }
        XCTAssertTrue(message.contains("current skill invocation"))
        fixture.viewModel.invalidateDirectConversation()
        gate.release()
        _ = await first.value

        XCTAssertTrue(fixture.viewModel.skillSlashSuggestions.isEmpty)
        XCTAssertFalse(fixture.transport.methods.contains { $0 == "session.create" || $0.hasPrefix("command.") || $0 == "prompt.submit" })
        await fixture.runtime.stop()
    }

    func testDelayedFailedCatalogAfterInvalidationDoesNotPublishOldError() async throws {
        let gate = VMSkillCatalogGate()
        let fixture = try await makeFixture(mode: .invocation, currentProfile: "work",
            catalogGate: gate, catalogError: URLError(.cannotConnectToHost))
        let request = Task {
            await fixture.viewModel.executeSkillShortcutCommand(name: "review-code", args: "this patch")
        }
        defer { gate.release() }
        guard await gate.waitUntilEntered() else { return XCTFail("Catalog request did not reach gate") }
        fixture.viewModel.invalidateDirectConversation()
        gate.release()
        _ = await request.value

        XCTAssertNil(fixture.viewModel.lastError)
        XCTAssertTrue(fixture.viewModel.skillSlashSuggestions.isEmpty)
        XCTAssertFalse(fixture.transport.methods.contains { $0 == "session.create" || $0.hasPrefix("command.") || $0 == "prompt.submit" })
        await fixture.runtime.stop()
    }

    private func makeFixture(mode: VMSkillTransport.Mode, currentProfile: String,
        catalogGate: VMSkillCatalogGate? = nil, catalogError: Error? = nil) async throws -> (
        viewModel: ChatViewModel, runtime: HermesServerRuntime, transport: VMSkillTransport,
        requests: VMSkillRequestRecorder, controller: GatewayConversationController
    ) {
        let transport = VMSkillTransport(mode: mode)
        let server = try XCTUnwrap(URL(string: "https://skill-vm.example.test"))
        let runtime = try HermesServerRuntime(origin: server) { sink in transport.installSink(sink); return transport }
        let store = InMemoryDirectPromptDeliveryUncertaintyStore()
        let requests = VMSkillRequestRecorder()
        let client = makeClient { request in
            let path = request.url!.path + (request.url!.query.map { "?\($0)" } ?? "")
            requests.paths.append(path)
            if request.url?.path == "/api/skills" {
                catalogGate?.enterAndWait()
                if let catalogError { throw catalogError }
                return apiTestJSONResponse(#"[{"name":"Review Code","category":"development","description":"Review a patch","enabled":true}]"#, for: request)
            }
            if request.url?.path == "/api/sessions/stored-session/messages" {
                return apiTestJSONResponse(
                    #"{"session_id":"stored-session","messages":[{"id":7,"role":"user","content":"  opaque server scaffold\n","display_content":"/review-code this patch"}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":1}}"#,
                    for: request
                )
            }
            XCTAssertEqual(request.url?.path, "/api/profiles/active")
            return apiTestJSONResponse("{\"active\":\"work\",\"current\":\"\(currentProfile)\"}", for: request)
        }
        let controller = GatewayConversationController(runtime: runtime, client: client,
            storedID: "stored-session", profile: "work", promptUncertaintyStore: store)
        try await controller.open()
        requests.paths.removeAll()
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "stored-session", title: "Skill", profile: "work"),
            server: server, client: client, liveActivityManager: VMSkillNoopLiveActivityManager(),
            gatewayRuntimeProvider: { _ in runtime }, promptUncertaintyStore: store,
            initialDirectConversation: controller
        )
        return (viewModel, runtime, transport, requests, controller)
    }

    private func cleanup(_ fixture: (viewModel: ChatViewModel, runtime: HermesServerRuntime,
        transport: VMSkillTransport, requests: VMSkillRequestRecorder,
        controller: GatewayConversationController)) async {
        fixture.viewModel.invalidateDirectConversation()
        await fixture.runtime.stop()
    }
}

private final class VMSkillRequestRecorder {
    var paths: [String] = []
}

private final class VMSkillCatalogGate: @unchecked Sendable {
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
        condition.lock(); defer { condition.unlock() }; return entered
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private final class VMSkillTransport: HermesGatewayTransport, @unchecked Sendable {
    enum Mode { case invocation, output }
    private let lock = NSLock()
    private let mode: Mode
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var requested: [String] = []
    private var prompts: [String] = []
    init(mode: Mode) { self.mode = mode }
    var methods: [String] { lock.withLock { requested } }
    var submittedTexts: [String] { lock.withLock { prompts } }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) { lock.withLock { self.sink = sink } }
    func connect() async throws {}
    func close() async {}
    func connectionIdentifier() async -> Int? { 1 }
    func emitCompletion() {
        let target = lock.withLock { sink }
        target?(HermesGatewayEvent(method: "event", type: "message.complete", sessionID: "runtime-session",
            sequence: 1, payload: .object(["status": .string("complete")]), params: nil,
            connectionGeneration: 1))
    }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { requested.append(method) }
        switch method {
        case "session.resume":
            return .object(["session_id": .string("runtime-session"), "session_key": .string("stored-session"), "running": .bool(false)])
        case "command.resolve":
            throw HermesGatewayError.server(code: 4011, message: "unknown command", data: nil,
                method: method, requestID: "skill-resolve", server: nil)
        case "command.dispatch":
            if case .output = mode { return .object(["type": .string("exec"), "output": .string("Skill output")]) }
            return .object(["type": .string("skill"), "name": .string("Review Code"),
                "message": .string("  opaque server scaffold\n"), "display": .string("/review-code this patch")])
        case "prompt.submit":
            let text: String
            if case .string(let raw)? = params?.gatewayFields["text"] { text = raw } else { text = "" }
            lock.withLock { prompts.append(text) }
            return .object(["status": .string("streaming"), "session_id": .string("runtime-session")])
        default: throw DirectSessionError.invalidResponse
        }
    }
}

@MainActor
private final class VMSkillNoopLiveActivityManager: AgentLiveActivityManaging {
    func start(sessionID: String, sessionTitle: String, streamID: String?) {}
    func update(_ event: AgentLiveActivityEvent) {}
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}
