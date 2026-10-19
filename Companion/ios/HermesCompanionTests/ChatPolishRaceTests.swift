import Foundation
import XCTest
@testable import HermesCompanion

@MainActor
final class ChatPolishRaceTests: XCTestCase {
    private var session: URLSession!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: AppStore!
    private var attachments: AttachmentDrafts!
    override func setUp() async throws {
        suite = "chat-polish-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolishHeldProtocol.self]
        session = URLSession(configuration: configuration)
        PolishHeldProtocol.reset()
        store = AppStore(api: .init(baseURL: URL(string: "http://127.0.0.1")!, token: nil, session: session), journal: OperationJournal(defaults: defaults), memory: ConversationMemory(hostID: suite, defaults: defaults))
        attachments = AttachmentDrafts(hostID: suite)
        store.attachmentDrafts = attachments
        store.connection = "Connected"
        store.selectedSession = .init(id: "first", title: "First", updatedAt: "", profile: "test")
        store.runState = .idle
    }
    override func tearDown() async throws {
        store?.background()
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: attachments.directory)
        PolishHeldProtocol.reset()
    }
    func testAcceptedSendClearsDraftAndUnlocksStopBeforeSlowReadCompletes() async throws {
        store.draft = "Accepted message"
        let send = Task { await store.send() }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        let snapshot = try await request("/snapshot")
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(store.runState, .working)
        let stop = Task { await store.execute(.init(kind: "interrupt")) }
        let interrupt = try await request("/commands", index: 1)
        XCTAssertEqual(interrupt.json["kind"] as? String, "interrupt")
        interrupt.respond(["operation_id": interrupt.json["operation_id"]!, "status": "accepted"])
        let stopped = await stop.value
        XCTAssertTrue(stopped)
        snapshot.respond(snapshotBody(text: "Accepted message"))
        await send.value
    }
    func testAcceptedRefreshDoesNotRetainStoreAfterOwnerReleasesIt() async throws {
        store.draft = "Accepted message"
        let send = Task { await store.send() }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        await send.value
        _ = try await request("/snapshot")
        weak var released = store
        store = nil
        for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(released, "An unfinished read must not retain the conversation owner.")
    }
    func testBackgroundCancelsHeldRefreshWithoutApplyingItsResponse() async throws {
        store.draft = "Accepted message"
        let send = Task { await store.send() }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        await send.value
        let snapshot = try await request("/snapshot")
        store.background()
        for _ in 0..<100 where !snapshot.wasStopped { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(snapshot.wasStopped)
        XCTAssertEqual(store.connection, "Paused")
        XCTAssertTrue(store.transcript.messages.isEmpty)
    }
    func testLatestWaitsForNewWindowAndDiscardsOlderResponse() async throws {
        try store.transcript.replace(.init(messages: [.init(id: "old", role: "assistant", text: "Old", provisional: false)], before: "cursor", hasMore: true))
        let originalRevision = store.latestRevision
        let older = Task { await store.loadOlder() }
        let oldRequest = try await request("/history")
        let latest = Task { await store.latest() }
        let latestRequest = try await request("/snapshot")
        XCTAssertEqual(store.latestRevision, originalRevision)
        XCTAssertEqual(store.transcript.messages.first?.id, "old")
        latestRequest.respond(snapshotBody(text: "Latest"))
        await latest.value
        XCTAssertNotEqual(store.latestRevision, originalRevision)
        oldRequest.respond(["messages": [["id": "stale", "role": "assistant", "text": "Stale", "provisional": false]], "before": NSNull(), "has_more": false])
        await older.value
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Latest"])
        XCTAssertFalse(store.isReadingHistory)
    }
    func testNewOlderIntentCancelsPendingLatestJump() async throws {
        try store.transcript.replace(.init(messages: [.init(id: "old", role: "assistant", text: "Old", provisional: false)], before: "cursor", hasMore: true))
        let revision = store.latestRevision
        let latest = Task { await store.latest() }
        let latestRequest = try await request("/snapshot")
        let older = Task { await store.loadOlder() }
        let oldRequest = try await request("/history")
        oldRequest.respond(["messages": [["id": "earlier", "role": "assistant", "text": "Earlier", "provisional": false]], "before": NSNull(), "has_more": false])
        await older.value
        latestRequest.respond(snapshotBody(text: "Wrong window"))
        await latest.value
        XCTAssertEqual(store.latestRevision, revision)
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Earlier", "Old"])
        XCTAssertTrue(store.isReadingHistory)
    }
    func testCompletedImportStaysWithOriginalConversation() async throws {
        let context = try XCTUnwrap(store.beginAttachmentImport(name: "note.txt"))
        store.selectedSession = .init(id: "second", title: "Second", updatedAt: "", profile: "test")
        let payload = try payload()
        store.finishAttachmentImport(context, result: .success(payload))
        XCTAssertTrue(store.attachments.isEmpty)
        XCTAssertEqual(attachments.items(for: "first").first?.payload?.name, "note.txt")
        XCTAssertEqual(AttachmentDrafts(hostID: suite).items(for: "first").count, 1)
    }
    func testConversationSwitchDuringUploadNeverSendsToNewSession() async throws {
        let item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        attachments.set([item], for: "first")
        store.draft = "Read this"
        let send = Task { await store.send() }
        let upload = try await request("/attachments")
        store.selectedSession = .init(id: "second", title: "Second", updatedAt: "", profile: "test")
        upload.respond(["id": "ticket", "name": "note.txt", "media_type": "text/plain", "byte_count": 5, "status": "ready"])
        await send.value
        XCTAssertTrue(PolishHeldProtocol.requests.filter { $0.request.url?.path.hasSuffix("/commands") == true }.isEmpty)
        XCTAssertTrue(store.attachments.isEmpty)
        XCTAssertEqual(attachments.items(for: "first").first?.ticket?.id, "ticket")
    }
    func testStopDuringUploadRetainsTicketAndCancelsPendingSend() async throws {
        let item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        attachments.set([item], for: "first")
        store.draft = "A direction"
        store.runState = .working
        let send = Task { await store.send() }
        let upload = try await request("/attachments")
        let stop = Task { await store.execute(.init(kind: "interrupt")) }
        let interrupt = try await request("/commands")
        XCTAssertEqual(interrupt.json["kind"] as? String, "interrupt")
        interrupt.respond(["operation_id": interrupt.json["operation_id"]!, "status": "accepted"])
        let stopped = await stop.value
        XCTAssertTrue(stopped)
        XCTAssertTrue(store.isSending)
        upload.respond(["id": "ticket", "name": "note.txt", "media_type": "text/plain", "byte_count": 5, "status": "ready"])
        await send.value
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.draft, "A direction")
        XCTAssertEqual(store.attachments.first?.ticket?.id, "ticket")
        XCTAssertEqual(PolishHeldProtocol.requests.filter { $0.request.url?.path.hasSuffix("/commands") == true }.count, 1)
    }
    func testExplicitRetryUsesNewUploadOperationAndUncertainCannotRetry() async throws {
        var item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        item.uploadError = "Rejected"
        attachments.set([item], for: "first")
        XCTAssertFalse(store.canSendDraft)
        store.retryAttachmentUpload(item)
        let retry = try XCTUnwrap(store.attachments.first)
        XCTAssertNotEqual(retry.uploadOperationID, item.uploadOperationID)
        XCTAssertTrue(store.canSendDraft)
        var uncertain = retry
        uncertain.uncertainUpload = true
        uncertain.uploadError = "Upload not confirmed"
        attachments.set([uncertain], for: "first")
        store.retryAttachmentUpload(uncertain)
        XCTAssertEqual(store.attachments.first?.uploadOperationID, uncertain.uploadOperationID)
        XCTAssertFalse(store.canSendDraft)
    }
    func testQueuedAttachmentReceiptClearsOnlySubmittedDraftItems() async throws {
        let first = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        attachments.set([first], for: "first")
        store.draft = "Read after this task"
        store.runState = .working
        let send = Task { await store.send() }
        let upload = try await request("/attachments")
        upload.respond(["id": "ticket", "name": "note.txt", "media_type": "text/plain", "byte_count": 5, "status": "ready"])
        let command = try await request("/commands")
        XCTAssertEqual(command.json["attachment_ids"] as? [String], ["ticket"])
        let later = DraftAttachment(id: UUID(), name: "later.txt", state: .ready(try payload()))
        attachments.set(store.attachments + [later], for: "first")
        store.draft = "A later draft"
        command.respond(["operation_id": command.json["operation_id"]!, "status": "queued"])
        await send.value
        XCTAssertEqual(store.draft, "A later draft")
        XCTAssertEqual(store.attachments.map(\.id), [later.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.payload!.fileURL.path))
    }
    func testRejectedUploadPreservesDraftAndFile() async throws {
        let item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        attachments.set([item], for: "first")
        store.draft = "Read this"
        let send = Task { await store.send() }
        let upload = try await request("/attachments")
        upload.respond(["error": ["code": "unsupported_attachment", "message": "Unsupported file"]], status: 400)
        await send.value
        XCTAssertEqual(store.draft, "Read this")
        XCTAssertEqual(store.attachments.count, 1)
        XCTAssertFalse(store.attachments[0].uncertainUpload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.payload!.fileURL.path))
    }
    private func payload() throws -> AttachmentPayload {
        let url = attachments.directory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: url)
        return .init(fileURL: url, name: "note.txt", mediaType: "text/plain", byteCount: 5, previewURL: nil)
    }
    private func request(_ suffix: String, index: Int = 0) async throws -> PolishHeldProtocol {
        for _ in 0..<200 {
            let found = PolishHeldProtocol.requests.filter { $0.request.url?.path.hasSuffix(suffix) == true }
            if found.count > index { return found[index] }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Missing held request " + suffix)
        throw ClientError.invalidResponse
    }
    private func snapshotBody(text: String) -> [String: Any] {
        ["session": ["id": "first", "title": "First", "updated_at": "", "profile": "test"],
         "page": ["messages": [["id": "latest", "role": "assistant", "text": text, "provisional": false]], "before": NSNull(), "has_more": false],
         "state": "working", "requests": [],
         "controls": ["model": "test", "provider": "test", "pending_model": NSNull(), "reasoning": "medium", "reasoning_levels": [], "models": [], "commands": []]]
    }
}

private final class PolishHeldProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [PolishHeldProtocol] = []
    static var requests: [PolishHeldProtocol] { lock.withLock { held } }
    static func reset() { lock.withLock { held = [] } }
    private(set) var json: [String: Any] = [:]
    private var stopped = false
    var wasStopped: Bool { Self.lock.withLock { stopped } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.withLock { Self.held.append(self) }
    }
    func respond(_ object: [String: Any], status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { stopped = true } }
}
