import XCTest
@testable import HermesMobile

final class DirectGatewayAttachmentReceiptTests: XCTestCase {
    func testImageReceiptRequiresAttachedAndPreservesGatewayPath() throws {
        let receipt = try DirectGatewayAttachmentReceipt.image(from: .object([
            "attached": .bool(true),
            "name": .string("camera-shot.png"),
            "path": .string("/gateway/generated/camera-shot.png"),
            "count": .number(1),
            "width": .number(1),
            "height": .number(1)
        ]))

        XCTAssertEqual(receipt.kind, .image)
        XCTAssertEqual(receipt.detachPaths, ["/gateway/generated/camera-shot.png"])
        XCTAssertEqual(receipt.filename, "camera-shot.png")
        XCTAssertNil(receipt.referenceText)
        XCTAssertNil(receipt.pdfPageCount)
    }

    func testImageReceiptRejectsMissingOrFalseAttachmentReference() {
        XCTAssertThrowsError(try DirectGatewayAttachmentReceipt.image(from: .object([
            "attached": .bool(false),
            "path": .string("/gateway/generated/image.png")
        ]))) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentReceiptError, .notAttached)
        }

        XCTAssertThrowsError(try DirectGatewayAttachmentReceipt.image(from: .object([
            "attached": .bool(true),
            "path": .string(" ")
        ]))) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentReceiptError, .missingReference)
        }
    }

    func testFileReceiptPreservesRefTextAndDoesNotExposeHostPath() throws {
        let receipt = try DirectGatewayAttachmentReceipt.file(from: .object([
            "attached": .bool(true),
            "name": .string("notes.txt"),
            "path": .string("/gateway/internal/notes.txt"),
            "ref_path": .string("/disposable/profile/attachments/notes.txt"),
            "ref_text": .string("@file:/disposable/profile/attachments/notes.txt"),
            "uploaded": .bool(true)
        ]))

        XCTAssertEqual(receipt.kind, .file)
        XCTAssertEqual(receipt.referenceText, "@file:/disposable/profile/attachments/notes.txt")
        XCTAssertTrue(receipt.detachPaths.isEmpty)
        XCTAssertEqual(receipt.filename, "notes.txt")
        XCTAssertNil(receipt.pdfPageCount)
    }

    func testFileReceiptRejectsEmptyOrWrongRefText() {
        for refText in ["@file:", "file:/missing-prefix", "@file:   "] {
            XCTAssertThrowsError(try DirectGatewayAttachmentReceipt.file(from: .object([
                "attached": .bool(true),
                "ref_text": .string(refText)
            ]))) { error in
                XCTAssertEqual(error as? DirectGatewayAttachmentReceiptError, .missingReference)
            }
        }
    }

    func testOptionalDisplayMetadataToleratesNullOrUnknownTypes() throws {
        let image = try DirectGatewayAttachmentReceipt.image(from: .object([
            "attached": .bool(true),
            "path": .string("/gateway/generated/image.png"),
            "name": .number(7)
        ]))
        XCTAssertNil(image.filename)

        let pdf = try DirectGatewayAttachmentReceipt.pdf(from: .object([
            "attached": .bool(true),
            "filename": .null,
            "pages_attached": .number(1),
            "pages": .array([
                .object([
                    "page": .number(1),
                    "path": .string("/gateway/generated/page.png")
                ])
            ])
        ]))
        XCTAssertNil(pdf.filename)
    }

    func testPDFReceiptRequiresMatchingNonemptyPageReferences() throws {
        let receipt = try DirectGatewayAttachmentReceipt.pdf(from: .object([
            "attached": .bool(true),
            "filename": .string("one-page.pdf"),
            "pages_attached": .number(2),
            "pages": .array([
                .object([
                    "page": .number(1),
                    "path": .string("/gateway/generated/one-page-1.png")
                ]),
                .object([
                    "page": .number(2),
                    "path": .string("/gateway/generated/one-page-2.png")
                ])
            ]),
            // `count` is the gateway's session attachment count, not the PDF
            // page count, so it is intentionally not used for consistency.
            "count": .number(3)
        ]))

        XCTAssertEqual(receipt.kind, .pdf)
        XCTAssertEqual(receipt.pdfPageCount, 2)
        XCTAssertEqual(receipt.detachPaths, [
            "/gateway/generated/one-page-1.png",
            "/gateway/generated/one-page-2.png"
        ])
        XCTAssertEqual(receipt.filename, "one-page.pdf")
    }

    func testPDFReceiptRejectsCountMismatchDuplicateOrEmptyPagePath() {
        let mismatch: JSONValue = .object([
            "attached": .bool(true),
            "pages_attached": .number(2),
            "pages": .array([
                .object(["page": .number(1), "path": .string("/gateway/one.png")])
            ])
        ])
        XCTAssertThrowsError(try DirectGatewayAttachmentReceipt.pdf(from: mismatch)) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentReceiptError, .inconsistentPDFPages)
        }

        let duplicate: JSONValue = .object([
            "attached": .bool(true),
            "pages_attached": .number(2),
            "pages": .array([
                .object(["page": .number(1), "path": .string("/gateway/one.png")]),
                .object(["page": .number(1), "path": .string("/gateway/two.png")])
            ])
        ])
        XCTAssertThrowsError(try DirectGatewayAttachmentReceipt.pdf(from: duplicate)) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentReceiptError, .inconsistentPDFPages)
        }

        let emptyPath: JSONValue = .object([
            "attached": .bool(true),
            "pages_attached": .number(1),
            "pages": .array([
                .object(["page": .number(1), "path": .string(" ")])
            ])
        ])
        XCTAssertThrowsError(try DirectGatewayAttachmentReceipt.pdf(from: emptyPath)) { error in
            XCTAssertEqual(error as? DirectGatewayAttachmentReceiptError, .missingReference)
        }
    }
}
