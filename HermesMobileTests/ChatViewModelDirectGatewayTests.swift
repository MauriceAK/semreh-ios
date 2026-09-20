import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class ChatViewModelDirectGatewayTests: APIClientTestCase {
    func testColdIdleLoadRequestsCurrentContextUsageSnapshot() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setUsageResponse(.object([
            "input": .number(800),
            "output": .number(200),
            "context_used": .number(12_345),
            "context_max": .number(128_000)
        ]))
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeDirectBlockingTestClient(),
            runtime: runtime,
            sessionID: "durable-1"
        )

        await vm.loadMessages()
        await waitUntil { vm.contextWindowSnapshot?.lastPromptTokens == 12_345 }

        XCTAssertEqual(fake.calls().filter { $0.method == "session.usage" }.count, 1)
        XCTAssertEqual(vm.contextWindowSnapshot?.lastPromptTokens, 12_345)
        XCTAssertEqual(vm.contextWindowSnapshot?.contextLength, 128_000)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testStalledContextUsageDoesNotHoldChatReadiness() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setUsageResponse(.object([
            "input": .number(800),
            "output": .number(200),
            "context_used": .number(12_345),
            "context_max": .number(128_000)
        ]))
        let usageGate = ChatDirectAsyncGate()
        fake.setUsageGate(usageGate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeDirectBlockingTestClient(),
            runtime: runtime,
            sessionID: "durable-1"
        )

        let load = Task { @MainActor in await vm.loadMessages() }
        await waitUntil { fake.calls().contains { $0.method == "session.usage" } }
        await waitUntil { !vm.isLoading }

        XCTAssertFalse(vm.isEstablishingConnection)
        XCTAssertNil(vm.contextWindowSnapshot)

        await usageGate.release()
        await load.value
        await waitUntil { vm.contextWindowSnapshot?.lastPromptTokens == 12_345 }
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testStaleContextUsageFromReloadCannotOverwriteNewerSnapshot() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setUsageResponse(.object([
            "input": .number(100),
            "output": .number(10),
            "context_used": .number(100),
            "context_max": .number(128_000)
        ]))
        let staleUsageGate = ChatDirectAsyncGate()
        fake.setUsageGate(staleUsageGate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeDirectBlockingTestClient(),
            runtime: runtime,
            sessionID: "durable-1"
        )

        let firstLoad = Task { @MainActor in await vm.loadMessages() }
        await waitUntil { fake.calls().filter { $0.method == "session.usage" }.count == 1 }
        await firstLoad.value

        fake.setUsageResponse(.object([
            "input": .number(900),
            "output": .number(90),
            "context_used": .number(900),
            "context_max": .number(128_000)
        ]))
        fake.setUsageGate(nil)
        await vm.loadMessages()
        await waitUntil { vm.contextWindowSnapshot?.lastPromptTokens == 900 }

        // The cancelled first request may still return from a transport that
        // does not interrupt an in-flight receive. Its old snapshot is stale.
        await staleUsageGate.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.contextWindowSnapshot?.lastPromptTokens, 900)

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBackgroundTasksCompleteInterleavedAndStatusTracksPendingCount() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeDirectBlockingTestClient(), runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "background"))
        let status = try XCTUnwrap(SlashCommandCatalog.command(named: "status"))

        guard case .executed(let firstNotice) = await vm.executeSlashCommand(command, args: "First audit"),
              case .executed = await vm.executeSlashCommand(command, args: "Second audit") else {
            return XCTFail("Expected both direct background starts")
        }
        XCTAssertEqual(firstNotice, "Background task started. I'll add the result here when it completes.")
        guard case .executed(let pendingStatus) = await vm.executeSlashCommand(status) else {
            return XCTFail("Expected status")
        }
        XCTAssertTrue(pendingStatus?.contains("Background tasks: 2") == true)

        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "background.complete", sequence: 1,
            payload: ["task_id": .string("background-2"), "text": .string("error: opaque second result")]))
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "background.complete", sequence: 2,
            payload: ["task_id": .string("background-1"), "text": .string("First result")]))
        await waitUntil { vm.messages.filter { $0.content?.contains("**Background**") == true }.count == 2 }
        let cards = vm.messages.compactMap(\.content).filter { $0.contains("**Background**") }
        XCTAssertEqual(cards, [
            "**Background** Second audit\n\nerror: opaque second result",
            "**Background** First audit\n\nFirst result",
        ])
        guard case .executed(let completedStatus) = await vm.executeSlashCommand(status) else {
            return XCTFail("Expected completed status")
        }
        XCTAssertTrue(completedStatus?.contains("Background tasks: 0") == true)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.background" }.count, 2)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBackgroundCompletionBufferedBeforeAcknowledgementReturns() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setBackgroundGate(gate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeDirectBlockingTestClient(), runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "background"))

        let request = Task { await vm.executeSlashCommand(command, args: "Fast task") }
        await waitUntil { fake.calls().contains { $0.method == "prompt.background" } }
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "background.complete", sequence: 1,
            payload: ["task_id": .string("background-1"), "text": .string("Fast answer")]))
        await gate.release()
        guard case .executed = await request.value else { return XCTFail("Expected background start") }
        await waitUntil { vm.messages.contains { $0.content == "**Background** Fast task\n\nFast answer" } }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.background" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBackgroundBufferedCloseAfterAcknowledgementReturnsUnknownNotStarted() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setBackgroundGate(gate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeDirectBlockingTestClient(), runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "background"))

        let request = Task { await vm.executeSlashCommand(command, args: "Close at ACK") }
        await waitUntil { fake.calls().contains { $0.method == "prompt.background" } }
        fake.emitClosed()
        await gate.release()

        guard case .unsupported(let message) = await request.value else {
            return XCTFail("A buffered close must not report that the background task started")
        }
        XCTAssertTrue(message.contains("Check Hermes"))
        XCTAssertEqual(vm.messages.filter {
            $0.content == "**Background** Close at ACK\n\nOutcome unknown. Check Hermes before starting it again."
        }.count, 1)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.background" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBackgroundUnknownClearsPendingCountAndNeverRetries() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setBlockingError("prompt.background", .transport("fixture lost acknowledgement"))
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeDirectBlockingTestClient(), runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "background"))
        let status = try XCTUnwrap(SlashCommandCatalog.command(named: "status"))

        guard case .unsupported(let message) = await vm.executeSlashCommand(command, args: "Uncertain task") else {
            return XCTFail("Expected explicit unknown outcome")
        }
        XCTAssertTrue(message.contains("Check Hermes"))
        XCTAssertTrue(vm.messages.contains {
            $0.content == "**Background** Uncertain task\n\nOutcome unknown. Check Hermes before starting it again."
        })
        guard case .executed(let text) = await vm.executeSlashCommand(status) else { return XCTFail("Expected status") }
        XCTAssertTrue(text?.contains("Background tasks: 0") == true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.background" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBackgroundInvalidationMarksEveryPendingAttemptUnknownWithoutRetry() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setBackgroundGate(gate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeDirectBlockingTestClient(), runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "background"))

        let request = Task { await vm.executeSlashCommand(command, args: "Interrupted task") }
        await waitUntil { fake.calls().contains { $0.method == "prompt.background" } }
        vm.invalidateDirectConversation()
        await gate.release()
        guard case .unsupported = await request.value else { return XCTFail("Expected invalidated start refusal") }
        XCTAssertTrue(vm.messages.contains {
            $0.content == "**Background** Interrupted task\n\nOutcome unknown. Check Hermes before starting it again."
        })
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.background" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBackgroundCardSurvivesScopedRefreshButNotCanonicalChange() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            let requestCount = requests.values().count
            let changed = requestCount > 2
            let sessionID = changed ? "different-tip" : "durable-1"
            let messages: String
            if changed {
                messages = #"[{"id":10,"role":"assistant","content":"Different canonical history"}]"#
            } else if requestCount == 2 {
                messages = #"[{"id":9,"role":"assistant","content":"Scoped canonical refresh"}]"#
            } else {
                messages = "[]"
            }
            let returned = messages == "[]" ? 0 : 1
            return apiTestJSONResponse("{\"session_id\":\"\(sessionID)\",\"messages\":\(messages),\"pagination\":{\"limit\":120,\"offset\":0,\"order\":\"latest\",\"returned\":\(returned)}}", for: request)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "background"))
        guard case .executed = await vm.executeSlashCommand(command, args: "Scoped task") else {
            return XCTFail("Expected background start")
        }
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "background.complete", sequence: 1,
            payload: ["task_id": .string("background-1"), "text": .string("Scoped result")]))
        await waitUntil { vm.messages.contains { $0.content?.contains("Scoped result") == true } }

        fake.emitCompletion(sequence: 2)
        await waitUntil { vm.messages.contains { $0.content == "Scoped canonical refresh" } }
        XCTAssertTrue(vm.messages.contains { $0.content?.contains("Scoped result") == true })
        await vm.loadMessages()
        await waitUntil { vm.messages.contains { $0.content == "Different canonical history" } }
        XCTAssertFalse(vm.messages.contains { $0.content?.contains("Scoped result") == true })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBtwRendersCompletionBufferedBeforeAcknowledgementReturns() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setBtwGate(gate)
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            let messages = requests.values().count == 1
                ? "[]"
                : #"[{"id":9,"role":"assistant","content":"Reconciled canonical history"}]"#
            return apiTestJSONResponse("{\"session_id\":\"durable-1\",\"messages\":\(messages),\"pagination\":{\"limit\":120,\"offset\":0,\"order\":\"latest\",\"returned\":1}}", for: request)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "btw"))

        let request = Task { await vm.executeSlashCommand(command, args: "What changed?") }
        await waitUntil { fake.calls().contains { $0.method == "prompt.btw" } }
        XCTAssertTrue(vm.messages.contains { $0.role == "local_assistant" && $0.content?.contains("**BTW** What changed?") == true && $0.content?.contains("...") == true })

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1", type: "btw.complete", sequence: 1,
            payload: ["task_id": .string("btw-1"), "question": .string("What changed?"), "text": .string("Only the direct transport.")]
        ))
        await gate.release()
        guard case .executed = await request.value else { return XCTFail("Expected direct BTW dispatch") }
        await waitUntil { vm.messages.contains { $0.content?.contains("Only the direct transport.") == true } }

        // A terminal refresh scheduled after the controller becomes idle must
        // not erase the history-independent local BTW card.
        fake.emitCompletion(sequence: 2)
        await waitUntil { vm.messages.contains { $0.content == "Reconciled canonical history" } }
        XCTAssertTrue(vm.messages.contains { $0.content?.contains("Only the direct transport.") == true })

        let call = try XCTUnwrap(fake.calls().first { $0.method == "prompt.btw" })
        XCTAssertEqual(fields(call.params)?["text"], .string("What changed?"))
        XCTAssertEqual(fields(call.params)?["profile"], .string("work"))
        XCTAssertFalse(vm.messages.contains { $0.content?.contains("...") == true })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBtwUnknownOutcomeStopsSpinnerWithoutAutomaticRetry() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setBlockingError("prompt.btw", .transport("fixture lost acknowledgement"))
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeDirectBlockingTestClient(), runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "btw"))

        let result = await vm.executeSlashCommand(command, args: "Did this run?")
        guard case .unsupported = result else { return XCTFail("Expected explicit unknown outcome") }
        await waitUntil { vm.messages.contains { $0.content?.contains("Outcome unknown") == true } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.btw" }.count, 1)
        XCTAssertFalse(vm.messages.contains { $0.content?.contains("...") == true })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBtwCardDoesNotCarryAcrossCanonicalConversationChange() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            let first = requests.values().count == 1
            let sessionID = first ? "durable-1" : "different-tip"
            let messages = first ? "[]" : #"[{"id":10,"role":"assistant","content":"Different canonical history"}]"#
            return apiTestJSONResponse("{\"session_id\":\"\(sessionID)\",\"messages\":\(messages),\"pagination\":{\"limit\":120,\"offset\":0,\"order\":\"latest\",\"returned\":1}}", for: request)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "btw"))

        guard case .executed = await vm.executeSlashCommand(command, args: "Scoped?") else {
            return XCTFail("Expected direct BTW dispatch")
        }
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1", type: "btw.complete", sequence: 1,
            payload: ["task_id": .string("btw-1"), "question": .string("Scoped?"), "text": .string("Original conversation only.")]
        ))
        await waitUntil { vm.messages.contains { $0.content?.contains("Original conversation only.") == true } }

        fake.emitCompletion(sequence: 2)
        await waitUntil { vm.messages.contains { $0.content == "Different canonical history" } }
        XCTAssertFalse(vm.messages.contains { $0.content?.contains("Original conversation only.") == true })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBtwAllowsOnlyOneActiveSideQuestion() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setBtwGate(gate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeDirectBlockingTestClient(), runtime: runtime, sessionID: "durable-1")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "btw"))

        let first = Task { await vm.executeSlashCommand(command, args: "First?") }
        await waitUntil { fake.calls().filter { $0.method == "prompt.btw" }.count == 1 }
        let second = await vm.executeSlashCommand(command, args: "Second?")
        guard case .unsupported(let message) = second else { return XCTFail("Expected active BTW refusal") }
        XCTAssertTrue(message.contains("current /btw"))
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.btw" }.count, 1)

        await gate.release()
        _ = await first.value
        vm.invalidateDirectConversation()
        XCTAssertFalse(vm.messages.contains { $0.content?.contains("...") == true })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testQueuedMessageDrainsOnceAfterAuthoritativeDirectCompletion() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { request in
            guard request.httpMethod == "GET",
                  request.url?.path == "/api/sessions/durable-1/messages" else {
                XCTFail("Unexpected queue reconciliation request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "profile" }?.value, "work")
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":[{"id":1,"role":"user","content":"Original turn"},{"id":2,"role":"assistant","content":"First answer"}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#,
                for: request
            )
        }, runtime: runtime, sessionID: nil)

        let accepted = await vm.sendMessage("Original turn")
        XCTAssertTrue(accepted)
        await waitUntil { vm.activeStreamID != nil && vm.hasStreamingAssistantMessageContent }

        let queued = await vm.submitStreamingMessage("Queued next turn", behavior: .queue)
        guard case .executed(let message) = queued else {
            XCTFail("Expected queue acknowledgement")
            return
        }
        XCTAssertTrue(message?.contains("#1") == true)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "message.complete",
            sequence: 3,
            payload: ["text": .string("First answer"), "status": .string("complete")]
        ))

        await waitUntil {
            fake.calls().filter { $0.method == "prompt.submit" }.count == 2
                && vm.messages.filter { $0.role == "user" }.map(\.content)
                    == ["Original turn", "Queued next turn"]
        }
        let submits = fake.calls().filter { $0.method == "prompt.submit" }
        XCTAssertEqual(fields(submits[1].params)?["text"], .string("Queued next turn"))
        XCTAssertEqual(vm.messages.filter { $0.role == "user" }.map(\.content),
                       ["Original turn", "Queued next turn"])
        XCTAssertTrue(vm.messages.contains { $0.role == "assistant" && $0.content == "First answer" })
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 2)

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testFailedDirectQueueDrainAttemptsOnceRetainsTextAndWaitsForExplicitTrigger() async throws {
        for failingMethod in ["session.create", "prompt.submit"] {
            let fake = ChatDirectFakeTransport()
            fake.setEmitsPromptEvents(false)
            fake.setBlockingError(failingMethod, .server(code: 4009,
                message: "fixture busy before dispatch", data: nil, method: failingMethod,
                requestID: "fixture-rejection", server: nil))
            let runtime = try makeRuntime(fake)
            let vm = makeViewModel(client: makeClient { request in
                // A runtime created before prompt rejection has a durable ID.
                // Its explicit retry can resume and reconcile the stock tail.
                guard request.httpMethod == "GET", request.url?.path == "/api/sessions/durable-1/messages" else {
                    XCTFail("Unexpected queue REST request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "profile" }?.value, "work")
                return apiTestJSONResponse(#"{"session_id":"durable-1","messages":[],"pagination":{"limit":120,"offset":0,"order":"latest","returned":0}}"#, for: request)
            }, runtime: runtime, sessionID: nil)
            // Exercise the retained queue entry/drain callbacks with a real
            // direct-owned VM, not the legacy renderer setup seam.
            XCTAssertEqual(vm.enqueueMessageForTesting("Keep the queued text"), 1)
            vm.drainQueuedMessagesForTesting()
            await waitUntil { vm.sendErrorMessage != nil }
            // A failure-driven recursive drain would issue more RPCs during
            // this bounded quiescence window, even with synchronous mock errors.
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(fake.calls().filter { $0.method == failingMethod }.count, 1)
            let statusCommand = try XCTUnwrap(SlashCommandCatalog.command(named: "status"))
            let status = await vm.executeSlashCommand(statusCommand)
            guard case .executed(let text) = status else { return XCTFail("Expected queue status") }
            XCTAssertTrue(text?.contains("Queued messages: 1") == true)

            fake.setBlockingError(failingMethod, nil)
            vm.drainQueuedMessagesForTesting()
            await waitUntil { vm.messages.contains { $0.role == "user" && $0.content == "Keep the queued text" } && !vm.isStartingChat }
            let submits = fake.calls().filter { $0.method == "prompt.submit" }
            XCTAssertEqual(submits.count, failingMethod == "prompt.submit" ? 2 : 1)
            XCTAssertEqual(fields(submits.last?.params)?["text"], .string("Keep the queued text"))
            let finalStatus = await vm.executeSlashCommand(statusCommand)
            guard case .executed(let finalText) = finalStatus else { return XCTFail("Expected final queue status") }
            XCTAssertTrue(finalText?.contains("Queued messages: 0") == true)
            await vm.disposeDirectConversation()
            await runtime.stop()
        }
    }

    func testOrdinarySendTrimsTextAndAddsExactlyOneOptimisticUserWithoutWebUI() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { _ in
            XCTFail("A draft send must not use WebUI REST")
            throw URLError(.badURL)
        }, runtime: runtime, sessionID: nil)
        let accepted = await vm.sendMessage("  Keep working  ")
        XCTAssertTrue(accepted)
        XCTAssertEqual(vm.messages.filter { $0.role == "user" }.map(\.content), ["Keep working"])
        let submit = try XCTUnwrap(fake.calls().first { $0.method == "prompt.submit" })
        XCTAssertEqual(fields(submit.params)?["text"], .string("Keep working"))
        XCTAssertEqual(fields(submit.params)?["profile"], .string("work"))
        XCTAssertEqual(fields(submit.params)?["session_id"], .string("runtime-1"))
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectSelectedModelSurvivesDefiniteCreateFailureAndExplicitRetry() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
                               runtime: runtime, sessionID: nil)
        await vm.loadComposerConfiguration()
        let option = try XCTUnwrap(vm.modelCatalogGroups.first?.models.last)
        let selected = await vm.selectComposerModel(option)
        XCTAssertTrue(selected)
        fake.setBlockingError("session.create", .transport("fixture refused before creation"))
        let first = await vm.sendMessage("First explicit attempt")
        XCTAssertFalse(first)
        XCTAssertEqual(vm.selectedModelID, option.id)
        XCTAssertEqual(vm.selectedModelProviderID, option.providerID)
        fake.setBlockingError("session.create", nil)
        let retry = await vm.sendMessage("User explicitly retried")
        XCTAssertTrue(retry)
        let creates = fake.calls().filter { $0.method == "session.create" }
        XCTAssertEqual(creates.count, 2)
        for create in creates {
            XCTAssertEqual(fields(create.params)?["model"], .string(option.id))
            XCTAssertEqual(fields(create.params)?["provider"], .string(try XCTUnwrap(option.providerID)))
            XCTAssertNil(fields(create.params)?["explicit_model_pick"], "WebUI flags are not direct contracts")
        }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testSceneActivationDuringDirectSubmitAcknowledgementPreservesNewResponse() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setPromptSubmitGate(gate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { _ in
            XCTFail("An active submit must not reload a stale REST tail")
            throw URLError(.badURL)
        }, runtime: runtime, sessionID: nil)
        let sending = Task { await vm.sendMessage("New local prompt") }
        await waitUntil { vm.isStartingChat && vm.hasStreamingAssistantMessageContent }
        let rows = vm.messages
        let anchor = vm.streamingAssistantMessageID
        await vm.refreshAfterSceneActivation()
        XCTAssertEqual(vm.messages, rows)
        XCTAssertEqual(vm.streamingAssistantMessageID, anchor)
        await gate.release()
        let accepted = await sending.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(vm.messages.filter { $0.role == "user" }.map(\.content), ["New local prompt"])
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testOrdinarySendDefiniteCreateFailureRollsBackWithoutTunnelBlameOrLegacyFallback() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setBlockingError("session.create", .transport("fixture connection unavailable"))
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { _ in
            XCTFail("A failed direct send must not use WebUI")
            throw URLError(.badURL)
        }, runtime: runtime, sessionID: nil)
        let accepted = await vm.sendMessage("Keep working")
        XCTAssertFalse(accepted)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertNotNil(vm.sendErrorMessage)
        XCTAssertFalse(vm.sendErrorMessage?.contains("hermes-webui") == true)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testOrdinarySendInvalidAcknowledgementRetainsUncertaintyInsteadOfUnsafeRollback() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setPromptSubmitResponse(.object([:]))
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { _ in throw URLError(.badURL) }, runtime: runtime, sessionID: nil)
        _ = await vm.sendMessage("Keep uncertain text")
        XCTAssertEqual(vm.messages.filter { $0.role == "user" }.map(\.content), ["Keep uncertain text"])
        XCTAssertTrue(vm.directConversationHasPromptDeliveryUncertainty)
        let again = await vm.sendMessage("Do not automatically retry")
        XCTAssertFalse(again)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testVoiceNoteTranscribesStagesOnlyItsClipAndSubmitsOnce() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/audio/transcribe")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "profile" }?.value, "work")
            return apiTestJSONResponse(#"{"ok":true,"transcript":"Spoken request"}"#, for: request)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: nil)
        await vm.uploadAttachment(data: Data("draft".utf8), filename: "draft.txt")
        let draftID = try XCTUnwrap(vm.directPendingAttachments.first?.id)

        let accepted = await vm.sendVoiceNote(audioData: Data("recording".utf8), filename: "voice.m4a")

        XCTAssertTrue(accepted)
        XCTAssertFalse(vm.isSendingVoiceNote)
        XCTAssertEqual(vm.directPendingAttachments.map(\.id), [draftID])
        XCTAssertEqual(fake.calls().map(\.method), ["session.create", "file.attach", "prompt.submit"])
        let file = try XCTUnwrap(fake.calls().first { $0.method == "file.attach" })
        XCTAssertEqual(fields(file.params)?["name"], .string("voice.m4a"))
        let submit = try XCTUnwrap(fake.calls().first { $0.method == "prompt.submit" })
        XCTAssertTrue(fields(submit.params)?["text"]?.gatewayString?.hasPrefix("Spoken request\n@file:") == true)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testVoiceNoteTranscriptionFailurePreservesDraftAndDoesNotStage() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/audio/transcribe")
            return apiTestJSONResponse(#"{"ok":false,"error":"STT unavailable"}"#, for: request)
        }, runtime: runtime, sessionID: nil)
        await vm.uploadAttachment(data: Data("draft".utf8), filename: "draft.txt")
        let ids = vm.directPendingAttachments.map(\.id)

        let accepted = await vm.sendVoiceNote(audioData: Data("recording".utf8), filename: "voice.m4a")
        XCTAssertFalse(accepted)
        XCTAssertEqual(vm.directPendingAttachments.map(\.id), ids)
        XCTAssertTrue(fake.calls().isEmpty)
        XCTAssertFalse(vm.isSendingVoiceNote)
        await runtime.stop()
    }

    func testVoiceNoteStageFailurePreservesVoiceAndDraftWithoutPrompt() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setAttachmentError("file.attach", .server(code: 4015, message: "rejected", data: nil,
            method: "file.attach", requestID: "voice-stage", server: nil))
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { request in
            apiTestJSONResponse(#"{"ok":true,"transcript":"Spoken request"}"#, for: request)
        }, runtime: runtime, sessionID: nil)
        await vm.uploadAttachment(data: Data("draft".utf8), filename: "draft.txt")

        let accepted = await vm.sendVoiceNote(audioData: Data("recording".utf8), filename: "voice.m4a")
        XCTAssertFalse(accepted)
        XCTAssertEqual(vm.directPendingAttachments.map(\.displayFilename), ["draft.txt", "voice.m4a"])
        XCTAssertEqual(fake.calls().map(\.method), ["session.create", "file.attach"])
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testVoiceNoteAmbiguousPromptPreservesAttachmentsAndNeverResends() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setPromptSubmitResponse(.object([:]))
        let runtime = try makeRuntime(fake)
        var transcriptionRequests = 0
        let vm = makeViewModel(client: makeClient { request in
            transcriptionRequests += 1
            return apiTestJSONResponse(#"{"ok":true,"transcript":"Spoken request"}"#, for: request)
        }, runtime: runtime, sessionID: nil)
        await vm.uploadAttachment(data: Data("draft".utf8), filename: "draft.txt")

        let accepted = await vm.sendVoiceNote(audioData: Data("recording".utf8), filename: "voice.m4a")
        XCTAssertTrue(accepted)
        XCTAssertTrue(vm.directConversationHasPromptDeliveryUncertainty)
        XCTAssertEqual(vm.directPendingAttachments.map(\.displayFilename), ["draft.txt", "voice.m4a"])
        let retry = await vm.sendVoiceNote(audioData: Data("retry".utf8), filename: "retry.m4a")
        XCTAssertFalse(retry)
        XCTAssertEqual(transcriptionRequests, 1)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testVoiceNoteActiveRunRefusesBeforeTranscription() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        var transcriptionRequests = 0
        let vm = makeViewModel(client: makeClient { request in
            transcriptionRequests += 1
            XCTFail("Active direct run must refuse voice before STT: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }, runtime: runtime, sessionID: nil)
        let started = await vm.sendMessage("Already running")
        XCTAssertTrue(started)
        await waitUntil { vm.activeStreamID != nil }

        let accepted = await vm.sendVoiceNote(audioData: Data("recording".utf8), filename: "voice.m4a")

        XCTAssertFalse(accepted)
        XCTAssertEqual(transcriptionRequests, 0)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectDuplicateAttachmentNamesKeepIndependentSelectionsAndStageEachOnce() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { _ in throw URLError(.badURL) }, runtime: runtime, sessionID: nil)
        await vm.uploadAttachment(data: Data("one".utf8), filename: "same.txt")
        await vm.uploadAttachment(data: Data("two".utf8), filename: "same.txt")
        XCTAssertEqual(vm.directPendingAttachments.count, 2)
        XCTAssertEqual(Set(vm.directPendingAttachments.map(\.id)).count, 2)
        let accepted = await vm.sendMessage("Compare these")
        XCTAssertTrue(accepted)
        XCTAssertEqual(fake.calls().filter { $0.method == "file.attach" }.count, 2)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        XCTAssertTrue(vm.directPendingAttachments.isEmpty)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testPromptUncertaintyMarkerWriteFailureIsDefiniteNondispatch() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let store = InMemoryDirectPromptDeliveryUncertaintyStore()
        store.failWrite = true
        let vm = makeViewModel(
            client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
            runtime: runtime,
            sessionID: "durable-1",
            promptUncertaintyStore: store
        )
        await vm.loadMessages()

        let sent = await vm.sendMessage("keep this draft")

        XCTAssertFalse(sent)
        XCTAssertFalse(vm.messages.contains { $0.role == "user" && $0.content == "keep this draft" })
        XCTAssertTrue(fake.calls().filter { $0.method == "prompt.submit" }.isEmpty)
        XCTAssertEqual(
            vm.sendErrorMessage,
            "Semreh could not save the delivery safety state, so the message was not sent. Your draft was kept."
        )

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDefinitePromptRejectionCleanupFailurePreservesDraftSemantics() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setBlockingError("prompt.submit", .server(
            code: 4001,
            message: "rejected",
            data: nil,
            method: "prompt.submit",
            requestID: "rejected-request",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        let store = InMemoryDirectPromptDeliveryUncertaintyStore()
        store.failRemove = true
        let vm = makeViewModel(
            client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
            runtime: runtime,
            sessionID: "durable-1",
            promptUncertaintyStore: store
        )
        await vm.loadMessages()

        let sent = await vm.sendMessage("rejected draft")

        XCTAssertFalse(sent)
        XCTAssertFalse(vm.messages.contains { $0.role == "user" && $0.content == "rejected draft" })
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        XCTAssertEqual(
            vm.sendErrorMessage,
            "Semreh could not save the delivery safety state, so the message was not sent. Your draft was kept."
        )
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testAcknowledgedPromptCleanupFailureUsesConfirmedAcceptancePresentation() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let store = InMemoryDirectPromptDeliveryUncertaintyStore()
        store.failRemove = true
        let vm = makeViewModel(
            client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
            runtime: runtime,
            sessionID: "durable-1",
            promptUncertaintyStore: store
        )
        await vm.loadMessages()

        let sent = await vm.sendMessage("accepted message")

        XCTAssertTrue(sent)
        XCTAssertTrue(vm.directConversationHasPromptDeliveryUncertainty)
        XCTAssertTrue(vm.directPromptDeliveryHasConfirmedAcceptance)
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "message.complete",
            sequence: 3,
            payload: ["text": .string("accepted answer")]
        ))
        await waitUntil {
            vm.sendErrorMessage == "Hermes accepted the previous message, but Semreh could not clear its local safety record. It was not resent."
        }
        XCTAssertEqual(
            vm.sendErrorMessage,
            "Hermes accepted the previous message, but Semreh could not clear its local safety record. It was not resent."
        )
        XCTAssertNotNil(vm.directPromptDeliveryRecoveryTarget)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testReopenedPromptUncertaintyRequiresExplicitCanonicalIdleAbandonBeforeFreshSend() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let store = InMemoryDirectPromptDeliveryUncertaintyStore()
        let identity = try DirectPromptDeliveryUncertaintyIdentity(
            origin: testServer,
            profile: "work",
            storedID: "durable-1"
        )
        let marker = DirectPromptDeliveryUncertaintyMarker(identity: identity)
        try store.write(marker)
        let vm = makeViewModel(
            client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
            runtime: runtime,
            sessionID: "durable-1",
            promptUncertaintyStore: store
        )

        await vm.loadMessages()
        XCTAssertTrue(vm.directConversationHasPromptDeliveryUncertainty)
        let target = try XCTUnwrap(vm.directPromptDeliveryRecoveryTarget)
        XCTAssertEqual(target.markerToken, marker.token)
        let blockedSend = await vm.sendMessage("blocked fresh message")
        XCTAssertFalse(blockedSend)
        XCTAssertTrue(fake.calls().filter { $0.method == "prompt.submit" }.isEmpty)

        store.failRemove = true
        let firstAbandon = await vm.abandonDirectPromptDeliveryUncertainty(target)
        XCTAssertFalse(firstAbandon)
        XCTAssertEqual(
            vm.sendErrorMessage,
            "The latest conversation could not be checked. The previous message may still appear, and no message was resent."
        )
        store.failRemove = false
        let abandoned = await vm.abandonDirectPromptDeliveryUncertainty(target)
        XCTAssertTrue(abandoned)
        XCTAssertFalse(vm.directConversationHasPromptDeliveryUncertainty)
        XCTAssertNil(vm.sendErrorMessage)
        XCTAssertNil(try store.load(for: identity))
        let freshSend = await vm.sendMessage("different fresh message")
        XCTAssertTrue(freshSend)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testReopenedDirectAttachmentRecoveryBlocksNewUploadUntilExplicitReset() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setSessionCloseResponse(.object(["closed": .bool(true)]))
        fake.setResumeResponseAfterSessionClose(.object([
            "session_id": .string("runtime-2"),
            "session_key": .string("durable-1")
        ]))
        let runtime = try makeRuntime(fake)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatViewModelDirectAttachmentRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markerStore = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let identity = try DirectGatewayAttachmentRecoveryIdentity(
            origin: testServer,
            profile: "work",
            storedID: "durable-1",
            runtimeID: "runtime-1"
        )
        try markerStore.write(DirectGatewayAttachmentRecoveryMarker(identity: identity))

        let vm = makeViewModel(
            client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
            runtime: runtime,
            sessionID: "durable-1",
            recoveryMarkerStore: markerStore
        )
        await vm.loadMessages()

        XCTAssertTrue(vm.attachmentRecoveryNeedsReset)
        XCTAssertTrue(vm.directPendingAttachments.isEmpty)
        await vm.uploadAttachment(data: directPNGData, filename: "blocked.png")
        XCTAssertTrue(vm.directPendingAttachments.isEmpty)
        XCTAssertTrue(vm.uploadAttachmentErrorMessage?.contains("unresolved") == true)

        let target = try XCTUnwrap(vm.directAttachmentRecoveryTarget)
        XCTAssertEqual(target.server, testServer)
        XCTAssertEqual(target.sessionID, "durable-1")
        XCTAssertEqual(target.runtimeID, "runtime-1")
        let didReset = await vm.resetDirectAttachmentRecovery(target)
        XCTAssertTrue(didReset)
        XCTAssertFalse(vm.attachmentRecoveryNeedsReset)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.close" }.count, 1)

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectComposerLoadsProfileInventoryAndStagesDraftChoicesUntilFirstSend() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/api/model/options" {
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "profile" }?.value, "work")
                XCTAssertEqual(query?.first { $0.name == "explicit_only" }?.value, "true")
                return apiTestJSONResponse(#"{"model":"model-a","provider":"fixture","providers":[{"slug":"fixture","name":"Fixture","authenticated":true,"models":["model-a","model-b","model-b"],"capabilities":{"model-a":{"reasoning":false},"model-b":{"reasoning":true,"can_disable_reasoning":false}}},{"slug":"unconfigured","authenticated":false,"models":["hidden"]}]}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/profiles")
            return apiTestJSONResponse(#"{"profiles":[{"name":"work"}],"active":"default"}"#, for: request)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: nil)
        await vm.loadComposerConfiguration()
        XCTAssertEqual(vm.selectedModelID, "model-a")
        XCTAssertEqual(vm.selectedModelProviderID, "fixture")
        XCTAssertEqual(vm.selectedProfileName, "work")
        XCTAssertFalse(vm.showsReasoningEffortControl)
        XCTAssertEqual(vm.modelCatalogGroups.count, 1)
        XCTAssertEqual(vm.modelCatalogGroups.first?.models.count, 2)
        XCTAssertTrue(fake.calls().isEmpty, "Configuration must not pre-create a runtime")
        let option = try XCTUnwrap(vm.modelCatalogGroups.first?.models.last)
        let selected = await vm.selectComposerModel(option)
        XCTAssertTrue(selected)
        XCTAssertTrue(vm.showsReasoningEffortControl)
        XCTAssertFalse(vm.supportedReasoningEfforts?.contains("none") ?? true)
        let inherited = await vm.selectReasoningEffort("inherit")
        XCTAssertTrue(inherited)
        XCTAssertEqual(vm.selectedReasoningSelection, "inherit")
        XCTAssertTrue(fake.calls().isEmpty, "Draft inheritance remains local and must not create a runtime")
        let invalidEffort = await vm.selectReasoningEffort("none")
        XCTAssertFalse(invalidEffort)
        let selectedEffort = await vm.selectReasoningEffort("high")
        XCTAssertTrue(selectedEffort)
        XCTAssertTrue(fake.calls().isEmpty)
        let sent = await vm.sendMessage("hello")
        XCTAssertTrue(sent)
        let create = try XCTUnwrap(fake.calls().first)
        XCTAssertEqual(create.method, "session.create")
        XCTAssertEqual(fields(create.params)?["model"], .string("model-b"))
        XCTAssertEqual(fields(create.params)?["provider"], .string("fixture"))
        XCTAssertEqual(fields(create.params)?["reasoning_effort"], .string("high"))
        XCTAssertEqual(Set(requests.values()), ["/api/model/options", "/api/profiles"])
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectComposerLoadsOnlyDeviceLocalBookmarksForItsProfileWithoutWorkspaceREST() async throws {
        let suite = "ChatViewModelDirectGatewayTests.workspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalOrganizerStore(defaults: defaults)
        try store.addWorkspaceBookmark(path: "/work/scoped", name: "Scoped", server: testServer, profile: "work")
        try store.addWorkspaceBookmark(path: "/work/default", name: nil, server: testServer, profile: "default")

        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            if request.url?.path == "/api/model/options" {
                return apiTestJSONResponse(#"{"model":"model-a","provider":"fixture","providers":[{"slug":"fixture","models":["model-a"]}]}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/profiles")
            return apiTestJSONResponse(#"{"profiles":[{"name":"work"}]}"#, for: request)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: nil, defaults: defaults)

        await vm.loadComposerConfiguration()

        XCTAssertEqual(vm.workspaceOrganizerProfile, "work")
        XCTAssertEqual(vm.workspaceRoots, [WorkspaceRoot(path: "/work/scoped", name: "Scoped")])
        XCTAssertEqual(vm.workspaceSuggestions, ["/work/scoped"])
        XCTAssertEqual(Set(requests.values()), ["/api/model/options", "/api/profiles"])
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectComposerReloadDoesNotOverwriteConcurrentDraftWorkspaceSelection() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let inventoryStarted = expectation(description: "inventory started")
        let releaseInventory = DispatchSemaphore(value: 0)
        let client = makeClient { request in
            if request.url?.path == "/api/model/options" {
                inventoryStarted.fulfill()
                releaseInventory.wait()
                return apiTestJSONResponse(#"{"model":"model-a","provider":"fixture","providers":[{"slug":"fixture","models":["model-a"]}]}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/profiles")
            return apiTestJSONResponse(#"{"profiles":[{"name":"work"}]}"#, for: request)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: nil)
        let load = Task { @MainActor in await vm.loadComposerConfiguration() }
        await fulfillment(of: [inventoryStarted], timeout: 2)

        let selected = await vm.selectWorkspacePath("/draft-choice")
        XCTAssertTrue(selected)
        releaseInventory.signal()
        await load.value

        XCTAssertEqual(vm.selectedWorkspacePath, "/draft-choice")
        XCTAssertTrue(vm.modelCatalogGroups.isEmpty, "A stale configuration result must not partially apply")
        XCTAssertTrue(fake.calls().isEmpty)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectComposerLoadFailurePreservesDraftSelection() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let draft = SessionSummary(
            title: "New Chat",
            workspace: "/draft",
            model: "chosen-model",
            modelProvider: "fixture",
            profile: "work"
        )
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: nil, session: draft)

        await vm.loadComposerConfiguration()

        XCTAssertEqual(vm.selectedWorkspacePath, "/draft")
        XCTAssertEqual(vm.selectedModelID, "chosen-model")
        XCTAssertEqual(vm.selectedModelProviderID, "fixture")
        XCTAssertNotNil(vm.composerConfigurationErrorMessage)
        XCTAssertTrue(fake.calls().isEmpty)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testComposerConfigurationFailureDiagnosticUsesOnlyBoundedClassification() throws {
        XCTAssertEqual(ComposerConfigurationLoadOutcome(error: URLError(.notConnectedToInternet)).rawValue, "network")
        XCTAssertEqual(
            ComposerConfigurationLoadOutcome(error: APIError.http(statusCode: 503, body: "private response contents")).rawValue,
            "http_503_server_error"
        )
        XCTAssertEqual(
            ComposerConfigurationLoadOutcome(error: APIError.decoding(underlying: DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "private payload")
            ))).rawValue,
            "decoding"
        )
        XCTAssertEqual(ComposerConfigurationLoadOutcome(error: CancellationError()).rawValue, "cancelled")
        XCTAssertEqual(
            ComposerConfigurationLoadOutcome(error: APIError.network(underlying: URLError(.cancelled))).rawValue,
            "cancelled"
        )
        XCTAssertEqual(ComposerConfigurationLoadOutcome(error: CocoaError(.fileReadCorruptFile)).rawValue, "other")
    }

    func testDirectComposerFailureBannerIdentifiesSourceWithoutResponseContent() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            if request.url?.path == "/api/model/options" {
                return apiTestJSONResponse(#"{"model":"model-a","provider":"fixture","providers":[]}"#, for: request)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (response, Data("private profile name and response contents".utf8))
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        await vm.loadComposerConfiguration()

        let message = try XCTUnwrap(vm.composerConfigurationErrorMessage)
        XCTAssertEqual(
            message,
            "Hermes chat settings could not be loaded. Your draft was preserved. source=profiles outcome=http_503_server_error has_canonical_session=false profile_scope_present=true"
        )
        XCTAssertFalse(message.contains("private"))
        guard case .http(let statusCode, let body) = vm.lastError as? APIError else {
            return XCTFail("The underlying error must remain available")
        }
        XCTAssertEqual(statusCode, 503)
        XCTAssertEqual(body, "private profile name and response contents")
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testExistingDirectChatLoadsScopedReasoningAndWritesOnlyThroughGateway() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeExistingComposerClient(requests: requests)
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")

        await vm.loadComposerConfiguration()

        XCTAssertEqual(vm.selectedModelID, "model-b", "Stored-chat metadata must win over catalog defaults")
        XCTAssertEqual(vm.selectedModelProviderID, "fixture")
        XCTAssertEqual(vm.selectedProfileName, "work")
        XCTAssertTrue(vm.showsReasoningEffortControl)
        XCTAssertEqual(vm.selectedReasoningEffort, "medium")
        XCTAssertFalse(vm.allowsReasoningInheritance)
        XCTAssertTrue(fake.calls().contains { $0.method == "session.resume" })
        XCTAssertTrue(fake.calls().contains { $0.method == "config.get" })
        XCTAssertFalse(fake.calls().contains { $0.method == "session.create" })
        XCTAssertEqual(Set(requests.values()), ["/api/model/options", "/api/profiles", "/api/sessions/durable-1/messages"])

        let gate = ChatDirectAsyncGate()
        fake.setReasoningSetGate(gate)
        let mutation = Task { await vm.selectReasoningEffort("high") }
        await yieldUntil {
            vm.isUpdatingComposerConfiguration
                && vm.selectedReasoningEffort == "high"
                && fake.calls().contains { $0.method == "config.set" }
        }
        let setCall = try XCTUnwrap(fake.calls().last { $0.method == "config.set" })
        let setFields = try XCTUnwrap(fields(setCall.params))
        XCTAssertEqual(setFields["key"], .string("reasoning"))
        XCTAssertEqual(setFields["value"], .string("high"))
        XCTAssertEqual(setFields["scope"], .string("session"))
        XCTAssertEqual(setFields["session_id"], .string("runtime-1"))
        XCTAssertEqual(setFields["profile"], .string("work"))
        XCTAssertTrue(vm.isUpdatingComposerConfiguration, "The picker must expose the in-flight mutation")
        await gate.release()
        let mutationSucceeded = await mutation.value
        XCTAssertTrue(mutationSucceeded)
        XCTAssertEqual(vm.selectedReasoningEffort, "high")
        XCTAssertFalse(vm.isUpdatingComposerConfiguration)
        XCTAssertFalse(vm.isReasoningChangeDeferred)

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testExistingDirectChatReasoningWriteRollsBackAndOldBackendIsReadOnly() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeExistingComposerClient(requests: requests)
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        await vm.loadComposerConfiguration()
        fake.setReasoningSetFailure(true)

        let failed = await vm.selectReasoningEffort("high")
        XCTAssertFalse(failed)
        XCTAssertEqual(vm.selectedReasoningEffort, "medium", "A failed ack must roll back the optimistic label")
        XCTAssertFalse(vm.isUpdatingComposerConfiguration)
        XCTAssertNotNil(vm.composerConfigurationErrorMessage)
        XCTAssertEqual(fake.calls().filter { $0.method == "config.set" }.count, 1, "Failure must not replay a targeted write")

        await vm.disposeDirectConversation()
        await runtime.stop()

        let oldFake = ChatDirectFakeTransport()
        oldFake.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        oldFake.setReasoningSetResponse(.object([
            "key": .string("reasoning"), "value": .string("high")
        ]))
        oldFake.setUpdatesReasoningReadback(true)
        let oldRuntime = try makeRuntime(oldFake)
        let oldRequests = ChatDirectRequestRecorder()
        let oldClient = makeExistingComposerClient(requests: oldRequests)
        let oldVM = makeViewModel(client: oldClient, runtime: oldRuntime, sessionID: "durable-1")
        await oldVM.loadComposerConfiguration()
        XCTAssertTrue(oldVM.showsReasoningEffortControl, "Stock Hermes reasoning remains configurable without the extension")
        XCTAssertTrue(oldVM.allowsReasoningChangesWhileStreaming)
        let oldSelection = await oldVM.selectReasoningEffort("high")
        XCTAssertTrue(oldSelection)
        XCTAssertEqual(oldVM.selectedReasoningEffort, "high")
        XCTAssertEqual(oldFake.calls().filter { $0.method == "config.set" }.count, 1)
        await oldVM.disposeDirectConversation()
        await oldRuntime.stop()
    }

    func testExistingDirectChatBusyReasoningChangeReportsDeferredAck() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setReasoningSetResponse(.object([
            "key": .string("reasoning"), "value": .string("high"),
            "scope": .string("session"), "deferred": .bool(true), "persisted": .bool(true)
        ]))
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let vm = makeViewModel(client: makeExistingComposerClient(requests: requests), runtime: runtime, sessionID: "durable-1")
        await vm.loadComposerConfiguration()

        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.start", sequence: 9))
        await yieldUntil { vm.activeStreamID != nil }
        XCTAssertTrue(vm.allowsReasoningChangesWhileStreaming)
        let busySelection = await vm.selectReasoningEffort("high")
        XCTAssertTrue(busySelection)
        XCTAssertEqual(vm.selectedReasoningEffort, "high")
        XCTAssertTrue(vm.isReasoningChangeDeferred, "A busy gateway may acknowledge persistence for the next turn")
        XCTAssertFalse(vm.isUpdatingComposerConfiguration)

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testStockDeferredReasoningIgnoresStaleSessionInfoEffort() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        fake.setSessionStatusResponse(.object(["output": .string("Agent Running: Yes")]))
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
            runtime: runtime,
            sessionID: "durable-1"
        )
        await vm.loadComposerConfiguration()

        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.start", sequence: 9))
        await yieldUntil { vm.activeStreamID != nil }
        let selected = await vm.selectReasoningEffort("high")
        XCTAssertTrue(selected)
        XCTAssertEqual(vm.selectedReasoningEffort, "high")
        XCTAssertTrue(vm.isReasoningChangeDeferred)

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "session.info",
            sequence: 10,
            payload: [
                "reasoning_effort": .string("medium"),
                "reasoning_deferred": .bool(false)
            ]
        ))
        await Task.yield()
        XCTAssertEqual(vm.selectedReasoningEffort, "high")
        XCTAssertEqual(vm.sessionReasoningEffort, "high")
        XCTAssertTrue(vm.isReasoningChangeDeferred)

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testFailedReasoningRefreshDisablesPreviouslySupportedControl() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
                               runtime: runtime, sessionID: "durable-1")
        await vm.loadComposerConfiguration()
        XCTAssertTrue(vm.showsReasoningEffortControl)
        fake.setReasoningGetResponse(.object([:]))
        await vm.loadComposerConfiguration()
        XCTAssertFalse(vm.showsReasoningEffortControl)
        XCTAssertFalse(vm.allowsReasoningChangesWhileStreaming)
        XCTAssertNotNil(vm.composerConfigurationErrorMessage)
        let accepted = await vm.selectReasoningEffort("high")
        XCTAssertFalse(accepted)
        XCTAssertFalse(fake.calls().contains { $0.method == "config.set" })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testFirstSendReasoningDiscoveryFailureOffersExplicitReload() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setReasoningGetResponse(.object([:]))
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeClient { _ in
            XCTFail("Post-send capability discovery must not fetch another transcript or legacy setting")
            throw URLError(.badURL)
        }, runtime: runtime, sessionID: nil)
        let sent = await vm.sendMessage("hello")
        XCTAssertTrue(sent)
        await yieldUntil { vm.composerConfigurationErrorMessage != nil }
        XCTAssertTrue(vm.composerConfigurationErrorMessage?.contains("model picker") == true)
        XCTAssertFalse(vm.showsReasoningEffortControl)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.create" }.count, 1)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testExistingDirectChatBeforeConfigurationRejectsMutationsWithoutRPC() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { _ in
            XCTFail("A stored-chat mutation before configuration must not call REST")
            throw URLError(.badURL)
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")

        let model = await vm.selectComposerModel(ModelCatalogOption(id: "new", displayName: "New", providerID: "fixture"))
        let effort = await vm.selectReasoningEffort("high")
        let workspace = await vm.selectWorkspacePath("/disposable")
        XCTAssertFalse(model)
        XCTAssertFalse(effort)
        XCTAssertFalse(workspace)
        XCTAssertTrue(fake.calls().isEmpty)

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectProfileChangeReturnsLocalDraftWithoutRetargetingOriginalChat() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { _ in XCTFail("Profile choice is local"); throw URLError(.badURL) }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        let profile = try JSONDecoder().decode(ProfileSummary.self, from: Data(#"{"name":"other"}"#.utf8))
        let outcome = await vm.switchProfile(profile, startNewSession: true)
        let draft = try XCTUnwrap(outcome?.session)
        XCTAssertNil(draft.sessionId)
        XCTAssertEqual(draft.profile, "other")
        XCTAssertTrue(vm.hasServerBackedSession)
        XCTAssertEqual(vm.selectedProfileTitle, "work")
        XCTAssertTrue(fake.calls().isEmpty)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testSceneActivationDiscoversExternalDirectRunAndRoutesItsEvents() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-1"),
            "session_key": .string("durable-1"),
            "running": .bool(true)
        ]))
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            guard request.url?.path == "/api/sessions/durable-1/messages" else {
                XCTFail("External-run discovery must use direct canonical history")
                throw URLError(.badURL)
            }
            let rows = requests.isTerminalPhase
                ? #"[{"id":1,"role":"user","content":"Work externally","timestamp":1},{"id":3,"role":"assistant","content":"Canonical completed answer","timestamp":3}]"#
                : #"[{"id":1,"role":"user","content":"Work externally","timestamp":1},{"id":2,"role":"assistant","content":"Latest external progress","timestamp":2}]"#
            let body = #"{"session_id":"durable-1","messages":\#(rows),"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#
            _ = try JSONSerialization.jsonObject(with: Data(body.utf8))
            return apiTestJSONResponse(body, for: request)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")

        await viewModel.refreshAfterSceneActivation()

        XCTAssertEqual(requests.values(), ["/api/sessions/durable-1/messages"])
        XCTAssertEqual(fake.calls().filter { $0.method == "session.resume" }.count, 1)
        XCTAssertFalse(fake.calls().contains { $0.method == "session.create" || $0.method == "prompt.submit" })
        XCTAssertEqual(viewModel.messages.filter { ["user", "assistant"].contains($0.role ?? "") }.compactMap(\.content),
            ["Work externally", "Latest external progress"])
        XCTAssertFalse(viewModel.messages.contains { $0.role == "local_notice" })
        XCTAssertEqual(viewModel.activeStreamID, "direct-run:durable-1")
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.sendErrorMessage)

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "other-runtime", type: "message.delta", sequence: 1,
            payload: ["text": .string("Sibling-only token")]
        ))
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1", type: "message.delta", sequence: 2,
            payload: ["text": .string("External stream continues")]
        ))
        for _ in 0..<40 { await Task.yield() }

        XCTAssertTrue(viewModel.messages.contains { $0.content == "Work externally" })
        XCTAssertFalse(viewModel.messages.contains { $0.content?.contains("Sibling-only token") == true })
        XCTAssertFalse(viewModel.messages.contains { $0.content?.contains("External stream continues") == true })
        XCTAssertEqual(requests.values(), ["/api/sessions/durable-1/messages"])

        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "tool.start", sequence: 3,
            payload: ["tool_id": .string("cold-tool"), "name": .string("read_file")]))
        await waitUntil { viewModel.liveToolCalls.map(\.id).contains("cold-tool") }
        requests.beginTerminalPhase()
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.complete", sequence: 4,
            payload: ["status": .string("complete"), "text": .string("Unwatermarked terminal text")]))
        await waitUntil { viewModel.messages.contains { $0.messageId == "3" } }
        XCTAssertTrue(viewModel.messages.contains { $0.content == "Canonical completed answer" })
        XCTAssertFalse(viewModel.messages.contains { $0.content?.contains("Unwatermarked terminal text") == true })
        XCTAssertEqual(requests.values(), ["/api/sessions/durable-1/messages", "/api/sessions/durable-1/messages"])
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testLocalDraftLoadDoesNotCreateOrCallREST() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            XCTFail("Opening a local draft must not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        await viewModel.loadMessages()

        XCTAssertTrue(fake.calls().isEmpty)
        XCTAssertTrue(requests.values().isEmpty)
        XCTAssertFalse(viewModel.hasServerBackedSession)
        XCTAssertTrue(viewModel.messages.isEmpty)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testFirstDirectSendCreatesOnceAndUsesRuntimePromptWithoutBookmarkingRuntimeID() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatViewModelDirectGatewayTests.\(UUID().uuidString)"))
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "nil")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil, defaults: defaults)
        var canonicalID: String?
        viewModel.onDirectCanonicalID = { canonicalID = $0 }

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)

        let calls = fake.calls()
        XCTAssertEqual(calls.filter { $0.method != "config.get" }.map(\.method), ["session.create", "prompt.submit"])
        for call in calls where call.method == "config.get" {
            XCTAssertEqual(fields(call.params)?["scope"], .string("session"))
            XCTAssertEqual(fields(call.params)?["session_id"], .string("runtime-1"))
        }
        XCTAssertEqual(fields(calls[1].params)?["session_id"], .string("runtime-1"))
        XCTAssertEqual(fields(calls[1].params)?["profile"], .string("work"))
        XCTAssertEqual(canonicalID, "durable-1")
        XCTAssertEqual(viewModel.attachmentSessionID, "durable-1")
        XCTAssertTrue(viewModel.hasServerBackedSession)
        XCTAssertTrue(requests.values().isEmpty)
        let retained = OpenChatSessionStore()
        _ = retained.adoptedViewModel(session: SessionSummary(sessionId: "durable-1", profile: "work"),
            server: testServer, creating: viewModel)
        XCTAssertEqual(retained.liveSessionIDs(for: testServer), ["durable-1"])
        XCTAssertTrue(retained.liveStreamIDs(for: testServer).isEmpty,
            "Direct liveness must never feed the legacy WebUI status watcher")
        let bookmarks = LiveRunBookmarkStore(defaults: defaults)
        XCTAssertNil(bookmarks.load(server: testServer, sessionID: "durable-1"))
        let serializedDefaults = defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }
            .compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertFalse(serializedDefaults.contains { $0.contains("runtime-1") })

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testStreamingEventRendersThenCanonicalTranscriptReplacesOptimisticRows() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            guard request.url?.path.contains("/api/sessions/durable-1/messages") == true else {
                XCTFail("Unexpected REST path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":[{"id":1,"role":"user","content":"hello","timestamp":1},{"id":2,"role":"assistant","content":"canonical answer","timestamp":2}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#,
                for: request
            )
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.messages.contains { $0.content == "streamed answer" } }
        XCTAssertTrue(viewModel.messages.contains { $0.content == "streamed answer" })

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "reasoning.delta",
            sequence: 10,
            payload: ["text": .string("ephemeral plan")]
        ))
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "tool.start",
            sequence: 11,
            payload: ["tool_id": .string("ephemeral-tool"), "name": .string("lookup")]
        ))
        await waitUntil {
            viewModel.liveReasoningText == "ephemeral plan"
                && viewModel.liveToolCalls.count == 1
        }

        fake.emitCompletion()
        await waitUntil { viewModel.messages.contains { $0.content == "canonical answer" } }

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["hello", "canonical answer"])
        XCTAssertTrue(viewModel.liveReasoningText.isEmpty)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertTrue(viewModel.completedReasoningGroups.isEmpty)
        XCTAssertTrue(viewModel.completedToolCallGroups.isEmpty)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectCompressSlashCommandUsesGatewayAndReportsNoop() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setResumeResponse(.object(["session_id": .string("runtime-parent"), "session_key": .string("parent")]))
        fake.setCompressResponse(.object([
            "status": .string("compressed"),
            "summary": .object(["noop": .bool(true), "aborted": .bool(false)]),
            "info": .object(["stored_session_id": .string("parent"), "profile_name": .string("work")])
        ]))
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/parent/messages")
            return apiTestJSONResponse(#"{"session_id":"parent","messages":[],"pagination":{"limit":120,"offset":0,"order":"latest","returned":0}}"#, for: request)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: "parent")
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "compress"))
        let result = await viewModel.executeSlashCommand(command)
        guard case .executed(let message) = result else {
            XCTFail("Expected direct compression outcome")
            await runtime.stop()
            return
        }
        XCTAssertEqual(message, "No changes from compression.")
        XCTAssertEqual(fake.calls().filter { $0.method == "session.compress" }.count, 1)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.resume" }.count, 1)
        XCTAssertFalse(viewModel.isCompressingSession)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBranchTransfersBoundChildWithoutResumingParentOrChild() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-parent"),
            "session_key": .string("parent")
        ]))
        fake.setBranchResponse(.object([
            "session_id": .string("runtime-child"),
            "stored_session_id": .string("child"),
            "parent": .string("parent"),
            "message_count": .number(2),
            "info": .object(["profile_name": .string("work")])
        ]))
        let runtime = try makeRuntime(fake)
        let requestedPaths = ChatDirectRequestRecorder()
        let client = makeClient { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)
            if path == "/api/sessions/parent/messages" || path == "/api/sessions/child/messages" {
                let id = path.contains("/child/") ? "child" : "parent"
                let messages = id == "parent"
                    ? #"[{"id":"parent-user","role":"user","content":"Parent question"},{"id":"parent-assistant","role":"assistant","content":"Parent answer"}]"#
                    : #"[{"id":"child-user","role":"user","content":"Parent question"},{"id":"child-assistant","role":"assistant","content":"Parent answer"}]"#
                return apiTestJSONResponse(
                    #"{"session_id":"\#(id)","messages":\#(messages),"pagination":{"limit":120,"offset":0,"order":"desc","returned":2}}"#,
                    for: request
                )
            }
            guard path == "/api/sessions/child" else {
                XCTFail("Unexpected direct branch path: \(path)")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                #"{"id":"child","profile":"work","title":"Child branch","message_count":2}"#,
                for: request
            )
        }
        let parentViewModel = makeViewModel(client: client, runtime: runtime, sessionID: "parent")
        await parentViewModel.loadMessages()

        let branchCommand = try XCTUnwrap(SlashCommandCatalog.command(named: "branch"))
        let result = await parentViewModel.executeSlashCommand(branchCommand)
        guard case .openedDirectBranch(let handoff) = result else {
            XCTFail("Direct branch should return an owned handoff")
            await runtime.stop()
            return
        }

        XCTAssertEqual(handoff.session.sessionId, "child")
        XCTAssertEqual(handoff.session.profile, "work")
        XCTAssertEqual(handoff.origin, testServer)
        XCTAssertEqual(handoff.profile, "work")
        XCTAssertEqual(fake.calls().filter { $0.method == "session.resume" }.count, 1)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.branch" }.count, 1)

        await handoff.viewModel.loadMessages()
        XCTAssertEqual(fake.calls().filter { $0.method == "session.resume" }.count, 1)
        XCTAssertEqual(parentViewModel.messages.map(\.content), ["Parent question", "Parent answer"])
        XCTAssertEqual(handoff.viewModel.messages.map(\.content), ["Parent question", "Parent answer"])
        XCTAssertFalse(parentViewModel.messages.contains { $0.messageId == "child-user" })
        XCTAssertTrue(requestedPaths.values().contains("/api/sessions/child"))

        await parentViewModel.disposeDirectConversation()
        await handoff.viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBranchRejectsDetailIdentityMismatchWithoutHandoff() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-parent"),
            "session_key": .string("parent")
        ]))
        fake.setBranchResponse(.object([
            "session_id": .string("runtime-child"),
            "stored_session_id": .string("child"),
            "parent": .string("parent"),
            "message_count": .number(2),
            "info": .object(["profile_name": .string("work")])
        ]))
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            let path = request.url?.path ?? "nil"
            if path.hasSuffix("/messages") {
                let id = path.contains("/child/") ? "child" : "parent"
                return apiTestJSONResponse(
                    #"{"session_id":"\#(id)","messages":[],"pagination":{"limit":120,"offset":0,"order":"desc","returned":0}}"#,
                    for: request
                )
            }
            guard path == "/api/sessions/child" else {
                XCTFail("Unexpected direct branch path: \(path)")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                #"{"id":"other-child","profile":"work","title":"Wrong child"}"#,
                for: request
            )
        }
        let parentViewModel = makeViewModel(client: client, runtime: runtime, sessionID: "parent")
        await parentViewModel.loadMessages()

        let result = await parentViewModel.branchDirectConversation()
        guard case .unsupported = result else {
            XCTFail("A detail identity mismatch must not produce a child handoff")
            await runtime.stop()
            return
        }
        XCTAssertEqual(fake.calls().filter { $0.method == "session.resume" }.count, 1)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.branch" }.count, 1)
        XCTAssertTrue(parentViewModel.messages.isEmpty)

        await parentViewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBranchColdParentResumesBeforeBranchWithoutPreload() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-parent"),
            "session_key": .string("parent")
        ]))
        fake.setBranchResponse(.object([
            "session_id": .string("runtime-child"),
            "stored_session_id": .string("child"),
            "parent": .string("parent"),
            "message_count": .number(2),
            "info": .object(["profile_name": .string("work")])
        ]))
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            let path = request.url?.path ?? "nil"
            if path.hasSuffix("/messages") {
                let id = path.contains("/child/") ? "child" : "parent"
                return apiTestJSONResponse(
                    #"{"session_id":"\#(id)","messages":[],"pagination":{"limit":120,"offset":0,"order":"desc","returned":0}}"#,
                    for: request
                )
            }
            guard path == "/api/sessions/child" else {
                XCTFail("Unexpected cold branch path: \(path)")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                #"{"id":"child","profile":"work","title":"Cold child","message_count":2}"#,
                for: request
            )
        }
        let parentViewModel = makeViewModel(client: client, runtime: runtime, sessionID: "parent")

        let result = await parentViewModel.branchDirectConversation()
        guard case .openedDirectBranch(let handoff) = result else {
            XCTFail("A cold retained chat should resume before branching")
            await runtime.stop()
            return
        }
        XCTAssertEqual(fake.calls().filter { $0.method == "session.resume" }.count, 1)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.branch" }.count, 1)
        XCTAssertEqual(handoff.session.sessionId, "child")

        await parentViewModel.disposeDirectConversation()
        await handoff.viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectNamedBranchIsExplicitlyUnsupportedUntilNameIsWired() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { _ in
                XCTFail("A named branch must be rejected before RPC")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: "parent"
        )

        let result = await viewModel.branchDirectConversation(name: "named child")
        guard case .unsupported(let message) = result else {
            XCTFail("Named branch must not be silently ignored")
            await runtime.stop()
            return
        }
        XCTAssertTrue(message.contains("Named direct branches"))
        XCTAssertTrue(fake.calls().isEmpty)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectTerminalRefreshFailureArchivesLiveCardsBeforeExternalNextTurn() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTAssertTrue(request.url?.path.contains("/api/sessions/durable-1/messages") == true)
            throw URLError(.networkConnectionLost)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.messages.contains { $0.content == "streamed answer" } }

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "reasoning.delta",
            sequence: 10,
            payload: ["text": .string("old plan")]
        ))
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "tool.start",
            sequence: 11,
            payload: [
                "tool_id": .string("old-tool"),
                "name": .string("read_file"),
                "summary": .string("old result")
            ]
        ))
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "tool.complete",
            sequence: 12,
            payload: [
                "tool_id": .string("old-tool"),
                "name": .string("read_file"),
                "summary": .string("old result")
            ]
        ))
        await waitUntil {
            viewModel.liveReasoningText == "old plan"
                && viewModel.liveToolCalls.count == 1
                && viewModel.reasoningAnchorMessageID != nil
                && viewModel.toolCallAnchorMessageID != nil
        }
        let oldAnchor = try XCTUnwrap(viewModel.reasoningAnchorMessageID)

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "message.complete",
            sequence: 13,
            payload: ["text": .string("old answer")]
        ))
        await waitUntil { viewModel.activeStreamID == nil }
        XCTAssertEqual(viewModel.liveReasoningText, "old plan")
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)

        // This is an externally originated next turn. The failed terminal read
        // must not let the previous cards bleed into the new live turn.
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "message.start",
            sequence: 14
        ))
        await waitUntil { viewModel.activeStreamID != nil && viewModel.liveReasoningText.isEmpty }

        XCTAssertTrue(viewModel.completedReasoningGroups.contains {
            $0.anchorMessageID == oldAnchor && $0.text == "old plan"
        })
        XCTAssertEqual(viewModel.completedToolCallGroupsForAnchor(oldAnchor).flatMap(\.toolCalls).map(\.id), ["old-tool"])
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertNil(viewModel.reasoningAnchorMessageID)
        XCTAssertNil(viewModel.toolCallAnchorMessageID)

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testInterimAndDifferentFinalSurviveCanonicalTerminalReadback() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/durable-1/messages")
            return apiTestJSONResponse(
                "{\"session_id\":\"durable-1\",\"messages\":[{\"id\":1,\"role\":\"user\",\"content\":\"hello\",\"timestamp\":1},{\"id\":2,\"role\":\"assistant\",\"content\":\"## Interim heading\",\"timestamp\":2},{\"id\":3,\"role\":\"assistant\",\"content\":\"Canonical final\",\"timestamp\":3}],\"pagination\":{\"limit\":120,\"offset\":0,\"order\":\"latest\",\"returned\":3}}",
                for: request
            )
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.messages.contains { $0.content == "streamed answer" } }
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.interim", sequence: 3,
            payload: ["text": .string("streamed answer"), "already_streamed": .bool(true)]))
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.complete", sequence: 4,
            payload: ["text": .string("Live final")]))

        await waitUntil {
            viewModel.messages.contains { $0.messageId == "2" && $0.content == "## Interim heading" }
                && viewModel.messages.contains { $0.messageId == "3" && $0.content == "Canonical final" }
        }
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == "assistant" }.compactMap(\.content),
            ["## Interim heading", "Canonical final"]
        )

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectTerminalRefreshRaceKeepsOldCardsOutOfNewTurn() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let refreshStarted = expectation(description: "terminal refresh started")
        let releaseRefresh = DispatchSemaphore(value: 0)
        defer { releaseRefresh.signal() }
        let client = makeClient { request in
            XCTAssertTrue(request.url?.path.contains("/api/sessions/durable-1/messages") == true)
            refreshStarted.fulfill()
            _ = releaseRefresh.wait(timeout: .now() + 2)
            throw URLError(.networkConnectionLost)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.messages.contains { $0.content == "streamed answer" } }
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "reasoning.delta",
            sequence: 10,
            payload: ["text": .string("first turn plan")]
        ))
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "tool.start",
            sequence: 11,
            payload: [
                "tool_id": .string("first-tool"),
                "name": .string("search")
            ]
        ))
        await waitUntil {
            viewModel.liveReasoningText == "first turn plan"
                && viewModel.liveToolCalls.count == 1
                && viewModel.reasoningAnchorMessageID != nil
        }
        let oldAnchor = try XCTUnwrap(viewModel.reasoningAnchorMessageID)

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "message.complete",
            sequence: 12,
            payload: ["text": .string("first answer")]
        ))
        await fulfillment(of: [refreshStarted], timeout: 2)

        // The controller cancels the old refresh when this next turn starts,
        // but the VM must still finalize the old presentation state first.
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "message.start",
            sequence: 13
        ))
        await waitUntil { viewModel.activeStreamID != nil && viewModel.liveReasoningText.isEmpty }
        XCTAssertTrue(viewModel.completedReasoningGroups.contains {
            $0.anchorMessageID == oldAnchor && $0.text == "first turn plan"
        })
        XCTAssertEqual(viewModel.completedToolCallGroupsForAnchor(oldAnchor).flatMap(\.toolCalls).map(\.id), ["first-tool"])

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "reasoning.delta",
            sequence: 14,
            payload: ["text": .string("second turn plan")]
        ))
        await waitUntil { viewModel.liveReasoningText == "second turn plan" }
        let newAnchor = try XCTUnwrap(viewModel.reasoningAnchorMessageID)
        XCTAssertNotEqual(newAnchor, oldAnchor)
        XCTAssertEqual(viewModel.liveToolCalls, [])

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testWrongSessionEventsAreIgnoredByDirectChatViewModel() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Wrong-session event test should not need transcript REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.messages.contains { $0.content == "streamed answer" } }
        fake.emit(ChatDirectEventFactory.event(sessionID: "other-runtime", type: "message.delta", sequence: 99, payload: ["text": .string("wrong answer")]))
        // An own-session sentinel proves the earlier wrong-session event has
        // passed through the FIFO consumer before checking the negative result.
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "session.usage", sequence: 100,
            payload: ["usage": .object(["input": .number(123)])]))
        await waitUntil { viewModel.contextWindowSnapshot?.inputTokens == 123 }
        viewModel.flushPendingStreamingContent()

        XCTAssertFalse(viewModel.messages.compactMap(\.content).joined().contains("wrong answer"))
        XCTAssertTrue(viewModel.messages.contains { $0.content == "streamed answer" })
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectClarificationRoutesAnswerAndCancelWithoutLegacyHTTP() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Direct clarification must not call legacy HTTP: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "clarify.request",
            sequence: 19,
            payload: ["question": .string("missing request")]
        ))
        await waitUntil { viewModel.sendErrorMessage?.contains("cannot safely display") == true }
        fake.emit(clarificationEvent(requestID: "request-answer", sequence: 20))
        await waitUntil { viewModel.clarificationPrompt?.pending.clarifyId == "request-answer" }
        let answerIdentity = try XCTUnwrap(viewModel.clarificationPrompt?.gatewayIdentity)
        let answered = await viewModel.respondToDirectClarification("answer", expectedIdentity: answerIdentity)
        XCTAssertTrue(answered)

        fake.emit(clarificationEvent(requestID: "request-cancel", sequence: 21))
        await waitUntil { viewModel.clarificationPrompt?.pending.clarifyId == "request-cancel" }
        let cancelIdentity = try XCTUnwrap(viewModel.clarificationPrompt?.gatewayIdentity)
        let cancelled = await viewModel.respondToDirectClarification("", expectedIdentity: cancelIdentity)
        XCTAssertTrue(cancelled)

        let responses = fake.calls().filter { $0.method == "clarify.respond" }
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(fields(responses[0].params)?["answer"], .string("answer"))
        XCTAssertEqual(fields(responses[1].params)?["answer"], .string(""))
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectBlockingApprovalAndSensitiveCancellationUseTypedGatewayWithoutLegacyHTTP() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeDirectBlockingTestClient(),
            runtime: runtime,
            sessionID: nil
        )

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }

        fake.emit(approvalEvent(requestID: "approval-deny", sequence: 20))
        await waitUntil { viewModel.pendingApprovalPrompt?.identity.requestID == "approval-deny" }
        let approvalIdentity = try XCTUnwrap(viewModel.pendingApprovalPrompt?.identity)
        let approvalResponse = try await viewModel.respondToApproval(.deny, expectedIdentity: approvalIdentity)
        XCTAssertEqual(approvalResponse, .accepted)
        XCTAssertNil(viewModel.pendingApprovalPrompt)

        fake.emit(secretEvent(requestID: "secret-cancel", sequence: 21))
        await waitUntil { viewModel.pendingSecretPrompt?.identity.requestID == "secret-cancel" }
        let secretIdentity = try XCTUnwrap(viewModel.pendingSecretPrompt?.identity)
        let secretResponse = try await viewModel.cancelSecret(expectedIdentity: secretIdentity)
        XCTAssertEqual(secretResponse, .accepted)
        XCTAssertNil(viewModel.pendingSecretPrompt)

        fake.emit(sudoEvent(requestID: "sudo-cancel", sequence: 22))
        await waitUntil { viewModel.pendingSudoPrompt?.identity.requestID == "sudo-cancel" }
        let sudoIdentity = try XCTUnwrap(viewModel.pendingSudoPrompt?.identity)
        let sudoResponse = try await viewModel.cancelSudo(expectedIdentity: sudoIdentity)
        XCTAssertEqual(sudoResponse, .accepted)
        XCTAssertNil(viewModel.pendingSudoPrompt)

        let calls = fake.calls()
        XCTAssertEqual(calls.filter { $0.method == "approval.respond" }.count, 1)
        XCTAssertEqual(fields(calls.first { $0.method == "approval.respond" }?.params)?["choice"], .string("deny"))
        XCTAssertEqual(fields(calls.first { $0.method == "secret.respond" }?.params)?["value"], .string(""))
        XCTAssertEqual(fields(calls.first { $0.method == "sudo.respond" }?.params)?["password"], .string(""))
        XCTAssertFalse(calls.contains { $0.method.hasPrefix("/api/") })

        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectBlockingReplacedIdentityCannotAnswerOldPromptOrLeakLegacyState() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeDirectBlockingTestClient(),
            runtime: runtime,
            sessionID: nil
        )
        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }

        fake.emit(approvalEvent(requestID: "approval-old", sequence: 20))
        await waitUntil { viewModel.pendingApprovalPrompt?.identity.requestID == "approval-old" }
        let oldIdentity = try XCTUnwrap(viewModel.pendingApprovalPrompt?.identity)
        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.complete", sequence: 21, payload: ["status": .string("complete")]))
        await waitUntil { viewModel.pendingApprovalPrompt == nil }
        fake.emit(approvalEvent(requestID: "approval-new", sequence: 22))
        await waitUntil { viewModel.pendingApprovalPrompt?.identity.requestID == "approval-new" }

        do {
            _ = try await viewModel.respondToApproval(.deny, expectedIdentity: oldIdentity)
            XCTFail("A replaced approval identity must be rejected")
        } catch GatewayBlockingContractError.staleInteraction { }
        XCTAssertEqual(fake.calls().filter { $0.method == "approval.respond" }.count, 0)
        XCTAssertNil(viewModel.blockingInteractionErrorMessage)

        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectBlockingApprovalUnknownServerErrorAndRejectedResponsesRemainVisibleOnlyForCurrentPrompt() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeDirectBlockingTestClient(),
            runtime: runtime,
            sessionID: nil
        )
        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }

        fake.setBlockingResponse("approval.respond", .object([:]))
        fake.emit(approvalEvent(requestID: "approval-rejected", sequence: 20))
        await waitUntil { viewModel.pendingApprovalPrompt?.identity.requestID == "approval-rejected" }
        let rejectedIdentity = try XCTUnwrap(viewModel.pendingApprovalPrompt?.identity)
        do {
            _ = try await viewModel.respondToApproval(.deny, expectedIdentity: rejectedIdentity)
            XCTFail("Malformed approval acknowledgement must not report success")
        } catch GatewayBlockingContractError.approvalNotResolved { }
        XCTAssertTrue(viewModel.blockingInteractionErrorMessage?.contains("did not confirm") == true)
        fake.emit(secretEvent(requestID: "secret-new", sequence: 21))
        await waitUntil { viewModel.pendingSecretPrompt?.identity.requestID == "secret-new" }
        let secretIdentity = try XCTUnwrap(viewModel.pendingSecretPrompt?.identity)
        XCTAssertNil(viewModel.blockingInteractionErrorMessage(for: secretIdentity))
        XCTAssertTrue(viewModel.blockingInteractionErrorMessage(for: rejectedIdentity)?.contains("did not confirm") == true)

        fake.emit(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.complete", sequence: 22, payload: ["status": .string("complete")]))
        await waitUntil { viewModel.pendingApprovalPrompt == nil }
        fake.setBlockingError("approval.respond", .server(
            code: 4009,
            message: "server rejected approval response",
            data: nil,
            method: "approval.respond",
            requestID: "approval-unknown-error",
            server: "fixture"
        ))
        fake.emit(approvalEvent(requestID: "approval-unknown-error", sequence: 23))
        await waitUntil { viewModel.pendingApprovalPrompt?.identity.requestID == "approval-unknown-error" }
        let unknownErrorIdentity = try XCTUnwrap(viewModel.pendingApprovalPrompt?.identity)
        do {
            _ = try await viewModel.respondToApproval(.deny, expectedIdentity: unknownErrorIdentity)
            XCTFail("An unknown approval server error must not be reported as expiry")
        } catch let error as HermesGatewayError {
            if case .server(let code, _, _, let method, _, _) = error {
                XCTAssertEqual(code, 4009)
                XCTAssertEqual(method, "approval.respond")
            } else {
                XCTFail("Expected the original approval server error, got \(error)")
            }
        } catch {
            XCTFail("Expected HermesGatewayError, got \(error)")
        }
        XCTAssertEqual(viewModel.pendingApprovalPrompt?.identity, unknownErrorIdentity)
        XCTAssertTrue(
            viewModel.blockingInteractionErrorMessage(for: unknownErrorIdentity)?.contains("could not be delivered") == true
        )

        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectClarificationExpiredResponseIsNotReportedAsSuccess() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setClarifyResponse(.object(["status": .string("expired")]))
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Expired direct clarification should not call REST: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        fake.emit(clarificationEvent(requestID: "request-expired", sequence: 20))
        await waitUntil { viewModel.clarificationPrompt?.pending.clarifyId == "request-expired" }
        let identity = try XCTUnwrap(viewModel.clarificationPrompt?.gatewayIdentity)

        let didRespond = await viewModel.respondToDirectClarification("answer", expectedIdentity: identity)

        XCTAssertFalse(didRespond)
        XCTAssertNil(viewModel.clarificationPrompt)
        XCTAssertEqual(viewModel.directClarificationErrorMessage, "That clarification expired before it was answered.")
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectClarificationReplacementClearsOwnedErrorButPreservesUnrelatedError() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Clarification replacement test should not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        fake.emit(clarificationEvent(requestID: "request-expiring", sequence: 20))
        await waitUntil { viewModel.clarificationPrompt?.pending.clarifyId == "request-expiring" }
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "clarify.expire",
            sequence: 21,
            payload: ["request_id": .string("request-expiring")]
        ))
        await waitUntil { viewModel.sendErrorMessage == "That clarification expired before it was answered." }

        fake.emit(clarificationEvent(requestID: "request-replacement", sequence: 22))
        await waitUntil { viewModel.clarificationPrompt?.pending.clarifyId == "request-replacement" }
        XCTAssertNil(viewModel.sendErrorMessage)

        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "clarify.expire",
            sequence: 23,
            payload: ["request_id": .string("request-replacement")]
        ))
        await waitUntil { viewModel.sendErrorMessage == "That clarification expired before it was answered." }
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "error",
            sequence: 24,
            payload: ["message": .string("Unrelated transport error")]
        ))
        await waitUntil { viewModel.sendErrorMessage == "Unrelated transport error" }
        fake.emit(clarificationEvent(requestID: "request-after-unrelated", sequence: 25))
        await waitUntil { viewModel.clarificationPrompt?.pending.clarifyId == "request-after-unrelated" }
        XCTAssertEqual(
            viewModel.sendErrorMessage,
            "Unrelated transport error"
        )

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectClarificationDuplicateTapIsSingleFlight() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setClarifyGate(gate)
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Duplicate direct clarification test should not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        fake.emit(clarificationEvent(requestID: "request-single-flight", sequence: 20))
        await waitUntil { viewModel.clarificationPrompt != nil }
        let identity = try XCTUnwrap(viewModel.clarificationPrompt?.gatewayIdentity)
        let first = Task { await viewModel.respondToDirectClarification("answer", expectedIdentity: identity) }
        await waitUntil { viewModel.isRespondingToDirectClarification }
        let secondTap = await viewModel.respondToDirectClarification("second", expectedIdentity: identity)
        XCTAssertFalse(secondTap)
        XCTAssertEqual(fake.calls().filter { $0.method == "clarify.respond" }.count, 1)
        await gate.release()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectClarificationReplacementAndInvalidationDoNotPolluteNewUI() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setClarifyGate(gate)
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Replacement direct clarification test should not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("hello")
        XCTAssertTrue(didSend)
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        fake.emit(clarificationEvent(requestID: "request-old", sequence: 20))
        await waitUntil { viewModel.clarificationPrompt?.pending.clarifyId == "request-old" }
        let oldIdentity = try XCTUnwrap(viewModel.clarificationPrompt?.gatewayIdentity)
        let first = Task { await viewModel.respondToDirectClarification("answer", expectedIdentity: oldIdentity) }
        await waitUntil { viewModel.isRespondingToDirectClarification }

        fake.emit(clarificationEvent(requestID: "request-new", sequence: 21))
        await waitUntil { viewModel.clarificationPrompt?.pending.clarifyId == "request-new" }
        await gate.release()
        let firstResult = await first.value
        XCTAssertFalse(firstResult)
        XCTAssertEqual(viewModel.clarificationPrompt?.pending.clarifyId, "request-new")
        XCTAssertNil(viewModel.directClarificationErrorMessage)

        let newIdentity = try XCTUnwrap(viewModel.clarificationPrompt?.gatewayIdentity)
        let secondGate = ChatDirectAsyncGate()
        fake.setClarifyGate(secondGate)
        let second = Task { await viewModel.respondToDirectClarification("answer", expectedIdentity: newIdentity) }
        await waitUntil { viewModel.isRespondingToDirectClarification }
        viewModel.invalidateDirectConversation()
        await secondGate.release()
        let secondResult = await second.value
        XCTAssertFalse(secondResult)
        XCTAssertNil(viewModel.clarificationPrompt)
        XCTAssertNil(viewModel.directClarificationErrorMessage)
        await runtime.stop()
    }

    func testDirectActivePagingPreservesLiveTailCardsAnchorsAndSibling() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-live-page", "chat-sibling"])
        fixture.installHistoricalTool(in: "chat-live-page")
        let fake = ChatLongFixtureTransport(fixture: fixture)
        let runtime = try makeRuntime(fake)
        let client = makeLongHistoryClient(fixture: fixture)
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "chat-live-page")
        let sibling = makeViewModel(client: client, runtime: runtime, sessionID: "chat-sibling")
        await vm.loadMessages()
        await sibling.loadMessages()
        let siblingRows = sibling.messages
        let oldest = try XCTUnwrap(vm.displayedTranscriptMessages.first)
        fake.emit(for: "chat-live-page", type: "message.start", sequence: 10)
        fake.emit(for: "chat-live-page", type: "message.delta", sequence: 11, payload: ["text": .string("before page")])
        fake.emit(for: "chat-live-page", type: "reasoning.delta", sequence: 12, payload: ["text": .string("keep plan")])
        fake.emit(for: "chat-live-page", type: "tool.start", sequence: 13, payload: ["tool_id": .string("paging-tool"), "name": .string("read_file")])
        await waitUntil { vm.hasStreamingAssistantMessageContent && vm.liveReasoningText == "keep plan" && vm.liveToolCalls.count == 1 }
        let liveID = try XCTUnwrap(vm.streamingAssistantMessageID)
        let reasoningAnchor = vm.reasoningAnchorMessageID
        let toolAnchor = vm.toolCallAnchorMessageID
        let streamID = vm.activeStreamID
        let tools = vm.liveToolCalls
        // More than two pages of durable growth moves the backwards cursor
        // past wholly newer rows. None may be prepended ahead of the old tail.
        fixture.appendRows(250, to: "chat-live-page")

        let loaded = await vm.loadOlderMessages()
        XCTAssertTrue(loaded)
        XCTAssertEqual(vm.messages.count, 228)
        XCTAssertEqual(Array(vm.messages.compactMap(\.messageId).dropLast()),
            (1773..<2000).map { "chat-live-page-row-\($0)" })
        XCTAssertEqual(fixture.requests().filter { $0.chatID == "chat-live-page" }.map(\.offset), [0, 119, 238, 357])
        XCTAssertTrue(vm.completedToolCallGroups.flatMap(\.toolCalls).contains { $0.name == "historical_lookup" })
        XCTAssertEqual(vm.messages.last?.id, liveID)
        XCTAssertEqual(vm.streamingAssistantMessageID, liveID)
        XCTAssertEqual(vm.activeStreamID, streamID)
        XCTAssertEqual(vm.liveReasoningText, "keep plan")
        XCTAssertEqual(vm.liveToolCalls, tools)
        XCTAssertEqual(vm.reasoningAnchorMessageID, reasoningAnchor)
        XCTAssertEqual(vm.toolCallAnchorMessageID, toolAnchor)
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.message.id == oldest.message.id }?.renderID, oldest.renderID)
        XCTAssertEqual(sibling.messages, siblingRows)

        fake.emit(for: "chat-live-page", type: "message.delta", sequence: 14, payload: ["text": .string(" after page")])
        await waitUntil { vm.messages.last?.content == "before page after page" }
        XCTAssertEqual(vm.messages.last?.id, liveID)
        let beforeFailure = vm.messages
        fixture.failNextOlderPage()
        let failed = await vm.loadOlderMessages()
        XCTAssertFalse(failed)
        XCTAssertEqual(vm.messages, beforeFailure)
        XCTAssertEqual(vm.streamingAssistantMessageID, liveID)
        XCTAssertEqual(vm.liveToolCalls, tools)
        XCTAssertEqual(vm.liveReasoningText, "keep plan")
        XCTAssertEqual(sibling.messages, siblingRows)
        await vm.disposeDirectConversation()
        await sibling.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectFullLoadDuringActiveRunSkipsStaleRESTAndPreservesLiveTailCardsAnchorsAndSibling() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-live-load", "chat-load-sibling"])
        let fake = ChatLongFixtureTransport(fixture: fixture)
        let runtime = try makeRuntime(fake)
        let client = makeLongHistoryClient(fixture: fixture)
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "chat-live-load")
        let sibling = makeViewModel(client: client, runtime: runtime, sessionID: "chat-load-sibling")
        await vm.loadMessages()
        await sibling.loadMessages()
        let durableRows = vm.messages
        let siblingRows = sibling.messages
        let requestsBeforeActiveLoad = fixture.requests()

        fake.emit(for: "chat-live-load", type: "message.start", sequence: 10)
        fake.emit(for: "chat-live-load", type: "message.delta", sequence: 11,
                  payload: ["text": .string("live answer")])
        fake.emit(for: "chat-live-load", type: "reasoning.delta", sequence: 12,
                  payload: ["text": .string("live plan")])
        fake.emit(for: "chat-live-load", type: "tool.start", sequence: 13,
                  payload: ["tool_id": .string("live-load-tool"), "name": .string("read_file")])
        await waitUntil {
            vm.hasStreamingAssistantMessageContent
                && vm.liveReasoningText == "live plan"
                && vm.liveToolCalls.map(\.id) == ["live-load-tool"]
                && vm.reasoningAnchorMessageID != nil
                && vm.toolCallAnchorMessageID != nil
        }
        let liveID = try XCTUnwrap(vm.streamingAssistantMessageID)
        let reasoningAnchor = try XCTUnwrap(vm.reasoningAnchorMessageID)
        let toolAnchor = try XCTUnwrap(vm.toolCallAnchorMessageID)
        let streamID = try XCTUnwrap(vm.activeStreamID)
        let connectionCount = fake.connectionCount()
        let RPCsBeforeActiveLoad = fake.calls()

        // The stock REST transcript is intentionally still the durable snapshot
        // from before this run. A public full load while active must not fetch and
        // apply it over the gateway-owned live tail.
        await vm.loadMessages()

        XCTAssertEqual(fixture.requests(), requestsBeforeActiveLoad)
        XCTAssertEqual(fake.calls(), RPCsBeforeActiveLoad)
        XCTAssertEqual(fake.connectionCount(), connectionCount)
        XCTAssertEqual(Array(vm.messages.dropLast()), durableRows)
        XCTAssertEqual(vm.messages.last?.messageId, liveID)
        XCTAssertEqual(vm.messages.last?.content, "live answer")
        XCTAssertEqual(vm.streamingAssistantMessageID, liveID)
        XCTAssertEqual(vm.activeStreamID, streamID)
        XCTAssertEqual(vm.liveReasoningText, "live plan")
        XCTAssertEqual(vm.liveToolCalls.map(\.id), ["live-load-tool"])
        XCTAssertEqual(vm.reasoningAnchorMessageID, reasoningAnchor)
        XCTAssertEqual(vm.toolCallAnchorMessageID, toolAnchor)
        XCTAssertEqual(sibling.messages, siblingRows)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })

        fake.emit(for: "chat-live-load", type: "message.delta", sequence: 14,
                  payload: ["text": .string(" continues")])
        await waitUntil { vm.messages.last?.content == "live answer continues" }
        XCTAssertEqual(vm.messages.last?.messageId, liveID)
        XCTAssertEqual(vm.reasoningAnchorMessageID, reasoningAnchor)
        XCTAssertEqual(vm.toolCallAnchorMessageID, toolAnchor)
        XCTAssertEqual(sibling.messages, siblingRows)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await vm.disposeDirectConversation()
        await sibling.disposeDirectConversation()
        await runtime.stop()
    }

    func testActiveDuplicateOnlyPageAdvancesRawCursorWithoutExhaustingHistory() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-duplicate-page"])
        let fake = ChatLongFixtureTransport(fixture: fixture)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeLongHistoryClient(fixture: fixture), runtime: runtime, sessionID: "chat-duplicate-page")
        await vm.loadMessages()
        fake.emit(for: "chat-duplicate-page", type: "message.start", sequence: 10)
        fake.emit(for: "chat-duplicate-page", type: "message.delta", sequence: 11, payload: ["text": .string("live")])
        await waitUntil { vm.hasStreamingAssistantMessageContent }
        let before = vm.messages
        fixture.appendRows(119, to: "chat-duplicate-page")
        let duplicateOnly = await vm.loadOlderMessages()
        XCTAssertFalse(duplicateOnly)
        XCTAssertEqual(vm.messages, before)
        XCTAssertTrue(vm.hasOlderMessages)
        let next = await vm.loadOlderMessages()
        XCTAssertTrue(next)
        XCTAssertEqual(fixture.requests().map(\.offset), [0, 119, 238])
        XCTAssertEqual(vm.messages.first?.messageId, "chat-duplicate-page-row-1761")
        XCTAssertEqual(vm.messages.last?.content, "live")
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectOlderPageFailurePreservesRowsAnchorAndCursorForRetry() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-page-failure"])
        let runtime = try makeRuntime(ChatLongFixtureTransport(fixture: fixture))
        let vm = makeViewModel(client: makeLongHistoryClient(fixture: fixture), runtime: runtime, sessionID: "chat-page-failure")
        await vm.loadMessages()
        let before = vm.messages
        let anchor = try XCTUnwrap(vm.displayedTranscriptMessages.first?.renderID)
        fixture.failNextOlderPage()

        let failed = await vm.loadOlderMessages()
        XCTAssertFalse(failed)
        XCTAssertEqual(vm.messages, before)
        XCTAssertEqual(vm.displayedTranscriptMessages.first?.renderID, anchor)
        XCTAssertTrue(vm.hasOlderMessages)
        XCTAssertFalse(vm.isLoadingOlderMessages)
        XCTAssertNotNil(vm.errorMessage)

        let retried = await vm.loadOlderMessages()
        XCTAssertTrue(retried)
        XCTAssertEqual(fixture.requests().map(\.offset), [0, 120, 120])
        XCTAssertEqual(vm.messages.compactMap(\.messageId), Array(fixture.messageIDs(for: "chat-page-failure").suffix(240)))
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.message.messageId == before.first?.messageId }?.renderID, anchor)
        XCTAssertTrue(vm.hasOlderMessages)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectOlderOverlapDeduplicatesAndTailReloadPreservesExpandedHistory() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-page-overlap"])
        let runtime = try makeRuntime(ChatLongFixtureTransport(fixture: fixture))
        let vm = makeViewModel(client: makeLongHistoryClient(fixture: fixture), runtime: runtime, sessionID: "chat-page-overlap")
        await vm.loadMessages()
        let anchor = try XCTUnwrap(vm.displayedTranscriptMessages.first?.renderID)
        fixture.overlapNextOlderPage()
        let loaded = await vm.loadOlderMessages()
        XCTAssertTrue(loaded)
        let ids = vm.messages.compactMap(\.messageId)
        XCTAssertEqual(ids, Array(fixture.messageIDs(for: "chat-page-overlap").suffix(239)))
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(vm.messagesOffset, 0, "Direct row identity is durable, not a WebUI absolute index")
        XCTAssertTrue(vm.hasOlderMessages)
        XCTAssertEqual(vm.displayedTranscriptMessages.first { $0.message.messageId == "chat-page-overlap-row-1880" }?.renderID, anchor)
        await vm.loadMessages()
        XCTAssertEqual(vm.messages.compactMap(\.messageId), ids)
        XCTAssertEqual(fixture.requests().map(\.offset), [0, 120, 0])
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testLongHistoriesPageChronologicallyAcrossThreeChatsAndReopenWithoutCrossRouting() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-a", "chat-b", "chat-c"])
        let fake = ChatLongFixtureTransport(fixture: fixture)
        let runtime = try makeRuntime(fake)
        let client = makeLongHistoryClient(fixture: fixture)

        let first = makeViewModel(client: client, runtime: runtime, sessionID: "chat-a")
        await first.loadMessages()
        XCTAssertEqual(first.messages.count, 120)
        XCTAssertEqual(first.messages.first?.messageId, "chat-a-row-1880")
        XCTAssertEqual(first.messages.last?.messageId, "chat-a-row-1999")
        XCTAssertTrue(first.messages.allSatisfy { $0.messageId?.hasPrefix("chat-a-") == true })
        let firstTailRowID = try XCTUnwrap(first.messages.first?.messageId)
        let firstTailRenderID = try XCTUnwrap(
            first.displayedTranscriptMessages.first { $0.message.messageId == firstTailRowID }?.renderID
        )

        var firstOlderPageCount = 0
        while first.hasOlderMessages {
            guard firstOlderPageCount < 20 else {
                XCTFail("Long-history cursor exceeded the bounded 20-page guard")
                throw ChatLongFixtureError.pagingLimitExceeded
            }
            let countBeforePage = first.messages.count
            let didLoad = await first.loadOlderMessages()
            guard didLoad, first.messages.count > countBeforePage else {
                XCTFail("Long-history older-page load made no progress")
                throw ChatLongFixtureError.pagingStalled
            }
            firstOlderPageCount += 1
            if firstOlderPageCount == 1 {
                let renderIDAfterPrepend = try XCTUnwrap(
                    first.displayedTranscriptMessages.first { $0.message.messageId == firstTailRowID }?.renderID
                )
                XCTAssertEqual(renderIDAfterPrepend, firstTailRenderID,
                    "Prepending an older page must preserve the first tail row's render ID")
            }
        }
        XCTAssertEqual(firstOlderPageCount, 16)
        XCTAssertEqual(first.messages.count, 2_000)
        XCTAssertEqual(first.messages.compactMap(\.messageId), fixture.messageIDs(for: "chat-a"))
        XCTAssertTrue(first.messages[0].content?.contains("```swift") == true)
        XCTAssertTrue(first.messages[0].content?.contains("**markdown**") == true)

        // Switching to two other long conversations must not reuse the first
        // controller's transcript or cursor. One older page is enough to prove
        // both the latest and backwards-offset requests are scoped correctly.
        let second = makeViewModel(client: client, runtime: runtime, sessionID: "chat-b")
        await second.loadMessages()
        XCTAssertEqual(second.messages.compactMap(\.messageId), Array(fixture.messageIDs(for: "chat-b").suffix(120)))
        let didLoadSecondOlderPage = await second.loadOlderMessages()
        XCTAssertTrue(didLoadSecondOlderPage)
        XCTAssertEqual(second.messages.count, 240)
        XCTAssertTrue(second.messages.allSatisfy { $0.messageId?.hasPrefix("chat-b-") == true })
        XCTAssertFalse(second.messages.contains { $0.messageId?.hasPrefix("chat-a-") == true })

        let third = makeViewModel(client: client, runtime: runtime, sessionID: "chat-c")
        await third.loadMessages()
        XCTAssertEqual(third.messages.count, 120)
        XCTAssertTrue(third.messages.allSatisfy { $0.messageId?.hasPrefix("chat-c-") == true })
        XCTAssertFalse(third.messages.contains { $0.messageId?.hasPrefix("chat-a-") == true })
        XCTAssertFalse(third.messages.contains { $0.messageId?.hasPrefix("chat-b-") == true })

        // Reopening B in a fresh VM must start from B's bounded latest page,
        // then prepend B's older page rather than inheriting A/C state.
        await second.disposeDirectConversation()
        let reopened = makeViewModel(client: client, runtime: runtime, sessionID: "chat-b")
        await reopened.loadMessages()
        XCTAssertEqual(reopened.messages.compactMap(\.messageId), Array(fixture.messageIDs(for: "chat-b").suffix(120)))
        let didLoadReopenedOlderPage = await reopened.loadOlderMessages()
        XCTAssertTrue(didLoadReopenedOlderPage)
        XCTAssertEqual(reopened.messages.count, 240)
        XCTAssertEqual(reopened.messages.compactMap(\.messageId), Array(fixture.messageIDs(for: "chat-b").suffix(240)))

        let transcriptRequests = fake.restRequests()
        XCTAssertTrue(transcriptRequests.count >= 1 + 16 + 1 + 1 + 1 + 1,
            "Expected bounded latest and older reads for A, B, C, and reopened B")
        for request in transcriptRequests {
            XCTAssertEqual(request.limit, 120)
            XCTAssertEqual(request.order, "latest")
            XCTAssertEqual(request.includeCompacted, "true")
            XCTAssertEqual(request.profile, "work")
        }
        XCTAssertEqual(Array(transcriptRequests.filter { $0.chatID == "chat-a" }.map(\.offset).prefix(3)), [0, 120, 240])
        XCTAssertEqual(Array(transcriptRequests.filter { $0.chatID == "chat-b" }.map(\.offset).prefix(3)), [0, 120, 0])
        XCTAssertEqual(transcriptRequests.filter { $0.chatID == "chat-c" }.count, 1)

        await first.disposeDirectConversation()
        await third.disposeDirectConversation()
        await reopened.disposeDirectConversation()
        await runtime.stop()
    }

    func testLongPagedHistoryKeepsOlderRowsWhenStreamingCompletionReconcilesLatestTail() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-send"])
        let fake = ChatLongFixtureTransport(fixture: fixture)
        let runtime = try makeRuntime(fake)
        let client = makeLongHistoryClient(fixture: fixture)
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: "chat-send")

        await viewModel.loadMessages()
        var olderPageCount = 0
        while viewModel.hasOlderMessages {
            guard olderPageCount < 20 else {
                XCTFail("Long-history send fixture exceeded the bounded 20-page guard")
                throw ChatLongFixtureError.pagingLimitExceeded
            }
            let countBeforePage = viewModel.messages.count
            let didLoad = await viewModel.loadOlderMessages()
            guard didLoad, viewModel.messages.count > countBeforePage else {
                XCTFail("Long-history send fixture older-page load made no progress")
                throw ChatLongFixtureError.pagingStalled
            }
            olderPageCount += 1
        }
        XCTAssertEqual(olderPageCount, 16)
        XCTAssertEqual(viewModel.messages.count, 2_000)
        let originalIDs = viewModel.messages.compactMap(\.messageId)
        XCTAssertEqual(originalIDs, fixture.messageIDs(for: "chat-send"))
        let originalOldestRenderID = try XCTUnwrap(
            viewModel.displayedTranscriptMessages.first { $0.message.messageId == originalIDs.first }?.renderID
        )

        let didSend = await viewModel.sendMessage("new question with **markdown** and `code`")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.messages.contains { $0.content == "streamed answer" } }
        XCTAssertEqual(viewModel.messages.filter { $0.content == "new question with **markdown** and `code`" }.count, 1)
        XCTAssertEqual(viewModel.messages.filter { $0.content == "streamed answer" }.count, 1)

        fake.emitCompletion(for: "chat-send")
        await waitUntil {
            viewModel.messages.contains { $0.messageId == "chat-send-row-2001" }
        }

        let finalIDs = viewModel.messages.compactMap(\.messageId)
        XCTAssertEqual(finalIDs.count, 2_002)
        XCTAssertEqual(Set(finalIDs).count, 2_002, "Canonical completion must not duplicate durable rows")
        XCTAssertEqual(Array(finalIDs.prefix(2_000)), originalIDs,
            "A latest-tail reconcile must retain every already-loaded older row")
        XCTAssertEqual(finalIDs.suffix(2), ["chat-send-row-2000", "chat-send-row-2001"])
        XCTAssertEqual(viewModel.messages.filter { $0.content == "new question with **markdown** and `code`" }.count, 1)
        XCTAssertEqual(viewModel.messages.filter { $0.content == "streamed answer" }.count, 0,
            "The durable terminal answer replaces the optimistic streamed row")
        XCTAssertEqual(viewModel.messages.last?.content, "canonical terminal answer")
        let reconciledOldestRenderID = try XCTUnwrap(
            viewModel.displayedTranscriptMessages.first { $0.message.messageId == originalIDs.first }?.renderID
        )
        XCTAssertEqual(reconciledOldestRenderID, originalOldestRenderID,
            "Latest-tail completion reconciliation must preserve an older row's render ID")

        let requests = fake.restRequests().filter { $0.chatID == "chat-send" }
        XCTAssertTrue(requests.contains { $0.offset == 0 && $0.limit == 120 })
        XCTAssertTrue(requests.contains { $0.offset == 1_920 && $0.limit == 120 })
        XCTAssertTrue(requests.filter { $0.offset == 0 }.allSatisfy { $0.order == "latest" })

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testTailRefreshHonorsRemovedSuffixAndKeepsBackwardCursorAligned() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-delete"])
        let fake = ChatLongFixtureTransport(fixture: fixture)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeLongHistoryClient(fixture: fixture), runtime: runtime, sessionID: "chat-delete")
        await vm.loadMessages()
        for _ in 0..<2 {
            let loaded = await vm.loadOlderMessages()
            XCTAssertTrue(loaded)
        }
        XCTAssertEqual(vm.messages.count, 360)
        let firstID = vm.messages.first?.messageId
        fixture.removeNewestRows(2, from: "chat-delete")
        await vm.loadMessages()
        XCTAssertEqual(vm.messages.count, 358)
        XCTAssertEqual(vm.messages.first?.messageId, firstID)
        XCTAssertEqual(vm.messages.last?.messageId, "chat-delete-row-1997")
        XCTAssertFalse(vm.messages.contains { $0.messageId == "chat-delete-row-1998" })
        let loaded = await vm.loadOlderMessages()
        XCTAssertTrue(loaded)
        XCTAssertEqual(fixture.requests().last?.offset, 358)
        XCTAssertEqual(vm.messages.compactMap(\.messageId), Array(fixture.messageIDs(for: "chat-delete").suffix(478)))
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testDisjointCanonicalTailDoesNotInventContinuityWithPreviouslyLoadedRows() async throws {
        let fixture = ChatLongHistoryFixture(chatIDs: ["chat-replaced"])
        let fake = ChatLongFixtureTransport(fixture: fixture)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(client: makeLongHistoryClient(fixture: fixture), runtime: runtime, sessionID: "chat-replaced")
        await vm.loadMessages()
        let loaded = await vm.loadOlderMessages()
        XCTAssertTrue(loaded)
        fixture.replaceRowIdentities(in: "chat-replaced")
        await vm.loadMessages()
        // No overlap means we cannot claim the old window still belongs to
        // this transcript. Reset to a bounded canonical tail, never blind-union.
        XCTAssertEqual(vm.messages.compactMap(\.messageId), Array(fixture.messageIDs(for: "chat-replaced").suffix(120)))
        XCTAssertTrue(vm.hasOlderMessages)
        let reloaded = await vm.loadOlderMessages()
        XCTAssertTrue(reloaded)
        XCTAssertEqual(fixture.requests().last?.offset, 120)
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testRejectedDirectSteerDoesNotInterruptOrResendPrompt() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setSteerResponse(.object(["status": .string("rejected")]))
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Rejected steer should not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        let didSend = await viewModel.sendMessage("running")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.activeStreamID != nil }
        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "steer"))
        let result = await viewModel.executeSlashCommand(command, args: "follow-up")

        guard case .unsupported(let message) = result else {
            XCTFail("Expected rejected steer result")
            return
        }
        XCTAssertTrue(message.contains("rejected"))
        let methods = fake.calls().map(\.method)
        XCTAssertEqual(methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "session.steer" }.count, 1)
        XCTAssertFalse(methods.contains("session.interrupt"))
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testInvalidatedDirectChatCannotSendAgain() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Invalidated direct chat should not call REST")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)

        viewModel.invalidateDirectConversation()
        let didSend = await viewModel.sendMessage("stale")
        XCTAssertFalse(didSend)
        XCTAssertTrue(fake.calls().isEmpty)
        XCTAssertFalse(viewModel.hasServerBackedSession)
        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testDirectAttachmentSelectionRetainsBytesAndProjectionWithoutRPC() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            XCTFail("Direct attachment selection must not call REST: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: nil)
        let thumbnail = directPNGData
        let initialUploadGeneration = viewModel.attachmentUploadGeneration

        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png", previewData: thumbnail)

        XCTAssertTrue(fake.calls().isEmpty, "Selecting a direct attachment must not create a session or call RPC")
        let pending = try XCTUnwrap(viewModel.directPendingAttachments.first)
        XCTAssertEqual(pending.originalBytes, directPNGData)
        XCTAssertEqual(pending.thumbnailData, thumbnail)
        XCTAssertEqual(viewModel.directPendingAttachmentDisplayItems.first?.name, "photo.png")
        XCTAssertNil(viewModel.directPendingAttachmentDisplayItems.first?.serverPath)
        XCTAssertEqual(viewModel.directPendingAttachmentDisplayItems.first?.localPreviewData, directPNGData)
        XCTAssertFalse(viewModel.isPreparingDirectAttachment)
        XCTAssertNil(viewModel.directAttachmentPreparationErrorMessage)
        XCTAssertEqual(viewModel.attachmentUploadGeneration, initialUploadGeneration + 1)
        viewModel.setUploadAttachmentError("The picker could not read that file.")
        XCTAssertEqual(viewModel.uploadAttachmentErrorMessage, "The picker could not read that file.")
        viewModel.setUploadAttachmentError(nil)
        XCTAssertNil(viewModel.uploadAttachmentErrorMessage)

        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testInvalidDirectAttachmentPreservesEarlierSelection() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Invalid direct attachment selection must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )

        await viewModel.uploadAttachment(data: directPNGData, filename: "kept.png")
        await viewModel.uploadAttachment(data: Data("not an image".utf8), filename: "broken.png")

        XCTAssertEqual(viewModel.directPendingAttachments.count, 1)
        XCTAssertEqual(viewModel.directPendingAttachments.first?.displayFilename, "kept.png")
        XCTAssertNotNil(viewModel.directAttachmentPreparationErrorMessage)
        XCTAssertTrue(fake.calls().isEmpty)
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectAttachmentRemovalAndClearRemoveOnlyPendingSelections() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Direct attachment removal must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )

        await viewModel.uploadAttachment(data: directPNGData, filename: "first.png")
        await viewModel.uploadAttachment(data: directPNGData, filename: "other.png")
        let firstID = try XCTUnwrap(viewModel.directPendingAttachments.first?.id)
        viewModel.removePendingAttachment(id: firstID)
        XCTAssertEqual(viewModel.directPendingAttachments.count, 1)
        XCTAssertEqual(viewModel.directPendingAttachments.first?.displayFilename, "other.png")

        await viewModel.uploadAttachment(data: directPNGData, filename: "second.png")
        viewModel.clearPendingAttachments()
        XCTAssertTrue(viewModel.directPendingAttachments.isEmpty)
        XCTAssertFalse(viewModel.isPreparingDirectAttachment)
        XCTAssertNil(viewModel.directAttachmentPreparationErrorMessage)
        XCTAssertTrue(fake.calls().isEmpty)
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectAttachmentInvalidationRejectsLatePreparationResultAndSendDuringPreparation() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let preparationGate = ChatDirectAsyncGate()
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Late direct attachment selection must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil,
            directAttachmentPreparer: { data, filename, previewData in
                await preparationGate.wait()
                try Task.checkCancellation()
                let source = try DirectGatewayAttachment(data: data, filename: filename)
                return DirectPendingAttachment(source: source, thumbnailData: previewData)
            }
        )
        let selection = Task {
            await viewModel.uploadAttachment(
                data: directPNGData,
                filename: "late.png"
            )
        }
        await waitUntil { viewModel.isPreparingDirectAttachment }
        let didSend = await viewModel.sendMessage("must wait")
        XCTAssertFalse(didSend)
        XCTAssertTrue(fake.calls().isEmpty)
        viewModel.invalidateDirectConversation()
        await preparationGate.release()
        await selection.value

        XCTAssertTrue(viewModel.directPendingAttachments.isEmpty)
        XCTAssertFalse(viewModel.isPreparingDirectAttachment)
        XCTAssertTrue(fake.calls().isEmpty)
        await runtime.stop()
    }

    func testDirectAttachmentImageUsesAuthenticatedManagedFileRouteAndCanonicalSessionIdentity() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let imageURL = "data:image/png;base64,\(directPNGData.base64EncodedString())"
        let viewModel = makeViewModel(
            client: makeClient { request in
                requests.append(request.url?.path ?? "nil")
                XCTAssertEqual(request.url?.path, "/api/files/read")
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertNil(query.first(where: { $0.name == "session_id" }))
                XCTAssertEqual(query.first(where: { $0.name == "path" })?.value, "/managed/images/result.png")
                return apiTestJSONResponse(#"{"data_url":"\#(imageURL)"}"#, for: request)
            },
            runtime: runtime,
            sessionID: "durable-1"
        )

        let data = await viewModel.attachmentImageData(path: "/managed/images/result.png")

        XCTAssertEqual(data, directPNGData)
        XCTAssertEqual(requests.values(), ["/api/files/read"])
        await runtime.stop()
    }

    func testDirectAttachmentImageDropsResponseAfterConversationInvalidation() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let responseGate = DispatchSemaphore(value: 0)
        let imageURL = "data:image/png;base64,\(directPNGData.base64EncodedString())"
        let viewModel = makeViewModel(
            client: makeClient { request in
                requests.append(request.url?.path ?? "nil")
                responseGate.wait()
                return apiTestJSONResponse(#"{"data_url":"\#(imageURL)"}"#, for: request)
            },
            runtime: runtime,
            sessionID: "durable-1"
        )

        let load = Task { await viewModel.attachmentImageData(path: "/managed/images/result.png") }
        await waitUntil { requests.values().contains("/api/files/read") }
        viewModel.invalidateDirectConversation()
        responseGate.signal()

        let loaded = await load.value
        XCTAssertNil(loaded)
        await runtime.stop()
    }

    func testDirectAttachmentRawDataUsesExactAuthenticatedManagedPath() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let bytes = Data("voice-bytes".utf8)
        let encoded = bytes.base64EncodedString()
        var requests = 0
        let viewModel = makeViewModel(client: makeClient { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/files/read")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "path" }?.value, "/profile/attachments/voice.m4a")
            XCTAssertNil(query?.first { $0.name == "session_id" })
            return apiTestJSONResponse("{\"data_url\":\"data:audio/mp4;base64,\(encoded)\"}", for: request)
        }, runtime: runtime, sessionID: "durable-1")

        let loaded = await viewModel.attachmentRawData(path: "/profile/attachments/voice.m4a")
        XCTAssertEqual(loaded, bytes)
        XCTAssertEqual(requests, 1)
        await runtime.stop()
    }

    func testDirectAttachmentRawDataRejectsRelativeAndDropsStaleResponse() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let gate = DispatchSemaphore(value: 0)
        let viewModel = makeViewModel(client: makeClient { request in
            requests.append(request.url?.path ?? "nil")
            gate.wait()
            return apiTestJSONResponse(#"{"data_url":"data:audio/mp4;base64,Y2xpcA=="}"#, for: request)
        }, runtime: runtime, sessionID: "durable-1")

        let relative = await viewModel.attachmentRawData(path: "attachments/voice.m4a")
        XCTAssertNil(relative)
        XCTAssertTrue(requests.values().isEmpty)
        let load = Task { await viewModel.attachmentRawData(path: "/profile/attachments/voice.m4a") }
        await waitUntil { requests.values() == ["/api/files/read"] }
        viewModel.invalidateDirectConversation()
        gate.signal()
        let stale = await load.value
        XCTAssertNil(stale)
        await runtime.stop()
    }

    func testDirectAttachmentRawDataFailureReturnsNilWithoutFallback() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        var requests = 0
        let viewModel = makeViewModel(client: makeClient { _ in
            requests += 1
            throw URLError(.cannotDecodeContentData)
        }, runtime: runtime, sessionID: "durable-1")

        let loaded = await viewModel.attachmentRawData(path: "/profile/attachments/voice.m4a")
        XCTAssertNil(loaded)
        XCTAssertEqual(requests, 1)
        await runtime.stop()
    }

    func testDirectSendStagesSelectionAndClearsConsumedBytes() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Direct attachment send must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "kept.png")

        let didSend = await viewModel.sendMessage("hello")

        XCTAssertTrue(didSend)
        XCTAssertTrue(viewModel.directPendingAttachments.isEmpty)
        XCTAssertEqual(fake.calls().map(\.method), ["session.create", "image.attach_bytes", "prompt.submit"])
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectSendStagesMixedAttachmentsAndPreservesExactAbsoluteFileReference() async throws {
        let fake = ChatDirectFakeTransport()
        // Pinned stock `file.attach` returns the server-owned profile-home path
        // for a remote byte upload. The app must preserve that exact ref through
        // prompt.submit; this proves transport only, not model ingestion.
        fake.setAttachmentResponse("file.attach", .object([
            "attached": .bool(true),
            "name": .string("notes.txt"),
            "path": .string("/fixture/profile/attachments/notes.txt"),
            "ref_path": .string("/fixture/profile/attachments/notes.txt"),
            "ref_text": .string("@file:/fixture/profile/attachments/notes.txt"),
            "uploaded": .bool(true)
        ]))
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Direct attachment send must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")
        await viewModel.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")

        let didSend = await viewModel.sendMessage("describe both")

        XCTAssertTrue(didSend)
        let submit = try XCTUnwrap(fake.calls().last { $0.method == "prompt.submit" })
        let fields = try XCTUnwrap(fields(submit.params))
        let submittedText = try XCTUnwrap(fields["text"]?.gatewayString)
        XCTAssertEqual(submittedText, "describe both\n@file:/fixture/profile/attachments/notes.txt")
        XCTAssertEqual(fake.calls().map(\.method), [
            "session.create", "image.attach_bytes", "file.attach", "prompt.submit"
        ])
        XCTAssertTrue(viewModel.directPendingAttachments.isEmpty)
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectStageDefinitePartialFailurePreservesEarlierReceiptWithoutSubmit() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setAttachmentError("file.attach", .server(
            code: 4015,
            message: "path or data_url required",
            data: nil,
            method: "file.attach",
            requestID: "file-rejected",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Attachment stage must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")
        await viewModel.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")

        let didSend = await viewModel.sendMessage("describe")

        XCTAssertFalse(didSend)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        XCTAssertTrue(viewModel.sendErrorMessage?.contains("notes.txt") == true)
        XCTAssertEqual(viewModel.directPendingAttachments.count, 2)
        if case .confirmed = viewModel.directPendingAttachments[0].stageState {
            // The known server receipt is preserved; it must not be silently detached.
        } else {
            XCTFail("Earlier successful stage must remain confirmed")
        }
        if case .pending = viewModel.directPendingAttachments[1].stageState {
            // The definite failure remains locally retryable.
        } else {
            XCTFail("Definite stage rejection must preserve the pending file")
        }
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectConfirmedGenericFileRemovalIsLocalOnly() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setAttachmentError("image.attach_bytes", .server(
            code: 4015,
            message: "path or data_url required",
            data: nil,
            method: "image.attach_bytes",
            requestID: "image-rejected",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Direct attachment removal must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")
        await viewModel.uploadAttachment(data: directPNGData, filename: "rejected.png")
        let fileID = try XCTUnwrap(viewModel.directPendingAttachments.first?.id)

        let didSend = await viewModel.sendMessage("stage then remove")
        XCTAssertFalse(didSend)
        XCTAssertEqual(viewModel.directPendingAttachments.count, 2)
        if case .confirmed = viewModel.directPendingAttachments[0].stageState {
            // The file receipt is confirmed locally even though no file.detach
            // RPC exists in the pinned stock contract.
        } else {
            XCTFail("The file must be confirmed before local removal")
        }

        viewModel.removePendingAttachment(id: fileID)

        XCTAssertEqual(viewModel.directPendingAttachments.map(\.displayFilename), ["rejected.png"])
        XCTAssertFalse(fake.calls().contains { $0.method == "file.detach" })
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectConfirmedImageRemovalSuccessRemovesOnlyItsChip() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setAttachmentError("file.attach", .server(
            code: 4015,
            message: "path or data_url required",
            data: nil,
            method: "file.attach",
            requestID: "file-rejected",
            server: "fixture"
        ))
        fake.setImageDetachResponse(.object(["detached": .bool(true), "count": .number(0)]))
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Direct attachment removal must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")
        await viewModel.uploadAttachment(data: Data("notes".utf8), filename: "rejected.txt")
        let imageID = try XCTUnwrap(viewModel.directPendingAttachments.first?.id)

        let didSend = await viewModel.sendMessage("stage then remove")
        XCTAssertFalse(didSend)
        viewModel.removePendingAttachment(id: imageID)
        await waitUntil { !viewModel.directPendingAttachments.contains { $0.id == imageID } }

        XCTAssertEqual(viewModel.directPendingAttachments.map(\.displayFilename), ["rejected.txt"])
        XCTAssertEqual(fake.calls().filter { $0.method == "image.detach" }.count, 1)
        XCTAssertNil(viewModel.uploadAttachmentErrorMessage)
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectConfirmedImageRemovalFailureKeepsItsChipAndRecoveryBarrier() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setAttachmentError("file.attach", .server(
            code: 4015,
            message: "path or data_url required",
            data: nil,
            method: "file.attach",
            requestID: "file-rejected",
            server: "fixture"
        ))
        fake.setImageDetachResponse(.object(["detached": .bool(false), "count": .number(0)]))
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Direct attachment removal must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")
        await viewModel.uploadAttachment(data: Data("notes".utf8), filename: "rejected.txt")
        let imageID = try XCTUnwrap(viewModel.directPendingAttachments.first?.id)

        let didSend = await viewModel.sendMessage("stage then keep")
        XCTAssertFalse(didSend)
        viewModel.removePendingAttachment(id: imageID)
        await waitUntil { viewModel.uploadAttachmentErrorMessage?.contains("could not be removed") == true }

        XCTAssertTrue(viewModel.directPendingAttachments.contains { $0.id == imageID })
        XCTAssertTrue(viewModel.attachmentRecoveryNeedsReset)
        XCTAssertTrue(viewModel.uploadAttachmentErrorMessage?.contains("could not be removed") == true)
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectStageUnknownFailureLocksItemAndNeverRestages() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setAttachmentError("image.attach_bytes", .timeout(
            method: "image.attach_bytes",
            requestID: "image-unknown"
        ))
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Attachment stage must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")

        let didSend = await viewModel.sendMessage("describe")
        XCTAssertFalse(didSend)
        let firstStageCount = fake.calls().filter { $0.method == "image.attach_bytes" }.count
        XCTAssertEqual(firstStageCount, 1)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        if case .unknown = viewModel.directPendingAttachments.first?.stageState {
            // Unknown stage outcome is retained and locked against blind retry.
        } else {
            XCTFail("Unknown stage outcome must remain visible and non-retryable")
        }

        fake.setAttachmentError("image.attach_bytes", nil)
        let didRetry = await viewModel.sendMessage("retry")
        XCTAssertFalse(didRetry)
        XCTAssertEqual(fake.calls().filter { $0.method == "image.attach_bytes" }.count, firstStageCount)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectSendBlocksSelectionMutationWhileStaging() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setAttachmentGate("image.attach_bytes", gate)
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Direct attachment send must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")
        let send = Task { await viewModel.sendMessage("describe") }
        await waitUntil { fake.calls().contains { $0.method == "image.attach_bytes" } }

        viewModel.clearPendingAttachments()
        XCTAssertEqual(viewModel.directPendingAttachments.count, 1)
        XCTAssertTrue(viewModel.uploadAttachmentErrorMessage?.contains("current direct message") == true)
        await gate.release()
        let didSend = await send.value
        XCTAssertTrue(didSend)
        XCTAssertTrue(viewModel.directPendingAttachments.isEmpty)
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectSendInvalidationPreventsLateStageSubmit() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setAttachmentGate("image.attach_bytes", gate)
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Invalidated direct send must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")
        let send = Task { await viewModel.sendMessage("describe") }
        await waitUntil { fake.calls().contains { $0.method == "image.attach_bytes" } }

        viewModel.invalidateDirectConversation()
        await gate.release()
        let didSend = await send.value
        XCTAssertFalse(didSend)
        XCTAssertTrue(viewModel.directPendingAttachments.isEmpty)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await runtime.stop()
    }

    func testDirectSendCancellationAfterSubmitDispatchKeepsUncertainTranscriptAndClearsConsumed() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setPromptSubmitGate(gate)
        fake.setPromptSubmitCancellation(true)
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                XCTFail("Direct send cancellation must not call REST: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")
        let send = Task { await viewModel.sendMessage("describe") }
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }

        send.cancel()
        await gate.release()
        let didSend = await send.value

        XCTAssertTrue(didSend, "A dispatched cancellation remains delivery-uncertain under existing send semantics")
        XCTAssertTrue(viewModel.directPendingAttachments.isEmpty)
        XCTAssertTrue(viewModel.sendErrorMessage?.contains("cannot confirm") == true)
        XCTAssertTrue(viewModel.messages.contains { $0.role == "user" && $0.content == "describe" })
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        let callsAfterUncertainSend = fake.calls().count
        let retry = await viewModel.sendMessage("retry")
        XCTAssertFalse(retry)
        XCTAssertEqual(fake.calls().count, callsAfterUncertainSend)
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectSendLateCancellationAfterTerminalStaysAmbiguousAndCannotRetry() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setPromptSubmitGate(gate)
        fake.setPromptSubmitCancellation(true)
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeClient { request in
                guard request.url?.path == "/api/sessions/durable-1/messages" else {
                    XCTFail("Unexpected terminal reconciliation path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
                return apiTestJSONResponse(
                    #"{"session_id":"durable-1","messages":[{"id":1,"role":"user","content":"describe","timestamp":1},{"id":2,"role":"assistant","content":"streamed answer","timestamp":2}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#,
                    for: request
                )
            },
            runtime: runtime,
            sessionID: nil
        )
        await viewModel.uploadAttachment(data: directPNGData, filename: "photo.png")
        let send = Task { await viewModel.sendMessage("describe") }
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        await yieldUntil { viewModel.activeStreamID != nil }

        // The terminal event arrives while the RPC acknowledgement is still
        // gated. Cancelling the late RPC continuation must remain ambiguous
        // even though a terminal receipt already exists.
        let completionCountBeforeTerminal = viewModel.responseCompletionHapticTrigger
        fake.emitCompletion()
        await waitUntil {
            viewModel.responseCompletionHapticTrigger > completionCountBeforeTerminal
        }
        send.cancel()
        await gate.release()
        let didSend = await send.value

        XCTAssertTrue(didSend)
        XCTAssertTrue(viewModel.directPendingAttachments.isEmpty)
        XCTAssertTrue(viewModel.sendErrorMessage?.contains("cannot confirm") == true)
        XCTAssertTrue(viewModel.messages.contains { $0.role == "user" && $0.content == "describe" })
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)

        // A later terminal event does not prove the late acknowledgement safe;
        // the controller's ambiguity remains sticky and prevents a replay.
        fake.emitCompletion(sequence: 4)
        await Task.yield()
        let callsAfterUncertainSend = fake.calls().count
        let retry = await viewModel.sendMessage("retry")
        XCTAssertFalse(retry)
        XCTAssertEqual(fake.calls().count, callsAfterUncertainSend)
        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testDirectAmbiguousResumeReassertsBannerAndDropsUnconfirmedOptimisticRow() async throws {
        let fake = ChatDirectFakeTransport()
        let gate = ChatDirectAsyncGate()
        fake.setPromptSubmitGate(gate)
        fake.setPromptSubmitCancellation(true)
        let runtime = try makeRuntime(fake)
        let viewModel = makeViewModel(
            client: makeExistingComposerClient(requests: ChatDirectRequestRecorder()),
            runtime: runtime,
            sessionID: nil
        )

        let send = Task { await viewModel.sendMessage("uncertain prompt") }
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        send.cancel()
        await gate.release()

        let didSend = await send.value
        XCTAssertTrue(didSend)
        XCTAssertTrue(viewModel.sendErrorMessage?.contains("cannot confirm") == true)
        XCTAssertTrue(viewModel.messages.contains { $0.role == "user" && $0.content == "uncertain prompt" })

        // A benign terminal event may arrive before the reconnect. It must not
        // erase the sticky delivery warning or make the optimistic row look
        // like a confirmed ordinary turn.
        let completionCountBeforeTerminal = viewModel.responseCompletionHapticTrigger
        fake.emitCompletion()
        await waitUntil {
            viewModel.responseCompletionHapticTrigger > completionCountBeforeTerminal
        }
        XCTAssertTrue(viewModel.sendErrorMessage?.contains("cannot confirm") == true)

        // Reconnect is read-only recovery. The fake canonical transcript is
        // empty, so the unpersisted optimistic row must not become a ghost;
        // the warning and delivery barrier remain.
        viewModel.setSendErrorMessage(nil)
        try await runtime.reconnect()
        await waitUntil { viewModel.sendErrorMessage?.contains("cannot confirm") == true }
        XCTAssertFalse(viewModel.messages.contains { $0.role == "local_notice" })
        XCTAssertFalse(viewModel.messages.contains { $0.role == "user" && $0.content == "uncertain prompt" })
        XCTAssertTrue(viewModel.sendErrorMessage?.contains("cannot confirm") == true,
                      "Ambiguous delivery stays visible in the composer recovery warning.")
        let callsBeforeBlockedDraft = fake.calls().count
        let blocked = await viewModel.sendMessage("next draft")
        XCTAssertFalse(blocked)
        XCTAssertEqual(fake.calls().count, callsBeforeBlockedDraft)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)

        viewModel.invalidateDirectConversation()
        await runtime.stop()
    }

    func testAcceptedSendDisconnectThenCompletedCanonicalResumeAllowsExplicitNextSendOnce() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            let path = request.url?.path ?? "nil"
            requests.append(path)
            guard path == "/api/sessions/durable-1/messages" else {
                XCTFail("Unexpected lifecycle reconciliation path: \(path)")
                throw URLError(.badURL)
            }
            let rows = requests.isTerminalPhase
                ? #"[{"id":1,"role":"user","content":"accepted question","timestamp":1},{"id":2,"role":"assistant","content":"canonical completed answer","timestamp":2}]"#
                : "[]"
            let returned = requests.isTerminalPhase ? 2 : 0
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":\#(rows),"pagination":{"limit":120,"offset":0,"order":"latest","returned":\#(returned)}}"#,
                for: request
            )
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")

        let firstAccepted = await viewModel.sendMessage("accepted question")
        XCTAssertTrue(firstAccepted)
        await waitUntil { viewModel.activeStreamID != nil }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)

        fake.emitClosed()
        requests.beginTerminalPhase()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-1"),
            "session_key": .string("durable-1"),
            "running": .bool(false)
        ]))

        try await runtime.reconnect()
        await viewModel.refreshAfterSceneActivation()
        await waitUntil {
            viewModel.activeStreamID == nil
                && viewModel.messages.contains { $0.content == "canonical completed answer" }
        }

        let nextAccepted = await viewModel.sendMessage("explicit next question")
        XCTAssertTrue(nextAccepted)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 2,
            "Foreground recovery must not submit; the explicit next send submits exactly once")

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    func testSendResumeEmptyReconcileKeepsExistingRowsVisibleUntilOptimisticAppend() async throws {
        let fake = ChatDirectFakeTransport()
        let attachmentGate = ChatDirectAsyncGate()
        fake.setAttachmentGate("file.attach", attachmentGate)
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            guard request.httpMethod == "GET",
                  request.url?.path == "/api/sessions/durable-1/messages" else {
                XCTFail("Send resume should only reconcile the direct transcript: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            // This models the stock resume/read race: the existing durable
            // session is known locally, but its canonical tail briefly reads
            // empty before the send is persisted.
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":[],"pagination":{"limit":120,"offset":0,"order":"latest","returned":0}}"#,
                for: request
            )
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        vm.seedTranscriptForTesting([
            ChatMessage(role: "user", content: "Existing question", timestamp: 1, messageId: "existing-user"),
            ChatMessage(role: "assistant", content: "Existing answer", timestamp: 2, messageId: "existing-assistant")
        ])
        await vm.uploadAttachment(data: Data("fixture body".utf8), filename: "fixture.txt")
        XCTAssertEqual(vm.directPendingAttachments.count, 1)

        let send = Task { await vm.sendMessage("Next question") }
        await waitUntil { fake.calls().contains { $0.method == "file.attach" } }

        // The attachment ACK is held after resume's empty transcript callback
        // and before the optimistic row is appended. The old implementation
        // exposed an empty transcript here; the existing rows must remain
        // renderable throughout this real send ordering.
        XCTAssertEqual(vm.messages.compactMap(\.messageId), ["existing-user", "existing-assistant"])
        XCTAssertTrue(vm.messages.contains { $0.content == "Existing answer" })

        await attachmentGate.release()
        let didSend = await send.value
        XCTAssertTrue(didSend)
        XCTAssertTrue(vm.messages.contains { $0.content == "Next question" })
        XCTAssertTrue(vm.messages.contains { $0.content == "Existing answer" })

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testOrdinaryAuthoritativeEmptyTranscriptRefreshClearsExistingRows() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeEmptyDirectTranscriptClient(sessionID: "durable-1"),
            runtime: runtime,
            sessionID: "durable-1"
        )
        seedExistingTranscript(in: vm)

        await vm.loadMessages()

        XCTAssertTrue(vm.messages.isEmpty,
                      "An ordinary canonical empty page remains authoritative outside the send window.")
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testSendResumeEmptyForAdoptedCanonicalSessionDropsPreviousRows() async throws {
        let fake = ChatDirectFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-1"),
            "session_key": .string("different-tip"),
            "running": .bool(false)
        ]))
        let attachmentGate = ChatDirectAsyncGate()
        fake.setAttachmentGate("file.attach", attachmentGate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeEmptyDirectTranscriptClient(sessionID: "different-tip"),
            runtime: runtime,
            sessionID: "durable-1"
        )
        seedExistingTranscript(in: vm)
        await vm.uploadAttachment(data: Data("fixture body".utf8), filename: "fixture.txt")

        let send = Task { await vm.sendMessage("Next question") }
        await waitUntil { fake.calls().contains { $0.method == "file.attach" } }

        XCTAssertTrue(vm.messages.isEmpty,
                      "A canonical-ID rollover must not retain the previous session's rows.")

        await attachmentGate.release()
        let didSend = await send.value
        XCTAssertTrue(didSend)
        XCTAssertFalse(vm.messages.contains { $0.content == "Existing answer" })
        XCTAssertTrue(vm.messages.contains { $0.content == "Next question" })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testExplicitClearDuringResumeEmptyGateWinsOverProtection() async throws {
        let fake = ChatDirectFakeTransport()
        let attachmentGate = ChatDirectAsyncGate()
        fake.setAttachmentGate("file.attach", attachmentGate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeEmptyDirectTranscriptClient(sessionID: "durable-1"),
            runtime: runtime,
            sessionID: "durable-1"
        )
        seedExistingTranscript(in: vm)
        await vm.uploadAttachment(data: Data("fixture body".utf8), filename: "fixture.txt")

        let send = Task { await vm.sendMessage("Next question") }
        await waitUntil { fake.calls().contains { $0.method == "file.attach" } }
        XCTAssertTrue(vm.messages.contains { $0.content == "Existing answer" })

        vm.clearTranscript()
        // Re-seed only to make the subsequent ordinary empty refresh observable;
        // the explicit clear must cancel the protected resume window first.
        vm.seedTranscriptForTesting([
            ChatMessage(role: "assistant", content: "Post-clear fixture", timestamp: 3, messageId: "post-clear")
        ])
        await vm.loadMessages()
        XCTAssertTrue(vm.messages.isEmpty,
                      "An empty refresh after explicit clear must not be protected by the earlier send.")

        await attachmentGate.release()
        let didSend = await send.value
        XCTAssertTrue(didSend)
        XCTAssertFalse(vm.messages.contains { $0.content == "Existing answer" })
        XCTAssertFalse(vm.messages.contains { $0.content == "Post-clear fixture" })
        XCTAssertTrue(vm.messages.contains { $0.content == "Next question" })
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testInvalidationDuringResumeEmptyGateStopsSendWithoutReapplyingRows() async throws {
        let fake = ChatDirectFakeTransport()
        let attachmentGate = ChatDirectAsyncGate()
        fake.setAttachmentGate("file.attach", attachmentGate)
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeEmptyDirectTranscriptClient(sessionID: "durable-1"),
            runtime: runtime,
            sessionID: "durable-1"
        )
        seedExistingTranscript(in: vm)
        await vm.uploadAttachment(data: Data("fixture body".utf8), filename: "fixture.txt")

        let send = Task { await vm.sendMessage("Next question") }
        await waitUntil { fake.calls().contains { $0.method == "file.attach" } }
        XCTAssertTrue(vm.messages.contains { $0.content == "Existing answer" })

        vm.invalidateDirectConversation()
        await attachmentGate.release()

        let didSend = await send.value
        XCTAssertFalse(didSend,
                       "Invalidation during attachment staging must stop the send before insertion.")
        XCTAssertTrue(vm.messages.contains { $0.content == "Existing answer" })
        XCTAssertFalse(vm.messages.contains { $0.content == "Next question" })
        await runtime.stop()
    }

    func testForegroundReentryTransientEmptyReadNeverSilentlyBlanksPopulatedRows() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let vm = makeViewModel(
            client: makeEmptyDirectTranscriptClient(sessionID: "durable-1"),
            runtime: runtime,
            sessionID: "durable-1"
        )
        seedExistingTranscript(in: vm)

        // Foreground re-entry reads a transiently empty canonical page while the
        // transcript is already populated (P01 blank-after-background class).
        // The populated rows must survive the read, or the user must see an
        // explicit error — never a silent blank transcript.
        await vm.refreshAfterSceneActivation()

        let silentBlank = vm.messages.isEmpty && vm.sendErrorMessage == nil && vm.errorMessage == nil
        XCTAssertFalse(silentBlank,
            "Foreground re-entry with a transient empty read must keep populated rows visible or surface an explicit error "
                + "(blank=\(vm.messages.isEmpty), sendError=\(String(describing: vm.sendErrorMessage)), error=\(String(describing: vm.errorMessage)))")
        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testOldChatDetailEntryReusingSessionStoreNeverSilentlyBlanksOnEmptyCanonicalRead() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeEmptyDirectTranscriptClient(sessionID: "durable-1")
        let store = OpenChatSessionStore()
        let original = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        seedExistingTranscript(in: original)
        _ = store.adoptedViewModel(
            session: SessionSummary(sessionId: "durable-1", profile: "work"),
            server: testServer,
            creating: original
        )
        XCTAssertEqual(store.retainedSessionCountForTesting, 1)

        // Detail re-entry for the old chat must reuse the retained model.
        let reused = store.viewModel(
            session: SessionSummary(sessionId: "durable-1", profile: "work"),
            server: testServer
        )
        XCTAssertTrue(reused === original, "Old-chat detail entry must reuse the session-store model")
        XCTAssertTrue(reused.messages.contains { $0.content == "Existing answer" },
                      "The reused model still renders the old chat transcript")

        // The reused model's canonical read transiently returns empty on entry.
        await reused.loadMessages()

        let silentBlank = reused.messages.isEmpty && reused.sendErrorMessage == nil && reused.errorMessage == nil
        XCTAssertFalse(silentBlank,
            "Old-chat detail entry with session-store reuse must not silently blank a populated transcript on an empty canonical read "
                + "(blank=\(reused.messages.isEmpty), sendError=\(String(describing: reused.sendErrorMessage)), error=\(String(describing: reused.errorMessage)))")
        await reused.disposeDirectConversation()
        await runtime.stop()
    }

    func testTransientBlankThenNonemptyReconcileRecoversAllowingExactlyOneSubsequentSend() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let requests = ChatDirectRequestRecorder()
        let client = makeClient { request in
            let path = request.url?.path ?? "nil"
            requests.append(path)
            guard request.httpMethod == "GET", path == "/api/sessions/durable-1/messages" else {
                XCTFail("Transient-blank recovery should only reconcile the direct transcript: \(path)")
                throw URLError(.badURL)
            }
            let rows = requests.isTerminalPhase
                ? #"[{"id":1,"role":"user","content":"Recovered question","timestamp":1},{"id":2,"role":"assistant","content":"Recovered canonical answer","timestamp":2}]"#
                : "[]"
            let returned = requests.isTerminalPhase ? 2 : 0
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":\#(rows),"pagination":{"limit":120,"offset":0,"order":"latest","returned":\#(returned)}}"#,
                for: request
            )
        }
        let vm = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")
        seedExistingTranscript(in: vm)

        // The first reconcile observes the transiently blank canonical page.
        await vm.loadMessages()
        // The later authoritative read returns the nonempty canonical tail: the
        // transcript must recover from the transient blank instead of staying blank.
        requests.beginTerminalPhase()
        await vm.loadMessages()

        XCTAssertFalse(vm.messages.isEmpty,
                      "The nonempty reconcile must restore the transcript after the transient blank")
        XCTAssertTrue(vm.messages.contains { $0.content == "Recovered question" })
        XCTAssertTrue(vm.messages.contains { $0.content == "Recovered canonical answer" })
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 0,
                       "Recovery itself must never submit")

        let didSend = await vm.sendMessage("Explicit next question")
        XCTAssertTrue(didSend)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1,
                       "Exactly one subsequent send submits exactly once")
        XCTAssertEqual(vm.messages.filter { $0.role == "user" && $0.content == "Explicit next question" }.count, 1)
        XCTAssertTrue(vm.messages.contains { $0.content == "Recovered canonical answer" },
                      "Recovered rows must remain visible after the explicit send")

        await vm.disposeDirectConversation()
        await runtime.stop()
    }

    func testLostTerminalRunningTrueResumeReattachesWithoutResubmitting() async throws {
        let fake = ChatDirectFakeTransport()
        let runtime = try makeRuntime(fake)
        let client = makeClient { request in
            guard request.httpMethod == "GET",
                  request.url?.path == "/api/sessions/durable-1/messages" else {
                XCTFail("Lost-terminal reattach should only read the direct transcript: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":[{"id":1,"role":"user","content":"accepted question","timestamp":1}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":1}}"#,
                for: request
            )
        }
        let viewModel = makeViewModel(client: client, runtime: runtime, sessionID: "durable-1")

        let firstAccepted = await viewModel.sendMessage("accepted question")
        XCTAssertTrue(firstAccepted)
        await waitUntil { viewModel.activeStreamID != nil }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)

        // The terminal event is lost with the connection, but Hermes is still
        // running. Resume must reattach to the live session, never resubmit.
        fake.emitClosed()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-1"),
            "session_key": .string("durable-1"),
            "running": .bool(true)
        ]))

        try await runtime.reconnect()
        await viewModel.refreshAfterSceneActivation()

        await waitUntil {
            viewModel.activeStreamID == "direct-run:durable-1"
                && !viewModel.isActiveStreamConnectionSuspended
        }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1,
                       "Lost-terminal resume must reattach to the running session, never resubmit the prompt")
        XCTAssertTrue(viewModel.messages.contains { $0.role == "user" && $0.content == "accepted question" })
        XCTAssertFalse(viewModel.messages.contains { $0.role == "local_notice" })
        XCTAssertNil(viewModel.sendErrorMessage)

        // The reattached stream routes live events again.
        fake.emit(ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "tool.start",
            sequence: 3,
            payload: ["tool_id": .string("reattached-tool"), "name": .string("read_file")],
            connectionGeneration: 2
        ))
        await waitUntil { viewModel.liveToolCalls.map(\.id).contains("reattached-tool") }

        await viewModel.disposeDirectConversation()
        await runtime.stop()
    }

    private func seedExistingTranscript(in vm: ChatViewModel) {
        vm.seedTranscriptForTesting([
            ChatMessage(role: "user", content: "Existing question", timestamp: 1, messageId: "existing-user"),
            ChatMessage(role: "assistant", content: "Existing answer", timestamp: 2, messageId: "existing-assistant")
        ])
    }

    private func makeEmptyDirectTranscriptClient(sessionID: String) -> APIClient {
        makeClient { request in
            guard request.httpMethod == "GET",
                  request.url?.path == "/api/sessions/\(sessionID)/messages" else {
                XCTFail("Unexpected direct transcript request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                "{\"session_id\":\"\(sessionID)\",\"messages\":[],\"pagination\":{\"limit\":120,\"offset\":0,\"order\":\"latest\",\"returned\":0}}",
                for: request
            )
        }
    }

    private let testServer = URL(string: "https://fixture.example")!

    private var directPNGData: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    private func clarificationEvent(requestID: String, sequence: Int) -> HermesGatewayEvent {
        ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "clarify.request",
            sequence: sequence,
            payload: [
                "request_id": .string(requestID),
                "question": .string("Choose a bounded answer"),
                "choices": .array([.string("answer"), .string("cancel")]),
                "multi_select": .bool(false)
            ]
        )
    }

    private func approvalEvent(requestID: String, sequence: Int) -> HermesGatewayEvent {
        ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "approval.request",
            sequence: sequence,
            payload: [
                "request_id": .string(requestID),
                "command": .string("echo fixture"),
                "description": .string("Allow the bounded fixture command"),
                "pattern_key": .string("fixture.command"),
                "pattern_keys": .array([.string("fixture.command")]),
                "allow_session": .bool(true),
                "allow_permanent": .bool(false),
                "choices": .array([.string("once"), .string("session"), .string("deny")])
            ]
        )
    }

    private func secretEvent(requestID: String, sequence: Int) -> HermesGatewayEvent {
        ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "secret.request",
            sequence: sequence,
            payload: [
                "request_id": .string(requestID),
                "prompt": .string("Enter the fixture secret"),
                "env_var": .string("FIXTURE_SECRET")
            ]
        )
    }

    private func sudoEvent(requestID: String, sequence: Int) -> HermesGatewayEvent {
        ChatDirectEventFactory.event(
            sessionID: "runtime-1",
            type: "sudo.request",
            sequence: sequence,
            payload: ["request_id": .string(requestID)]
        )
    }

    private func makeViewModel(
        client: APIClient,
        runtime: HermesServerRuntime,
        sessionID: String?,
        session: SessionSummary? = nil,
        defaults: UserDefaults = .standard,
        directAttachmentPreparer: (@Sendable (Data, String, Data?) async throws -> DirectPendingAttachment)? = nil,
        recoveryMarkerStore: (any DirectGatewayAttachmentRecoveryMarkerStoreProtocol)? = nil,
        promptUncertaintyStore: (any DirectPromptDeliveryUncertaintyStoreProtocol)? = nil
    ) -> ChatViewModel {
        let isolatedMarkerStore = recoveryMarkerStore ?? DirectGatewayAttachmentRecoveryMarkerStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ChatViewModelDirectGatewayTests-\(UUID().uuidString)", isDirectory: true)
        )
        return ChatViewModel(
            session: session ?? SessionSummary(sessionId: sessionID, title: "New Chat", profile: "work"),
            server: testServer,
            client: client,
            liveActivityManager: ChatDirectNoopLiveActivityManager(),
            userDefaults: defaults,
            gatewayRuntimeProvider: { _ in runtime },
            directAttachmentPreparer: directAttachmentPreparer,
            directAttachmentRecoveryMarkerStore: isolatedMarkerStore,
            promptUncertaintyStore: promptUncertaintyStore ?? InMemoryDirectPromptDeliveryUncertaintyStore()
        )
    }

    private func makeRuntime(_ fake: ChatDirectFakeTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: testServer) { sink in
            fake.installSink(sink)
            return fake
        }
    }

    private func makeRuntime(_ fake: ChatLongFixtureTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: testServer) { sink in
            fake.installSink(sink)
            return fake
        }
    }

    private func makeLongHistoryClient(fixture: ChatLongHistoryFixture) -> APIClient {
        makeClient { request in
            guard request.url?.path.contains("/api/sessions/") == true,
                  request.url?.path.hasSuffix("/messages") == true,
                  let chatID = request.url?.path.split(separator: "/").dropLast().last.map(String.init)
            else {
                XCTFail("Unexpected long-history REST path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            return fixture.response(for: request, chatID: chatID)
        }
    }

    private func makeExistingComposerClient(requests: ChatDirectRequestRecorder) -> APIClient {
        makeClient { request in
            let path = request.url?.path ?? "nil"
            requests.append(path)
            switch path {
            case "/api/model/options":
                return apiTestJSONResponse(#"{"model":"model-a","provider":"fixture","providers":[{"slug":"fixture","name":"Fixture","authenticated":true,"models":["model-a","model-b"],"capabilities":{"model-a":{"reasoning":false},"model-b":{"reasoning":true,"can_disable_reasoning":false}}}]}"#, for: request)
            case "/api/profiles":
                return apiTestJSONResponse(#"{"profiles":[{"name":"work"}],"active":"work"}"#, for: request)
            default:
                guard path.hasPrefix("/api/sessions/") && path.hasSuffix("/messages") else {
                    XCTFail("Unexpected legacy/direct REST request: \(path)")
                    throw URLError(.badURL)
                }
                return apiTestJSONResponse(#"{"session_id":"durable-1","messages":[],"pagination":{"limit":120,"offset":0,"order":"desc","returned":0}}"#, for: request)
            }
        }
    }

    private func makeDirectBlockingTestClient() -> APIClient {
        makeClient { request in
            guard request.httpMethod == "GET",
                  request.url?.path == "/api/sessions/durable-1/messages" else {
                XCTFail("Unexpected direct blocking REST request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":[],"pagination":{"limit":120,"offset":0,"order":"latest","returned":0}}"#,
                for: request
            )
        }
    }

    private func fields(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value, case .object(let fields) = value else { return nil }
        return fields
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func yieldUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

@MainActor
private final class ChatDirectNoopLiveActivityManager: AgentLiveActivityManaging {
    func start(sessionID: String, sessionTitle: String, streamID: String?) {}
    func update(_ event: AgentLiveActivityEvent) {}
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}

private enum ChatDirectEventFactory {
    static func event(
        sessionID: String,
        type: String,
        sequence: Int,
        payload: [String: JSONValue]? = nil,
        connectionGeneration: Int = 1
    ) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: "event",
            type: type,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload.map(JSONValue.object),
            params: nil,
            connectionGeneration: connectionGeneration
        )
    }
}

private final class ChatDirectRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var terminalPhase = false

    var isTerminalPhase: Bool {
        lock.withLock { terminalPhase }
    }

    func beginTerminalPhase() {
        lock.withLock { terminalPhase = true }
    }

    func append(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private enum ChatLongFixtureError: Error {
    case pagingLimitExceeded
    case pagingStalled
}

private final class ChatDirectFakeTransport: HermesGatewayTransport, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let params: JSONValue?
    }

    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var callsValue: [Call] = []
    private var generation = 0
    private var connected = false
    private var steerResponse: JSONValue = .object(["status": .string("accepted")])
    private var promptSubmitResponse: JSONValue = .object(["status": .string("streaming")])
    private var btwGate: ChatDirectAsyncGate?
    private var backgroundGate: ChatDirectAsyncGate?
    private var backgroundRequestCount = 0
    private var emitsPromptEvents = true
    private var resumeResponse: JSONValue = .object([
        "session_id": .string("runtime-1"),
        "session_key": .string("durable-1"),
        "info": .object([
            "model": .string("model-b"),
            "provider": .string("fixture"),
            "profile": .string("work"),
            "reasoning_effort": .string("medium")
        ])
    ])
    private var branchResponse: JSONValue?
    private var compressResponse: JSONValue?
    private var reasoningGetResponse: JSONValue = .object([
        "value": .string("medium"),
        "display": .string("show"),
        "session_reasoning_contract": .number(1),
        "deferred": .bool(false)
    ])
    private var reasoningSetResponse: JSONValue?
    private var reasoningSetGate: ChatDirectAsyncGate?
    private var reasoningSetShouldFail = false
    private var updatesReasoningReadback = false
    private var sessionStatusResponse: JSONValue = .object([
        "output": .string("Agent Running: No")
    ])
    private var usageResponse: JSONValue = .object([:])
    private var usageGate: ChatDirectAsyncGate?
    private var clarifyResponse: JSONValue = .object(["status": .string("ok")])
    private var sessionCloseResponse: JSONValue = .object([:])
    private var resumeResponseAfterSessionClose: JSONValue?
    private var clarifyGate: ChatDirectAsyncGate?
    private var attachmentResponses: [String: JSONValue] = [:]
    private var imageDetachResponse: JSONValue = .object(["detached": .bool(false), "count": .number(0)])
    private var attachmentErrors: [String: HermesGatewayError] = [:]
    private var blockingResponses: [String: JSONValue] = [
        "approval.respond": .object(["resolved": .number(1)]),
        "secret.respond": .object(["status": .string("ok")]),
        "sudo.respond": .object(["status": .string("ok")]),
        "approval.pending": .object(["approvals": .array([])])
    ]
    private var blockingErrors: [String: HermesGatewayError] = [:]
    private var attachmentGates: [String: ChatDirectAsyncGate] = [:]
    private var promptSubmitGate: ChatDirectAsyncGate?
    private var promptSubmitShouldCancel = false

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        withLock { self.sink = sink }
    }

    func setSteerResponse(_ response: JSONValue) {
        withLock { steerResponse = response }
    }

    func setPromptSubmitResponse(_ response: JSONValue) {
        withLock { promptSubmitResponse = response }
    }

    func setEmitsPromptEvents(_ enabled: Bool) {
        withLock { emitsPromptEvents = enabled }
    }

    func setResumeResponse(_ response: JSONValue) {
        withLock { resumeResponse = response }
    }

    func setBranchResponse(_ response: JSONValue) {
        withLock { branchResponse = response }
    }

    func setCompressResponse(_ response: JSONValue) {
        withLock { compressResponse = response }
    }

    func setReasoningGetResponse(_ response: JSONValue) {
        withLock { reasoningGetResponse = response }
    }

    func setReasoningSetResponse(_ response: JSONValue) {
        withLock { reasoningSetResponse = response }
    }

    func setReasoningSetGate(_ gate: ChatDirectAsyncGate) {
        withLock { reasoningSetGate = gate }
    }

    func setReasoningSetFailure(_ enabled: Bool) {
        withLock { reasoningSetShouldFail = enabled }
    }

    func setUpdatesReasoningReadback(_ enabled: Bool) {
        withLock { updatesReasoningReadback = enabled }
    }

    func setSessionStatusResponse(_ response: JSONValue) {
        withLock { sessionStatusResponse = response }
    }

    func setUsageResponse(_ response: JSONValue) {
        withLock { usageResponse = response }
    }

    func setUsageGate(_ gate: ChatDirectAsyncGate?) {
        withLock { usageGate = gate }
    }

    func setClarifyGate(_ gate: ChatDirectAsyncGate?) {
        withLock { clarifyGate = gate }
    }

    func setClarifyResponse(_ response: JSONValue) {
        withLock { clarifyResponse = response }
    }

    func setSessionCloseResponse(_ response: JSONValue) {
        withLock { sessionCloseResponse = response }
    }

    func setResumeResponseAfterSessionClose(_ response: JSONValue) {
        withLock { resumeResponseAfterSessionClose = response }
    }

    func setAttachmentResponse(_ method: String, _ response: JSONValue) {
        withLock { attachmentResponses[method] = response }
    }

    func setImageDetachResponse(_ response: JSONValue) {
        withLock { imageDetachResponse = response }
    }

    func setBlockingResponse(_ method: String, _ response: JSONValue) {
        withLock { blockingResponses[method] = response }
    }

    func setBlockingError(_ method: String, _ error: HermesGatewayError?) {
        withLock {
            if let error { blockingErrors[method] = error }
            else { blockingErrors.removeValue(forKey: method) }
        }
    }

    func setAttachmentError(_ method: String, _ error: HermesGatewayError?) {
        withLock {
            if let error { attachmentErrors[method] = error }
            else { attachmentErrors.removeValue(forKey: method) }
        }
    }

    func setAttachmentGate(_ method: String, _ gate: ChatDirectAsyncGate?) {
        withLock {
            if let gate { attachmentGates[method] = gate }
            else { attachmentGates.removeValue(forKey: method) }
        }
    }

    func setPromptSubmitGate(_ gate: ChatDirectAsyncGate?) {
        withLock { promptSubmitGate = gate }
    }

    func setBtwGate(_ gate: ChatDirectAsyncGate?) {
        withLock { btwGate = gate }
    }

    func setBackgroundGate(_ gate: ChatDirectAsyncGate?) {
        withLock { backgroundGate = gate }
    }

    func setPromptSubmitCancellation(_ enabled: Bool) {
        withLock { promptSubmitShouldCancel = enabled }
    }

    func calls() -> [Call] {
        withLock { callsValue }
    }

    func connect() async throws {
        withLock {
            generation += 1
            connected = true
        }
    }

    func close() async {
        withLock { connected = false }
    }

    func connectionIdentifier() async -> Int? {
        withLock { connected ? generation : nil }
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        let requestError = withLock { attachmentErrors[method] ?? blockingErrors[method] }
        let behavior = withLock { () -> (JSONValue?, JSONValue?, ChatDirectAsyncGate?, Bool, JSONValue?, JSONValue?) in
            callsValue.append(Call(method: method, params: params))
            switch method {
            case "session.create":
                return (.object([
                    "session_id": .string("runtime-1"),
                    "session_key": .string("durable-1")
                ]), nil, nil, false, nil, nil)
            case "session.resume", "session.info":
                return (resumeResponse, nil, nil, false, nil, nil)
            case "session.branch":
                return (branchResponse ?? .object([:]), nil, nil, false, nil, nil)
            case "session.compress":
                return (compressResponse ?? .object([:]), nil, nil, false, nil, nil)
            case "config.get":
                return (reasoningGetResponse, nil, nil, false, nil, nil)
            case "config.set":
                return (reasoningSetResponse, reasoningSetResponse, reasoningSetGate,
                        reasoningSetShouldFail, nil, params)
            case "prompt.submit":
                let sink = emitsPromptEvents ? self.sink : nil
                Task {
                    sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.start", sequence: 1))
                    sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.delta", sequence: 2, payload: ["text": .string("streamed answer")]))
                }
                return (promptSubmitResponse, nil, promptSubmitGate, false, nil, nil)
            case "prompt.btw":
                return (.object(["task_id": .string("btw-1")]), nil, btwGate, false, nil, nil)
            case "prompt.background":
                backgroundRequestCount += 1
                return (.object(["task_id": .string("background-\(backgroundRequestCount)")]),
                        nil, backgroundGate, false, nil, nil)
            case "session.steer":
                return (steerResponse, nil, nil, false, nil, nil)
            case "session.interrupt":
                return (.object(["status": .string("interrupted")]), nil, nil, false, nil, nil)
            case "session.status":
                return (sessionStatusResponse, nil, nil, false, nil, nil)
            case "session.usage":
                return (usageResponse, nil, usageGate, false, nil, nil)
            case "session.close":
                if let resumeResponseAfterSessionClose {
                    self.resumeResponse = resumeResponseAfterSessionClose
                    self.resumeResponseAfterSessionClose = nil
                }
                return (sessionCloseResponse, nil, nil, false, nil, nil)
            case "clarify.respond":
                return (clarifyResponse, nil, clarifyGate, false, nil, nil)
            case "image.attach_bytes", "file.attach", "pdf.attach":
                let response = attachmentResponses[method] ?? Self.defaultAttachmentResponse(for: method)
                return (response, nil, attachmentGates[method], false, nil, nil)
            case "image.detach":
                return (imageDetachResponse, nil, nil, false, nil, nil)
            case "approval.respond", "secret.respond", "sudo.respond", "approval.pending":
                return (blockingResponses[method] ?? .object([:]), nil, nil, false, nil, nil)
            default:
                return (.object([:]), nil, nil, false, nil, nil)
            }
        }
        if method == "config.set" {
            if let gate = behavior.2 { await gate.wait() }
            if behavior.3 { throw DirectSessionError.invalidResponse }
            updateReasoningReadbackIfNeeded(params)
            if let response = behavior.1 { return response }
            let value: String
            if case .object(let paramsFields) = params,
               let parameterValue = paramsFields["value"]?.gatewayString {
                value = parameterValue
            } else {
                value = "medium"
            }
            return .object([
                "key": .string("reasoning"), "value": .string(value),
                "scope": .string("session"), "deferred": .bool(false),
                "persisted": .bool(true)
            ])
        }
        if method == "clarify.respond", let gate = behavior.2 {
            await gate.wait()
        }
        if method == "image.attach_bytes" || method == "file.attach" || method == "pdf.attach",
           let gate = behavior.2 {
            await gate.wait()
        }
        if method == "prompt.submit", let gate = behavior.2 {
            await gate.wait()
            if withLock({ promptSubmitShouldCancel }) { throw CancellationError() }
        }
        if method == "prompt.btw", let gate = behavior.2 {
            await gate.wait()
        }
        if method == "prompt.background", let gate = behavior.2 {
            await gate.wait()
        }
        if method == "session.usage", let gate = behavior.2 {
            await gate.wait()
        }
        if let requestError { throw requestError }
        return behavior.0
    }

    private static func defaultAttachmentResponse(for method: String) -> JSONValue {
        switch method {
        case "image.attach_bytes":
            return .object([
                "attached": .bool(true),
                "path": .string("/profile/images/photo.png"),
                "name": .string("photo.png")
            ])
        case "file.attach":
            return .object([
                "attached": .bool(true),
                "name": .string("notes.txt"),
                "ref_text": .string("@file:attachments/notes.txt")
            ])
        case "pdf.attach":
            return .object([
                "attached": .bool(true),
                "filename": .string("report.pdf"),
                "pages_attached": .number(1),
                "pages": .array([
                    .object(["path": .string("/profile/images/pdf_p1.png"), "page": .number(1)])
                ])
            ])
        default:
            return .object([:])
        }
    }

    private func updateReasoningReadbackIfNeeded(_ params: JSONValue?) {
        let shouldUpdate = withLock { updatesReasoningReadback }
        guard shouldUpdate,
              case .object(let fields) = params,
              let value = fields["value"]?.gatewayString else { return }
        withLock {
            reasoningGetResponse = .object([
                "value": .string(value),
                "display": .string("show")
            ])
        }
    }

    func emitCompletion(sequence: Int = 3) {
        let sink = withLock { self.sink }
        sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.complete", sequence: sequence, payload: ["text": .string("streamed answer")]))
    }

    func emit(_ event: HermesGatewayEvent) {
        let sink = withLock { self.sink }
        sink?(event)
    }

    func emitClosed() {
        emit(HermesGatewayEvent(
            method: "local", type: "transport.closed", sessionID: nil,
            sequence: nil, payload: nil, params: nil, connectionGeneration: 1
        ))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor ChatDirectAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// A bounded, deterministic REST fixture for long-history direct-chat tests.
/// It intentionally serves only 120 rows per request, including the final
/// short page, so the tests exercise the production backwards cursor rather
/// than a large unbounded response.
private final class ChatLongHistoryFixture: @unchecked Sendable {
    struct Request: Equatable {
        let chatID: String
        let profile: String?
        let limit: Int?
        let offset: Int
        let order: String?
        let includeCompacted: String?
    }

    private let lock = NSLock()
    private var rowsByChat: [String: [[String: Any]]]
    private var requestsValue: [Request] = []
    private var failOlderPage = false
    private var overlapOlderPage = false

    func failNextOlderPage() { withLock { failOlderPage = true } }
    func overlapNextOlderPage() { withLock { overlapOlderPage = true } }

    func appendRows(_ count: Int, to chatID: String) {
        withLock {
            let start = rowsByChat[chatID, default: []].count
            for index in start..<(start + count) {
                rowsByChat[chatID, default: []].append([
                    "id": "\(chatID)-row-\(index)", "role": "assistant",
                    "content": "new durable tail \(index)", "timestamp": 1_770_000_000 + index
                ])
            }
        }
    }

    func installHistoricalTool(in chatID: String) {
        withLock {
            rowsByChat[chatID]?[1801]["tool_calls"] = [[
                "id": "historical-tool", "type": "function",
                "function": ["name": "historical_lookup", "arguments": "{}"]
            ]]
            rowsByChat[chatID]?[1802]["role"] = "tool"
            rowsByChat[chatID]?[1802]["tool_call_id"] = "historical-tool"
        }
    }

    init(chatIDs: [String]) {
        rowsByChat = Dictionary(uniqueKeysWithValues: chatIDs.map { chatID in
            let rows = (0..<2_000).map { index -> [String: Any] in
                let content: String
                if index % 5 == 0 {
                    content = "\(chatID) row \(index) **markdown**\n```swift\nlet value = \(index)\n```"
                } else if index % 2 == 0 {
                    content = "\(chatID) row \(index) with `inline code` and **bold** text"
                } else {
                    content = "\(chatID) row \(index) plain chronological content"
                }
                return [
                    "id": "\(chatID)-row-\(index)",
                    "role": index.isMultiple(of: 2) ? "user" : "assistant",
                    "content": content,
                    "timestamp": 1_770_000_000 + index
                ]
            }
            return (chatID, rows)
        })
    }

    func messageIDs(for chatID: String) -> [String] {
        withLock { rowsByChat[chatID, default: []].compactMap { $0["id"] as? String } }
    }

    func removeNewestRows(_ count: Int, from chatID: String) {
        withLock { rowsByChat[chatID]?.removeLast(count) }
    }

    func replaceRowIdentities(in chatID: String) {
        withLock {
            rowsByChat[chatID] = rowsByChat[chatID]?.enumerated().map { index, value in
                var row = value
                row["id"] = "replacement-\(chatID)-\(index)"
                return row
            }
        }
    }

    func appendCompletionTurn(for chatID: String) {
        withLock {
            guard var rows = rowsByChat[chatID], rows.count == 2_000 else { return }
            rows.append([
                "id": "\(chatID)-row-2000",
                "role": "user",
                "content": "new question with **markdown** and `code`",
                "timestamp": 1_770_002_000
            ])
            rows.append([
                "id": "\(chatID)-row-2001",
                "role": "assistant",
                "content": "canonical terminal answer",
                "timestamp": 1_770_002_001
            ])
            rowsByChat[chatID] = rows
        }
    }

    func response(for request: URLRequest, chatID: String) -> (HTTPURLResponse, Data) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        let limit = Int(query["limit"] ?? "0")
        let offset = max(0, Int(query["offset"] ?? "0") ?? 0)
        let rows = withLock { rowsByChat[chatID] ?? [] }
        let boundedLimit = min(max(limit ?? 0, 1), 120)
        let behavior = withLock { () -> (fail: Bool, overlap: Bool) in
            guard offset > 0 else { return (false, false) }
            defer { failOlderPage = false; overlapOlderPage = false }
            return (failOlderPage, overlapOlderPage)
        }
        let end = min(rows.count, max(0, rows.count - offset) + (behavior.overlap ? 1 : 0))
        let start = max(0, end - boundedLimit)
        let page = Array(rows[start..<end])
        let result: [String: Any] = [
            "session_id": chatID,
            "messages": page,
            "pagination": [
                "limit": boundedLimit,
                "offset": offset,
                "order": query["order"] ?? "",
                "returned": page.count
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [])
        let recorded = Request(
            chatID: chatID,
            profile: query["profile"],
            limit: limit,
            offset: offset,
            order: query["order"],
            includeCompacted: query["include_compacted"]
        )
        withLock { requestsValue.append(recorded) }
        return (HTTPURLResponse(
            url: request.url!, statusCode: behavior.fail ? 503 : 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!, data)
    }

    func requests() -> [Request] {
        withLock { requestsValue }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ChatLongFixtureTransport: HermesGatewayTransport, @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let params: JSONValue?
    }

    private let lock = NSLock()
    private let fixture: ChatLongHistoryFixture
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var connected = false
    private var generation = 0
    private var recordedCalls: [Call] = []

    init(fixture: ChatLongHistoryFixture) {
        self.fixture = fixture
    }

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        withLock { self.sink = sink }
    }

    func connect() async throws {
        withLock {
            generation += 1
            connected = true
        }
    }

    func close() async {
        withLock { connected = false }
    }

    func connectionIdentifier() async -> Int? {
        withLock { connected ? generation : nil }
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        withLock { recordedCalls.append(Call(method: method, params: params)) }
        let values = params.flatMap { value -> [String: JSONValue]? in
            guard case .object(let fields) = value else { return nil }
            return fields
        } ?? [:]
        switch method {
        case "session.resume":
            let chatID = values["session_id"]?.gatewayString ?? "unknown"
            return .object([
                "session_id": .string("runtime-" + chatID),
                "session_key": .string(chatID)
            ])
        case "prompt.submit":
            let runtimeID = values["session_id"]?.gatewayString ?? ""
            let chatID = runtimeID.hasPrefix("runtime-") ? String(runtimeID.dropFirst("runtime-".count)) : runtimeID
            fixture.appendCompletionTurn(for: chatID)
            let sink = withLock { self.sink }
            Task {
                sink?(ChatDirectEventFactory.event(sessionID: runtimeID, type: "message.start", sequence: 1))
                sink?(ChatDirectEventFactory.event(sessionID: runtimeID, type: "message.delta", sequence: 2,
                    payload: ["text": .string("streamed answer")]))
            }
            return .object(["status": .string("streaming")])
        default:
            return .object([:])
        }
    }

    func calls() -> [Call] {
        withLock { recordedCalls }
    }

    func connectionCount() -> Int {
        withLock { generation }
    }

    func emitCompletion(for chatID: String) {
        let sink = withLock { self.sink }
        sink?(ChatDirectEventFactory.event(
            sessionID: "runtime-" + chatID, type: "message.complete", sequence: 3,
            payload: ["text": .string("streamed answer")]
        ))
    }

    func emit(for chatID: String, type: String, sequence: Int, payload: [String: JSONValue] = [:]) {
        let sink = withLock { self.sink }
        sink?(ChatDirectEventFactory.event(sessionID: "runtime-" + chatID, type: type, sequence: sequence, payload: payload))
    }

    func restRequests() -> [ChatLongHistoryFixture.Request] {
        fixture.requests()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
