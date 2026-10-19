import Foundation
import XCTest
@testable import HermesCompanion

@MainActor
final class ResultNavigationTests: XCTestCase {
    func testResultMissingFromCachedSessionsOpensCanonicalConversation() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.close() }
        await fixture.selectCurrent()
        XCTAssertFalse(fixture.store.sessions.contains { $0.id == "result" })

        try await fixture.store.openResultConversation("result")

        XCTAssertEqual(fixture.store.selectedSession?.id, "result")
        XCTAssertEqual(fixture.store.selectedSession?.title, "Completed follow-up")
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Canonical follow-up result"])
        XCTAssertEqual(fixture.store.runState, .idle)
        XCTAssertEqual(fixture.store.controls?.model, "result-model")
        XCTAssertEqual(fixture.store.sessions.filter { $0.id == "result" }.count, 1)
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertEqual(fixture.memory.draft(for: "current"), "Unsent current conversation draft")
    }

    func testFailedResultSnapshotPreservesCurrentConversationAndDraft() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.close() }
        await fixture.selectCurrent()

        do {
            try await fixture.store.openResultConversation("missing")
            XCTFail("Opening a missing result must report its failure.")
        } catch {}

        XCTAssertEqual(fixture.store.selectedSession?.id, "current")
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Current conversation answer"])
        XCTAssertEqual(fixture.store.controls?.model, "current-model")
        XCTAssertEqual(fixture.store.draft, "Unsent current conversation draft")
        XCTAssertEqual(fixture.memory.selectedID, "current")
        XCTAssertEqual(fixture.memory.draft(for: "current"), "Unsent current conversation draft")
        XCTAssertEqual(fixture.store.sessions.map(\.id), ["current"])
    }

    func testHeldResultSnapshotCannotReplaceNewHostConversation() async throws {
        let started = expectation(description: "The old host result snapshot is pending")
        let fixture = try NavigationFixture(heldRoute: "GET /v1/sessions/result/snapshot", started: started)
        defer { fixture.close() }
        await fixture.selectCurrent()
        let navigation = Task { try await fixture.store.openResultConversation("result") }
        defer { navigation.cancel() }
        let handoff = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(handoff, .completed)
        guard handoff == .completed else { return }

        await fixture.selectOtherHost()
        try fixture.exchange.release()
        _ = try? await navigation.value

        assertOtherHostRemainsSelected(fixture)
        XCTAssertFalse(fixture.store.sessions.contains { $0.id == "result" })
    }

    func testHeldNewSessionResponseCannotReplaceNewHostConversation() async throws {
        let started = expectation(description: "The old host new conversation request is pending")
        let fixture = try NavigationFixture(heldRoute: "POST /v1/sessions", started: started)
        defer { fixture.close() }
        await fixture.selectCurrent()
        let creation = Task { await fixture.store.newSession() }
        defer { creation.cancel() }
        let handoff = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(handoff, .completed)
        guard handoff == .completed else { return }

        await fixture.selectOtherHost()
        try fixture.exchange.release()
        await creation.value

        assertOtherHostRemainsSelected(fixture)
        XCTAssertFalse(fixture.store.sessions.contains { $0.id == "created-on-old-host" })
    }

    private func assertOtherHostRemainsSelected(_ fixture: NavigationFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.store.grant?.host.name, "Other host", file: file, line: line)
        XCTAssertEqual(fixture.store.selectedSession?.id, "other-current", file: file, line: line)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Other host answer"], file: file, line: line)
        XCTAssertEqual(fixture.store.draft, "Unsent other host draft", file: file, line: line)
        XCTAssertEqual(fixture.otherMemory.selectedID, "other-current", file: file, line: line)
        XCTAssertEqual(fixture.otherMemory.draft(for: "other-current"), "Unsent other host draft", file: file, line: line)
        XCTAssertEqual(fixture.memory.draft(for: "current"), "Unsent current conversation draft", file: file, line: line)
    }
}

@MainActor
private final class NavigationFixture {
    let suite = "result-navigation-" + UUID().uuidString
    let defaults: UserDefaults
    let session: URLSession
    let store: AppStore
    let memory: ConversationMemory
    let otherMemory: ConversationMemory
    let exchange: NavigationExchange
    let baseURL: URL
    let otherURL: URL

    init(heldRoute: String? = nil, started: XCTestExpectation? = nil) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        memory = ConversationMemory(hostID: "original-host", defaults: defaults)
        otherMemory = ConversationMemory(hostID: "other-host", defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NavigationProtocol.self]
        session = URLSession(configuration: configuration)
        baseURL = try XCTUnwrap(URL(string: "https://original-\(UUID().uuidString).invalid"))
        otherURL = try XCTUnwrap(URL(string: "https://other-\(UUID().uuidString).invalid"))
        exchange = NavigationExchange(responses: [
            "GET /v1/sessions/current/snapshot": try .encoded(Self.snapshot(id: "current", title: "Current conversation", text: "Current conversation answer")),
            "GET /v1/sessions/result/snapshot": try .encoded(Self.snapshot(id: "result", title: "Completed follow-up", text: "Canonical follow-up result")),
            "GET /v1/sessions/other-current/snapshot": try .encoded(Self.snapshot(id: "other-current", title: "Other conversation", text: "Other host answer")),
            "POST /v1/sessions": try .encoded(ChatSession(id: "created-on-old-host", title: "Old host creation", updatedAt: "", profile: "test"))
        ], heldRoute: heldRoute, started: started)
        NavigationProtocol.register(exchange, for: baseURL)
        NavigationProtocol.register(exchange, for: otherURL)
        store = AppStore(api: .init(baseURL: baseURL, token: nil, session: session), journal: OperationJournal(defaults: defaults), memory: memory)
        store.connection = "Connected"
    }

    func selectCurrent() async {
        let current = ChatSession(id: "current", title: "Current conversation", updatedAt: "", profile: "test")
        store.sessions = [current]
        await store.select(current)
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Current conversation answer"])
        store.draft = "Unsent current conversation draft"
    }

    func selectOtherHost() async {
        let grant = DeviceGrant(baseURL: otherURL.absoluteString, deviceID: "synthetic-other-device", token: "synthetic-test-grant", host: .init(name: "Other host", profile: "test"))
        store.usePairedHost(grant, api: .init(baseURL: otherURL, token: nil, session: session), memory: otherMemory)
        let current = ChatSession(id: "other-current", title: "Other conversation", updatedAt: "", profile: "test")
        store.sessions = [current]
        await store.select(current)
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Other host answer"])
        store.draft = "Unsent other host draft"
    }

    func close() {
        session.invalidateAndCancel()
        NavigationProtocol.unregister(baseURL)
        NavigationProtocol.unregister(otherURL)
        defaults.removePersistentDomain(forName: suite)
    }

    private static func snapshot(id: String, title: String, text: String) -> SessionSnapshot {
        .init(session: .init(id: id, title: title, updatedAt: "", profile: "test"),
              page: .init(messages: [.init(id: id + "-answer", role: "assistant", text: text, provisional: false)], before: nil, hasMore: false),
              state: .idle, requests: [],
              controls: .init(model: id + "-model", provider: "synthetic", pendingModel: nil, reasoning: "low", reasoningLevels: ["low"], models: [], commands: []))
    }
}

private struct NavigationResponse: Sendable {
    let status: Int
    let data: Data

    static func encoded<T: Encodable>(_ value: T) throws -> Self {
        .init(status: 200, data: try CompanionAPI.encoder.encode(value))
    }

    static let missing = Self(status: 404, data: Data(#"{"error":{"code":"not_found","message":"Synthetic result unavailable"}}"#.utf8))
}

private final class NavigationExchange: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: NavigationResponse]
    private let heldRoute: String?
    private let started: XCTestExpectation?
    private var pending: (NavigationProtocol, NavigationResponse)?

    init(responses: [String: NavigationResponse], heldRoute: String?, started: XCTestExpectation?) {
        self.responses = responses
        self.heldRoute = heldRoute
        self.started = started
    }

    func accept(_ request: NavigationProtocol) {
        let route = (request.request.httpMethod ?? "GET") + " " + (request.request.url?.path ?? "")
        let response = responses[route] ?? .missing
        if route == heldRoute {
            lock.withLock { pending = (request, response) }
            started?.fulfill()
        } else { request.respond(response) }
    }

    func release() throws {
        let response = lock.withLock {
            let value = pending
            pending = nil
            return value
        }
        let (request, result) = try XCTUnwrap(response, "The request must be held before its response is released.")
        request.respond(result)
    }
}

private final class NavigationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var exchanges: [String: NavigationExchange] = [:]

    static func register(_ exchange: NavigationExchange, for url: URL) {
        lock.withLock { exchanges[url.host!] = exchange }
    }

    static func unregister(_ url: URL) {
        _ = lock.withLock { exchanges.removeValue(forKey: url.host!) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let exchange = Self.lock.withLock { Self.exchanges[request.url?.host ?? ""] }
        guard let exchange else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        exchange.accept(self)
    }

    func respond(_ result: NavigationResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
