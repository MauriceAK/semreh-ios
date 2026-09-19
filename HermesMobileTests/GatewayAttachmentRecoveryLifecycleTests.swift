import Foundation
import XCTest
@testable import HermesMobile

/// Focused lifecycle coverage for the durable unresolved-attachment marker.
/// This file is intentionally unregistered until the parent worker reviews it.
@MainActor
final class GatewayAttachmentRecoveryLifecycleTests: XCTestCase {
    func testKnownThenUnknownPDFReopenBlocksPlainAndStage() async throws {
        let fake = RecoveryLifecycleFake()
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        fake.setServerError("pdf.attach", .timeout(method: "pdf.attach", requestID: "pdf-unknown"))
        let runtime = try makeRuntime(fake)
        let store = makeStore("known-unknown")
        let owner = makeController(runtime: runtime, storedID: "durable-1", store: store)
        try await owner.open()
        _ = try await owner.stageAttachment(DirectPendingAttachment(source: .image(data: imageData, filename: "photo.png")))
        do {
            _ = try await owner.stageAttachment(DirectPendingAttachment(source: .pdf(data: Data("%PDF-1.4\n".utf8), filename: "report.pdf")))
            XCTFail("The PDF transport result must remain unknown")
        } catch DirectGatewayAttachmentStageError.unknown(.pdf, _, .transport) { }
        do {
            try await owner.submit("must remain blocked")
            XCTFail("The owner must quarantine after the unknown PDF result")
        } catch DirectSessionError.unresolvedAttachment { }
        do {
            _ = try await owner.stageAttachment(DirectPendingAttachment(source: .image(data: imageData, filename: "owner-again.png")))
            XCTFail("The owner must reject another stage after the unknown PDF result")
        } catch DirectGatewayAttachmentStageError.definiteBeforeStage(.image, .unresolvedAttachment) { }

        let reopened = makeController(runtime: runtime, storedID: "durable-1", store: store)
        try await reopened.open()
        XCTAssertTrue(reopened.attachmentRecoveryNeedsReset)
        do {
            try await reopened.submit("must remain blocked")
            XCTFail("A recreated controller must not send around an unresolved stage")
        } catch DirectSessionError.unresolvedAttachment { }
        do {
            _ = try await reopened.stageAttachment(DirectPendingAttachment(source: .image(data: imageData, filename: "again.png")))
            XCTFail("A recreated controller must not stage around an unresolved stage")
        } catch DirectGatewayAttachmentStageError.definiteBeforeStage(.image, .unresolvedAttachment) { }
        await runtime.stop()
    }

    func testDurableCloseAckLostRebindsFreshRuntimeWithoutRetryingClose() async throws {
        let fake = RecoveryLifecycleFake()
        let runtime = try makeRuntime(fake)
        let store = makeStore("close-lost")
        let controller = makeController(runtime: runtime, storedID: "durable-1", store: store)
        try await controller.open()
        _ = try await controller.stageAttachment(DirectPendingAttachment(source: .image(data: imageData, filename: "photo.png")))
        let token = try XCTUnwrap(controller.unresolvedAttachmentMarkerToken)
        fake.setServerError("session.close", .timeout(method: "session.close", requestID: "close-lost"))
        fake.setResumeResponses([
            sessionBinding(runtimeID: "runtime-2", storedID: "durable-1")
        ])

        try await controller.resetPendingAttachments(expectedToken: token)
        XCTAssertFalse(controller.attachmentRecoveryNeedsReset)
        XCTAssertEqual(controller.binding?.runtimeID, "runtime-2")
        XCTAssertEqual(fake.calls.filter { $0 == "session.close" }.count, 1)
        await runtime.stop()
    }

    func testCorruptMarkerExplicitResetClosesAndRebindsFreshRuntime() async throws {
        let fake = RecoveryLifecycleFake()
        let runtime = try makeRuntime(fake)
        let store = makeStore("corrupt-reset")
        let identity = try DirectGatewayAttachmentRecoveryIdentity(
            origin: runtime.origin,
            profile: "default",
            storedID: "durable-1",
            runtimeID: "runtime-1"
        )
        try FileManager.default.createDirectory(at: storeRoot(store), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: try store.markerURL(for: identity), options: [.atomic])
        let controller = makeController(runtime: runtime, storedID: "durable-1", store: store)
        try await controller.open()
        XCTAssertTrue(controller.attachmentRecoveryNeedsReset)
        XCTAssertNil(controller.unresolvedAttachmentMarkerToken)
        fake.setResumeResponses([
            sessionBinding(runtimeID: "runtime-2", storedID: "durable-1")
        ])

        try await controller.resetPendingAttachments()
        XCTAssertFalse(controller.attachmentRecoveryNeedsReset)
        XCTAssertEqual(controller.binding?.runtimeID, "runtime-2")
        XCTAssertEqual(fake.calls.filter { $0 == "session.close" }.count, 1)
        await runtime.stop()
    }

    func testDurableSameRuntimeRebindRefusalRetainsResetBarrier() async throws {
        let fake = RecoveryLifecycleFake()
        let runtime = try makeRuntime(fake)
        let store = makeStore("same-runtime")
        let controller = makeController(runtime: runtime, storedID: "durable-1", store: store)
        try await controller.open()
        _ = try await controller.stageAttachment(DirectPendingAttachment(source: .image(data: imageData, filename: "photo.png")))
        let token = try XCTUnwrap(controller.unresolvedAttachmentMarkerToken)
        fake.setServerError("session.close", .timeout(method: "session.close", requestID: "close-lost"))
        fake.setResumeResponses([
            sessionBinding(runtimeID: "runtime-1", storedID: "durable-1")
        ])

        do {
            try await controller.resetPendingAttachments(expectedToken: token)
            XCTFail("Rebinding the same runtime cannot prove queue abandonment")
        } catch DirectSessionError.attachmentRecoveryUnavailable { }
        XCTAssertTrue(controller.attachmentRecoveryNeedsReset)
        XCTAssertEqual(fake.calls.filter { $0 == "session.close" }.count, 1)
        await runtime.stop()
    }

    func testFreshRuntimeMarkerRemainsBlockedAndIsNotDiscarded() async throws {
        let fake = RecoveryLifecycleFake()
        let runtime = try makeRuntime(fake)
        let store = makeStore("rebound-marker")
        let controller = makeController(runtime: runtime, storedID: "durable-1", store: store)
        try await controller.open()
        _ = try await controller.stageAttachment(DirectPendingAttachment(source: .image(data: imageData, filename: "old.png")))
        let oldToken = try XCTUnwrap(controller.unresolvedAttachmentMarkerToken)
        let reboundIdentity = try DirectGatewayAttachmentRecoveryIdentity(
            origin: runtime.origin,
            profile: "default",
            storedID: "durable-1",
            runtimeID: "runtime-2"
        )
        let reboundMarker = DirectGatewayAttachmentRecoveryMarker(identity: reboundIdentity)
        try store.write(reboundMarker)
        fake.setServerError("session.close", .timeout(method: "session.close", requestID: "close-lost"))
        fake.setResumeResponses([
            sessionBinding(runtimeID: "runtime-2", storedID: "durable-1")
        ])

        do {
            try await controller.resetPendingAttachments(expectedToken: oldToken)
            XCTFail("A pre-existing B marker must prevent clearing B quarantine")
        } catch DirectSessionError.unresolvedAttachment { }
        XCTAssertTrue(controller.attachmentRecoveryNeedsReset)
        XCTAssertNotNil(try store.load(for: reboundIdentity))
        do {
            try await controller.submit("blocked")
            XCTFail("The rebound runtime must remain blocked")
        } catch DirectSessionError.unresolvedAttachment { }
        await runtime.stop()
    }

    func testDraftLostCloseAck4001ProvesRuntimeGone() async throws {
        let fake = RecoveryLifecycleFake()
        let runtime = try makeRuntime(fake)
        let store = makeStore("draft-4001")
        let controller = makeController(runtime: runtime, store: store)
        _ = try await controller.stageAttachment(DirectPendingAttachment(source: .image(data: imageData, filename: "draft.png")))
        fake.setServerError("session.close", .timeout(method: "session.close", requestID: "close-lost"))
        fake.setServerError("session.status", .server(
            code: 4001,
            message: "session not found",
            data: nil,
            method: "session.status",
            requestID: "status-missing",
            server: "fixture"
        ))

        try await controller.resetPendingAttachments(expectedToken: try XCTUnwrap(controller.unresolvedAttachmentMarkerToken))
        XCTAssertFalse(controller.attachmentRecoveryNeedsReset)
        XCTAssertNil(controller.binding)
        await runtime.stop()
    }

    func testDraftLostCloseAckMissingProofRemainsBlocked() async throws {
        let cases: [HermesGatewayError] = [
            .transport("status unavailable"),
            .server(code: 4001, message: "wrong method", data: nil, method: "other.method", requestID: "wrong", server: "fixture")
        ]
        for (index, statusError) in cases.enumerated() {
            let fake = RecoveryLifecycleFake()
            let runtime = try makeRuntime(fake)
            let store = makeStore("draft-missing-\(index)")
            let controller = makeController(runtime: runtime, store: store)
            _ = try await controller.stageAttachment(DirectPendingAttachment(source: .image(data: imageData, filename: "draft.png")))
            fake.setServerError("session.close", .timeout(method: "session.close", requestID: "close-lost"))
            fake.setServerError("session.status", statusError)
            do {
                try await controller.resetPendingAttachments(expectedToken: try XCTUnwrap(controller.unresolvedAttachmentMarkerToken))
                XCTFail("Missing exact 4001 session.status proof must remain blocked")
            } catch DirectSessionError.attachmentRecoveryUnavailable { }
            catch DirectSessionError.staleOperation { }
            XCTAssertTrue(controller.attachmentRecoveryNeedsReset)
            XCTAssertNotNil(controller.binding)
            await runtime.stop()
        }
    }

    private let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    private func makeRuntime(_ fake: RecoveryLifecycleFake) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: URL(string: "https://fixture.example")!) { sink in
            fake.installSink(sink)
            return fake
        }
    }

    private func makeController(
        runtime: HermesServerRuntime,
        storedID: String? = nil,
        store: DirectGatewayAttachmentRecoveryMarkerStore,
        promptUncertaintyStore: any DirectPromptDeliveryUncertaintyStoreProtocol = InMemoryDirectPromptDeliveryUncertaintyStore()
    ) -> GatewayConversationController {
        GatewayConversationController(runtime: runtime, storedID: storedID, recoveryMarkerStore: store, promptUncertaintyStore: promptUncertaintyStore) { id, _, _, _ in
            DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
    }

    private func makeStore(_ suffix: String) -> DirectGatewayAttachmentRecoveryMarkerStore {
        DirectGatewayAttachmentRecoveryMarkerStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayAttachmentRecoveryLifecycle-\(suffix)-\(UUID().uuidString)", isDirectory: true))
    }

    private func storeRoot(_ store: DirectGatewayAttachmentRecoveryMarkerStore) -> URL {
        // The test store's markerURL parent is its injected temporary root.
        // Derive it without adding a production path accessor.
        let marker = try! store.markerURL(for: try! DirectGatewayAttachmentRecoveryIdentity(
            origin: URL(string: "https://fixture.example")!, profile: "default", storedID: "durable-1", runtimeID: "runtime-1"))
        return marker.deletingLastPathComponent()
    }

    private func sessionBinding(runtimeID: String, storedID: String) -> JSONValue {
        .object(["session_id": .string(runtimeID), "session_key": .string(storedID)])
    }
}

private final class RecoveryLifecycleFake: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var connected = false
    private var generation = 0
    private var responseValues: [String: JSONValue] = [:]
    private var serverErrors: [String: HermesGatewayError] = [:]
    private var resumeValues: [JSONValue] = []
    private(set) var calls: [String] = []

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        withLock { self.sink = sink }
    }

    func connect() async throws { withLock { connected = true; generation += 1 } }
    func close() async { withLock { connected = false } }
    func connectionIdentifier() async -> Int? { withLock { connected ? generation : nil } }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        let (response, error, resume) = withLock {
            calls.append(method)
            let nextResume = method == "session.resume" && !resumeValues.isEmpty ? resumeValues.removeFirst() : nil
            return (responseValues[method], serverErrors[method], nextResume)
        }
        if let error { throw error }
        if let resume { return resume }
        switch method {
        case "session.create", "session.resume":
            return .object(["session_id": .string("runtime-1"), "session_key": .string("durable-1")])
        case "image.attach_bytes":
            return response ?? .object(["attached": .bool(true), "path": .string("/profile/images/photo.png"), "name": .string("photo.png")])
        case "pdf.attach":
            return response ?? .object(["attached": .bool(true), "filename": .string("report.pdf"), "pages_attached": .number(1), "pages": .array([.object(["path": .string("/profile/images/pdf-p1.png"), "page": .number(1)])])])
        case "session.close":
            return response ?? .object(["closed": .bool(true)])
        case "session.status":
            return response ?? .object(["output": .string("Agent Running: No")])
        default:
            return response ?? .object(["status": .string("streaming")])
        }
    }

    func setResponse(_ method: String, _ response: JSONValue) { withLock { responseValues[method] = response } }
    func setServerError(_ method: String, _ error: HermesGatewayError) { withLock { serverErrors[method] = error } }
    func setResumeResponses(_ responses: [JSONValue]) { withLock { resumeValues = responses } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
}
