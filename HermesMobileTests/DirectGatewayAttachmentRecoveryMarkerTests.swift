import Foundation
import XCTest
@testable import HermesMobile

final class DirectGatewayAttachmentRecoveryMarkerTests: XCTestCase {
    func testMarkerPersistsAcrossStoreRecreationAndNormalizesOrigin() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let identity = try DirectGatewayAttachmentRecoveryIdentity(
            origin: URL(string: "HTTPS://FIXTURE.EXAMPLE:443/")!,
            profile: " default ",
            storedID: " stored-a ",
            runtimeID: " runtime-a "
        )
        XCTAssertEqual(identity.origin, "https://fixture.example")
        XCTAssertEqual(identity.profile, "default")
        XCTAssertEqual(identity.storedID, "stored-a")
        XCTAssertEqual(identity.runtimeID, "runtime-a")

        let marker = DirectGatewayAttachmentRecoveryMarker(identity: identity)
        try DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root).write(marker)

        let recreatedStore = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        XCTAssertEqual(try recreatedStore.load(for: identity), marker)
    }

    func testCustomPortIsRetainedAndOriginInputsAreValidated() throws {
        let identity = try DirectGatewayAttachmentRecoveryIdentity(
            origin: URL(string: "HTTPS://FIXTURE.EXAMPLE:8443/")!,
            profile: "work",
            storedID: "stored-a",
            runtimeID: "runtime-a"
        )
        XCTAssertEqual(identity.origin, "https://fixture.example:8443")

        for invalidOrigin in [
            "https://user:pass@fixture.example",
            "https://fixture.example/path",
            "https://fixture.example?query=1",
            "https://fixture.example#fragment"
        ] {
            XCTAssertThrowsError(
                try DirectGatewayAttachmentRecoveryIdentity(
                    origin: URL(string: invalidOrigin)!,
                    profile: "default",
                    storedID: "stored-a",
                    runtimeID: "runtime-a"
                ),
                "Unexpectedly accepted invalid origin \(invalidOrigin)"
            ) { error in
                XCTAssertEqual(
                    error as? DirectGatewayAttachmentRecoveryMarkerStoreError,
                    .invalidIdentity
                )
            }
        }
    }

    func testOriginProfileAndRuntimeAreIsolationKeys() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let identity = try makeIdentity(
            origin: "https://alpha.example",
            profile: "default",
            storedID: "stored-a",
            runtimeID: "runtime-a"
        )
        try store.write(DirectGatewayAttachmentRecoveryMarker(identity: identity))

        let mismatches = [
            try makeIdentity(origin: "https://beta.example", profile: "default", storedID: "stored-a", runtimeID: "runtime-a"),
            try makeIdentity(origin: "https://alpha.example", profile: "work", storedID: "stored-a", runtimeID: "runtime-a"),
            try makeIdentity(origin: "https://alpha.example", profile: "default", storedID: "stored-a", runtimeID: "runtime-b")
        ]
        for mismatch in mismatches {
            XCTAssertNil(try store.load(for: mismatch))
        }
    }

    func testSameRuntimeStoredIDRotationKeepsMarkerQueueScope() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let original = try makeIdentity(
            origin: "https://alpha.example",
            profile: "default",
            storedID: "stored-ancestor",
            runtimeID: "runtime-a"
        )
        let rotated = try makeIdentity(
            origin: "https://alpha.example",
            profile: "default",
            storedID: "stored-tip",
            runtimeID: "runtime-a"
        )
        let marker = DirectGatewayAttachmentRecoveryMarker(identity: original)
        try store.write(marker)

        let loaded = try store.load(for: rotated)
        XCTAssertEqual(loaded?.token, marker.token)
        XCTAssertEqual(loaded?.identity, original)
    }

    func testCorruptAndUnsupportedSchemaFailClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let identity = try makeIdentity(
            origin: "https://alpha.example",
            profile: "default",
            storedID: "stored-a",
            runtimeID: "runtime-a"
        )
        let url = try store.markerURL(for: identity)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try Data("not-json".utf8).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.load(for: identity)) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentRecoveryMarkerStoreError, .corrupt)
        }

        let unsupported = #"{"schemaVersion":999,"token":"00000000-0000-0000-0000-000000000000","identity":{"origin":"https://alpha.example","profile":"default","storedID":"stored-a","runtimeID":"runtime-a"},"status":"unresolved"}"#
        try Data(unsupported.utf8).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.load(for: identity)) { error in
            XCTAssertEqual(
                error as? DirectGatewayAttachmentRecoveryMarkerStoreError,
                .unsupportedSchema
            )
        }
    }

    func testTokenMismatchCannotRemoveNewerMarker() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let identity = try makeIdentity(
            origin: "https://alpha.example",
            profile: "default",
            storedID: "stored-a",
            runtimeID: "runtime-a"
        )
        let oldMarker = DirectGatewayAttachmentRecoveryMarker(
            token: UUID(),
            identity: identity
        )
        let newerMarker = DirectGatewayAttachmentRecoveryMarker(
            token: UUID(),
            identity: identity
        )
        try store.write(oldMarker)
        try store.write(newerMarker)

        XCTAssertThrowsError(try store.remove(oldMarker)) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentRecoveryMarkerStoreError, .tokenMismatch)
        }
        XCTAssertEqual(try store.load(for: identity), newerMarker)
    }

    func testWriteAndReadFailuresFailClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("blocking")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-a-directory".utf8).write(to: blockingFile, options: [.atomic])

        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: blockingFile)
        let identity = try makeIdentity(
            origin: "https://alpha.example",
            profile: "default",
            storedID: "stored-a",
            runtimeID: "runtime-a"
        )
        let marker = DirectGatewayAttachmentRecoveryMarker(identity: identity)

        XCTAssertThrowsError(try store.write(marker)) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentRecoveryMarkerStoreError, .io)
        }

        let readRoot = root.appendingPathComponent("read-failure", isDirectory: true)
        let readStore = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: readRoot)
        let markerURL = try readStore.markerURL(for: identity)
        try FileManager.default.createDirectory(
            at: markerURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        XCTAssertThrowsError(try readStore.load(for: identity)) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentRecoveryMarkerStoreError, .io)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DirectGatewayAttachmentRecoveryMarkerTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeIdentity(
        origin: String,
        profile: String,
        storedID: String,
        runtimeID: String
    ) throws -> DirectGatewayAttachmentRecoveryIdentity {
        try DirectGatewayAttachmentRecoveryIdentity(
            origin: XCTUnwrap(URL(string: origin)),
            profile: profile,
            storedID: storedID,
            runtimeID: runtimeID
        )
    }
}
