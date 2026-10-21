import XCTest
@testable import HermesCompanion

@MainActor
final class VoiceDictationTests: XCTestCase {
    private func context(session: String? = "first", host: UUID = UUID(), selection: UUID = UUID()) -> VoiceDraftContext {
        VoiceDraftContext(sessionID: session, hostGeneration: host, selectionGeneration: selection)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<100 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate())
    }

    func testFinishAppendsToConcurrentEditsExactlyOnceAndNeverSends() async {
        let engine = HeldVoiceEngine()
        let voice = VoiceDictationController(makeEngine: { engine })
        let origin = context()
        var draft = "Already typed"
        var insertions = 0
        voice.begin(context: origin)
        await waitUntil { voice.phase == .recording }
        XCTAssertEqual(draft, "Already typed")
        voice.finish(currentContext: { origin }) {
            insertions += 1
            draft = VoiceDictationController.appending($0, to: draft)
        }
        voice.finish(currentContext: { origin }) { _ in XCTFail("Repeated Finish must not start another insertion") }
        draft += " and edited"
        await waitUntil { engine.finalResult != nil }
        engine.complete("  Dictated sentence.  ")
        await waitUntil { voice.phase == .idle }
        XCTAssertEqual(draft, "Already typed and edited Dictated sentence.")
        XCTAssertEqual(insertions, 1)
        XCTAssertEqual(engine.finishCount, 1)
    }

    func testCancelRejectsLateTranscriptAndLateEvents() async {
        let engine = HeldVoiceEngine()
        let voice = VoiceDictationController(makeEngine: { engine })
        let origin = context()
        voice.begin(context: origin)
        await waitUntil { voice.phase == .recording }
        voice.finish(currentContext: { origin }) { _ in XCTFail("Canceled text must not be inserted") }
        await waitUntil { engine.finalResult != nil }
        voice.cancel()
        engine.events?(.level(1))
        engine.events?(.downloading(1))
        engine.complete("Late transcript")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(voice.phase, .idle)
        XCTAssertTrue(voice.levels.allSatisfy { $0 == 0 })
        XCTAssertEqual(engine.cancelCount, 1)
    }

    func testCancelThenImmediateRestartIgnoresPreviousAttemptResults() async {
        let first = HeldVoiceEngine()
        let second = HeldVoiceEngine()
        var count = 0
        let voice = VoiceDictationController(makeEngine: { count += 1; return count == 1 ? first : second })
        let origin = context()
        var inserted: [String] = []
        voice.begin(context: origin)
        await waitUntil { voice.phase == .recording }
        voice.finish(currentContext: { origin }) { inserted.append($0) }
        await waitUntil { first.finalResult != nil }
        voice.cancel()
        voice.begin(context: origin)
        await waitUntil { voice.phase == .recording }
        first.complete("Stale")
        first.events?(.failed)
        first.events?(.interrupted)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(voice.phase, .recording)
        voice.finish(currentContext: { origin }) { inserted.append($0) }
        await waitUntil { second.finalResult != nil }
        second.complete("Current")
        await waitUntil { voice.phase == .idle }
        XCTAssertEqual(inserted, ["Current"])
        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(second.cancelCount, 1)
    }

    func testChangedContextRejectsResultsEvenWithoutViewChangeCallback() async {
        for switchHost in [false, true] {
            let engine = HeldVoiceEngine()
            let voice = VoiceDictationController(makeEngine: { engine })
            let origin = context()
            var current = origin
            voice.begin(context: origin)
            await waitUntil { voice.phase == .recording }
            voice.finish(currentContext: { current }) { _ in XCTFail("Old conversation text must not be inserted") }
            await waitUntil { engine.finalResult != nil }
            current = context(session: origin.sessionID, host: switchHost ? UUID() : origin.hostGeneration)
            engine.complete("Old text")
            await waitUntil { voice.phase == .idle }
            XCTAssertEqual(engine.cancelCount, 1)
        }
    }

    func testNavigationAwayAndBackInvalidatesSameConversationAttempt() async {
        let engine = HeldVoiceEngine()
        let voice = VoiceDictationController(makeEngine: { engine })
        let origin = context()
        voice.begin(context: origin)
        await waitUntil { voice.phase == .recording }
        voice.contextChanged(context(session: "second", host: origin.hostGeneration))
        voice.contextChanged(origin)
        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(engine.cancelCount, 1)
        voice.finish(currentContext: { origin }) { _ in XCTFail("Navigation canceled dictation") }
        XCTAssertEqual(engine.finishCount, 0)
    }

    func testPreparationCancellationNeverStartsMicrophone() async {
        let engine = HeldVoiceEngine()
        engine.holdPreparation = true
        let voice = VoiceDictationController(makeEngine: { engine })
        voice.begin(context: context())
        await waitUntil { engine.preparation != nil }
        voice.cancel()
        engine.preparation?.resume()
        engine.preparation = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(voice.phase, .idle)
    }

    func testDownloadRequiresExplicitActionAndShowsProgress() async {
        var engines: [HeldVoiceEngine] = []
        let voice = VoiceDictationController(makeEngine: {
            let engine = HeldVoiceEngine()
            engine.needsAssets = true
            engines.append(engine)
            return engine
        })
        let origin = context()
        voice.begin(context: origin)
        await waitUntil { voice.phase == .needsDownload("English") }
        XCTAssertEqual(engines[0].startCount, 0)
        voice.begin(context: origin, allowDownload: true)
        await waitUntil { voice.phase == .recording }
        XCTAssertEqual(engines[1].allowedDownload, true)
        voice.cancel()
    }

    func testPermissionAndAssetErrorsNeverStartRecording() async {
        for failure in [VoiceFailure.microphoneDenied, .unsupported, .unsupportedLanguage, .assetsUnavailable] {
            let engine = HeldVoiceEngine()
            engine.preparationError = failure
            let voice = VoiceDictationController(makeEngine: { engine })
            voice.begin(context: context())
            await waitUntil { voice.phase == .failed(failure) }
            XCTAssertEqual(engine.startCount, 0)
            XCTAssertEqual(engine.cancelCount, 1)
        }
    }

    func testInterruptionStopsCaptureAndPreservesUncommittedText() async {
        let engine = HeldVoiceEngine()
        let voice = VoiceDictationController(makeEngine: { engine })
        voice.begin(context: context())
        await waitUntil { voice.phase == .recording }
        engine.events?(.interrupted)
        XCTAssertEqual(voice.phase, .failed(.interrupted))
        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertEqual(engine.finishCount, 0)
    }

    func testNoSpeechDoesNotReplaceDraft() async {
        let engine = HeldVoiceEngine()
        let voice = VoiceDictationController(makeEngine: { engine })
        let origin = context()
        voice.begin(context: origin)
        await waitUntil { voice.phase == .recording }
        voice.finish(currentContext: { origin }) { _ in XCTFail("Silence must not change the draft") }
        await waitUntil { engine.finalResult != nil }
        engine.complete(" \n ")
        await waitUntil { voice.phase == .failed(.noSpeech) }
    }

    func testFinalSegmentsReplaceDuplicateRangesAndPreserveOrder() {
        var segments: [VoiceTranscriptSegment] = []
        VoiceTranscriptSegment.merge(.init(start: 2, duration: 1, text: " second"), into: &segments)
        VoiceTranscriptSegment.merge(.init(start: 0, duration: 2, text: "First"), into: &segments)
        VoiceTranscriptSegment.merge(.init(start: 2, duration: 1, text: " sentence."), into: &segments)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.sorted { $0.start < $1.start }.map(\.text).joined(), "First sentence.")
        XCTAssertEqual(VoiceDictationController.appending("Next", to: "First\n"), "First\nNext")
        XCTAssertEqual(VoiceDictationController.appending("Next", to: ""), "Next")
    }
}

@MainActor
private final class HeldVoiceEngine: VoiceEngine {
    var preparationError: VoiceFailure?
    var needsAssets = false
    var allowedDownload = false
    var holdPreparation = false
    var startCount = 0
    var cancelCount = 0
    var finishCount = 0
    var events: (@MainActor @Sendable (VoiceEngineEvent) -> Void)?
    var preparation: CheckedContinuation<Void, Never>?
    var finalResult: CheckedContinuation<String, Error>?
    func prepare(allowDownload: Bool, events: @escaping @MainActor @Sendable (VoiceEngineEvent) -> Void) async throws {
        self.events = events
        allowedDownload = allowDownload
        if let preparationError { throw preparationError }
        if needsAssets && !allowDownload { throw VoiceFailure.downloadRequired("English") }
        if allowDownload { events(.downloading(0.5)) }
        if holdPreparation { await withCheckedContinuation { preparation = $0 } }
    }
    func start() async throws { startCount += 1 }
    func finish() async throws -> String {
        finishCount += 1
        return try await withCheckedThrowingContinuation { finalResult = $0 }
    }
    func complete(_ text: String) { finalResult?.resume(returning: text); finalResult = nil }
    func cancel() { cancelCount += 1 }
}
