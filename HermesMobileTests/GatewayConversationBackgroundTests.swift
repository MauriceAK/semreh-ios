import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationBackgroundTests: XCTestCase {
    func testConcurrentTasksCompleteInterleavedIncludingBeforeAck() async throws {
        let fixture = try await makeFixture(mode: .overlap)
        let first = UUID(), second = UUID()
        var outcomes: [GatewayConversationController.BackgroundOutcome] = []
        fixture.controller.onBackgroundOutcome = { outcomes.append($0) }

        let firstStart = Task { try await fixture.controller.startBackground("First", attemptID: first) }
        let secondStart = Task { try await fixture.controller.startBackground("Second", attemptID: second) }
        await fixture.transport.waitUntilRequestsEntered(2)
        fixture.transport.emitCompletion(taskID: "bg_second", text: "second answer")
        fixture.transport.emitCompletion(taskID: "bg_first", text: "error: opaque result")
        await fixture.transport.releaseRequests()
        let firstID = try await firstStart.value
        let secondID = try await secondStart.value
        await drainEvents()

        XCTAssertEqual(firstID, "bg_first")
        XCTAssertEqual(secondID, "bg_second")
        XCTAssertEqual(outcomes, [
            .completed(attemptID: second, taskID: secondID, prompt: "Second", text: "second answer"),
            .completed(attemptID: first, taskID: firstID, prompt: "First", text: "error: opaque result")
        ])
        await fixture.runtime.stop()
    }

    func testWrongTaskAndSessionDoNotComplete() async throws {
        let fixture = try await makeFixture()
        let attempt = UUID()
        var outcomes: [GatewayConversationController.BackgroundOutcome] = []
        fixture.controller.onBackgroundOutcome = { outcomes.append($0) }
        let taskID = try await fixture.controller.startBackground("Scoped", attemptID: attempt)
        fixture.transport.emitCompletion(taskID: "bg_wrong", text: "wrong")
        fixture.transport.emitCompletion(taskID: taskID, text: "wrong session", sessionID: "runtime-other")
        await drainEvents()
        XCTAssertTrue(outcomes.isEmpty)
        fixture.transport.emitCompletion(taskID: taskID, text: "right")
        await drainEvents()
        XCTAssertEqual(outcomes, [.completed(attemptID: attempt, taskID: taskID, prompt: "Scoped", text: "right")])
        await fixture.runtime.stop()
    }

    func testOneFailureDoesNotDropSiblingAndNeverRetries() async throws {
        let fixture = try await makeFixture(mode: .failFirst)
        let sibling = UUID()
        var outcomes: [GatewayConversationController.BackgroundOutcome] = []
        fixture.controller.onBackgroundOutcome = { outcomes.append($0) }
        let taskID = try await fixture.controller.startBackground("Second", attemptID: sibling)
        do {
            _ = try await fixture.controller.startBackground("Fail", attemptID: UUID())
            XCTFail("Expected a definite method refusal")
        } catch {
            guard case HermesGatewayError.server(_, _, _, let method, _, _) = error else {
                return XCTFail("Expected a method-specific server refusal, got \(error)")
            }
            XCTAssertEqual(method, "prompt.background")
        }
        fixture.transport.emitCompletion(taskID: taskID, text: "survived")
        await drainEvents()
        XCTAssertEqual(outcomes, [.completed(attemptID: sibling, taskID: taskID, prompt: "Second", text: "survived")])
        XCTAssertEqual(fixture.transport.requestedMethods.filter { $0 == "prompt.background" }.count, 2)
        await fixture.runtime.stop()
    }

    func testDuplicateAcknowledgedTaskIDMakesBothAttemptsUnknownAndIgnoresCompletion() async throws {
        let fixture = try await makeFixture(mode: .duplicateAck)
        let original = UUID(), collision = UUID()
        var outcomes: [GatewayConversationController.BackgroundOutcome] = []
        fixture.controller.onBackgroundOutcome = { outcomes.append($0) }

        let taskID = try await fixture.controller.startBackground("First", attemptID: original)
        do {
            _ = try await fixture.controller.startBackground("Second", attemptID: collision)
            XCTFail("Expected duplicate acknowledgement to be ambiguous")
        } catch {
            XCTAssertEqual(error as? DirectBackgroundError, .outcomeUnknown)
        }
        XCTAssertEqual(outcomes, [.unknown(attemptID: original)])

        fixture.transport.emitCompletion(taskID: taskID, text: "ambiguous")
        await drainEvents()
        XCTAssertEqual(outcomes, [.unknown(attemptID: original)])
        XCTAssertEqual(fixture.transport.requestedMethods.filter { $0 == "prompt.background" }.count, 2)
        await fixture.runtime.stop()
    }

    func testDisconnectAndInvalidationReportEveryAttemptUnknown() async throws {
        let fixture = try await makeFixture()
        let first = UUID(), second = UUID()
        var outcomes: [GatewayConversationController.BackgroundOutcome] = []
        fixture.controller.onBackgroundOutcome = { outcomes.append($0) }
        _ = try await fixture.controller.startBackground("First", attemptID: first)
        _ = try await fixture.controller.startBackground("Second", attemptID: second)
        fixture.transport.emitClosed()
        await drainEvents()
        XCTAssertEqual(Set(outcomes.map(\.attemptID)), Set([first, second]))

        let invalidated = try await makeFixture()
        let third = UUID(), fourth = UUID()
        var invalidatedOutcomes: [GatewayConversationController.BackgroundOutcome] = []
        invalidated.controller.onBackgroundOutcome = { invalidatedOutcomes.append($0) }
        _ = try await invalidated.controller.startBackground("Third", attemptID: third)
        _ = try await invalidated.controller.startBackground("Fourth", attemptID: fourth)
        invalidated.controller.invalidate()
        XCTAssertEqual(Set(invalidatedOutcomes.map(\.attemptID)), Set([third, fourth]))
        await fixture.runtime.stop()
        await invalidated.runtime.stop()
    }

    func testLostAckAndStaleScopeDoNotRetryOrAcceptLateCompletion() async throws {
        let fixture = try await makeFixture(mode: .lostAck)
        let attempt = UUID()
        do {
            _ = try await fixture.controller.startBackground("Lost", attemptID: attempt)
            XCTFail("Expected unknown outcome")
        } catch {
            XCTAssertEqual(error as? DirectBackgroundError, .outcomeUnknown)
        }
        fixture.transport.emitCompletion(taskID: "bg_first", text: "late")
        await drainEvents()
        XCTAssertEqual(fixture.transport.requestedMethods.filter { $0 == "prompt.background" }.count, 1)

        let stale = try await makeFixture()
        let staleAttempt = UUID()
        var outcomes: [GatewayConversationController.BackgroundOutcome] = []
        stale.controller.onBackgroundOutcome = { outcomes.append($0) }
        let staleTaskID = try await stale.controller.startBackground("Scoped", attemptID: staleAttempt)
        stale.controller.invalidate()
        stale.transport.emitCompletion(taskID: staleTaskID, text: "late")
        await drainEvents()
        XCTAssertEqual(outcomes, [.unknown(attemptID: staleAttempt)])
        await fixture.runtime.stop()
        await stale.runtime.stop()
    }

    func testCanonicalRebindReportsActiveAttemptUnknown() async throws {
        let fixture = try await makeFixture(rebindOnRefresh: true)
        let attempt = UUID()
        var outcomes: [GatewayConversationController.BackgroundOutcome] = []
        fixture.controller.onBackgroundOutcome = { outcomes.append($0) }
        let taskID = try await fixture.controller.startBackground("Old tip", attemptID: attempt)

        try await fixture.controller.refresh()
        XCTAssertEqual(outcomes, [.unknown(attemptID: attempt)])
        fixture.transport.emitCompletion(taskID: taskID, text: "late old tip")
        await drainEvents()
        XCTAssertEqual(outcomes, [.unknown(attemptID: attempt)])
        await fixture.runtime.stop()
    }

    private func makeFixture(
        mode: BackgroundTransport.Mode = .normal,
        rebindOnRefresh: Bool = false
    ) async throws -> (
        controller: GatewayConversationController, runtime: HermesServerRuntime, transport: BackgroundTransport
    ) {
        let transport = BackgroundTransport(mode: mode)
        let runtime = try HermesServerRuntime(origin: XCTUnwrap(URL(string: "https://background.example.test"))) { sink in
            transport.installSink(sink)
            return transport
        }
        let loads = BackgroundLockedCounter()
        let controller = GatewayConversationController(runtime: runtime, storedID: "stored-session") { id, _, _, _ in
            loads.increment()
            let resolvedID = rebindOnRefresh && loads.value > 1 ? "different-tip" : id
            return DirectHermesTranscriptPage(sessionID: resolvedID, messages: [], pagination: nil)
        }
        try await controller.open()
        return (controller, runtime, transport)
    }

    private func drainEvents() async { for _ in 0..<80 { await Task.yield() } }
}

private final class BackgroundLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private extension GatewayConversationController.BackgroundOutcome {
    var attemptID: UUID {
        switch self {
        case .completed(let attemptID, _, _, _), .unknown(let attemptID): attemptID
        }
    }
}

private final class BackgroundTransport: HermesGatewayTransport, @unchecked Sendable {
    enum Mode { case normal, overlap, failFirst, lostAck, duplicateAck }
    private let lock = NSLock()
    private let mode: Mode
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var generation = 0
    private var sequence = 0
    private var methods: [String] = []
    private let requestGate = BackgroundRequestGate()
    var requestedMethods: [String] { lock.withLock { methods } }

    init(mode: Mode) { self.mode = mode }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) { lock.withLock { self.sink = sink } }
    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async {}
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { methods.append(method) }
        if method == "session.resume" {
            return .object(["session_id": .string("runtime-session"), "session_key": .string("stored-session"), "running": .bool(false)])
        }
        guard method == "prompt.background" else { return .object([:]) }
        let prompt = params?.gatewayFields["text"]?.gatewayString ?? ""
        let taskID: String
        if prompt == "Second", case .duplicateAck = mode {
            taskID = "bg_first"
        } else {
            taskID = "bg_" + prompt.lowercased().replacingOccurrences(of: " ", with: "_")
        }
        if mode == .failFirst, prompt == "Fail" {
            throw HermesGatewayError.server(
                code: 4012, message: "fixture refusal", data: nil,
                method: "prompt.background", requestID: "bg-refusal", server: nil
            )
        }
        if mode == .lostAck { throw HermesGatewayError.transport("lost") }
        if mode == .overlap { await requestGate.enterAndWait() }
        return .object(["task_id": .string(taskID)])
    }

    func waitUntilRequestsEntered(_ count: Int) async { await requestGate.waitUntilEntered(count) }
    func releaseRequests() async { await requestGate.releaseAll() }

    func emitCompletion(taskID: String, text: String, sessionID: String = "runtime-session") {
        emit(type: "background.complete", sessionID: sessionID, payload: ["task_id": .string(taskID), "text": .string(text)])
    }
    func emitClosed() { emit(type: "transport.closed", method: "local", sessionID: nil, payload: [:]) }
    private func emit(type: String, method: String = "event", sessionID: String?, payload: [String: JSONValue]) {
        let delivery = lock.withLock { () -> ((@Sendable (HermesGatewayEvent) -> Void)?, HermesGatewayEvent) in
            sequence += 1
            return (sink, HermesGatewayEvent(method: method, type: type, sessionID: sessionID, sequence: sequence,
                payload: .object(payload), params: nil, connectionGeneration: generation))
        }
        delivery.0?(delivery.1)
    }
}

private actor BackgroundRequestGate {
    private var entered = 0
    private var released = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered += 1
        guard !released else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func waitUntilEntered(_ count: Int) async {
        while entered < count { await Task.yield() }
    }

    func releaseAll() {
        released = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
