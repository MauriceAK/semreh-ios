import XCTest
@testable import HermesMobile

@MainActor
final class KanbanEventStreamClientTests: XCTestCase {
    func testDecodesStockWebSocketEnvelopeWithoutInventingHelloOrFrameID() {
        let frame = KanbanStreamFrameDecoder.decode(data: Data(#"{"events":[{"id":8,"task_id":"CARD-8","kind":"future_kind","payload":{"private":"value"},"created_at":1700000000}],"cursor":8,"future":true}"#.utf8))
        guard case let .events(events, cursor, frameID) = frame else { return XCTFail("Expected events") }
        XCTAssertEqual(cursor, 8)
        XCTAssertNil(frameID)
        XCTAssertEqual(events.first?.eventID, 8)
        XCTAssertEqual(events.first?.cardID, "CARD-8")
        XCTAssertEqual(events.first?.kind, "future_kind")
    }

    func testRejectsMalformedKnownEnvelope() {
        for data in [#"{"events":[],"cursor":-1}"#, #"{"events":[],"cursor":"bad"}"#, "not json"] {
            XCTAssertEqual(KanbanStreamFrameDecoder.decode(data: Data(data.utf8)), .malformed)
        }
    }

    func testMintsTicketBuildsExactSocketURLAndSignalsConnectedOnlyOnOpen() async {
        let socket = FakeKanbanSocket()
        var request: URLRequest?
        let client = KanbanEventStreamClient(
            customHeaderProvider: { [CustomHeader(name: "X-Proxy", value: "allowed")] },
            ticketProvider: { _ in "secret-ticket" }
        ) { built, onOpen in
            request = built
            socket.onOpen = onOpen
            return socket
        }
        var frames: [KanbanStreamFrame] = []
        client.start(url: URL(string: "https://example.test/api/plugins/kanban/events?board=main&since=7")!,
                     onFrame: { frames.append($0) }, onFailure: { XCTFail("Unexpected failure") })
        await socket.waitUntilResumed()
        XCTAssertTrue(frames.isEmpty)
        let components = URLComponents(url: try! XCTUnwrap(request?.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.scheme, "wss")
        XCTAssertEqual(components?.path, "/api/plugins/kanban/events")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Proxy"), "allowed")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })["board"]!, "main")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })["since"]!, "7")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })["ticket"]!, "secret-ticket")
        socket.open()
        await drain()
        XCTAssertEqual(frames, [.connected])
        client.stop()
    }

    func testInvalidPathOrDuplicateScopeFailsBeforeMintingTicket() async {
        let calls = LockedInteger()
        let client = KanbanEventStreamClient(ticketProvider: { _ in calls.increment(); return "ticket" }) { _, _ in
            XCTFail("Invalid targets must not create a socket")
            return FakeKanbanSocket()
        }
        var failures = 0
        for value in [
            "https://example.test/api/kanban/events?board=main&since=0",
            "https://example.test/api/plugins/kanban/events?board=main&board=other&since=0",
            "https://example.test/api/plugins/kanban/events?board=main&since=0&ticket=existing"
        ] {
            client.start(url: URL(string: value)!, onFrame: { _ in XCTFail("Unexpected frame") },
                         onFailure: { failures += 1 })
            await drain()
        }
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(failures, 3)
        client.stop()
    }

    func testStopAndRestartRejectStaleOpenFramesAndFailures() async {
        let sockets = FakeKanbanSocketFactory()
        let client = KanbanEventStreamClient(ticketProvider: { _ in "ticket" }, socketFactory: sockets.make)
        var frames: [KanbanStreamFrame] = []
        var failures = 0
        let url = URL(string: "https://example.test/api/plugins/kanban/events?board=main&since=0")!
        client.start(url: url, onFrame: { frames.append($0) }, onFailure: { failures += 1 })
        await sockets.waitForCount(1)
        let stale = sockets.sockets[0]
        client.start(url: url, onFrame: { frames.append($0) }, onFailure: { failures += 1 })
        await sockets.waitForCount(2)
        stale.open()
        stale.push(.string(#"{"events":[],"cursor":1}"#))
        stale.fail()
        sockets.sockets[1].open()
        await drain()
        XCTAssertEqual(frames, [.connected])
        XCTAssertEqual(failures, 0)
        client.stop()
    }

    private func drain() async { for _ in 0..<30 { await Task.yield() } }
}

private final class FakeKanbanSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sockets: [FakeKanbanSocket] = []
    func make(_ request: URLRequest, _ onOpen: @escaping @Sendable () -> Void) -> any KanbanWebSocket {
        let socket = FakeKanbanSocket(); socket.onOpen = onOpen
        lock.withLock { sockets.append(socket) }
        return socket
    }
    func waitForCount(_ count: Int) async { while lock.withLock({ sockets.count }) < count { await Task.yield() } }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class FakeKanbanSocket: KanbanWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var resumed = false
    var onOpen: (@Sendable () -> Void)?
    func resume() { lock.withLock { resumed = true } }
    func waitUntilResumed() async { while !lock.withLock({ resumed }) { await Task.yield() } }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { pending in
            lock.withLock { continuation = pending }
        }
    }
    func cancel() { fail(CancellationError()) }
    func open() { onOpen?() }
    func push(_ message: URLSessionWebSocketTask.Message) { lock.withLock { let c = continuation; continuation = nil; c?.resume(returning: message) } }
    func fail(_ error: Error = URLError(.networkConnectionLost)) { lock.withLock { let c = continuation; continuation = nil; c?.resume(throwing: error) } }
}
