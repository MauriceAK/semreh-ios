import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor @Observable
final class AppStore {
    var grant: DeviceGrant?
    var sessions: [ChatSession] = []
    var selectedSession: ChatSession? { didSet { selectionChanged(from: oldValue) } }
    var transcript = TranscriptWindow()
    var controls: AgentControls?
    var requests: [AgentRequest] = []
    var jobs: [FollowUpJob] = []
    var updates: [AgentUpdate] = []
    var preferences = DeliveryPreferences.initial
    var runState: RunState = .synchronizing
    var connection = "Connecting"
    var error: String?
    var notice: String?
    var draft = "" { didSet { persistDraft() } }
    var isPairing = false
    enum PendingAction { case creating, uploading, command(String) }
    var pendingAction: PendingAction?
    var isSending: Bool { pendingAction != nil }
    private var sendIntent = UUID()
    private var pendingInterrupt: String?
    var isStopping: Bool { pendingInterrupt != nil }
    var isWorking: Bool { runState == .working || runState == .waiting }
    var isLoadingHistory = false
    var isReadingHistory = false
    var newActivity = false
    var latestRevision = UUID()
    var uncertain: [PendingOperation] = []
    var confirmation: PendingModelConfirmation?
    var routedUpdateID: String?
    var notificationStatus = "Not enabled"
    var hostStatus: HostStatus?
    private(set) var fixture = false
    var attachmentDrafts = AttachmentDrafts(hostID: "unpaired")
    var attachments: [DraftAttachment] { attachmentDrafts.items(for: selectedSession?.id) }
    var hasDraftContent: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    var canSendDraft: Bool { hasDraftContent && attachments.allSatisfy { $0.payload != nil && !$0.uncertainUpload && $0.uploadError == nil } }
    private var conversationMemory: ConversationMemory?
    private var restoringConversation = false
    private var api: CompanionAPI?
    private var socket: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Never>?
    private var deltaTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingDeltas: [Delta] = []
    private var pendingDeltaBytes = 0
    private var journal = OperationJournal()
    private var historyIntent = UUID()
    private var selectionGeneration = UUID()
    private var hostGeneration = UUID()
    private var knownUpdateIDs = Set<String>()
    private var hasLoadedUpdates = false
    private var notificationToken: String?
    private var fixtureOldest = 9880
    private var fixtureTimer: Task<Void, Never>?
    #if DEBUG
    var fixtureHoldWork = false
    #endif

    var canCommand: Bool { connection == "Connected" }
    var currentUncertain: [PendingOperation] { uncertain.filter { $0.sessionID == selectedSession?.id } }
    var statusLabel: String {
        if connection != "Connected" { return connection }
        switch runState {
        case .idle: return "Ready"
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .synchronizing: return "Synchronizing"
        case .offline: return "Host offline"
        case .failed: return "Needs attention"
        }
    }
    init(api testAPI: CompanionAPI? = nil, journal testJournal: OperationJournal? = nil, memory testMemory: ConversationMemory? = nil) {
        if let testJournal { journal = testJournal }
        conversationMemory = testMemory
        if let testAPI { api = testAPI; uncertain = journal.pending; restoreConversation(); return }
        #if DEBUG
        fixture = ProcessInfo.processInfo.arguments.contains("--fixture")
        #endif
        if fixture {
            loadFixture()
            #if DEBUG
            FixtureControl.shared.connect(self)
            #endif
            return
        }
        grant = GrantVault.load()
        uncertain = journal.pending
        if let grant, let client = try? CompanionAPI(baseURL: validatedBaseURL(grant.baseURL), token: grant.token) {
            usePairedHost(grant, api: client)
        }
    }
    isolated deinit {
        for task in refreshTasks.values { task.cancel() }
        connectionTask?.cancel()
        deltaTask?.cancel()
        fixtureTimer?.cancel()
    }
    func usePairedHost(_ grant: DeviceGrant, api: CompanionAPI, memory: ConversationMemory? = nil) {
        refreshTask?.cancel()
        refreshTask = nil
        self.grant = grant
        self.api = api
        attachmentDrafts = AttachmentDrafts(hostID: grant.baseURL + "|" + grant.deviceID)
        hostGeneration = UUID()
        selectionGeneration = UUID()
        conversationMemory = memory ?? ConversationMemory(hostID: grant.baseURL + "|" + grant.deviceID)
        confirmation = nil
        restoreConversation()
    }
    private var commandContext: ConversationContext? {
        selectedSession.map { ConversationContext(sessionID: $0.id, hostGeneration: hostGeneration, selectionGeneration: selectionGeneration) }
    }
    @discardableResult
    func confirmModelChange(_ pending: PendingModelConfirmation) async -> Bool {
        guard pending.context == commandContext else {
            notice = "This model confirmation expired when the conversation or host changed. Choose the model again."
            return false
        }
        return await execute(.init(kind: "model", value: pending.details.value, provider: pending.details.provider, confirmed: true))
    }
    private func restoreConversation() {
        restoringConversation = true
        defer { restoringConversation = false }
        let args = ProcessInfo.processInfo.arguments
        let requested = args.firstIndex(of: "--session").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let id = requested ?? conversationMemory?.selectedID
        selectedSession = id.map { ChatSession(id: $0, title: "Conversation", updatedAt: "", profile: grant?.host.profile ?? "") }
        draft = conversationMemory?.draft(for: id) ?? ""
    }
    private func selectionChanged(from old: ChatSession?) {
        guard !restoringConversation, old?.id != selectedSession?.id else { return }
        confirmation = nil
        if old == nil, let id = selectedSession?.id { attachmentDrafts.moveNewDraft(to: id) }
        let newDraft = old == nil && !draft.isEmpty ? draft : conversationMemory?.draft(for: selectedSession?.id) ?? ""
        draft = newDraft
        conversationMemory?.select(selectedSession?.id)
    }
    private func persistDraft() {
        guard !restoringConversation, let conversationMemory else { return }
        if !conversationMemory.saveDraft(draft, for: selectedSession?.id) {
            notice = "This large draft cannot be restored after closing the app. Copy it before closing."
        }
    }
    func start() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--attachment-file"), args.indices.contains(index + 1) {
            await importFile(URL(fileURLWithPath: args[index + 1]))
        }
        #endif
        if fixture { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--invitation"), arguments.indices.contains(index + 1) {
            await pair(arguments[index + 1])
        } else if api != nil { connect() }
        await updateNotificationStatus()
    }
    func pair(_ invitationText: String) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            let invitation = try Invitation.parse(invitationText)
            let baseURL = try validatedBaseURL(invitation.url)
            let client = CompanionAPI(baseURL: baseURL, token: nil)
            struct PairBody: Encodable, Sendable { let code: String; let deviceName: String }
            let result: PairResult = try await client.mutate("v1/pair", body: PairBody(code: invitation.code, deviceName: UIDevice.current.name))
            guard result.version == 1 else { throw ClientError.invalidResponse }
            let newGrant = DeviceGrant(baseURL: invitation.url, deviceID: result.deviceId, token: result.token, host: result.host)
            try GrantVault.save(newGrant)
            usePairedHost(newGrant, api: CompanionAPI(baseURL: baseURL, token: result.token))
            error = nil
            connect()
        } catch { self.error = error.localizedDescription }
    }
    func connect() {
        guard !fixture, let api else { return }
        connectionTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        connectionTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self else { return }
                self.connection = "Synchronizing"
                do {
                    let socket = try api.webSocket()
                    self.socket = socket
                    socket.resume()
                    try await self.synchronize()
                    self.connection = "Connected"
                    delay = 1
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .data(let bytes): data = bytes
                        case .string(let string): data = Data(string.utf8)
                        @unknown default: continue
                        }
                        let decodeSpan = ChatPerformance.shared.begin(.socketDecode, count: data.count)
                        let event: WireEvent
                        do { event = try CompanionAPI.decoder.decode(WireEvent.self, from: data); ChatPerformance.shared.end(decodeSpan) }
                        catch { ChatPerformance.shared.end(decodeSpan, outcome: .failed); throw error }
                        try self.receive(event)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.flushDeltas()
                    self.connection = "Reconnecting"
                    self.requests = []
                    self.notice = error.localizedDescription
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 20)
                }
            }
        }
    }
    func background() {
        for task in refreshTasks.values { task.cancel() }
        refreshTask = nil
        if fixture { return }
        connectionTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        flushDeltas()
        connection = "Paused"
        requests = []
    }
    func waitForScheduledRefreshes() -> Task<Void, Never> {
        let tasks = Array(refreshTasks.values)
        return Task {
            for task in tasks { await task.value }
        }
    }
    func foreground() {
        attachmentDrafts.refreshExpiredTickets()
        if !fixture && api != nil { connect() }
    }
    private func synchronize() async throws {
        guard let api else { throw ClientError.notPaired }
        let status: HostStatus = try await api.get("v1/host")
        guard status.version == 1 else { throw ClientError.invalidResponse }
        hostStatus = status
        let list: SessionList = try await api.get("v1/sessions")
        sessions = list.sessions
        if let selectedSession, sessions.contains(where: { $0.id == selectedSession.id }) {
            try await refreshCurrent()
        } else {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--session"), args.indices.contains(index + 1) {
                selectedSession = sessions.first(where: { $0.id == args[index + 1] }) ?? ChatSession(id: args[index + 1], title: "Conversation", updatedAt: "", profile: grant?.host.profile ?? "")
            } else { selectedSession = sessions.first }
            if selectedSession != nil { try await refreshCurrent(forceHistory: true) }
        }
        let updateList: UpdateList = try await api.get("v1/updates")
        updates = Array(updateList.updates.prefix(200))
        knownUpdateIDs = Set(updates.map(\.id))
        hasLoadedUpdates = true
        preferences = try await api.get("v1/preferences")
        if let notificationToken { await registerPush(notificationToken) }
        error = nil
    }
    func select(_ session: ChatSession) async {
        beginSelection(session)
        if fixture { loadFixtureTranscript(); return }
        do { try await refreshCurrent(forceHistory: true) }
        catch { self.error = error.localizedDescription }
    }
    func openResultConversation(_ id: String) async throws {
        if fixture { await select(Self.fixtureSession); return }
        guard let api else { throw ClientError.notPaired }
        let host = hostGeneration
        let selection = selectionGeneration
        let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(id)/snapshot")
        guard host == hostGeneration, selection == selectionGeneration else { throw CancellationError() }
        guard snapshot.session.id == id else { throw ClientError.invalidResponse }
        var history = TranscriptWindow()
        try history.replace(snapshot.page)
        beginSelection(snapshot.session)
        transcript = history
        controls = snapshot.controls
        requests = snapshot.requests
        runState = snapshot.state
        if !sessions.contains(where: { $0.id == id }) { sessions.insert(snapshot.session, at: 0) }
    }
    private func beginSelection(_ session: ChatSession) {
        refreshTask?.cancel()
        refreshTask = nil
        selectedSession = session
        latestRevision = UUID()
        selectionGeneration = UUID()
        historyIntent = UUID()
        transcript = TranscriptWindow()
        requests = []
        controls = nil
        runState = .synchronizing
        isReadingHistory = false
        newActivity = false
        pendingDeltas.removeAll()
        pendingDeltaBytes = 0
    }
    private func scheduleRefresh(forceHistory: Bool = false) {
        refreshTask?.cancel()
        guard let api, let context = commandContext else { return }
        let intent = historyIntent
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.refreshTasks.removeValue(forKey: id) }
            do {
                try Task.checkCancellation()
                let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(context.sessionID)/snapshot")
                try Task.checkCancellation()
                guard let self, context == self.commandContext, intent == self.historyIntent else { return }
                try self.apply(snapshot, forceHistory: forceHistory)
            } catch {}
        }
        refreshTasks[id] = task
        refreshTask = task
    }
    func refreshCurrent(forceHistory: Bool = false) async throws {
        guard let api, let id = selectedSession?.id else { return }
        let generation = selectionGeneration
        let intent = historyIntent
        let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(id)/snapshot")
        guard generation == selectionGeneration, intent == historyIntent, selectedSession?.id == id else { return }
        try apply(snapshot, forceHistory: forceHistory)
    }
    private func apply(_ snapshot: SessionSnapshot, forceHistory: Bool = false) throws {
        selectedSession = snapshot.session
        controls = snapshot.controls
        requests = snapshot.requests
        runState = snapshot.state
        if forceHistory || !isReadingHistory {
            try transcript.replace(snapshot.page)
            newActivity = false
        } else { newActivity = true }
    }
    func latest() async {
        let intent = UUID()
        historyIntent = intent
        let generation = selectionGeneration
        if fixture { ChatPerformance.shared.mark(.latestRequested); loadFixtureTranscript(); isReadingHistory = false; latestRevision = UUID(); return }
        guard let api, let id = selectedSession?.id else { return }
        do {
            let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(id)/snapshot")
            guard generation == selectionGeneration, intent == historyIntent else { return }
            ChatPerformance.shared.mark(.latestRequested)
            try apply(snapshot, forceHistory: true)
            isReadingHistory = false
            latestRevision = UUID()
        } catch {
            guard generation == selectionGeneration, intent == historyIntent else { return }
            self.error = error.localizedDescription
        }
    }
    func loadOlder() async {
        guard !isLoadingHistory, transcript.hasMore, let id = selectedSession?.id else { return }
        let intent = UUID()
        historyIntent = intent
        isLoadingHistory = true
        isReadingHistory = true
        defer { isLoadingHistory = false }
        if fixture {
            let lower = max(0, fixtureOldest - 120)
            try? transcript.prepend(fixturePage(lower..<fixtureOldest))
            fixtureOldest = lower
            return
        }
        guard let api, let before = transcript.before else { return }
        let generation = selectionGeneration
        do {
            let page: HistoryPage = try await api.get("v1/sessions/\(id)/history", query: [.init(name: "before", value: before)])
            guard generation == selectionGeneration, intent == historyIntent else { return }
            try transcript.prepend(page)
        } catch {
            guard generation == selectionGeneration, intent == historyIntent else { return }
            self.error = error.localizedDescription
        }
    }
    @discardableResult
    func newSession(refresh: Bool = true) async -> String? {
        guard canCommand, !isSending else { return nil }
        if fixture { await select(Self.fixtureSession); return Self.fixtureSession.id }
        guard let api else { return nil }
        let host = hostGeneration
        let selection = selectionGeneration
        struct Body: Encodable, Sendable { let operationId = UUID().uuidString }
        pendingAction = .creating
        defer { pendingAction = nil }
        do {
            let session: ChatSession = try await api.mutate("v1/sessions", body: Body())
            guard host == hostGeneration else { return nil }
            sessions.insert(session, at: 0)
            guard selection == selectionGeneration else { return nil }
            beginSelection(session)
            if refresh { scheduleRefresh(forceHistory: true) }
            return session.id
        } catch {
            guard host == hostGeneration else { return nil }
            self.error = error.localizedDescription + " The creation may have completed. Refresh before creating another chat."
            return nil
        }
    }
    struct AttachmentImportContext {
        let drafts: AttachmentDrafts
        let sessionID: String?
        let id: UUID
    }
    func beginAttachmentImport(name: String) -> AttachmentImportContext? {
        if let rejection = attachmentDrafts.importRejection(for: selectedSession?.id) { error = rejection; return nil }
        guard attachments.count < AttachmentDrafts.maxCount else { error = "Attach up to 4 files per message."; return nil }
        let item = DraftAttachment(id: UUID(), name: name, state: .importing)
        attachmentDrafts.set(attachments + [item], for: selectedSession?.id)
        return .init(drafts: attachmentDrafts, sessionID: selectedSession?.id, id: item.id)
    }
    func finishAttachmentImport(_ context: AttachmentImportContext, result: Result<AttachmentPayload, Error>) {
        guard context.drafts.contains(context.id) else {
            if case .success(let payload) = result {
                try? FileManager.default.removeItem(at: payload.fileURL)
                if let preview = payload.previewURL { try? FileManager.default.removeItem(at: preview) }
            }
            return
        }
        context.drafts.update(context.id, sessionID: context.drafts.sessionID(for: context.id)) { item in
            switch result {
            case .success(let payload): item.name = payload.name; item.state = .ready(payload)
            case .failure(let error): item.state = .failed(error.localizedDescription)
            }
        }
    }
    func importFile(_ url: URL) async {
        guard let context = beginAttachmentImport(name: url.lastPathComponent) else { return }
        do { finishAttachmentImport(context, result: .success(try await AttachmentImport.file(url, directory: context.drafts.directory, id: context.id))) }
        catch { finishAttachmentImport(context, result: .failure(error)) }
    }
    func retryAttachmentUpload(_ item: DraftAttachment) {
        guard item.payload != nil, !item.uncertainUpload, item.uploadError != nil, !isSending else { return }
        attachmentDrafts.update(item.id, sessionID: selectedSession?.id) {
            $0.uploadOperationID = UUID().uuidString.lowercased()
            $0.uploadError = nil
            $0.ticket = nil
            $0.uploadedAt = nil
        }
    }
    func removeAttachment(_ item: DraftAttachment) {
        let sessionID = selectedSession?.id
        attachmentDrafts.remove([item.id], sessionID: sessionID)
        if let ticket = item.ticket, let api, let sessionID {
            Task {
                struct Body: Encodable, Sendable { let operationId = UUID().uuidString }
                struct Removed: Decodable, Sendable { let removed: Bool? }
                let _: Removed? = try? await api.mutate("v1/sessions/\(sessionID)/attachments/\(ticket.id)", method: "DELETE", body: Body())
            }
        }
    }
    func send() async {
        attachmentDrafts.refreshExpiredTickets()
        let submittedDraft = draft
        let originatingMemory = conversationMemory
        let originatingAttachments = attachmentDrafts
        let originatingHost = hostGeneration
        let text = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendDraft, !isSending, !isStopping else { return }
        let intent = UUID()
        sendIntent = intent
        if !attachments.isEmpty, text.hasPrefix("/") {
            error = "Send attachments with a message. Remove them before using a slash command."
            return
        }
        if selectedSession == nil { guard await newSession(refresh: false) != nil else { return } }
        guard let submittedSessionID = selectedSession?.id, canCommand, originatingHost == hostGeneration, intent == sendIntent else { return }
        let origin = commandContext
        let submittedItems = attachments
        guard submittedItems.compactMap(\.payload).reduce(0, { $0 + $1.byteCount }) <= AttachmentDrafts.maxTotalBytes else {
            error = "Attachments must total 16 MB or less per message."; return
        }
        var ticketIDs: [String] = []
        if !submittedItems.isEmpty {
            guard !fixture, let api else { error = "Attachment delivery requires a connected Hermes host."; return }
            pendingAction = .uploading
            for item in submittedItems {
                guard origin == commandContext, intent == sendIntent else { pendingAction = nil; return }
                if let ticket = item.ticket { ticketIDs.append(ticket.id); continue }
                guard let payload = item.payload else { pendingAction = nil; return }
                do {
                    struct Body: Encodable, Sendable {
                        let operationId: String
                        let name: String
                        let mediaType: String
                        let contentBase64: String
                    }
                    let content = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: payload.fileURL).base64EncodedString() }.value
                    guard origin == commandContext, intent == sendIntent else { pendingAction = nil; return }
                    let uploadedAt = Date()
                    let ticket: AttachmentTicket = try await api.mutate("v1/sessions/\(submittedSessionID)/attachments", body: Body(operationId: item.uploadOperationID, name: payload.name, mediaType: payload.mediaType, contentBase64: content))
                    guard ticket.status == "ready" else { throw ClientError.invalidResponse }
                    originatingAttachments.update(item.id, sessionID: submittedSessionID) { $0.ticket = ticket; $0.uploadedAt = uploadedAt; $0.uploadError = nil }
                    ticketIDs.append(ticket.id)
                } catch {
                    let definite = (error as? ClientError)?.isDefiniteRejection == true
                    originatingAttachments.update(item.id, sessionID: submittedSessionID) {
                        $0.uploadError = definite ? error.localizedDescription : "Upload was not confirmed. Remove this item and check the conversation before trying again."
                        $0.uncertainUpload = !definite
                    }
                    if origin == commandContext { self.error = error.localizedDescription }
                    pendingAction = nil
                    return
                }
            }
            pendingAction = nil
        }
        guard origin == commandContext, intent == sendIntent else { return }
        var command = AgentCommand(kind: "send", text: text)
        command.attachmentIds = ticketIDs.isEmpty ? nil : ticketIDs
        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if let name = parts.first, controls?.commands.contains(where: { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == name }) == true {
                command = AgentCommand(kind: "slash", name: String(name), arg: parts.count > 1 ? String(parts[1]) : "")
            }
        }
        if await execute(command) {
            originatingAttachments.remove(Set(submittedItems.map(\.id)), sessionID: submittedSessionID)
            if hostGeneration == originatingHost && selectedSession?.id == submittedSessionID {
                if draft == submittedDraft { draft = "" }
            } else if originatingMemory?.draft(for: submittedSessionID) == submittedDraft {
                originatingMemory?.saveDraft("", for: submittedSessionID)
            }
        }
    }
    @discardableResult
    func execute(_ command: AgentCommand) async -> Bool {
        guard canCommand, let id = selectedSession?.id else { return false }
        let interrupt = command.kind == "interrupt"
        guard interrupt ? !isStopping : (!isSending && !isStopping) else { return false }
        if interrupt { pendingInterrupt = command.operationId; sendIntent = UUID() }
        else { pendingAction = .command(command.kind) }
        defer {
            if interrupt { pendingInterrupt = nil }
            else { pendingAction = nil }
        }
        if fixture { fixtureCommand(command); return true }
        guard let api else { return false }
        let origin = commandContext
        journal.begin(command, sessionID: id)
        let receiptSpan = ChatPerformance.shared.begin(.sendReceipt)
        do {
            let receipt: CommandReceipt = try await api.mutate("v1/sessions/\(id)/commands", body: command)
            guard receipt.operationId.caseInsensitiveCompare(command.operationId) == .orderedSame else { throw ClientError.invalidResponse }
            ChatPerformance.shared.end(receiptSpan)
            receiveReceipt(receipt, origin: origin)
            let accepted = [.accepted, .queued, .steered, .redirected].contains(receipt.status)
            if accepted, origin == commandContext, command.kind == "send" { runState = requests.isEmpty ? .working : .waiting }
            if origin == commandContext { scheduleRefresh() }
            return accepted
        } catch {
            ChatPerformance.shared.end(receiptSpan, outcome: .failed)
            if (error as? ClientError)?.isDefiniteRejection == true {
                journal.resolve(command.operationId)
                uncertain = journal.pending
                self.error = error.localizedDescription
            } else {
                uncertain = journal.pending
                self.error = "The host did not confirm this action. It may have completed. Check the conversation before sending again."
            }
            return false
        }
    }
    func acknowledgeUncertain(_ operation: PendingOperation) {
        journal.resolve(operation.operationID)
        uncertain = journal.pending
    }
    private func receiveReceipt(_ receipt: CommandReceipt, origin: ConversationContext? = nil) {
        if receipt.status != .uncertain { journal.resolve(receipt.operationId) }
        uncertain = journal.pending
        notice = receipt.message
        if let details = receipt.confirmation, let origin {
            if origin == commandContext { confirmation = .init(details: details, context: origin) }
            else { notice = "The model change needs confirmation in its original conversation. Choose the model there again." }
        } else if origin != nil { confirmation = nil }
        if receipt.status == .uncertain { error = "Delivery is uncertain. Check Hermes before sending again." }
        else if receipt.status == .rejected && receipt.confirmation == nil { error = receipt.message ?? "Hermes rejected the action." }
    }
    func answer(_ request: AgentRequest, answer: String) async {
        guard requests.contains(where: { $0.id == request.id && $0.generation == request.generation }) else { return }
        _ = await execute(.init(kind: "answer", requestId: request.id, generation: request.generation, answer: answer))
    }
    func receive(_ event: WireEvent) throws {
        if case .update(let update) = event.payload {
            updates.removeAll { $0.id == update.id }
            updates.insert(update, at: 0)
            updates = Array(updates.prefix(200))
            if hasLoadedUpdates && knownUpdateIDs.insert(update.id).inserted { notify(update) }
            knownUpdateIDs.formIntersection(updates.map(\.id))
            return
        }
        if case .connection(let value) = event.payload {
            if let sessionID = event.sessionId {
                guard sessionID == selectedSession?.id else { return }
                guard let state = RunState(rawValue: value.state) else { throw ClientError.invalidResponse }
                runState = state
                if state == .offline || state == .synchronizing { requests = [] }
            } else {
                connection = value.state == "connected" ? "Connected" : "Synchronizing"
                if value.state != "connected" { requests = [] }
            }
            if let message = value.message { notice = message }
            return
        }
        guard event.sessionId == selectedSession?.id else { return }
        switch event.payload {
        case .snapshot(let value): flushDeltas(); try apply(value)
        case .delta(let delta):
            guard pendingDeltas.count < 1024, pendingDeltaBytes + delta.text.utf8.count < TranscriptWindow.maxBytes else {
                throw ClientError.payloadTooLarge
            }
            ChatPerformance.shared.mark(.deltaQueued, count: delta.text.utf8.count)
            pendingDeltas.append(delta)
            pendingDeltaBytes += delta.text.utf8.count
            runState = .working
            if deltaTask == nil {
                deltaTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(50))
                    self?.flushDeltas()
                }
            }
        case .requests(let value): requests = value; if !value.isEmpty { runState = .waiting }
        case .controls(let value): controls = value
        case .receipt(let value): receiveReceipt(value)
        default: break
        }
    }
    private func flushDeltas() {
        let span = ChatPerformance.shared.begin(.deltaFlush, count: pendingDeltas.count)
        defer { ChatPerformance.shared.end(span) }
        deltaTask?.cancel()
        deltaTask = nil
        do {
            for delta in pendingDeltas { try transcript.apply(delta) }
            if isReadingHistory { newActivity = true }
        } catch { self.error = error.localizedDescription }
        pendingDeltas.removeAll(keepingCapacity: true)
        pendingDeltaBytes = 0
    }
    func loadActivity() async {
        guard !fixture, let api else { return }
        do {
            let jobList: JobList = try await api.get("v1/jobs")
            jobs = jobList.jobs
            let updateList: UpdateList = try await api.get("v1/updates")
            updates = Array(updateList.updates.prefix(200))
        } catch { self.error = error.localizedDescription }
    }
    func createJob(name: String, instruction: String, schedule: String, notify: String) async -> Bool {
        guard !fixture, let api, let sessionId = selectedSession?.id else {
            if fixture { notice = "Fixture mode does not create Hermes schedules." }; return false
        }
        struct Body: Encodable, Sendable {
            let operationId = UUID().uuidString
            let sessionId: String; let name: String; let instruction: String; let schedule: String; let notify: String
        }
        do {
            let job: FollowUpJob = try await api.mutate("v1/jobs", body: Body(sessionId: sessionId, name: name, instruction: instruction, schedule: schedule, notify: notify))
            jobs.insert(job, at: 0)
            return true
        } catch { self.error = error.localizedDescription + " Check follow-ups before creating it again."; return false }
    }
    func toggleJob(_ job: FollowUpJob) async {
        guard !fixture, let api else { return }
        struct Body: Encodable, Sendable { let operationId = UUID().uuidString; let enabled: Bool }
        do {
            let updated: FollowUpJob = try await api.mutate("v1/jobs/\(job.id)", method: "PATCH", body: Body(enabled: !job.enabled))
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = updated }
        } catch { self.error = error.localizedDescription; await loadActivity() }
    }
    func updateDetail(_ id: String) async throws -> UpdateDetail {
        if fixture, let update = updates.first(where: { $0.id == id }) {
            return .init(update: update, text: "Controlled fixture result. A real result is read from Hermes.", resultSessionId: Self.fixtureSession.id)
        }
        guard let api else { throw ClientError.notPaired }
        return try await api.get("v1/updates/\(id)")
    }
    func savePreferences(_ value: DeliveryPreferences) async -> Bool {
        if fixture { preferences = value; return true }
        guard let api else { return false }
        do {
            preferences = try await api.mutate("v1/preferences", method: "PUT", body: value)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func disconnect() async {
        guard !fixture, let api else { return }
        struct Revoked: Decodable, Sendable { let revoked: Bool }
        do {
            let _: Revoked = try await api.perform(api.request("v1/device", method: "DELETE"))
            background()
            GrantVault.remove()
            grant = nil
            hostGeneration = UUID()
            confirmation = nil
            self.api = nil
            sessions = []; selectedSession = nil; transcript = TranscriptWindow()
        } catch { self.error = error.localizedDescription }
    }
    func enableNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            await updateNotificationStatus()
        } catch { self.error = error.localizedDescription }
    }
    func updateNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus == .authorized ? "Enabled on this iPhone" : "Not enabled on this iPhone"
    }
    func registerPush(_ token: String) async {
        notificationToken = token
        guard !fixture, let api else { return }
        struct Body: Encodable, Sendable { let pushToken: String; let environment: String }
        struct Result: Decodable, Sendable { let registered: Bool }
        do {
            let entitlementEnvironment = Bundle.main.object(forInfoDictionaryKey: "CompanionPushEnvironment") as? String
            let environment = entitlementEnvironment == "production" ? "production" : "sandbox"
            let _: Result = try await api.mutate("v1/device", method: "PATCH", body: Body(pushToken: token, environment: environment))
        } catch { notice = "Push registration is unavailable. In-app updates remain available." }
    }
    func routeNotification(updateID: String?, sessionID: String?) async {
        if !fixture, api != nil { try? await synchronize() }
        if let sessionID, let session = sessions.first(where: { $0.id == sessionID }) { await select(session) }
        if let updateID { routedUpdateID = updateID }
        else { try? await refreshCurrent() }
    }
    private func notify(_ update: AgentUpdate) {
        guard preferences.notificationsEnabled else { return }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: preferences.timeZone) ?? .current
        let minutes = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
        if let start = preferences.quietStart, let end = preferences.quietEnd {
            let quiet = start <= end ? (start..<end).contains(minutes) : minutes >= start || minutes < end
            if quiet { return }
        }
        let content = UNMutableNotificationContent()
        content.title = update.kind == "needs_you" ? "Hermes needs you" : "Hermes has an update"
        content.body = "Open Companion to see the details."
        content.userInfo = ["update_id": update.id, "session_id": update.sessionId ?? ""]
        UNUserNotificationCenter.current().add(.init(identifier: update.id, content: content, trigger: nil))
    }
}

extension AppStore {
    static let fixtureSession = ChatSession(id: "fixture-history", title: "A thoughtful workspace", updatedAt: "2026-10-19T00:00:00Z", profile: "UI test fixture")
    private func fixturePage(_ range: Range<Int>) -> HistoryPage {
        let messages = range.map { index in
            ChatMessage(id: "fixture-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant", text: index == 9999 ? "I’ve organized the next steps. We can explore an idea, work through code, or keep an eye on something important.\n\nYour agent stays on your own computer." : "Message \(index + 1). " + (index.isMultiple(of: 13) ? "A longer note with enough detail to read while the conversation continues.\n\n```swift\nlet nextStep = idea.refined()\n```\nThe context remains in Hermes." : "A small step toward a useful result."), provisional: false)
        }
        return .init(messages: messages, before: range.lowerBound > 0 ? String(range.lowerBound) : nil, hasMore: range.lowerBound > 0)
    }
    private func loadFixture() {
        attachmentDrafts = AttachmentDrafts(hostID: "ui-fixture")
        attachmentDrafts.set([], for: Self.fixtureSession.id)
        grant = .init(baseURL: "http://127.0.0.1", deviceID: "fixture", token: "fixture-not-a-credential", host: .init(name: "UI fixture", profile: "Isolated fixture"))
        sessions = [Self.fixtureSession]
        selectedSession = Self.fixtureSession
        connection = "Connected"
        loadFixtureTranscript()
        controls = .init(model: "fixture-model", provider: "fixture", pendingModel: nil, reasoning: "medium", reasoningLevels: ["low", "medium", "high"], models: [.init(id: "fixture-model", provider: "fixture", label: "Fixture model", reasoning: true), .init(id: "fixture-other", provider: "fixture", label: "Another fixture model", reasoning: true)], commands: [.init(name: "model", description: "Choose a model"), .init(name: "reasoning", description: "Change reasoning"), .init(name: "status", description: "Show status")])
        if ProcessInfo.processInfo.arguments.contains("--fixture-approval") {
            requests = [.init(id: "approval-1", generation: "generation-1", kind: "approval", title: "Review this action", description: "The fixture agent wants to publish a draft. This controlled fixture performs no external action.", choices: [.init(id: "allow", label: "Approve once"), .init(id: "deny", label: "Decline")], allowsText: false)]
            runState = .waiting
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-cancel-request") {
            fixtureTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(9))
                self?.requests = []
                self?.runState = .idle
                self?.notice = "Fixture request canceled on the host."
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-reconnect") {
            fixtureTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.connection = "Reconnecting"
                self?.requests = []
                try? await Task.sleep(for: .seconds(4))
                self?.connection = "Connected"
                self?.notice = "Fixture connection restored. No command was replayed."
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-no-push") { hostStatus = .init(version: 1, capabilities: .init(notifications: false)) }
        if ProcessInfo.processInfo.arguments.contains("--fixture-working") { runState = .working }
        if ProcessInfo.processInfo.arguments.contains("--fixture-multiline") { draft = "Help me refine this idea.\nKeep the important details.\nShow me the next useful step." }
        if ProcessInfo.processInfo.arguments.contains("--fixture-empty") { transcript = TranscriptWindow() }
        if ProcessInfo.processInfo.arguments.contains("--fixture-attachment-importing") {
            attachmentDrafts.set([.init(id: UUID(), name: "Photo", state: .importing)], for: selectedSession?.id)
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-attachment-failed") {
            attachmentDrafts.set([.init(id: UUID(), name: "Large document.pdf", state: .failed("Each file must be 5 MB or smaller."))], for: selectedSession?.id)
        }
        updates = [.init(id: "fixture-update", kind: "result", title: "A useful change", summary: "A completed follow-up appears here with its original result.", createdAt: "2026-10-19T00:00:00Z", sessionId: Self.fixtureSession.id, jobId: nil, resultSessionId: Self.fixtureSession.id)]
    }
    private func loadFixtureTranscript() {
        fixtureOldest = 9880
        if ProcessInfo.processInfo.arguments.contains("--fixture-muse") {
            let conversation: [(String, String)] = [
                ("assistant", "The project is ready for a focused review. I’ve kept your decisions together so we can pick up where we left off.\n\nThe next step is to check the experience on a real conversation, including the small details that make it comfortable to use."),
                ("user", "What should we look at first?"),
                ("assistant", "Start with the conversation itself. The message you’re reading should stay in place while new text arrives, and your draft should stay intact when you switch tasks.\n\nThen check the controls. You should be able to send a message, add a picture, or stop the agent without hunting for the right button."),
                ("user", "Can you make a short checklist?"),
                ("assistant", "## A useful first pass\n\n- **Read comfortably:** keep the conversation visible behind the controls.\n- **Stay in control:** preserve a draft while the agent works.\n- **Show the result:** present the actual answer with clear formatting.\n\n### Before sharing\n\n1. Try a long conversation.\n2. Scroll back while a reply streams.\n3. Return to the newest message.\n\nA small example:\n\n```swift\nlet message = \"A useful next step\"\nprint(message)\n```\n\nKeep **bold**, *emphasis*, and [links](https://example.com) readable. Literal code such as `<untrusted_tool_result>` and `{\"ok\": true}` remains visible when it is part of the answer."),
                ("user", "That sounds right. Keep going."),
                ("assistant", "I’ll work through those checks and keep the results in this conversation.\n\nYou can keep writing while I work. If something needs your decision, the question will appear here with the relevant details.")
            ]
            let messages = conversation.enumerated().map { index, row in
                ChatMessage(id: "muse-\(index)", role: row.0, text: row.1, provisional: false)
            }
            try? transcript.replace(.init(messages: messages, before: nil, hasMore: false))
        } else if ProcessInfo.processInfo.arguments.contains("--fixture-long-code") {
            let code = (1...200).map { "let line\($0) = \($0) // a readable source line" }.joined(separator: "\n")
            try? transcript.replace(.init(messages: [.init(id: "fixture-code", role: "assistant", text: "A code example.\n\n```swift\n" + code + "\n```\nCode ends here.", provisional: false)], before: nil, hasMore: false))
        } else { try? transcript.replace(fixturePage(9880..<10000)) }
        runState = .idle
        newActivity = false
    }
    private func fixtureCommand(_ command: AgentCommand) {
        if command.kind == "answer" { requests = []; runState = .idle; notice = "Fixture request resolved." }
        if command.kind == "interrupt" { fixtureTimer?.cancel(); runState = .idle }
        if command.kind == "model" || command.kind == "reasoning", let old = controls {
            controls = .init(model: command.kind == "model" ? command.value! : old.model, provider: "fixture", pendingModel: nil, reasoning: command.kind == "reasoning" ? command.value! : old.reasoning, reasoningLevels: old.reasoningLevels, models: old.models, commands: old.commands)
        }
        if command.kind == "send" {
            runState = .working
            fixtureTimer?.cancel()
            fixtureTimer = Task { [weak self] in
                for index in 0..<80 {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    try? self?.transcript.apply(.init(id: "fixture-stream", text: index == 0 ? "Controlled streaming fixture. " : "A new thought arrives. ", replace: index == 0))
                }
                #if DEBUG
                if self?.fixtureHoldWork == true { return }
                #endif
                self?.runState = .idle
            }
        }
    }
}
