import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class HermesServerRuntimeTests: XCTestCase {
    func testBindingAcceptsResumeAliasesAndCanonicalContinuation() throws {
        let result: JSONValue = .object(["session_id": .string("runtime"), "session_key": .string("tip"), "stored_session_id": .string("tip"), "resumed": .string("tip")])
        let binding = try GatewaySessionBinding.resolve(result, requestedID: "ancestor", profile: "work")
        XCTAssertEqual(binding, GatewaySessionBinding(storedID: "tip", runtimeID: "runtime", profile: "work"))
    }

    func testConflictingAliasesAndMissingRuntimeFailClosed() {
        XCTAssertThrowsError(try GatewaySessionBinding.resolve(.object(["session_id": .string("rt"), "stored_session_id": .string("a"), "session_key": .string("b")]), profile: "default")) {
            XCTAssertEqual($0 as? DirectSessionError, .conflictingDurableIDs)
        }
        XCTAssertThrowsError(try GatewaySessionBinding.resolve(.object(["stored_session_id": .string("a")]), profile: "default"))
    }

    func testConcurrentInitialConnectSharesOneSocketAndRecovery() async throws {
        let fake = RuntimeFakeTransport(blockedConnections: [1])
        let runtime = try makeRuntime(fake)
        let recoveries = RecoveryProbe()
        _ = runtime.observe(event: { _ in }, recover: { _ in await recoveries.record() })

        async let first: Void = runtime.connect()
        async let second: Void = runtime.connect()
        await fake.waitForConnection(1)
        await fake.releaseConnection(1)
        _ = try await (first, second)

        let connectionCount = await fake.connectionCount()
        let recoveryCount = await recoveries.count()
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(runtime.state, .ready)
        await runtime.stop()
    }

    func testConcurrentReconnectDeduplicatesCloseConnectAndRecovery() async throws {
        let fake = RuntimeFakeTransport()
        let runtime = try makeRuntime(fake)
        let recoveries = RecoveryProbe()
        _ = runtime.observe(event: { _ in }, recover: { _ in await recoveries.record() })

        try await runtime.connect()
        await fake.blockConnection(2)

        let first = Task { try await runtime.reconnect() }
        await fake.waitForConnection(2)
        let secondEntered = CallLatch()
        let second = Task {
            await secondEntered.mark()
            try await runtime.reconnect()
        }
        // The latch is set immediately before the second call. Yielding once
        // lets that call reach the shared connect task while connection 2 is
        // still held by the fake.
        await secondEntered.wait()
        await Task.yield()
        await fake.releaseConnection(2)
        try await first.value
        try await second.value

        let connectionCount = await fake.connectionCount()
        let closeCount = await fake.closeCount()
        let recoveryCount = await recoveries.count()
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(recoveryCount, 2)
        XCTAssertEqual(runtime.state, .ready)
        await runtime.stop()
    }

    func testStopDuringConnectionCannotBecomeReady() async throws {
        let fake = RuntimeFakeTransport(blockedConnections: [1])
        let runtime = try makeRuntime(fake)
        let connection = Task { try await runtime.connect() }
        await fake.waitForConnection(1)

        await runtime.stop()
        do {
            try await connection.value
            XCTFail("a stopped connection must not succeed")
        } catch {
            // Cancellation or staleOperation are both fail-closed outcomes.
        }
        XCTAssertEqual(runtime.state, .stopped)
        let connectionCount = await fake.connectionCount()
        XCTAssertEqual(connectionCount, 1)
    }

    func testExternalCloseDuringRecoveryDoesNotBecomeReady() async throws {
        let fake = RuntimeFakeTransport()
        let runtime = try makeRuntime(fake)
        let recovery = RecoveryGate()
        _ = runtime.observe(event: { _ in }, recover: { _ in await recovery.run() })

        try await runtime.connect()
        await recovery.blockNext()
        let reconnect = Task { try await runtime.reconnect() }
        await recovery.waitForCall(2)

        // The socket can disappear while a reconciliation hook is suspended.
        await fake.externalClose()
        await recovery.release()
        do {
            try await reconnect.value
            XCTFail("a closed transport must not be reported ready")
        } catch {
            // The runtime rejects the stale transport generation.
        }
        XCTAssertEqual(runtime.state, .disconnected)
        await runtime.stop()
    }

    func testStaleFramesFromPreviousTransportGenerationAreIgnored() async throws {
        let fake = RuntimeFakeTransport()
        let runtime = try makeRuntime(fake)
        let events = EventProbe()
        _ = runtime.observe(event: { event in Task { await events.record(event) } }, recover: { _ in })

        try await runtime.connect()
        try await runtime.reconnect()
        await fake.emit(event: makeEvent(generation: 1, type: "stale"))
        await fake.emit(event: makeEvent(generation: 2, type: "current"))
        await events.waitForCount(1)

        let receivedTypes = await events.values().map(\.type)
        XCTAssertEqual(receivedTypes, ["current"])
        await runtime.stop()
    }

    func testGenerationBarrierDeliversBufferedFrameOnlyAfterRecovery() async throws {
        let fake = RuntimeFakeTransport(blockedConnections: [2])
        let runtime = try makeRuntime(fake)
        let events = EventProbe()
        let recovery = RecoveryGate()
        var observedStates: [HermesServerRuntime.State] = []
        var readyStates: [HermesServerRuntime.State] = []
        _ = runtime.observe(event: { event in
            observedStates.append(runtime.state)
            Task { await events.record(event) }
        }, recover: { _ in await recovery.run() }, ready: { readyStates.append(runtime.state) })

        try await runtime.connect()
        await recovery.blockNext()
        let reconnect = Task { try await runtime.reconnect() }
        await fake.waitForConnection(2)
        await fake.releaseConnection(2)
        await recovery.waitForCall(2)
        await fake.emit(event: makeEvent(generation: 2, type: "buffered"))
        await Task.yield()
        let countBeforeRecovery = await events.count()
        XCTAssertEqual(countBeforeRecovery, 0)
        XCTAssertEqual(readyStates, [.ready], "Reconnect readiness must wait for every recovery")

        await recovery.release()
        try await reconnect.value
        await events.waitForCount(1)
        let receivedTypes = await events.values().map(\.type)
        XCTAssertEqual(receivedTypes, ["buffered"])
        XCTAssertEqual(observedStates, [.ready])
        XCTAssertEqual(readyStates, [.ready, .ready])
        XCTAssertEqual(runtime.state, .ready)
        await runtime.stop()
    }

    func testReadyRuntimeRecoversAfterMatchingLocalCloseAndIgnoresStaleClose() async throws {
        let fake = RuntimeFakeTransport()
        let runtime = try makeRuntime(fake)
        let events = EventProbe()
        var recoveryCount = 0
        let recovered = expectation(description: "automatic recovery reaches ready")
        let staleAndProbeDelivered = expectation(description: "stale close is processed without recovery")
        staleAndProbeDelivered.assertForOverFulfill = false
        _ = runtime.observe(event: { event in
            Task { await events.record(event) }
            if event.type == "probe" { staleAndProbeDelivered.fulfill() }
        }, recover: { _ in
            recoveryCount += 1
            if recoveryCount == 2 { recovered.fulfill() }
        })

        try await runtime.connect()
        XCTAssertEqual(recoveryCount, 1)

        // A close from an obsolete socket generation must not demote a ready
        // runtime or schedule its recovery loop.
        await fake.emit(event: makeEvent(generation: 999, type: "transport.closed", method: "local"))
        await fake.emit(event: makeEvent(generation: 1, type: "probe"))
        await fulfillment(of: [staleAndProbeDelivered], timeout: 1)
        XCTAssertEqual(runtime.state, .ready)
        XCTAssertEqual(recoveryCount, 1)

        await fake.emit(event: makeEvent(generation: 1, type: "transport.closed", method: "local"))
        await fulfillment(of: [recovered], timeout: 5)
        await Task.yield()
        XCTAssertEqual(runtime.state, .ready)
        let connectionCount = await fake.connectionCount()
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(recoveryCount, 2)
        await runtime.stop()
    }

    func testObserverRemovalDuringRecoveryDropsItsBufferedEvents() async throws {
        let fake = RuntimeFakeTransport()
        let runtime = try makeRuntime(fake)
        let removedEvents = EventProbe()
        let retainedEvents = EventProbe()
        let recovery = RecoveryGate()
        let removedID = runtime.observe(event: { event in Task { await removedEvents.record(event) } }, recover: { _ in await recovery.run() })
        _ = runtime.observe(event: { event in Task { await retainedEvents.record(event) } }, recover: { _ in })

        try await runtime.connect()
        await recovery.blockNext()
        let reconnect = Task { try await runtime.reconnect() }
        await recovery.waitForCall(2)
        await fake.emit(event: makeEvent(generation: 2, type: "only-retained"))
        runtime.removeObserver(removedID)
        await recovery.release()
        try await reconnect.value
        await retainedEvents.waitForCount(1)

        let removedCount = await removedEvents.count()
        let retainedTypes = await retainedEvents.values().map(\.type)
        XCTAssertEqual(removedCount, 0)
        XCTAssertEqual(retainedTypes, ["only-retained"])
        await runtime.stop()
    }

    func testRequestIsNotReplayedAfterAmbiguousTransportFailure() async throws {
        let fake = RuntimeFakeTransport(failingMethods: ["prompt.submit"])
        let runtime = try makeRuntime(fake)
        try await runtime.connect()

        do {
            _ = try await runtime.request("prompt.submit", params: ["text": .string("one")])
            XCTFail("the transport failure should be surfaced")
        } catch {
            // A lost acknowledgement is ambiguous and must not be retried.
        }
        let methods = await fake.methods()
        XCTAssertEqual(methods, ["prompt.submit"])
        XCTAssertEqual(runtime.state, .disconnected)
        await runtime.stop()
    }

    func testReconnectRebindsOnceAndNeverSubmitsPrompt() async throws {
        let fake = RuntimeFakeTransport()
        let runtime = try makeRuntime(fake)
        let recoveries = RecoveryProbe()
        _ = runtime.observe(event: { _ in }, recover: { transport in
            await recoveries.record()
            _ = try await transport.request(method: "session.resume", params: .object(["session_id": .string("stored"), "profile": .string("work")]), timeout: nil)
        })
        try await runtime.connect()
        try await runtime.reconnect()
        let methods = await fake.methods()
        let recoveryCount = await recoveries.count()
        XCTAssertEqual(methods, ["session.resume", "session.resume"])
        XCTAssertEqual(recoveryCount, 2)
        await runtime.stop()
    }

    func testStopRejectsFurtherOperations() async throws {
        let fake = RuntimeFakeTransport()
        let runtime = try makeRuntime(fake)
        await runtime.stop()
        do {
            try await runtime.connect()
            XCTFail("stopped runtime reconnected")
        } catch { XCTAssertEqual(error as? DirectSessionError, .stopped) }
        let connectionCount = await fake.connectionCount()
        XCTAssertEqual(connectionCount, 0)
    }

    func testOnlyHTTPSRootOriginsAccepted() {
        for value in [
            "http://fixture.example",
            "https://fixture.example/base",
            "https://u:p@fixture.example",
            "https://fixture.example?token=x",
            "https://fixture.example#fragment",
            "https://fixture.example:0",
            "https://fixture.example:65536"
        ] {
            XCTAssertThrowsError(try HermesServerRuntime(origin: URL(string: value)!) { _ in RuntimeFakeTransport() }) {
                XCTAssertEqual($0 as? DirectSessionError, .invalidOrigin)
            }
        }
    }

    func testNonDefaultHTTPSPortPreservesRuntimeAndGatewayIdentity() async throws {
        let origin = try XCTUnwrap(URL(string: "https://fixture.example:8443"))
        let fake = RuntimeFakeTransport()
        let runtime = try HermesServerRuntime(origin: origin) { sink in
            fake.sinkBox.install(sink)
            return fake
        }

        XCTAssertEqual(runtime.origin, origin)
        XCTAssertEqual(try HermesServerRuntime.gatewayURL(for: origin).absoluteString, "wss://fixture.example:8443/api/ws")

        try await runtime.connect()
        _ = try await runtime.request("session.resume", params: ["session_id": .string("stored")])
        let connectionCount = await fake.connectionCount()
        let methods = await fake.methods()
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(methods, ["session.resume"])
        await runtime.stop()
    }

    private func makeRuntime(_ fake: RuntimeFakeTransport) throws -> HermesServerRuntime {
        let sinkBox = fake.sinkBox
        return try HermesServerRuntime(origin: URL(string: "https://fixture.example")!) { sink in
            sinkBox.install(sink)
            return fake
        }
    }

    private func makeEvent(generation: Int, type: String, method: String = "event") -> HermesGatewayEvent {
        HermesGatewayEvent(method: method, type: type, sessionID: "runtime", sequence: nil, payload: .object(["text": .string(type)]), params: nil, connectionGeneration: generation)
    }
}

private final class RuntimeEventSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HermesGatewayEvent) -> Void)?

    func install(_ handler: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func send(_ event: HermesGatewayEvent) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event)
    }
}

private actor RuntimeFakeTransport: HermesGatewayTransport {
    nonisolated let sinkBox: RuntimeEventSinkBox
    private var blockedConnections: Set<Int>
    private var failingMethods: Set<String>
    private var connections = 0
    private var closes = 0
    private var activeIdentifier: Int?
    private var recordedMethods: [String] = []
    private var connectionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedContinuations: [Int: [CheckedContinuation<Void, Error>]] = [:]

    init(blockedConnections: Set<Int> = [], failingMethods: Set<String> = []) {
        self.sinkBox = RuntimeEventSinkBox()
        self.blockedConnections = blockedConnections
        self.failingMethods = failingMethods
    }

    func connect() async throws {
        connections += 1
        let connection = connections
        signalConnectionWaiters(connection)
        if blockedConnections.contains(connection) {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    blockedContinuations[connection, default: []].append(continuation)
                }
            }, onCancel: {
                Task { await self.cancelBlockedConnection(connection) }
            })
        }
        activeIdentifier = connection
    }

    func close() async {
        closes += 1
        activeIdentifier = nil
    }

    func externalClose() {
        closes += 1
        activeIdentifier = nil
    }

    func connectionIdentifier() async -> Int? { activeIdentifier }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        recordedMethods.append(method)
        if failingMethods.remove(method) != nil { throw HermesGatewayError.transport("fixture") }
        return .object(["ok": .bool(true)])
    }

    func blockConnection(_ number: Int) { blockedConnections.insert(number) }

    func releaseConnection(_ number: Int) {
        let continuations = blockedContinuations.removeValue(forKey: number) ?? []
        continuations.forEach { $0.resume() }
    }

    func cancelBlockedConnection(_ number: Int) {
        let continuations = blockedContinuations.removeValue(forKey: number) ?? []
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }

    func waitForConnection(_ number: Int) async {
        guard connections < number else { return }
        await withCheckedContinuation { continuation in
            connectionWaiters[number, default: []].append(continuation)
        }
    }

    func emit(event: HermesGatewayEvent) { sinkBox.send(event) }
    func connectionCount() -> Int { connections }
    func closeCount() -> Int { closes }
    func methods() -> [String] { recordedMethods }

    private func signalConnectionWaiters(_ connection: Int) {
        let ready = connectionWaiters.keys.filter { $0 <= connection }
        for number in ready {
            connectionWaiters.removeValue(forKey: number)?.forEach { $0.resume() }
        }
    }
}

private actor EventProbe {
    private var events: [HermesGatewayEvent] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ event: HermesGatewayEvent) {
        events.append(event)
        let ready = waiters.keys.filter { $0 <= events.count }
        for count in ready { waiters.removeValue(forKey: count)?.forEach { $0.resume() } }
    }

    func waitForCount(_ expected: Int) async {
        guard events.count < expected else { return }
        await withCheckedContinuation { continuation in
            waiters[expected, default: []].append(continuation)
        }
    }

    func count() -> Int { events.count }
    func values() -> [HermesGatewayEvent] { events }
}

private actor RecoveryProbe {
    private var calls = 0

    func record() { calls += 1 }
    func count() -> Int { calls }
}

private actor CallLatch {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        entered = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor RecoveryGate {
    private var calls = 0
    private var blocked = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func blockNext() { blocked = true }

    func run() async {
        calls += 1
        let ready = waiters.keys.filter { $0 <= calls }
        for count in ready { waiters.removeValue(forKey: count)?.forEach { $0.resume() } }
        guard blocked else { return }
        blocked = false
        await withCheckedContinuation { continuation in blockedContinuation = continuation }
    }

    func release() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func waitForCall(_ expected: Int) async {
        guard calls < expected else { return }
        await withCheckedContinuation { continuation in waiters[expected, default: []].append(continuation) }
    }
}
