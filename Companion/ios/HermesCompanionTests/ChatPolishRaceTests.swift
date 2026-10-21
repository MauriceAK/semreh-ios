import Foundation
import XCTest
@testable import HermesCompanion

@MainActor
final class ChatPolishRaceTests: XCTestCase {
    private var session: URLSession!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: AppStore!
    private var attachments: AttachmentDrafts!
    override func setUp() async throws {
        suite = "chat-polish-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolishHeldProtocol.self]
        session = URLSession(configuration: configuration)
        PolishHeldProtocol.reset()
        store = AppStore(api: .init(baseURL: URL(string: "http://127.0.0.1/\(suite!)")!, token: nil, session: session), journal: OperationJournal(defaults: defaults), memory: ConversationMemory(hostID: suite, defaults: defaults))
        attachments = AttachmentDrafts(hostID: suite)
        store.attachmentDrafts = attachments
        store.connection = "Connected"
        store.selectedSession = .init(id: "first", title: "First", updatedAt: "", profile: "test")
        store.runState = .idle
    }
    override func tearDown() async throws {
        if let store {
            store.background()
            await store.waitForScheduledRefreshes().value
        }
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: attachments.directory)
        PolishHeldProtocol.reset()
    }
    func testAcceptedSendClearsDraftAndUnlocksStopBeforeSlowReadCompletes() async throws {
        store.draft = "Accepted message"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); _ = await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        let snapshot = try await request("/snapshot")
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(store.runState, .working)
        let stop = Task { await store.execute(.init(kind: "interrupt")) }
        addTeardownBlock { stop.cancel(); _ = await stop.value }
        let interrupt = try await request("/commands", index: 1)
        XCTAssertEqual(interrupt.json["kind"] as? String, "interrupt")
        interrupt.respond(["operation_id": interrupt.json["operation_id"]!, "status": "accepted"])
        let stopped = await stop.value
        XCTAssertTrue(stopped)
        snapshot.respond(snapshotBody(text: "Accepted message"))
        await send.value
    }
    func testAcceptedReceiptShowsCanonicalUserBeforeSlowSnapshot() async throws {
        store.draft = "hi"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted", "user_row_id": "official-user-41"])
        await send.value
        let snapshot = try await request("/snapshot")
        XCTAssertEqual(store.displayMessages.map(\.id), ["official-user-41"])
        XCTAssertEqual(store.displayMessages.first?.role, "user")
        XCTAssertEqual(store.displayMessages.first?.text, "hi")
        XCTAssertTrue(store.transcript.messages.isEmpty, "A receipt preview must not fabricate a canonical history row.")
        XCTAssertEqual(store.runState, .working)
        var body = snapshotBody(text: "Hello")
        body["page"] = ["messages": [
            ["id": "official-user-41", "role": "user", "text": "hi", "provisional": false],
            ["id": "official-assistant-42", "role": "assistant", "text": "Hello", "provisional": false]
        ], "before": NSNull(), "has_more": false]
        snapshot.respond(body)
        await store.waitForScheduledRefreshes().value
        XCTAssertEqual(store.transcript.messages.map(\.id), ["official-user-41", "official-assistant-42"])
        XCTAssertEqual(store.displayMessages.map(\.id), ["official-user-41", "official-assistant-42"])
    }
    func testWorkingAndReplyBeforeSendReceiptWaitForUserRow() async throws {
        store.draft = "hi"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        try store.receive(connectionEvent(state: "working"))
        XCTAssertEqual(store.transcriptActivity, .idle, "A new send must not show the working bubble before its user message.")
        let delta = try CompanionAPI.decoder.decode(WireEvent.self, from: Data(#"{"type":"delta","session_id":"first","payload":{"id":"official-assistant-42","text":"Hello","replace":true}}"#.utf8))
        try store.receive(delta)
        for _ in 0..<100 where store.transcript.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.transcript.messages.first?.text, "Hello")
        XCTAssertTrue(store.displayMessages.isEmpty, "Keep an overtaking assistant response behind the unconfirmed submission.")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted", "user_row_id": "official-user-41"])
        await send.value
        XCTAssertEqual(store.displayMessages.map(\.id), ["official-user-41", "official-assistant-42"])
        XCTAssertEqual(store.transcriptActivity, .working)
    }
    func testSteeringExistingRunKeepsWorkingIndicatorDuringReceipt() async throws {
        store.runState = .working
        store.draft = "Please use the other file"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        XCTAssertEqual(store.transcriptActivity, .working)
        command.respond(["operation_id": command.json["operation_id"]!, "status": "steered"])
        await send.value
        XCTAssertEqual(store.transcriptActivity, .working)
    }
    func testToolProgressDoesNotBecomeChatNotice() throws {
        let event = try CompanionAPI.decoder.decode(WireEvent.self, from: Data(#"{"type":"connection","session_id":"first","payload":{"state":"working","message":"mcp__gbrain__recall"}}"#.utf8))
        try store.receive(event)
        XCTAssertEqual(store.runState, .working)
        XCTAssertNil(store.notice)
        XCTAssertNil(store.error)
    }
    func testFailedAgentEventRemainsVisible() throws {
        let event = try CompanionAPI.decoder.decode(WireEvent.self, from: Data(#"{"type":"connection","session_id":"first","payload":{"state":"failed","message":"The model provider rejected this request."}}"#.utf8))
        try store.receive(event)
        XCTAssertEqual(store.runState, .failed)
        XCTAssertTrue([store.notice, store.error].contains("The model provider rejected this request."))
    }
    func testOrdinarySyncIsQuietAndActualDisconnectClearsOnlyOnRecovery() throws {
        try store.receive(hostConnectionEvent(state: "synchronizing", message: "Refreshing Hermes state."))
        XCTAssertNil(store.connectionError)
        XCTAssertNil(store.notice)
        try store.receive(hostConnectionEvent(state: "offline", message: "Hermes is unavailable."))
        XCTAssertEqual(store.connectionError, "Hermes is unavailable.")
        try store.receive(hostConnectionEvent(state: "synchronizing", message: "Refreshing Hermes state."))
        XCTAssertEqual(store.connectionError, "Hermes is unavailable.")
        try store.receive(hostConnectionEvent(state: "connected", message: nil))
        XCTAssertNil(store.connectionError)
        XCTAssertEqual(store.connection, "Connected")
    }
    func testSynchronizationDoesNotEraseConcurrentAgentFailure() async throws {
        let synchronization = Task { await store.routeNotification(updateID: "controlled-update", sessionID: nil) }
        addTeardownBlock { synchronization.cancel(); await synchronization.value }
        try await request("/host").respond(["version": 1, "capabilities": ["notifications": false]])
        try await request("/sessions").respond(["sessions": [["id": "first", "title": "First", "updated_at": "", "profile": "test"]]])
        try await request("/snapshot").respond(snapshotBody(text: "Existing answer"))
        try await request("/updates").respond(["updates": []])
        let preferences = try await request("/preferences")
        let failure = try CompanionAPI.decoder.decode(WireEvent.self, from: Data(#"{"type":"connection","session_id":"first","payload":{"state":"failed","message":"The provider rejected this request."}}"#.utf8))
        try store.receive(failure)
        XCTAssertEqual(store.error, "The provider rejected this request.")
        preferences.respond(["notifications_enabled": true, "quiet_start": NSNull(), "quiet_end": NSNull(), "time_zone": "UTC"])
        await synchronization.value
        XCTAssertEqual(store.error, "The provider rejected this request.", "Healthy transport recovery must not acknowledge an agent failure for the user.")
    }
    func testAcceptedPreviewSurvivesStaleSnapshotAndCanonicalContentWins() async throws {
        store.draft = "hi"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted", "user_row_id": "user-41"])
        await send.value
        let snapshot = try await request("/snapshot")
        var stale = snapshotBody(text: "")
        stale["page"] = ["messages": [], "before": NSNull(), "has_more": false]
        snapshot.respond(stale)
        await store.waitForScheduledRefreshes().value
        XCTAssertEqual(store.displayMessages.map(\.id), ["user-41"])
        XCTAssertTrue(store.transcript.messages.isEmpty)
        try receiveSnapshot(messages: [["id": "user-41", "role": "user", "text": "Canonical hi", "provisional": false]], state: "idle")
        XCTAssertEqual(store.displayMessages.map(\.text), ["Canonical hi"])
        XCTAssertEqual(store.displayMessages, store.transcript.messages)
    }
    func testRepeatedTextReceiptsRemainDistinctAndOrdered() async throws {
        for index in 1...2 {
            store.draft = "hi"
            let send = Task { await store.send() }
            addTeardownBlock { send.cancel(); await send.value }
            let command = try await request("/commands", index: index - 1)
            command.respond(["operation_id": command.json["operation_id"]!, "status": index == 1 ? "accepted" : "queued", "user_row_id": "user-\(index)"])
            await send.value
        }
        XCTAssertEqual(store.displayMessages.map(\.id), ["user-1", "user-2"])
        XCTAssertEqual(store.displayMessages.map(\.text), ["hi", "hi"])
        try receiveSnapshot(messages: [["id": "user-1", "role": "user", "text": "hi", "provisional": false]], state: "working")
        XCTAssertEqual(store.displayMessages.map(\.id), ["user-1", "user-2"])
        try receiveSnapshot(messages: [
            ["id": "user-1", "role": "user", "text": "hi", "provisional": false],
            ["id": "user-2", "role": "user", "text": "hi", "provisional": false]
        ], state: "working")
        XCTAssertEqual(store.displayMessages.map(\.id), ["user-1", "user-2"])
    }
    func testCanonicalRowBeforeReceiptDoesNotDuplicateOrRestartFinishedRun() async throws {
        store.draft = "hi"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        try receiveSnapshot(messages: [
            ["id": "user-41", "role": "user", "text": "hi", "provisional": false],
            ["id": "assistant-42", "role": "assistant", "text": "Hello", "provisional": false]
        ], state: "idle")
        XCTAssertEqual(store.displayMessages.map(\.id), ["user-41", "assistant-42"], "Canonical history must remain visible while its HTTP receipt is still held.")
        XCTAssertEqual(store.transcriptActivity, .idle)
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted", "user_row_id": "user-41"])
        await send.value
        XCTAssertEqual(store.displayMessages.map(\.id), ["user-41", "assistant-42"])
        XCTAssertEqual(store.transcriptActivity, .idle)
    }
    func testReceiptWithoutRowIDWaitsForCanonicalEvidence() async throws {
        store.draft = "hi"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        await send.value
        XCTAssertTrue(store.displayMessages.isEmpty)
        XCTAssertEqual(store.transcriptActivity, .idle)
        let snapshot = try await request("/snapshot")
        var body = snapshotBody(text: "Hello")
        body["page"] = ["messages": [["id": "official-user", "role": "user", "text": "hi", "provisional": false]], "before": NSNull(), "has_more": false]
        snapshot.respond(body)
        await store.waitForScheduledRefreshes().value
        XCTAssertEqual(store.displayMessages.map(\.id), ["official-user"])
        XCTAssertEqual(store.transcriptActivity, .working)
    }
    func testRejectedSendPreservesDraftWithoutPreviewOrFakeHistory() async throws {
        store.draft = "hi"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "rejected", "message": "This action was rejected."])
        await send.value
        XCTAssertEqual(store.draft, "hi")
        XCTAssertTrue(store.displayMessages.isEmpty)
        XCTAssertTrue(store.transcript.messages.isEmpty)
        XCTAssertEqual(store.error, "This action was rejected.")
        XCTAssertEqual(store.transcriptActivity, .idle)
    }
    func testWebSocketReceiptConfirmsSendEvenIfHTTPResponseIsLost() async throws {
        store.draft = "hi"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        try store.receive(connectionEvent(state: "working"))
        let data = try JSONSerialization.data(withJSONObject: ["type": "receipt", "session_id": "first", "payload": [
            "operation_id": command.json["operation_id"]!, "status": "accepted", "user_row_id": "user-41"
        ]])
        let receipt = try CompanionAPI.decoder.decode(WireEvent.self, from: data)
        try store.receive(receipt)
        try store.receive(receipt)
        XCTAssertEqual(store.displayMessages.map(\.id), ["user-41"])
        command.fail(URLError(.networkConnectionLost))
        await send.value
        XCTAssertEqual(store.draft, "")
        XCTAssertTrue(store.uncertain.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.displayMessages.map(\.id), ["user-41"])
        XCTAssertEqual(store.transcriptActivity, .working)
    }
    func testUnconfirmedSendKeepsDraftAndDoesNotInventUserRow() async throws {
        store.draft = "hi"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        command.fail(URLError(.networkConnectionLost))
        await send.value
        XCTAssertEqual(store.draft, "hi")
        XCTAssertEqual(store.currentUncertain.count, 1)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.displayMessages.isEmpty)
        XCTAssertTrue(store.transcript.messages.isEmpty)
    }
    func testAcknowledgedUncertainSendDoesNotHideSuccessfulRetry() async throws {
        store.draft = "hi"
        let first = Task { await store.send() }
        addTeardownBlock { first.cancel(); await first.value }
        let lost = try await request("/commands")
        lost.fail(URLError(.networkConnectionLost))
        await first.value
        let uncertain = try XCTUnwrap(store.currentUncertain.first)
        store.acknowledgeUncertain(uncertain)
        XCTAssertTrue(store.currentUncertain.isEmpty)
        let retry = Task { await store.send() }
        addTeardownBlock { retry.cancel(); await retry.value }
        let command = try await request("/commands", index: 1)
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted", "user_row_id": "retry-user"])
        await retry.value
        let delta = try CompanionAPI.decoder.decode(WireEvent.self, from: Data(#"{"type":"delta","session_id":"first","payload":{"id":"retry-assistant","text":"Hello","replace":true}}"#.utf8))
        try store.receive(delta)
        for _ in 0..<100 where store.transcript.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.displayMessages.map(\.id), ["retry-user", "retry-assistant"])
        XCTAssertEqual(store.transcriptActivity, .working)
    }
    func testAcceptedRefreshDoesNotRetainStoreAfterOwnerReleasesIt() async throws {
        store.draft = "Accepted message"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); _ = await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        await send.value
        let snapshot = try await request("/snapshot")
        let completion = store.waitForScheduledRefreshes()
        addTeardownBlock { @MainActor [weak owner = store] in
            owner?.background()
            await completion.value
        }
        weak var released = store
        store = nil
        for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(released, "An unfinished read must not retain the conversation owner.")
        released?.background()
        await completion.value
        for _ in 0..<100 where !snapshot.wasStopped { try await Task.sleep(for: .milliseconds(10)) }
        if !snapshot.wasStopped { await logRefreshTasks("after-owner-release", selected: snapshot) }
        XCTAssertTrue(snapshot.wasStopped)
    }
    func testBackgroundCancelsHeldRefreshWithoutApplyingItsResponse() async throws {
        store.draft = "Accepted message"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); _ = await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        await send.value
        let snapshot = try await request("/snapshot")
        store.background()
        for _ in 0..<100 where !snapshot.wasStopped { try await Task.sleep(for: .milliseconds(10)) }
        if !snapshot.wasStopped { await logRefreshTasks("after-background", selected: snapshot) }
        XCTAssertTrue(snapshot.wasStopped)
        XCTAssertEqual(store.connection, "Paused")
        XCTAssertTrue(store.transcript.messages.isEmpty)
    }
    func testBackgroundDrainsSupersededAndCurrentRefreshesBeforeSessionInvalidation() async throws {
        store.draft = "Accepted message"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        await send.value
        let superseded = try await request("/snapshot")

        let stop = Task { await store.execute(.init(kind: "interrupt")) }
        addTeardownBlock { stop.cancel(); _ = await stop.value }
        let interrupt = try await request("/commands", index: 1)
        interrupt.respond(["operation_id": interrupt.json["operation_id"]!, "status": "accepted"])
        let accepted = await stop.value
        XCTAssertTrue(accepted)
        let current = try await request("/snapshot", index: 1)

        let completion = store.waitForScheduledRefreshes()
        store.background()
        await completion.value

        let remaining = await session.allTasks
        XCTAssertTrue(remaining.isEmpty)
        for _ in 0..<100 where !superseded.wasStopped || !current.wasStopped { try await Task.sleep(for: .milliseconds(10)) }
        if !superseded.wasStopped { await logRefreshTasks("after-drain-superseded", selected: superseded) }
        if !current.wasStopped { await logRefreshTasks("after-drain-current", selected: current) }
        XCTAssertTrue(superseded.wasStopped)
        XCTAssertTrue(current.wasStopped)
        XCTAssertEqual(store.connection, "Paused")
        XCTAssertTrue(store.transcript.messages.isEmpty)
        session.invalidateAndCancel()
    }
    func testRequestLookupIgnoresLateSnapshotFromPreviousSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolishHeldProtocol.self]
        let previousSession = URLSession(configuration: configuration)
        let previousOwner = "previous-" + UUID().uuidString
        let previousURL = URL(string: "http://127.0.0.1/\(previousOwner)/v1/sessions/first/snapshot")!
        PolishHeldProtocol.reset()
        let previousRead = Task { try? await previousSession.data(from: previousURL) }
        addTeardownBlock {
            previousRead.cancel()
            _ = await previousRead.value
            previousSession.invalidateAndCancel()
        }
        let previousSnapshot = try await request("/snapshot", owner: previousOwner)
        store.draft = "Accepted message"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); _ = await send.value }
        let command = try await request("/commands")
        command.respond(["operation_id": command.json["operation_id"]!, "status": "accepted"])
        await send.value
        let snapshot = try await request("/snapshot")
        if snapshot.request.url?.path.hasPrefix("/\(suite!)/") != true {
            await logRefreshTasks("late-previous-session", selected: snapshot)
        }
        XCTAssertTrue(snapshot.request.url?.path.hasPrefix("/\(suite!)/") == true,
                      "Request lookup must select the current test's snapshot.")
        store.background()
        for _ in 0..<100 where !snapshot.wasStopped { try await Task.sleep(for: .milliseconds(10)) }
        if !snapshot.wasStopped { await logRefreshTasks("isolated-background", selected: snapshot) }
        XCTAssertTrue(snapshot.wasStopped)
        XCTAssertFalse(previousSnapshot.wasStopped)
        XCTAssertEqual(store.connection, "Paused")
        XCTAssertTrue(store.transcript.messages.isEmpty)
        previousRead.cancel()
        _ = await previousRead.value
    }
    func testLoadedLatestMovesWithoutSnapshotAndPreservesRows() async throws {
        try store.transcript.replace(.init(messages: [.init(id: "loaded", role: "assistant", text: "Already here", provisional: false)], before: "cursor", hasMore: true))
        store.isReadingHistory = true
        let messages = store.transcript.messages
        let revision = store.latestRevision
        let latest = Task { await store.latest() }
        addTeardownBlock { latest.cancel(); await latest.value }
        for _ in 0..<30 where store.latestRevision == revision { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(store.latestRevision, revision, "A loaded Latest jump must not wait for transport.")
        XCTAssertFalse(store.isReadingHistory)
        XCTAssertEqual(store.transcript.messages, messages)
        XCTAssertTrue(heldRequests().isEmpty, "Loaded Latest must not request a snapshot.")
        latest.cancel()
        await latest.value
    }
    func testSkippedSnapshotRequiresLatestFetchAndIgnoresDuplicateTap() async throws {
        try store.transcript.replace(.init(messages: [.init(id: "old", role: "assistant", text: "Old", provisional: false)], before: nil, hasMore: false))
        store.isReadingHistory = true
        let refresh = Task { try await store.refreshCurrent() }
        addTeardownBlock { refresh.cancel(); _ = try? await refresh.value }
        let skipped = try await request("/snapshot")
        skipped.respond(snapshotBody(text: "Canonical"))
        try await refresh.value
        XCTAssertTrue(store.newActivity)
        XCTAssertFalse(store.transcript.hasNewer)
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Old"])
        let revision = store.latestRevision
        let latest = Task { await store.latest() }
        addTeardownBlock { latest.cancel(); await latest.value }
        let pending = try await request("/snapshot", index: 1)
        XCTAssertTrue(store.isFetchingLatest)
        XCTAssertTrue(store.isReadingHistory)
        XCTAssertEqual(store.latestRevision, revision)
        await store.latest()
        XCTAssertEqual(heldRequests().count, 2)
        pending.respond(snapshotBody(text: "Canonical"))
        await latest.value
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Canonical"])
        XCTAssertFalse(store.isFetchingLatest)
        XCTAssertFalse(store.newActivity)
        XCTAssertNotEqual(store.latestRevision, revision)
    }
    func testForcedRefreshFetchesEvenWhenLatestRowsAreLoaded() async throws {
        try store.transcript.replace(.init(messages: [.init(id: "loaded", role: "assistant", text: "Loaded", provisional: false)], before: nil, hasMore: false))
        let revision = store.latestRevision
        let latest = Task { await store.latest(forceRefresh: true) }
        addTeardownBlock { latest.cancel(); await latest.value }
        let pending = try await request("/snapshot")
        XCTAssertTrue(store.isFetchingLatest)
        XCTAssertEqual(store.latestRevision, revision)
        pending.respond(snapshotBody(text: "Reconciled"))
        await latest.value
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Reconciled"])
        XCTAssertFalse(store.isFetchingLatest)
    }
    func testUserDragCancelsHeldLatestWithoutChangingReaderWindow() async throws {
        try store.transcript.replace(.init(messages: [.init(id: "old", role: "assistant", text: "Old", provisional: false)], before: nil, hasMore: false))
        store.isReadingHistory = true
        store.newActivity = true
        let revision = store.latestRevision
        let latest = Task { await store.latest() }
        addTeardownBlock { latest.cancel(); await latest.value }
        let pending = try await request("/snapshot")
        XCTAssertTrue(store.isFetchingLatest)
        store.userScrollBegan()
        XCTAssertFalse(store.isFetchingLatest)
        pending.respond(snapshotBody(text: "Must not pull the reader down"))
        await latest.value
        XCTAssertTrue(store.isReadingHistory)
        XCTAssertTrue(store.newActivity)
        XCTAssertEqual(store.latestRevision, revision)
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Old"])
    }
    func testLatestFailurePreservesRowsAndReadingIntent() async throws {
        try store.transcript.replace(.init(messages: [.init(id: "old", role: "assistant", text: "Old", provisional: false)], before: nil, hasMore: false))
        store.isReadingHistory = true
        store.newActivity = true
        let revision = store.latestRevision
        let latest = Task { await store.latest() }
        addTeardownBlock { latest.cancel(); await latest.value }
        let pending = try await request("/snapshot")
        pending.respond(["error": ["code": "unavailable", "message": "Snapshot unavailable"]], status: 503)
        await latest.value
        XCTAssertFalse(store.isFetchingLatest)
        XCTAssertTrue(store.isReadingHistory)
        XCTAssertTrue(store.newActivity)
        XCTAssertEqual(store.latestRevision, revision)
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Old"])
        XCTAssertNotNil(store.error)
    }
    func testTrimmedTailRequiresLatestFetchWithoutNewActivity() async throws {
        for page in 0..<5 {
            let rows = (0..<120).map { ChatMessage(id: "page-\(page)-\($0)", role: "assistant", text: "History", provisional: false) }
            if page == 0 { try store.transcript.replace(.init(messages: rows, before: "cursor", hasMore: true)) }
            else { try store.transcript.prepend(.init(messages: rows, before: "cursor", hasMore: true)) }
        }
        XCTAssertTrue(store.transcript.hasNewer)
        XCTAssertFalse(store.newActivity)
        let latest = Task { await store.latest() }
        addTeardownBlock { latest.cancel(); await latest.value }
        let pending = try await request("/snapshot")
        XCTAssertTrue(store.isFetchingLatest)
        pending.respond(snapshotBody(text: "Latest tail"))
        await latest.value
        XCTAssertFalse(store.transcript.hasNewer)
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Latest tail"])
    }
    func testLatestWaitsForNewWindowAndDiscardsOlderResponse() async throws {
        store.newActivity = true
        try store.transcript.replace(.init(messages: [.init(id: "old", role: "assistant", text: "Old", provisional: false)], before: "cursor", hasMore: true))
        let originalRevision = store.latestRevision
        let older = Task { await store.loadOlder() }
        addTeardownBlock { older.cancel(); _ = await older.value }
        let oldRequest = try await request("/history")
        let latest = Task { await store.latest() }
        addTeardownBlock { latest.cancel(); _ = await latest.value }
        let latestRequest = try await request("/snapshot")
        XCTAssertEqual(store.latestRevision, originalRevision)
        XCTAssertEqual(store.transcript.messages.first?.id, "old")
        latestRequest.respond(snapshotBody(text: "Latest"))
        await latest.value
        XCTAssertNotEqual(store.latestRevision, originalRevision)
        oldRequest.respond(["messages": [["id": "stale", "role": "assistant", "text": "Stale", "provisional": false]], "before": NSNull(), "has_more": false])
        await older.value
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Latest"])
        XCTAssertFalse(store.isReadingHistory)
    }
    func testNewOlderIntentCancelsPendingLatestJump() async throws {
        store.newActivity = true
        try store.transcript.replace(.init(messages: [.init(id: "old", role: "assistant", text: "Old", provisional: false)], before: "cursor", hasMore: true))
        let revision = store.latestRevision
        let latest = Task { await store.latest() }
        addTeardownBlock { latest.cancel(); _ = await latest.value }
        let latestRequest = try await request("/snapshot")
        let older = Task { await store.loadOlder() }
        addTeardownBlock { older.cancel(); _ = await older.value }
        let oldRequest = try await request("/history")
        oldRequest.respond(["messages": [["id": "earlier", "role": "assistant", "text": "Earlier", "provisional": false]], "before": NSNull(), "has_more": false])
        await older.value
        latestRequest.respond(snapshotBody(text: "Wrong window"))
        await latest.value
        XCTAssertEqual(store.latestRevision, revision)
        XCTAssertEqual(store.transcript.messages.map(\.text), ["Earlier", "Old"])
        XCTAssertTrue(store.isReadingHistory)
    }
    func testFailedConversationCreationKeepsDraftAndDoesNotDuplicatePendingRequest() async throws {
        store.draft = "Keep this thought"
        let create = Task { await store.newSession() }
        addTeardownBlock { create.cancel(); _ = await create.value }
        let pending = try await request("/sessions")
        XCTAssertTrue(store.isSending)
        let duplicate = await store.newSession()
        XCTAssertNil(duplicate)
        XCTAssertEqual(heldRequests().count, 1)
        pending.respond(["error": ["code": "unavailable", "message": "Creation unavailable"]], status: 503)
        let created = await create.value
        XCTAssertNil(created)
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.selectedSession?.id, "first")
        XCTAssertEqual(store.draft, "Keep this thought")
        XCTAssertNotNil(store.error)
    }
    func testCompletedImportStaysWithOriginalConversation() async throws {
        let context = try XCTUnwrap(store.beginAttachmentImport(name: "note.txt"))
        store.selectedSession = .init(id: "second", title: "Second", updatedAt: "", profile: "test")
        let payload = try payload()
        store.finishAttachmentImport(context, result: .success(payload))
        XCTAssertTrue(store.attachments.isEmpty)
        XCTAssertEqual(attachments.items(for: "first").first?.payload?.name, "note.txt")
        XCTAssertEqual(AttachmentDrafts(hostID: suite).items(for: "first").count, 1)
    }
    func testConversationSwitchDuringUploadNeverSendsToNewSession() async throws {
        let item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        attachments.set([item], for: "first")
        store.draft = "Read this"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); _ = await send.value }
        let upload = try await request("/attachments")
        store.selectedSession = .init(id: "second", title: "Second", updatedAt: "", profile: "test")
        upload.respond(["id": "ticket", "name": "note.txt", "media_type": "text/plain", "byte_count": 5, "status": "ready"])
        await send.value
        XCTAssertTrue(heldRequests().filter { $0.request.url?.path.hasSuffix("/commands") == true }.isEmpty)
        XCTAssertTrue(store.attachments.isEmpty)
        XCTAssertEqual(attachments.items(for: "first").first?.ticket?.id, "ticket")
    }
    func testStopDuringUploadRetainsTicketAndCancelsPendingSend() async throws {
        let item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        attachments.set([item], for: "first")
        store.draft = "A direction"
        store.runState = .working
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); _ = await send.value }
        let upload = try await request("/attachments")
        let stop = Task { await store.execute(.init(kind: "interrupt")) }
        addTeardownBlock { stop.cancel(); _ = await stop.value }
        let interrupt = try await request("/commands")
        XCTAssertEqual(interrupt.json["kind"] as? String, "interrupt")
        interrupt.respond(["operation_id": interrupt.json["operation_id"]!, "status": "accepted"])
        let stopped = await stop.value
        XCTAssertTrue(stopped)
        XCTAssertTrue(store.isSending)
        upload.respond(["id": "ticket", "name": "note.txt", "media_type": "text/plain", "byte_count": 5, "status": "ready"])
        await send.value
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.draft, "A direction")
        XCTAssertEqual(store.attachments.first?.ticket?.id, "ticket")
        XCTAssertEqual(heldRequests().filter { $0.request.url?.path.hasSuffix("/commands") == true }.count, 1)
    }
    func testExplicitRetryUsesNewUploadOperationAndUncertainCannotRetry() async throws {
        var item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        item.uploadError = "Rejected"
        attachments.set([item], for: "first")
        XCTAssertFalse(store.canSendDraft)
        store.retryAttachmentUpload(item)
        let retry = try XCTUnwrap(store.attachments.first)
        XCTAssertNotEqual(retry.uploadOperationID, item.uploadOperationID)
        XCTAssertTrue(store.canSendDraft)
        var uncertain = retry
        uncertain.uncertainUpload = true
        uncertain.uploadError = "Upload not confirmed"
        attachments.set([uncertain], for: "first")
        store.retryAttachmentUpload(uncertain)
        XCTAssertEqual(store.attachments.first?.uploadOperationID, uncertain.uploadOperationID)
        XCTAssertFalse(store.canSendDraft)
    }
    func testQueuedAttachmentReceiptClearsOnlySubmittedDraftItems() async throws {
        let first = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        attachments.set([first], for: "first")
        store.draft = "Read after this task"
        store.runState = .working
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); _ = await send.value }
        let upload = try await request("/attachments")
        upload.respond(["id": "ticket", "name": "note.txt", "media_type": "text/plain", "byte_count": 5, "status": "ready"])
        let command = try await request("/commands")
        XCTAssertEqual(command.json["attachment_ids"] as? [String], ["ticket"])
        let later = DraftAttachment(id: UUID(), name: "later.txt", state: .ready(try payload()))
        attachments.set(store.attachments + [later], for: "first")
        store.draft = "A later draft"
        command.respond(["operation_id": command.json["operation_id"]!, "status": "queued", "user_row_id": "queued-user"])
        await send.value
        XCTAssertEqual(store.draft, "A later draft")
        XCTAssertEqual(store.attachments.map(\.id), [later.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.payload!.fileURL.path))
        XCTAssertEqual(store.displayMessages.last?.id, "queued-user")
        XCTAssertEqual(store.displayMessages.last?.text, "Read after this task")
        XCTAssertEqual(store.displayMessages.last?.attachments?.map(\.id), ["ticket"])
    }
    func testRejectedUploadPreservesDraftAndFile() async throws {
        let item = DraftAttachment(id: UUID(), name: "note.txt", state: .ready(try payload()))
        attachments.set([item], for: "first")
        store.draft = "Read this"
        let send = Task { await store.send() }
        addTeardownBlock { send.cancel(); _ = await send.value }
        let upload = try await request("/attachments")
        upload.respond(["error": ["code": "unsupported_attachment", "message": "Unsupported file"]], status: 400)
        await send.value
        XCTAssertEqual(store.draft, "Read this")
        XCTAssertEqual(store.attachments.count, 1)
        XCTAssertFalse(store.attachments[0].uncertainUpload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.payload!.fileURL.path))
    }
    private func payload() throws -> AttachmentPayload {
        let url = attachments.directory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: url)
        return .init(fileURL: url, name: "note.txt", mediaType: "text/plain", byteCount: 5, previewURL: nil)
    }
    private func heldRequests(owner: String? = nil) -> [PolishHeldProtocol] {
        let prefix = "/\(owner ?? suite!)/"
        return PolishHeldProtocol.requests.filter { $0.request.url?.path.hasPrefix(prefix) == true }
    }
    private func request(_ suffix: String, index: Int = 0, owner: String? = nil) async throws -> PolishHeldProtocol {
        for _ in 0..<200 {
            let found = heldRequests(owner: owner).filter { $0.request.url?.path.hasSuffix(suffix) == true }
            if found.count > index { return found[index] }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Missing held request " + suffix)
        throw ClientError.invalidResponse
    }
    private func logRefreshTasks(_ phase: String, selected: PolishHeldProtocol) async {
        let tasks = await session.allTasks
        print("[PolishHeld] \(phase) suite=\(suite!) selected=\(selected.identity) url=\(selected.request.url!.absoluteString) stopped=\(selected.wasStopped)")
        print("[PolishHeld] tasks=\(tasks.map { "\($0.taskIdentifier):\($0.state.rawValue):\($0.originalRequest?.url?.absoluteString ?? "nil")" })")
        print("[PolishHeld] lifecycle=\(PolishHeldProtocol.lifecycle)")
    }
    private func snapshotBody(text: String) -> [String: Any] {
        ["session": ["id": "first", "title": "First", "updated_at": "", "profile": "test"],
         "page": ["messages": [["id": "latest", "role": "assistant", "text": text, "provisional": false]], "before": NSNull(), "has_more": false],
         "state": "working", "requests": [],
         "controls": ["model": "test", "provider": "test", "pending_model": NSNull(), "reasoning": "medium", "reasoning_levels": [], "models": [], "commands": []]]
    }
    private func connectionEvent(state: String) throws -> WireEvent {
        let data = try JSONSerialization.data(withJSONObject: ["type": "connection", "session_id": "first", "payload": ["state": state]])
        return try CompanionAPI.decoder.decode(WireEvent.self, from: data)
    }
    private func hostConnectionEvent(state: String, message: String?) throws -> WireEvent {
        var payload = ["state": state]
        if let message { payload["message"] = message }
        let data = try JSONSerialization.data(withJSONObject: ["type": "connection", "payload": payload])
        return try CompanionAPI.decoder.decode(WireEvent.self, from: data)
    }
    private func receiveSnapshot(messages: [[String: Any]], state: String) throws {
        var snapshot = snapshotBody(text: "")
        snapshot["page"] = ["messages": messages, "before": NSNull(), "has_more": false]
        snapshot["state"] = state
        let data = try JSONSerialization.data(withJSONObject: ["type": "snapshot", "session_id": "first", "payload": snapshot])
        try store.receive(CompanionAPI.decoder.decode(WireEvent.self, from: data))
    }
}

private final class PolishHeldProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [PolishHeldProtocol] = []
    nonisolated(unsafe) private static var events: [String] = []
    static var requests: [PolishHeldProtocol] { lock.withLock { held } }
    static var lifecycle: [String] { lock.withLock { events } }
    static func reset() { lock.withLock { held = []; events = ["reset \(Date.timeIntervalSinceReferenceDate)"] } }
    let identity = UUID().uuidString
    private(set) var json: [String: Any] = [:]
    private var stopped = false
    var wasStopped: Bool { Self.lock.withLock { stopped } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.withLock {
            Self.held.append(self)
            Self.events.append("start \(identity) \(Date.timeIntervalSinceReferenceDate) \(request.url!.absoluteString)")
        }
    }
    func respond(_ object: [String: Any], status: Int = 200) {
        Self.lock.withLock { Self.events.append("respond \(identity) \(Date.timeIntervalSinceReferenceDate)") }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
    override func stopLoading() {
        Self.lock.withLock {
            stopped = true
            Self.events.append("stop \(identity) \(Date.timeIntervalSinceReferenceDate)")
        }
    }
}
