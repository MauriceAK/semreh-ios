import XCTest
@testable import HermesMobile

final class APIClientSessionExportTests: APIClientTestCase {
    // MARK: - Endpoint construction

    func testExportEndpointBuildsPathAndQuery() {
        let url = Endpoint.exportSession(sessionID: "abc-123", format: .html)
            .url(relativeTo: URL(string: "https://example.test")!)

        XCTAssertEqual(url.path, "/api/session/export")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            components?.queryItems,
            [
                URLQueryItem(name: "session_id", value: "abc-123"),
                URLQueryItem(name: "format", value: "html")
            ]
        )
    }

    func testExportEndpointEncodesJSONFormat() {
        let url = Endpoint.exportSession(sessionID: "abc 123", format: .json)
            .url(relativeTo: URL(string: "https://example.test")!)

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.last, URLQueryItem(name: "format", value: "json"))
        // Session IDs with spaces must be percent-encoded, not dropped.
        XCTAssertEqual(components?.queryItems?.first?.value, "abc 123")
    }

    // MARK: - Download

    func testExportSessionRendersStockTranscriptWithEscapedMetadataAndTools() async throws {
        let json = Data(#"{"id":"abc-123","title":"<script>bad</script>","custom":{"preserved":true},"messages":[{"role":"assistant","content":"<img src='https://evil.test'> & hello","tool_calls":[{"function":{"name":"fixture","arguments":"secretless"}}]},{"role":"tool","content":"tool output"}]}"#.utf8)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/abc-123/export")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work")])
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            // The response is a file download, so the export request must not
            // claim it only accepts JSON.
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Disposition": "attachment; filename=\"hermes-abc-123.html\""
                ]
            )!
            return (response, json)
        }

        let file = try await client.exportSession(id: "abc-123", format: .html, fallbackTitle: "Planning", profile: "work")

        let html = String(decoding: file.data, as: UTF8.self)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("tool output"))
        XCTAssertTrue(html.contains("tool_calls"))
        XCTAssertTrue(html.contains("preserved"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertEqual(file.filename, "Planning.html")
    }

    func testExportSessionFallsBackToTitleWhenHeaderMissing() async throws {
        let json = Data(#"{"id":"abc-123","messages":[],"unknown":{"kept":true}}"#.utf8)
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, json)
        }

        let file = try await client.exportSession(id: "abc-123", format: .json, fallbackTitle: "Planning notes", profile: "default")

        XCTAssertEqual(file.data, json)
        XCTAssertEqual(file.filename, "Planning notes.json")
    }

    func testExportSessionMapsBadRequestToHTTPErrorWithBody() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error": "Session not found"}"#.utf8))
        }

        do {
            _ = try await client.exportSession(id: "missing", format: .html, profile: "default")
            XCTFail("Expected direct request failure")
        } catch DirectHermesRequestError.http(let statusCode, _) {
            XCTAssertEqual(statusCode, 404)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExportRejectsMalformedOrPartialJSONInsteadOfSharingTruncatedFile() async throws {
        for payload in [#"{"messages":["#, #"{"id":"missing-messages"}"#] {
            let client = makeClient { apiTestJSONResponse(payload, for: $0) }
            do {
                _ = try await client.exportSession(id: "s", format: .json, profile: "work")
                XCTFail("Invalid export accepted")
            } catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    func testExportEnforcesStreamingByteLimit() async throws {
        let client = makeClient { apiTestJSONResponse(#"{"messages":[],"extra":"01234567890123456789"}"#, for: $0) }
        do {
            _ = try await client.exportSession(id: "s", format: .json, profile: "default", maximumBytes: 16)
            XCTFail("Oversized export accepted")
        } catch PreviewDownloadError.responseTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 16)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testHTMLSizeLimitFailsWithoutTruncatingAndPreservesStructuredContent() throws {
        let object: [String: Any] = ["messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": "https://invalid.test/image"]]]]]]
        let html = String(decoding: try SessionExportFile.html(from: object), as: UTF8.self)
        XCTAssertTrue(html.contains("image_url"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertThrowsError(try SessionExportFile.html(from: object, maximumBytes: 10))
    }

    func testExportPreservesMessagesBeyondStockStreamPageAndRejectsWrongIdentity() async throws {
        let object: [String: Any] = ["id": "s", "messages": (0..<501).map { ["role": "user", "content": "row-\($0)"] }]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let client = makeClient { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "application/json"])!, bytes)
        }
        let file = try await client.exportSession(id: "s", format: .html, profile: "default")
        XCTAssertTrue(String(decoding: file.data, as: UTF8.self).contains("row-500"))
        do {
            _ = try await client.exportSession(id: "other", format: .json, profile: "default")
            XCTFail("Wrong exported identity accepted")
        } catch SessionExportError.invalidResponse { }
    }

    // MARK: - Filename derivation

    func testFilenamePrefersQuotedContentDisposition() {
        let filename = SessionExportFile.filename(
            contentDisposition: "attachment; filename=\"hermes-s1.html\"",
            fallbackTitle: "Ignored",
            sessionID: "s1",
            format: .html
        )
        XCTAssertEqual(filename, "hermes-s1.html")
    }

    func testFilenameParsesUnquotedToken() {
        let filename = SessionExportFile.filename(
            contentDisposition: "attachment; filename=export.json",
            fallbackTitle: nil,
            sessionID: "s1",
            format: .json
        )
        XCTAssertEqual(filename, "export.json")
    }

    func testFilenameStripsPathComponentsFromHeader() {
        let filename = SessionExportFile.filename(
            contentDisposition: "attachment; filename=\"../../etc/passwd\"",
            fallbackTitle: nil,
            sessionID: "s1",
            format: .html
        )
        // Only the last path component survives; traversal segments are gone.
        XCTAssertEqual(filename, "passwd")
    }

    func testFilenameSanitizesTitleFallback() {
        let filename = SessionExportFile.filename(
            contentDisposition: nil,
            fallbackTitle: "  Fix: build/CI \n pipeline  ",
            sessionID: "s1",
            format: .html
        )
        XCTAssertEqual(filename, "Fix build CI pipeline.html")
    }

    func testFilenameUsesSessionIDWhenTitleUnusable() {
        let filename = SessionExportFile.filename(
            contentDisposition: "inline",
            fallbackTitle: "   ",
            sessionID: "abc-123",
            format: .json
        )
        XCTAssertEqual(filename, "hermes-abc-123.json")
    }

    func testFilenameTruncatesVeryLongTitles() {
        let longTitle = String(repeating: "a", count: 200)
        let filename = SessionExportFile.filename(
            contentDisposition: nil,
            fallbackTitle: longTitle,
            sessionID: "s1",
            format: .json
        )
        XCTAssertEqual(filename, String(repeating: "a", count: 80) + ".json")
    }
}
