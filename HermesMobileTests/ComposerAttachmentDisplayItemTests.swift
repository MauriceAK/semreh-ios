import XCTest
@testable import HermesMobile

final class ComposerAttachmentDisplayItemTests: XCTestCase {
    func testLegacyProjectionPreservesServerPathAndExistingPreviewMetadata() {
        let pending = PendingAttachment(
            name: "photo.png",
            path: "/server/photo.png",
            mime: "image/png",
            size: 12,
            isImage: true,
            thumbnailData: Data([0x01])
        )
        let item = ComposerAttachmentDisplayItem(pending: pending)

        XCTAssertEqual(item.id, pending.id)
        XCTAssertEqual(item.name, "photo.png")
        XCTAssertEqual(item.serverPath, "/server/photo.png")
        XCTAssertEqual(item.thumbnailData, Data([0x01]))
        XCTAssertNil(item.localPreviewData)
        XCTAssertEqual(item.legacyPendingAttachment(), pending)
    }

    func testDirectProjectionHasNoServerPathAndImageAndPDFGetLocalPreviewBytes() throws {
        let image = try DirectGatewayAttachment.image(data: pngData, filename: "photo.png")
        let imageItem = ComposerAttachmentDisplayItem(
            direct: DirectPendingAttachment(source: image, thumbnailData: Data([0x01]))
        )
        XCTAssertNil(imageItem.serverPath)
        XCTAssertEqual(imageItem.localPreviewData, pngData)
        XCTAssertNil(imageItem.legacyPendingAttachment())

        let pdf = try DirectGatewayAttachment.pdf(data: Data("%PDF-1.4\n".utf8), filename: "report.pdf")
        let pdfItem = ComposerAttachmentDisplayItem(direct: DirectPendingAttachment(source: pdf))
        XCTAssertNil(pdfItem.serverPath)
        XCTAssertEqual(pdfItem.localPreviewData, pdf.originalBytes)
    }

    func testEqualityExcludesPreviewBytesFromMetadataComparison() throws {
        let source = try DirectGatewayAttachment.image(data: pngData, filename: "photo.png")
        let id = UUID()
        let lhs = ComposerAttachmentDisplayItem(
            direct: DirectPendingAttachment(id: id, source: source, thumbnailData: Data([0x01]))
        )
        let rhs = ComposerAttachmentDisplayItem(
            direct: DirectPendingAttachment(id: id, source: source, thumbnailData: Data([0x02]))
        )

        // Equality remains metadata-only so SwiftUI does not compare large
        // preview/source data on every composer update.
        XCTAssertEqual(lhs, rhs)
    }

    private var pngData: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}
