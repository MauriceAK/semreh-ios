import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientChatEndpointTests: APIClientTestCase {
    func testNativeAuthSubmitSendsOnlyEncryptedEnvelope() async throws {
        let envelope = NativeAuthWireEnvelope(
            type: "semreh.native-secret-envelope.v1",
            issuedBy: "semreh-native",
            immutable: true,
            contextID: "ctx_1234567890",
            browserSessionID: "bs_1234567890",
            envelopeID: "env_1234567890",
            providerOrigin: "https://example.com",
            path: "/login",
            cipherSuite: "AES-256-GCM",
            keyID: "rt_1234567890",
            clientPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            nonce: "AAAAAAAAAAAAAAAA",
            ciphertext: "enc_v1.synthetic_placeholder.AAAAAAAAAAAAAAAAAAAAAAAA",
            tag: "AAAAAAAAAAAAAAAAAAAAAA",
            journalPolicy: "never",
            expiresAt: "2099-01-01T00:00:00Z"
        )
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/native-auth/submit")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Semreh-Client"), "native-auth-v1")
            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["session_id"] as? String, "session-abc")
            XCTAssertEqual(body["stream_id"] as? String, "stream-abc")
            let nested = try XCTUnwrap(body["envelope"] as? [String: Any])
            XCTAssertEqual(nested["type"] as? String, "semreh.native-secret-envelope.v1")
            XCTAssertEqual(nested["journal_policy"] as? String, "never")
            for key in ["password", "username", "credential", "value", "field_ids"] {
                XCTAssertNil(nested[key], "Plaintext credential key crossed the transport: \(key)")
            }
            return apiTestJSONResponse(
                #"{"ok":true,"state":"submitted","code":"submitted","stage":"complete","retryable":false,"requires_remint":false}"#,
                for: request
            )
        }

        let response = try await client.submitNativeAuth(
            sessionID: "session-abc",
            streamID: "stream-abc",
            envelope: envelope
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.state, "submitted")
    }

    func testNativeAuthCancelUsesOpaqueContextAndStreamOnly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/native-auth/cancel")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Semreh-Client"), "native-auth-v1")
            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(Set(body.keys), Set(["session_id", "stream_id", "component_id"]))
            XCTAssertEqual(body["component_id"] as? String, "ctx_1234567890")
            return apiTestJSONResponse(
                #"{"ok":true,"state":"cancelled","code":"cancelled","stage":"cancel","retryable":false,"requires_remint":false}"#,
                for: request
            )
        }

        let response = try await client.cancelNativeAuth(
            sessionID: "session-abc",
            streamID: "stream-abc",
            contextID: "ctx_1234567890"
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.state, "cancelled")
    }

    func testNativeAuthSubmitRejectsPartialSuccessContract() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"ok":true,"state":"submitted"}"#, for: request)
        }

        do {
            _ = try await client.submitNativeAuth(
                sessionID: "session-abc",
                streamID: "stream-abc",
                envelope: nativeAuthTestEnvelope()
            )
            XCTFail("Partial 2xx native-auth outcomes must remain ambiguous")
        } catch {
            guard case APIError.decoding = error else {
                return XCTFail("Expected strict response decoding, got \(error)")
            }
        }
    }

    func testNativeAuthSubmitMapsTypedRetryableOutcome() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"ok":false,"state":"busy","code":"busy","stage":"runtime","retryable":true,"requires_remint":false}"#.utf8)
            )
        }

        do {
            _ = try await client.submitNativeAuth(
                sessionID: "session-abc",
                streamID: "stream-abc",
                envelope: nativeAuthTestEnvelope()
            )
            XCTFail("Expected typed native-auth outcome")
        } catch let error as NativeAuthControlError {
            XCTAssertEqual(error.outcome.code, "busy")
            XCTAssertTrue(error.outcome.retryable)
            XCTAssertFalse(error.outcome.requiresRemint)
            XCTAssertEqual(error.statusCode, 409)
        }
    }

    private func nativeAuthTestEnvelope() -> NativeAuthWireEnvelope {
        NativeAuthWireEnvelope(
            type: "semreh.native-secret-envelope.v1",
            issuedBy: "semreh-native",
            immutable: true,
            contextID: "ctx_1234567890",
            browserSessionID: "bs_1234567890",
            envelopeID: "env_1234567890",
            providerOrigin: "https://example.com",
            path: "/login",
            cipherSuite: "AES-256-GCM",
            keyID: "rt_1234567890",
            clientPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            nonce: "AAAAAAAAAAAAAAAA",
            ciphertext: "AAAAAAAAAAAAAAAAAAAAAA",
            tag: "AAAAAAAAAAAAAAAAAAAAAA",
            journalPolicy: "never",
            expiresAt: "2099-01-01T00:00:00Z"
        )
    }

    func testStartChatBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["message"] as? String, "Please try again")
            XCTAssertEqual(body?["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body?["model"] as? String, "gpt-5.4")

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-123",
              "session_id": "session-abc"
            }
            """, for: request)
        }

        let response = try await client.startChat(
            sessionID: "session-abc",
            message: "Please try again",
            workspace: "/tmp/workspace",
            model: "gpt-5.4"
        )

        XCTAssertEqual(response.streamId, "stream-123")
        XCTAssertEqual(response.sessionId, "session-abc")
    }

    func testStartChatIncludesAttachmentPayloads() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["message"] as? String, "Summarize this CSV\n\n[Attached files: /tmp/workspace/data.csv]")
            let attachments = try XCTUnwrap(body["attachments"] as? [[String: Any]])
            XCTAssertEqual(attachments.count, 1)
            XCTAssertEqual(attachments.first?["name"] as? String, "data.csv")
            XCTAssertEqual(attachments.first?["path"] as? String, "/tmp/workspace/data.csv")
            XCTAssertEqual(attachments.first?["mime"] as? String, "text/csv")
            XCTAssertEqual(attachments.first?["size"] as? Double, 42)
            XCTAssertEqual(attachments.first?["is_image"] as? Bool, false)

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-123",
              "session_id": "session-abc"
            }
            """, for: request)
        }

        let response = try await client.startChat(
            sessionID: "session-abc",
            message: "Summarize this CSV\n\n[Attached files: /tmp/workspace/data.csv]",
            workspace: "/tmp/workspace",
            model: "gpt-5.4",
            attachments: [
                .object([
                    "name": .string("data.csv"),
                    "path": .string("/tmp/workspace/data.csv"),
                    "mime": .string("text/csv"),
                    "size": .number(42),
                    "is_image": .bool(false)
                ])
            ]
        )

        XCTAssertEqual(response.streamId, "stream-123")
        XCTAssertEqual(response.sessionId, "session-abc")
    }

    func testStartChatIncludesProviderAndProfileContext() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["session_id"] as? String, "session-openrouter")
            XCTAssertEqual(body["message"] as? String, "Use the selected profile model")
            XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body["model"] as? String, "deepseek/deepseek-chat-v3-0324:free")
            XCTAssertEqual(body["model_provider"] as? String, "openrouter")
            XCTAssertEqual(body["profile"] as? String, "work")
            XCTAssertNil(body["modelProvider"])
            XCTAssertNil(body["explicit_model_pick"])

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-openrouter",
              "session_id": "session-openrouter"
            }
            """, for: request)
        }

        let response = try await client.startChat(
            sessionID: "session-openrouter",
            message: "Use the selected profile model",
            workspace: "/tmp/workspace",
            model: "deepseek/deepseek-chat-v3-0324:free",
            modelProvider: "openrouter",
            profile: "work"
        )

        XCTAssertEqual(response.streamId, "stream-openrouter")
        XCTAssertEqual(response.sessionId, "session-openrouter")
    }

    func testStartChatIncludesExplicitModelPickOnlyWhenRequested() async throws {
        var requestCount = 0
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            XCTAssertEqual(request.httpMethod, "POST")

            requestCount += 1
            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")

            if requestCount == 1 {
                XCTAssertEqual(body["explicit_model_pick"] as? Bool, true)
            } else {
                XCTAssertNil(body["explicit_model_pick"])
            }

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-\(requestCount)",
              "session_id": "session-abc"
            }
            """, for: request)
        }

        _ = try await client.startChat(
            sessionID: "session-abc",
            message: "Use the explicit model",
            workspace: "/tmp/workspace",
            model: "gpt-5.4-mini",
            explicitModelPick: true
        )
        _ = try await client.startChat(
            sessionID: "session-abc",
            message: "Use the ordinary model context",
            workspace: "/tmp/workspace",
            model: "gpt-5.4-mini"
        )

        XCTAssertEqual(requestCount, 2)
    }

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
        XCTAssertEqual(item.localImageData, source.originalBytes)
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
            session: SessionSummary(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
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
            session: SessionSummary(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
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
            session: try makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
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
            session: try makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
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
            session: try makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
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
            session: try makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
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
            session: try makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
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
            session: try makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
        )

        await viewModel.load()

        guard case let .unavailable(message) = viewModel.preview else {
            return XCTFail("Known unsupported direct binaries should remain unavailable.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("file type"))
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
            session: try makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
        )

        await viewModel.load()

        XCTAssertNil(viewModel.preview)
        XCTAssertEqual(viewModel.errorMessage, APIError.unauthorized.localizedDescription)
        guard let error = viewModel.lastError as? APIError,
              case .unauthorized = error else {
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
            session: try makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client,
            usesDirectGateway: true
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

    @MainActor
    func testChatAttachmentPreviewLoadsPDFBytesFromRawEndpoint() async throws {
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage()
            "Attachment PDF".draw(at: CGPoint(x: 24, y: 24), withAttributes: nil)
        }
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file/raw")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/pdf"]
            )
            return (try XCTUnwrap(response), pdfData)
        }
        let item = ChatAttachmentPreviewItem(
            pending: PendingAttachment(
                name: "report.pdf",
                path: "/tmp/workspace/report.pdf",
                mime: "application/pdf",
                size: pdfData.count,
                isImage: false,
                thumbnailData: nil
            )
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .pdf(previewDocument) = viewModel.preview else {
            return XCTFail("PDF attachments should load into the native PDF preview state.")
        }
        XCTAssertEqual(previewDocument.document.pageCount, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChatAttachmentPreviewLoadsUploadedMarkdownFromInboxCapableRawEndpoint() async throws {
        let markdown = "# Notes\n\nRendered markdown."
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file/raw")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], "notes.md")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/markdown; charset=utf-8"]
            )
            return (try XCTUnwrap(response), Data(markdown.utf8))
        }
        let item = ChatAttachmentPreviewItem(
            pending: PendingAttachment(
                name: "notes.md",
                path: "notes.md",
                mime: "text/markdown",
                size: markdown.utf8.count,
                isImage: false,
                thumbnailData: nil
            )
        )
        let viewModel = try ChatAttachmentPreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: item,
            apiClient: client
        )

        await viewModel.load()

        guard case let .markdown(file) = viewModel.preview else {
            return XCTFail("Markdown attachments should load into the rendered document state.")
        }
        XCTAssertEqual(file.content, "# Notes\n\nRendered markdown.")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCancelChatBuildsExpectedQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["stream_id"], "stream-123")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "cancelled": true,
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let response = try await client.cancelChat(streamID: "stream-123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.cancelled, true)
        XCTAssertEqual(response.streamId, "stream-123")
    }

    func testChatStreamStatusBuildsExpectedQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["stream_id"], "stream-123")

            return apiTestJSONResponse("""
            {
              "active": true,
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let response = try await client.chatStreamStatus(streamID: "stream-123")

        XCTAssertEqual(response.active, true)
        XCTAssertEqual(response.streamId, "stream-123")
    }
}
