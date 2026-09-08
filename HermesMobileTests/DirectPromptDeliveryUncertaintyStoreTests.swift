import Foundation
import XCTest
@testable import HermesMobile

final class InMemoryDirectPromptDeliveryUncertaintyStore: DirectPromptDeliveryUncertaintyStoreProtocol {
    private(set) var markers: [DirectPromptDeliveryUncertaintyMarker] = []
    var failLoad = false
    var failWrite = false
    var failRemove = false

    func candidates(for identity: DirectPromptDeliveryUncertaintyIdentity, limit: Int) throws -> [DirectPromptDeliveryUncertaintyMarker] {
        if failLoad { throw DirectPromptDeliveryUncertaintyStoreError.io }
        let scoped = markers.filter { $0.identity.origin == identity.origin && $0.identity.profile == identity.profile }
        guard scoped.count <= limit else { throw DirectPromptDeliveryUncertaintyStoreError.candidateLimitExceeded }
        return scoped.sorted { $0.identity.storedID < $1.identity.storedID }
    }

    func load(for identity: DirectPromptDeliveryUncertaintyIdentity) throws -> DirectPromptDeliveryUncertaintyMarker? {
        if failLoad { throw DirectPromptDeliveryUncertaintyStoreError.io }
        return markers.first { $0.identity == identity }
    }

    func write(_ marker: DirectPromptDeliveryUncertaintyMarker) throws {
        if failWrite { throw DirectPromptDeliveryUncertaintyStoreError.io }
        markers.removeAll { $0.identity == marker.identity }
        markers.append(marker)
    }

    func remove(_ marker: DirectPromptDeliveryUncertaintyMarker) throws {
        if failRemove { throw DirectPromptDeliveryUncertaintyStoreError.io }
        guard let current = markers.first(where: { $0.identity == marker.identity }) else {
            throw DirectPromptDeliveryUncertaintyStoreError.missing
        }
        guard current.token == marker.token else {
            throw DirectPromptDeliveryUncertaintyStoreError.tokenMismatch
        }
        markers.removeAll { $0.identity == marker.identity }
    }
}

final class DirectPromptDeliveryUncertaintyStoreTests: XCTestCase {
    func testCandidatesAreScopedBoundedAndIgnoreUnattributableLegacyCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptCandidates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectPromptDeliveryUncertaintyStore(rootURL: root)
        let requested = try identity(origin: "https://fixture.example", profile: "work", storedID: "tip")
        let ancestor = try identity(origin: "https://fixture.example", profile: "work", storedID: "ancestor")
        let otherProfile = try identity(origin: "https://fixture.example", profile: "other", storedID: "ancestor")
        let otherOrigin = try identity(origin: "https://other.example", profile: "work", storedID: "ancestor")
        for value in [requested, ancestor, otherProfile, otherOrigin] {
            try store.write(DirectPromptDeliveryUncertaintyMarker(identity: value))
        }
        try Data("invalid legacy record".utf8).write(to: root.appendingPathComponent("marker-unattributable.json"))
        XCTAssertEqual(try store.candidates(for: requested, limit: 2).map(\.identity.storedID), ["ancestor", "tip"])
        XCTAssertThrowsError(try store.candidates(for: requested, limit: 1)) {
            XCTAssertEqual($0 as? DirectPromptDeliveryUncertaintyStoreError, .candidateLimitExceeded)
        }
        try Data("invalid exact record".utf8).write(to: store.markerURL(for: requested))
        XCTAssertThrowsError(try store.load(for: requested)) {
            XCTAssertEqual($0 as? DirectPromptDeliveryUncertaintyStoreError, .corrupt)
        }
        XCTAssertEqual(try store.candidates(for: requested, limit: 2).map(\.identity.storedID), ["ancestor"])
    }

    func testRoundTripAndIdentityIsolation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectPromptDeliveryUncertainty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectPromptDeliveryUncertaintyStore(rootURL: root)
        let first = try identity(origin: "https://alpha.example", profile: "default", storedID: "chat-a")
        let second = try identity(origin: "https://alpha.example", profile: "default", storedID: "chat-b")
        let third = try identity(origin: "https://beta.example", profile: "default", storedID: "chat-a")
        let marker = DirectPromptDeliveryUncertaintyMarker(identity: first)

        try store.write(marker)

        XCTAssertEqual(try store.load(for: first), marker)
        XCTAssertNil(try store.load(for: second))
        XCTAssertNil(try store.load(for: third))
        XCTAssertNotEqual(try store.markerURL(for: first), try store.markerURL(for: second))
        XCTAssertNotEqual(try store.markerURL(for: first), try store.markerURL(for: third))
    }

    func testTokenCheckedRemovalAndCorruptMetadataFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectPromptDeliveryUncertainty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectPromptDeliveryUncertaintyStore(rootURL: root)
        let identity = try self.identity(origin: "https://fixture.example", profile: "default", storedID: "chat-a")
        let marker = DirectPromptDeliveryUncertaintyMarker(identity: identity)
        let newer = DirectPromptDeliveryUncertaintyMarker(identity: identity)
        try store.write(marker)

        XCTAssertThrowsError(try store.remove(newer)) { error in
            XCTAssertEqual(error as? DirectPromptDeliveryUncertaintyStoreError, .tokenMismatch)
        }
        XCTAssertEqual(try store.load(for: identity), marker)

        let url = try store.markerURL(for: identity)
        try Data("not-json".utf8).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.load(for: identity)) { error in
            XCTAssertEqual(error as? DirectPromptDeliveryUncertaintyStoreError, .corrupt)
        }
    }

    func testUnsupportedSchemaAndInvalidDecodedIdentityFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectPromptDeliveryUncertainty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectPromptDeliveryUncertaintyStore(rootURL: root)
        let identity = try self.identity(origin: "https://fixture.example", profile: "default", storedID: "chat-a")
        let url = try store.markerURL(for: identity)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unsupported = #"{"schemaVersion":999,"token":"00000000-0000-0000-0000-000000000000","identity":{"origin":"https://fixture.example","profile":"default","storedID":"chat-a"},"status":"unresolved","createdAt":"2026-01-01T00:00:00Z"}"#
        try Data(unsupported.utf8).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.load(for: identity)) { error in
            XCTAssertEqual(error as? DirectPromptDeliveryUncertaintyStoreError, .unsupportedSchema)
        }

        let invalidIdentity = #"{"schemaVersion":1,"token":"00000000-0000-0000-0000-000000000000","identity":{"origin":"https://fixture.example/not-an-origin","profile":"default","storedID":"chat-a"},"status":"unresolved","createdAt":"2026-01-01T00:00:00Z"}"#
        try Data(invalidIdentity.utf8).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.load(for: identity)) { error in
            XCTAssertEqual(error as? DirectPromptDeliveryUncertaintyStoreError, .invalidIdentity)
        }
    }

    func testIdentityNormalizesOriginAndSeparatesProfiles() throws {
        let normalized = try identity(
            origin: "https://EXAMPLE.test:443",
            profile: " work ",
            storedID: " chat-a "
        )
        let equivalent = try identity(
            origin: "https://example.test",
            profile: "work",
            storedID: "chat-a"
        )
        let otherProfile = try identity(
            origin: "https://example.test",
            profile: "personal",
            storedID: "chat-a"
        )

        XCTAssertEqual(normalized, equivalent)
        XCTAssertEqual(normalized.origin, "https://example.test")
        XCTAssertEqual(normalized.profile, "work")
        XCTAssertEqual(normalized.storedID, "chat-a")
        XCTAssertNotEqual(normalized, otherProfile)
    }

    private func identity(origin: String, profile: String, storedID: String) throws -> DirectPromptDeliveryUncertaintyIdentity {
        let url = try XCTUnwrap(URL(string: origin))
        return try DirectPromptDeliveryUncertaintyIdentity(origin: url, profile: profile, storedID: storedID)
    }
}
