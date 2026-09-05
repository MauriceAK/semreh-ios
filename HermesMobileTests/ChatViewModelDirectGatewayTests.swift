import XCTest
@testable import HermesMobile

@MainActor
final class ChatViewModelDirectGatewayTests: APIClientTestCase {
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
        let oldRuntime = try makeRuntime(oldFake)
        let oldRequests = ChatDirectRequestRecorder()
        let oldClient = makeExistingComposerClient(requests: oldRequests)
        let oldVM = makeViewModel(client: oldClient, runtime: oldRuntime, sessionID: "durable-1")
        await oldVM.loadComposerConfiguration()
        XCTAssertFalse(oldVM.showsReasoningEffortControl, "A valid old payload is read-only, not a write-capable contract")
        XCTAssertFalse(oldVM.allowsReasoningChangesWhileStreaming)
        let oldSelection = await oldVM.selectReasoningEffort("high")
        XCTAssertFalse(oldSelection)
        XCTAssertFalse(oldFake.calls().contains { $0.method == "config.set" })
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

        fake.emitCompletion()
        await waitUntil { viewModel.messages.contains { $0.content == "canonical answer" } }

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["hello", "canonical answer"])
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

    private let testServer = URL(string: "https://fixture.example")!

    private func makeViewModel(
        client: APIClient,
        runtime: HermesServerRuntime,
        sessionID: String?,
        defaults: UserDefaults = .standard
    ) -> ChatViewModel {
        ChatViewModel(
            session: SessionSummary(sessionId: sessionID, title: "New Chat", profile: "work"),
            server: testServer,
            client: client,
            liveActivityManager: ChatDirectNoopLiveActivityManager(),
            userDefaults: defaults,
            gatewayRuntimeProvider: { _ in runtime }
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
        payload: [String: JSONValue]? = nil
    ) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: "event",
            type: type,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload.map(JSONValue.object),
            params: nil,
            connectionGeneration: 1
        )
    }
}

private final class ChatDirectRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

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
    private var reasoningGetResponse: JSONValue = .object([
        "value": .string("medium"),
        "display": .string("show"),
        "session_reasoning_contract": .number(1),
        "deferred": .bool(false)
    ])
    private var reasoningSetResponse: JSONValue?
    private var reasoningSetGate: ChatDirectAsyncGate?
    private var reasoningSetShouldFail = false

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        withLock { self.sink = sink }
    }

    func setSteerResponse(_ response: JSONValue) {
        withLock { steerResponse = response }
    }

    func setResumeResponse(_ response: JSONValue) {
        withLock { resumeResponse = response }
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
            case "config.get":
                return (reasoningGetResponse, nil, nil, false, nil, nil)
            case "config.set":
                return (reasoningSetResponse, reasoningSetResponse, reasoningSetGate,
                        reasoningSetShouldFail, nil, params)
            case "prompt.submit":
                let sink = self.sink
                Task {
                    sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.start", sequence: 1))
                    sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.delta", sequence: 2, payload: ["text": .string("streamed answer")]))
                }
                return (.object(["status": .string("streaming")]), nil, nil, false, nil, nil)
            case "session.steer":
                return (steerResponse, nil, nil, false, nil, nil)
            case "session.interrupt":
                return (.object(["status": .string("interrupted")]), nil, nil, false, nil, nil)
            case "session.status":
                return (.object(["output": .string("Agent Running: No")]), nil, nil, false, nil, nil)
            default:
                return (.object([:]), nil, nil, false, nil, nil)
            }
        }
        if method == "config.set" {
            if let gate = behavior.2 { await gate.wait() }
            if behavior.3 { throw DirectSessionError.invalidResponse }
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
        return behavior.0
    }

    func emitCompletion() {
        let sink = withLock { self.sink }
        sink?(ChatDirectEventFactory.event(sessionID: "runtime-1", type: "message.complete", sequence: 3, payload: ["text": .string("streamed answer")]))
    }

    func emit(_ event: HermesGatewayEvent) {
        let sink = withLock { self.sink }
        sink?(event)
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
        let end = max(0, rows.count - offset)
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
            url: request.url!, statusCode: 200, httpVersion: nil,
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
    private let lock = NSLock()
    private let fixture: ChatLongHistoryFixture
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var connected = false
    private var generation = 0

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

    func emitCompletion(for chatID: String) {
        let sink = withLock { self.sink }
        sink?(ChatDirectEventFactory.event(
            sessionID: "runtime-" + chatID, type: "message.complete", sequence: 3,
            payload: ["text": .string("streamed answer")]
        ))
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
