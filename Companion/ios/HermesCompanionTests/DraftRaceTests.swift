import Foundation
import XCTest
@testable import HermesCompanion

@MainActor
final class DraftRaceTests: XCTestCase {
    func testAcceptedSendPreservesNewTypingInSameConversation() async throws {
        try await exercise(switchConversation: false)
    }

    func testAcceptedSendPreservesOtherConversationDraft() async throws {
        try await exercise(switchConversation: true)
    }

    func testAcceptedSendPreservesSameIDDraftOnAnotherPairedHost() async throws {
        try await exercise(switchConversation: false, switchHost: true)
    }

    func testModelConfirmationCannotRetargetAndValidConfirmationStillWorks() async throws {
        let suite = "model-origin-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DraftHeldProtocol.self]
        let session = URLSession(configuration: config)
        let store = AppStore(api: .init(baseURL: URL(string: "http://127.0.0.1")!, token: nil, session: session), journal: OperationJournal(defaults: defaults), memory: ConversationMemory(hostID: "model-host", defaults: defaults))
        addTeardownBlock { @MainActor in
            store.background()
            await store.waitForScheduledRefreshes().value
            session.invalidateAndCancel()
            DraftHeldProtocol.held = nil
            defaults.removePersistentDomain(forName: suite)
        }
        store.connection = "Connected"
        let first = ChatSession(id: "first", title: "First", updatedAt: "", profile: "test")
        let second = ChatSession(id: "second", title: "Second", updatedAt: "", profile: "test")
        await store.select(first)
        DraftHeldProtocol.held = nil
        let late = Task { await store.execute(.init(kind: "model", value: "expensive")) }
        addTeardownBlock { late.cancel(); _ = await late.value }
        let lateRequest = try await heldRequest()
        await store.select(second)
        lateRequest.completeConfirmation()
        let lateAccepted = await late.value
        XCTAssertFalse(lateAccepted)
        XCTAssertNil(store.confirmation)
        let selected = Task { await store.execute(.init(kind: "model", value: "expensive")) }
        addTeardownBlock { selected.cancel(); _ = await selected.value }
        try await heldRequest().completeConfirmation()
        _ = await selected.value
        let stale = try XCTUnwrap(store.confirmation)
        await store.select(first)
        XCTAssertNil(store.confirmation)
        let staleAccepted = await store.confirmModelChange(stale)
        XCTAssertFalse(staleAccepted)
        XCTAssertNil(DraftHeldProtocol.held)
        let valid = Task { await store.execute(.init(kind: "model", value: "expensive")) }
        addTeardownBlock { valid.cancel(); _ = await valid.value }
        try await heldRequest().completeConfirmation()
        _ = await valid.value
        let pending = try XCTUnwrap(store.confirmation)
        let confirmed = Task { await store.confirmModelChange(pending) }
        addTeardownBlock { confirmed.cancel(); _ = await confirmed.value }
        let confirmedRequest = try await heldRequest()
        XCTAssertEqual(confirmedRequest.request.url?.path, "/v1/sessions/first/commands")
        XCTAssertEqual(confirmedRequest.command["confirmed"] as? Bool, true)
        confirmedRequest.completeAccepted()
        let confirmedAccepted = await confirmed.value
        XCTAssertTrue(confirmedAccepted)
    }

    private func heldRequest() async throws -> DraftHeldProtocol {
        for _ in 0..<100 where DraftHeldProtocol.held == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(DraftHeldProtocol.held)
    }

    private func exercise(switchConversation: Bool, switchHost: Bool = false) async throws {
        let suite = "draft-race-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DraftHeldProtocol.self]
        let session = URLSession(configuration: config)
        let memory = ConversationMemory(hostID: "controlled-host", defaults: defaults)
        let store = AppStore(api: .init(baseURL: URL(string: "http://127.0.0.1")!, token: nil, session: session), journal: OperationJournal(defaults: defaults), memory: memory)
        addTeardownBlock { @MainActor in
            store.background()
            await store.waitForScheduledRefreshes().value
            session.invalidateAndCancel()
            DraftHeldProtocol.held = nil
            defaults.removePersistentDomain(forName: suite)
        }
        store.connection = "Connected"
        let first = ChatSession(id: "first", title: "First", updatedAt: "", profile: "test")
        let second = ChatSession(id: "second", title: "Second", updatedAt: "", profile: "test")
        await store.select(second)
        store.draft = "Unsent second conversation draft"
        await store.select(first)
        store.draft = "The submitted first conversation draft"
        DraftHeldProtocol.held = nil
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        for _ in 0..<100 where DraftHeldProtocol.held == nil { try await Task.sleep(for: .milliseconds(10)) }
        let held = try XCTUnwrap(DraftHeldProtocol.held)
        XCTAssertTrue(store.isSending)
        if switchHost {
            let other = ConversationMemory(hostID: "another-host", defaults: defaults)
            let grant = DeviceGrant(baseURL: "http://127.0.0.1:19298", deviceID: "controlled-other", token: "not-a-credential", host: .init(name: "Other", profile: "test"))
            store.usePairedHost(grant, api: .init(baseURL: URL(string: "http://127.0.0.1:19298")!, token: nil, session: session), memory: other)
            await store.select(first)
            store.draft = "The submitted first conversation draft"
        } else if switchConversation { await store.select(second) }
        else { store.draft = "New text typed while waiting" }
        let expected = store.draft
        held.completeAccepted()
        await send.value
        XCTAssertEqual(store.draft, expected)
        XCTAssertTrue(store.uncertain.isEmpty)
        if switchConversation || switchHost {
            XCTAssertFalse(store.displayMessages.contains { $0.id == "accepted-user" }, "An old submission must not appear in the new conversation or host.")
        } else {
            XCTAssertEqual(store.displayMessages.first?.id, "accepted-user")
            XCTAssertEqual(store.displayMessages.first?.text, "The submitted first conversation draft")
        }
        let restored = ConversationMemory(hostID: switchHost ? "another-host" : "controlled-host", defaults: defaults)
        XCTAssertEqual(restored.draft(for: switchConversation ? "second" : "first"), expected)
        if switchConversation { XCTAssertEqual(restored.draft(for: "first"), "") }
        if switchHost { XCTAssertEqual(ConversationMemory(hostID: "controlled-host", defaults: defaults).draft(for: "first"), "") }
    }
}

private final class DraftHeldProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: DraftHeldProtocol?
    static var held: DraftHeldProtocol? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    private var operationID = ""
    private(set) var command: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "POST" else {
            respond(status: 503, object: ["error": ["code": "host_unavailable", "message": "Controlled read unavailable"]])
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        command = object ?? [:]
        operationID = object?["operation_id"] as? String ?? "missing"
        Self.held = self
    }
    func completeAccepted() {
        respond(status: 200, object: ["operation_id": operationID.uppercased(), "status": "accepted", "user_row_id": "accepted-user"])
        Self.held = nil
    }
    func completeConfirmation() {
        respond(status: 200, object: ["operation_id": operationID, "status": "rejected", "confirmation": ["kind": "model", "value": "expensive", "provider": "controlled", "message": "Confirm model cost"]])
        Self.held = nil
    }
    private func respond(status: Int, object: [String: Any]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
