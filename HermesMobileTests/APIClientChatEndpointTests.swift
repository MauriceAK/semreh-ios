import XCTest
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientChatEndpointTests: APIClientTestCase {
    func testPendingAttachmentBuildsBrowserCompatibleChatMessageText() {
        let html = PendingAttachment(
            name: "sample.html",
            path: "/tmp/workspace/sample.html",
            mime: "text/html",
            size: 42,
            isImage: false,
            thumbnailData: nil
        )
        let image = PendingAttachment(
            name: "image.jpg",
            path: "/tmp/workspace/image.jpg",
            mime: "image/jpeg",
            size: 100,
            isImage: true,
            thumbnailData: Data()
        )

        let message = PendingAttachment.chatMessageText(
            draft: "Analyze these files",
            attachments: [html, image]
        )

        XCTAssertEqual(
            message,
            "Analyze these files\n\n[Attached files: /tmp/workspace/sample.html, /tmp/workspace/image.jpg]"
        )
    }

    func testChatAttachmentPreviewItemInfersImageMessageAttachment() {
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: nil,
                path: "/tmp/workspace/photo.PNG",
                mime: nil,
                size: 128,
                isImage: nil
            ),
            localData: Data([0x01])
        )

        XCTAssertEqual(item.displayName, "photo.PNG")
        XCTAssertEqual(item.displayPath, "/tmp/workspace/photo.PNG")
        XCTAssertTrue(item.inferredIsImage)
        XCTAssertFalse(item.isKnownUnsupportedBinary)
    }

    func testChatAttachmentPreviewItemUsesPendingFileMetadata() {
        let item = ChatAttachmentPreviewItem(
            pending: PendingAttachment(
                name: "report.pdf",
                path: "/tmp/workspace/report.pdf",
                mime: "application/pdf",
                size: 2_048,
                isImage: false,
                thumbnailData: nil
            )
        )

        XCTAssertEqual(item.displayName, "report.pdf")
        XCTAssertEqual(item.displayPath, "/tmp/workspace/report.pdf")
        XCTAssertFalse(item.inferredIsImage)
        XCTAssertEqual(item.documentKind, .pdf)
        XCTAssertFalse(item.isKnownUnsupportedBinary)
    }

    func testChatAttachmentPreviewItemUsesDirectMemoryProjectionWithoutHostPath() throws {
        let source = try DirectGatewayAttachment.image(
            data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!,
            filename: "photo.png"
        )
        let display = ComposerAttachmentDisplayItem(
            direct: DirectPendingAttachment(source: source, thumbnailData: Data([0x01]))
        )
        let item = ChatAttachmentPreviewItem(display: display)

        XCTAssertEqual(item.displayName, "photo.png")
        XCTAssertNil(item.path)
        XCTAssertEqual(item.mime, source.mimeType)
        XCTAssertEqual(item.size, source.originalBytes.count)
        XCTAssertEqual(item.localPreviewData, source.originalBytes)
    }

    @MainActor
    func testChatAttachmentPreviewLoadsDirectImageFromMemoryWithoutSessionOrAPI() async throws {
        let source = try DirectGatewayAttachment.image(
            data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!,
            filename: "photo.png"
        )
        let item = ChatAttachmentPreviewItem(
            display: ComposerAttachmentDisplayItem(
                direct: DirectPendingAttachment(source: source)
            )
        )
        let client = makeClient { request in
            XCTFail("Direct memory preview must not request a host/server path: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .image(preview) = viewModel.preview else {
            return XCTFail("Direct image attachments should load from retained memory bytes.")
        }
        XCTAssertEqual(preview.data, source.originalBytes)
        XCTAssertEqual(preview.originalByteCount, source.originalBytes.count)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewDownsamplesDirectLocalImageAndPreservesOriginalBytes() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let originalImageData = UIGraphicsImageRenderer(
            size: CGSize(width: 3_000, height: 2_000),
            format: format
        ).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 2_000))
        }
        let source = try DirectGatewayAttachment.image(data: originalImageData, filename: "large.png")
        let pending = DirectPendingAttachment(source: source)
        let item = ChatAttachmentPreviewItem(
            display: ComposerAttachmentDisplayItem(direct: pending)
        )
        let client = makeClient { request in
            XCTFail("Direct local preview must not request a session or server path: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .image(preview) = viewModel.preview else {
            return XCTFail("Direct local image should produce a preview")
        }
        let previewImage = try XCTUnwrap(UIImage(data: preview.data)?.cgImage)
        XCTAssertLessThanOrEqual(max(previewImage.width, previewImage.height), ImagePreviewDownsampler.filePreviewMaxPixelSize)
        XCTAssertNotEqual(preview.data, originalImageData)
        XCTAssertEqual(preview.originalByteCount, originalImageData.count)
        XCTAssertEqual(pending.originalBytes, originalImageData)
    }

    @MainActor
    func testChatAttachmentPreviewLoadsDirectPDFFromMemoryWithoutSessionOrAPI() async throws {
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage()
            "Local PDF".draw(at: CGPoint(x: 24, y: 24), withAttributes: nil)
        }
        let source = try DirectGatewayAttachment.pdf(data: pdfData, filename: "local.pdf")
        let item = ChatAttachmentPreviewItem(
            display: ComposerAttachmentDisplayItem(direct: DirectPendingAttachment(source: source))
        )
        let client = makeClient { request in
            XCTFail("Direct local PDF preview must not request a host/server path: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .pdf(document) = viewModel.preview else {
            return XCTFail("Direct local PDF should produce a native PDF preview.")
        }
        XCTAssertEqual(document.document.pageCount, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewRejectsMalformedDirectLocalPDFWithoutNetwork() async throws {
        let source = try DirectGatewayAttachment.pdf(
            data: Data("%PDF-1.4\nnot-a-real-document".utf8),
            filename: "broken.pdf"
        )
        let item = ChatAttachmentPreviewItem(
            display: ComposerAttachmentDisplayItem(direct: DirectPendingAttachment(source: source))
        )
        let client = makeClient { request in
            XCTFail("Malformed direct local PDF must not request a host/server path: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .unavailable(message) = viewModel.preview else {
            return XCTFail("Malformed direct local PDF should remain unavailable.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("decode"))
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewRejectsDeclaredOversizeDirectLocalPDFWithoutAllocatingCapSizedData() async throws {
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage()
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "oversize.pdf",
                path: nil,
                mime: "application/pdf",
                size: DocumentPreviewLimits.maximumBytes + 1,
                isImage: false
            ),
            localData: pdfData
        )
        let client = makeClient { request in
            XCTFail("Oversized direct local PDF must not request a host/server path: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .unavailable(message) = viewModel.preview else {
            return XCTFail("Oversized direct local PDF should remain unavailable.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("too large"))
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testCancelledDirectLocalPDFPreviewDoesNotRequestNetworkOrPublishPreview() async throws {
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage()
        }
        let source = try DirectGatewayAttachment.pdf(data: pdfData, filename: "cancelled.pdf")
        let item = ChatAttachmentPreviewItem(
            display: ComposerAttachmentDisplayItem(direct: DirectPendingAttachment(source: source))
        )
        let client = makeClient { request in
            XCTFail("Cancelled direct local PDF preview must not request a host/server path: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        let task = Task { @MainActor in
            await viewModel.load()
        }
        task.cancel()
        await task.value

        XCTAssertNil(viewModel.preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewLoadsDirectImageFromAuthenticatedManagedFileEnvelope() async throws {
        let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let dataURL = "data:image/png;base64,\(imageData.base64EncodedString())"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/files/read")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "path" })?.value, "/home/fixture/images/result.png")
            XCTAssertNil(query.first(where: { $0.name == "session_id" }))
            return apiTestJSONResponse(
                #"{"data_url":"\#(dataURL)","mime_type":"image/png","name":"result.png","path":"/home/fixture/images/result.png","size":\#(imageData.count)}"#,
                for: request
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            session: URLSession(configuration: configuration),
            customHeaderProvider: { [CustomHeader(name: "Authorization", value: "Bearer fixture")] }
        )
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "result.png",
                path: "/home/fixture/images/result.png",
                mime: "image/png",
                size: imageData.count,
                isImage: true
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .image(preview) = viewModel.preview else {
            return XCTFail("Direct image preview should decode the authenticated managed-file envelope.")
        }
        XCTAssertEqual(preview.data, imageData)
        XCTAssertEqual(preview.originalByteCount, imageData.count)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewLoadsDirectTextFromManagedFileWithoutLegacyHTTP() async throws {
        let text = "plain text from the managed file"
        let dataURL = "data:text/plain;base64,\(Data(text.utf8).base64EncodedString())"
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/files/read")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], "/home/fixture/attachments/notes.txt")
            return apiTestJSONResponse(
                #"{"data_url":"\#(dataURL)","mime_type":"text/plain","name":"notes.txt","path":"/home/fixture/attachments/notes.txt","size":\#(text.utf8.count)}"#,
                for: request
            )
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "notes.txt",
                path: "/home/fixture/attachments/notes.txt",
                mime: "text/plain",
                size: text.utf8.count,
                isImage: false
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .text(file) = viewModel.preview else {
            return XCTFail("Direct text attachments should use the managed-file response bytes.")
        }
        XCTAssertEqual(file.content, text)
        XCTAssertEqual(file.path, "/home/fixture/attachments/notes.txt")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewLoadsDirectMarkdownFromManagedFile() async throws {
        let markdown = "# Notes\n\nRendered markdown."
        let dataURL = "data:text/markdown;base64,\(Data(markdown.utf8).base64EncodedString())"
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/files/read")
            return apiTestJSONResponse(
                #"{"data_url":"\#(dataURL)","mime_type":"text/markdown","name":"notes.md","path":"/home/fixture/attachments/notes.md","size":\#(markdown.utf8.count)}"#,
                for: request
            )
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "notes.md",
                path: "/home/fixture/attachments/notes.md",
                mime: "text/markdown",
                size: markdown.utf8.count,
                isImage: false
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .markdown(file) = viewModel.preview else {
            return XCTFail("Direct Markdown attachments should use the managed-file response bytes.")
        }
        XCTAssertEqual(file.content, markdown)
        XCTAssertEqual(file.path, "/home/fixture/attachments/notes.md")
    }

    @MainActor
    func testChatAttachmentPreviewRejectsDirectTextAboveDisplayLimitWithoutDecoding() async throws {
        let oversizedText = Data(repeating: 0x78, count: 256 * 1_024 + 1)
        let dataURL = "data:text/plain;base64,\(oversizedText.base64EncodedString())"
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/files/read")
            return apiTestJSONResponse(
                #"{"data_url":"\#(dataURL)","mime_type":"text/plain","name":"large.txt","path":"/home/fixture/attachments/large.txt","size":\#(oversizedText.count)}"#,
                for: request
            )
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "large.txt",
                path: "/home/fixture/attachments/large.txt",
                mime: "text/plain",
                size: oversizedText.count,
                isImage: false
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .unavailable(message) = viewModel.preview else {
            return XCTFail("Oversized direct text should be rejected before preview rendering.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("too large"))
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewRejectsRelativeDirectPathWithoutRequest() async throws {
        let client = makeClient { request in
            XCTFail("Relative direct references must not request a guessed host path: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "notes.txt",
                path: "attachments/notes.txt",
                mime: "text/plain",
                size: 12,
                isImage: false
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .unavailable(message) = viewModel.preview else {
            return XCTFail("Relative direct references should remain unavailable without a request.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("not available"))
    }

    @MainActor
    func testChatAttachmentPreviewDoesNotFetchKnownUnsupportedDirectBinary() async throws {
        let client = makeClient { request in
            XCTFail("Known unsupported direct binaries must not be fetched: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "archive.zip",
                path: "/home/fixture/attachments/archive.zip",
                mime: "application/zip",
                size: 12,
                isImage: false
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .unavailable(message) = viewModel.preview else {
            return XCTFail("Known unsupported direct binaries should remain unavailable.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("file type"))
    }

    @MainActor
    func testChatAttachmentPreviewLoadsDirectAudioFromManagedFile() async throws {
        let audio = Data([0x00, 0x01, 0x02, 0x03])
        let dataURL = "data:audio/mp4;base64,\(audio.base64EncodedString())"
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/files/read")
            return apiTestJSONResponse(
                #"{"data_url":"\#(dataURL)","mime_type":"audio/mp4","name":"note.m4a","path":"/home/fixture/attachments/note.m4a","size":\#(audio.count)}"#,
                for: request
            )
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "note.m4a",
                path: "/home/fixture/attachments/note.m4a",
                mime: "audio/mp4",
                size: audio.count,
                isImage: false
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .audio(previewData) = viewModel.preview else {
            return XCTFail("Direct audio attachments should retain the managed-file bytes.")
        }
        XCTAssertEqual(previewData, audio)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewMapsManagedFileUnauthorizedWithoutLegacyFallback() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/files/read")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"detail":"unauthorized"}"#.utf8))
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "notes.txt",
                path: "/home/fixture/attachments/notes.txt",
                mime: "text/plain",
                size: 12,
                isImage: false
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        XCTAssertNil(viewModel.preview)
        XCTAssertEqual(viewModel.errorMessage, DirectHermesRequestError.http(statusCode: 401, reason: .unauthorized).localizedDescription)
        guard let error = viewModel.lastError as? DirectHermesRequestError,
              case .http(statusCode: 401, reason: .unauthorized) = error else {
            return XCTFail("Managed-file 401 should remain an authentication error.")
        }
    }

    @MainActor
    func testChatAttachmentPreviewLoadsDirectPDFFromManagedFileWithPreviewLimit() async throws {
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage()
            "Attachment PDF".draw(at: CGPoint(x: 24, y: 24), withAttributes: nil)
        }
        let dataURL = "data:application/pdf;base64,\(pdfData.base64EncodedString())"
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/files/read")
            return apiTestJSONResponse(
                #"{"data_url":"\#(dataURL)","mime_type":"application/pdf","name":"report.pdf","path":"/home/fixture/attachments/report.pdf","size":\#(pdfData.count)}"#,
                for: request
            )
        }
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: "report.pdf",
                path: "/home/fixture/attachments/report.pdf",
                mime: "application/pdf",
                size: pdfData.count,
                isImage: false
            ),
            localData: nil
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .pdf(document) = viewModel.preview else {
            return XCTFail("Direct PDF attachments should use the managed-file bytes.")
        }
        XCTAssertEqual(document.document.pageCount, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testDocumentPreviewKindRejectsStrongMIMEConflict() {
        XCTAssertNil(DocumentPreviewKind.infer(nameOrPath: "report.pdf", mimeType: "text/html"))
        XCTAssertEqual(
            DocumentPreviewKind.infer(nameOrPath: "notes.md", mimeType: "application/octet-stream"),
            .markdown
        )
    }

    func testChatAttachmentPreviewItemRecognizesMarkdownFromMIMEWithoutExtension() {
        let item = ChatAttachmentPreviewItem(
            pending: PendingAttachment(
                name: "release-notes",
                path: "/tmp/workspace/release-notes",
                mime: "text/markdown; charset=utf-8",
                size: 512,
                isImage: false,
                thumbnailData: nil
            )
        )

        XCTAssertEqual(item.documentKind, .markdown)
        XCTAssertFalse(item.isKnownUnsupportedBinary)
    }

}
