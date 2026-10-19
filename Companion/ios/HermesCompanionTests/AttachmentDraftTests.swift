import Foundation
import ImageIO
import UIKit
import XCTest
@testable import HermesCompanion

@MainActor
final class AttachmentDraftTests: XCTestCase {
    func testRelocatedContainerRebasesOwnedFilesWithoutReadingOrDeletingOldPaths() throws {
        let hostID = UUID().uuidString
        let drafts = AttachmentDrafts(hostID: hostID)
        let oldDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: drafts.directory)
            try? FileManager.default.removeItem(at: oldDirectory)
        }
        let id = UUID()
        let oldFile = oldDirectory.appendingPathComponent(id.uuidString)
        let oldPreview = oldDirectory.appendingPathComponent(id.uuidString + "-preview.jpg")
        let currentFile = drafts.directory.appendingPathComponent(id.uuidString)
        let currentPreview = drafts.directory.appendingPathComponent(id.uuidString + "-preview.jpg")
        try Data("old sentinel".utf8).write(to: oldFile)
        try Data("old preview sentinel".utf8).write(to: oldPreview)
        let currentBytes = Data("current saved file".utf8)
        try currentBytes.write(to: currentFile)
        try Data("current preview".utf8).write(to: currentPreview)
        let payload = AttachmentPayload(fileURL: oldFile, name: "saved.txt", mediaType: "text/plain", byteCount: currentBytes.count, previewURL: oldPreview)
        drafts.set([.init(id: id, name: "saved.txt", state: .ready(payload))], for: "session")

        let restored = AttachmentDrafts(hostID: hostID)
        let item = try XCTUnwrap(restored.items(for: "session").first)
        let recovered = try XCTUnwrap(item.payload)
        XCTAssertEqual(recovered.fileURL, currentFile)
        XCTAssertEqual(recovered.previewURL, currentPreview)
        XCTAssertEqual(try Data(contentsOf: recovered.fileURL), currentBytes)
        XCTAssertEqual(recovered.name, payload.name)
        XCTAssertEqual(recovered.mediaType, payload.mediaType)
        XCTAssertEqual(recovered.byteCount, payload.byteCount)
        restored.remove([id], sessionID: "session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentPreview.path))
        XCTAssertEqual(try Data(contentsOf: oldFile), Data("old sentinel".utf8))
        XCTAssertEqual(try Data(contentsOf: oldPreview), Data("old preview sentinel".utf8))
    }
    func testManifestCannotRestoreOrDeleteAnArbitraryExternalPath() throws {
        let hostID = UUID().uuidString
        let drafts = AttachmentDrafts(hostID: hostID)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-sentinel-" + UUID().uuidString + ".txt")
        defer {
            try? FileManager.default.removeItem(at: drafts.directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let sentinel = Data("do not read as an attachment or remove".utf8)
        try sentinel.write(to: outside)
        let id = UUID()
        drafts.set([.init(id: id, name: "outside.txt", state: .ready(.init(fileURL: outside, name: "outside.txt", mediaType: "text/plain", byteCount: sentinel.count, previewURL: outside)))], for: "session")
        let restored = AttachmentDrafts(hostID: hostID)
        XCTAssertNil(restored.items(for: "session").first?.payload)
        restored.remove([id], sessionID: "session")
        drafts.remove([id], sessionID: "session")
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }
    func testDraftLimitRejectsNewConversationWithoutEvictingSavedItems() throws {
        let id = UUID().uuidString
        let drafts = AttachmentDrafts(hostID: id)
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        for index in 0..<20 { drafts.set([.init(id: UUID(), name: "Saved", state: .failed("Choose again"))], for: "session-\(index)") }
        XCTAssertNotNil(drafts.importRejection(for: "new-session"))
        XCTAssertNil(drafts.importRejection(for: "session-0"))
        XCTAssertEqual(AttachmentDrafts(hostID: id).items(for: "session-0").count, 1)
        let removed = try XCTUnwrap(drafts.items(for: "session-0").first)
        drafts.remove([removed.id], sessionID: "session-0")
        XCTAssertNil(drafts.importRejection(for: "new-session"))
        XCTAssertTrue(AttachmentDrafts(hostID: id).items(for: "session-0").isEmpty)
    }
    func testImportReservationsPreventConcurrentSelectionsExceedingStorageBound() throws {
        let drafts = AttachmentDrafts(hostID: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        for index in 0..<12 {
            XCTAssertNil(drafts.importRejection(for: "session-\(index)"))
            drafts.set([.init(id: UUID(), name: "Import", state: .importing)], for: "session-\(index)")
        }
        XCTAssertNotNil(drafts.importRejection(for: "overflow"))
        for index in 0..<12 { XCTAssertEqual(drafts.items(for: "session-\(index)").count, 1) }
    }
    func testExpiryRetainsLocalFileAndTicketForExplicitRetry() throws {
        let drafts = AttachmentDrafts(hostID: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let file = drafts.directory.appendingPathComponent(UUID().uuidString)
        try Data("keep this draft".utf8).write(to: file)
        var item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(.init(fileURL: file, name: "note.txt", mediaType: "text/plain", byteCount: 15, previewURL: nil)))
        item.ticket = .init(id: "ready-ticket", name: "note.txt", mediaType: "text/plain", byteCount: 15, status: "ready")
        item.uploadedAt = Date(timeIntervalSince1970: 100)
        drafts.set([item], for: "session")
        drafts.refreshExpiredTickets(now: Date(timeIntervalSince1970: 100 + AttachmentDrafts.ticketLifetime))
        let retained = try XCTUnwrap(drafts.items(for: "session").first)
        XCTAssertNotNil(retained.uploadError)
        XCTAssertEqual(retained.ticket?.id, "ready-ticket")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testInvalidImageIsRejectedBeforePreparedFileIsCreated() async throws {
        let drafts = AttachmentDrafts(hostID: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let source = drafts.directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: source)
        let id = UUID()
        do {
            _ = try await AttachmentImport.file(source, directory: drafts.directory, id: id)
            XCTFail("Invalid image bytes must fail before becoming ready.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.directory.appendingPathComponent(id.uuidString).path))
    }
    func testFileImageGetsSmallPreviewAndPreservesOriginalBytes() async throws {
        let drafts = AttachmentDrafts(hostID: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
        }
        let original = try XCTUnwrap(image.pngData())
        let source = drafts.directory.appendingPathComponent("sample.png")
        try original.write(to: source)
        let payload = try await AttachmentImport.file(source, directory: drafts.directory, id: UUID())
        XCTAssertEqual(try Data(contentsOf: payload.fileURL), original)
        let preview = try XCTUnwrap(payload.previewURL)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(preview as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth] as? Int ?? Int.max, 112)
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight] as? Int ?? Int.max, 112)
    }
    func testQuotaCountsActualPreparedBytesWithoutDeletingThem() throws {
        let drafts = AttachmentDrafts(hostID: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let file = drafts.directory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AttachmentDrafts.maxLocalBytes))
        try handle.close()
        XCTAssertNotNil(drafts.importRejection(for: "session"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(drafts.localByteCount, AttachmentDrafts.maxLocalBytes)
    }
}
