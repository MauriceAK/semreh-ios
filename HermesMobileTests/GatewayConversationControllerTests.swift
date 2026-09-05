import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationControllerTests: XCTestCase {
    func testFirstSubmitCreatesOnceAndUsesRuntimeIDAndProfile() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil, profile: "work")

        try await controller.submit("hello")

        let calls = fake.calls()
        XCTAssertEqual(calls.map(\.method), ["session.create", "prompt.submit"])
        XCTAssertEqual(objectFields(calls[0].params)?["profile"], .string("work"))
        XCTAssertEqual(objectFields(calls[1].params)?["session_id"], .string("runtime-1"))
        XCTAssertEqual(objectFields(calls[1].params)?["profile"], .string("work"))
        XCTAssertEqual(controller.binding?.runtimeID, "runtime-1")
        XCTAssertEqual(controller.storedID, "durable-1")

        await runtime.stop()
    }

    func testExistingResumeUsesCanonicalTipForBindingAndTranscript() async throws {
        let fake = ControllerFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-tip"),
            "session_key": .string("tip")
        ]))
        let runtime = try makeRuntime(fake)
        var loadedIDs: [String] = []
        let controller = makeController(runtime: runtime, storedID: "ancestor", profile: "work") { id, _, _, _ in
            loadedIDs.append(id)
            return self.page(id)
        }

        try await controller.open()

        XCTAssertEqual(loadedIDs, ["tip"])
        XCTAssertEqual(controller.storedID, "tip")
        XCTAssertEqual(controller.binding, GatewaySessionBinding(storedID: "tip", runtimeID: "runtime-tip", profile: "work"))
        let resume = try XCTUnwrap(fake.calls().first(where: { $0.method == "session.resume" }))
        XCTAssertEqual(objectFields(resume.params)?["session_id"], .string("ancestor"))
        XCTAssertEqual(objectFields(resume.params)?["profile"], .string("work"))

        await runtime.stop()
    }

    func testAlreadyReadyResumeBuffersEarlyEventsUntilBindingAndCanonicalReadFinish() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        try await runtime.connect()
        let sinkConsumed = AsyncGate()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-event"),
            "session_key": .string("tip")
        ]))
        fake.setResumeEventsBeforeResponse(
            [
                event(sessionID: "runtime-event", type: "message.start", sequence: 1),
                event(sessionID: "runtime-event", type: "message.delta", sequence: 2)
            ],
            sinkConsumedGate: sinkConsumed
        )
        var observations: [(String, String?, String?)] = []
        var canonicalIDs: [String] = []
        let controller = makeController(runtime: runtime, storedID: "ancestor") { _, _, _, _ in
            self.page("tip")
        }
        controller.onCanonicalID = { canonicalIDs.append($0) }
        controller.onEvent = { event in
            observations.append((event.type, controller.storedID, controller.binding?.runtimeID))
        }

        try await controller.open()

        XCTAssertEqual(observations.map(\.0), ["message.start", "message.delta"])
        XCTAssertTrue(observations.allSatisfy { $0.1 == "tip" && $0.2 == "runtime-event" })
        XCTAssertEqual(canonicalIDs, ["tip"])
        XCTAssertEqual(controller.storedID, "tip")
        XCTAssertEqual(controller.binding?.runtimeID, "runtime-event")
        await runtime.stop()
    }

    func testLocalDraftOpenDoesNotCreateOrAttach() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)

        try await controller.open()

        XCTAssertTrue(fake.calls().isEmpty)
        XCTAssertNil(controller.binding)
        XCTAssertNil(controller.storedID)
        await runtime.stop()
    }

    func testInterleavedConversationEventsAreFilteredByRuntimeSessionID() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let first = makeController(runtime: runtime, storedID: nil, profile: "default")
        let second = makeController(runtime: runtime, storedID: nil, profile: "default")
        var firstEvents: [String] = []
        var secondEvents: [String] = []
        first.onEvent = { firstEvents.append($0.type) }
        second.onEvent = { secondEvents.append($0.type) }

        try await first.submit("one")
        try await second.submit("two")
        fake.emit(event(sessionID: "runtime-1", type: "message.delta", sequence: 1))
        fake.emit(event(sessionID: "runtime-2", type: "message.delta", sequence: 2))
        await yieldUntil { firstEvents.count == 1 && secondEvents.count == 1 }

        XCTAssertEqual(firstEvents, ["message.delta"])
        XCTAssertEqual(secondEvents, ["message.delta"])
        await runtime.stop()
    }

    func testPromptTimeoutBlocksRetryWithoutDuplicateSubmission() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptTimeout(true)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)

        do {
            try await controller.submit("ambiguous")
            XCTFail("Expected prompt timeout")
        } catch HermesGatewayError.timeout {
            // The server may have accepted the prompt; it must not be replayed.
        }
        XCTAssertEqual(controller.runState, .deliveryUnknown)

        do {
            try await controller.submit("retry")
            XCTFail("Expected retry to remain blocked")
        } catch DirectSessionError.ambiguousPrompt {
            // Expected path.
        }

        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await runtime.stop()
    }

    func testDefinitePromptRejection404MakesDraftCloseable() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptServerError(.server(
            code: 404,
            message: "session not found",
            data: nil,
            method: "prompt.submit",
            requestID: "2",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        var loadedIDs: [String] = []
        let controller = makeController(runtime: runtime, storedID: nil) { id, _, _, _ in
            loadedIDs.append(id)
            throw APIError.http(statusCode: 404, body: #"{"detail":"Session not found"}"#)
        }

        do {
            try await controller.submit("rejected")
            XCTFail("Expected definite prompt rejection")
        } catch HermesGatewayError.server {
            // The structured REST 404 separately proves no durable row exists.
        }
        try await controller.dispose()

        XCTAssertEqual(loadedIDs, ["durable-1"])
        XCTAssertEqual(fake.calls().map(\.method), ["session.create", "prompt.submit", "session.close"])
        XCTAssertEqual(objectFields(fake.calls().last?.params)?["session_id"], .string("runtime-1"))
        await runtime.stop()
    }

    func testDisconnectedDraftCleanupFailsClosedWithoutStaleClose() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptServerError(.server(
            code: 404,
            message: "session not found",
            data: nil,
            method: "prompt.submit",
            requestID: "2",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil) { _, _, _, _ in
            throw APIError.http(statusCode: 404, body: #"{"detail":"Session not found"}"#)
        }
        do { try await controller.submit("rejected") } catch HermesGatewayError.server { }
        await runtime.stop()

        do {
            try await controller.dispose()
            XCTFail("Expected conservative draft cleanup failure")
        } catch DirectSessionError.draftCleanupUnconfirmed {
            // A dead runtime cannot safely close the old runtime ID.
        }
        XCTAssertFalse(fake.calls().contains { $0.method == "session.close" })
    }

    func testRejectedSteerDoesNotFallbackToInterruptOrPrompt() async throws {
        let fake = ControllerFakeTransport()
        fake.setSteerResponse(.object(["status": .string("rejected")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)
        try await controller.submit("running")

        let outcome = try await controller.steer("follow-up")

        XCTAssertEqual(outcome.rawValue, "rejected")
        let methods = fake.calls().map(\.method)
        XCTAssertEqual(methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertFalse(methods.contains("session.interrupt"))
        await runtime.stop()
    }

    func testInterruptWaitsForTerminalEventAndProvesStopped() async throws {
        let fake = ControllerFakeTransport()
        fake.setInterruptResponse(.object(["status": .string("interrupted")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)
        try await controller.submit("running")
        fake.setInterruptEvent(event(
            sessionID: "runtime-1",
            type: "message.complete",
            sequence: 3,
            payload: .object(["status": .string("interrupted")])
        ))

        try await controller.interrupt()

        XCTAssertEqual(controller.runState, .idle)
        XCTAssertTrue(fake.calls().contains { $0.method == "session.interrupt" })
        XCTAssertTrue(fake.calls().contains { $0.method == "session.status" })
        await runtime.stop()
    }

    func testUnconfirmedInterruptCanBeRetriedWithoutResubmittingPrompt() async throws {
        let fake = ControllerFakeTransport()
        fake.setInterruptResponse(.object(["status": .string("unconfirmed")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)
        try await controller.submit("running")
        do {
            try await controller.interrupt()
            XCTFail("An unconfirmed acknowledgement must not report stopped")
        } catch {
            XCTAssertEqual(controller.runState, .stopping)
        }
        fake.setInterruptResponse(.object(["status": .string("interrupted")]))
        fake.setInterruptEvent(event(sessionID: "runtime-1", type: "message.complete", sequence: 3,
            payload: .object(["status": .string("interrupted")])))
        try await controller.interrupt()
        XCTAssertEqual(controller.runState, .idle)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.interrupt" }.count, 2)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await runtime.stop()
    }

    func testDuplicateTerminalEventCausesExactlyOneCanonicalReload() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        var loadedIDs: [String] = []
        var terminalEvents = 0
        let controller = makeController(runtime: runtime, storedID: nil) { id, _, _, _ in
            loadedIDs.append(id)
            return self.page("tip")
        }
        controller.onEvent = { event in
            if event.type == "message.complete" { terminalEvents += 1 }
        }
        try await controller.submit("complete")

        let terminal = event(sessionID: "runtime-1", type: "message.complete", sequence: 9)
        fake.emit(terminal)
        await yieldUntil { loadedIDs.count == 1 }
        fake.emit(terminal)
        await Task.yield()

        XCTAssertEqual(terminalEvents, 1)
        XCTAssertEqual(loadedIDs, ["durable-1"])
        XCTAssertEqual(controller.storedID, "tip")
        XCTAssertNil(controller.binding)
        await runtime.stop()
    }

    func testConflictingResumeAliasesReloadCanonicalTranscriptWithoutBinding() async throws {
        let fake = ControllerFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-conflict"),
            "session_key": .string("tip-a"),
            "stored_session_id": .string("tip-b")
        ]))
        let runtime = try makeRuntime(fake)
        var loadedIDs: [String] = []
        let controller = makeController(runtime: runtime, storedID: "ancestor") { id, _, _, _ in
            loadedIDs.append(id)
            return self.page("tip-a")
        }

        do {
            try await controller.open()
            XCTFail("Expected conflicting aliases")
        } catch DirectSessionError.conflictingDurableIDs {
            // The canonical REST read is still authoritative.
        }

        XCTAssertEqual(loadedIDs, ["ancestor"])
        XCTAssertEqual(controller.storedID, "tip-a")
        XCTAssertNil(controller.binding)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.resume" }.count, 1)
        await runtime.stop()
    }

    func testTerminalRefreshBecomesStaleWhenNextPromptStarts() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let gate = AsyncGate()
        var loadCount = 0
        var transcriptCount = 0
        let controller = makeController(runtime: runtime, storedID: nil) { _, _, _, _ in
            loadCount += 1
            if loadCount == 1 { await gate.wait() }
            return self.page("durable-1")
        }
        controller.onTranscript = { _, _ in transcriptCount += 1 }
        try await controller.submit("first")

        fake.emit(event(sessionID: "runtime-1", type: "message.complete", sequence: 11))
        await yieldUntil { loadCount == 1 }
        try await controller.submit("next")
        await gate.release()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 2)
        XCTAssertEqual(transcriptCount, 0)
        await runtime.stop()
    }

    private func makeRuntime(_ fake: ControllerFakeTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: URL(string: "https://fixture.example")!) { sink in
            fake.installSink(sink)
            return fake
        }
    }

    private func makeController(
        runtime: HermesServerRuntime,
        storedID: String?,
        profile: String = "default",
        loader: @escaping GatewayConversationController.TranscriptLoader = { id, _, _, _ in
            DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
    ) -> GatewayConversationController {
        GatewayConversationController(runtime: runtime, storedID: storedID, profile: profile, loadTranscript: loader)
    }

    private func page(_ sessionID: String) -> DirectHermesTranscriptPage {
        DirectHermesTranscriptPage(sessionID: sessionID, messages: [], pagination: nil)
    }

    private func event(
        sessionID: String,
        type: String,
        sequence: Int,
        payload: JSONValue? = nil
    ) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: "gateway.event",
            type: type,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload,
            params: nil,
            connectionGeneration: 1
        )
    }

    private func objectFields(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value, case .object(let fields) = value else { return nil }
        return fields
    }

    private func yieldUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ControllerFakeTransport: HermesGatewayTransport, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let params: JSONValue?
    }

    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var callsValue: [Call] = []
    private var generationValue = 0
    private var connected = false
    private var createCount = 0
    private var resumeResponse: JSONValue?
    private var resumeEventsBeforeResponse: [HermesGatewayEvent] = []
    private var resumeResponseGate: AsyncGate?
    private var sinkConsumedGate: AsyncGate?
    private var steerResponse: JSONValue = .object(["status": .string("accepted")])
    private var promptTimeout = false
    private var promptServerError: HermesGatewayError?
    private var interruptResponse: JSONValue = .object([:])
    private var interruptEvent: HermesGatewayEvent?

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        let wrapped: @Sendable (HermesGatewayEvent) -> Void = { [weak self] event in
            sink(event)
            guard let self else { return }
            let gate = self.withLock { self.sinkConsumedGate }
            if let gate {
                Task { await gate.release() }
            }
        }
        withLock { self.sink = wrapped }
    }

    func setResumeResponse(_ response: JSONValue) {
        withLock { resumeResponse = response }
    }

    func setResumeEventsBeforeResponse(
        _ events: [HermesGatewayEvent],
        sinkConsumedGate: AsyncGate
    ) {
        withLock {
            resumeEventsBeforeResponse = events
            resumeResponseGate = sinkConsumedGate
            self.sinkConsumedGate = sinkConsumedGate
        }
    }

    func setSteerResponse(_ response: JSONValue) {
        withLock { steerResponse = response }
    }

    func setPromptTimeout(_ enabled: Bool) {
        withLock { promptTimeout = enabled }
    }

    func setPromptServerError(_ error: HermesGatewayError) {
        withLock { promptServerError = error }
    }

    func setInterruptResponse(_ response: JSONValue) {
        withLock { interruptResponse = response }
    }

    func setInterruptEvent(_ event: HermesGatewayEvent) {
        withLock { interruptEvent = event }
    }

    func calls() -> [Call] {
        withLock { callsValue }
    }

    func connect() async throws {
        withLock {
            generationValue += 1
            connected = true
        }
    }

    func close() async {
        withLock { connected = false }
    }

    func connectionIdentifier() async -> Int? {
        withLock { connected ? generationValue : nil }
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        let behavior: (JSONValue?, [HermesGatewayEvent], AsyncGate?, Bool, HermesGatewayError?, JSONValue, JSONValue, HermesGatewayEvent?, Int)
        behavior = withLock {
            callsValue.append(Call(method: method, params: params))
            return (
                resumeResponse,
                resumeEventsBeforeResponse,
                resumeResponseGate,
                promptTimeout,
                promptServerError,
                steerResponse,
                interruptResponse,
                interruptEvent,
                callsValue.count
            )
        }

        switch method {
        case "session.create":
            let number = withLock {
                createCount += 1
                return createCount
            }
            return .object([
                "session_id": .string("runtime-\(number)"),
                "session_key": .string("durable-\(number)")
            ])
        case "session.resume":
            for event in behavior.1 { emit(event) }
            if let gate = behavior.2 {
                await gate.wait()
                withLock {
                    resumeEventsBeforeResponse.removeAll()
                    resumeResponseGate = nil
                    sinkConsumedGate = nil
                }
            }
            return behavior.0 ?? .object([
                "session_id": .string("runtime-resumed"),
                "session_key": .string("resumed")
            ])
        case "prompt.submit":
            if let error = behavior.4 { throw error }
            if behavior.3 {
                throw HermesGatewayError.timeout(method: method, requestID: "\(behavior.8)")
            }
            return .object(["status": .string("streaming")])
        case "session.steer":
            return behavior.5
        case "session.interrupt":
            if let event = behavior.7 { emit(event) }
            return behavior.6
        case "session.status":
            return .object(["output": .string("Agent Running: No")])
        default:
            return .object([:])
        }
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
