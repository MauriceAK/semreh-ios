import SwiftUI
import XCTest
import CryptoKit
@testable import HermesMobile

/// Exercises lossless adaptive batches, injectable pacing, deadline catch-up and
/// cancellation ownership without contacting a gateway.
final class ChatViewModelStreamingPaceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testResponsivePresentationCoalescesReceivedBurstWithoutWordReplayAndRearms() async throws {
        let stream = DirectPacingEventFixture()
        let viewModel = try makeViewModel(
            streamClient: stream,
            wordCadenceNanoseconds: 48_000_000,
            maxLagNanoseconds: 1_000_000_000
        )
        viewModel.setResponsiveStreamingPresentation(true)
        var now: UInt64 = 0
        viewModel.streamingClockForTesting = { now }
        let gate = StreamingTaskSuspensionGate()
        viewModel.streamingTaskWaitForTesting = { owner, delay in
            await gate.suspend(owner: owner, delay: delay)
        }
        defer {
            viewModel.setTranscriptPresentationActive(false)
            gate.finish()
        }
        stream.startResponse(on: viewModel)
        let burst = (0..<300).map { "word\($0) " }.joined()
        stream.emit(.token(burst))
        let frame = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: frame.owner)], timeout: 2)
        XCTAssertEqual(gate.delays[frame.owner], 32_000_000)
        XCTAssertEqual(assistantContent(of: viewModel), "")

        now = 8_000_000
        stream.emit(.token("cafe"))
        stream.emit(.token("\u{301}\n"))
        XCTAssertEqual(viewModel.scheduledStreamingContentFlushForTesting?.owner, frame.owner)
        now = 32_000_000
        try gate.release(frame.owner)
        await frame.task.value
        let expected = burst + "cafe\u{301}\n"
        XCTAssertEqual(Array((assistantContent(of: viewModel) ?? "").utf8), Array(expected.utf8))
        XCTAssertNil(viewModel.scheduledStreamingContentFlushForTesting, "No artificial word backlog")

        now = 40_000_000
        stream.emit(.token("next burst"))
        let next = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: next.owner)], timeout: 2)
        XCTAssertEqual(gate.delays[next.owner], 32_000_000, "An emptied buffer begins a new coalescing window")
        // An unavailable main actor cannot meet a wall-clock deadline. Its first
        // resumed tick must catch up completely instead of adding further lag.
        now = 200_000_000
        try gate.release(next.owner)
        await next.task.value
        XCTAssertEqual(assistantContent(of: viewModel), expected + "next burst")
        XCTAssertNil(viewModel.scheduledStreamingContentFlushForTesting)
    }

    @MainActor
    func testPacedDeadlineSurvivesPartialDrainAndNewArrivals() async throws {
        let stream = DirectPacingEventFixture()
        let viewModel = try makeViewModel(
            streamClient: stream,
            wordCadenceNanoseconds: 100_000_000,
            maxLagNanoseconds: 300_000_000
        )
        var now: UInt64 = 0
        viewModel.streamingClockForTesting = { now }
        let gate = StreamingTaskSuspensionGate()
        viewModel.streamingTaskWaitForTesting = { owner, delay in
            await gate.suspend(owner: owner, delay: delay)
        }
        defer {
            viewModel.setTranscriptPresentationActive(false)
            gate.finish()
        }
        stream.startResponse(on: viewModel)
        let initial = String(repeating: "old ", count: 60)
        stream.emit(.token(initial))
        let first = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: first.owner)], timeout: 2)
        now = 1_000_000
        try gate.release(first.owner)
        await first.task.value
        XCTAssertFalse((assistantContent(of: viewModel) ?? "").isEmpty)
        XCTAssertNotEqual(assistantContent(of: viewModel), initial)

        let continuation = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: continuation.owner)], timeout: 2)
        now = 250_000_000
        let fresh = String(repeating: "new ", count: 60)
        stream.emit(.token(fresh))
        try gate.release(continuation.owner)
        await continuation.task.value
        XCTAssertEqual(assistantContent(of: viewModel), initial + fresh,
                       "Fresh arrivals must not restart the older pending text's 300 ms budget")
        XCTAssertNil(viewModel.scheduledStreamingContentFlushForTesting)
    }

    @MainActor
    func testLongResponsiveReplyPrioritizesIndependentInteractionsWithoutExtendingDeadline() async throws {
        let stream = DirectPacingEventFixture()
        let vm = try makeViewModel(streamClient: stream, wordCadenceNanoseconds: 48_000_000,
                                   maxLagNanoseconds: 1_000_000_000)
        vm.setResponsiveStreamingPresentation(true)
        var now: UInt64 = 0
        vm.streamingClockForTesting = { now }
        let gate = StreamingTaskSuspensionGate()
        vm.streamingTaskWaitForTesting = { owner, delay in await gate.suspend(owner: owner, delay: delay) }
        defer { vm.setTranscriptPresentationActive(false); gate.finish() }
        stream.startResponse(on: vm)
        let source = String(repeating: "Long unbroken paragraph café 👩🏽‍💻 with whitespace. ", count: 1_600)
        stream.emit(.token(source))
        let ordinary = try XCTUnwrap(vm.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: ordinary.owner)], timeout: 2)
        XCTAssertEqual(gate.delays[ordinary.owner], 100_000_000)
        XCTAssertEqual(assistantContent(of: vm), "", "Network bytes are buffered without whole-row publication per arrival")

        now = 20_000_000
        vm.setStreamingInteractionPriority(true)
        let reader = try XCTUnwrap(vm.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: reader.owner)], timeout: 2)
        XCTAssertTrue(ordinary.task.isCancelled)
        XCTAssertEqual(gate.delays[reader.owner], 130_000_000, "Original150ms deadline still owns the pending bytes")
        vm.setComposerInteractionActive(true)
        vm.setStreamingInteractionPriority(false)
        XCTAssertEqual(vm.scheduledStreamingContentFlushForTesting?.owner, reader.owner,
                       "Ending a drag must not erase focused composer's independent priority")

        now = 145_000_000
        stream.emit(.token("\r\ncafe"))
        stream.emit(.token("\u{301} 🧑‍"))
        stream.emit(.token("💻 end"))
        vm.setComposerInteractionActive(false)
        let settle = try XCTUnwrap(vm.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: settle.owner)], timeout: 2)
        XCTAssertEqual(gate.delays[settle.owner], 5_000_000)
        try gate.release(ordinary.owner)
        await ordinary.task.value
        try gate.release(reader.owner)
        await reader.task.value
        XCTAssertEqual(vm.scheduledStreamingContentFlushForTesting?.owner, settle.owner)
        XCTAssertEqual(assistantContent(of: vm), "")
        now = 150_000_000
        try gate.release(settle.owner)
        await settle.task.value
        let expected = source + "\r\ncafe\u{301} 🧑‍💻 end"
        XCTAssertEqual(Array((assistantContent(of: vm) ?? "").utf8), Array(expected.utf8))
        XCTAssertNil(vm.scheduledStreamingContentFlushForTesting, "A coalesced tick shows all received text; no artificial replay queue")

        stream.emit(.token(" final pending bytes"))
        let final = try XCTUnwrap(vm.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: final.owner)], timeout: 2)
        stream.emit(.cancelled)
        XCTAssertEqual(assistantContent(of: vm), expected + " final pending bytes")
        XCTAssertNil(vm.streamingActivityStatus)
        XCTAssertTrue(final.task.isCancelled)
        try gate.release(final.owner)
        await final.task.value
        XCTAssertEqual(assistantContent(of: vm), expected + " final pending bytes")
        XCTAssertNil(vm.scheduledStreamingContentFlushForTesting)
    }

    @MainActor
    func testGatewayStatusNeverBecomesReasoningAndInterimCommentaryStaysVisible() throws {
        let stream = DirectPacingEventFixture()
        let vm = try makeStalledDrainViewModel(streamClient: stream)
        vm.setResponsiveStreamingPresentation(true)
        stream.startResponse(on: vm)
        let transcriptRevisionBeforeStatus = vm.transcriptRenderRevision
        stream.emit(.thinking("Looking at the workspace"))
        stream.emit(.thinking("Waiting for the provider"))
        XCTAssertEqual(vm.streamingActivityStatus, "Waiting for the provider")
        XCTAssertTrue(vm.messages.isEmpty, "Spinner status must not create an empty assistant/reasoning row")
        XCTAssertTrue(vm.liveReasoningText.isEmpty)
        XCTAssertNil(vm.scheduledStreamingContentFlushForTesting)
        XCTAssertEqual(vm.transcriptRenderRevision, transcriptRevisionBeforeStatus,
                       "Changing an unused spinner label must not invalidate the transcript")

        stream.emit(.reasoning("Provider plan.\n"))
        let commentary = "  Got it, looking into that.\n"
        stream.emit(.token(commentary))
        stream.emit(.interimAssistant(text: commentary, alreadyStreamed: true))
        XCTAssertEqual(vm.messages.filter { $0.role == "assistant" }.compactMap(\.content), [commentary])
        XCTAssertEqual(vm.liveReasoningText, "Provider plan.\n")
        XCTAssertNotNil(vm.streamingActivityStatus)
        stream.emit(.thinking(String(repeating: "status ", count: 1_000)))
        XCTAssertLessThanOrEqual(vm.streamingActivityStatus?.count ?? 0, 160)
        XCTAssertEqual(vm.liveReasoningText, "Provider plan.\n")
        stream.emit(.reasoning("Provider conclusion."))
        stream.emit(.token("Actual final response"))
        stream.emit(.done)
        XCTAssertEqual(vm.messages.filter { $0.role == "assistant" }.compactMap(\.content),
                       [commentary, "Actual final response"])
        XCTAssertTrue(vm.liveReasoningText.isEmpty)
        XCTAssertEqual(vm.messages.compactMap(\.reasoning), ["Provider plan.\nProvider conclusion."])
        XCTAssertEqual(vm.displayedReasoningGroups.map(\.text), ["Provider plan.\nProvider conclusion."])
        XCTAssertNil(vm.streamingActivityStatus)
        XCTAssertNil(vm.scheduledStreamingContentFlushForTesting)

        // An unstreamed/recovered interim also remains a visible assistant
        // message with its original formatting, never a thought disclosure.
        vm.clearTranscript()
        stream.startResponse(on: vm)
        stream.emit(.thinking("Waiting"))
        stream.emit(.interimAssistant(text: commentary, alreadyStreamed: false))
        stream.emit(.token("Stopped partial response"))
        stream.emit(.cancelled)
        XCTAssertEqual(vm.messages.filter { $0.role == "assistant" }.compactMap(\.content),
                       [commentary, "Stopped partial response"])
        XCTAssertNil(vm.streamingActivityStatus)
        XCTAssertFalse(vm.liveReasoningText.contains("Waiting"))
    }

    @MainActor
    func testReasoningOnlyBatchKeepsOriginalDeadlineAndStatusDoesNotRescheduleIt() async throws {
        let stream = DirectPacingEventFixture()
        let vm = try makeStalledDrainViewModel(streamClient: stream)
        vm.setResponsiveStreamingPresentation(true)
        var now: UInt64 = 0
        vm.streamingClockForTesting = { now }
        let gate = StreamingTaskSuspensionGate()
        vm.streamingTaskWaitForTesting = { owner, delay in await gate.suspend(owner: owner, delay: delay) }
        defer { vm.setTranscriptPresentationActive(false); gate.finish() }
        stream.startResponse(on: vm)
        stream.emit(.reasoning("provider reasoning"))
        let initial = try XCTUnwrap(vm.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: initial.owner)], timeout: 2)
        now = 145_000_000
        stream.emit(.thinking("Working"))
        XCTAssertEqual(vm.scheduledStreamingContentFlushForTesting?.owner, initial.owner)
        vm.setStreamingInteractionPriority(true)
        let replacement = try XCTUnwrap(vm.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: replacement.owner)], timeout: 2)
        XCTAssertEqual(gate.delays[replacement.owner], 5_000_000)
        try gate.release(initial.owner)
        await initial.task.value
        XCTAssertTrue(vm.liveReasoningText.isEmpty)
        now = 150_000_000
        try gate.release(replacement.owner)
        await replacement.task.value
        XCTAssertEqual(vm.liveReasoningText, "provider reasoning")
        XCTAssertNil(vm.scheduledStreamingContentFlushForTesting)
    }

    func testPresentationSleepStopsAtOldestPendingDeadline() {
        XCTAssertEqual(StreamingWordDrain.nextDelay(
            requestedNanoseconds: 100_000_000,
            oldestPendingAgeNanoseconds: 290_000_000,
            maxLagNanoseconds: 300_000_000
        ), 10_000_000)
        XCTAssertEqual(StreamingWordDrain.nextDelay(
            requestedNanoseconds: 100_000_000,
            oldestPendingAgeNanoseconds: 310_000_000,
            maxLagNanoseconds: 300_000_000
        ), 0)
        XCTAssertEqual(StreamingWordDrain.drainQuota(
            backlogUnitCount: 1_000,
            cadenceNanoseconds: 16_000_000,
            maxLagNanoseconds: 300_000_000,
            oldestPendingAgeNanoseconds: 300_000_000
        ), 1_000)
    }

    @MainActor
    func testCancelledContentSleeperCannotClearReplacementOrForkCadenceChain() async throws {
        let stream = DirectPacingEventFixture()
        let viewModel = try makeStalledDrainViewModel(streamClient: stream)
        let gate = StreamingTaskSuspensionGate()
        viewModel.streamingTaskWaitForTesting = { owner, delay in
            await gate.suspend(owner: owner, delay: delay)
        }
        defer {
            viewModel.setTranscriptPresentationActive(false)
            gate.finish()
        }
        stream.startResponse(on: viewModel)
        stream.emit(.token("prefix\r\n"))
        let stale = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: stale.owner)], timeout: 2)

        // Drain the boundary synchronously and install B before cancelled A
        // resumes. The gate deliberately does not resume on cancellation.
        viewModel.flushPendingStreamingContent()
        XCTAssertTrue(stale.task.isCancelled)
        XCTAssertEqual(assistantContent(of: viewModel), "prefix\r\n")
        let chunks = ["cafe", "\u{301}  beta\n", "👩‍", "👩‍👧‍👦 end"]
        stream.emit(.token(chunks[0]))
        let replacement = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        XCTAssertNotEqual(stale.owner, replacement.owner)
        await fulfillment(of: [gate.arrival(for: replacement.owner)], timeout: 2)
        for chunk in chunks.dropFirst() { stream.emit(.token(chunk)) }
        stream.emit(.reasoning("thought\t"))
        try gate.release(stale.owner)
        await stale.task.value

        // Resuming cancelled A must not erase the live replacement B.
        XCTAssertEqual(viewModel.scheduledStreamingContentFlushForTesting?.owner, replacement.owner)
        XCTAssertEqual(assistantContent(of: viewModel), "prefix\r\n")
        XCTAssertEqual(viewModel.liveReasoningText, "")
        XCTAssertEqual(viewModel.streamProgressHapticTrigger, 0)
        stream.emit(.token("  tail"))
        XCTAssertEqual(viewModel.scheduledStreamingContentFlushForTesting?.owner, replacement.owner)
        XCTAssertEqual(gate.suspendedOwners, Set([replacement.owner]), "No orphaned B plus a new C")

        try gate.release(replacement.owner)
        await replacement.task.value
        XCTAssertEqual(assistantContent(of: viewModel), "prefix\r\ncafe\u{301}  ")
        XCTAssertEqual(viewModel.liveReasoningText, "thought\t")
        let successor = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        XCTAssertNotEqual(successor.owner, replacement.owner)
        await fulfillment(of: [gate.arrival(for: successor.owner)], timeout: 2)
        XCTAssertEqual(gate.suspendedOwners, Set([successor.owner]))
        XCTAssertEqual(gate.delays[replacement.owner], 1_000_000)
        XCTAssertEqual(gate.delays[successor.owner], 60_000_000_000)
        stream.emit(.token("\tfinal"))
        XCTAssertEqual(viewModel.scheduledStreamingContentFlushForTesting?.owner, successor.owner)

        // A real terminal without replacement text must drain every byte now.
        stream.emit(.done)
        let expected = "prefix\r\n" + chunks.joined() + "  tail\tfinal"
        XCTAssertEqual(Array((assistantContent(of: viewModel) ?? "").utf8), Array(expected.utf8))
        XCTAssertNil(viewModel.scheduledStreamingContentFlushForTesting)
        XCTAssertTrue(successor.task.isCancelled)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
        let progressAtTerminal = viewModel.streamProgressHapticTrigger
        try gate.release(successor.owner)
        await successor.task.value
        XCTAssertEqual(assistantContent(of: viewModel), expected)
        XCTAssertEqual(viewModel.streamProgressHapticTrigger, progressAtTerminal)
        XCTAssertNil(viewModel.scheduledStreamingContentFlushForTesting)
        XCTAssertTrue(gate.suspendedOwners.isEmpty)
    }

    @MainActor
    func testCancelledContentSleeperRetainsOffscreenBacklogAndSuppressesReplayHaptics() async throws {
        let stream = DirectPacingEventFixture()
        let viewModel = try makeStalledDrainViewModel(streamClient: stream)
        let gate = StreamingTaskSuspensionGate()
        viewModel.streamingTaskWaitForTesting = { owner, delay in
            await gate.suspend(owner: owner, delay: delay)
        }
        defer {
            viewModel.setTranscriptPresentationActive(false)
            gate.finish()
        }
        stream.startResponse(on: viewModel)
        stream.emit(.token("  alpha beta\n"))
        let stale = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: stale.owner)], timeout: 2)
        viewModel.setTranscriptPresentationActive(false)
        stream.emit(.token("gamma\tdelta"))
        stream.emit(.reasoning("offscreen thought"))
        try gate.release(stale.owner)
        await stale.task.value
        XCTAssertEqual(assistantContent(of: viewModel), "")
        XCTAssertEqual(viewModel.liveReasoningText, "")
        XCTAssertNil(viewModel.scheduledStreamingContentFlushForTesting)
        XCTAssertTrue(gate.suspendedOwners.isEmpty)

        viewModel.setTranscriptPresentationActive(true)
        let reentry = try XCTUnwrap(viewModel.scheduledStreamingContentFlushForTesting)
        await fulfillment(of: [gate.arrival(for: reentry.owner)], timeout: 2)
        XCTAssertEqual(gate.delays[reentry.owner], 0)
        try gate.release(reentry.owner)
        await reentry.task.value
        XCTAssertEqual(assistantContent(of: viewModel), "  alpha beta\ngamma\tdelta")
        XCTAssertEqual(viewModel.liveReasoningText, "offscreen thought")

        let expected = "  alpha beta\ngamma\tdelta"
        XCTAssertEqual(Array((assistantContent(of: viewModel) ?? "").utf8), Array(expected.utf8))
        XCTAssertEqual(viewModel.streamProgressHapticTrigger, 0, "Do not replay backlog progress pulses")
        XCTAssertNil(viewModel.scheduledStreamingContentFlushForTesting)
        XCTAssertTrue(gate.suspendedOwners.isEmpty)
    }

    @MainActor
    func testCancelledScrollSleeperCannotClearReplacementOrPublishOffscreen() async throws {
        let stream = DirectPacingEventFixture()
        let viewModel = try makeStalledDrainViewModel(streamClient: stream)
        let gate = StreamingTaskSuspensionGate()
        viewModel.streamingTaskWaitForTesting = { owner, delay in
            await gate.suspend(owner: owner, delay: delay)
        }
        defer {
            viewModel.setTranscriptPresentationActive(false)
            gate.finish()
        }
        let originalTrigger = viewModel.streamingScrollTrigger
        viewModel.scheduleStreamingScrollTriggerForTesting()
        let stale = try XCTUnwrap(viewModel.scheduledStreamingScrollTriggerForTesting)
        await fulfillment(of: [gate.arrival(for: stale.owner)], timeout: 2)
        viewModel.setTranscriptPresentationActive(false)
        viewModel.setTranscriptPresentationActive(true)
        viewModel.scheduleStreamingScrollTriggerForTesting()
        let replacement = try XCTUnwrap(viewModel.scheduledStreamingScrollTriggerForTesting)
        await fulfillment(of: [gate.arrival(for: replacement.owner)], timeout: 2)
        XCTAssertTrue(stale.task.isCancelled)
        try gate.release(stale.owner)
        await stale.task.value
        XCTAssertEqual(viewModel.scheduledStreamingScrollTriggerForTesting?.owner, replacement.owner)
        XCTAssertEqual(viewModel.streamingScrollTrigger, originalTrigger)
        viewModel.scheduleStreamingScrollTriggerForTesting()
        XCTAssertEqual(viewModel.scheduledStreamingScrollTriggerForTesting?.owner, replacement.owner)
        XCTAssertEqual(gate.suspendedOwners, Set([replacement.owner]))
        try gate.release(replacement.owner)
        await replacement.task.value
        XCTAssertNil(viewModel.scheduledStreamingScrollTriggerForTesting)
        XCTAssertEqual(viewModel.streamingScrollTrigger, originalTrigger + 1)

        viewModel.scheduleStreamingScrollTriggerForTesting()
        let offscreen = try XCTUnwrap(viewModel.scheduledStreamingScrollTriggerForTesting)
        await fulfillment(of: [gate.arrival(for: offscreen.owner)], timeout: 2)
        viewModel.setTranscriptPresentationActive(false)
        viewModel.scheduleStreamingScrollTriggerForTesting()
        try gate.release(offscreen.owner)
        await offscreen.task.value
        XCTAssertEqual(viewModel.streamingScrollTrigger, originalTrigger + 1)
        XCTAssertNil(viewModel.scheduledStreamingScrollTriggerForTesting)
        XCTAssertTrue(gate.suspendedOwners.isEmpty)
    }

    @MainActor
    func testBufferedBurstRevealsWordByWordAtCadence() async throws {
        let streamClient = DirectPacingEventFixture()
        // 60s lag bound keeps the quota at one word per tick for this backlog.
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 200_000_000,
            maxLagNanoseconds: 60_000_000_000
        )

        streamClient.startResponse(on: viewModel)

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
        let streamClient = DirectPacingEventFixture()
        // Real-executor convergence smoke test. The deterministic clock test
        // above verifies the 300 ms policy deadline independently of scheduling.
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 100_000_000,
            maxLagNanoseconds: 300_000_000
        )

        streamClient.startResponse(on: viewModel)

        let words = (0..<60).map { "w\($0) " }
        for word in words {
            streamClient.emit(.token(word))
        }

        let target = words.joined()
        let observed = try await observeAssistantContent(viewModel, until: target)

        XCTAssertEqual(observed.last, target)
        // A late main-actor tick may correctly reveal everything at once.
        // Progressive batching is checked with a controlled clock above.
    }

    @MainActor
    func testDoneEventFlushesRemainingBufferImmediately() async throws {
        let streamClient = DirectPacingEventFixture()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        streamClient.startResponse(on: viewModel)

        streamClient.emit(.token("alpha beta gamma"))
        _ = try await observeAssistantContent(viewModel, until: "alpha ")
        XCTAssertEqual(assistantContent(of: viewModel), "alpha ")

        streamClient.emit(.done)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")

        // Nothing may trickle in after completion.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testCancelledEventFlushesRemainingBufferImmediately() async throws {
        let streamClient = DirectPacingEventFixture()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        streamClient.startResponse(on: viewModel)

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
        let streamClient = DirectPacingEventFixture()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )

        streamClient.startResponse(on: viewModel)

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
        let streamClient = DirectPacingEventFixture()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )

        streamClient.startResponse(on: viewModel)
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
    func testProgressPulseDoesNotReplayOffscreenBacklogOrAfterCancellation() async throws {
        let streamClient = DirectPacingEventFixture()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 20_000_000,
            maxLagNanoseconds: 100_000_000
        )
        streamClient.startResponse(on: viewModel)
        viewModel.setTranscriptPresentationActive(false)
        let backlog = String(repeating: "old ", count: 40)
        streamClient.emit(.token(backlog))
        viewModel.setTranscriptPresentationActive(true)
        _ = try await observeAssistantContent(viewModel, until: backlog)
        XCTAssertEqual(viewModel.streamProgressHapticTrigger, 0)

        // Fresh visible progress may pulse, at most once per interval.
        streamClient.emit(.token(String(repeating: "new ", count: 40)))
        _ = try await observeAssistantContent(viewModel, until: backlog + String(repeating: "new ", count: 40))
        XCTAssertLessThanOrEqual(viewModel.streamProgressHapticTrigger, 1)

        streamClient.emit(.cancelled)
        let afterCancel = viewModel.streamProgressHapticTrigger
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(viewModel.streamProgressHapticTrigger, afterCancel)
    }

    @MainActor
    func testSustainedVisibleStreamPublishesProgressPulse() async throws {
        let streamClient = DirectPacingEventFixture()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 20_000_000,
            // Keep a one-word quota: 100 words span roughly two seconds.
            // A lag bound equal to one cadence would drain the whole burst.
            maxLagNanoseconds: 60_000_000_000
        )
        streamClient.startResponse(on: viewModel)

        let sustainedProgress = (0..<100).map { "visible\($0) " }.joined()
        streamClient.emit(.token(sustainedProgress))
        _ = try await observeAssistantContent(viewModel, until: sustainedProgress)

        XCTAssertGreaterThan(
            viewModel.streamProgressHapticTrigger, 0,
            "the model must publish stream progress; this does not prove UIKit/compositor delivery"
        )
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
        let streamClient = DirectPacingEventFixture()
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

        streamClient.startResponse(on: viewModel)
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
        streamClient.emit(.interimAssistant(text: "late interim", alreadyStreamed: false))

        let expectedContent = "live\n\nlate interim"
        XCTAssertEqual(viewModel.messages.last?.content, expectedContent)
        XCTAssertEqual(viewModel.displayedTranscriptMessages.last?.message.content, expectedContent)
        XCTAssertEqual(
            viewModel.transcriptFullRecomputeCountForTesting,
            recomputesAfterPrepend,
            "sealing an interim after pagination must update the shifted live row incrementally"
        )
        XCTAssertNil(viewModel.streamingAssistantMessageID)
    }

    // MARK: - Helpers

    /// 60s cadence with a far larger lag bound keeps the quota at one word per
    /// tick: the first tick reveals one word, then the drain effectively stalls
    /// so completion-path flushes are observable.
    @MainActor
    private func makeStalledDrainViewModel(
        streamClient: DirectPacingEventFixture
    ) throws -> ChatViewModel {
        try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 60_000_000_000,
            maxLagNanoseconds: 3_600_000_000_000
        )
    }


    @MainActor
    private func makeViewModel(
        streamClient: DirectPacingEventFixture,
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
            streamingScrollCoalescingDelayNanoseconds: 1_000_000,
            streamingWordRevealCadenceNanoseconds: wordCadenceNanoseconds,
            streamingMaxRevealLagNanoseconds: maxLagNanoseconds,
            gatewayRuntimeProvider: { _ in throw DirectSessionError.invalidResponse }
        )
        streamClient.attach(viewModel)
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
        let streamClient = DirectPacingEventFixture()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 60_000_000_000,
            maxLagNanoseconds: 3_600_000_000_000,
            historyMessageCount: historyMessageCount
        )
        // Benchmark renderer state only; history is explicitly seeded above.
        let historicalContents = viewModel.messages.compactMap(\.content)
        streamClient.startResponse(on: viewModel)
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
        var expectedSegments: [String] = []
        let interimStartedAt = CFAbsoluteTimeGetCurrent()
        for index in 0..<400 {
            let interimText = "interim-\(index)"
            streamClient.emit(.interimAssistant(text: interimText, alreadyStreamed: false))
            expectedSegments.append(index == 0 ? "seed\n\n\(interimText)" : interimText)
        }
        let interimIngestion = CFAbsoluteTimeGetCurrent() - interimStartedAt

        XCTAssertEqual(
            viewModel.messages.compactMap(\.content),
            historicalContents + expectedSegments,
            "Sealed segments append without changing the seeded history."
        )
        XCTAssertEqual(viewModel.displayedTranscriptMessages.last?.message.content, expectedSegments.last)
        XCTAssertEqual(
            viewModel.transcriptFullRecomputeCountForTesting,
            recomputesBeforeBurst,
            "interim_assistant segment sealing must stay on the incremental transcript path"
        )

        let chunks = (0..<400).map { "t\($0) " }
        for chunk in chunks {
            streamClient.emit(.token(chunk))
        }
        let completionStartedAt = CFAbsoluteTimeGetCurrent()
        streamClient.emit(.done)
        let completionElapsed = CFAbsoluteTimeGetCurrent() - completionStartedAt
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        print(
            "SEMREH_HISTORY_PHASE rows=\(historyMessageCount) interim=\(interimIngestion)s completion=\(completionElapsed)s total=\(elapsed)s"
        )

        XCTAssertEqual(assistantContent(of: viewModel), chunks.joined())
        XCTAssertEqual(
            viewModel.displayedTranscriptMessages.last?.message.content,
            chunks.joined(),
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

@MainActor
private final class DirectPacingEventFixture {
    enum Event {
        case token(String)
        case thinking(String)
        case reasoning(String)
        case interimAssistant(text: String, alreadyStreamed: Bool)
        case done
        case cancelled
    }

    private(set) var stopCount = 0
    private weak var viewModel: ChatViewModel?
    private var sequence = 0

    func attach(_ viewModel: ChatViewModel) { self.viewModel = viewModel }

    func startResponse(on viewModel: ChatViewModel) {
        attach(viewModel)
        emit(type: "message.start")
    }

    func emit(_ event: Event) {
        switch event {
        case .token(let text):
            emit(type: "message.delta", payload: ["text": .string(text)])
        case .thinking(let text):
            emit(type: "thinking.delta", payload: ["text": .string(text)])
        case .reasoning(let text):
            emit(type: "reasoning.delta", payload: ["text": .string(text)])
        case .interimAssistant(let text, let alreadyStreamed):
            emit(type: "message.interim", payload: [
                "text": .string(text),
                "already_streamed": .bool(alreadyStreamed)
            ])
        case .done:
            emit(type: "message.complete", payload: ["status": .string("complete")])
        case .cancelled:
            emit(type: "message.complete", payload: ["status": .string("cancelled")])
        }
    }

    private func emit(type: String, payload: [String: JSONValue] = [:]) {
        sequence += 1
        viewModel?.handleDirectEventForTesting(HermesGatewayEvent(
            method: "event",
            type: type,
            sessionID: "runtime-test",
            sequence: sequence,
            payload: .object(payload),
            params: nil,
            connectionGeneration: 1
        ))
    }
}

/// Cancellation-insensitive suspension lets the test choose when cancelled A
/// resumes, including after replacement B has entered the real scheduler.
@MainActor
private final class StreamingTaskSuspensionGate {
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [UUID: XCTestExpectation] = [:]
    private var enteredOwners: Set<UUID> = []
    private var isFinished = false
    private(set) var delays: [UUID: UInt64] = [:]

    var suspendedOwners: Set<UUID> { Set(continuations.keys) }

    func suspend(owner: UUID, delay: UInt64) async {
        guard !isFinished else { return }
        await withCheckedContinuation { continuation in
            continuations[owner] = continuation
            delays[owner] = delay
            enteredOwners.insert(owner)
            arrivals.removeValue(forKey: owner)?.fulfill()
        }
    }

    func arrival(for owner: UUID) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Streaming task \(owner) suspended")
        if enteredOwners.contains(owner) {
            expectation.fulfill()
        } else {
            arrivals[owner] = expectation
        }
        return expectation
    }

    func release(_ owner: UUID) throws {
        let continuation = try XCTUnwrap(continuations.removeValue(forKey: owner))
        continuation.resume()
    }

    func finish() {
        isFinished = true
        let waiting = Array(continuations.values)
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
