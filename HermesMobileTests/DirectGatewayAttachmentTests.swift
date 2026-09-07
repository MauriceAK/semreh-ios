import XCTest
import UniformTypeIdentifiers
@testable import HermesMobile

final class DirectGatewayAttachmentTests: XCTestCase {
    func testImageRetainsBytesDerivesMIMEAndBuildsExactParameters() async throws {
        let attachment = try DirectGatewayAttachment.image(
            data: pngData,
            filename: "../photo",
            typeIdentifier: UTType.png.identifier
        )

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.originalBytes, pngData)
        XCTAssertEqual(attachment.displayFilename, "photo.png")
        XCTAssertEqual(attachment.mimeType, "image/png")
        let parameters = try await attachment.rpcParameters()
        XCTAssertEqual(parameters, [
            "content_base64": .string(pngData.base64EncodedString()),
            "filename": .string("photo.png")
        ])
    }

    func testFileUsesDataURLAndNeverEmitsPath() async throws {
        let bytes = Data("print('hello')".utf8)
        let attachment = try DirectGatewayAttachment.file(
            data: bytes,
            filename: " /tmp/example.txt\n",
            typeIdentifier: UTType.plainText.identifier
        )

        XCTAssertEqual(attachment.displayFilename, "example.txt")
        XCTAssertEqual(attachment.mimeType, "text/plain")
        let parameters = try await attachment.rpcParameters()
        XCTAssertEqual(parameters, [
            "data_url": .string("data:text/plain;base64,\(bytes.base64EncodedString())"),
            "name": .string("example.txt")
        ])
        XCTAssertNil(parameters["path"])
    }

    func testPDFRetainsOriginalBytesAndBuildsContentBase64Shape() async throws {
        let bytes = Data("%PDF-1.4\n% synthetic\n".utf8)
        let attachment = try DirectGatewayAttachment.pdf(data: bytes, filename: "report")

        XCTAssertEqual(attachment.displayFilename, "report.pdf")
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.originalBytes, bytes)
        let parameters = try await attachment.rpcParameters()
        XCTAssertEqual(parameters, [
            "content_base64": .string(bytes.base64EncodedString()),
            "filename": .string("report.pdf")
        ])
    }

    func testMalformedEmptyAndUnsupportedSourcesAreRejected() {
        XCTAssertThrowsError(try DirectGatewayAttachment.image(data: Data(), filename: "empty.png")) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentError, .empty)
        }
        XCTAssertThrowsError(try DirectGatewayAttachment.image(data: Data([0x00, 0x01]), filename: "bad.png")) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentError, .malformed)
        }
        XCTAssertThrowsError(try DirectGatewayAttachment.image(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            filename: "truncated.png"
        )) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentError, .malformed)
        }
        XCTAssertThrowsError(try DirectGatewayAttachment(
            data: pngData,
            filename: "photo.txt",
            kind: .image,
            typeIdentifier: UTType.plainText.identifier
        )) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentError, .unsupportedImageExtension)
        }
    }

    func testCapsCanBeValidatedWithoutAllocatingCapSizedData() {
        XCTAssertNoThrow(try DirectGatewayAttachment.validate(
            byteCount: DirectGatewayAttachmentLimits.imageMaximumBytes,
            kind: .image
        ))
        XCTAssertThrowsError(try DirectGatewayAttachment.validate(
            byteCount: DirectGatewayAttachmentLimits.imageMaximumBytes + 1,
            kind: .image
        )) { error in
            XCTAssertEqual(
                error as? DirectGatewayAttachmentError,
                .tooLarge(kind: .image, maximumBytes: DirectGatewayAttachmentLimits.imageMaximumBytes)
            )
        }
        XCTAssertThrowsError(try DirectGatewayAttachment.validate(
            byteCount: DirectGatewayAttachmentLimits.pdfMaximumBytes + 1,
            kind: .pdf
        )) { error in
            XCTAssertEqual(
                error as? DirectGatewayAttachmentError,
                .tooLarge(kind: .pdf, maximumBytes: DirectGatewayAttachmentLimits.pdfMaximumBytes)
            )
        }
        XCTAssertEqual(DirectGatewayAttachmentLimits.fileMaximumBytes, DirectGatewayAttachmentLimits.pdfMaximumBytes)
        XCTAssertThrowsError(try DirectGatewayAttachment.validate(
            byteCount: DirectGatewayAttachmentLimits.fileMaximumBytes! + 1,
            kind: .file
        )) { error in
            XCTAssertEqual(
                error as? DirectGatewayAttachmentError,
                .tooLarge(kind: .file, maximumBytes: DirectGatewayAttachmentLimits.fileMaximumBytes!)
            )
        }
    }

    @MainActor
    func testCancelledPreparationDoesNotChangeRetainedSource() async throws {
        let attachment = try DirectGatewayAttachment.file(data: Data("source".utf8), filename: "source.txt")
        let task = Task { try await attachment.rpcParameters() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled preparation should throw CancellationError")
        } catch is CancellationError {
            // Expected: rpcParameters checks cancellation before starting work.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(attachment.originalBytes, Data("source".utf8))
    }

    private var pngData: Data {
        // Valid 1x1 RGBA PNG, kept tiny so tests never allocate near a source cap.
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}
