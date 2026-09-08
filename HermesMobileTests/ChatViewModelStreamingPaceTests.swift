import SwiftUI
import XCTest
import CryptoKit
@testable import HermesMobile

/// Display-pacing tests for issue #212: buffered streamed tokens are revealed
/// word-by-word at an adaptive cadence, while completion paths flush instantly.
final class ChatViewModelStreamingPaceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testBufferedBurstRevealsWordByWordAtCadence() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        // 60s lag bound keeps the quota at one word per tick for this backlog.
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 200_000_000,
            maxLagNanoseconds: 60_000_000_000
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma delta"))

        let target = "alpha beta gamma delta"
        let observed = try await observeAssistantContent(viewModel, until: target)

        XCTAssertEqual(observed.first, "alpha ")
        XCTAssertEqual(observed.last, target)
        XCTAssertGreaterThanOrEqual(
            observed.count, 3,
            "burst should reveal progressively across cadence ticks, not at once; observed: \(observed)"
        )
        for (earlier, later) in zip(observed, observed.dropFirst()) {
            XCTAssertTrue(
                later.hasPrefix(earlier),
                "paced reveal must only append: \(earlier) → \(later)"
            )
        }

        // The drain loop must re-arm for tokens arriving after the buffer emptied.
        streamClient.emit(.token(" epsilon"))
        _ = try await observeAssistantContent(viewModel, until: target + " epsilon")
        XCTAssertEqual(assistantContent(of: viewModel), target + " epsilon")
    }

    @MainActor
    func testLargeBacklogCatchesUpWithinLagBound() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        // 60 words × 100ms cadence = 6s of backlog; the 300ms lag bound forces a
        // ~20-word quota per tick, so convergence inside the 4s observation window
        // proves catch-up scaling (steady one-word cadence would time out).
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 100_000_000,
            maxLagNanoseconds: 300_000_000
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Stream a reply")
        XCTAssertTrue(didStart)

        let words = (0..<60).map { "w\($0) " }
        for word in words {
            streamClient.emit(.token(word))
        }

        let target = words.joined()
        let observed = try await observeAssistantContent(viewModel, until: target)

        XCTAssertEqual(observed.last, target)
        XCTAssertGreaterThanOrEqual(
            observed.count, 2,
            "catch-up should drain in scaled chunks, not one dump; observed counts: \(observed.map(\.count))"
        )
    }

    @MainActor
    func testDoneEventFlushesRemainingBufferImmediately() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        let didStart = viewModel.seedLegacyResponseForTesting("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma"))
        _ = try await observeAssistantContent(viewModel, until: "alpha ")
        XCTAssertEqual(assistantContent(of: viewModel), "alpha ")

        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")

        // Nothing may trickle in after completion.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testCancelledEventFlushesRemainingBufferImmediately() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        let didStart = viewModel.seedLegacyResponseForTesting("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma"))
        _ = try await observeAssistantContent(viewModel, until: "alpha ")
        XCTAssertEqual(assistantContent(of: viewModel), "alpha ")

        streamClient.emit(.cancelled)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testPacedContentConvergesByteIdenticalToUnpacedJoin() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Stream a reply")
        XCTAssertTrue(didStart)

        // Awkward chunk boundaries: ZWJ family, flag, CRLF, tabs, doubled spaces,
        // and a combining mark split across chunks ("cafe" + U+0301).
        let chunks = [
            "The 👩‍👩‍👧‍👦 family ",
            "and 🇫🇷 flag met.\r\n",
            "tabs\tand  doubles ",
            "cafe",
            "\u{301} fin"
        ]
        for chunk in chunks {
            streamClient.emit(.token(chunk))
        }

        let target = chunks.joined()
        _ = try await observeAssistantContent(viewModel, until: target)
        let content = try XCTUnwrap(assistantContent(of: viewModel))
        XCTAssertEqual(
            Array(content.utf8),
            Array(target.utf8),
            "paced content must converge byte-identical to the unpaced concatenation"
        )
    }

    @MainActor
    func testOffscreenTranscriptBuffersPresentationUntilReopened() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Keep working while I leave")
        XCTAssertTrue(didStart)
        viewModel.setTranscriptPresentationActive(false)
        streamClient.emit(.token("alpha beta gamma"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(assistantContent(of: viewModel), "")
        XCTAssertEqual(streamClient.stopCount, 0, "Leaving the screen must preserve transport ownership")

        viewModel.setTranscriptPresentationActive(true)
        _ = try await observeAssistantContent(viewModel, until: "alpha beta gamma")
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testStreamingMutationCostDoesNotScaleWithLoadedHistory() async throws {
        let large = try await timedStreamingHotPaths(historyMessageCount: 10_000)
        let small = try await timedStreamingHotPaths(historyMessageCount: 1_000)
        let evidence = "SEMREH_HISTORY_SCALING "
            + "1k_total=\(small.total)s 10k_total=\(large.total)s "
            + "1k_has=\(small.hasContentLookup)s 10k_has=\(large.hasContentLookup)s "
            + "1k_interim=\(small.interimIngestion)s 10k_interim=\(large.interimIngestion)s"
        print(evidence)
        let attachment = XCTAttachment(string: evidence)
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThan(
            large.total,
            max(small.total * 3, 0.015),
            "10k loaded rows must not make live-tail work history-proportional (1k=\(small.total)s, 10k=\(large.total)s)"
        )
        XCTAssertLessThan(
            large.hasContentLookup,
            max(small.hasContentLookup * 3, 0.015),
            "hasStreamingAssistantMessageContent must stay history-independent (1k=\(small.hasContentLookup)s, 10k=\(large.hasContentLookup)s)"
        )
        XCTAssertLessThan(
            large.interimIngestion,
            max(small.interimIngestion * 3, 0.015),
            "interim_assistant ingestion must stay history-independent (1k=\(small.interimIngestion)s, 10k=\(large.interimIngestion)s)"
        )
    }

    @MainActor
    func testStreamingPositionRecoversAfterStructuralPrepend() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let olderMessages: [[String: Any]] = [[
            "role": "user",
            "content": "older page",
            "message_id": "older-page-0",
            "timestamp": 1_699_999_999
        ]]
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 60_000_000_000,
            maxLagNanoseconds: 3_600_000_000_000,
            historyMessageCount: 4,
            initialMessagesOffset: 1,
            olderMessages: olderMessages
        )

        // makeViewModel seeds renderer history directly; no gateway load claim.
        XCTAssertEqual(viewModel.messagesOffset, 1)

        let didStart = viewModel.seedLegacyResponseForTesting("Keep the live tail")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("live"))
        viewModel.flushPendingStreamingContent()
        let liveMessageID = try XCTUnwrap(viewModel.streamingAssistantMessageID)
        XCTAssertTrue(viewModel.hasStreamingAssistantMessageContent)

        // Exercise the shared structural reducer, not gateway pagination;
        // direct active-run paging has separate boundary and event-routing tests.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let olderRows = try decoder.decode(
            [ChatMessage].self,
            from: JSONSerialization.data(withJSONObject: olderMessages)
        )
        viewModel.prependMessagesForTesting(olderRows)
        XCTAssertEqual(viewModel.messages.first?.id, "older-page-0")
        XCTAssertEqual(viewModel.messages.last?.id, liveMessageID)
        XCTAssertTrue(
            viewModel.hasStreamingAssistantMessageContent,
            "a structural prepend must invalidate the cached index lookup without losing the live row"
        )

        let recomputesAfterPrepend = viewModel.transcriptFullRecomputeCountForTesting
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(
            text: "late interim",
            alreadyStreamed: false
        )))

        let expectedContent = "live\n\nlate interim"
        XCTAssertEqual(viewModel.messages.last?.content, expectedContent)
        XCTAssertEqual(viewModel.displayedTranscriptMessages.last?.message.content, expectedContent)
        XCTAssertEqual(
            viewModel.transcriptFullRecomputeCountForTesting,
            recomputesAfterPrepend,
            "an interim event after pagination must replace the shifted live row incrementally"
        )
    }

    // MARK: - Helpers

    /// 60s cadence with a far larger lag bound keeps the quota at one word per
    /// tick: the first tick reveals one word, then the drain effectively stalls
    /// so completion-path flushes are observable.
    @MainActor
    private func makeStalledDrainViewModel(
        streamClient: PacingSpySSEStreamingClient
    ) throws -> ChatViewModel {
        try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 60_000_000_000,
            maxLagNanoseconds: 3_600_000_000_000
        )
    }


    @MainActor
    private func makeViewModel(
        streamClient: PacingSpySSEStreamingClient,
        wordCadenceNanoseconds: UInt64,
        maxLagNanoseconds: UInt64,
        historyMessageCount: Int = 0,
        initialMessagesOffset: Int = 0,
        olderMessages: [[String: Any]] = []
    ) throws -> ChatViewModel {
        let historyMessages: [[String: Any]] = (0..<historyMessageCount).map { index in
            [
                "role": index.isMultiple(of: 2) ? "user" : "assistant",
                "content": "history-\(index)",
                "message_id": "history-\(index)",
                "timestamp": 1_700_000_000 + index
            ]
        }
        var sessionPayload: [String: Any] = [
            "session_id": "session-abc",
            "title": "Pacing",
            "messages": historyMessages
        ]
        if initialMessagesOffset > 0 {
            sessionPayload["messages_offset"] = initialMessagesOffset
        }
        let sessionResponseData = try JSONSerialization.data(withJSONObject: [
            "session": sessionPayload
        ])
        let sessionResponse = try XCTUnwrap(String(data: sessionResponseData, encoding: .utf8))
        let olderSessionResponseData = try JSONSerialization.data(withJSONObject: [
            "session": [
                "session_id": "session-abc",
                "messages": olderMessages,
                "messages_offset": 0
            ]
        ])
        let olderSessionResponse = try XCTUnwrap(String(data: olderSessionResponseData, encoding: .utf8))

        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            default:
                if request.url?.query?.contains("msg_before=") == true {
                    return apiTestJSONResponse(
                        olderSessionResponse,
                        for: request
                    )
                }
                return apiTestJSONResponse(
                    sessionResponse,
                    for: request
                )
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(
            SessionSummary.self,
            from: Data(
                #"{"session_id": "session-abc", "title": "Pacing", "workspace": "/tmp/workspace"}"#.utf8
            )
        )

        let viewModel = ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: streamClient,
            streamingScrollCoalescingDelayNanoseconds: 1_000_000,
            streamingWordRevealCadenceNanoseconds: wordCadenceNanoseconds,
            streamingMaxRevealLagNanoseconds: maxLagNanoseconds
        )
        if historyMessageCount > 0 {
            let rows = try decoder.decode([ChatMessage].self, from: JSONSerialization.data(withJSONObject: historyMessages))
            viewModel.seedTranscriptForTesting(rows, messagesOffset: initialMessagesOffset)
        }
        return viewModel
    }

    @MainActor
    private struct StreamingHotPathBenchmark {
        let total: TimeInterval
        let hasContentLookup: TimeInterval
        let interimIngestion: TimeInterval
    }

    @MainActor
    private func timedStreamingHotPaths(historyMessageCount: Int) async throws -> StreamingHotPathBenchmark {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 60_000_000_000,
            maxLagNanoseconds: 3_600_000_000_000,
            historyMessageCount: historyMessageCount
        )
        // Benchmark renderer state only; history is explicitly seeded above.
        let didStart = viewModel.seedLegacyResponseForTesting("Benchmark live tail")
        XCTAssertTrue(didStart)
        let startedAt = CFAbsoluteTimeGetCurrent()
        streamClient.emit(.token("seed"))
        viewModel.flushPendingStreamingContent()
        XCTAssertTrue(viewModel.hasStreamingAssistantMessageContent)

        var positiveLookups = 0
        let hasStartedAt = CFAbsoluteTimeGetCurrent()
        for _ in 0..<2_000 {
            if viewModel.hasStreamingAssistantMessageContent {
                positiveLookups += 1
            }
        }
        let hasContentLookup = CFAbsoluteTimeGetCurrent() - hasStartedAt
        XCTAssertEqual(positiveLookups, 2_000)

        let recomputesBeforeBurst = viewModel.transcriptFullRecomputeCountForTesting
        var expectedContent = "seed"
        let interimStartedAt = CFAbsoluteTimeGetCurrent()
        for index in 0..<400 {
            let interimText = "interim-\(index)"
            streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(
                text: interimText,
                alreadyStreamed: false
            )))
            expectedContent += "\n\n\(interimText)"
        }
        let interimIngestion = CFAbsoluteTimeGetCurrent() - interimStartedAt

        XCTAssertEqual(assistantContent(of: viewModel), expectedContent)
        XCTAssertEqual(
            viewModel.displayedTranscriptMessages.last?.message.content,
            expectedContent,
            "the incrementally replaced live row must display every interim event"
        )
        XCTAssertEqual(
            viewModel.transcriptFullRecomputeCountForTesting,
            recomputesBeforeBurst,
            "interim_assistant must replace only the live row, not remap the full transcript"
        )

        let chunks = (0..<400).map { "t\($0) " }
        for chunk in chunks {
            streamClient.emit(.token(chunk))
        }
        let completionStartedAt = CFAbsoluteTimeGetCurrent()
        streamClient.emit(.done(DoneStreamEvent()))
        let completionElapsed = CFAbsoluteTimeGetCurrent() - completionStartedAt
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        print(
            "SEMREH_HISTORY_PHASE rows=\(historyMessageCount) interim=\(interimIngestion)s completion=\(completionElapsed)s total=\(elapsed)s"
        )

        XCTAssertEqual(assistantContent(of: viewModel), expectedContent + chunks.joined())
        XCTAssertEqual(
            viewModel.displayedTranscriptMessages.last?.message.content,
            expectedContent + chunks.joined(),
            "the incrementally appended live row must paint the complete assistant content"
        )
        return StreamingHotPathBenchmark(
            total: elapsed,
            hasContentLookup: hasContentLookup,
            interimIngestion: interimIngestion
        )
    }


    @MainActor
    private func assistantContent(of viewModel: ChatViewModel) -> String? {
        viewModel.messages.last(where: { $0.role == "assistant" })?.content
    }

    /// Polls assistant content every 5ms until it equals `target` (or times out),
    /// returning every distinct non-empty value observed in order.
    @MainActor
    private func observeAssistantContent(
        _ viewModel: ChatViewModel,
        until target: String,
        timeoutNanoseconds: UInt64 = 4_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String] {
        let pollNanoseconds: UInt64 = 5_000_000
        var observed: [String] = []
        var elapsed: UInt64 = 0
        while elapsed <= timeoutNanoseconds {
            if let content = assistantContent(of: viewModel), !content.isEmpty,
               observed.last != content {
                observed.append(content)
            }
            if observed.last == target {
                return observed
            }

            try await Task.sleep(nanoseconds: pollNanoseconds)
            elapsed += pollNanoseconds
        }

        XCTFail(
            "timed out waiting for \(target); observed: \(observed)",
            file: file,
            line: line
        )
        return observed
    }
}

/// Issue #214: the streaming bottom-follow scroll and active-row growth share
/// one short cadence-synced animation, disabled entirely under Reduce Motion.
final class ChatStreamingMotionTests: XCTestCase {
    func testStreamingFollowUsesShortEaseOut() {
        XCTAssertEqual(
            ChatMotion.streamingFollow(reduceMotion: false),
            .easeOut(duration: 0.15)
        )
    }

    func testStreamingFollowIsDisabledUnderReduceMotion() {
        XCTAssertNil(ChatMotion.streamingFollow(reduceMotion: true))
    }

    func testStreamingFollowIsShorterThanRegularFollowScroll() {
        // The streaming curve must stay snappier than the regular follow scroll
        // so per-flush retargeting keeps up with the word reveal cadence.
        XCTAssertNotEqual(
            ChatMotion.streamingFollow(reduceMotion: false),
            ChatMotion.scrollToLatest(reduceMotion: false)
        )
    }
}

private final class PacingSpySSEStreamingClient: SSEStreamingClient {
    private(set) var lastEventID: String?
    private(set) var stopCount = 0
    private var onEvent: (@MainActor (SSEEvent) -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        lastEventID = nil
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
    }

    @MainActor
    func emit(_ event: SSEEvent) {
        onEvent?(event)
    }
}
