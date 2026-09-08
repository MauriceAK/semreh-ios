import XCTest
@testable import HermesMobile

final class APIClientTTSTests: APIClientTestCase {
    func testSynthesisUsesStockTextOnlyRequestAndDecodesAudioEnvelope() async throws {
        let audio = Data([0xFF, 0xF3, 0x18, 0xC4])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/audio/speak")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work")])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: try XCTUnwrap(apiTestBodyData(from: request))) as? [String: String])
            XCTAssertEqual(object, ["text": "Hello from Semreh."])
            return apiTestJSONResponse(String(decoding: try Self.envelope(audio: audio), as: UTF8.self), for: request)
        }
        let result = try await client.synthesizeSpeech(text: "Hello from Semreh.", profile: "work")
        XCTAssertEqual(result, audio)
    }

    func testSupportedStockAudioMIMEsAndUnknownEnvelopeFields() throws {
        for mime in ["audio/mpeg", "audio/ogg", "audio/wav", "audio/flac"] {
            let audio = Data([1, 2, 3])
            XCTAssertEqual(try DirectTTSAudioResponse.decode(Self.envelope(audio: audio, mime: mime)), audio)
        }
    }

    func testMalformedOrNonAudioEnvelopeIsRejected() throws {
        let invalid: [[String: Any]] = [
            [:],
            ["ok": false, "mime_type": "audio/mpeg", "data_url": "data:audio/mpeg;base64,AQ=="],
            ["ok": true, "mime_type": "text/html", "data_url": "data:text/html;base64,AQ=="],
            ["ok": true, "mime_type": "audio/wav", "data_url": "data:audio/mpeg;base64,AQ=="],
            ["ok": true, "mime_type": "audio/mpeg", "data_url": "https://other.test/audio"],
            ["ok": true, "mime_type": "audio/mpeg", "data_url": "data:audio/mpeg;base64,"],
            ["ok": true, "mime_type": "audio/mpeg", "data_url": "data:audio/mpeg;base64,%%%"],
            ["ok": true, "mime_type": "audio/mpeg", "data_url": "data:audio/mpeg;base64,A Q=="],
            ["ok": true, "mime_type": "audio/mpeg", "data_url": "data:audio/mpeg;base64,AR=="]
        ]
        for object in invalid {
            XCTAssertThrowsError(try DirectTTSAudioResponse.decode(JSONSerialization.data(withJSONObject: object))) {
                guard case APIError.decoding = $0 else { return XCTFail("Expected decoding failure") }
            }
        }
    }

    func testDecodedAudioLimitRejectsOverflowWithoutChangingBoundaryBytes() throws {
        let envelope = try Self.envelope(audio: Data([1, 2, 3]))
        XCTAssertEqual(try DirectTTSAudioResponse.decode(envelope, maximumDecodedBytes: 3), Data([1, 2, 3]))
        XCTAssertThrowsError(try DirectTTSAudioResponse.decode(envelope, maximumDecodedBytes: 2)) {
            XCTAssertEqual($0 as? PreviewDownloadError, .responseTooLarge(maximumBytes: 2))
        }
    }

    func testOversizedEnvelopeIsRejectedFromContentLength() async {
        let client = makeClient { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json",
                    "Content-Length": String(DirectTTSAudioResponse.maximumEnvelopeBytes + 1)]))
            return (response, Data())
        }
        do {
            _ = try await client.synthesizeSpeech(text: "Hello.", profile: "default")
            XCTFail("Expected bounded response failure")
        } catch is PreviewDownloadError { }
        catch { XCTFail("Expected size-limit error") }
    }

    func testRawLegacyAudioIsRejected() async {
        let client = makeClient { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"]))
            return (response, Data([1, 2, 3]))
        }
        do {
            _ = try await client.synthesizeSpeech(text: "Hello.", profile: "default")
            XCTFail("Expected JSON envelope")
        } catch APIError.decoding { }
        catch { XCTFail("Expected decoding failure") }
    }

    func testRateLimitPreservesDirectClassificationWithoutRawBody() async {
        let client = makeClient { request in
            try Self.errorResponse(#"{"detail":"private server error"}"#, for: request, statusCode: 429)
        }
        do {
            _ = try await client.synthesizeSpeech(text: "Hello.", profile: "default")
            XCTFail("Expected rate limit")
        } catch let error as DirectHermesRequestError {
            XCTAssertEqual(error, .http(statusCode: 429, reason: .rateLimited))
        } catch { XCTFail("Expected direct HTTP classification") }
    }

    func testStructuredExpiryAndUnstructured401RemainDistinct() async {
        for structured in [true, false] {
            let client = makeClient { request in
                try Self.errorResponse(structured
                    ? #"{"error":"session_expired","detail":"Unauthorized","reason":"invalid_or_expired_session"}"#
                    : #"{"detail":"Unauthorized"}"#, for: request, statusCode: 401)
            }
            do {
            _ = try await client.synthesizeSpeech(text: "Hello.", profile: "default")
                XCTFail("Expected auth failure")
            } catch DirectHermesAuthError.sessionExpired {
                XCTAssertTrue(structured)
            } catch let error as DirectHermesRequestError {
                XCTAssertFalse(structured)
                XCTAssertEqual(error, .http(statusCode: 401, reason: .unauthorized))
            } catch { XCTFail("Expected direct auth classification") }
        }
    }

    private static func envelope(audio: Data, mime: String = "audio/mpeg") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "ok": true, "data_url": "data:\(mime);base64,\(audio.base64EncodedString())",
            "mime_type": mime, "provider": "fixture", "future_field": true
        ])
    }

    private static func errorResponse(_ json: String, for request: URLRequest, statusCode: Int) throws -> (HTTPURLResponse, Data) {
        (try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: statusCode,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])), Data(json.utf8))
    }
}
