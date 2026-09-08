import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationBTWTests: XCTestCase {
    func testStartsAndCompletesMatchingSideQuestionWithoutTranscriptMutation() async throws {
        let fixture = try await makeFixture()
        var outcomes: [GatewayConversationController.BtwOutcome] = []
        fixture.controller.onBtwOutcome = { outcomes.append($0) }
        var genericEvents: [String] = []
        fixture.controller.onEvent = { genericEvents.append($0.type) }
        let attempt = UUID()
        let transcriptLoadsBeforeBtw = fixture.transcriptLoads.value

        let taskID = try await fixture.controller.startBtw("What changed?", attemptID: attempt)
        XCTAssertEqual(taskID, "btw_123456")
        do {
            _ = try await fixture.controller.startBtw("Second question", attemptID: UUID())
            XCTFail("Only one side question may be active")
        } catch {
            XCTAssertEqual(error as? DirectBtwError, .alreadyActive)
        }
        fixture.transport.emitCompletion(taskID: taskID, question: "What changed?", text: "Only tests changed.")
        await drainEvents()

        XCTAssertEqual(outcomes, [.completed(
            attemptID: attempt, taskID: taskID,
            question: "What changed?", text: "Only tests changed."
        )])
        XCTAssertEqual(genericEvents, ["btw.complete"])
        XCTAssertEqual(fixture.transcriptLoads.value, transcriptLoadsBeforeBtw)
        await fixture.runtime.stop()
    }

    func testCompletionBeforeAcknowledgementReturnIsDelivered() async throws {
        let fixture = try await makeFixture(mode: .completeBeforeAck)
        let attempt = UUID()
        var outcomes: [GatewayConversationController.BtwOutcome] = []
        fixture.controller.onBtwOutcome = { outcomes.append($0) }

        let taskID = try await fixture.controller.startBtw("Race?", attemptID: attempt)
        await drainEvents()

        XCTAssertEqual(taskID, "btw_123456")
        XCTAssertEqual(outcomes, [.completed(
            attemptID: attempt, taskID: taskID, question: "Race?", text: "Correlated."
        )])
        await fixture.runtime.stop()
    }

    func testWrongTaskAndWrongSessionCannotCompleteAttempt() async throws {
        let fixture = try await makeFixture()
        let attempt = UUID()
        var outcomes: [GatewayConversationController.BtwOutcome] = []
        fixture.controller.onBtwOutcome = { outcomes.append($0) }
        _ = try await fixture.controller.startBtw("Which?", attemptID: attempt)

        fixture.transport.emitCompletion(taskID: "btw_stale", question: "Which?", text: "stale")
        fixture.transport.emitCompletion(taskID: "btw_123456", question: "Which?", text: "wrong session", sessionID: "runtime-other")
        fixture.transport.emitCompletion(taskID: "btw_123456", question: "Different?", text: "wrong question")
        await drainEvents()
        XCTAssertTrue(outcomes.isEmpty)

        fixture.transport.emitCompletion(taskID: "btw_123456", question: "Which?", text: "current")
        await drainEvents()
        XCTAssertEqual(outcomes, [.completed(
            attemptID: attempt, taskID: "btw_123456", question: "Which?", text: "current"
        )])
        await fixture.runtime.stop()
    }

    func testInvalidationAndDisconnectReportUnknownAndRejectStaleCompletion() async throws {
        let fixture = try await makeFixture()
        let attempt = UUID()
        var outcomes: [GatewayConversationController.BtwOutcome] = []
        fixture.controller.onBtwOutcome = { outcomes.append($0) }
        _ = try await fixture.controller.startBtw("Still there?", attemptID: attempt)

        fixture.transport.emitClosed()
        await drainEvents()
        fixture.transport.emitCompletion(taskID: "btw_123456", question: "Still there?", text: "late")
        await drainEvents()
        XCTAssertEqual(outcomes, [.unknown(attemptID: attempt)])

        let second = try await makeFixture()
        let secondAttempt = UUID()
        var secondOutcomes: [GatewayConversationController.BtwOutcome] = []
        second.controller.onBtwOutcome = { secondOutcomes.append($0) }
        _ = try await second.controller.startBtw("Invalidate?", attemptID: secondAttempt)
        second.controller.invalidate()
        XCTAssertEqual(secondOutcomes, [.unknown(attemptID: secondAttempt)])
        await fixture.runtime.stop()
        await second.runtime.stop()
    }

    func testUnknownAcknowledgementIsNotRetried() async throws {
        let fixture = try await makeFixture(mode: .transportFailure)
        do {
            _ = try await fixture.controller.startBtw("Retry?", attemptID: UUID())
            XCTFail("Expected an unknown outcome")
        } catch {
            XCTAssertEqual(error as? DirectBtwError, .outcomeUnknown)
        }
        let methods = fixture.transport.requestedMethods
        XCTAssertEqual(methods.filter { $0 == "prompt.btw" }.count, 1)
        await fixture.runtime.stop()
    }

    private func makeFixture(mode: BtwTransport.Mode = .normal) async throws -> (
        controller: GatewayConversationController,
        runtime: HermesServerRuntime,
        transport: BtwTransport,
        transcriptLoads: LockedCounter
    ) {
        let transport = BtwTransport(mode: mode)
        let runtime = try HermesServerRuntime(origin: XCTUnwrap(URL(string: "https://btw.example.test"))) { sink in
            transport.installSink(sink)
            return transport
        }
        let loads = LockedCounter()
        let controller = GatewayConversationController(runtime: runtime, storedID: "stored-session") { id, _, _, _ in
            loads.increment()
            return DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
        try await controller.open()
        return (controller, runtime, transport, loads)
    }

    private func drainEvents() async {
        for _ in 0..<80 { await Task.yield() }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class BtwTransport: HermesGatewayTransport, @unchecked Sendable {
    enum Mode: Equatable { case normal, completeBeforeAck, transportFailure }
    private let lock = NSLock()
    private let mode: Mode
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var generation = 0
    private var sequence = 0
    private var methods: [String] = []
    var requestedMethods: [String] { lock.withLock { methods } }

    init(mode: Mode) { self.mode = mode }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) { lock.withLock { self.sink = sink } }
    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async {}
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { methods.append(method) }
        if method == "session.resume" {
            return .object([
                "session_id": .string("runtime-session"),
                "session_key": .string("stored-session"),
                "running": .bool(false)
            ])
        }
        guard method == "prompt.btw" else { return .object([:]) }
        if mode == .transportFailure { throw HermesGatewayError.transport("lost acknowledgement") }
        if mode == .completeBeforeAck {
            emitCompletion(taskID: "btw_123456", question: "Race?", text: "Correlated.")
        }
        return .object(["task_id": .string("btw_123456")])
    }

    func emitCompletion(taskID: String, question: String, text: String, sessionID: String = "runtime-session") {
        emit(type: "btw.complete", sessionID: sessionID, payload: [
            "task_id": .string(taskID), "question": .string(question), "text": .string(text)
        ])
    }

    func emitClosed() { emit(type: "transport.closed", method: "local", sessionID: nil, payload: [:]) }

    private func emit(type: String, method: String = "event", sessionID: String?, payload: [String: JSONValue]) {
        let delivery = lock.withLock { () -> ((@Sendable (HermesGatewayEvent) -> Void)?, HermesGatewayEvent) in
            sequence += 1
            return (sink, HermesGatewayEvent(
                method: method, type: type, sessionID: sessionID, sequence: sequence,
                payload: .object(payload), params: nil, connectionGeneration: generation
            ))
        }
        delivery.0?(delivery.1)
    }
}
