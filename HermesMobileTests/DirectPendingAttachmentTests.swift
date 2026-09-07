import XCTest
@testable import HermesMobile

final class DirectPendingAttachmentTests: XCTestCase {
    func testRetainsStableIdentitySourceBytesAndDisplayMetadata() throws {
        let id = UUID()
        let bytes = Data("source".utf8)
        let source = try DirectGatewayAttachment.file(data: bytes, filename: "notes.txt")
        let thumbnail = Data([0x01, 0x02])
        let pending = DirectPendingAttachment(id: id, source: source, thumbnailData: thumbnail)

        XCTAssertEqual(pending.id, id)
        XCTAssertEqual(pending.originalBytes, bytes)
        XCTAssertEqual(pending.byteCount, bytes.count)
        XCTAssertEqual(pending.displayFilename, "notes.txt")
        XCTAssertEqual(pending.mimeType, "text/plain")
        XCTAssertEqual(pending.thumbnailData, thumbnail)
        XCTAssertEqual(pending.stageState, .pending)
    }

    func testConfirmedStageIsReusableOnlyForExactOriginBindingAndGeneration() throws {
        let source = try DirectGatewayAttachment.image(data: pngData, filename: "photo.png")
        var pending = DirectPendingAttachment(source: source)
        let scope = Self.scope(
            origin: "https://alpha.example",
            storedID: "stored-a",
            runtimeID: "runtime-a",
            profile: "default",
            generation: 4
        )
        XCTAssertTrue(pending.confirm(scope: scope, serverDetachPaths: ["/profile/images/photo.png"]))
        XCTAssertTrue(pending.isConfirmed(for: scope))
        XCTAssertEqual(pending.serverDetachPaths(for: scope), ["/profile/images/photo.png"])

        let mismatchedScopes = [
            Self.scope(origin: "https://beta.example", storedID: "stored-a", runtimeID: "runtime-a", profile: "default", generation: 4),
            Self.scope(origin: "https://alpha.example", storedID: "stored-b", runtimeID: "runtime-a", profile: "default", generation: 4),
            Self.scope(origin: "https://alpha.example", storedID: "stored-a", runtimeID: "runtime-b", profile: "default", generation: 4),
            Self.scope(origin: "https://alpha.example", storedID: "stored-a", runtimeID: "runtime-a", profile: "other", generation: 4),
            Self.scope(origin: "https://alpha.example", storedID: "stored-a", runtimeID: "runtime-a", profile: "default", generation: 5),
            Self.scope(origin: "https://alpha.example", storedID: "stored-a", runtimeID: "runtime-a", profile: "default", generation: 4, turnEpoch: 1)
        ]
        for mismatchedScope in mismatchedScopes {
            XCTAssertFalse(pending.isConfirmed(for: mismatchedScope))
            XCTAssertTrue(pending.serverDetachPaths(for: mismatchedScope).isEmpty)
        }
    }

    func testGenericFileReferenceIsScopedAndHasNoDetachPath() throws {
        let source = try DirectGatewayAttachment.file(data: Data("code".utf8), filename: "main.swift")
        var pending = DirectPendingAttachment(source: source)
        let scope = Self.scope(
            origin: "https://alpha.example",
            storedID: "stored-file",
            runtimeID: "runtime-file",
            profile: "default",
            generation: 2
        )
        XCTAssertTrue(pending.confirm(scope: scope, referenceText: "@file:main.swift"))
        XCTAssertEqual(pending.referenceText(for: scope), "@file:main.swift")
        XCTAssertTrue(pending.serverDetachPaths(for: scope).isEmpty)
    }

    func testUnknownStageCannotBeConfirmedOrRetried() throws {
        let source = try DirectGatewayAttachment.pdf(
            data: Data("%PDF-1.4\n".utf8),
            filename: "report.pdf"
        )
        var pending = DirectPendingAttachment(source: source)
        let scope = Self.scope(
            origin: "https://alpha.example",
            storedID: "stored-pdf",
            runtimeID: "runtime-pdf",
            profile: "default",
            generation: 9
        )
        XCTAssertTrue(pending.markUnknown(scope: scope))
        XCTAssertTrue(pending.stageState.isUnknown)
        XCTAssertFalse(pending.confirm(scope: scope, serverDetachPaths: ["/profile/images/page-1.png"]))
        XCTAssertFalse(pending.isConfirmed(for: scope))
        XCTAssertTrue(pending.referenceText(for: scope) == nil)
    }

    private static func scope(
        origin: String,
        storedID: String,
        runtimeID: String,
        profile: String,
        generation: Int,
        turnEpoch: Int = 0
    ) -> DirectPendingAttachmentStageScope {
        DirectPendingAttachmentStageScope(
            binding: GatewaySessionBinding(storedID: storedID, runtimeID: runtimeID, profile: profile),
            connectionGeneration: generation,
            origin: URL(string: origin)!,
            turnEpoch: turnEpoch
        )
    }

    private var pngData: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}
