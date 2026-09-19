import Foundation
import XCTest
@testable import HermesMobile

final class HermesGatewayClientTests: XCTestCase {
    func testConnectWaitsForReadyAndPingCorrelatesResponse() async throws {
        let socketBox = LockedBox<FakeGatewaySocket?>(nil)
        let requestBox = LockedBox<URLRequest?>(nil)
        let ticketCount = LockedBox(0)
        let client = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: {
                ticketCount.withValue { $0 += 1 }
                return "fresh-ticket"
            },
            socketFactory: { request in
                requestBox.value = request
                let socket = FakeGatewaySocket()
                socketBox.value = socket
                return socket
            }
        )

        let connectTask = Task { try await client.connect() }
        let socket = try await waitForValue(socketBox)
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":true},"future_field":"ignored"}}"#)
        try await connectTask.value

        XCTAssertEqual(ticketCount.value, 1)
        XCTAssertEqual(requestBox.value?.url?.query, "ticket=fresh-ticket")

        let pingTask = Task { try await client.ping() }
        let sent = try await socket.waitForSentMessage()
        let id = try Self.id(from: sent)
        socket.emit(#"{"jsonrpc":"2.0","id":\#(id),"result":{"ok":true,"new_field":"ignored"}}"#)
        let result = try await pingTask.value
        XCTAssertEqual(result, .object(["ok": .bool(true), "new_field": .string("ignored")]))

        await client.close()
    }

    func testStructuredServerErrorRetainsCorrelationContext() async throws {
        let socketBox = LockedBox<FakeGatewaySocket?>(nil)
        let client = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: { "ticket" },
            socketFactory: { _ in
                let socket = FakeGatewaySocket()
                socketBox.value = socket
                return socket
            }
        )
        let connectTask = Task { try await client.connect() }
        let socket = try await waitForValue(socketBox)
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        try await connectTask.value

        let requestTask = Task { try await client.request(method: "session.create") }
        let sent = try await socket.waitForSentMessage()
        let id = try Self.id(from: sent)
        socket.emit(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4007,"message":"session not found","data":{"retryable":false}}}"#)

        do {
            _ = try await requestTask.value
            XCTFail("expected JSON-RPC error")
        } catch let error as HermesGatewayError {
            guard case let .server(code, message, data, method, requestID, server) = error else {
                return XCTFail("unexpected gateway error: \(error)")
            }
            XCTAssertEqual(code, 4007)
            XCTAssertEqual(message, "session not found")
            XCTAssertEqual(data, .object(["retryable": .bool(false)]))
            XCTAssertEqual(method, "session.create")
            XCTAssertEqual(requestID, id)
            XCTAssertEqual(server, "example.test")
        }

        await client.close()
    }

    func testUnknownEventFieldsAreToleratedAndDispatched() async throws {
        let socketBox = LockedBox<FakeGatewaySocket?>(nil)
        let events = LockedBox<[HermesGatewayEvent]>([])
        let client = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: { "ticket" },
            eventHandler: { event in events.withValue { $0.append(event) } },
            socketFactory: { _ in
                let socket = FakeGatewaySocket()
                socketBox.value = socket
                return socket
            }
        )
        let connectTask = Task { try await client.connect() }
        let socket = try await waitForValue(socketBox)
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        try await connectTask.value
        events.withValue { $0.removeAll() }
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"new.future.event","session_id":"runtime-1","seq":17,"payload":{"text":"hello","unknown":{"nested":true}},"unknown_param":42},"unknown_envelope":true}"#)

        let event = try await waitForCondition(events, where: { !$0.isEmpty }).first
        XCTAssertEqual(event?.type, "new.future.event")
        XCTAssertEqual(event?.sessionID, "runtime-1")
        XCTAssertEqual(event?.sequence, 17)
        XCTAssertEqual(event?.payload?.objectValueForTests?["text"], .string("hello"))

        await client.close()
    }

    func testCloseFailsPendingRequestAndTimeoutIsReported() async throws {
        let socketBox = LockedBox<FakeGatewaySocket?>(nil)
        let client = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: { "ticket" },
            requestTimeout: .seconds(2),
            socketFactory: { _ in
                let socket = FakeGatewaySocket()
                socketBox.value = socket
                return socket
            }
        )
        let connectTask = Task { try await client.connect() }
        let socket = try await waitForValue(socketBox)
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        try await connectTask.value

        let pending = Task { try await client.request(method: "prompt.submit") }
        _ = try await socket.waitForSentMessage()
        await client.close()
        do {
            _ = try await pending.value
            XCTFail("expected close error")
        } catch let error as HermesGatewayError {
            XCTAssertEqual(error, .closed)
        }

        // A fresh connection has a bounded request timeout and does not wait forever.
        let reconnect = Task { try await client.connect() }
        let replacement = try await waitForValue(socketBox, where: { $0?.isCancelled == false })
        replacement.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        try await reconnect.value
        do {
            _ = try await client.request(method: "gateway.ping", timeout: .milliseconds(25))
            XCTFail("expected request timeout")
        } catch let error as HermesGatewayError {
            guard case .timeout(method: "gateway.ping", requestID: _) = error else {
                return XCTFail("unexpected timeout error: \(error)")
            }
        }
        await client.close()
    }

    func testCloseDuringTicketMintInvalidatesConnectionGeneration() async throws {
        let gate = TicketGate()
        let factoryCalls = LockedBox(0)
        let client = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: { await gate.ticket() },
            socketFactory: { _ in
                factoryCalls.withValue { $0 += 1 }
                return FakeGatewaySocket()
            }
        )

        let connection = Task { try await client.connect() }
        await gate.waitUntilRequested()
        await client.close()
        await gate.release("ticket-after-close")

        do {
            try await connection.value
            XCTFail("close should invalidate a ticket being minted")
        } catch let error as HermesGatewayError {
            XCTAssertEqual(error, .closed)
        }
        XCTAssertEqual(factoryCalls.value, 0)
    }

    func testCancelledRequestResumesWithCancellationError() async throws {
        let socketBox = LockedBox<FakeGatewaySocket?>(nil)
        let client = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: { "ticket" },
            socketFactory: { _ in
                let socket = FakeGatewaySocket()
                socketBox.value = socket
                return socket
            }
        )
        let connectTask = Task { try await client.connect() }
        let socket = try await waitForValue(socketBox)
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        try await connectTask.value

        let request = Task { try await client.request(method: "prompt.submit") }
        _ = try await socket.waitForSentMessage()
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("expected cancellation")
        } catch let error as HermesGatewayError {
            guard case .cancelled(method: "prompt.submit", requestID: _) = error else {
                return XCTFail("unexpected cancellation error: \(error)")
            }
        }
        await client.close()
    }

    func testReplyWithoutResultOrErrorIsInvalidMessage() async throws {
        let socketBox = LockedBox<FakeGatewaySocket?>(nil)
        let client = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: { "ticket" },
            socketFactory: { _ in
                let socket = FakeGatewaySocket()
                socketBox.value = socket
                return socket
            }
        )
        let connectTask = Task { try await client.connect() }
        let socket = try await waitForValue(socketBox)
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        try await connectTask.value
        let request = Task { try await client.request(method: "gateway.ping") }
        let sent = try await socket.waitForSentMessage()
        let id = try Self.id(from: sent)
        socket.emit(#"{"jsonrpc":"2.0","id":\#(id)}"#)
        do {
            _ = try await request.value
            XCTFail("missing result must not be treated as a successful nil result")
        } catch let error as HermesGatewayError {
            XCTAssertEqual(error, .invalidMessage)
        }
        await client.close()
    }

    func testHugeSequenceIsIgnoredWithoutIntegerTrap() async throws {
        let socketBox = LockedBox<FakeGatewaySocket?>(nil)
        let events = LockedBox<[HermesGatewayEvent]>([])
        let client = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: { "ticket" },
            eventHandler: { event in events.withValue { $0.append(event) } },
            socketFactory: { _ in
                let socket = FakeGatewaySocket()
                socketBox.value = socket
                return socket
            }
        )
        let connectTask = Task { try await client.connect() }
        let socket = try await waitForValue(socketBox)
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        try await connectTask.value
        events.withValue { $0.removeAll() }
        socket.emit(#"{"jsonrpc":"2.0","method":"event","params":{"type":"future.event","seq":1e100,"payload":{}}}"#)
        let event = try await waitForCondition(events, where: { !$0.isEmpty }).first
        XCTAssertNil(event?.sequence)

        let request = Task { try await client.request(method: "gateway.ping", timeout: .milliseconds(25)) }
        _ = try await socket.waitForSentMessage()
        socket.emit(#"{"jsonrpc":"2.0","id":1e100,"result":{"ok":true}}"#)
        do {
            _ = try await request.value
            XCTFail("an out-of-range numeric id must not correlate")
        } catch let error as HermesGatewayError {
            guard case .timeout(method: "gateway.ping", requestID: _) = error else {
                return XCTFail("unexpected huge-id error: \(error)")
            }
        }
        await client.close()
    }

    func testStaticTokenAndBlankTicketAreRejected() async throws {
        let calls = LockedBox(0)
        let staticTokenClient = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws?token=static-secret")!,
            ticketProvider: { "fresh" },
            socketFactory: { _ in
                calls.withValue { $0 += 1 }
                return FakeGatewaySocket()
            }
        )
        do {
            try await staticTokenClient.connect()
            XCTFail("static token URL must be rejected")
        } catch let error as HermesGatewayError {
            XCTAssertEqual(error, .invalidGatewayURL)
        }

        let blankTicketClient = HermesGatewayClient(
            gatewayURL: URL(string: "wss://example.test/api/ws")!,
            ticketProvider: { "  " },
            socketFactory: { _ in
                calls.withValue { $0 += 1 }
                return FakeGatewaySocket()
            }
        )
        do {
            try await blankTicketClient.connect()
            XCTFail("blank ticket must be rejected")
        } catch let error as HermesGatewayError {
            XCTAssertEqual(error, .invalidGatewayURL)
        }
        XCTAssertEqual(calls.value, 0)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { withValue { $0 } }
        set { withValue { $0 = newValue } }
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

private enum FakeGatewaySocketError: Error {
    case closed
}

private enum TestWaitError: Error {
    case timeout
}

private actor TicketGate {
    private var requested = false
    private var continuation: CheckedContinuation<String, Never>?

    func ticket() async -> String {
        requested = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        while !requested {
            await Task.yield()
        }
    }

    func release(_ value: String) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private final class FakeGatewaySocket: HermesGatewayWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [URLSessionWebSocketTask.Message] = []
    private var waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var sent: [URLSessionWebSocketTask.Message] = []
    private var cancelled = false

    var isCancelled: Bool {
        withLock { cancelled }
    }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string = message else {
            XCTFail("Pinned Hermes requires JSON-RPC text frames, not binary frames")
            throw FakeGatewaySocketError.closed
        }
        withLock { sent.append(message) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) in
            let state = withLock { () -> (URLSessionWebSocketTask.Message?, Bool) in
                if !incoming.isEmpty {
                    return (incoming.removeFirst(), false)
                }
                if cancelled {
                    return (nil, true)
                }
                waiters.append(continuation)
                return (nil, false)
            }
            if let message = state.0 {
                continuation.resume(returning: message)
            } else if state.1 {
                continuation.resume(throwing: FakeGatewaySocketError.closed)
            }
        }
    }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        let pendingWaiters = withLock { () -> [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] in
            cancelled = true
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        pendingWaiters.forEach { $0.resume(throwing: FakeGatewaySocketError.closed) }
    }

    func emit(_ text: String) {
        emit(.string(text))
    }

    func emit(_ message: URLSessionWebSocketTask.Message) {
        let waiter = withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            if !waiters.isEmpty { return waiters.removeFirst() }
            incoming.append(message)
            return nil
        }
        if let waiter {
            waiter.resume(returning: message)
        }
    }

    func waitForSentMessage() async throws -> URLSessionWebSocketTask.Message {
        for _ in 0..<200 {
            if let message = withLock({ sent.first }) { return message }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw TestWaitError.timeout
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func waitForValue<Value: Sendable>(
    _ box: LockedBox<Value?>,
    where predicate: @escaping @Sendable (Value?) -> Bool = { $0 != nil }
) async throws -> Value {
    for _ in 0..<500 {
        if let value = box.value, predicate(value) { return value }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw TestWaitError.timeout
}

private func waitForCondition<Value: Sendable>(
    _ box: LockedBox<Value>,
    where predicate: @escaping @Sendable (Value) -> Bool
) async throws -> Value {
    for _ in 0..<500 {
        let value = box.value
        if predicate(value) { return value }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw TestWaitError.timeout
}

private extension JSONValue {
    var objectValueForTests: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

private extension HermesGatewayClientTests {
    static func id(from message: URLSessionWebSocketTask.Message) throws -> String {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw TestWaitError.timeout
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let number = object["id"] as? NSNumber { return number.stringValue }
        if let string = object["id"] as? String { return string }
        throw TestWaitError.timeout
    }
}
