import Foundation
import XCTest
@testable import HermesCompanion

@MainActor
final class HostOperationIsolationTests: XCTestCase {
    func testWrongProfileResultCannotReplaceCurrentConversationOrDraft() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Keep this answer", sequence: 1))
        fixture.store.draft = "Keep this draft"
        let selection = fixture.store.selectedSession
        let open = Task { try await fixture.store.openResultConversation("other-session") }
        let request = try await fixture.request(host: "old", suffix: "/snapshot")
        var body = Self.positionedBody("Wrong profile answer", sequence: 1)
        body["session"] = ["id": "other-session", "title": "Wrong profile", "updated_at": "", "profile": "another-profile"]
        request.respond(body)
        do { try await open.value; XCTFail("A different profile must be rejected before changing the selection.") }
        catch { XCTAssertTrue(error is ClientError) }
        XCTAssertEqual(fixture.store.selectedSession?.id, selection?.id)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Keep this answer"])
        XCTAssertEqual(fixture.store.draft, "Keep this draft")
        XCTAssertTrue(fixture.store.canCommand)
    }
    func testReconnectReplacesHeldConnectionAndPreservesDisplay() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Keep this answer", sequence: 1))
        fixture.store.draft = "Keep this draft"
        fixture.store.connect()
        _ = try await fixture.request(host: "old", suffix: "/host")
        fixture.store.reconnect()
        _ = try await fixture.request(host: "old", suffix: "/host", index: 1)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Keep this answer"])
        XCTAssertEqual(fixture.store.draft, "Keep this draft")
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertTrue(fixture.store.requests.isEmpty)
        XCTAssertNil(fixture.store.controls)
        XCTAssertEqual(fixture.requests(host: "old").filter { $0.request.url!.path.hasSuffix("/host") }.count, 2)
    }
    func testOldAcceptedCommandDoesNotClearNewHostCommand() async throws {
        try await exerciseOldCommand(status: 200, receipt: "accepted")
    }
    func testOldUncertainReceiptDoesNotPublishIntoNewHost() async throws {
        try await exerciseOldCommand(status: 409, receipt: "uncertain")
    }
    func testOldRejectedReceiptDoesNotPublishIntoNewHost() async throws {
        try await exerciseOldCommand(status: 409, receipt: "rejected")
    }
    func testOldHTTPFailureDoesNotPublishIntoNewHost() async throws {
        try await exerciseOldCommand(status: 503, receipt: nil)
    }
    private func exerciseOldCommand(status: Int, receipt: String?) async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        fixture.store.routedUpdateID = "old-update"
        let old = Task { await fixture.store.execute(.init(operationId: "old-operation", kind: "send", text: "Old host send")) }
        addTeardownBlock { old.cancel(); _ = await old.value }
        let oldRequest = try await fixture.request(host: "old", suffix: "/commands")
        try fixture.useHost("new")
        XCTAssertNil(fixture.store.routedUpdateID)
        fixture.store.notice = "Current host notice"
        fixture.store.error = "Current host error"
        let current = Task { await fixture.store.execute(.init(operationId: "new-operation", kind: "send", text: "New host send")) }
        addTeardownBlock { current.cancel(); _ = await current.value }
        let currentRequest = try await fixture.request(host: "new", suffix: "/commands")
        if let receipt {
            oldRequest.respond(["operation_id": "old-operation", "status": receipt, "message": "Old host failure"], status: status)
        } else {
            oldRequest.respond(["error": ["code": "host_unavailable", "message": "Old transport failed"]], status: status)
        }
        _ = await old.value
        XCTAssertTrue(fixture.store.isSending)
        XCTAssertEqual(fixture.store.notice, "Current host notice")
        XCTAssertEqual(fixture.store.error, "Current host error")
        XCTAssertFalse(fixture.store.uncertain.contains { $0.operationID == "old-operation" })
        XCTAssertTrue(fixture.store.uncertain.allSatisfy { $0.scope?.deviceID == "new" })
        XCTAssertFalse(fixture.requests(host: "new").contains { $0.request.url!.path.hasSuffix("/snapshot") })
        XCTAssertEqual(fixture.store.displayMessages.map(\.text), ["New host send"])
        currentRequest.respond(["operation_id": "new-operation", "status": "uncertain"], status: 409)
        _ = await current.value
        XCTAssertFalse(fixture.store.isSending)
        XCTAssertEqual(fixture.store.currentUncertain.map(\.operationID), ["new-operation"])
        if receipt == nil || receipt == "uncertain" {
            XCTAssertTrue(fixture.journal.pending.contains { $0.operationID == "old-operation" && $0.scope?.deviceID == "old" })
        } else {
            XCTAssertFalse(fixture.journal.pending.contains { $0.operationID == "old-operation" })
        }
    }
    func testOldCreationDoesNotClearNewHostCommand() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        let creation = Task { await fixture.store.newSession() }
        addTeardownBlock { creation.cancel(); _ = await creation.value }
        let request = try await fixture.request(host: "old", suffix: "/sessions")
        try fixture.useHost("new")
        let current = Task { await fixture.store.execute(.init(operationId: "new-operation", kind: "send", text: "Current")) }
        addTeardownBlock { current.cancel(); _ = await current.value }
        let command = try await fixture.request(host: "new", suffix: "/commands")
        request.respond(["id": "old-created", "title": "Old", "updated_at": "", "profile": "test"])
        _ = await creation.value
        XCTAssertTrue(fixture.store.isSending)
        XCTAssertFalse(fixture.store.sessions.contains { $0.id == "old-created" })
        command.respond(["operation_id": "new-operation", "status": "accepted"])
        _ = await current.value
    }
    func testOldUploadFailureDoesNotClearNewHostCommand() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        let drafts = fixture.store.attachmentDrafts
        let file = fixture.directory.appendingPathComponent("upload.txt")
        try Data("Synthetic".utf8).write(to: file)
        drafts.set([.init(id: UUID(), name: "upload.txt", state: .ready(.init(fileURL: file, name: "upload.txt", mediaType: "text/plain", byteCount: 9, previewURL: nil)))], for: "same-session")
        fixture.store.draft = "Old attachment"
        let upload = Task { await fixture.store.send() }
        addTeardownBlock { upload.cancel(); await upload.value }
        let request = try await fixture.request(host: "old", suffix: "/attachments")
        try fixture.useHost("new")
        let current = Task { await fixture.store.execute(.init(operationId: "new-operation", kind: "send", text: "Current")) }
        addTeardownBlock { current.cancel(); _ = await current.value }
        let command = try await fixture.request(host: "new", suffix: "/commands")
        request.respond(["error": ["code": "host_unavailable", "message": "Old upload failure"]], status: 503)
        await upload.value
        XCTAssertTrue(fixture.store.isSending)
        XCTAssertNil(fixture.store.error)
        XCTAssertTrue(fixture.store.attachments.isEmpty)
        XCTAssertEqual(drafts.items(for: "same-session").first?.uncertainUpload, true)
        XCTAssertFalse(fixture.requests(host: "old").contains { $0.request.url!.path.hasSuffix("/commands") })
        command.respond(["operation_id": "new-operation", "status": "accepted"])
        _ = await current.value
    }
    func testOldInterruptDoesNotClearNewHostStop() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        let old = Task { await fixture.store.execute(.init(operationId: "old-stop", kind: "interrupt")) }
        addTeardownBlock { old.cancel(); _ = await old.value }
        let oldRequest = try await fixture.request(host: "old", suffix: "/commands")
        try fixture.useHost("new")
        let current = Task { await fixture.store.execute(.init(operationId: "new-stop", kind: "interrupt")) }
        addTeardownBlock { current.cancel(); _ = await current.value }
        let currentRequest = try await fixture.request(host: "new", suffix: "/commands")
        oldRequest.respond(["operation_id": "old-stop", "status": "accepted"])
        _ = await old.value
        XCTAssertTrue(fixture.store.isStopping)
        currentRequest.respond(["operation_id": "new-stop", "status": "accepted"])
        _ = await current.value
        XCTAssertFalse(fixture.store.isStopping)
    }
    func testPreOfflineSnapshotCannotRestoreAuthorityOrHideFailure() async throws {
        try await exerciseSnapshotInvalidation(state: "offline", message: "Host is unavailable")
    }
    func testPreSynchronizingSnapshotCannotRestoreAuthority() async throws {
        try await exerciseSnapshotInvalidation(state: "synchronizing", message: nil)
    }
    private func exerciseSnapshotInvalidation(state: String, message: String?) async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        let refresh = Task { try await fixture.store.refreshCurrent() }
        addTeardownBlock { refresh.cancel(); _ = try? await refresh.value }
        let request = try await fixture.request(host: "old", suffix: "/snapshot")
        var payload = ["state": state]
        payload["message"] = message
        try fixture.store.receive(Self.event(type: "connection", payload: payload))
        XCTAssertFalse(fixture.store.canCommand)
        request.respond(Self.snapshot(text: "Stale answer", requests: [["id": "stale-request", "generation": "stale", "kind": "approval", "title": "Stale", "description": "", "choices": []]]))
        try await refresh.value
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertTrue(fixture.store.requests.isEmpty)
        XCTAssertTrue(fixture.store.transcript.messages.isEmpty)
        XCTAssertEqual(fixture.store.connectionError, message)
        let fresh = Task { try await fixture.store.refreshCurrent() }
        addTeardownBlock { fresh.cancel(); _ = try? await fresh.value }
        let freshRequest = try await fixture.request(host: "old", suffix: "/snapshot", index: 1)
        freshRequest.respond(Self.snapshot(text: "Fresh answer"))
        try await fresh.value
        XCTAssertTrue(fixture.store.canCommand)
        XCTAssertNil(fixture.store.connectionError)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Fresh answer"])
    }
    func testBackgroundOldReceiptSettlesDraftWithoutStartingRefresh() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        fixture.store.draft = "Submitted draft"
        let send = Task { await fixture.store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let request = try await fixture.request(host: "old", suffix: "/commands")
        fixture.store.background()
        let operationID = try XCTUnwrap(request.operationID)
        request.respond(["operation_id": operationID, "status": "accepted", "message": "Old episode notice"])
        await send.value
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertEqual(fixture.store.connection, "")
        XCTAssertEqual(fixture.store.runState, .synchronizing)
        XCTAssertNil(fixture.store.notice)
        XCTAssertNil(fixture.store.error)
        XCTAssertFalse(fixture.requests(host: "old").contains { $0.request.url!.path.hasSuffix("/snapshot") })
    }
    func testReaderSendRetainsWorkingAndPublicReplyAfterPreSendPositionedSnapshotArrives() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        var beforeSend = Self.positionedBody("Previous answer", sequence: 1, state: "idle")
        try fixture.store.receive(Self.event(type: "snapshot", payload: beforeSend, position: ["epoch": "epoch", "sequence": 1]))
        fixture.store.readerPositionChanged(.anchored(messageID: "row", offsetFromUsableTop: 12),
            context: try XCTUnwrap(fixture.store.readerContext))
        XCTAssertTrue(fixture.store.isReadingHistory)
        fixture.store.draft = "Reader send"
        let send = Task { await fixture.store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await fixture.request(host: "old", suffix: "/commands")
        let heldSnapshot = try await fixture.request(host: "old", suffix: "/snapshot")
        let operationID = try XCTUnwrap(command.operationID)
        let receipt: [String: Any] = ["operation_id": operationID, "status": "accepted", "user_row_id": "sent-row"]
        try fixture.store.receive(Self.event(type: "connection", payload: ["state": "working"], position: ["epoch": "epoch", "sequence": 3]))
        try fixture.store.receive(Self.event(type: "receipt", payload: receipt, position: ["epoch": "epoch", "sequence": 4]))
        XCTAssertEqual(fixture.store.transcriptActivity, .working)
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertTrue(fixture.store.isSending)
        beforeSend["stream_position"] = ["epoch": "epoch", "sequence": 2]
        let staleRefresh = fixture.store.waitForScheduledRefreshes()
        heldSnapshot.respond(beforeSend)
        await staleRefresh.value
        XCTAssertEqual(fixture.store.runState, .working,
            "A pre-send HTTP snapshot must not erase the newer host working event while the accepted command response is held.")
        XCTAssertEqual(fixture.store.transcriptActivity, .working)
        XCTAssertEqual(fixture.store.displayMessages.map(\.text), ["Previous answer", "Reader send"])
        XCTAssertFalse(fixture.store.isReadingHistory)
        XCTAssertTrue(fixture.store.isSending)
        XCTAssertFalse(fixture.store.canCommand)
        let recovery = try await fixture.request(host: "old", suffix: "/snapshot", index: 1)
        var working = Self.positionedBody("Public intermediate reply", sequence: 5)
        let workingMessages: [[String: Any]] = [
            ["id": "row", "role": "assistant", "text": "Previous answer", "provisional": false],
            ["id": "sent-row", "role": "user", "text": "Reader send", "provisional": false, "operation_id": operationID],
            ["id": "interim", "role": "assistant", "text": "Public intermediate reply", "provisional": false]
        ]
        working["page"] = ["messages": workingMessages, "before": NSNull(), "has_more": false]
        recovery.respond(working)
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertTrue(fixture.store.canCommand)
        XCTAssertEqual(fixture.store.transcriptActivity, .working)
        XCTAssertEqual(fixture.store.displayMessages.map(\.text), ["Previous answer", "Reader send", "Public intermediate reply"])
        XCTAssertEqual(fixture.store.displayMessages.filter { $0.id == "sent-row" }.count, 1)
        fixture.store.draft = "Replacement draft"
        var completion = Self.positionedBody("Completed answer", sequence: 6, state: "idle")
        completion["page"] = ["messages": workingMessages + [
            ["id": "answer", "role": "assistant", "text": "Completed answer", "provisional": false]
        ], "before": NSNull(), "has_more": false]
        try fixture.store.receive(Self.event(type: "snapshot", payload: completion, position: ["epoch": "epoch", "sequence": 6]))
        XCTAssertEqual(fixture.store.transcriptActivity, .idle)
        XCTAssertTrue(fixture.store.isSending)
        command.respond(receipt)
        await send.value
        XCTAssertEqual(fixture.store.transcriptActivity, .idle,
            "A late HTTP acceptance must not restart a turn whose canonical reply is already complete.")
        let refreshed = try await fixture.request(host: "old", suffix: "/snapshot", index: 2)
        completion["stream_position"] = ["epoch": "epoch", "sequence": 7]
        refreshed.respond(completion)
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.runState, .idle)
        XCTAssertFalse(fixture.store.isSending)
        XCTAssertEqual(fixture.store.draft, "Replacement draft")
        XCTAssertEqual(fixture.store.displayMessages.map(\.text), ["Previous answer", "Reader send", "Public intermediate reply", "Completed answer"])
        XCTAssertEqual(fixture.store.displayMessages.map(\.id), fixture.store.transcript.messages.map(\.id))
        XCTAssertEqual(fixture.store.displayMessages.filter { $0.id == "sent-row" }.count, 1)
    }
    func testBufferedPreSnapshotDeltaDoesNotDuplicateInflightTextAfterReconnect() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Hello world", sequence: 3))
        try fixture.store.receive(Self.delta(" world", sequence: 2))
        fixture.store.background()
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Hello world"])
    }
    func testSnapshotCutDiscardsQueuedPrefixAndKeepsIdenticalPostCutDelta() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("ha", sequence: 1))
        try fixture.store.receive(Self.delta(" ha", sequence: 2))
        try fixture.store.receive(Self.delta(" ha", sequence: 4))
        try fixture.store.receive(Self.positionedSnapshot("ha ha", sequence: 3))
        try fixture.store.receive(Self.delta(" ha", sequence: 4))
        fixture.store.background()
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["ha ha ha"])
    }
    func testCompletionSnapshotUsesNewCutAfterLastDelta() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("A", sequence: 1))
        try fixture.store.receive(Self.delta("B", sequence: 2))
        try fixture.store.receive(Self.positionedSnapshot("AB", sequence: 3, state: "idle"))
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["AB"])
        XCTAssertEqual(fixture.store.runState, .idle)
        XCTAssertTrue(fixture.store.canCommand)
    }
    func testAppliedPostCutDeltaRejectsHeldSnapshotThenRecovers() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("A", sequence: 1))
        let refresh = Task { try await fixture.store.refreshCurrent() }
        addTeardownBlock { refresh.cancel(); _ = try? await refresh.value }
        let held = try await fixture.request(host: "old", suffix: "/snapshot")
        try fixture.store.receive(Self.delta("B", sequence: 3))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["AB"])
        held.respond(Self.positionedBody("A", sequence: 2))
        try await refresh.value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["AB"])
        XCTAssertFalse(fixture.store.canCommand)
        let recovery = try await fixture.request(host: "old", suffix: "/snapshot", index: 1)
        recovery.respond(Self.positionedBody("AB", sequence: 4))
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["AB"])
        XCTAssertTrue(fixture.store.canCommand)
    }
    func testEpochRotationBuffersPostCutWorkAndRejectsRetiredEpoch() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Old", sequence: 10))
        try fixture.store.receive(Self.delta("!", sequence: 3, epoch: "restarted"))
        XCTAssertFalse(fixture.store.canCommand)
        let recovery = try await fixture.request(host: "old", suffix: "/snapshot")
        recovery.respond(Self.positionedBody("New", sequence: 2, epoch: "restarted"))
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["New!"])
        XCTAssertTrue(fixture.store.canCommand)
        try fixture.store.receive(Self.delta(" stale", sequence: 11))
        try fixture.store.receive(Self.positionedSnapshot("Old response", sequence: 12))
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["New!"])
        XCTAssertTrue(fixture.store.canCommand)
    }
    func testEpochRecoveryRetriesBusySnapshotWithoutAnotherEvent() async throws {
        try await exerciseTransientRecovery(status: 409)
    }
    func testEpochRecoveryRetriesUnavailableSnapshotWithoutAnotherEvent() async throws {
        try await exerciseTransientRecovery(status: 503)
    }
    private func exerciseTransientRecovery(status: Int) async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Cached answer", sequence: 10))
        fixture.store.draft = "Keep this draft"
        try fixture.store.receive(Self.delta("!", sequence: 3, epoch: "restarted"))
        let first = try await fixture.request(host: "old", suffix: "/snapshot")
        first.respond(["error": ["code": "snapshot_unavailable", "message": "Snapshot is changing"]], status: status)
        let retry = try await fixture.request(host: "old", suffix: "/snapshot", index: 1)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Cached answer"])
        XCTAssertEqual(fixture.store.draft, "Keep this draft")
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertNil(fixture.store.connectionError)
        retry.respond(Self.positionedBody("Recovered", sequence: 2, epoch: "restarted"))
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Recovered!"])
        XCTAssertTrue(fixture.store.canCommand)
        XCTAssertNil(fixture.store.connectionError)
    }
    func testSameEpochRecoveryRetriesTransportFailureWithoutAnotherEvent() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("A", sequence: 1))
        try fixture.store.receive(Self.delta("B", sequence: 3))
        try await Task.sleep(for: .milliseconds(80))
        try fixture.store.receive(Self.positionedSnapshot("A", sequence: 2))
        let first = try await fixture.request(host: "old", suffix: "/snapshot")
        first.fail(URLError(.networkConnectionLost))
        let retry = try await fixture.request(host: "old", suffix: "/snapshot", index: 1)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["AB"])
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertNil(fixture.store.connectionError)
        retry.respond(Self.positionedBody("AB", sequence: 4))
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["AB"])
        XCTAssertTrue(fixture.store.canCommand)
    }
    func testStreamRecoveryExhaustionIsActionableAndDoesNotRetryOnMoreEvents() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Cached answer", sequence: 10))
        fixture.store.draft = "Keep this draft"
        try fixture.store.receive(Self.delta("!", sequence: 3, epoch: "restarted"))
        for index in 0..<3 {
            let request = try await fixture.request(host: "old", suffix: "/snapshot", index: index)
            request.respond(["error": ["code": "snapshot_unavailable", "message": "Snapshot is changing"]], status: 503)
        }
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertNotNil(fixture.store.connectionError)
        XCTAssertFalse(fixture.store.requiresPairing)
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Cached answer"])
        XCTAssertEqual(fixture.store.draft, "Keep this draft")
        try fixture.store.receive(Self.delta(" more", sequence: 4, epoch: "restarted"))
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.requests(host: "old").filter { $0.request.url!.path.hasSuffix("/snapshot") }.count, 3)
        try fixture.store.receive(Self.positionedSnapshot("Fresh answer", sequence: 5, epoch: "restarted", state: "idle"))
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Fresh answer"])
        XCTAssertTrue(fixture.store.canCommand)
        XCTAssertNil(fixture.store.connectionError)
    }
    func testRepeatedStaleSnapshotCutsExhaustWithoutRestartingRecoveryBudget() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("A", sequence: 1))
        try fixture.store.receive(Self.delta("B", sequence: 3))
        try await Task.sleep(for: .milliseconds(80))
        try fixture.store.receive(Self.positionedSnapshot("A", sequence: 2))
        for index in 0..<3 {
            let request = try await fixture.request(host: "old", suffix: "/snapshot", index: index)
            request.respond(Self.positionedBody("A", sequence: 2))
        }
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["AB"])
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertNotNil(fixture.store.connectionError)
        XCTAssertEqual(fixture.requests(host: "old").filter { $0.request.url!.path.hasSuffix("/snapshot") }.count, 3)
    }
    func testFreshSocketSnapshotCancelsHeldRecoveryBeforeLateAuthorizationFailure() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Cached answer", sequence: 10))
        try fixture.store.receive(Self.delta("!", sequence: 3, epoch: "restarted"))
        let held = try await fixture.request(host: "old", suffix: "/snapshot")
        try fixture.store.receive(Self.positionedSnapshot("Fresh answer", sequence: 4, epoch: "restarted", state: "idle"))
        held.respond(["error": ["code": "unauthorized", "message": "Old request failed"]], status: 401)
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Fresh answer"])
        XCTAssertTrue(fixture.store.canCommand)
        XCTAssertFalse(fixture.store.requiresPairing)
        XCTAssertNil(fixture.store.connectionError)
        XCTAssertEqual(fixture.requests(host: "old").filter { $0.request.url!.path.hasSuffix("/snapshot") }.count, 1)
    }
    func testStreamRecoveryUnauthorizedResponseRequiresPairingWithoutRetry() async throws {
        try await exerciseRecoveryAuthorizationFailure(status: 401)
    }
    func testStreamRecoveryForbiddenResponseRequiresPairingWithoutRetry() async throws {
        try await exerciseRecoveryAuthorizationFailure(status: 403)
    }
    private func exerciseRecoveryAuthorizationFailure(status: Int) async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Cached answer", sequence: 10))
        try fixture.store.receive(Self.delta("!", sequence: 3, epoch: "restarted"))
        let request = try await fixture.request(host: "old", suffix: "/snapshot")
        request.respond(["error": ["code": "unauthorized", "message": "Device revoked"]], status: status)
        await fixture.store.waitForScheduledRefreshes().value
        try fixture.store.receive(Self.delta(" more", sequence: 4, epoch: "restarted"))
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertTrue(fixture.store.requiresPairing)
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertNotNil(fixture.store.connectionError)
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Cached answer"])
        XCTAssertTrue(fixture.store.requests.isEmpty)
        XCTAssertNil(fixture.store.controls)
        XCTAssertEqual(fixture.requests(host: "old").filter { $0.request.url!.path.hasSuffix("/snapshot") }.count, 1)
        fixture.store.background()
        fixture.store.foreground()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(fixture.requests(host: "old").contains { $0.request.url!.path.hasSuffix("/host") },
            "Foreground must not retry a grant that requires replacement pairing.")
        XCTAssertTrue(fixture.store.requiresPairing)
    }
    func testOldHostStreamRecoveryCannotPublishFailureOrRetryAfterReplacement() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Old answer", sequence: 10))
        try fixture.store.receive(Self.delta("!", sequence: 3, epoch: "restarted"))
        let held = try await fixture.request(host: "old", suffix: "/snapshot")
        try fixture.useHost("new")
        try fixture.store.receive(Self.positionedSnapshot("New host answer", sequence: 1))
        held.respond(["error": ["code": "unauthorized", "message": "Old device revoked"]], status: 401)
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["New host answer"])
        XCTAssertTrue(fixture.store.canCommand)
        XCTAssertFalse(fixture.store.requiresPairing)
        XCTAssertNil(fixture.store.connectionError)
        XCTAssertEqual(fixture.requests(host: "old").filter { $0.request.url!.path.hasSuffix("/snapshot") }.count, 1)
        XCTAssertFalse(fixture.requests(host: "new").contains { $0.request.url!.path.hasSuffix("/snapshot") })
    }
    func testBackgroundCancelsPendingStreamRecoveryWithoutRetryOrNotice() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Cached answer", sequence: 10))
        try fixture.store.receive(Self.delta("!", sequence: 3, epoch: "restarted"))
        let held = try await fixture.request(host: "old", suffix: "/snapshot")
        fixture.store.background()
        held.respond(["error": ["code": "snapshot_unavailable", "message": "Snapshot is changing"]], status: 503)
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Cached answer"])
        XCTAssertFalse(fixture.store.canCommand)
        XCTAssertNil(fixture.store.connectionError)
        XCTAssertEqual(fixture.requests(host: "old").filter { $0.request.url!.path.hasSuffix("/snapshot") }.count, 1)
    }
    func testBufferedRequestAfterDeltaKeepsWaitingStateWhenSnapshotArrives() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Old answer", sequence: 10))
        try fixture.store.receive(Self.delta("!", sequence: 3, epoch: "restarted"))
        let request: [String: Any] = ["id": "approval", "generation": "current", "kind": "approval", "title": "Confirm", "description": "", "choices": []]
        try fixture.store.receive(Self.event(type: "requests", payload: ["requests": [request]], position: ["epoch": "restarted", "sequence": 4]))
        let recovery = try await fixture.request(host: "old", suffix: "/snapshot")
        recovery.respond(Self.positionedBody("Recovered", sequence: 2, epoch: "restarted"))
        await fixture.store.waitForScheduledRefreshes().value
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Recovered!"])
        XCTAssertEqual(fixture.store.requests.map(\.id), ["approval"])
        XCTAssertEqual(fixture.store.runState, .waiting)
        XCTAssertTrue(fixture.store.canCommand)
    }
    func testHostSwitchResetsStreamCursorEvenForReusedSessionAndEpoch() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Old", sequence: 100))
        try fixture.store.receive(Self.delta(" queued", sequence: 101))
        try fixture.useHost("new")
        try fixture.store.receive(Self.positionedSnapshot("New", sequence: 1))
        fixture.store.background()
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["New"])
    }
    func testCoveredReceiptStillResolvesOperationJournal() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        fixture.journal.begin(.init(operationId: "covered-operation", kind: "send"), sessionID: "same-session", scope: HostScope(try XCTUnwrap(fixture.store.grant)))
        try fixture.store.receive(Self.positionedSnapshot("Accepted", sequence: 10))
        try fixture.store.receive(Self.event(type: "receipt", payload: ["operation_id": "covered-operation", "status": "accepted"], position: ["epoch": "epoch", "sequence": 5]))
        XCTAssertFalse(fixture.journal.pending.contains { $0.operationID == "covered-operation" })
        XCTAssertTrue(fixture.store.currentUncertain.isEmpty)
    }
    func testSelectionResetDropsQueuedPreviousConversationAndAcceptsLowerCut() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("Previous", sequence: 100))
        try fixture.store.receive(Self.delta(" queued", sequence: 101))
        fixture.store.selectedSession = .init(id: "another-session", title: "Another", updatedAt: "", profile: "test")
        var body = Self.positionedBody("Current", sequence: 1)
        body["session"] = ["id": "another-session", "title": "Another", "updated_at": "", "profile": "test"]
        try fixture.store.receive(Self.event(type: "snapshot", payload: body, position: ["epoch": "epoch", "sequence": 1], sessionID: "another-session"))
        fixture.store.background()
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Current"])
    }
    func testBackgroundResetsEpisodeCursorAfterFlushingVisibleWork() async throws {
        let fixture = try HostOperationFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try fixture.useHost("old")
        try fixture.store.receive(Self.positionedSnapshot("A", sequence: 100))
        try fixture.store.receive(Self.delta("B", sequence: 101))
        fixture.store.background()
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["AB"])
        try fixture.store.receive(Self.positionedSnapshot("Fresh episode", sequence: 1))
        XCTAssertEqual(fixture.store.transcript.messages.map(\.text), ["Fresh episode"])
        XCTAssertFalse(fixture.store.canCommand)
    }
    func testInvalidStreamPositionIsRejected() throws {
        XCTAssertThrowsError(try Self.event(type: "delta", payload: ["id": "row", "text": "A", "replace": false], position: ["epoch": "", "sequence": 1]))
        XCTAssertThrowsError(try Self.event(type: "delta", payload: ["id": "row", "text": "A", "replace": false], position: ["epoch": "epoch", "sequence": -1]))
    }
    private static func delta(_ text: String, sequence: Int, epoch: String = "epoch") throws -> WireEvent {
        try event(type: "delta", payload: ["id": "row", "text": text, "replace": false], position: ["epoch": epoch, "sequence": sequence])
    }
    private static func positionedSnapshot(_ text: String, sequence: Int, epoch: String = "epoch", state: String = "working") throws -> WireEvent {
        try event(type: "snapshot", payload: positionedBody(text, sequence: sequence, epoch: epoch, state: state), position: ["epoch": epoch, "sequence": sequence])
    }
    private static func positionedBody(_ text: String, sequence: Int, epoch: String = "epoch", state: String = "working") -> [String: Any] {
        var body = snapshot(text: text)
        body["state"] = state
        body["stream_position"] = ["epoch": epoch, "sequence": sequence]
        body["page"] = ["messages": [["id": "row", "role": "assistant", "text": text, "provisional": state == "working"]], "before": NSNull(), "has_more": false]
        return body
    }
    private static func event(type: String, payload: [String: Any], position: [String: Any]? = nil, sessionID: String = "same-session") throws -> WireEvent {
        var body: [String: Any] = ["type": type, "session_id": sessionID, "payload": payload]
        body["stream_position"] = position
        return try CompanionAPI.decoder.decode(WireEvent.self, from: JSONSerialization.data(withJSONObject: body))
    }
    private static func snapshot(text: String, requests: [[String: Any]] = []) -> [String: Any] {
        ["session": ["id": "same-session", "title": "Current", "updated_at": "", "profile": "test"],
         "page": ["messages": [["id": "row", "role": "assistant", "text": text, "provisional": false]], "before": NSNull(), "has_more": false],
         "state": "idle", "requests": requests,
         "controls": ["model": "test", "provider": "test", "reasoning": "medium", "reasoning_levels": [], "models": [], "commands": []]]
    }
}

@MainActor
private final class HostOperationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let defaults: UserDefaults
    let journal: OperationJournal
    let session: URLSession
    let store: AppStore
    private let exchange = HostOperationExchange()
    private var hosts: [String: String] = [:]
    private var draftDirectories: [URL] = []
    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        journal = OperationJournal(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostOperationProtocol.self]
        session = URLSession(configuration: configuration)
        store = AppStore(api: .init(baseURL: URL(string: "https://unused.invalid")!, token: nil, session: session), journal: journal, displayCache: ConversationDisplayCache(directory: directory.appendingPathComponent("cache")))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func useHost(_ name: String) throws {
        let host = "\(name)-\(suite).invalid"
        hosts[name] = host
        HostOperationProtocol.register(exchange, host: host)
        let url = URL(string: "https://" + host)!
        let grant = DeviceGrant(baseURL: url.absoluteString, deviceID: name, token: "synthetic", host: .init(name: name, profile: "test"))
        let memory = ConversationMemory(hostID: name, defaults: defaults)
        memory.select("same-session")
        store.usePairedHost(grant, api: .init(baseURL: url, token: nil, session: session), memory: memory)
        draftDirectories.append(store.attachmentDrafts.directory)
        try store.receiveFreshSnapshotForTesting()
    }
    func requests(host: String) -> [HostOperationProtocol] { exchange.requests.filter { $0.request.url?.host == hosts[host] } }
    func request(host: String, suffix: String, index: Int = 0) async throws -> HostOperationProtocol {
        for _ in 0..<300 {
            let matching = requests(host: host).filter { $0.request.url!.path.hasSuffix(suffix) }
            if matching.indices.contains(index) { return matching[index] }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Missing controlled request for \(host) \(suffix)")
        throw ClientError.invalidResponse
    }
    func close() async {
        store.background()
        await store.waitForScheduledRefreshes().value
        session.invalidateAndCancel()
        for host in hosts.values { HostOperationProtocol.unregister(host: host) }
        defaults.removePersistentDomain(forName: suite)
        for directory in draftDirectories { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class HostOperationExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [HostOperationProtocol] = []
    var requests: [HostOperationProtocol] { lock.withLock { held } }
    func receive(_ request: HostOperationProtocol) { lock.withLock { held.append(request) } }
}

private final class HostOperationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var exchanges: [String: HostOperationExchange] = [:]
    private(set) var operationID: String?
    static func register(_ exchange: HostOperationExchange, host: String) { lock.withLock { exchanges[host] = exchange } }
    static func unregister(host: String) { _ = lock.withLock { exchanges.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        operationID = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["operation_id"] as? String
        let exchange = Self.lock.withLock { Self.exchanges[request.url!.host!] }
        exchange?.receive(self)
    }
    override func stopLoading() {}
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
    func respond(_ object: [String: Any], status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
}
