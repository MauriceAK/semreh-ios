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
    func testNativeAuthPromptSurvivesStreamFinishForLocalInput() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )
        let didStart = viewModel.seedLegacyResponseForTesting("Hold the native auth request open")
        XCTAssertTrue(didStart)
        let component = try XCTUnwrap(
            try? JSONDecoder().decode(
                NativeAuthWireComponent.self,
                from: Data(
                    """
                    {"type":"semreh.native-component.v1","issued_by":"browser","immutable":true,"context_id":"ctx_1234567890","browser_session_id":"bs_1234567890","component_id":"cmp_1234567890","field":"fld_email_12345678","action_handle":"act_fill_12345678","kind":"identifier","label":"Email","provider_origin":"https://example.com","path":"/login","runtime_public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","key_id":"rt_1234567890","expires_at":"2099-01-01T00:00:00Z","binding":{"issued_by":"browser","immutable":true,"tab_handle":"tab_12345678","frame_handle":"frame_12345678","document_generation":"doc_12345678","visibility":"visible","editability":"editable","match_count":1,"target_ref":{"issued_by":"browser","immutable":true,"ref_id":"ref_email_12345678","strategy":"css","selector":"input[type=email]"}}}
                    """.utf8
                )
            )
        )

        viewModel.streamCoordinatorApplyNativeAuthComponent(component)
        XCTAssertNotNil(viewModel.nativeAuthPrompt)

        streamClient.emit(.done(DoneStreamEvent()))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertNotNil(
            viewModel.nativeAuthPrompt,
            "an active native-auth prompt must remain available after the model stream ends"
        )
        XCTAssertEqual(
            viewModel.nativeAuthPrompt?.streamID,
            "stream-123",
            "the prompt must retain the browser stream owner after the SSE connection ends"
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/native-auth/cancel")
            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["session_id"] as? String, "session-abc")
            XCTAssertEqual(body["stream_id"] as? String, "stream-123")
            return apiTestJSONResponse(
                #"{"ok":true,"state":"cancelled","code":"cancelled","stage":"cancel","retryable":false,"requires_remint":false}"#,
                for: request
            )
        }
        let didCancel = await viewModel.cancelNativeAuth()
        XCTAssertTrue(didCancel)
    }

    @MainActor
    func testNativeAuthConflictingDuplicateFailsClosedAfterIdempotentDuplicate() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )
        let didStart = viewModel.seedLegacyResponseForTesting("Open a native auth prompt")
        XCTAssertTrue(didStart)

        let original = try makeNativeAuthComponent()
        viewModel.streamCoordinatorApplyNativeAuthComponent(original)
        viewModel.streamCoordinatorApplyNativeAuthComponent(original)
        XCTAssertEqual(viewModel.nativeAuthPrompt?.components, [original])

        let conflictingDuplicate = try makeNativeAuthComponent(label: "Changed label")
        viewModel.streamCoordinatorApplyNativeAuthComponent(conflictingDuplicate)

        XCTAssertNil(viewModel.nativeAuthPrompt)
        XCTAssertNotNil(viewModel.nativeAuthErrorMessage)
    }

    @MainActor
    func testNativeAuthMixedMetadataAndConflictingContextFailClosed() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )
        let didStartMixedMetadataStream = viewModel.seedLegacyResponseForTesting("Open a native auth prompt")
        XCTAssertTrue(didStartMixedMetadataStream)
        let runtimeKey = nativeAuthRuntimePublicKey()
        let original = try makeNativeAuthComponent(runtimePublicKey: runtimeKey)
        viewModel.streamCoordinatorApplyNativeAuthComponent(original)

        let mixedMetadata = try makeNativeAuthComponent(
            browserSessionID: "bs_other_123456",
            componentID: "cmp_second_123456",
            field: "fld_second_123456",
            actionHandle: "act_second_123456",
            runtimePublicKey: runtimeKey
        )
        viewModel.streamCoordinatorApplyNativeAuthComponent(mixedMetadata)
        XCTAssertNil(viewModel.nativeAuthPrompt)

        let conflictingContext = try makeNativeAuthComponent(
            contextID: "ctx_other_123456",
            componentID: "cmp_other_123456",
            runtimePublicKey: runtimeKey
        )
        viewModel.streamCoordinatorApplyNativeAuthComponent(conflictingContext)
        XCTAssertNil(viewModel.nativeAuthPrompt)
        XCTAssertNotNil(viewModel.nativeAuthErrorMessage)
    }

    @MainActor
    func testNativeAuthOutOfOrderStateAndTerminalReplayCannotResurrectPrompt() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )
        let didStartOutOfOrderStream = viewModel.seedLegacyResponseForTesting("Open a native auth prompt")
        XCTAssertTrue(didStartOutOfOrderStream)
        let component = try makeNativeAuthComponent()
        viewModel.streamCoordinatorApplyNativeAuthComponent(component)

        let awaiting = try makeNativeAuthState(status: "awaiting_browser")
        viewModel.streamCoordinatorApplyNativeAuthState(awaiting)
        viewModel.streamCoordinatorApplyNativeAuthState(try makeNativeAuthState(status: "focused"))
        XCTAssertEqual(viewModel.nativeAuthPrompt?.state, awaiting)

        viewModel.streamCoordinatorApplyNativeAuthState(try makeNativeAuthState(status: "completed"))
        XCTAssertNil(viewModel.nativeAuthPrompt)
        viewModel.streamCoordinatorApplyNativeAuthComponent(component)
        viewModel.streamCoordinatorApplyNativeAuthState(awaiting)
        XCTAssertNil(viewModel.nativeAuthPrompt)
    }

    @MainActor
    func testNativeAuthAmbiguousRetryReusesEnvelopeAndStaleSuccessCannotReviveState() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )
        let didStartRetryStream = viewModel.seedLegacyResponseForTesting("Open a native auth prompt")
        XCTAssertTrue(didStartRetryStream)
        let runtimeKey = nativeAuthRuntimePublicKey()
        let input = try makeNativeAuthComponent(runtimePublicKey: runtimeKey)
        let submit = try makeNativeAuthComponent(
            componentID: "cmp_submit_123456",
            field: "fld_submit_123456",
            actionHandle: "act_submit_123456",
            kind: "submit",
            label: "Continue",
            runtimePublicKey: runtimeKey
        )
        viewModel.streamCoordinatorApplyNativeAuthComponent(input)
        viewModel.streamCoordinatorApplyNativeAuthComponent(submit)

        var envelopes: [[String: Any]] = []
        var attempt = 0
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            envelopes.append(try XCTUnwrap(body["envelope"] as? [String: Any]))
            attempt += 1
            if attempt == 1 { throw URLError(.timedOut) }
            Thread.sleep(forTimeInterval: 0.12)
            return apiTestJSONResponse(
                #"{"ok":true,"state":"submitted","code":"submitted","stage":"complete","retryable":false,"requires_remint":false}"#,
                for: request
            )
        }

        let initialSubmitSucceeded = await viewModel.submitNativeAuth(
            values: [input.field: "synthetic-value"],
            component: submit,
            actionHandle: submit.actionHandle
        )
        XCTAssertFalse(initialSubmitSucceeded)
        XCTAssertTrue(viewModel.nativeAuthCanRetrySubmission)

        let retryTask = Task { @MainActor in
            await viewModel.submitNativeAuth(
                values: [:],
                component: submit,
                actionHandle: submit.actionHandle
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        viewModel.streamCoordinatorApplyNativeAuthState(
            try makeNativeAuthState(
                componentID: submit.componentID,
                actionHandle: submit.actionHandle,
                kind: "submit",
                status: "completed"
            )
        )
        let retrySucceeded = await retryTask.value
        XCTAssertFalse(retrySucceeded)
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(envelopes[0]["envelope_id"] as? String, envelopes[1]["envelope_id"] as? String)
        XCTAssertEqual(envelopes[0]["ciphertext"] as? String, envelopes[1]["ciphertext"] as? String)
        XCTAssertNil(viewModel.nativeAuthPrompt)
        XCTAssertFalse(viewModel.nativeAuthCanRetrySubmission)
    }

    #if DEBUG
    @MainActor
    func testNativeAuthE2EAutoSubmitUsesProductionEncryptedRouteOnceAndClearsState() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let server = try XCTUnwrap(URL(string: "http://127.0.0.1:8787"))
        let forbiddenProbe = UUID().uuidString
        let controller = try XCTUnwrap(
            NativeAuthE2EAutoSubmitController.resolve(
                arguments: [
                    NativeAuthE2EAutoSubmitController.launchFlag,
                    "--ignored-e2e-input",
                    forbiddenProbe
                ],
                serverURL: server
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id":"session-abc","title":"E2E"}"#.utf8)
        )
        let viewModel = ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient()
        )
        viewModel.setNativeAuthE2EAutoSubmitControllerForTesting(controller)
        let submitted = expectation(description: "production native-auth submit route called")
        var submitRequestCount = 0
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-123"}"#,
                    for: request
                )
            case "/api/native-auth/submit":
                submitRequestCount += 1
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Semreh-Client"), "native-auth-v1")
                let bodyData = try XCTUnwrap(apiTestBodyData(from: request))
                XCTAssertFalse(String(decoding: bodyData, as: UTF8.self).contains(forbiddenProbe))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                XCTAssertEqual(Set(body.keys), Set(["session_id", "stream_id", "envelope"]))
                let envelope = try XCTUnwrap(body["envelope"] as? [String: Any])
                XCTAssertEqual(
                    Set(envelope.keys),
                    Set([
                        "type", "issued_by", "immutable", "context_id", "browser_session_id",
                        "envelope_id", "provider_origin", "path", "cipher_suite", "key_id",
                        "client_public_key", "nonce", "ciphertext", "tag", "journal_policy", "expires_at"
                    ])
                )
                XCTAssertEqual(envelope["journal_policy"] as? String, "never")
                submitted.fulfill()
                return apiTestJSONResponse(
                    #"{"ok":true,"state":"submitted","code":"submitted","stage":"complete","retryable":false,"requires_remint":false}"#,
                    for: request
                )
            default:
                return apiTestJSONResponse(
                    #"{"session":{"session_id":"session-abc","title":"E2E","messages":[]}}"#,
                    for: request
                )
            }
        }

        let didStartFixtureStream = viewModel.seedLegacyResponseForTesting("Open the fixture prompt")
        XCTAssertTrue(didStartFixtureStream)
        let runtimeKey = nativeAuthRuntimePublicKey()
        let input = try makeNativeAuthComponent(
            providerOrigin: "https://127.0.0.1:9443",
            runtimePublicKey: runtimeKey
        )
        let submit = try makeNativeAuthComponent(
            componentID: "cmp_submit_123456",
            field: "fld_submit_123456",
            actionHandle: "act_submit_123456",
            kind: "submit",
            label: "Continue",
            providerOrigin: "https://127.0.0.1:9443",
            runtimePublicKey: runtimeKey
        )
        // SSE callbacks may be scheduled onto MainActor out of wire order. The
        // available state must be held until its exact components arrive.
        viewModel.streamCoordinatorApplyNativeAuthState(
            try makeNativeAuthState(
                componentID: submit.componentID,
                actionHandle: submit.actionHandle,
                kind: "submit",
                providerOrigin: "https://127.0.0.1:9443",
                status: "available"
            )
        )
        viewModel.streamCoordinatorApplyNativeAuthComponent(input)
        viewModel.streamCoordinatorApplyNativeAuthComponent(submit)

        await fulfillment(of: [submitted], timeout: 2)
        for _ in 0..<100 where !controller.isSpent {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(submitRequestCount, 1)
        XCTAssertNil(viewModel.nativeAuthPrompt)
        XCTAssertFalse(viewModel.nativeAuthCanRetrySubmission)
        XCTAssertFalse(controller.hasPendingValues)
        XCTAssertTrue(controller.isSpent)
        XCTAssertEqual(controller.attemptCount, 1)

        viewModel.streamCoordinatorApplyNativeAuthComponent(input)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(submitRequestCount, 1)
    }

    @MainActor
    func testNativeAuthE2EAutoSubmitTransportFailureTerminalizesWithoutRetryState() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let server = try XCTUnwrap(URL(string: "http://127.0.0.1:8787"))
        let controller = try XCTUnwrap(
            NativeAuthE2EAutoSubmitController.resolve(
                arguments: [NativeAuthE2EAutoSubmitController.launchFlag],
                serverURL: server
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id":"session-abc","title":"E2E failure"}"#.utf8)
        )
        let viewModel = ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient()
        )
        viewModel.setNativeAuthE2EAutoSubmitControllerForTesting(controller)
        let submitAttempted = expectation(description: "encrypted native-auth submit attempted")
        var submitRequestCount = 0
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-123"}"#,
                    for: request
                )
            case "/api/native-auth/submit":
                submitRequestCount += 1
                let bodyData = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                XCTAssertEqual(Set(body.keys), Set(["session_id", "stream_id", "envelope"]))
                XCTAssertNotNil(body["envelope"] as? [String: Any])
                submitAttempted.fulfill()
                throw URLError(.timedOut)
            default:
                return apiTestJSONResponse(
                    #"{"session":{"session_id":"session-abc","title":"E2E failure","messages":[]}}"#,
                    for: request
                )
            }
        }

        let didStartFixtureStream = viewModel.seedLegacyResponseForTesting("Open the fixture prompt")
        XCTAssertTrue(didStartFixtureStream)
        let runtimeKey = nativeAuthRuntimePublicKey()
        let input = try makeNativeAuthComponent(
            providerOrigin: "https://127.0.0.1:9443",
            runtimePublicKey: runtimeKey
        )
        let submit = try makeNativeAuthComponent(
            componentID: "cmp_submit_failure_123456",
            field: "fld_submit_failure_123456",
            actionHandle: "act_submit_failure_123456",
            kind: "submit",
            label: "Continue",
            providerOrigin: "https://127.0.0.1:9443",
            runtimePublicKey: runtimeKey
        )
        viewModel.streamCoordinatorApplyNativeAuthComponent(input)
        viewModel.streamCoordinatorApplyNativeAuthComponent(submit)
        viewModel.streamCoordinatorApplyNativeAuthState(
            try makeNativeAuthState(
                componentID: submit.componentID,
                actionHandle: submit.actionHandle,
                kind: "submit",
                providerOrigin: "https://127.0.0.1:9443",
                status: "available"
            )
        )

        await fulfillment(of: [submitAttempted], timeout: 2)
        for _ in 0..<100 where viewModel.nativeAuthPrompt != nil {
            await Task.yield()
        }
        XCTAssertEqual(submitRequestCount, 1)
        XCTAssertNil(viewModel.nativeAuthPrompt)
        XCTAssertFalse(viewModel.nativeAuthCanRetrySubmission)
        XCTAssertFalse(viewModel.hasPendingNativeAuthSubmissionForTesting)
        XCTAssertFalse(controller.hasPendingValues)
        XCTAssertTrue(controller.isSpent)

        viewModel.streamCoordinatorApplyNativeAuthComponent(input)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(submitRequestCount, 1)
    }
    #endif

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
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient(),
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

    private func makeNativeAuthComponent(
        contextID: String = "ctx_1234567890",
        browserSessionID: String = "bs_1234567890",
        componentID: String = "cmp_1234567890",
        field: String = "fld_email_12345678",
        actionHandle: String = "act_fill_12345678",
        kind: String = "identifier",
        label: String = "Email",
        providerOrigin: String = "https://example.com",
        path: String = "/login",
        runtimePublicKey: String? = nil,
        keyID: String = "rt_1234567890",
        expiresAt: String = "2099-01-01T00:00:00Z",
        tabHandle: String = "tab_12345678",
        frameHandle: String = "frame_12345678",
        documentGeneration: String = "doc_12345678"
    ) throws -> NativeAuthWireComponent {
        let publicKey = runtimePublicKey ?? Curve25519.KeyAgreement.PrivateKey()
            .publicKey.rawRepresentation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let object: [String: Any] = [
            "type": "semreh.native-component.v1",
            "issued_by": "browser",
            "immutable": true,
            "context_id": contextID,
            "browser_session_id": browserSessionID,
            "component_id": componentID,
            "field": field,
            "action_handle": actionHandle,
            "kind": kind,
            "label": label,
            "provider_origin": providerOrigin,
            "path": path,
            "runtime_public_key": publicKey,
            "key_id": keyID,
            "expires_at": expiresAt,
            "binding": [
                "issued_by": "browser",
                "immutable": true,
                "tab_handle": tabHandle,
                "frame_handle": frameHandle,
                "document_generation": documentGeneration,
                "visibility": "visible",
                "editability": kind == "submit" ? "not_editable" : "editable",
                "match_count": 1,
                "target_ref": [
                    "issued_by": "browser",
                    "immutable": true,
                    "ref_id": "ref_12345678",
                    "strategy": "css",
                    "selector": kind == "submit" ? "button[type=submit]" : "input[type=email]"
                ]
            ]
        ]
        return try JSONDecoder().decode(
            NativeAuthWireComponent.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func nativeAuthRuntimePublicKey() -> String {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeNativeAuthState(
        contextID: String = "ctx_1234567890",
        browserSessionID: String = "bs_1234567890",
        componentID: String = "cmp_1234567890",
        actionHandle: String = "act_fill_12345678",
        kind: String = "identifier",
        providerOrigin: String = "https://example.com",
        path: String = "/login",
        status: String
    ) throws -> NativeAuthWireState {
        let object: [String: Any] = [
            "type": "semreh.native-component-state.v1",
            "issued_by": "browser",
            "immutable": true,
            "context_id": contextID,
            "browser_session_id": browserSessionID,
            "component_id": componentID,
            "action_handle": actionHandle,
            "kind": kind,
            "provider_origin": providerOrigin,
            "path": path,
            "status": status
        ]
        return try JSONDecoder().decode(
            NativeAuthWireState.self,
            from: JSONSerialization.data(withJSONObject: object)
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
