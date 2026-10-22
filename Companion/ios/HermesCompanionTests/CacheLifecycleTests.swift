import Foundation
import XCTest
@testable import HermesCompanion

@MainActor
final class CacheLifecycleTests: XCTestCase {
    func testColdCachedRowsDraftAndAnchorAppearBeforeHeldSnapshotWithoutAuthority() async throws {
        let started = expectation(description: "Snapshot is held")
        let fixture = try CacheLifecycleFixture(held: "/v1/sessions/saved/snapshot", started: started)
        addTeardownBlock { @MainActor in await fixture.close() }
        try await fixture.seed()
        fixture.attach()
        let sync = Task { try await fixture.store.synchronize() }
        addTeardownBlock { sync.cancel(); _ = try? await sync.value }
        let completion = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(completion, .completed)
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Cached answer"])
        XCTAssertEqual(fixture.store.draft, "Independent draft")
        XCTAssertEqual(fixture.store.readerRestoration?.position, .anchored(messageID: "cached-row", offsetFromUsableTop: 17))
        XCTAssertFalse(fixture.store.canCommand)
        let accepted = await fixture.store.execute(.init(kind: "answer", requestId: "cached", generation: "stale", answer: "allow"))
        XCTAssertFalse(accepted)
        XCTAssertFalse(fixture.exchange.requested.contains { $0.hasSuffix("/commands") })
        XCTAssertEqual(fixture.store.statusLabel, "")
        try fixture.store.receive(Self.connection("connected"))
        XCTAssertFalse(fixture.store.canCommand)
        fixture.exchange.release()
        try await sync.value
        XCTAssertTrue(fixture.store.canCommand)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Cached answer"])
        XCTAssertTrue(fixture.store.newActivity)
    }

    func testFreshSnapshotWinsOverHeldDiskRead() async throws {
        let started = expectation(description: "Disk restore is held")
        let gate = CacheReadGate(started: started)
        let fixture = try CacheLifecycleFixture(beforeRead: { await gate.wait() })
        addTeardownBlock { @MainActor in await gate.release(); await fixture.close() }
        try await fixture.seed()
        fixture.attach()
        let completion = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(completion, .completed)
        try fixture.store.receiveFreshSnapshotForTesting(messages: [.init(id: "fresh", role: "assistant", text: "Fresh answer", provisional: false)])
        await gate.release()
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Fresh answer"])
        XCTAssertNil(fixture.store.readerRestoration)
        XCTAssertTrue(fixture.store.canCommand)
    }

    func testHeldOldHostSynchronizationCannotPublishIntoReplacementHost() async throws {
        let started = expectation(description: "Old host status is held")
        let fixture = try CacheLifecycleFixture(held: "/v1/host", started: started)
        addTeardownBlock { @MainActor in await fixture.close() }
        fixture.attach()
        fixture.store.sessions = [.init(id: "old-only", title: "Old host", updatedAt: "", profile: "test")]
        let sync = Task { try await fixture.store.synchronize() }
        addTeardownBlock { sync.cancel(); _ = try? await sync.value }
        let completion = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(completion, .completed)
        let replacement = DeviceGrant(baseURL: fixture.url.absoluteString + "/replacement", deviceID: "replacement", token: "synthetic", host: .init(name: "Replacement", profile: "test"))
        let memory = ConversationMemory(hostID: "replacement", defaults: fixture.defaults)
        memory.select("saved")
        memory.saveDraft("Replacement draft", for: "saved")
        fixture.store.usePairedHost(replacement, api: fixture.api, memory: memory)
        XCTAssertTrue(fixture.store.sessions.isEmpty)
        XCTAssertTrue(fixture.store.transcript.messages.isEmpty)
        XCTAssertNil(fixture.store.controls)
        XCTAssertTrue(fixture.store.requests.isEmpty)
        XCTAssertFalse(fixture.store.canCommand)
        try fixture.store.receiveFreshSnapshotForTesting(messages: [.init(id: "replacement-row", role: "assistant", text: "Replacement answer", provisional: false)])
        fixture.exchange.release()
        do { try await sync.value; XCTFail("A replaced host must cancel its old synchronization.") } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(fixture.store.grant?.deviceID, "replacement")
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Replacement answer"])
        XCTAssertEqual(fixture.store.draft, "Replacement draft")
        XCTAssertNil(fixture.store.hostStatus)
        XCTAssertNil(fixture.store.connectionError)
    }

    func testRestoredSelectionOutsideSessionListIsFetchedDirectly() async throws {
        let fixture = try CacheLifecycleFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        fixture.attach()
        try await fixture.store.synchronize()
        XCTAssertEqual(fixture.store.selectedSession?.id, "saved")
        XCTAssertTrue(fixture.exchange.requested.contains("/v1/sessions/saved/snapshot"))
        XCTAssertFalse(fixture.exchange.requested.contains("/v1/sessions/recent/snapshot"))
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Fresh answer"])
        XCTAssertTrue(fixture.store.canCommand)
        fixture.store.background()
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Fresh answer"])
        XCTAssertEqual(fixture.store.statusLabel, "")
        try fixture.store.receive(Self.connection("connected"))
        XCTAssertFalse(fixture.store.canCommand)
    }

    func testWarmSelectionRestoresSynchronouslyAndOldRendererCannotChangeAnchor() async throws {
        let fixture = try CacheLifecycleFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        fixture.attach()
        try await fixture.store.synchronize()
        let saved = try XCTUnwrap(fixture.store.selectedSession)
        let oldContext = try XCTUnwrap(fixture.store.readerContext)
        fixture.store.readerPositionChanged(.anchored(messageID: "fresh-row", offsetFromUsableTop: 8), context: oldContext)
        await fixture.store.select(.init(id: "other", title: "Other", updatedAt: "", profile: "test"))
        await fixture.store.select(saved)
        XCTAssertEqual(fixture.store.readerRestoration?.position, .anchored(messageID: "fresh-row", offsetFromUsableTop: 8))
        fixture.store.readerPositionChanged(.anchored(messageID: "wrong", offsetFromUsableTop: 100), context: oldContext)
        XCTAssertEqual(fixture.store.readerRestoration?.position, .anchored(messageID: "fresh-row", offsetFromUsableTop: 8))
    }

    func testDuplicateForegroundKeepsOneActiveSynchronization() async throws {
        let started = expectation(description: "The sole synchronization is held")
        let fixture = try CacheLifecycleFixture(held: "/v1/host", started: started)
        addTeardownBlock { @MainActor in await fixture.close() }
        fixture.attach()
        fixture.store.foreground()
        fixture.store.foreground()
        fixture.store.foreground()
        let completion = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(completion, .completed)
        fixture.store.foreground()
        XCTAssertEqual(fixture.exchange.requested.filter { $0 == "/v1/host" }.count, 1)
        fixture.store.background()
        XCTAssertNil(fixture.store.connectionError)
        XCTAssertFalse(fixture.store.canCommand)
    }

    private static func connection(_ state: String) throws -> WireEvent {
        try CompanionAPI.decoder.decode(WireEvent.self, from: JSONSerialization.data(withJSONObject: ["type": "connection", "payload": ["state": state]]))
    }
}

private actor CacheReadGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        guard !released else { return }
        started.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CacheLifecycleFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let defaults: UserDefaults
    let session: URLSession
    let url: URL
    let grant: DeviceGrant
    let memory: ConversationMemory
    let api: CompanionAPI
    let cache: ConversationDisplayCache
    let store: AppStore
    let exchange: CacheExchange

    init(held: String? = nil, started: XCTestExpectation? = nil, beforeRead: (@Sendable () async -> Void)? = nil) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        url = URL(string: "https://cache-\(UUID().uuidString).invalid")!
        grant = .init(baseURL: url.absoluteString, deviceID: "synthetic-device", token: "synthetic", host: .init(name: "Cache test", profile: "test"))
        memory = ConversationMemory(hostID: suite, defaults: defaults)
        memory.select("saved")
        memory.saveDraft("Independent draft", for: "saved")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheProtocol.self]
        session = URLSession(configuration: configuration)
        api = .init(baseURL: url, token: nil, session: session)
        cache = ConversationDisplayCache(directory: directory, beforeRead: beforeRead)
        exchange = CacheExchange(held: held, started: started)
        CacheProtocol.register(exchange, host: url.host!)
        store = AppStore(api: api, journal: OperationJournal(defaults: defaults), displayCache: cache)
    }
    func attach() { store.usePairedHost(grant, api: api, memory: memory) }
    func seed() async throws {
        var window = TranscriptWindow()
        try window.replace(.init(messages: [.init(id: "cached-row", role: "assistant", text: "Cached answer", provisional: false)], before: nil, hasMore: false))
        let cached = CachedConversation(scope: HostScope(grant), session: .init(id: "saved", title: "Saved", updatedAt: "", profile: "test"), window: DisplayWindow(window), recentTail: nil, reader: .anchored(messageID: "cached-row", offsetFromUsableTop: 17), fetchedAt: Date())
        await ConversationDisplayCache(directory: directory).remember(cached)
    }
    func close() async {
        store.background()
        exchange.release()
        await store.waitForScheduledRefreshes().value
        session.invalidateAndCancel()
        CacheProtocol.unregister(host: url.host!)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: store.attachmentDrafts.directory)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class CacheExchange: @unchecked Sendable {
    private let lock = NSLock()
    private let held: String?
    private let started: XCTestExpectation?
    private var pending: CacheProtocol?
    private var paths: [String] = []
    var requested: [String] { lock.withLock { paths } }
    init(held: String?, started: XCTestExpectation?) { self.held = held; self.started = started }
    func receive(_ request: CacheProtocol) {
        let path = request.request.url!.path
        let shouldHold = lock.withLock {
            paths.append(path)
            if path == held { pending = request; return true }
            return false
        }
        if shouldHold { started?.fulfill() } else { respond(request) }
    }
    func release() {
        let request = lock.withLock { let request = pending; pending = nil; return request }
        if let request { respond(request) }
    }
    private func respond(_ request: CacheProtocol) {
        let path = request.request.url!.path
        let body: [String: Any]
        switch path {
        case "/v1/host": body = ["version": 1, "profile": "test", "capabilities": ["notifications": false]]
        case "/v1/sessions": body = ["sessions": [["id": "recent", "title": "Recent", "updated_at": "", "profile": "test"]]]
        case "/v1/updates": body = ["updates": []]
        case "/v1/preferences": body = ["notifications_enabled": false, "time_zone": "UTC"]
        default:
            let id = path.contains("/other/") ? "other" : "saved"
            body = ["session": ["id": id, "title": "Fresh", "updated_at": "", "profile": "test"],
                "page": ["messages": [["id": "fresh-row", "role": "assistant", "text": "Fresh answer", "provisional": false]], "before": NSNull(), "has_more": false],
                "state": "idle", "requests": [], "controls": ["model": "test", "provider": "test", "reasoning": "medium", "reasoning_levels": [], "models": [], "commands": []]]
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        request.client?.urlProtocol(request, didReceive: HTTPURLResponse(url: request.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: data)
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

private final class CacheProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var exchanges: [String: CacheExchange] = [:]
    static func register(_ exchange: CacheExchange, host: String) { lock.withLock { exchanges[host] = exchange } }
    static func unregister(host: String) { _ = lock.withLock { exchanges.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let exchange = Self.lock.withLock { Self.exchanges[request.url!.host!] }
        exchange?.receive(self)
    }
    override func stopLoading() {}
}
