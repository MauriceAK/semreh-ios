import XCTest
@testable import HermesMobile

/// Contract tests for the riskiest streaming paths: disconnect → reconnect
/// with replayed tokens, server restart mid-stream, and replay of content the
/// client already rendered. Each test drives a real `ChatViewModel` (which
/// owns the replay dedup from PR #211) and a real `ChatStreamCoordinator`
/// through a full scripted wire sequence via `ScriptedSSEStreamingClient`.
final class StreamReconnectContractTests: APIClientTestCase {
    // MARK: - Scenario 1: reconnect with overlapping replayed tokens (#201 regression guard)

    @MainActor
    func testReconnectWithOverlappingReplayRendersEachTokenExactlyOnce() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.transportError("The network connection was lost."))
            ],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.token("charlie "), lastEventID: "stream-123:3"),
                .init(.token("delta."), lastEventID: "stream-123:4"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Planning"}}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo "])
        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)

        // The transport error schedules an async reconnect; the status probe
        // reports the stream inactive with a replay journal available.
        try await waitUntil { streamClient.startedURLs.count == 2 }

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let query = queryDictionary(of: replayURL)
        XCTAssertEqual(replayURL.path, "/api/chat/stream")
        XCTAssertEqual(query["stream_id"], "stream-123")
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "2")

        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo charlie delta."])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.droppedEventCount, 0)
    }

    // MARK: - Scenario 2: missing terminal recovered from canonical direct state

    @MainActor
    func testDirectDisconnectBeforeTerminalReplacesPartialWithCanonicalCompletedAnswer() async throws {
        let transport = MissingTerminalDirectTransport(running: false)
        let server = URL(string: "https://example.test")!
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink)
            return transport
        }
        var canonicalRows = [
            ChatMessage(role: "user", content: "Keep working", timestamp: 1,
                messageId: "1")
        ]
        let controller = GatewayConversationController(
            runtime: runtime, storedID: "durable-1", profile: "work",
            loadTranscript: { id, profile, _, _ in
                XCTAssertEqual(id, "durable-1")
                XCTAssertEqual(profile, "work")
                return DirectHermesTranscriptPage(sessionID: id, messages: canonicalRows, pagination: nil)
            }
        )
        try await controller.open()
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "durable-1", profile: "work"), server: server,
            gatewayRuntimeProvider: { _ in runtime }, initialDirectConversation: controller
        )
        await viewModel.loadMessages()
        XCTAssertEqual(viewModel.messages.compactMap(\.messageId), ["1"])

        transport.setRunning(true)
        transport.emit("message.start")
        transport.emit("message.delta", payload: ["text": .string("Alpha bravo ")])
        try await waitUntil {
            viewModel.flushPendingStreamingContent()
            return self.assistantContents(of: viewModel) == ["Alpha bravo "]
        }
        let userIDBeforeRecovery = try XCTUnwrap(viewModel.messages.first?.id)

        // Hermes persisted the complete answer, but the socket disappeared before
        // the client received message.complete. A fresh resume reports idle and its
        // canonical read must replace the transient prefix rather than append it.
        canonicalRows = [
            ChatMessage(role: "user", content: "Keep working", timestamp: 1,
                messageId: "1"),
            ChatMessage(role: "assistant", content: "Alpha bravo charlie delta.", timestamp: 2,
                messageId: "2")
        ]
        transport.setRunning(false)
        try await runtime.reconnect()

        XCTAssertEqual(viewModel.messages.compactMap(\.content),
            ["Keep working", "Alpha bravo charlie delta."])
        XCTAssertEqual(controller.runState, .idle)
        XCTAssertEqual(viewModel.messages.first?.id, userIDBeforeRecovery)
        XCTAssertEqual(viewModel.messages.compactMap(\.messageId), ["1", "2"])
        XCTAssertFalse(viewModel.messages.contains { $0.content == "Alpha bravo " })
        XCTAssertEqual(transport.methods(), ["session.resume", "session.resume"])
        XCTAssertFalse(transport.methods().contains("prompt.submit"))
        XCTAssertNil(viewModel.streamingAssistantMessageID)
        XCTAssertNil(viewModel.sendErrorMessage)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    // MARK: - Scenario 3: replay arriving after the response already rendered locally


    @MainActor
    func testDirectRunningResumePreservesCompletedAssistantSegmentWithoutSubmittingDuplicate() async throws {
        try await assertDirectBusySendPreservesExistingTurn(hasCompletedCurrentTurnSegment: true)
    }

    @MainActor
    func testDuplicateStartReconnectDoesNotReusePreviousTurnAssistantAnchor() async throws {
        try await assertDirectBusySendPreservesExistingTurn(hasCompletedCurrentTurnSegment: false)
    }

    func testOnlySpecificMissingStream404IsTerminal() {
        XCTAssertTrue(
            APIError.http(statusCode: 404, body: #"{"error":"stream not found"}"#).indicatesMissingStream
        )
        XCTAssertFalse(
            APIError.http(statusCode: 404, body: #"{"error":"endpoint not found"}"#).indicatesMissingStream
        )
        XCTAssertFalse(APIError.http(statusCode: 404, body: nil).indicatesMissingStream)
    }

    private func jsonResponse(
        _ json: String,
        statusCode: Int,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(json.utf8)
        )
    }

    // MARK: - Helpers

    @MainActor
    private func assertDirectBusySendPreservesExistingTurn(hasCompletedCurrentTurnSegment: Bool) async throws {
        let fake = SendRetirementDirectTransport()
        let server = URL(string: "https://example.test")!
        let runtime = try HermesServerRuntime(origin: server) { sink in
            fake.installSink(sink)
            return fake
        }
        // Stock REST exposes durable segments, not the current inflight buffer.
        // A completed assistant segment in a running turn must not absorb a later delta.
        let rows = hasCompletedCurrentTurnSegment
            ? #"[{"id":1,"role":"user","content":"Already accepted"},{"id":2,"role":"assistant","content":"Completed interim answer"}]"#
            : #"[{"id":1,"role":"assistant","content":"Previous response"},{"id":2,"role":"user","content":"Already accepted"}]"#
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/durable-1/messages")
            XCTAssertEqual(self.queryDictionary(of: request.url!)["profile"], "work")
            return apiTestJSONResponse("{\"session_id\":\"durable-1\",\"messages\":\(rows),\"pagination\":{\"limit\":120,\"offset\":0,\"order\":\"latest\",\"returned\":2}}", for: request)
        }
        let vm = ChatViewModel(session: SessionSummary(sessionId: "durable-1", profile: "work"),
            server: server, client: client, gatewayRuntimeProvider: { _ in runtime })
        let accepted = await vm.sendMessage("Duplicate request")
        XCTAssertFalse(accepted)
        XCTAssertEqual(fake.methods(), ["session.resume"])
        XCTAssertEqual(vm.messages.compactMap(\.content), hasCompletedCurrentTurnSegment
            ? ["Already accepted", "Completed interim answer"] : ["Previous response", "Already accepted"])
        XCTAssertFalse(vm.messages.contains { $0.content == "Duplicate request" })
        let durableIDs = vm.messages.map(\.id)
        fake.emitDelta("new response")
        try await waitUntil {
            vm.flushPendingStreamingContent()
            return self.assistantContents(of: vm).last == "new response"
        }
        XCTAssertEqual(assistantContents(of: vm), hasCompletedCurrentTurnSegment
            ? ["Completed interim answer", "new response"] : ["Previous response", "new response"])
        XCTAssertEqual(Array(vm.messages.prefix(2)).map(\.id), durableIDs)
        XCTAssertFalse(durableIDs.contains(try XCTUnwrap(vm.messages.last?.id)))
        XCTAssertFalse(fake.methods().contains("prompt.submit"))
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    @MainActor
    private func makeViewModel(
        streamClient: ScriptedSSEStreamingClient,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "workspace": "/tmp/workspace"
            }
            """.utf8)
        )

        let viewModel = ChatViewModel(
            session: session,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient()
        )
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }
        return viewModel
    }

    @MainActor
    private func assistantContents(of viewModel: ChatViewModel) -> [String] {
        viewModel.messages.filter { $0.role == "assistant" }.compactMap(\.content)
    }

    private func queryDictionary(of url: URL) -> [String: String] {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 8,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

/// Minimal direct resume fixture shared by send-retirement tests. It never
/// implements the removed WebUI start/replay protocol.
final class SendRetirementDirectTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }; self.sink = sink
    }
    func methods() -> [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func record(_ method: String) { lock.lock(); defer { lock.unlock() }; recorded.append(method) }
    func connect() async throws {}
    func close() async {}
    func connectionIdentifier() async -> Int? { 1 }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        record(method)
        guard method == "session.resume" else { throw DirectSessionError.invalidResponse }
        return .object(["session_id": .string("runtime-existing"), "session_key": .string("durable-1"),
                        "running": .bool(true)])
    }
    func emitDelta(_ text: String) {
        lock.lock(); let target = sink; lock.unlock()
        target?(HermesGatewayEvent(method: "event", type: "message.delta", sessionID: "runtime-existing",
            sequence: 1, payload: .object(["text": .string(text)]), params: nil, connectionGeneration: 1))
    }
}

private final class MissingTerminalDirectTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var recorded: [String] = []
    private var running: Bool
    private var generation = 0
    private var sequence = 0

    init(running: Bool) { self.running = running }

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }

    func setRunning(_ value: Bool) { lock.withLock { running = value } }
    func methods() -> [String] { lock.withLock { recorded } }
    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async { }
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { recorded.append(method) }
        guard method == "session.resume" else { throw DirectSessionError.invalidResponse }
        return lock.withLock {
            .object([
                "session_id": .string("runtime-1"),
                "session_key": .string("durable-1"),
                "running": .bool(running)
            ])
        }
    }

    func emit(_ type: String, payload: [String: JSONValue] = [:]) {
        let delivery = lock.withLock { () -> ((@Sendable (HermesGatewayEvent) -> Void)?, HermesGatewayEvent) in
            sequence += 1
            return (sink, HermesGatewayEvent(
                method: "event", type: type, sessionID: "runtime-1", sequence: sequence,
                payload: .object(payload), params: nil, connectionGeneration: generation
            ))
        }
        delivery.0?(delivery.1)
    }
}
