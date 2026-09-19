import XCTest
@testable import HermesMobile

final class DirectHermesMessageAttachmentProjectionTests: XCTestCase {
    func testProjectsStandaloneCanonicalImageAndFileLines() {
        let projection = DirectHermesMessageAttachmentProjection.project(
            userContent: "Inspect these\n@image:/home/images/upload.jpg\n@file:`attachments/notes with space.txt`"
        )

        XCTAssertEqual(projection.cleanedText, "Inspect these")
        XCTAssertEqual(projection.attachments.map(\.name), ["upload.jpg", "notes with space.txt"])
        XCTAssertEqual(projection.attachments.map(\.path), [
            "/home/images/upload.jpg",
            "attachments/notes with space.txt"
        ])
        XCTAssertEqual(projection.attachments.map(\.isImage), [true, false])
    }

    func testLeavesInlineAndMalformedReferencesVisible() {
        let content = "Look at @image:/tmp/photo.png\n@file:bad path\n@image:`unterminated"
        let projection = DirectHermesMessageAttachmentProjection.project(userContent: content)

        XCTAssertTrue(projection.attachments.isEmpty)
        XCTAssertEqual(projection.cleanedText, content)
    }

    func testLeavesReferencesInsideFencedCodeVisible() {
        let content = "```text\n@image:/tmp/photo.png\n@file:notes.txt\n```\nCaption"
        let projection = DirectHermesMessageAttachmentProjection.project(userContent: content)

        XCTAssertTrue(projection.attachments.isEmpty)
        XCTAssertEqual(projection.cleanedText, content)
    }

    func testFenceRequiresMatchingDelimiterLengthAndWhitespaceOnlyClose() {
        let content = "````swift\n@image:/tmp/code.png\n```\n````not-close\n````\n@image:/tmp/real.png"
        let projection = DirectHermesMessageAttachmentProjection.project(userContent: content)

        XCTAssertEqual(projection.attachments.map(\.path), ["/tmp/real.png"])
        XCTAssertEqual(
            projection.cleanedText,
            "````swift\n@image:/tmp/code.png\n```\n````not-close\n````"
        )
    }

    func testImageOnlyMessageLeavesEmptyDisplayText() {
        let projection = DirectHermesMessageAttachmentProjection.project(
            userContent: "@image:/home/images/upload.png"
        )

        XCTAssertEqual(projection.cleanedText, "")
        XCTAssertEqual(projection.attachments.count, 1)
    }

    func testProjectsOnlyTheTextPartOfNativeVisionShape() {
        let parts: [JSONValue] = [
            .object([
                "type": .string("text"),
                "text": .string("Caption\n@image:/home/images/upload.jpg")
            ]),
            .object([
                "type": .string("image_url"),
                "image_url": .object(["url": .string("data:image/png;base64,AAAA")])
            ])
        ]

        let projection = try! XCTUnwrap(
            DirectHermesMessageAttachmentProjection.project(userParts: parts)
        )

        XCTAssertEqual(projection.cleanedText, "Caption")
        XCTAssertEqual(projection.attachments.map(\.path), ["/home/images/upload.jpg"])
    }

    func testMergePreservesExplicitMetadataAndDeduplicatesByIdentity() {
        let explicit = [
            MessageAttachment(
                name: "upload.jpg",
                path: "/server/upload.jpg",
                mime: "image/jpeg",
                size: 12,
                isImage: true
            )
        ]
        let inferred = [
            MessageAttachment(name: "upload.jpg", path: "/home/images/upload.jpg", isImage: true),
            MessageAttachment(name: "notes.txt", path: "attachments/notes.txt", isImage: false)
        ]

        let merged = DirectHermesMessageAttachmentProjection.merge(explicit: explicit, inferred: inferred)

        XCTAssertEqual(merged?.count, 3)
        XCTAssertEqual(merged?.first?.mime, "image/jpeg")
        XCTAssertEqual(merged?.dropFirst().map(\.path), [
            "/home/images/upload.jpg",
            "attachments/notes.txt"
        ])
    }

    func testUnambiguousNameOnlyExplicitAttachmentDeduplicatesInferredPath() {
        let merged = DirectHermesMessageAttachmentProjection.merge(
            explicit: [MessageAttachment(name: "upload.jpg", mime: "image/jpeg")],
            inferred: [MessageAttachment(name: "upload.jpg", path: "/home/images/upload.jpg", isImage: true)]
        )

        XCTAssertEqual(merged?.count, 1)
        XCTAssertEqual(merged?.first?.path, "/home/images/upload.jpg")
        XCTAssertEqual(merged?.first?.mime, "image/jpeg")
    }

    func testAmbiguousNameOnlyExplicitAttachmentRetainsEveryInferredPath() {
        let merged = DirectHermesMessageAttachmentProjection.merge(
            explicit: [MessageAttachment(name: "upload.jpg")],
            inferred: [
                MessageAttachment(name: "upload.jpg", path: "/home/images/a/upload.jpg", isImage: true),
                MessageAttachment(name: "upload.jpg", path: "/home/images/b/upload.jpg", isImage: true)
            ]
        )

        XCTAssertEqual(merged?.count, 3)
        XCTAssertEqual(merged?.compactMap(\.path), [
            "/home/images/a/upload.jpg",
            "/home/images/b/upload.jpg"
        ])
    }
}
