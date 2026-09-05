import XCTest
@testable import HermesMobile

@MainActor
final class ChatViewModelDirectGatewayTests: APIClientTestCase {
    func testDirectComposerLoadsProfileInventoryAndStagesDraftChoicesUntilFirstSend() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/api/model/options" {
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "profile" }?.value, "work")
                XCTAssertEqual(query?.first { $0.name == "explicit_only" }?.value, "true")
                return apiTestJSONResponse(#"{"model":"model-a","provider":"fixture","providers":[{"slug":"fixture","name":"Fixture","authenticated":true,"models":["model-a","model-b","model-b"],"capabilities":{"model-a":{"reasoning":false},"model-b":{"reasoning":true,"can_disable_reasoning":false}}},{"slug":"unconfigured","authenticated":false,"models":["hidden"]}]}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/profiles")
            return apiTestJSONResponse(#"{"profiles":[{"name":"work"}],"active":"default"}"#, for: request)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: nil)
        await vm.loadComposerConfiguration()
        XCTAssertEqual(vm.selectedModelID, "model-a")
        XCTAssertEqual(vm.selectedModelProviderID, "fixture")
        XCTAssertEqual(vm.selectedProfileName, "work")
        XCTAssertFalse(vm.showsReasoningEffortControl)
        XCTAssertEqual(vm.modelCatalogGroups.count, 1)
        XCTAssertEqual(vm.modelCatalogGroups.first?.models.count, 2)
        XCTAssertTrue(fake.calls().isEmpty, "Configuration must not pre-create a runtime")
        let option = try XCTUnwrap(vm.modelCatalogGroups.first?.models.last)
        let selected = await vm.selectComposerModel(option)
        XCTAssertTrue(selected)
        XCTAssertTrue(vm.showsReasoningEffortControl)
        XCTAssertFalse(vm.supportedReasoningEfforts?.contains("none") ?? true)
        let invalidEffort = await vm.selectReasoningEffort("none")
        XCTAssertFalse(invalidEffort)
        let selectedEffort = await vm.selectReasoningEffort("high")
        XCTAssertTrue(selectedEffort)
        XCTAssertTrue(fake.calls().isEmpty)
        let sent = await vm.sendMessage("hello")
        XCTAssertTrue(sent)
        let create = try XCTUnwrap(fake.calls().first)
        XCTAssertEqual(create.method, "session.create")
        XCTAssertEqual(fields(create.params)?["model"], .string("model-b"))
        XCTAssertEqual(fields(create.params)?["provider"], .string("fixture"))
        XCTAssertEqual(fields(create.params)?["reasoning_effort"], .string("high"))
        XCTAssertEqual(Set(requests.values()), ["/api/model/options", "/api/profiles"])
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testExistingDirectChatConfigurationAndSuggestionsNeverUseLegacyOrGlobalWrites() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { _ in XCTFail("No legacy REST or global write is allowed"); throw URLError(.badURL) }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        let selected = await vm.selectComposerModel(ModelCatalogOption(id: "new", displayName: "New", providerID: "fixture"))
        let effort = await vm.selectReasoningEffort("high")
        let workspace = await vm.selectWorkspacePath("/disposable")
        XCTAssertFalse(selected)
        XCTAssertFalse(effort)
        XCTAssertFalse(workspace)
        XCTAssertNotNil(vm.composerConfigurationErrorMessage)
        await vm.refreshWorkspaceRoots()
        await vm.loadWorkspaceSuggestions(prefix: "/")
        await vm.loadPersonalitySuggestions()
        await vm.loadSkillSlashSuggestions()
        XCTAssertTrue(fake.calls().isEmpty)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectProfileChangeReturnsLocalDraftWithoutRetargetingOriginalChat() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { _ in XCTFail("Profile choice is local"); throw URLError(.badURL) }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        let profile = try JSONDecoder().decode(ProfileSummary.self, from: Data(#"{"name":"other"}"#.utf8))
        let outcome = await vm.switchProfile(profile, startNewSession: true)
        let draft = try XCTUnwrap(outcome?.session)
        XCTAssertNil(draft.sessionId)
        XCTAssertEqual(draft.profile, "other")
        XCTAssertTrue(vm.hasServerBackedSession)
        XCTAssertEqual(vm.selectedProfileTitle, "work")
        XCTAssertTrue(fake.calls().isEmpty)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testLocalDraftLoadDoesNotCreateOrCallREST() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            XCTFail("Opening a local draft must not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        await viewModel.loadMessages()

        XCTAssertTrue(fake.calls().isEmpty)
        XCTAssertTrue(requests.values().isEmpty)
        XCTAssertFalse(viewModel.hasServerBackedSession)
        XCTAssertTrue(viewModel.messages.isEmpty)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testFirstDirectSendCreatesOnceAndUsesRuntimePromptWithoutBookmarkingRuntimeID() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatViewModelDirectGatewayTests.\(UUID().uuidString)"))
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil, defaults: defaults)
        var canonicalID: String?
        viewModel.onDirectCanonicalID = { canonicalID = $0 }

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)

        let calls = fake.calls()
        XCTAssertEqual(calls.map(\.method), ["session.create", "prompt.submit"])
        XCTAssertEqual(fields(calls[1].params)?["session_id"], .string("runtime-1"))
        XCTAssertEqual(fields(calls[1].params)?["profile"], .string("work"))
        XCTAssertEqual(canonicalID, "durable-1")
        XCTAssertTrue(viewModel.hasServerBackedSession)
        XCTAssertTrue(requests.values().isEmpty)
        let retained = OpenChatSessionStore()
        _ = retained.adoptedViewModel(session: SessionSummary(sessionId: "durable-1", profile: "work"),
            server: testServer, creating: viewModel)
        XCTAssertEqual(retained.liveSessionIDs(for: testServer), ["durable-1"])
        XCTAssertTrue(retained.liveStreamIDs(for: testServer).isEmpty,
            "Direct liveness must never feed the legacy WebUI status watcher")
        let bookmarks = LiveRunBookmarkStore(defaults: defaults)
        XCTAssertNil(bookmarks.load(server: testServer, sessionID: "durable-1"))
        let serializedDefaults = defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }
            .compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertFalse(serializedDefaults.contains { $0.contains("runtime-1") })

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testStreamingEventRendersThenCanonicalTranscriptReplacesOptimisticRows() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            guard request.url?.path.contains("/api/sessions/durable-1/messages") == true else {
                XCTFail("Unexpected REST path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":[{"id":1,"role":"user","content":"hello","timestamp":1},{"id":2,"role":"assistant","content":"canonical answer","timestamp":2}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#,
                for: request
            )
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.messages.contains { $0.content == "streamed answer" } }
        XCTAssertTrue(viewModel.messages.contains { $0.content == "streamed answer" })

        fake.emitCompletion()
        await waitUntil { viewModel.messages.contains { $0.content == "canonical answer" } }

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["hello", "canonical answer"])
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testWrongSessionEventsAreIgnoredByDirectChatViewModel() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Wrong-session event test should not need transcript REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.messages.contains { $0.content == "streamed answer" } }
        fake.emit(ChatDirectEventFactory.event(sessionID: "other-runtime", type: "message.delta", sequence: 99, payload: ["text": .string("wrong answer")]))
        // An own-session sentinel proves the earlier wrong-session event has
        // passed through the FIFO consumer before checking the negative result.
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "session.usage", sequence: 100,
            payload: ["usage": .object(["input": .number(123)])]))
        await waitUntil { viewModel.contextWindowSnapshot?.inputTokens == 123 }
        viewModel.flushPendingStreamingContent()

        XCTAssertFalse(viewModel.messages.compactMap(\.content).joined().contains("wrong answer"))
        XCTAssertTrue(viewModel.messages.contains { $0.content == "streamed answer" })
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testRejectedDirectSteerDoesNotInterruptOrResendPrompt() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setSteerResponse(.object(["status": .string("rejected")]))
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Rejected steer should not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("running")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.activeStreamID != nil }
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "steer"))
        let result = await viewModel.executeSlashCommand(command, args: "follow-up")

        guard case .unsupported(let message) = result else {
            XCTFail("Expected rejected steer result")
            return
        }
        XCTAssertTrue(message.contains("rejected"))
        let methods = fake.calls().map(\.method)
        XCTAssertEqual(methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "session.steer" }.count, 1)
        XCTAssertFalse(methods.contains("session.interrupt"))
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testInvalidatedDirectChatCannotSendAgain() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Invalidated direct chat should not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        viewModel.invalidateDirectConversation()
        let didSend = await viewModel.sendMessage("stale")
        XCTAssertFalse(didSend)
        XCTAssertTrue(fake.calls().isEmpty)
        XCTAssertFalse(viewModel.hasServerBackedSession)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    private let testServer = URL(string: "https://fixture.example")!

    private func makeViewModel(
        client: APIClient,
        runtime: HermesServerRuntime,
        sessionID: String?,
        defaults: UserDefaults = .standard
    ) -> ChatViewModel {
        ChatViewModel(
            session: SessionSummary(sessionId: sessionID, title: "New Chat", profile: "work"),
            server: testServer,
            client: client,
            liveActivityManager: ChatDirectNoopLiveActivityManager(),
            userDefaults: defaults,
            gatewayRuntimeProvider: { _ in runtime }
        )
    }

    private func makeRuntime(_ fake: ChatDirectFakeTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: testServer) { sink in
            fake.installSink(sink)
            return fake
        }
    }

    private func fields(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value, case .object(let fields) = value else { return nil }
        return fields
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

@MainActor
private final class ChatDirectNoopLiveActivityManager: AgentLiveActivityManaging {
    func start(sessionID: String, sessionTitle: String, streamID: String?) {}
    func update(_ event: AgentLiveActivityEvent) {}
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}

private enum ChatDirectEventFactory {
    static func event(
        sessionID: String,
        type: String,
        sequence: Int,
        payload: [String: JSONValue]? = nil
    ) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: "event",
            type: type,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload.map(JSONValue.object),
            params: nil,
            connectionGeneration: 1
        )
    }
}

private final class ChatDirectRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private final class ChatDirectFakeTransport: HermesGatewayTransport, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let params: JSONValue?
    }

    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var callsValue: [Call] = []
    private var generation = 0
    private var connected = false
    private var steerResponse: JSONValue = .object(["status": .string("accepted")])

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        withLock { self.sink = sink }
    }

    func setSteerResponse(_ response: JSONValue) {
        withLock { steerResponse = response }
    }

    func calls() -> [Call] {
        withLock { callsValue }
    }

    func connect() async throws {
        withLock {
            generation += 1
            connected = true
        }
    }

    func close() async {
        withLock { connected = false }
    }

    func connectionIdentifier() async -> Int? {
        withLock { connected ? generation : nil }
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        let response = withLock { () -> JSONValue? in
            callsValue.append(Call(method: method, params: params))
            switch method {
            case "session.create":
                return .object([
                    "session_id": .string("runtime-1"),
                    "session_key": .string("durable-1")
                ])
            case "prompt.submit":
                let sink = self.sink
                Task {
                    sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.start", sequence: 1))
                    sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.delta", sequence: 2, payload: ["text": .string("streamed answer")]))
                }
                return .object(["status": .string("streaming")])
            case "session.steer":
                return steerResponse
            case "session.interrupt":
                return .object(["status": .string("interrupted")])
            case "session.status":
                return .object(["output": .string("Agent Running: No")])
            default:
                return .object([:])
            }
        }
        return response
    }

    func emitCompletion() {
        let sink = withLock { self.sink }
        sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.complete", sequence: 3, payload: ["text": .string("streamed answer")]))
    }

    func emit(_ event: HermesGatewayEvent) {
        let sink = withLock { self.sink }
        sink?(event)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
