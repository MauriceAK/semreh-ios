import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationBlockingTests: XCTestCase {
    func testClarifyAnswerAndEmptyAnswerCancellationUseCapturedIdentity() async throws {
        let fake = BlockingFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        try await controller.submit("ask")

        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-1"))
        XCTAssertEqual(controller.pendingBlockingPrompt?.choices, ["answer", "cancel"])
        let firstIdentity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        let firstResponse = try await controller.respondToBlockingPrompt("answer", expectedIdentity: firstIdentity)
        XCTAssertEqual(firstResponse, .accepted)
        XCTAssertNil(controller.pendingBlockingPrompt)

        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-2"))
        let secondIdentity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        let secondResponse = try await controller.respondToBlockingPrompt("", expectedIdentity: secondIdentity)
        XCTAssertEqual(secondResponse, .accepted)
        let answers = fake.calls().compactMap { call -> String? in
            guard call.method == "clarify.respond",
                  let fields = call.params?.gatewayFields else { return nil }
            return fields["answer"]?.gatewayString ?? ""
        }
        XCTAssertEqual(answers, ["answer", ""])
        await runtime.stop()
    }

    func testWrongSessionAndGenerationEventsNeverCreateOrClearPrompt() async throws {
        let fake = BlockingFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        try await controller.submit("ask")

        fake.emit(clarifyEvent(sessionID: "other-runtime", requestID: "wrong"))
        fake.emit(clarifyEvent(sessionID: "runtime-1", requestID: "old-generation", generation: 99))
        await awaitEvent(controller, fake, event(sessionID: "runtime-1", type: "message.start", payload: .object([:])))
        XCTAssertNil(controller.pendingBlockingPrompt)

        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-1"))
        fake.emit(expiryEvent(sessionID: "runtime-1", requestID: "request-1", generation: 99))
        await awaitEvent(controller, fake, event(sessionID: "runtime-1", type: "message.start", payload: .object([:])))
        XCTAssertNotNil(controller.pendingBlockingPrompt)
        await runtime.stop()
    }

    func testDuplicateRequestIsIdempotentAndExpiryClearsOnlyMatchingRequest() async throws {
        let fake = BlockingFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        try await controller.submit("ask")

        let request = clarifyEvent(sessionID: "runtime-1", requestID: "request-1")
        await awaitEvents(controller, fake, [request, request], expectedCount: 2)
        let first = try XCTUnwrap(controller.pendingBlockingPrompt)
        await awaitEvent(controller, fake, expiryEvent(sessionID: "runtime-1", requestID: "other"))
        XCTAssertEqual(controller.pendingBlockingPrompt, first)
        await awaitEvent(controller, fake, expiryEvent(sessionID: "runtime-1", requestID: "request-1"))
        XCTAssertNil(controller.pendingBlockingPrompt)
        await runtime.stop()
    }

    func testResponseBecomesStaleWhenAReplacementArrivesInFlight() async throws {
        let fake = BlockingFakeTransport()
        let gate = AsyncGate()
        fake.setClarifyGate(gate)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        try await controller.submit("ask")

        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-1"))
        let identity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        let response = Task { try await controller.respondToBlockingPrompt("answer", expectedIdentity: identity) }
        await fake.waitForClarifyCall()
        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-2"))
        await gate.release()
        do {
            _ = try await response.value
            XCTFail("replacement must invalidate an in-flight response")
        } catch GatewayBlockingError.staleClarification { }
        XCTAssertEqual(controller.pendingBlockingPrompt?.identity.requestID, "request-2")
        await runtime.stop()
    }

    func testCapturedIdentityRejectsReplacementBeforeSendAndSecondTapIsSingleFlight() async throws {
        let fake = BlockingFakeTransport()
        let gate = AsyncGate()
        fake.setClarifyGate(gate)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        try await controller.submit("ask")
        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-1"))
        let firstIdentity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-2"))
        do {
            _ = try await controller.respondToBlockingPrompt("answer", expectedIdentity: firstIdentity)
            XCTFail("a replaced captured identity must not send")
        } catch GatewayBlockingError.staleClarification { }

        let currentIdentity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        let first = Task { try await controller.respondToBlockingPrompt("answer", expectedIdentity: currentIdentity) }
        await fake.waitForClarifyCall()
        do {
            _ = try await controller.respondToBlockingPrompt("cancel", expectedIdentity: currentIdentity)
            XCTFail("second tap must not send while first response is in flight")
        } catch GatewayBlockingError.responseInFlight { }
        await gate.release()
        _ = try await first.value
        await runtime.stop()
    }

    func testTerminalBeforeAckAcceptsMatchingOkWithoutClearingReplacement() async throws {
        let fake = BlockingFakeTransport()
        let gate = AsyncGate()
        fake.setClarifyGate(gate)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        try await controller.submit("ask")
        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-1"))
        let identity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        let response = Task { try await controller.respondToBlockingPrompt("answer", expectedIdentity: identity) }
        await fake.waitForClarifyCall()
        await awaitEvent(controller, fake, event(sessionID: "runtime-1", type: "message.complete", payload: .object(["status": .string("ok")])) )
        await gate.release()
        let result = try await response.value
        XCTAssertEqual(result, .accepted)
        XCTAssertNil(controller.pendingBlockingPrompt)
        await runtime.stop()
    }

    func testResponseBecomesStaleWhenExpiryArrivesInFlight() async throws {
        let fake = BlockingFakeTransport()
        let gate = AsyncGate()
        fake.setClarifyGate(gate)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        try await controller.submit("ask")

        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-1"))
        let identity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        let response = Task { try await controller.respondToBlockingPrompt("answer", expectedIdentity: identity) }
        await fake.waitForClarifyCall()
        await awaitEvent(controller, fake, expiryEvent(sessionID: "runtime-1", requestID: "request-1"))
        await gate.release()
        do {
            _ = try await response.value
            XCTFail("expiry must invalidate an in-flight response")
        } catch GatewayBlockingError.staleClarification { }
        XCTAssertNil(controller.pendingBlockingPrompt)
        await runtime.stop()
    }

    func testResumeReconstructsPendingClarifyAndExpiredAckClearsIt() async throws {
        let fake = BlockingFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-resumed"),
            "session_key": .string("stored-chat"),
            "pending_clarify": clarifyPayload(requestID: "request-resumed")
        ]))
        fake.setClarifyResponse(.object(["status": .string("expired")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")
        try await controller.open()

        XCTAssertEqual(controller.pendingBlockingPrompt?.identity.requestID, "request-resumed")
        let identity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        let expiredResponse = try await controller.respondToBlockingPrompt("answer", expectedIdentity: identity)
        XCTAssertEqual(expiredResponse, .expired)
        XCTAssertNil(controller.pendingBlockingPrompt)
        await runtime.stop()
    }

    func testMalformedAndBatchClarifyFailClosedWithExplicitErrors() async throws {
        let fake = BlockingFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        var errors: [GatewayBlockingError] = []
        let errorsExpectation = expectation(description: "both malformed blocking events are reported")
        errorsExpectation.expectedFulfillmentCount = 2
        controller.onError = { error in
            if let error = error as? GatewayBlockingError {
                errors.append(error)
                errorsExpectation.fulfill()
            }
        }
        try await controller.submit("ask")
        fake.emit(event(sessionID: "runtime-1", type: "clarify.request", payload: .object([
            "request_id": .string("batch"),
            "questions": .array([])
        ])))
        fake.emit(event(sessionID: "runtime-1", type: "clarify.request", payload: .object([
            "question": .string("missing request")
        ])))
        await fulfillment(of: [errorsExpectation], timeout: 2.0)
        XCTAssertEqual(errors, [.unsupportedBatchClarification, .malformedClarification])
        XCTAssertNil(controller.pendingBlockingPrompt)
        await runtime.stop()
    }

    func testInvalidateClearsPromptAndRejectsLateResponse() async throws {
        let fake = BlockingFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        try await controller.submit("ask")
        await awaitEvent(controller, fake, clarifyEvent(sessionID: "runtime-1", requestID: "request-1"))
        let identity = try XCTUnwrap(controller.pendingBlockingPrompt?.identity)
        controller.invalidate()
        XCTAssertNil(controller.pendingBlockingPrompt)
        do {
            _ = try await controller.respondToBlockingPrompt("answer", expectedIdentity: identity)
            XCTFail("invalidated controller must reject response")
        } catch DirectSessionError.stopped { }
        await runtime.stop()
    }

    private func awaitEvent(
        _ controller: GatewayConversationController,
        _ fake: BlockingFakeTransport,
        _ event: HermesGatewayEvent
    ) async {
        await awaitEvents(controller, fake, [event], expectedCount: 1)
    }

    private func awaitEvents(
        _ controller: GatewayConversationController,
        _ fake: BlockingFakeTransport,
        _ events: [HermesGatewayEvent],
        expectedCount: Int
    ) async {
        let eventExpectation = expectation(description: "gateway event delivery")
        eventExpectation.expectedFulfillmentCount = expectedCount
        controller.onEvent = { _ in eventExpectation.fulfill() }
        for event in events { fake.emit(event) }
        await fulfillment(of: [eventExpectation], timeout: 2.0)
    }

    private func makeRuntime(_ fake: BlockingFakeTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: URL(string: "https://fixture.example")!) { sink in
            fake.installSink(sink)
            return fake
        }
    }

    private func makeController(
        runtime: HermesServerRuntime,
        storedID: String? = nil
    ) -> GatewayConversationController {
        GatewayConversationController(runtime: runtime, storedID: storedID) { id, _, _, _ in
            DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
    }

    private func clarifyEvent(sessionID: String, requestID: String, generation: Int = 101) -> HermesGatewayEvent {
        event(sessionID: sessionID, type: "clarify.request", payload: clarifyPayload(requestID: requestID), generation: generation)
    }

    private func expiryEvent(sessionID: String, requestID: String, generation: Int = 101) -> HermesGatewayEvent {
        event(sessionID: sessionID, type: "clarify.expire", payload: .object(["request_id": .string(requestID)]), generation: generation)
    }

    private func clarifyPayload(requestID: String) -> JSONValue {
        .object([
            "request_id": .string(requestID),
            "question": .string("Choose a bounded answer"),
            "choices": .array([.string("answer"), .string("cancel")]),
            "multi_select": .bool(false)
        ])
    }

    private func event(
        sessionID: String,
        type: String,
        payload: JSONValue,
        generation: Int = 101
    ) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: "event", type: type, sessionID: sessionID, sequence: 1,
            payload: payload, params: nil, connectionGeneration: generation
        )
    }
}

private actor AsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class BlockingFakeTransport: HermesGatewayTransport, @unchecked Sendable {
    struct Call: Sendable { let method: String; let params: JSONValue? }

    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var callsValue: [Call] = []
    private var connected = false
    private var generation = 100
    private var resumeResponse: JSONValue?
    private var clarifyResponse: JSONValue = .object(["status": .string("ok")])
    private var clarifyGate: AsyncGate?
    private var clarifyCalled: CheckedContinuation<Void, Never>?
    private var clarifyWasCalled = false

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        withLock { self.sink = sink }
    }

    func connect() async throws {
        withLock { generation += 1; connected = true }
    }

    func close() async { withLock { connected = false } }

    func connectionIdentifier() async -> Int? { withLock { connected ? generation : nil } }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        let response = withLock { () -> JSONValue? in
            callsValue.append(Call(method: method, params: params))
            switch method {
            case "session.create":
                return .object(["session_id": .string("runtime-1"), "session_key": .string("durable-1")])
            case "session.resume":
                return resumeResponse ?? .object(["session_id": .string("runtime-resumed"), "session_key": .string("stored-chat")])
            case "prompt.submit":
                return .object(["status": .string("streaming")])
            case "clarify.respond":
                return clarifyResponse
            default:
                return .object([:])
            }
        }
        if method == "clarify.respond" {
            let (gate, waiter) = withLock { () -> (AsyncGate?, CheckedContinuation<Void, Never>?) in
                clarifyWasCalled = true
                let waiter = clarifyCalled
                clarifyCalled = nil
                return (clarifyGate, waiter)
            }
            if let waiter { waiter.resume() }
            if let gate { await gate.wait() }
        }
        return response
    }

    func emit(_ event: HermesGatewayEvent) {
        let sink = withLock { self.sink }
        sink?(event)
    }

    func setResumeResponse(_ response: JSONValue) { withLock { resumeResponse = response } }
    func setClarifyResponse(_ response: JSONValue) { withLock { clarifyResponse = response } }
    func setClarifyGate(_ gate: AsyncGate) { withLock { clarifyGate = gate } }

    func waitForClarifyCall() async {
        await withCheckedContinuation { continuation in
            withLock {
                if clarifyWasCalled { continuation.resume() }
                else { clarifyCalled = continuation }
            }
        }
    }

    func calls() -> [Call] { withLock { callsValue } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
}
