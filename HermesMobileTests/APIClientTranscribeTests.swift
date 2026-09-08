import XCTest
@testable import HermesMobile

final class APIClientTranscribeTests: APIClientTestCase {
    func testExactStockRequestAndResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/audio/transcribe")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work & notes")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(apiTestBodyData(from: request))) as! [String: String]
            XCTAssertEqual(body, ["data_url": "data:audio/wav;base64,Y2xpcA==", "mime_type": "audio/wav"])
            return apiTestJSONResponse(#"{"ok":true,"transcript":"hello","provider":"fixture","future":1}"#, for: request)
        }
        let response = try await client.transcribeAudio(data: Data("clip".utf8), mimeType: "audio/wav", profile: "work & notes")
        XCTAssertEqual(response.transcript, "hello")
    }

    func testEmptyTranscriptIsValidSilence() async throws {
        let client = makeClient { apiTestJSONResponse(#"{"ok":true,"transcript":""}"#, for: $0) }
        let response = try await client.transcribeAudio(data: Data([1]), mimeType: "audio/wav", profile: "default")
        XCTAssertEqual(response.transcript, "")
    }

    func testMalformedSuccessCannotBecomeTranscript() async throws {
        let client = makeClient { apiTestJSONResponse(#"{"transcript":"unacknowledged"}"#, for: $0) }
        do {
            _ = try await client.transcribeAudio(data: Data([1]), mimeType: "audio/wav", profile: "default")
            XCTFail("Expected rejected acknowledgement")
        } catch DirectTranscriptionError.invalidAcknowledgement {}
    }

    func testStockErrorDoesNotRetryLegacyEndpoint() async throws {
        var requests = 0
        let client = makeClient { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/api/audio/transcribe")
            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"detail":"Transcription unavailable"}"#.utf8))
        }
        do {
            _ = try await client.transcribeAudio(data: Data([1]), mimeType: "audio/wav", profile: "default")
            XCTFail("Expected stock error")
        } catch {}
        XCTAssertEqual(requests, 1)
    }

    func testInvalidAndOversizedRecordingsNeverUpload() async throws {
        let client = makeClient { _ in XCTFail("Must not upload"); throw URLError(.badURL) }
        for data in [Data(), Data(repeating: 0, count: APIClient.maximumTranscriptionBytes + 1)] {
            do {
                _ = try await client.transcribeAudio(data: data, mimeType: "audio/wav", profile: "default")
                XCTFail("Expected local validation")
            } catch is DirectTranscriptionError {}
        }
    }

    @MainActor
    func testHeldTranscriptCannotCommitAfterLiveProfileChanges() async {
        var liveProfile = "original"
        var draft = ComposerVoiceDraftUpdateSession()
        draft.begin(baseDraft: "Keep this", profile: liveProfile,
                    currentProfile: { liveProfile })
        var completion: CheckedContinuation<String, Never>?
        let heldTranscriber = Task { @MainActor in
            await withCheckedContinuation { completion = $0 }
        }
        while completion == nil { await Task.yield() }
        liveProfile = "different"
        completion?.resume(returning: "late words")
        let transcript = await heldTranscriber.value
        XCTAssertNil(draft.composedDraft(for: transcript))
        liveProfile = "original"
        XCTAssertEqual(draft.composedDraft(for: transcript), "Keep this late words")
    }

    @MainActor
    func testProfileScopePreservesSelectionSessionAndDefault() {
        XCTAssertEqual(ComposerVoiceInputController.profileScope(selected: " chosen ", session: "existing"), "chosen")
        XCTAssertEqual(ComposerVoiceInputController.profileScope(selected: nil, session: "existing"), "existing")
        XCTAssertEqual(ComposerVoiceInputController.profileScope(selected: " ", session: nil), "default")
    }
}
