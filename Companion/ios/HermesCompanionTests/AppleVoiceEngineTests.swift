import XCTest
@testable import HermesCompanion

#if DEBUG
@MainActor
final class AppleVoiceEngineTests: XCTestCase {
    func testInstalledAppleEngineTranscribesOptInFileWithoutMicrophoneOrDownload() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["COMPANION_TEST_SPEECH_FILE"],
              let expected = environment["COMPANION_TEST_SPEECH_EXPECTED"], !expected.isEmpty else {
            throw XCTSkip("Requires a root-selected local audio file and corrected reference. No microphone or model download is performed.")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26.") }
        let engine = AppleVoiceEngine()
        defer { engine.cancel() }
        let transcript: String
        do { transcript = try await engine.transcribeFileForVerification(URL(fileURLWithPath: path)) }
        catch VoiceFailure.unsupported { throw XCTSkip("SpeechTranscriber is unavailable on this runtime/hardware. Fixture results do not establish recognition.") }
        catch VoiceFailure.unsupportedLanguage { throw XCTSkip("The runtime's current language is unsupported.") }
        catch VoiceFailure.downloadRequired(let language) { throw XCTSkip("The \(language) model is not installed. No download was authorized for this check.") }
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains(expected), "The actual Apple engine must include the supplied corrected reference.")
        let evidence = XCTAttachment(string: transcript)
        evidence.name = "real-apple-file-transcript"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}

#endif
