import XCTest
import UIKit
@testable import HermesCompanion

final class DomainTests: XCTestCase {
    func testInvitationRejectsRemotePlaintextAndEmbeddedCredentials() throws {
        XCTAssertThrowsError(try validatedBaseURL("http://example.com"))
        XCTAssertThrowsError(try validatedBaseURL("https://token@example.com"))
        XCTAssertThrowsError(try validatedBaseURL("https://example.com?token=secret"))
        XCTAssertNoThrow(try validatedBaseURL("http://127.0.0.1:19220"))
        XCTAssertNoThrow(try validatedBaseURL("https://relay.example.com/h/host"))
    }
    func testBaseURLPreservesRelayPath() throws {
        let api = CompanionAPI(baseURL: try validatedBaseURL("https://relay.example.com/h/one"), token: "device-test")
        let request = try api.request("v1/sessions")
        XCTAssertEqual(request.url?.path, "/h/one/v1/sessions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-test")
        XCTAssertNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query)
    }
    func testTenThousandHistoryStaysBoundedAndDeduplicated() throws {
        var window = TranscriptWindow()
        try window.replace(page(9880..<10000))
        for end in stride(from: 9880, to: 0, by: -120) {
            try window.prepend(page(max(0, end - 120)..<end))
            XCTAssertLessThanOrEqual(window.messages.count, 500)
            XCTAssertLessThanOrEqual(window.byteCount, 8 * 1024 * 1024)
            XCTAssertEqual(Set(window.messages.map(\.id)).count, window.messages.count)
        }
        XCTAssertEqual(window.messages.first?.id, "0")
        XCTAssertTrue(window.hasNewer)
        XCTAssertFalse(window.hasMore)
    }
    func testLiveDeltaCannotDisplaceOlderWindow() throws {
        var window = TranscriptWindow()
        try window.replace(page(880..<1000))
        for end in stride(from: 880, to: 280, by: -120) { try window.prepend(page((end - 120)..<end)) }
        let ids = window.messages.map(\.id)
        try window.apply(.init(id: "stream", text: "Hello", replace: false))
        XCTAssertEqual(window.messages.map(\.id), ids)
        XCTAssertTrue(window.hasNewer)
    }
    func testCanonicalSnapshotReplacesProvisionalSegment() throws {
        var window = TranscriptWindow()
        try window.replace(page(0..<1))
        try window.apply(.init(id: "live", text: "hel", replace: false))
        try window.apply(.init(id: "live", text: "lo", replace: false))
        XCTAssertEqual(window.messages.last?.text, "hello")
        try window.replace(.init(messages: [.init(id: "canonical", role: "assistant", text: "hello", provisional: false)], before: nil, hasMore: false))
        XCTAssertEqual(window.messages.map(\.id), ["canonical"])
    }
    func testOversizeBodyFailsWithoutMutatingWindow() throws {
        var window = TranscriptWindow()
        try window.replace(page(0..<10))
        let oversized = ChatMessage(id: "too-large", role: "assistant", text: String(repeating: "a", count: TranscriptWindow.maxBytes), provisional: false)
        XCTAssertThrowsError(try window.prepend(.init(messages: [oversized], before: nil, hasMore: false)))
        XCTAssertEqual(window.messages.count, 10)
    }
    func testSnakeCaseControlsAndConfirmationContract() throws {
        let data = Data(#"{"operation_id":"one","status":"rejected","confirmation":{"kind":"model","value":"expensive","provider":"provider","message":"Confirm cost"}}"#.utf8)
        let receipt = try CompanionAPI.decoder.decode(CommandReceipt.self, from: data)
        XCTAssertEqual(receipt.confirmation?.value, "expensive")
        let command = AgentCommand(kind: "model", value: "expensive", provider: "provider", confirmed: true)
        let encoded = try CompanionAPI.encoder.encode(command)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["confirmed"] as? Bool, true)
        XCTAssertNotNil(object["operation_id"])
    }
    @MainActor func testOperationJournalPersistsUncertaintyWithoutResubmission() throws {
        let suite = "hermes-unit-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = OperationJournal(defaults: defaults)
        let command = AgentCommand(kind: "send", text: "private draft")
        journal.begin(command, sessionID: "stored-session")
        let restored = OperationJournal(defaults: defaults)
        XCTAssertEqual(restored.pending.count, 1)
        XCTAssertEqual(restored.pending.first?.operationID, command.operationId)
        let data = try XCTUnwrap(defaults.data(forKey: "pending-operations-v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private draft"))
        restored.resolve(command.operationId)
        XCTAssertTrue(OperationJournal(defaults: defaults).pending.isEmpty)
    }
    func testNonSuccessReceiptPreservesUncertainOutcome() throws {
        let data = Data(#"{"operation_id":"pending","status":"uncertain","message":"May have completed"}"#.utf8)
        let receipt: CommandReceipt = try CompanionAPI.decodeResponse(data, status: 409)
        XCTAssertEqual(receipt.operationId, "pending")
        XCTAssertEqual(receipt.status, .uncertain)
        XCTAssertFalse(ClientError.server(503, "host_unavailable", "Unknown outcome").isDefiniteRejection)
        XCTAssertFalse(ClientError.server(409, "operation_conflict", "Unknown outcome").isDefiniteRejection)
        XCTAssertFalse(ClientError.server(500, "internal_error", "Unknown outcome").isDefiniteRejection)
        XCTAssertTrue(ClientError.server(409, "stale_request", "Request canceled").isDefiniteRejection)
    }
    @MainActor func testSessionStatusDoesNotDisconnectOrDisableControls() throws {
        let store = AppStore(api: CompanionAPI(baseURL: URL(string: "http://127.0.0.1")!, token: nil))
        store.selectedSession = AppStore.fixtureSession
        store.connection = "Connected"
        func event(_ session: String?, _ state: String) throws -> WireEvent {
            var object: [String: Any] = ["type": "connection", "payload": ["state": state]]
            if let session { object["session_id"] = session }
            return try CompanionAPI.decoder.decode(WireEvent.self, from: JSONSerialization.data(withJSONObject: object))
        }
        try store.receive(event("another-session", "working"))
        XCTAssertTrue(store.canCommand)
        XCTAssertEqual(store.runState, .synchronizing)
        try store.receive(event(AppStore.fixtureSession.id, "working"))
        XCTAssertEqual(store.runState, .working)
        XCTAssertTrue(store.canCommand)
        store.requests = [.init(id: "one", generation: "one", kind: "approval", title: "Approve", description: "", choices: [], allowsText: false)]
        try store.receive(event(nil, "offline"))
        XCTAssertFalse(store.canCommand)
        XCTAssertTrue(store.requests.isEmpty)
    }
    @MainActor func testUpdateStreamRemainsBounded() throws {
        let store = AppStore(api: CompanionAPI(baseURL: URL(string: "http://127.0.0.1")!, token: nil))
        for index in 0..<1000 {
            let data = Data("{\"type\":\"update\",\"payload\":{\"id\":\"update-\(index)\",\"kind\":\"result\",\"title\":\"Result\",\"summary\":\"\",\"created_at\":\"now\"}}".utf8)
            try store.receive(CompanionAPI.decoder.decode(WireEvent.self, from: data))
        }
        XCTAssertEqual(store.updates.count, 200)
        XCTAssertEqual(store.updates.first?.id, "update-999")
        XCTAssertEqual(store.updates.last?.id, "update-800")
    }
    @MainActor func testExecuteRetainsUnknownOutcomesAcrossRelaunchWithoutReplay() async throws {
        let suite = "hermes-execute-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = CompanionAPI(baseURL: URL(string: "http://127.0.0.1")!, token: nil, session: session)
        let store = AppStore(api: api, journal: OperationJournal(defaults: defaults))
        store.connection = "Connected"
        store.selectedSession = AppStore.fixtureSession
        CommandResponseProtocol.posts = 0
        CommandResponseProtocol.decodedCommands = 0
        CommandResponseProtocol.status = 409
        CommandResponseProtocol.receiptStatus = "uncertain"
        let first = AgentCommand(kind: "send", text: "Synthetic operation one")
        let firstAccepted = await store.execute(first)
        XCTAssertFalse(firstAccepted)
        XCTAssertEqual(store.currentUncertain.map(\.operationID), [first.operationId])
        CommandResponseProtocol.status = 503
        CommandResponseProtocol.receiptStatus = nil
        let second = AgentCommand(kind: "send", text: "Synthetic operation two")
        let secondAccepted = await store.execute(second)
        XCTAssertFalse(secondAccepted)
        XCTAssertEqual(Set(store.currentUncertain.map(\.operationID)), [first.operationId, second.operationId])
        XCTAssertEqual(CommandResponseProtocol.posts, 2)
        let restored = AppStore(api: api, journal: OperationJournal(defaults: defaults))
        XCTAssertEqual(Set(restored.uncertain.map(\.operationID)), [first.operationId, second.operationId])
        XCTAssertEqual(CommandResponseProtocol.posts, 2)
        CommandResponseProtocol.status = 409
        CommandResponseProtocol.receiptStatus = "rejected"
        let rejected = AgentCommand(kind: "answer", requestId: "old", generation: "old", answer: "deny")
        let rejectedAccepted = await store.execute(rejected)
        XCTAssertFalse(rejectedAccepted)
        XCTAssertEqual(Set(OperationJournal(defaults: defaults).pending.map(\.operationID)), [first.operationId, second.operationId])
        XCTAssertEqual(CommandResponseProtocol.posts, 3)
        XCTAssertEqual(CommandResponseProtocol.decodedCommands, 3)
    }
    @MainActor func testConversationAndDraftsRestoreWithoutCrossingSessionsOrHosts() async throws {
        let suite = "hermes-conversation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = CompanionAPI(baseURL: URL(string: "http://127.0.0.1")!, token: nil, session: session)
        let memory = ConversationMemory(hostID: "isolated-one", defaults: defaults)
        let store = AppStore(api: api, memory: memory)
        let first = ChatSession(id: "first", title: "First", updatedAt: "", profile: "test")
        let second = ChatSession(id: "second", title: "Second", updatedAt: "", profile: "test")
        await store.select(first)
        store.draft = "Draft for the first conversation"
        await store.select(second)
        XCTAssertEqual(store.draft, "")
        store.draft = "Draft for the second conversation"
        let restored = AppStore(api: api, memory: ConversationMemory(hostID: "isolated-one", defaults: defaults))
        XCTAssertEqual(restored.selectedSession?.id, "second")
        XCTAssertEqual(restored.draft, "Draft for the second conversation")
        await restored.select(first)
        XCTAssertEqual(restored.draft, "Draft for the first conversation")
        XCTAssertNil(ConversationMemory(hostID: "isolated-two", defaults: defaults).selectedID)
        XCTAssertEqual(ConversationMemory(hostID: "isolated-two", defaults: defaults).draft(for: "first"), "")
        XCTAssertFalse(memory.saveDraft(String(repeating: "x", count: 65537), for: "oversize"))
        XCTAssertEqual(ConversationMemory(hostID: "isolated-one", defaults: defaults).draft(for: "oversize"), "")
    }
    @MainActor func testMeasuredRowsPreserveLongCodeAndDynamicType() {
        let code = ChatMessage(id: "code", role: "assistant", text: (1...200).map { "let line\($0) = \($0) // a readable source line" }.joined(separator: "\n"), provisional: false)
        let medium = UITraitCollection(preferredContentSizeCategory: .medium)
        let large = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let normalHeight = BubbleCell.height(code, width: 402, traits: medium)
        let largeHeight = BubbleCell.height(code, width: 402, traits: large)
        XCTAssertGreaterThan(normalHeight, 2000)
        XCTAssertGreaterThan(largeHeight, normalHeight)
        XCTAssertGreaterThan(BubbleCell.height(code, width: 300, traits: medium), normalHeight)
    }
    private func page(_ range: Range<Int>) -> HistoryPage {
        .init(messages: range.map { .init(id: String($0), role: "assistant", text: "Message \($0)", provisional: false) }, before: range.lowerBound > 0 ? String(range.lowerBound) : nil, hasMore: range.lowerBound > 0)
    }
}

private final class CommandResponseProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 409
    nonisolated(unsafe) static var receiptStatus: String? = "uncertain"
    nonisolated(unsafe) static var posts = 0
    nonisolated(unsafe) static var decodedCommands = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var object: [String: Any] = ["error": ["code": "host_unavailable", "message": "Synthetic unknown outcome"]]
        if request.httpMethod == "POST" {
            Self.posts += 1
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
            if let command = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let operationID = command["operation_id"] as? String {
                Self.decodedCommands += 1
                if let state = Self.receiptStatus { object = ["operation_id": operationID, "status": state, "message": "Synthetic receipt"] }
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
