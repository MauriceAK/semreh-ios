import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class LocalSendPresentationTests: APIClientTestCase {
    func testPendingBubblePrecedesResumeSurvivesCanonicalReadAndPromotesWithoutReinsertion() async throws {
        let resumeGate = LocalSendGate()
        let stageGate = LocalSendGate()
        let promptGate = LocalSendGate()
        let transport = LocalSendTransport(resumeGate: resumeGate, stageGate: stageGate, promptGate: promptGate)
        let (vm, runtime) = try makeFixture(transport)
        vm.seedTranscriptForTesting([
            ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1, messageId: "cached")
        ])
        await vm.uploadAttachment(data: Data("local file".utf8), filename: "notes.txt")

        let send = Task { await vm.sendMessage("  New question  ") }
        await waitUntil { transport.calls.contains("session.resume") }
        let pending = vm.displayedTranscriptMessages.last
        let insertion = vm.outgoingInsertionEvent
        XCTAssertEqual(pending?.message.content, "New question")
        XCTAssertEqual(pending?.loadedIndex, -1)
        XCTAssertEqual(pending?.localDelivery, .sending)
        XCTAssertNotNil(insertion)
        XCTAssertFalse(vm.messages.contains { $0.content == "New question" })
        if let pending {
            XCTAssertNil(MessageActionContext(message: pending.message, visibleIndex: pending.loadedIndex, messagesOffset: 0))
        }

        await resumeGate.release()
        await waitUntil { transport.calls.contains("file.attach") }
        XCTAssertEqual(vm.messages.compactMap(\.content), ["Earlier question", "Earlier answer"])
        XCTAssertEqual(vm.displayedTranscriptMessages.map(\.message.content), ["Earlier question", "Earlier answer", "New question"])
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, pending?.renderID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        XCTAssertEqual(vm.outgoingInsertionEvent, insertion)
        let referenceCard = ChatViewModel.compressionReferenceCard(
            messages: vm.messages, messagesOffset: 0,
            transcriptMessages: vm.displayedTranscriptMessages,
            metadata: CompressionAnchorMetadata(visibleIdx: 1, messageKey: nil, summary: "Earlier context")
        )
        XCTAssertEqual(referenceCard?.afterRenderID, vm.displayedTranscriptMessages.first { $0.loadedIndex == 1 }?.renderID)
        XCTAssertNotEqual(referenceCard?.afterRenderID, pending?.renderID,
                          "A pending send must never steal the canonical compaction anchor")

        await stageGate.release()
        await waitUntil { transport.calls.contains("prompt.submit") }
        let promoted = vm.displayedTranscriptMessages.last
        XCTAssertEqual(promoted?.loadedIndex, 2)
        XCTAssertEqual(promoted?.localDelivery, .sending)
        XCTAssertEqual(promoted?.message, pending?.message)
        XCTAssertEqual(promoted?.renderID, pending?.renderID)
        XCTAssertEqual(vm.outgoingInsertionEvent, insertion, "Promotion must not replay the outgoing animation")
        XCTAssertEqual(vm.messages.filter { $0.content == "New question" }.count, 1)
        XCTAssertEqual(vm.displayedTranscriptMessages.filter { $0.message.content == "New question" }.count, 1)
        XCTAssertFalse(vm.displayedTranscriptMessages.contains { $0.loadedIndex == -1 })

        await promptGate.release()
        let accepted = await send.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .accepted)
        XCTAssertNil(vm.displayedTranscriptMessages.last?.localDelivery?.label)
        XCTAssertTrue(vm.displayedTranscriptMessages.dropLast().allSatisfy { $0.localDelivery == nil })
        XCTAssertTrue(vm.directPendingAttachments.isEmpty)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testCanonicalTipRolloverDropsOldHistoryButPreservesPendingIdentity() async throws {
        let resumeGate = LocalSendGate()
        let stageGate = LocalSendGate()
        let transport = LocalSendTransport(resumeGate: resumeGate, stageGate: stageGate, resumedSessionID: "different-tip")
        let (vm, runtime) = try makeFixture(transport, emptyTranscript: true)
        vm.seedTranscriptForTesting([
            ChatMessage(role: "assistant", content: "Previous session answer", timestamp: 1, messageId: "previous")
        ])
        await vm.uploadAttachment(data: Data("local file".utf8), filename: "notes.txt")
        let send = Task { await vm.sendMessage("New tip question") }
        await waitUntil { transport.calls.contains("session.resume") }
        let pendingID = vm.displayedTranscriptMessages.last?.renderID
        let insertion = vm.outgoingInsertionEvent
        XCTAssertNotNil(pendingID)
        await resumeGate.release()
        await waitUntil { transport.calls.contains("file.attach") }

        XCTAssertEqual(vm.attachmentSessionID, "different-tip")
        XCTAssertTrue(vm.messages.isEmpty, "A different canonical tip must drop previous session history")
        XCTAssertEqual(vm.displayedTranscriptMessages.count, 1)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.message.content, "New tip question")
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, pendingID)
        await stageGate.release()
        let accepted = await send.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(vm.messages.compactMap(\.content), ["New tip question"])
        XCTAssertEqual(vm.displayedTranscriptMessages.count, 1)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, 0)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, pendingID)
        XCTAssertEqual(vm.outgoingInsertionEvent, insertion)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDefiniteAttachmentRefusalKeepsLocalNotSentBubbleAndDraftRetryable() async throws {
        let stageGate = LocalSendGate()
        let transport = LocalSendTransport(stageGate: stageGate, stageError: .server(
            code: 4015, message: "path or data_url required", data: nil,
            method: "file.attach", requestID: "fixture-stage", server: "fixture"
        ))
        let (vm, runtime) = try makeFixture(transport)
        await vm.uploadAttachment(data: Data("local file".utf8), filename: "notes.txt")
        let attachmentIDs = vm.directPendingAttachments.map(\.id)
        let send = Task { await vm.sendMessage("Keep this draft") }
        await waitUntil { transport.calls.contains("file.attach") }
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.message.content, "Keep this draft")
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        let pendingID = vm.displayedTranscriptMessages.last?.renderID

        await stageGate.release()
        let accepted = await send.value
        XCTAssertFalse(accepted, "The composer uses false to restore the submitted draft")
        XCTAssertEqual(vm.messages.compactMap(\.content), ["Earlier question", "Earlier answer"])
        XCTAssertEqual(vm.displayedTranscriptMessages.map(\.message.content), ["Earlier question", "Earlier answer", "Keep this draft"])
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, pendingID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .notSent)
        XCTAssertNil(vm.composerSendErrorMessage)
        XCTAssertEqual(vm.directPendingAttachments.map(\.id), attachmentIDs)
        XCTAssertTrue(vm.sendErrorMessage?.contains("Your draft was kept") == true)
        XCTAssertFalse(vm.isStartingChat)
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testCancellationDuringResumeRemovesUnsubmittedBubble() async throws {
        let resumeGate = LocalSendGate()
        let transport = LocalSendTransport(resumeGate: resumeGate)
        let (vm, runtime) = try makeFixture(transport)
        let send = Task { await vm.sendMessage("Cancelled draft") }
        await waitUntil { transport.calls.contains("session.resume") }
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.message.content, "Cancelled draft")
        send.cancel()
        await resumeGate.release()
        let accepted = await send.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(vm.messages.contains { $0.content == "Cancelled draft" })
        XCTAssertFalse(vm.displayedTranscriptMessages.contains { $0.message.content == "Cancelled draft" })
        XCTAssertFalse(vm.isStartingChat)
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testResumeFailureKeepsUnsubmittedPresentationAndDraft() async throws {
        let resumeGate = LocalSendGate()
        let transport = LocalSendTransport(resumeGate: resumeGate, resumeError: .timeout(
            method: "session.resume", requestID: "fixture-resume"
        ))
        let (vm, runtime) = try makeFixture(transport)
        let send = Task { await vm.sendMessage("Retryable draft") }
        await waitUntil { transport.calls.contains("session.resume") }
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        await resumeGate.release()
        let accepted = await send.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(vm.displayedTranscriptMessages.count, 1)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .notSent)
        XCTAssertNil(vm.composerSendErrorMessage)
        XCTAssertFalse(vm.isStartingChat)
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
        XCTAssertTrue(vm.sendErrorMessage?.contains("Your draft was kept") == true)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testUnknownPromptAcknowledgementKeepsPromotedBubbleAndBlocksDuplicateSend() async throws {
        let promptGate = LocalSendGate()
        let transport = LocalSendTransport(promptGate: promptGate, promptError: .timeout(
            method: "prompt.submit", requestID: "fixture-prompt"
        ))
        let (vm, runtime) = try makeFixture(transport)
        let send = Task { await vm.sendMessage("Possibly delivered") }
        await waitUntil { transport.calls.contains("prompt.submit") }
        let promoted = vm.displayedTranscriptMessages.last
        let insertion = vm.outgoingInsertionEvent
        XCTAssertEqual(promoted?.message.content, "Possibly delivered")
        XCTAssertEqual(promoted?.loadedIndex, 2)
        await promptGate.release()
        let acceptedOrUncertain = await send.value
        XCTAssertTrue(acceptedOrUncertain, "Unknown delivery must not restore a resendable composer draft")
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.message, promoted?.message)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, promoted?.renderID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .unconfirmed)
        XCTAssertNil(vm.composerSendErrorMessage)
        XCTAssertTrue(vm.sendErrorMessage?.contains("cannot confirm") == true)
        let retryAccepted = await vm.sendMessage("Possibly delivered")
        XCTAssertFalse(retryAccepted)
        XCTAssertEqual(vm.outgoingInsertionEvent, insertion)
        XCTAssertEqual(vm.messages.filter { $0.content == "Possibly delivered" }.count, 1)
        XCTAssertEqual(vm.displayedTranscriptMessages.filter { $0.message.content == "Possibly delivered" }.count, 1)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testPreviewDisabledRetainsExistingSendPresentation() async throws {
        let resumeGate = LocalSendGate()
        let transport = LocalSendTransport(resumeGate: resumeGate)
        let (vm, runtime) = try makeFixture(transport, previewEnabled: false)
        let send = Task { await vm.sendMessage("Control surface") }
        await waitUntil { transport.calls.contains("session.resume") }
        XCTAssertTrue(vm.displayedTranscriptMessages.isEmpty)
        XCTAssertNil(vm.outgoingInsertionEvent)
        await resumeGate.release()
        let accepted = await send.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.message.content, "Control surface")
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, 2)
        XCTAssertNil(vm.displayedTranscriptMessages.last?.localDelivery)
        XCTAssertEqual(vm.outgoingInsertionEvent?.sequence, 1)
        await stream("Control answer", through: transport, vm: vm)
        transport.setTranscript(LocalSendTransport.baseline + [
            LocalSendTransport.row(3, role: "user", text: "Control surface"), LocalSendTransport.row(4, role: "assistant", text: "Control answer")
        ])
        transport.emit("message.complete", sequence: 3, text: "Control answer")
        await waitUntil { vm.messages.last?.messageId == "4" }
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.message.messageId == "3" }?.renderID, "transcript:row:3")
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, "transcript:row:4")
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testAcceptedTerminalEchoPreservesUserAndAssistantRowsWithDurableColdRestore() async throws {
        let suite = "LocalSendEcho-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = LocalSendTransport()
        let (vm, runtime) = try makeFixture(transport, defaults: defaults)
        let accepted = await vm.sendMessage("A new question")
        XCTAssertTrue(accepted)
        let localUser = try XCTUnwrap(vm.displayedTranscriptMessages.last)
        await stream("A complete answer", through: transport, vm: vm)
        let liveAssistant = try XCTUnwrap(vm.displayedTranscriptMessages.last)
        let warmPoint = ChatWarmReaderMemory.Point(messageID: liveAssistant.renderID, minY: -24, viewportWidth: 402)
        vm.warmTranscriptReaderMemory?.point = warmPoint
        vm.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: liveAssistant.renderID)
        let store = TranscriptRestoreStore(defaults: defaults)
        let origin = URL(string: "https://example.test")!
        XCTAssertEqual(store.load(server: origin, sessionID: "durable-1").visibleMessageID, liveAssistant.renderID)

        let canonical = LocalSendTransport.baseline + [
            LocalSendTransport.row(3, role: "user", text: "A new question"),
            LocalSendTransport.row(4, role: "assistant", text: "A complete answer")
        ]
        transport.setTranscript(canonical)
        transport.emit("message.complete", sequence: 3, text: "A complete answer")
        await waitUntil { vm.messages.last?.messageId == "4" }
        let user = try XCTUnwrap(vm.displayedTranscriptMessages.first { $0.message.messageId == "3" })
        let assistant = try XCTUnwrap(vm.displayedTranscriptMessages.last)
        XCTAssertEqual(user.renderID, localUser.renderID)
        XCTAssertEqual(user.localDelivery, .accepted)
        XCTAssertEqual(assistant.renderID, liveAssistant.renderID)
        XCTAssertEqual(user.anchorID, "3", "Canonical actions and turn anchors retain durable identity")
        XCTAssertEqual(MessageActionContext(message: user.message, visibleIndex: user.loadedIndex, messagesOffset: 0)?.messageID, "3")
        XCTAssertEqual(Set(vm.displayedTranscriptMessages.map(\.renderID)).count, vm.displayedTranscriptMessages.count)
        XCTAssertEqual(store.load(server: origin, sessionID: "durable-1").visibleMessageID, "transcript:row:4",
                       "A bookmark saved before the echo must become durable even while offscreen")
        XCTAssertEqual(vm.transcriptRestoreTarget, .message(id: liveAssistant.renderID))
        XCTAssertEqual(vm.warmTranscriptReaderMemory?.point, warmPoint)
        vm.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: user.renderID)
        XCTAssertEqual(store.load(server: origin, sessionID: "durable-1").visibleMessageID, "transcript:row:3")
        XCTAssertEqual(vm.transcriptRestoreTarget, .message(id: localUser.renderID))
        await vm.disposeDirectConversation()
        await runtime.stop()

        let coldTransport = LocalSendTransport()
        coldTransport.setTranscript(canonical)
        let (cold, coldRuntime) = try makeFixture(coldTransport, defaults: defaults)
        await cold.loadMessages()
        XCTAssertEqual(cold.transcriptRestoreTarget, .message(id: "transcript:row:3"))
        XCTAssertEqual(cold.displayedTranscriptMessages.first { $0.message.messageId == "3" }?.renderID, "transcript:row:3")
        await cold.disposeDirectConversation()
        await coldRuntime.stop()
    }

    func testRepeatedIdenticalAcceptedTurnsKeepDistinctAliasesAndRetainedPrefix() async throws {
        let transport = LocalSendTransport()
        let (vm, runtime) = try makeFixture(transport)
        let firstAccepted = await vm.sendMessage("Repeat")
        XCTAssertTrue(firstAccepted)
        let firstUserID = vm.displayedTranscriptMessages.last?.renderID
        await stream("Answer", through: transport, vm: vm)
        transport.setTranscript(LocalSendTransport.baseline + [
            LocalSendTransport.row(3, role: "user", text: "Repeat"), LocalSendTransport.row(4, role: "assistant", text: "Answer")
        ])
        transport.emit("message.complete", sequence: 3, text: "Answer")
        await waitUntil { vm.messages.last?.messageId == "4" }

        let secondAccepted = await vm.sendMessage("Repeat")
        XCTAssertTrue(secondAccepted)
        let secondUserID = vm.displayedTranscriptMessages.last?.renderID
        await stream("Answer", through: transport, vm: vm, firstSequence: 4)
        // The terminal tail overlaps only the previous durable assistant. The
        // previously aliased user belongs to the retained prefix, not this page.
        transport.setTranscript([
            LocalSendTransport.row(4, role: "assistant", text: "Answer"),
            LocalSendTransport.row(5, role: "user", text: "Repeat"), LocalSendTransport.row(6, role: "assistant", text: "Answer")
        ])
        transport.emit("message.complete", sequence: 6, text: "Answer")
        await waitUntil { vm.messages.last?.messageId == "6" }
        XCTAssertNotEqual(firstUserID, secondUserID)
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.message.messageId == "3" }?.renderID, firstUserID)
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.message.messageId == "5" }?.renderID, secondUserID)
        XCTAssertEqual(vm.messages.compactMap(\.messageId), ["1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(Set(vm.displayedTranscriptMessages.map(\.renderID)).count, 6)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 2)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testFirstAcceptedDraftEchoPreservesBothPresentationIdentities() async throws {
        let transport = LocalSendTransport()
        let (vm, runtime) = try makeFixture(transport, emptyTranscript: true, sessionID: nil)
        let accepted = await vm.sendMessage("First question")
        XCTAssertTrue(accepted)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .accepted)
        let userID = vm.displayedTranscriptMessages.last?.renderID
        await stream("First answer", through: transport, vm: vm)
        let assistantID = vm.displayedTranscriptMessages.last?.renderID
        transport.setTranscript([
            LocalSendTransport.row(3, role: "user", text: "First question"), LocalSendTransport.row(4, role: "assistant", text: "First answer")
        ])
        transport.emit("message.complete", sequence: 3, text: "First answer")
        await waitUntil { vm.messages.last?.messageId == "4" }
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.displayedTranscriptMessages.first?.renderID, userID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, assistantID)
        XCTAssertEqual(transport.calls.filter { $0 == "session.create" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testCanonicalTerminalBeforeAcknowledgementDoesNotGuessOrReassignIdentityLater() async throws {
        let gate = LocalSendGate()
        let transport = LocalSendTransport(promptGate: gate)
        let (vm, runtime) = try makeFixture(transport)
        let send = Task { await vm.sendMessage("Question") }
        await waitUntil { transport.calls.contains("prompt.submit") }
        await stream("Answer", through: transport, vm: vm)
        transport.setTranscript(LocalSendTransport.baseline + [
            LocalSendTransport.row(3, role: "user", text: "Question"), LocalSendTransport.row(4, role: "assistant", text: "Answer")
        ])
        transport.emit("message.complete", sequence: 3, text: "Answer")
        await waitUntil { vm.messages.last?.messageId == "4" }
        let canonicalIDs = vm.displayedTranscriptMessages.map(\.renderID)
        XCTAssertEqual(canonicalIDs.suffix(2), ["transcript:row:3", "transcript:row:4"])
        await gate.release()
        let accepted = await send.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(vm.displayedTranscriptMessages.map(\.renderID), canonicalIDs)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testEchoMismatchDuplicateUsersAndChangedScopeNeverBorrowLocalIdentity() async throws {
        let cases: [(String, [JSONValue], String?)] = [
            ("mismatched text", [LocalSendTransport.row(3, role: "user", text: "Other question"), LocalSendTransport.row(4, role: "assistant", text: "Answer")], nil),
            ("indistinguishable users", [LocalSendTransport.row(3, role: "user", text: "Question"), LocalSendTransport.row(4, role: "assistant", text: "Answer"), LocalSendTransport.row(5, role: "user", text: "Question")], nil),
            ("duplicate durable rows", [LocalSendTransport.row(3, role: "user", text: "Question"), LocalSendTransport.row(3, role: "assistant", text: "Answer")], nil),
            ("canonical rollover", [LocalSendTransport.row(3, role: "user", text: "Question"), LocalSendTransport.row(4, role: "assistant", text: "Answer")], "different-tip")
        ]
        for (label, rows, scope) in cases {
            let transport = LocalSendTransport()
            let (vm, runtime) = try makeFixture(transport)
            let accepted = await vm.sendMessage("Question")
            XCTAssertTrue(accepted, label)
            let localUserID = vm.displayedTranscriptMessages.last?.renderID
            await stream("Answer", through: transport, vm: vm)
            let liveAssistantID = vm.displayedTranscriptMessages.last?.renderID
            transport.setTranscript(LocalSendTransport.baseline + rows, sessionID: scope)
            transport.emit("message.complete", sequence: 3, text: "Answer")
            await waitUntil { vm.messages.contains { $0.messageId == "3" } }
            XCTAssertFalse(vm.displayedTranscriptMessages.contains { $0.renderID == localUserID }, label)
            XCTAssertFalse(vm.displayedTranscriptMessages.contains { $0.renderID == liveAssistantID }, label)
            XCTAssertEqual(vm.messages.count, LocalSendTransport.baseline.count + rows.count, label)
            await vm.disposeDirectConversation()
            await runtime.stop()
        }
    }

    func testUnknownAcknowledgementDoesNotGainAliasFromMatchingTerminal() async throws {
        let transport = LocalSendTransport(promptError: .timeout(method: "prompt.submit", requestID: "unknown"))
        let (vm, runtime) = try makeFixture(transport)
        let uncertain = await vm.sendMessage("Question")
        XCTAssertTrue(uncertain)
        let localID = vm.displayedTranscriptMessages.last?.renderID
        await stream("Answer", through: transport, vm: vm)
        transport.setTranscript(LocalSendTransport.baseline + [
            LocalSendTransport.row(3, role: "user", text: "Question"), LocalSendTransport.row(4, role: "assistant", text: "Answer")
        ])
        transport.emit("message.complete", sequence: 3, text: "Answer")
        await waitUntil { vm.messages.last?.messageId == "4" }
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.message.messageId == "3" }?.renderID, "transcript:row:3")
        XCTAssertFalse(vm.displayedTranscriptMessages.contains { $0.renderID == localID },
                       "Canonical body replaces only the redundant body, never the delivery barrier")
        XCTAssertEqual(vm.displayedTranscriptMessages.count, 4)
        XCTAssertEqual(vm.messages.count, 4)
        XCTAssertTrue(vm.directConversationHasPromptDeliveryUncertainty)
        XCTAssertNil(vm.composerSendErrorMessage, "The compact recovery notice owns this attempt error")
        let retried = await vm.sendMessage("Question")
        XCTAssertFalse(retried)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
        transport.setTranscript([])
        transport.emit("message.complete", sequence: 4)
        await waitUntil { vm.messages.isEmpty }
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, localID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .unconfirmed,
                       "Hiding a redundant body must not prune its uncertain delivery state")
        transport.setTranscript(LocalSendTransport.baseline + [
            LocalSendTransport.row(3, role: "user", text: "Question"), LocalSendTransport.row(4, role: "assistant", text: "Answer")
        ])
        transport.emit("message.complete", sequence: 5)
        await waitUntil { vm.messages.last?.messageId == "4" }
        XCTAssertFalse(vm.displayedTranscriptMessages.contains { $0.renderID == localID })
        let target = try XCTUnwrap(vm.directPromptDeliveryRecoveryTarget)
        let recovered = await vm.abandonDirectPromptDeliveryUncertainty(target)
        XCTAssertTrue(recovered)
        XCTAssertFalse(vm.directConversationHasPromptDeliveryUncertainty)
        XCTAssertNil(vm.sendErrorMessage)
        XCTAssertEqual(vm.displayedTranscriptMessages.count, 4)
        XCTAssertTrue(vm.displayedTranscriptMessages.allSatisfy { $0.localDelivery == nil })
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testMismatchedAssistantKeepsCanonicalIdentityWithoutLosingVerifiedUserAlias() async throws {
        let transport = LocalSendTransport()
        let (vm, runtime) = try makeFixture(transport)
        let accepted = await vm.sendMessage("Question")
        XCTAssertTrue(accepted)
        let localUserID = vm.displayedTranscriptMessages.last?.renderID
        await stream("Visible answer", through: transport, vm: vm)
        let liveID = vm.displayedTranscriptMessages.last?.renderID
        transport.setTranscript(LocalSendTransport.baseline + [
            LocalSendTransport.row(3, role: "user", text: "Question"), LocalSendTransport.row(4, role: "assistant", text: "Different saved answer")
        ])
        transport.emit("message.complete", sequence: 3, text: "Visible answer")
        await waitUntil { vm.messages.last?.messageId == "4" }
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.message.messageId == "3" }?.renderID, localUserID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, "transcript:row:4")
        XCTAssertNotEqual(vm.displayedTranscriptMessages.last?.renderID, liveID)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    private func stream(_ text: String, through transport: LocalSendTransport, vm: ChatViewModel,
                        firstSequence: Int = 1) async {
        transport.emit("message.start", sequence: firstSequence)
        transport.emit("message.delta", sequence: firstSequence + 1, text: text)
        await waitUntil { vm.messages.last?.role == "assistant" && vm.messages.last?.content == text }
    }

    func testDefiniteRejectionReusesOnlyExactFailedIntentAndRetainsOneLocalFailure() async throws {
        let transport = LocalSendTransport(promptError: .server(code: 4001, message: "rejected", data: nil,
            method: "prompt.submit", requestID: "fixture-rejected", server: "fixture"))
        let (vm, runtime) = try makeFixture(transport)
        let draft = "  Keep exact 👩🏽‍💻\n"
        let firstResult = await vm.sendMessage(draft)
        XCTAssertFalse(firstResult)
        let first = try XCTUnwrap(vm.displayedTranscriptMessages.last)
        let insertion = vm.outgoingInsertionEvent
        XCTAssertEqual(first.localDelivery, .notSent)
        XCTAssertEqual(first.loadedIndex, -1)
        XCTAssertNil(MessageActionContext(message: first.message, visibleIndex: -1, messagesOffset: 0))
        XCTAssertEqual(vm.messages.compactMap(\.content), ["Earlier question", "Earlier answer"])
        XCTAssertNil(vm.composerSendErrorMessage)
        let secondResult = await vm.sendMessage(draft)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, first.renderID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.message.timestamp, first.message.timestamp)
        XCTAssertEqual(vm.outgoingInsertionEvent, insertion)
        XCTAssertEqual(vm.displayedTranscriptMessages.filter { $0.loadedIndex == -1 }.count, 1)

        let differentResult = await vm.sendMessage("A different intent")
        XCTAssertFalse(differentResult)
        XCTAssertNotEqual(vm.displayedTranscriptMessages.last?.renderID, first.renderID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .notSent)
        XCTAssertFalse(vm.displayedTranscriptMessages.contains { $0.message.id == first.message.id })
        XCTAssertEqual(vm.displayedTranscriptMessages.filter { $0.loadedIndex == -1 }.count, 1)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 3, "Only explicit sends dispatch")
        XCTAssertEqual(vm.messages.compactMap(\.content), ["Earlier question", "Earlier answer"])
        vm.setSendErrorMessage("Hermes has not confirmed that the response stopped.")
        XCTAssertEqual(vm.composerSendErrorMessage, "Hermes has not confirmed that the response stopped.",
                       "An unrelated later error remains visible while the failed row stays mounted")
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .notSent)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testSafetyMarkerWriteFailureIsLocalNotSentWithoutDispatch() async throws {
        let store = InMemoryDirectPromptDeliveryUncertaintyStore()
        store.failWrite = true
        let transport = LocalSendTransport()
        let (vm, runtime) = try makeFixture(transport, promptStore: store)
        let accepted = await vm.sendMessage("Do not dispatch")
        XCTAssertFalse(accepted)
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
        XCTAssertFalse(vm.messages.contains { $0.content == "Do not dispatch" })
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .notSent)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        XCTAssertNil(vm.composerSendErrorMessage)
        XCTAssertTrue(vm.sendErrorMessage?.contains("not sent") == true)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testAcceptedMarkerCleanupFailureKeepsAcceptedRowAndSafetyAttention() async throws {
        let store = InMemoryDirectPromptDeliveryUncertaintyStore()
        store.failRemove = true
        let transport = LocalSendTransport()
        let (vm, runtime) = try makeFixture(transport, promptStore: store)
        let accepted = await vm.sendMessage("Accepted once")
        XCTAssertTrue(accepted)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .accepted)
        XCTAssertTrue(vm.directConversationHasPromptDeliveryUncertainty)
        XCTAssertTrue(vm.directPromptDeliveryHasConfirmedAcceptance)
        XCTAssertEqual(vm.composerSendErrorMessage, vm.sendErrorMessage)
        let blocked = await vm.sendMessage("Accepted once")
        XCTAssertFalse(blocked)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .accepted)
        XCTAssertNotNil(vm.composerSendErrorMessage, "Accepted cleanup attention is not an unconfirmed delivery label")
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testUnconfirmedRowSurvivesCanonicalEmptyWithoutBecomingRetryable() async throws {
        let transport = LocalSendTransport(promptError: .timeout(method: "prompt.submit", requestID: "lost-ack"))
        let (vm, runtime) = try makeFixture(transport)
        let result = await vm.sendMessage("Possibly received")
        XCTAssertTrue(result)
        let original = try XCTUnwrap(vm.displayedTranscriptMessages.last)
        // Exercise the actual terminal REST reconciliation, not an echo guess.
        transport.setTranscript([])
        transport.emit("message.complete", sequence: 1)
        await waitUntil { vm.messages.isEmpty }
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(vm.displayedTranscriptMessages.count, 1)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, original.renderID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .unconfirmed)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        let blocked = await vm.sendMessage("Possibly received")
        XCTAssertFalse(blocked)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
        let target = try XCTUnwrap(vm.directPromptDeliveryRecoveryTarget)
        let recovered = await vm.abandonDirectPromptDeliveryUncertainty(target)
        XCTAssertTrue(recovered)
        XCTAssertTrue(vm.displayedTranscriptMessages.isEmpty, "Successful explicit recovery retires the unresolved local row")
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.directConversationHasPromptDeliveryUncertainty)
        XCTAssertNil(vm.sendErrorMessage)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testUnchangedEarlierHistoryKeepsUnknownBodyAndRecoveryPreservesAcceptedFooter() async throws {
        let transport = LocalSendTransport()
        let (vm, runtime) = try makeFixture(transport)
        let firstResult = await vm.sendMessage("Repeated question")
        XCTAssertTrue(firstResult)
        let acceptedID = try XCTUnwrap(vm.displayedTranscriptMessages.last?.renderID)
        await stream("Previous answer", through: transport, vm: vm)
        transport.setTranscript(LocalSendTransport.baseline + [
            LocalSendTransport.row(3, role: "user", text: "Repeated question"),
            LocalSendTransport.row(4, role: "assistant", text: "Previous answer")
        ])
        transport.emit("message.complete", sequence: 3, text: "Previous answer")
        await waitUntil { vm.messages.last?.messageId == "4" }
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.renderID == acceptedID }?.localDelivery, .accepted)

        transport.setPromptError(.timeout(method: "prompt.submit", requestID: "later-unknown"))
        let uncertain = await vm.sendMessage("Repeated question")
        XCTAssertTrue(uncertain)
        let localID = try XCTUnwrap(vm.displayedTranscriptMessages.last?.renderID)
        transport.emit("message.complete", sequence: 4)
        await waitUntil { vm.messages.count == 4 }
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.renderID, localID)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .unconfirmed)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.loadedIndex, -1)
        XCTAssertEqual(vm.displayedTranscriptMessages.count, 5, "Unchanged old history cannot erase the current unknown question")
        XCTAssertNil(vm.composerSendErrorMessage)
        let target = try XCTUnwrap(vm.directPromptDeliveryRecoveryTarget)
        let recovered = await vm.abandonDirectPromptDeliveryUncertainty(target)
        XCTAssertTrue(recovered)
        XCTAssertFalse(vm.displayedTranscriptMessages.contains { $0.renderID == localID })
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.renderID == acceptedID }?.localDelivery, .accepted,
                       "Recovery retires only its current unconfirmed presentation")
        XCTAssertEqual(vm.messages.count, 4)
        XCTAssertEqual(transport.calls.filter { $0 == "prompt.submit" }.count, 2)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testFailedPresentationCannotOverwriteNewerComposerDraft() async throws {
        let suite = "LocalSendDraft-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let origin = URL(string: "https://example.test")!
        let configuration = SessionSummary(sessionId: "durable-1", profile: "work")
        let store = ComposerDraftStore(defaults: defaults)
        let writer = store.claimWriter(server: origin, sessionID: configuration.id, owner: UUID())
        store.save("", configuration: configuration, server: origin, sessionID: configuration.id, writer: writer)
        let checkpoint = try XCTUnwrap(store.submissionCheckpoint(server: origin, sessionID: configuration.id, writer: writer))
        let gate = LocalSendGate()
        let transport = LocalSendTransport(resumeGate: gate,
            resumeError: .timeout(method: "session.resume", requestID: "offline"))
        let (vm, runtime) = try makeFixture(transport, defaults: defaults)
        let submitted = "  Original 👩🏽‍💻\n"
        let send = Task { await vm.sendMessage(submitted) }
        await waitUntil { transport.calls.contains("session.resume") }
        let newer = "  New draft\n"
        store.noteWriterEdit(newer, writer: writer, server: origin, sessionID: configuration.id)
        await gate.release()
        let accepted = await send.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(vm.displayedTranscriptMessages.last?.localDelivery, .notSent)
        XCTAssertFalse(store.restoreFailedSubmission(submitted, checkpoint: checkpoint, server: origin, sessionID: configuration.id))
        XCTAssertTrue(store.save(newer, configuration: configuration, server: origin, sessionID: configuration.id, writer: writer))
        XCTAssertEqual(store.load(server: origin, sessionID: configuration.id).utf8.map { $0 }, Array(newer.utf8))
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testInvalidationDuringHeldFailureCannotReviveLocalAttempt() async throws {
        let gate = LocalSendGate()
        let transport = LocalSendTransport(resumeGate: gate,
            resumeError: .timeout(method: "session.resume", requestID: "old-owner"))
        let (vm, runtime) = try makeFixture(transport)
        let send = Task { await vm.sendMessage("Old conversation") }
        await waitUntil { transport.calls.contains("session.resume") }
        vm.invalidateDirectConversation()
        await gate.release()
        let accepted = await send.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(vm.displayedTranscriptMessages.isEmpty)
        XCTAssertFalse(transport.calls.contains("prompt.submit"))
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    private func makeFixture(
        _ transport: LocalSendTransport,
        previewEnabled: Bool = true,
        emptyTranscript: Bool = false,
        defaults: UserDefaults = .standard,
        sessionID: String? = "durable-1",
        promptStore: InMemoryDirectPromptDeliveryUncertaintyStore = InMemoryDirectPromptDeliveryUncertaintyStore()
    ) throws -> (ChatViewModel, HermesServerRuntime) {
        let origin = URL(string: "https://example.test")!
        let runtime = try HermesServerRuntime(origin: origin) { sink in
            transport.installSink(sink)
            return transport
        }
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/\(transport.resumedSessionID)/messages")
            return apiTestJSONResponse(try transport.transcriptResponse(empty: emptyTranscript), for: request)
        }
        let vm = ChatViewModel(
            session: SessionSummary(sessionId: sessionID, title: "Fixture", profile: "work"),
            server: origin,
            client: client,
            liveActivityManager: LocalSendNoopActivityManager(),
            userDefaults: defaults,
            gatewayRuntimeProvider: { _ in runtime },
            directAttachmentRecoveryMarkerStore: LocalSendAttachmentMarkerStore(),
            promptUncertaintyStore: promptStore
        )
        vm.setLocalSendPresentationEnabled(previewEnabled)
        return (vm, runtime)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Held operation was not reached", file: file, line: line)
    }
}

private actor LocalSendGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Holds actual gateway suspension points. No timing assumption substitutes
/// for observing the pending row before the server is allowed to respond.
private final class LocalSendTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var canonicalRows: [JSONValue]?
    private var canonicalSessionID: String?
    private let resumeGate: LocalSendGate?
    private let stageGate: LocalSendGate?
    private let promptGate: LocalSendGate?
    private let resumeError: HermesGatewayError?
    private let stageError: HermesGatewayError?
    private var promptError: HermesGatewayError?
    let resumedSessionID: String

    init(resumeGate: LocalSendGate? = nil, stageGate: LocalSendGate? = nil,
         promptGate: LocalSendGate? = nil, resumeError: HermesGatewayError? = nil,
         stageError: HermesGatewayError? = nil, promptError: HermesGatewayError? = nil,
         resumedSessionID: String = "durable-1") {
        self.resumeGate = resumeGate
        self.stageGate = stageGate
        self.promptGate = promptGate
        self.resumeError = resumeError
        self.stageError = stageError
        self.promptError = promptError
        self.resumedSessionID = resumedSessionID
    }

    var calls: [String] { lock.withLock { recordedCalls } }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }
    func setPromptError(_ error: HermesGatewayError?) {
        lock.withLock { promptError = error }
    }
    func setTranscript(_ rows: [JSONValue], sessionID: String? = nil) {
        lock.withLock {
            canonicalRows = rows
            canonicalSessionID = sessionID
        }
    }
    static func row(_ id: Int, role: String, text: String) -> JSONValue {
        .object(["id": .number(Double(id)), "role": .string(role), "content": .string(text), "timestamp": .number(Double(id))])
    }
    static var baseline: [JSONValue] {
        [row(1, role: "user", text: "Earlier question"), row(2, role: "assistant", text: "Earlier answer")]
    }
    func transcriptResponse(empty: Bool) throws -> String {
        let (overrideRows, overrideID) = lock.withLock { (canonicalRows, canonicalSessionID) }
        let rows = overrideRows ?? (empty ? [] : Self.baseline)
        let response = JSONValue.object([
            "session_id": .string(overrideID ?? resumedSessionID), "messages": .array(rows),
            "pagination": .object(["limit": .number(120), "offset": .number(0), "order": .string("latest"), "returned": .number(Double(rows.count))])
        ])
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }
    func emit(_ type: String, sequence: Int, text: String? = nil) {
        let callback = lock.withLock { sink }
        callback?(HermesGatewayEvent(method: "event", type: type, sessionID: "runtime-1", sequence: sequence,
                                    payload: text.map { .object(["text": .string($0)]) }, params: nil, connectionGeneration: 1))
    }
    func connect() async throws {}
    func close() async {}
    func connectionIdentifier() async -> Int? { 1 }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { recordedCalls.append(method) }
        switch method {
        case "session.create", "session.resume":
            await resumeGate?.wait()
            if let resumeError { throw resumeError }
            return .object(["session_id": .string("runtime-1"), "session_key": .string(resumedSessionID), "running": .bool(false)])
        case "session.status":
            return .object(["output": .string("Agent Running: No")])
        case "config.get":
            return .object(["value": .string("medium"), "display": .string("show")])
        case "file.attach":
            await stageGate?.wait()
            if let stageError { throw stageError }
            return .object(["attached": .bool(true), "name": .string("notes.txt"), "ref_text": .string("@file:attachments/notes.txt")])
        case "prompt.submit":
            await promptGate?.wait()
            if let promptError = lock.withLock({ self.promptError }) { throw promptError }
            return .object(["status": .string("streaming")])
        default:
            return .object([:])
        }
    }
}

@MainActor
private final class LocalSendNoopActivityManager: AgentLiveActivityManaging {
    func start(sessionID: String, sessionTitle: String, streamID: String?) {}
    func update(_ event: AgentLiveActivityEvent) {}
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}

private final class LocalSendAttachmentMarkerStore: DirectGatewayAttachmentRecoveryMarkerStoreProtocol {
    private var markers: [DirectGatewayAttachmentRecoveryMarker] = []
    func load(for identity: DirectGatewayAttachmentRecoveryIdentity) throws -> DirectGatewayAttachmentRecoveryMarker? {
        markers.first { $0.identity == identity }
    }
    func write(_ marker: DirectGatewayAttachmentRecoveryMarker) throws {
        markers.removeAll { $0.identity == marker.identity }
        markers.append(marker)
    }
    func remove(_ marker: DirectGatewayAttachmentRecoveryMarker) throws {
        markers.removeAll { $0.identity == marker.identity && $0.token == marker.token }
    }
}
