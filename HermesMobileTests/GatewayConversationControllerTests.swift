import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationControllerTests: XCTestCase {
    func testFirstSubmitCreatesOnceAndUsesRuntimeIDAndProfile() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil, profile: "work")

        try await controller.submit("hello")

        let calls = fake.calls()
        XCTAssertEqual(calls.map(\.method), ["session.create", "prompt.submit"])
        XCTAssertEqual(objectFields(calls[0].params)?["profile"], .string("work"))
        XCTAssertEqual(objectFields(calls[1].params)?["session_id"], .string("runtime-1"))
        XCTAssertEqual(objectFields(calls[1].params)?["profile"], .string("work"))
        XCTAssertEqual(controller.binding?.runtimeID, "runtime-1")
        XCTAssertEqual(controller.storedID, "durable-1")

        await runtime.stop()
    }

    func testDefinitiveSubmitAckRemovesCrashQuarantineMarker() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        try await controller.submit("healthy")

        XCTAssertNil(promptStore.markers.first)
        XCTAssertFalse(controller.hasAmbiguousPromptDelivery)
        await runtime.stop()
    }

    func testDelayedSubmitAckRemovesMarkerMigratedToCanonicalTip() async throws {
        let fake = ControllerFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-ancestor"),
            "session_key": .string("ancestor")
        ]))
        let promptGate = AsyncGate()
        fake.setPromptResponseGate(promptGate)
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        var canonicalID = "ancestor"
        let controller = makeController(
            runtime: runtime,
            storedID: "ancestor",
            promptUncertaintyStore: promptStore
        ) { _, _, _, _ in
            self.page(canonicalID)
        }
        try await controller.open()

        let submit = Task { try await controller.submit("healthy after compression") }
        await yieldUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        let ancestorMarker = try XCTUnwrap(promptStore.markers.first)
        XCTAssertEqual(ancestorMarker.identity.storedID, "ancestor")

        canonicalID = "tip"
        try await controller.refresh()
        XCTAssertEqual(controller.storedID, "tip")
        XCTAssertEqual(promptStore.markers.count, 1)
        XCTAssertEqual(promptStore.markers.first?.identity.storedID, "tip")
        XCTAssertEqual(promptStore.markers.first?.token, ancestorMarker.token)

        await promptGate.release()
        try await submit.value

        XCTAssertTrue(promptStore.markers.isEmpty)
        XCTAssertFalse(controller.hasAmbiguousPromptDelivery)
        XCTAssertNil(controller.promptDeliveryUncertaintyToken)
        await runtime.stop()
    }

    func testMarkerWriteFailureIsProvenNondispatchAndDoesNotQuarantineSend() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        promptStore.failWrite = true
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        do {
            try await controller.submit("preserve draft")
            XCTFail("A failed safety-marker write must prevent dispatch")
        } catch DirectPromptDeliveryUncertaintyError.persistenceUnavailable { }

        XCTAssertEqual(controller.runState, .idle)
        XCTAssertFalse(controller.hasAmbiguousPromptDelivery)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await runtime.stop()
    }

    func testAcceptedPromptWithMarkerCleanupFailureKeepsKnownAcceptanceSeparate() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        promptStore.failRemove = true
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        try await controller.submit("accepted")

        XCTAssertTrue(controller.hasAmbiguousPromptDelivery)
        XCTAssertTrue(controller.promptDeliveryUncertaintyHasConfirmedAcceptance)
        XCTAssertEqual(promptStore.markers.count, 1)
        await runtime.stop()
    }

    func testAcceptedPromptDoesNotRemoveReplacementPersistedToken() async throws {
        let fake = ControllerFakeTransport()
        let promptGate = AsyncGate()
        fake.setPromptResponseGate(promptGate)
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        let submit = Task { try await controller.submit("accepted") }
        await yieldUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        let original = try XCTUnwrap(promptStore.markers.first)
        let replacement = DirectPromptDeliveryUncertaintyMarker(identity: original.identity)
        try promptStore.write(replacement)

        await promptGate.release()
        try await submit.value

        XCTAssertEqual(promptStore.markers.first?.token, replacement.token)
        XCTAssertTrue(controller.hasAmbiguousPromptDelivery)
        XCTAssertFalse(controller.promptDeliveryUncertaintyHasConfirmedAcceptance)
        await runtime.stop()
    }

    func testDefiniteRejectionWithMarkerCleanupFailureRestoresSafeBarrier() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptServerError(.server(
            code: 4001,
            message: "session not found",
            data: nil,
            method: "prompt.submit",
            requestID: "cleanup-failure",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        promptStore.failRemove = true
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore) { id, _, _, _ in
            throw APIError.http(statusCode: 404, body: #"{"detail":"Session not found"}"#)
        }

        do {
            try await controller.submit("rejected")
            XCTFail("Expected local cleanup failure after definite rejection")
        } catch DirectPromptDeliveryUncertaintyError.persistenceUnavailable { }
        XCTAssertTrue(controller.hasAmbiguousPromptDelivery)
        XCTAssertFalse(controller.promptDeliveryUncertaintyHasConfirmedAcceptance)
        XCTAssertEqual(promptStore.markers.count, 1)
        await runtime.stop()
    }

    func testDispatchedTimeoutPersistsAcrossControllerRecreationAndNewRuntime() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptTimeout(true)
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        do {
            try await controller.submit("uncertain")
            XCTFail("Expected an ambiguous prompt outcome")
        } catch HermesGatewayError.timeout { }
        let marker = try XCTUnwrap(promptStore.markers.first)
        XCTAssertTrue(controller.hasAmbiguousPromptDelivery)
        await runtime.stop()

        let replacementFake = ControllerFakeTransport()
        replacementFake.setResumeResponse(.object([
            "session_id": .string("runtime-replacement"),
            "session_key": .string("durable-1")
        ]))
        let replacementRuntime = try makeRuntime(replacementFake)
        let replacement = makeController(
            runtime: replacementRuntime,
            storedID: "durable-1",
            promptUncertaintyStore: promptStore
        )
        XCTAssertEqual(replacement.promptDeliveryUncertaintyToken, marker.token)
        XCTAssertTrue(replacement.hasAmbiguousPromptDelivery)
        try await replacement.open()
        do {
            try await replacement.submit("duplicate")
            XCTFail("A recreated controller must retain the no-resend barrier")
        } catch DirectSessionError.ambiguousPrompt { }
        XCTAssertFalse(replacementFake.calls().contains { $0.method == "prompt.submit" })
        await replacementRuntime.stop()
    }

    func testManualUncertaintyAbandonRequiresFreshIdleProofAndOnlyClearsMarker() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptTimeout(true)
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        do { try await controller.submit("uncertain") } catch HermesGatewayError.timeout { }
        let token = try XCTUnwrap(controller.promptDeliveryUncertaintyToken)
        try await controller.abandonPromptDeliveryUncertainty(expectedToken: token)

        XCTAssertNil(promptStore.markers.first)
        XCTAssertFalse(controller.hasAmbiguousPromptDelivery)
        XCTAssertEqual(controller.runState, .idle)
        XCTAssertFalse(fake.calls().contains { $0.method == "session.close" })
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await runtime.stop()
    }

    func testManualUncertaintyAbandonRejectsWrongTokenAndConcurrentAction() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptTimeout(true)
        let statusGate = AsyncGate()
        fake.setSessionStatusGate(statusGate)
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        do { try await controller.submit("uncertain") } catch HermesGatewayError.timeout { }
        let token = try XCTUnwrap(controller.promptDeliveryUncertaintyToken)
        do {
            try await controller.abandonPromptDeliveryUncertainty(expectedToken: UUID())
            XCTFail("A replaced token must not clear the marker")
        } catch DirectSessionError.staleOperation { }

        let abandon = Task { try await controller.abandonPromptDeliveryUncertainty(expectedToken: token) }
        await yieldUntil { fake.calls().contains { $0.method == "session.status" } }
        do {
            try await controller.abandonPromptDeliveryUncertainty(expectedToken: token)
            XCTFail("Only one abandon operation may own the marker at a time")
        } catch DirectSessionError.staleOperation { }
        await statusGate.release()
        try await abandon.value
        XCTAssertTrue(promptStore.markers.isEmpty)
        await runtime.stop()
    }

    func testManualUncertaintyAbandonRejectsReplacementTokenAfterDelayedStatus() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptTimeout(true)
        let statusGate = AsyncGate()
        fake.setSessionStatusGate(statusGate)
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        do { try await controller.submit("uncertain") } catch HermesGatewayError.timeout { }
        let token = try XCTUnwrap(controller.promptDeliveryUncertaintyToken)
        let abandon = Task { try await controller.abandonPromptDeliveryUncertainty(expectedToken: token) }
        await yieldUntil { fake.calls().contains { $0.method == "session.status" } }
        let identity = try DirectPromptDeliveryUncertaintyIdentity(
            origin: URL(string: "https://fixture.example")!,
            profile: "default",
            storedID: "durable-1"
        )
        let replacement = DirectPromptDeliveryUncertaintyMarker(identity: identity)
        try promptStore.write(replacement)
        await statusGate.release()
        do {
            try await abandon.value
            XCTFail("A replaced persisted token must not be cleared by an old operation")
        } catch DirectSessionError.staleOperation { }
        XCTAssertEqual(promptStore.markers.first?.token, replacement.token)
        await runtime.stop()
    }

    func testManualUncertaintyAbandonRejectsReboundGenerationAfterDelayedStatus() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptTimeout(true)
        let statusGate = AsyncGate()
        fake.setSessionStatusGate(statusGate)
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        do { try await controller.submit("uncertain") } catch HermesGatewayError.timeout { }
        let token = try XCTUnwrap(controller.promptDeliveryUncertaintyToken)
        let abandon = Task { try await controller.abandonPromptDeliveryUncertainty(expectedToken: token) }
        await yieldUntil { fake.calls().contains { $0.method == "session.status" } }
        try await runtime.reconnect()
        await statusGate.release()
        do {
            try await abandon.value
            XCTFail("A rebound runtime must invalidate the old abandon operation")
        } catch DirectSessionError.staleOperation { }
        XCTAssertEqual(promptStore.markers.first?.token, token)
        await runtime.stop()
    }

    func testExistingResumeUsesCanonicalTipForBindingAndTranscript() async throws {
        let fake = ControllerFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-tip"),
            "session_key": .string("tip")
        ]))
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let ancestorIdentity = try DirectPromptDeliveryUncertaintyIdentity(
            origin: URL(string: "https://fixture.example")!,
            profile: "work",
            storedID: "ancestor"
        )
        let ancestorMarker = DirectPromptDeliveryUncertaintyMarker(identity: ancestorIdentity)
        try promptStore.write(ancestorMarker)
        var loadedIDs: [String] = []
        let controller = makeController(runtime: runtime, storedID: "ancestor", profile: "work", promptUncertaintyStore: promptStore) { id, _, _, _ in
            loadedIDs.append(id)
            return self.page(id)
        }

        try await controller.open()

        XCTAssertEqual(loadedIDs, ["tip"])
        XCTAssertEqual(controller.storedID, "tip")
        XCTAssertEqual(controller.binding, GatewaySessionBinding(storedID: "tip", runtimeID: "runtime-tip", profile: "work"))
        let tipIdentity = try DirectPromptDeliveryUncertaintyIdentity(
            origin: URL(string: "https://fixture.example")!,
            profile: "work",
            storedID: "tip"
        )
        XCTAssertEqual(try promptStore.load(for: tipIdentity)?.token, ancestorMarker.token)
        XCTAssertNil(try promptStore.load(for: ancestorIdentity))
        let resume = try XCTUnwrap(fake.calls().first(where: { $0.method == "session.resume" }))
        XCTAssertEqual(objectFields(resume.params)?["session_id"], .string("ancestor"))
        XCTAssertEqual(objectFields(resume.params)?["profile"], .string("work"))

        await runtime.stop()
    }

    func testAlreadyReadyResumeBuffersEarlyEventsUntilBindingAndCanonicalReadFinish() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        try await runtime.connect()
        let sinkConsumed = AsyncGate()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-event"),
            "session_key": .string("tip")
        ]))
        fake.setResumeEventsBeforeResponse(
            [
                event(sessionID: "runtime-event", type: "message.start", sequence: 1),
                event(sessionID: "runtime-event", type: "message.delta", sequence: 2)
            ],
            sinkConsumedGate: sinkConsumed
        )
        var observations: [(String, String?, String?)] = []
        var canonicalIDs: [String] = []
        let eventDelivery = expectation(description: "recovered events are delivered")
        eventDelivery.expectedFulfillmentCount = 2
        let controller = makeController(runtime: runtime, storedID: "ancestor") { _, _, _, _ in
            self.page("tip")
        }
        controller.onCanonicalID = { canonicalIDs.append($0) }
        controller.onEvent = { event in
            observations.append((event.type, controller.storedID, controller.binding?.runtimeID))
            eventDelivery.fulfill()
        }

        try await controller.open()
        await fulfillment(of: [eventDelivery], timeout: 2)

        XCTAssertEqual(observations.map(\.0), ["message.start", "message.delta"])
        XCTAssertTrue(observations.allSatisfy { $0.1 == "tip" && $0.2 == "runtime-event" })
        XCTAssertEqual(canonicalIDs, ["tip"])
        XCTAssertEqual(controller.storedID, "tip")
        XCTAssertEqual(controller.binding?.runtimeID, "runtime-event")
        await runtime.stop()
    }

    func testLocalDraftOpenDoesNotCreateOrAttach() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)

        try await controller.open()

        XCTAssertTrue(fake.calls().isEmpty)
        XCTAssertNil(controller.binding)
        XCTAssertNil(controller.storedID)
        await runtime.stop()
    }

    func testStoredChatReasoningGetterUsesExactSessionAndProfileScope() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("high"),
            "display": .string("show"),
            "session_reasoning_contract": .number(1),
            "deferred": .bool(false)
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat", profile: "work")

        let configuration = try await controller.reasoningConfiguration()

        XCTAssertEqual(configuration, .init(effort: "high", deferred: false, supportsSessionChanges: true))
        let call = try XCTUnwrap(fake.calls().first(where: { $0.method == "config.get" }))
        XCTAssertEqual(objectFields(call.params), [
            "key": .string("reasoning"),
            "scope": .string("session"),
            "session_id": .string("runtime-resumed"),
            "profile": .string("work")
        ])
        await runtime.stop()
    }

    func testDelayedReasoningReadIsInvalidatedByAQueuedWrite() async throws {
        let fake = ControllerFakeTransport()
        let readGate = AsyncGate()
        fake.setReasoningGetGate(readGate)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        let read = Task { try await controller.reasoningConfiguration() }
        await yieldUntil { fake.calls().contains { $0.method == "config.get" } }
        let write = Task { try await controller.setReasoningEffort("high") }
        _ = try await write.value
        await readGate.release()
        do {
            _ = try await read.value
            XCTFail("A read started before a setting write must not return stale state")
        } catch DirectSessionError.staleOperation { }
        await runtime.stop()
    }

    func testReasoningReadStartedDuringQueuedWritesWaitsForTheLatestWrite() async throws {
        let fake = ControllerFakeTransport()
        let firstWrite = AsyncGate()
        fake.setReasoningSetGate(firstWrite)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        let first = Task { try await controller.setReasoningEffort("high") }
        await yieldUntil { fake.calls().filter { $0.method == "config.set" }.count == 1 }
        let second = Task { try await controller.setReasoningEffort("max") }
        await Task.yield()
        let read = Task { try await controller.reasoningConfiguration() }
        await firstWrite.release()

        _ = try await first.value
        _ = try await second.value
        let configuration = try await read.value
        XCTAssertEqual(configuration.effort, "max")
        await runtime.stop()
    }

    func testStoredChatReasoningSetterPreservesRunningStateAndAcceptsDeferredAck() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"),
            "display": .string("show"),
            "session_reasoning_contract": .number(1),
            "deferred": .bool(false)
        ]))
        fake.setReasoningSetResponse(.object([
            "key": .string("reasoning"),
            "value": .string("high"),
            "scope": .string("session"),
            "deferred": .bool(true),
            "persisted": .bool(true)
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")
        try await controller.open()
        fake.emit(event(sessionID: "runtime-resumed", type: "message.start", sequence: 1))
        await Task.yield()

        let configuration = try await controller.setReasoningEffort("high")

        XCTAssertEqual(configuration, .init(effort: "high", deferred: true, supportsSessionChanges: true))
        XCTAssertEqual(controller.runState, .running)
        let call = try XCTUnwrap(fake.calls().first(where: { $0.method == "config.set" }))
        XCTAssertEqual(objectFields(call.params)?["scope"], .string("session"))
        XCTAssertEqual(objectFields(call.params)?["session_id"], .string("runtime-resumed"))
        XCTAssertEqual(objectFields(call.params)?["profile"], .string("default"))
        await runtime.stop()
    }

    func testReasoningDoesNotCreateAnUnsentDraftAndRejectsDisposedController() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let draft = makeController(runtime: runtime, storedID: nil)

        do {
            _ = try await draft.reasoningConfiguration()
            XCTFail("A draft must not attach just to read reasoning")
        } catch DirectSessionError.invalidBinding { }
        do {
            _ = try await draft.setReasoningEffort("high")
            XCTFail("A draft must not write reasoning")
        } catch DirectSessionError.invalidResponse { }
        XCTAssertTrue(fake.calls().isEmpty)

        let stored = makeController(runtime: runtime, storedID: "stored-chat")
        stored.invalidate()
        do {
            _ = try await stored.reasoningConfiguration()
            XCTFail("A disposed controller must not read reasoning")
        } catch DirectSessionError.invalidBinding { }
        XCTAssertTrue(fake.calls().isEmpty)
        await runtime.stop()
    }

    func testStockBackendUsesIdleStatusExactAckAndReadback() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"),
            "display": .string("show")
        ]))
        fake.setReasoningSetResponse(.object([
            "key": .string("reasoning"), "value": .string("high")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        let configuration = try await controller.reasoningConfiguration()
        XCTAssertEqual(configuration, .init(effort: "medium", deferred: false, supportsSessionChanges: true))
        let applied = try await controller.setReasoningEffort("high")
        XCTAssertEqual(applied, .init(effort: "high", deferred: false, supportsSessionChanges: true))
        XCTAssertEqual(fake.calls().map(\.method), [
            "session.resume", "config.get", "config.get", "session.status", "config.set", "config.get"
        ])
        await runtime.stop()
    }

    func testUnknownOrMalformedReasoningExtensionDoesNotFallBackToStock() async throws {
        for response in [
            JSONValue.object([
                "value": .string("medium"), "display": .string("show"),
                "session_reasoning_contract": .number(2), "deferred": .bool(false)
            ]),
            JSONValue.object([
                "value": .string("medium"), "display": .string("show"),
                "deferred": .bool(false)
            ]),
            JSONValue.object([
                "value": .string("medium"), "display": .string("show"),
                "session_reasoning_contract": .number(1)
            ])
        ] {
            let fake = ControllerFakeTransport()
            fake.setReasoningGetResponse(response)
            let runtime = try makeRuntime(fake)
            let controller = makeController(runtime: runtime, storedID: "stored-chat")
            do { _ = try await controller.reasoningConfiguration(); XCTFail("Malformed extension accepted") }
            catch DirectSessionError.invalidResponse { }
            XCTAssertFalse(fake.calls().contains { $0.method == "config.set" })
            await runtime.stop()
        }
    }

    func testStockAckToleratesUnknownFieldsButRejectsContradictoryKnownFields() async throws {
        let accepted = ControllerFakeTransport()
        accepted.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        accepted.setReasoningSetResponse(.object([
            "key": .string("reasoning"), "value": .string("high"),
            "scope": .string("session"), "persisted": .bool(true),
            "deferred": .bool(false), "future": .string("ignored")
        ]))
        let acceptedRuntime = try makeRuntime(accepted)
        _ = try await makeController(runtime: acceptedRuntime, storedID: "stored-chat")
            .setReasoningEffort("high")
        await acceptedRuntime.stop()

        let rejected = ControllerFakeTransport()
        rejected.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        rejected.setReasoningSetResponse(.object([
            "key": .string("reasoning"), "value": .string("high"),
            "scope": .string("global")
        ]))
        let rejectedRuntime = try makeRuntime(rejected)
        let controller = makeController(runtime: rejectedRuntime, storedID: "stored-chat")
        do { _ = try await controller.setReasoningEffort("high"); XCTFail("Contradictory ACK accepted") }
        catch DirectSessionError.invalidResponse { }
        XCTAssertEqual(rejected.calls().filter { $0.method == "config.set" }.count, 1)
        await rejectedRuntime.stop()
    }

    func testStockRunningChoiceQueuesWithoutWriteAndAppliesBeforeNextSubmit() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        fake.setReasoningSetResponse(.object([
            "key": .string("reasoning"), "value": .string("max")
        ]))
        let setGate = AsyncGate()
        fake.setReasoningSetGate(setGate)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")
        try await controller.open()
        fake.emit(event(sessionID: "runtime-resumed", type: "message.start", sequence: 1))
        await Task.yield()

        let queued = try await controller.setReasoningEffort("high")
        XCTAssertTrue(queued.deferred)
        XCTAssertEqual(controller.pendingReasoningEffort, "high")
        XCTAssertFalse(fake.calls().contains { $0.method == "config.set" })
        let latest = try await controller.setReasoningEffort("max")
        XCTAssertEqual(latest.effort, "max")
        XCTAssertEqual(controller.pendingReasoningEffort, "max")
        XCTAssertFalse(fake.calls().contains { $0.method == "config.set" })

        fake.emit(event(sessionID: "runtime-resumed", type: "message.complete", sequence: 2))
        await yieldUntil { fake.calls().contains { $0.method == "config.set" } }
        let submit = Task { try await controller.submit("next") }
        await Task.yield()
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await setGate.release()
        try await submit.value
        let methods = fake.calls().map(\.method)
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "config.set")),
                          try XCTUnwrap(methods.firstIndex(of: "prompt.submit")))
        XCTAssertNil(controller.pendingReasoningEffort)
        await runtime.stop()
    }

    func testStockBusyPreflightRetainsPendingAndNeverWrites() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        fake.setSessionStatusResponse(.object(["output": .string("Agent Running: Yes")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        let result = try await controller.setReasoningEffort("high")
        XCTAssertTrue(result.deferred)
        XCTAssertEqual(controller.pendingReasoningEffort, "high")
        XCTAssertFalse(fake.calls().contains { $0.method == "config.set" })
        await runtime.stop()
    }

    func testInvalidationClearsStockPendingChoiceWithoutApplyingIt() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")
        try await controller.open()
        fake.emit(event(sessionID: "runtime-resumed", type: "message.start", sequence: 1))
        await Task.yield()

        _ = try await controller.setReasoningEffort("high")
        XCTAssertEqual(controller.pendingReasoningEffort, "high")
        controller.invalidate()
        XCTAssertNil(controller.pendingReasoningEffort)
        fake.emit(event(sessionID: "runtime-resumed", type: "message.complete", sequence: 2))
        await Task.yield()
        XCTAssertFalse(fake.calls().contains { $0.method == "config.set" })
        await runtime.stop()
    }

    func testStockBadAckIsNotRetriedByNextSubmit() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        fake.setReasoningSetResponse(.object(["key": .string("reasoning")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        do { _ = try await controller.setReasoningEffort("high"); XCTFail("Bad ACK accepted") }
        catch DirectSessionError.invalidResponse { }
        do { try await controller.submit("must not send"); XCTFail("Ambiguous write was hidden") }
        catch DirectSessionError.invalidResponse { }
        XCTAssertEqual(fake.calls().filter { $0.method == "config.set" }.count, 1)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await runtime.stop()
    }

    func testStockBadReadbackFailsAfterOneWrite() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        fake.setReasoningSetResponse(.object([
            "key": .string("reasoning"), "value": .string("high")
        ]))
        fake.setUpdatesReasoningReadback(false)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        do { _ = try await controller.setReasoningEffort("high"); XCTFail("Bad readback accepted") }
        catch DirectSessionError.invalidResponse { }
        XCTAssertEqual(fake.calls().filter { $0.method == "config.set" }.count, 1)
        await runtime.stop()
    }

    func testStockRebindDuringWriteRejectsStaleAckWithoutRetry() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningGetResponse(.object([
            "value": .string("medium"), "display": .string("show")
        ]))
        fake.setReasoningSetResponse(.object([
            "key": .string("reasoning"), "value": .string("high")
        ]))
        let gate = AsyncGate()
        fake.setReasoningSetGate(gate)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        let write = Task { try await controller.setReasoningEffort("high") }
        await yieldUntil { fake.calls().contains { $0.method == "config.set" } }
        try await runtime.reconnect()
        await gate.release()
        do { _ = try await write.value; XCTFail("Stale stock ACK accepted") }
        catch DirectSessionError.staleOperation { }
        XCTAssertEqual(fake.calls().filter { $0.method == "config.set" }.count, 1)
        await runtime.stop()
    }

    func testMalformedReasoningAckFailsClosed() async throws {
        let fake = ControllerFakeTransport()
        fake.setReasoningSetResponse(.object([
            "key": .string("reasoning"),
            "value": .string("high"),
            "scope": .string("session"),
            "deferred": .bool(false)
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        do {
            _ = try await controller.setReasoningEffort("high")
            XCTFail("A missing persisted acknowledgement must fail closed")
        } catch DirectSessionError.invalidResponse { }
        await runtime.stop()
    }

    func testInvalidReasoningValuesAndRunStatesAreRejected() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        for effort in ["show", "inherit", "default", "unknown"] {
            do {
                _ = try await controller.setReasoningEffort(effort)
                XCTFail("Unexpectedly accepted reasoning effort")
            } catch DirectSessionError.invalidResponse { }
        }
        let promptGate = AsyncGate()
        fake.setPromptResponseGate(promptGate)
        let submitting = Task { try? await controller.submit("busy") }
        await yieldUntil { controller.runState == .submitting }
        do {
            _ = try await controller.setReasoningEffort("high")
            XCTFail("Submitting state must reject a setting mutation")
        } catch DirectSessionError.invalidResponse { }
        await promptGate.release()
        _ = await submitting.value
        XCTAssertEqual(controller.runState, .running)
        fake.setInterruptResponse(.object(["status": .string("interrupted")]))
        let stopping = Task { try? await controller.interrupt() }
        await yieldUntil { controller.runState == .stopping }
        do {
            _ = try await controller.setReasoningEffort("high")
            XCTFail("Stopping state must reject a setting mutation")
        } catch DirectSessionError.invalidResponse { }
        stopping.cancel()
        _ = await stopping.value
        let unknownFake = ControllerFakeTransport()
        let unknownRuntime = try makeRuntime(unknownFake)
        let unknown = makeController(runtime: unknownRuntime, storedID: "unknown-chat")
        try await unknown.submit("unknown delivery")
        unknownFake.emit(event(sessionID: "runtime-resumed", type: "transport.closed", sequence: 2, method: "local"))
        await Task.yield()
        do {
            XCTAssertEqual(unknown.runState, .deliveryUnknown)
            _ = try await unknown.setReasoningEffort("high")
            XCTFail("Unknown delivery state must reject a setting mutation")
        } catch DirectSessionError.invalidResponse { }
        await runtime.stop()
        await unknownRuntime.stop()
    }

    func testCompetingReasoningWritesRemainOrderedAndBlockSubmit() async throws {
        let fake = ControllerFakeTransport()
        let firstWrite = AsyncGate()
        fake.setReasoningSetGate(firstWrite)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        let first = Task { try await controller.setReasoningEffort("high") }
        await yieldUntil { fake.calls().filter { $0.method == "config.set" }.count == 1 }
        let second = Task { try await controller.setReasoningEffort("max") }
        do {
            try await controller.submit("racing send")
            XCTFail("Submit must wait for queued reasoning writes")
        } catch DirectSessionError.ambiguousPrompt { }
        await firstWrite.release()
        _ = try await first.value
        _ = try await second.value

        let values = fake.calls().filter { $0.method == "config.set" }.compactMap {
            objectFields($0.params)?["value"]?.gatewayString
        }
        XCTAssertEqual(values, ["high", "max"])
        await runtime.stop()
    }

    func testRebindDuringReasoningWriteRejectsStaleCapability() async throws {
        let fake = ControllerFakeTransport()
        let setGate = AsyncGate()
        fake.setReasoningSetGate(setGate)
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: "stored-chat")

        let write = Task { try await controller.setReasoningEffort("high") }
        await yieldUntil { fake.calls().contains { $0.method == "config.set" } }
        try await runtime.reconnect()
        await setGate.release()
        do {
            _ = try await write.value
            XCTFail("A capability from the old socket must not be accepted")
        } catch DirectSessionError.staleOperation { }
        await runtime.stop()
    }

    func testInterleavedConversationEventsAreFilteredByRuntimeSessionID() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let first = makeController(runtime: runtime, storedID: nil, profile: "default")
        let second = makeController(runtime: runtime, storedID: nil, profile: "default")
        var firstEvents: [String] = []
        var secondEvents: [String] = []
        first.onEvent = { firstEvents.append($0.type) }
        second.onEvent = { secondEvents.append($0.type) }

        try await first.submit("one")
        try await second.submit("two")
        fake.emit(event(sessionID: "runtime-1", type: "message.delta", sequence: 1))
        fake.emit(event(sessionID: "runtime-2", type: "message.delta", sequence: 2))
        await yieldUntil { firstEvents.count == 1 && secondEvents.count == 1 }

        XCTAssertEqual(firstEvents, ["message.delta"])
        XCTAssertEqual(secondEvents, ["message.delta"])
        await runtime.stop()
    }

    func testPromptTimeoutBlocksRetryWithoutDuplicateSubmission() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptTimeout(true)
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore)

        do {
            try await controller.submit("ambiguous")
            XCTFail("Expected prompt timeout")
        } catch HermesGatewayError.timeout {
            // The server may have accepted the prompt; it must not be replayed.
        }
        XCTAssertEqual(controller.runState, .deliveryUnknown)
        XCTAssertEqual(promptStore.markers.count, 1)

        do {
            try await controller.submit("retry")
            XCTFail("Expected retry to remain blocked")
        } catch DirectSessionError.ambiguousPrompt {
            // Expected path.
        }

        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await runtime.stop()
    }

    func testDefiniteStaleRuntimeRejectionAndREST404MakeDraftCloseable() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptServerError(.server(
            code: 4001, // Pinned _sess_nowait; REST 404 below is a separate contract.
            message: "session not found",
            data: nil,
            method: "prompt.submit",
            requestID: "2",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        let promptStore = InMemoryDirectPromptDeliveryUncertaintyStore()
        var loadedIDs: [String] = []
        let controller = makeController(runtime: runtime, storedID: nil, promptUncertaintyStore: promptStore) { id, _, _, _ in
            loadedIDs.append(id)
            throw APIError.http(statusCode: 404, body: #"{"detail":"Session not found"}"#)
        }

        do {
            try await controller.submit("rejected")
            XCTFail("Expected definite prompt rejection")
        } catch HermesGatewayError.server {
            // The structured REST 404 separately proves no durable row exists.
        }
        try await controller.dispose()

        XCTAssertEqual(loadedIDs, ["durable-1"])
        XCTAssertEqual(fake.calls().map(\.method), ["session.create", "prompt.submit", "session.close"])
        XCTAssertEqual(objectFields(fake.calls().last?.params)?["session_id"], .string("runtime-1"))
        XCTAssertTrue(promptStore.markers.isEmpty)
        await runtime.stop()
    }

    func testDisconnectedDraftCleanupFailsClosedWithoutStaleClose() async throws {
        let fake = ControllerFakeTransport()
        fake.setPromptServerError(.server(
            code: 4001, // Pinned _sess_nowait; do not use an HTTP code as an RPC code.
            message: "session not found",
            data: nil,
            method: "prompt.submit",
            requestID: "2",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil) { _, _, _, _ in
            throw APIError.http(statusCode: 404, body: #"{"detail":"Session not found"}"#)
        }
        do { try await controller.submit("rejected") } catch HermesGatewayError.server { }
        await runtime.stop()

        do {
            try await controller.dispose()
            XCTFail("Expected conservative draft cleanup failure")
        } catch DirectSessionError.draftCleanupUnconfirmed {
            // A dead runtime cannot safely close the old runtime ID.
        }
        XCTAssertFalse(fake.calls().contains { $0.method == "session.close" })
    }

    func testRejectedSteerDoesNotFallbackToInterruptOrPrompt() async throws {
        let fake = ControllerFakeTransport()
        fake.setSteerResponse(.object(["status": .string("rejected")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)
        try await controller.submit("running")

        let outcome = try await controller.steer("follow-up")

        XCTAssertEqual(outcome.rawValue, "rejected")
        let methods = fake.calls().map(\.method)
        XCTAssertEqual(methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertFalse(methods.contains("session.interrupt"))
        await runtime.stop()
    }

    func testInterruptWaitsForTerminalEventAndProvesStopped() async throws {
        let fake = ControllerFakeTransport()
        fake.setInterruptResponse(.object(["status": .string("interrupted")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)
        try await controller.submit("running")
        fake.setInterruptEvent(event(
            sessionID: "runtime-1",
            type: "message.complete",
            sequence: 3,
            payload: .object(["status": .string("interrupted")])
        ))

        try await controller.interrupt()

        XCTAssertEqual(controller.runState, .idle)
        XCTAssertTrue(fake.calls().contains { $0.method == "session.interrupt" })
        XCTAssertTrue(fake.calls().contains { $0.method == "session.status" })
        await runtime.stop()
    }

    func testUnconfirmedInterruptCanBeRetriedWithoutResubmittingPrompt() async throws {
        let fake = ControllerFakeTransport()
        fake.setInterruptResponse(.object(["status": .string("unconfirmed")]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime, storedID: nil)
        try await controller.submit("running")
        do {
            try await controller.interrupt()
            XCTFail("An unconfirmed acknowledgement must not report stopped")
        } catch {
            XCTAssertEqual(controller.runState, .stopping)
        }
        fake.setInterruptResponse(.object(["status": .string("interrupted")]))
        fake.setInterruptEvent(event(sessionID: "runtime-1", type: "message.complete", sequence: 3,
            payload: .object(["status": .string("interrupted")])))
        try await controller.interrupt()
        XCTAssertEqual(controller.runState, .idle)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.interrupt" }.count, 2)
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await runtime.stop()
    }

    func testDuplicateTerminalEventCausesExactlyOneCanonicalReload() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        var loadedIDs: [String] = []
        var terminalEvents = 0
        let controller = makeController(runtime: runtime, storedID: nil) { id, _, _, _ in
            loadedIDs.append(id)
            return self.page("tip")
        }
        controller.onEvent = { event in
            if event.type == "message.complete" { terminalEvents += 1 }
        }
        try await controller.submit("complete")

        let terminal = event(sessionID: "runtime-1", type: "message.complete", sequence: 9)
        fake.emit(terminal)
        await yieldUntil { loadedIDs.count == 1 }
        fake.emit(terminal)
        await Task.yield()

        XCTAssertEqual(terminalEvents, 1)
        XCTAssertEqual(loadedIDs, ["durable-1"])
        XCTAssertEqual(controller.storedID, "tip")
        XCTAssertNil(controller.binding)
        await runtime.stop()
    }

    func testConflictingResumeAliasesReloadCanonicalTranscriptWithoutBinding() async throws {
        let fake = ControllerFakeTransport()
        fake.setResumeResponse(.object([
            "session_id": .string("runtime-conflict"),
            "session_key": .string("tip-a"),
            "stored_session_id": .string("tip-b")
        ]))
        let runtime = try makeRuntime(fake)
        var loadedIDs: [String] = []
        let controller = makeController(runtime: runtime, storedID: "ancestor") { id, _, _, _ in
            loadedIDs.append(id)
            return self.page("tip-a")
        }

        do {
            try await controller.open()
            XCTFail("Expected conflicting aliases")
        } catch DirectSessionError.conflictingDurableIDs {
            // The canonical REST read is still authoritative.
        }

        XCTAssertEqual(loadedIDs, ["ancestor"])
        XCTAssertEqual(controller.storedID, "tip-a")
        XCTAssertNil(controller.binding)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.resume" }.count, 1)
        await runtime.stop()
    }

    func testTerminalRefreshBecomesStaleWhenNextPromptStarts() async throws {
        let fake = ControllerFakeTransport()
        let runtime = try makeRuntime(fake)
        let gate = AsyncGate()
        var loadCount = 0
        var transcriptCount = 0
        let controller = makeController(runtime: runtime, storedID: nil) { _, _, _, _ in
            loadCount += 1
            if loadCount == 1 { await gate.wait() }
            return self.page("durable-1")
        }
        controller.onTranscript = { _, _ in transcriptCount += 1 }
        try await controller.submit("first")

        fake.emit(event(sessionID: "runtime-1", type: "message.complete", sequence: 11))
        await yieldUntil { loadCount == 1 }
        try await controller.submit("next")
        await gate.release()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 2)
        XCTAssertEqual(transcriptCount, 0)
        await runtime.stop()
    }

    func testOlderResponseCrossingNewTailReadIsRejectedWithoutApplyingStaleCursor() async throws {
        let runtime = try makeRuntime(ControllerFakeTransport())
        let olderStarted = AsyncGate()
        let releaseOlder = AsyncGate()
        let controller = makeController(runtime: runtime, storedID: "durable-1") { id, _, _, offset in
            if offset > 0 {
                await olderStarted.release()
                await releaseOlder.wait()
            }
            return self.page(id)
        }
        var appliedKinds: [Bool] = []
        controller.onTranscript = { _, older in appliedKinds.append(older) }
        let olderRead = Task { try await controller.refresh(offset: 120) }
        await olderStarted.wait()
        try await controller.refresh()
        await releaseOlder.release()
        do {
            try await olderRead.value
            XCTFail("An old backwards cursor must not cross a new tail read")
        } catch DirectSessionError.staleOperation { }
        XCTAssertEqual(appliedKinds, [false])
        // The reader can explicitly retry with the current cursor.
        try await controller.refresh(offset: 120)
        XCTAssertEqual(appliedKinds, [false, true])
        await runtime.stop()
    }

    func testSlowTailResponseCannotOverwriteMoreRecentTailRead() async throws {
        let runtime = try makeRuntime(ControllerFakeTransport())
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()
        var readCount = 0
        let controller = makeController(runtime: runtime, storedID: "durable-1") { id, _, _, _ in
            readCount += 1
            if readCount == 1 {
                await firstStarted.release()
                await releaseFirst.wait()
            }
            return self.page(id)
        }
        var appliedCount = 0
        controller.onTranscript = { _, _ in appliedCount += 1 }
        let firstRead = Task { try await controller.refresh() }
        await firstStarted.wait()
        try await controller.refresh()
        await releaseFirst.release()
        do {
            try await firstRead.value
            XCTFail("A superseded tail response must not replace newer history")
        } catch DirectSessionError.staleOperation { }
        XCTAssertEqual(appliedCount, 1)
        await runtime.stop()
    }

    private func makeRuntime(_ fake: ControllerFakeTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: URL(string: "https://fixture.example")!) { sink in
            fake.installSink(sink)
            return fake
        }
    }

    private func makeController(
        runtime: HermesServerRuntime,
        storedID: String?,
        profile: String = "default",
        promptUncertaintyStore: any DirectPromptDeliveryUncertaintyStoreProtocol = InMemoryDirectPromptDeliveryUncertaintyStore(),
        loader: @escaping GatewayConversationController.TranscriptLoader = { id, _, _, _ in
            DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
    ) -> GatewayConversationController {
        let markerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayConversationControllerTests-\(UUID().uuidString)", isDirectory: true)
        let markerStore = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: markerRoot)
        return GatewayConversationController(
            runtime: runtime,
            storedID: storedID,
            profile: profile,
            recoveryMarkerStore: markerStore,
            promptUncertaintyStore: promptUncertaintyStore,
            loadTranscript: loader
        )
    }

    private func page(_ sessionID: String) -> DirectHermesTranscriptPage {
        DirectHermesTranscriptPage(sessionID: sessionID, messages: [], pagination: nil)
    }

    private func event(
        sessionID: String,
        type: String,
        sequence: Int,
        payload: JSONValue? = nil,
        method: String = "gateway.event"
    ) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: method,
            type: type,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload,
            params: nil,
            connectionGeneration: 1
        )
    }

    private func objectFields(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value, case .object(let fields) = value else { return nil }
        return fields
    }

    private func yieldUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ControllerFakeTransport: HermesGatewayTransport, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let params: JSONValue?
    }

    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var callsValue: [Call] = []
    private var generationValue = 0
    private var connected = false
    private var createCount = 0
    private var resumeResponse: JSONValue?
    private var resumeEventsBeforeResponse: [HermesGatewayEvent] = []
    private var resumeResponseGate: AsyncGate?
    private var sinkConsumedGate: AsyncGate?
    private var steerResponse: JSONValue = .object(["status": .string("accepted")])
    private var promptTimeout = false
    private var promptResponseGate: AsyncGate?
    private var promptServerError: HermesGatewayError?
    private var interruptResponse: JSONValue = .object([:])
    private var interruptEvent: HermesGatewayEvent?
    private var reasoningGetResponse: JSONValue = .object([
        "value": .string("medium"),
        "display": .string("show"),
        "session_reasoning_contract": .number(1),
        "deferred": .bool(false)
    ])
    private var reasoningGetGate: AsyncGate?
    private var reasoningSetResponse: JSONValue?
    private var reasoningSetGate: AsyncGate?
    private var sessionStatusResponse: JSONValue = .object([
        "output": .string("Agent Running: No")
    ])
    private var sessionStatusGate: AsyncGate?
    private var updatesReasoningReadback = true

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        let wrapped: @Sendable (HermesGatewayEvent) -> Void = { [weak self] event in
            sink(event)
            guard let self else { return }
            let gate = self.withLock { self.sinkConsumedGate }
            if let gate {
                Task { await gate.release() }
            }
        }
        withLock { self.sink = wrapped }
    }

    func setResumeResponse(_ response: JSONValue) {
        withLock { resumeResponse = response }
    }

    func setResumeEventsBeforeResponse(
        _ events: [HermesGatewayEvent],
        sinkConsumedGate: AsyncGate
    ) {
        withLock {
            resumeEventsBeforeResponse = events
            resumeResponseGate = sinkConsumedGate
            self.sinkConsumedGate = sinkConsumedGate
        }
    }

    func setSteerResponse(_ response: JSONValue) {
        withLock { steerResponse = response }
    }

    func setPromptTimeout(_ enabled: Bool) {
        withLock { promptTimeout = enabled }
    }

    func setPromptResponseGate(_ gate: AsyncGate) {
        withLock { promptResponseGate = gate }
    }

    func setPromptServerError(_ error: HermesGatewayError) {
        withLock { promptServerError = error }
    }

    func setInterruptResponse(_ response: JSONValue) {
        withLock { interruptResponse = response }
    }

    func setInterruptEvent(_ event: HermesGatewayEvent) {
        withLock { interruptEvent = event }
    }

    func setReasoningGetResponse(_ response: JSONValue) {
        withLock { reasoningGetResponse = response }
    }

    func setReasoningGetGate(_ gate: AsyncGate) {
        withLock { reasoningGetGate = gate }
    }

    func setReasoningSetResponse(_ response: JSONValue) {
        withLock { reasoningSetResponse = response }
    }

    func setReasoningSetGate(_ gate: AsyncGate) {
        withLock { reasoningSetGate = gate }
    }

    func setSessionStatusResponse(_ response: JSONValue) {
        withLock { sessionStatusResponse = response }
    }

    func setSessionStatusGate(_ gate: AsyncGate) {
        withLock { sessionStatusGate = gate }
    }

    func setUpdatesReasoningReadback(_ enabled: Bool) {
        withLock { updatesReasoningReadback = enabled }
    }

    func calls() -> [Call] {
        withLock { callsValue }
    }

    func connect() async throws {
        withLock {
            generationValue += 1
            connected = true
        }
    }

    func close() async {
        withLock { connected = false }
    }

    func connectionIdentifier() async -> Int? {
        withLock { connected ? generationValue : nil }
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        let behavior: (JSONValue?, [HermesGatewayEvent], AsyncGate?, Bool, HermesGatewayError?, JSONValue, JSONValue, HermesGatewayEvent?, Int)
        behavior = withLock {
            callsValue.append(Call(method: method, params: params))
            return (
                resumeResponse,
                resumeEventsBeforeResponse,
                resumeResponseGate,
                promptTimeout,
                promptServerError,
                steerResponse,
                interruptResponse,
                interruptEvent,
                callsValue.count
            )
        }

        switch method {
        case "session.create":
            let number = withLock {
                createCount += 1
                return createCount
            }
            return .object([
                "session_id": .string("runtime-\(number)"),
                "session_key": .string("durable-\(number)")
            ])
        case "session.resume":
            for event in behavior.1 { emit(event) }
            if let gate = behavior.2 {
                await gate.wait()
                withLock {
                    resumeEventsBeforeResponse.removeAll()
                    resumeResponseGate = nil
                    sinkConsumedGate = nil
                }
            }
            return behavior.0 ?? .object([
                "session_id": .string("runtime-resumed"),
                "session_key": .string("resumed")
            ])
        case "prompt.submit":
            let promptGate = withLock {
                let gate = promptResponseGate
                promptResponseGate = nil
                return gate
            }
            if let promptGate { await promptGate.wait() }
            if let error = behavior.4 { throw error }
            if behavior.3 {
                throw HermesGatewayError.timeout(method: method, requestID: "\(behavior.8)")
            }
            return .object(["status": .string("streaming")])
        case "session.steer":
            return behavior.5
        case "session.interrupt":
            if let event = behavior.7 { emit(event) }
            return behavior.6
        case "session.status":
            let (response, gate) = withLock {
                let gate = sessionStatusGate
                sessionStatusGate = nil
                return (sessionStatusResponse, gate)
            }
            if let gate { await gate.wait() }
            return response
        case "config.get":
            let (response, gate) = withLock {
                let gate = reasoningGetGate
                reasoningGetGate = nil
                return (reasoningGetResponse, gate)
            }
            if let gate { await gate.wait() }
            return response
        case "config.set":
            let (response, gate) = withLock {
                let gate = reasoningSetGate
                reasoningSetGate = nil
                return (reasoningSetResponse, gate)
            }
            if let gate { await gate.wait() }
            guard let params, case .object(let fields) = params,
                  let value = fields["value"]?.gatewayString else {
                return response ?? .object([:])
            }
            let result = response ?? .object([
                "key": .string("reasoning"),
                "value": .string(value),
                "scope": .string("session"),
                "deferred": .bool(false),
                "persisted": .bool(true)
            ])
            if withLock({ updatesReasoningReadback }),
               case .object(let fields) = result,
               let value = fields["value"]?.gatewayString {
                let deferred = fields["deferred"] == .bool(true)
                withLock {
                    var readback: [String: JSONValue] = [
                        "value": .string(value),
                        "display": .string("show"),
                        "deferred": .bool(deferred)
                    ]
                    if reasoningGetResponse.gatewayFields["session_reasoning_contract"] == .number(1) {
                        readback["session_reasoning_contract"] = .number(1)
                    } else {
                        readback.removeValue(forKey: "deferred")
                    }
                    reasoningGetResponse = .object(readback)
                }
            }
            return result
        default:
            return .object([:])
        }
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
