import XCTest
import UIKit
@testable import HermesMobile

@MainActor
final class ChatAttachmentCoordinatorTests: APIClientTestCase {
    private var delegateSpies: [ChatAttachmentCoordinatorDelegateSpy] = []

    override func tearDown() {
        super.tearDown()
    }

    func testPastedFileLoaderReadsSelectedFileAndPreservesFilename() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("semreh-pasted-file-\(UUID().uuidString).txt")
        let expectedData = Data("selected file contents".utf8)
        try expectedData.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try await PastedFileLoader.load(from: url, suggestedName: nil)

        XCTAssertEqual(file.data, expectedData)
        XCTAssertEqual(file.filename, url.lastPathComponent)
    }

    func testLocalPendingAndPreviewBookkeepingRemainsTransportIndependent() throws {
        let preview = Data([0x01, 0x02])
        let first = PendingAttachment(
            name: "one.png", path: "/tmp/one.png", mime: "image/png",
            size: preview.count, isImage: true, thumbnailData: preview
        )
        let second = PendingAttachment(
            name: "two.txt", path: "/tmp/two.txt", mime: "text/plain",
            size: 3, isImage: false, thumbnailData: nil
        )
        let coordinator = makeCoordinator(client: makeClient { request in
            XCTFail("Local bookkeeping must not request the network: \(request)")
            throw URLError(.badServerResponse)
        })
        coordinator.replacePendingAttachments([first, second])
        let firstID = try XCTUnwrap(coordinator.pendingAttachments.first?.id)

        coordinator.removePendingAttachment(id: firstID)

        XCTAssertEqual(coordinator.pendingAttachments.map(\.name), ["two.txt"])
        coordinator.restorePendingAttachments([first])
        let preparation = coordinator.prepareForSend(localMessageID: "local-message")
        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
        XCTAssertEqual(preparation.attachments.map(\.name), ["one.png", "two.txt"])
        XCTAssertEqual(preparation.apiPayloads?.count, 2)
        XCTAssertEqual(coordinator.localAttachmentPreviews["local-message"]?["/tmp/one.png"], preview)
    }

    func testTranscriptSameServerRemoteMediaUsesAuthenticatedSession() async throws {
        let mediaData = Data([0x01, 0x02, 0x03])
        let remoteURL = try XCTUnwrap(URL(string: "https://example.test/generated/media/image.png?variant=full"))
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "authenticated")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let thumbnail = await coordinator.transcriptMediaThumbnailData(
            for: TranscriptMediaReference(rawReference: remoteURL.absoluteString)
        )

        XCTAssertEqual(thumbnail, mediaData)
    }

    func testTranscriptLocalImageIncludesSessionIDOnMediaEndpoint() async throws {
        let mediaData = try XCTUnwrap(Self.imageData())
        let mediaPath = "/Users/hermes/.hermes/browser_screenshots/example.png"
        let sessionID = "session-abc"
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/media")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], sessionID)
            XCTAssertEqual(query["path"], mediaPath)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let thumbnail = await coordinator.transcriptMediaThumbnailData(
            for: TranscriptMediaReference(rawReference: mediaPath)
        )

        XCTAssertNotNil(thumbnail)
    }

    func testTranscriptLocalAudioUsesManagedFileEndpoint() async throws {
        let mediaData = Data("audio-bytes".utf8)
        let mediaPath = "/tmp/generated/clip.mp3"
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/files/read")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["path"], mediaPath)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let dataURL = "data:audio/mpeg;base64,\(mediaData.base64EncodedString())"
            return (response, Data(#"{"data_url":"\#(dataURL)","mime_type":"audio/mpeg","name":"clip.mp3","path":"/tmp/generated/clip.mp3","size":11}"#.utf8))
        }
        let coordinator = makeCoordinator(client: client)

        let data = await coordinator.transcriptMediaData(
            for: TranscriptMediaReference(rawReference: mediaPath)
        )

        XCTAssertEqual(data, mediaData)
    }

    func testTranscriptExternalRemoteVideoUsesPublicMediaSession() async throws {
        let mediaData = Data("video-bytes".utf8)
        let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.test/generated/movie.mp4"))
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "public")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let data = await coordinator.transcriptMediaData(
            for: TranscriptMediaReference(rawReference: remoteURL.absoluteString)
        )

        XCTAssertEqual(data, mediaData)
    }

    func testTranscriptLocalAudioWithoutSessionDoesNotRequestMediaEndpoint() async {
        var requestCount = 0
        let client = makeAuthenticatedMediaClient { request in
            requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("unexpected".utf8))
        }
        let coordinator = ChatAttachmentCoordinator(client: client)
        let delegate = ChatAttachmentCoordinatorDelegateSpy()
        delegate.attachmentSessionID = nil
        delegateSpies.append(delegate)
        coordinator.delegate = delegate

        let data = await coordinator.transcriptMediaData(
            for: TranscriptMediaReference(rawReference: "/tmp/generated/clip.mp3")
        )

        XCTAssertNil(data)
        XCTAssertEqual(requestCount, 0)
    }

    private func makeCoordinator(client: APIClient) -> ChatAttachmentCoordinator {
        let coordinator = ChatAttachmentCoordinator(client: client)
        let delegate = ChatAttachmentCoordinatorDelegateSpy()
        delegateSpies.append(delegate)
        coordinator.delegate = delegate
        return coordinator
    }

    private func makeAuthenticatedMediaClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let authenticatedConfiguration = URLSessionConfiguration.ephemeral
        authenticatedConfiguration.protocolClasses = [MockURLProtocol.self]
        authenticatedConfiguration.httpAdditionalHeaders = ["X-Hermes-Test-Session": "authenticated"]

        let publicConfiguration = URLSessionConfiguration.ephemeral
        publicConfiguration.protocolClasses = [MockURLProtocol.self]
        publicConfiguration.httpAdditionalHeaders = ["X-Hermes-Test-Session": "public"]

        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: authenticatedConfiguration),
            publicMediaSession: URLSession(configuration: publicConfiguration)
        )
    }

    private static func imageData() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }

}

@MainActor
private final class ChatAttachmentCoordinatorDelegateSpy: ChatAttachmentCoordinatorDelegate {
    var attachmentSessionID: String? = "session-abc"
}
