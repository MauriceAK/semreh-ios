import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class GatewayColdMarkerIntegrationTests: XCTestCase {
    func testColdCompressedTipMigratesRealAncestorMarkerAndLeavesOtherScopeUntouched() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ancestor = try identity(profile: "work", storedID: "ancestor")
        let tip = try identity(profile: "work", storedID: "tip")
        let unrelated = try identity(profile: "other", storedID: "ancestor")
        let token = UUID()
        let marker = DirectPromptDeliveryUncertaintyMarker(
            token: token, identity: ancestor, createdAt: Date(timeIntervalSince1970: 1)
        )
        let unrelatedMarker = DirectPromptDeliveryUncertaintyMarker(identity: unrelated)
        try fixture.store.write(marker)
        try fixture.store.write(unrelatedMarker)
        let transport = ColdMarkerTransport()
        let runtime = try makeRuntime(transport)
        let controller = makeController(runtime: runtime, storedID: "tip", profile: "work", fixture: fixture) {
            id, profile, _, _ in
            XCTAssertEqual(profile, "work")
            XCTAssertTrue(id == "ancestor" || id == "tip")
            return DirectHermesTranscriptPage(sessionID: "tip", messages: [], pagination: nil)
        }

        try await controller.open()

        XCTAssertTrue(controller.hasAmbiguousPromptDelivery)
        XCTAssertEqual(controller.promptDeliveryUncertaintyToken, token)
        XCTAssertNil(try fixture.store.load(for: ancestor))
        XCTAssertEqual(try fixture.store.load(for: tip)?.token, token)
        XCTAssertEqual(try fixture.store.load(for: unrelated), unrelatedMarker)
        do { try await controller.submit("must not replay"); XCTFail("Expected delivery barrier") }
        catch DirectSessionError.ambiguousPrompt { }
        XCTAssertFalse(transport.methods().contains("prompt.submit"))
        await runtime.stop()
    }

    func testExactCorruptRealMarkerFailsClosedBeforePromptDispatch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exact = try identity(profile: "work", storedID: "tip")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fixture.store.markerURL(for: exact), options: .atomic)
        let transport = ColdMarkerTransport()
        let runtime = try makeRuntime(transport)
        let controller = makeController(runtime: runtime, storedID: "tip", profile: "work", fixture: fixture)

        XCTAssertTrue(controller.hasAmbiguousPromptDelivery)
        do { try await controller.submit("must not dispatch"); XCTFail("Expected corrupt-marker barrier") }
        catch DirectSessionError.staleOperation { }
        XCTAssertTrue(transport.methods().isEmpty)
        await runtime.stop()
    }

    func testUnattributableLegacyCorruptionDoesNotPoisonCleanScopedController() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let legacyURL = fixture.root.appendingPathComponent("marker-unattributable.json")
        try Data("invalid legacy record".utf8).write(to: legacyURL, options: .atomic)
        let transport = ColdMarkerTransport()
        let runtime = try makeRuntime(transport)
        let controller = makeController(runtime: runtime, storedID: "tip", profile: "work", fixture: fixture)

        try await controller.open()

        XCTAssertFalse(controller.hasAmbiguousPromptDelivery)
        XCTAssertNil(controller.promptDeliveryUncertaintyToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(transport.methods().contains("prompt.submit"))
        await runtime.stop()
    }

    private func makeFixture() throws -> (root: URL, store: DirectPromptDeliveryUncertaintyStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayColdMarkerIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        return (root, DirectPromptDeliveryUncertaintyStore(rootURL: root))
    }

    private func identity(profile: String, storedID: String) throws -> DirectPromptDeliveryUncertaintyIdentity {
        try DirectPromptDeliveryUncertaintyIdentity(
            origin: XCTUnwrap(URL(string: "https://fixture.example")), profile: profile, storedID: storedID
        )
    }

    private func makeRuntime(_ transport: ColdMarkerTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: URL(string: "https://fixture.example")!) { sink in
            transport.installSink(sink)
            return transport
        }
    }

    private func makeController(
        runtime: HermesServerRuntime,
        storedID: String,
        profile: String,
        fixture: (root: URL, store: DirectPromptDeliveryUncertaintyStore),
        loader: @escaping GatewayConversationController.TranscriptLoader = { id, _, _, _ in
            DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
    ) -> GatewayConversationController {
        GatewayConversationController(
            runtime: runtime,
            storedID: storedID,
            profile: profile,
            recoveryMarkerStore: DirectGatewayAttachmentRecoveryMarkerStore(
                rootURL: fixture.root.appendingPathComponent("attachments", isDirectory: true)
            ),
            promptUncertaintyStore: fixture.store,
            loadTranscript: loader
        )
    }
}

private final class ColdMarkerTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMethods: [String] = []
    private var generation = 0

    func installSink(_: @escaping @Sendable (HermesGatewayEvent) -> Void) { }

    func connect() async throws {
        lock.withLock { generation += 1 }
    }

    func close() async { }

    func connectionIdentifier() async -> Int? {
        lock.withLock { generation == 0 ? nil : generation }
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { recordedMethods.append(method) }
        if method == "session.resume" {
            return .object(["session_id": .string("runtime-tip"), "session_key": .string("tip")])
        }
        if method == "session.close" { return .object([:]) }
        return .object(["status": .string("accepted")])
    }

    func methods() -> [String] {
        lock.withLock { recordedMethods }
    }
}
