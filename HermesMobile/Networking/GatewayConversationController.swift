import Foundation
import Observation

/// One conversation on the active server's shared socket. The view model owns
/// rendering/cache; this owner owns identity and RPC delivery, never a socket.
@MainActor
@Observable
final class GatewayConversationController {
    enum RunState: Equatable { case idle, submitting, running, stopping, deliveryUnknown }
    enum SteerOutcome: String { case accepted, queued, rejected }
    typealias TranscriptLoader = @MainActor (String, String, Int, Int) async throws -> DirectHermesTranscriptPage

    private(set) var binding: GatewaySessionBinding?
    private(set) var storedID: String?
    private(set) var runState: RunState = .idle
    let profile: String
    var onBinding: ((GatewaySessionBinding) -> Void)?
    var onCanonicalID: ((String) -> Void)?
    var onEvent: ((HermesGatewayEvent) -> Void)?
    var onTranscript: ((DirectHermesTranscriptPage, Bool) -> Void)?
    var onResume: ((JSONValue?) -> Void)?
    var onError: ((Error) -> Void)?
    var isVisible = false
    var isEditing = false {
        didSet { if !isEditing, transcriptDirty { scheduleIdleRefresh() } }
    }

    @ObservationIgnored private let runtime: HermesServerRuntime
    @ObservationIgnored private let loadTranscript: TranscriptLoader
    @ObservationIgnored private var observerID: UUID?
    @ObservationIgnored private var attachmentTask: Task<Void, Error>?
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var idleRefreshTask: Task<Void, Never>?
    private var lifecycle = 0
    private var disposed = false
    private var didDispose = false
    private var hasSubmittedPrompt: Bool
    private var transcriptDirty = false
    private var terminalReceipt: String?
    private var promptInFlight = false
    private var bindingEpoch = 0
    private var turnEpoch = 0
    private var durableRowConfirmed: Bool

    init(runtime: HermesServerRuntime, storedID: String?, profile: String = "default", loadTranscript: @escaping TranscriptLoader) {
        self.runtime = runtime
        self.storedID = storedID
        let normalizedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profile = normalizedProfile.isEmpty ? "default" : normalizedProfile
        self.loadTranscript = loadTranscript
        hasSubmittedPrompt = storedID != nil
        durableRowConfirmed = storedID != nil
        observerID = runtime.observe(event: { [weak self] event in
            self?.receive(event)
        }, recover: { [weak self] transport in
            guard let self, !self.disposed else { return }
            // Fresh, unsent runtime sessions have no durable row to resume.
            self.invalidateBinding()
            if self.hasSubmittedPrompt, self.storedID != nil {
                try await self.resume(using: transport)
            }
        })
    }

    convenience init(runtime: HermesServerRuntime, client: APIClient, storedID: String?, profile: String = "default") {
        self.init(runtime: runtime, storedID: storedID, profile: profile) { id, profile, limit, offset in
            try await client.directSessionMessages(sessionID: id, profile: profile, limit: limit, offset: offset)
        }
    }

    deinit { attachmentTask?.cancel(); reconciliationTask?.cancel(); idleRefreshTask?.cancel() }

    /// Opening a local draft does not create a backend session.
    func open() async throws {
        guard !disposed else { throw DirectSessionError.stopped }
        guard storedID != nil, hasSubmittedPrompt else { return }
        try await ensureBinding(create: [:])
    }

    /// Creation settings are per draft, not mutations of server configuration.
    /// A lost prompt acknowledgement is never automatically replayed.
    func submit(_ text: String, create: [String: JSONValue] = [:]) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DirectSessionError.invalidResponse }
        guard runState == .idle, !promptInFlight else { throw DirectSessionError.ambiguousPrompt }
        promptInFlight = true
        defer { promptInFlight = false }
        turnEpoch &+= 1
        reconciliationTask?.cancel()
        idleRefreshTask?.cancel()
        runState = .submitting
        do { try await ensureBinding(create: create) }
        catch { runState = .idle; throw error }
        guard binding != nil else { runState = .idle; throw DirectSessionError.invalidBinding }
        let generation = lifecycle
        terminalReceipt = nil
        hasSubmittedPrompt = true
        do {
            let result = try await runtime.request("prompt.submit", parameters: {
                guard !self.disposed, let binding = self.binding else { throw DirectSessionError.invalidBinding }
                return ["session_id": .string(binding.runtimeID), "profile": .string(self.profile), "text": .string(text)]
            })
            try checkLifecycle(generation)
            guard result?.gatewayFields["status"]?.gatewayString == "streaming" else { throw DirectSessionError.invalidResponse }
            // A very short turn can complete before the RPC continuation runs.
            if runState == .submitting { runState = .running }
        } catch {
            guard !disposed, generation == lifecycle else { throw error }
            if case HermesGatewayError.server = error {
                runState = .idle
                // A definite RPC rejection can precede first-row persistence.
                // Only a canonical, structured not-found response proves this
                // runtime is still an abandonable draft. Connectivity does not.
                if !durableRowConfirmed {
                    do { try await refresh() }
                    catch let probeError as APIError {
                        if case .http(404, let body) = probeError,
                           let data = body?.data(using: .utf8),
                           let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
                           payload.gatewayFields["detail"] == .string("Session not found") {
                            hasSubmittedPrompt = false
                        }
                    } catch { /* Remain conservative when persistence is unknown. */ }
                }
            } else if terminalReceipt == nil {
                runState = .deliveryUnknown
            }
            throw error
        }
    }

    func steer(_ text: String) async throws -> SteerOutcome {
        guard !disposed, binding != nil, runState == .running,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DirectSessionError.invalidResponse }
        let result = try await runtime.request("session.steer", parameters: {
            guard !self.disposed, let binding = self.binding, self.runState == .running else { throw DirectSessionError.staleOperation }
            return ["session_id": .string(binding.runtimeID), "profile": .string(self.profile), "text": .string(text)]
        })
        guard let status = result?.gatewayFields["status"]?.gatewayString,
              let outcome = SteerOutcome(rawValue: status) else { throw DirectSessionError.invalidResponse }
        // Rejected steer never becomes interrupt + prompt.submit.
        return outcome
    }

    /// The interrupt acknowledgement is not evidence the server has stopped.
    /// Confirm both a matching terminal event and the pinned status contract.
    func interrupt() async throws {
        // An unconfirmed interrupt must remain retryable, without reopening
        // ordinary send/steer or treating a lost acknowledgement as success.
        guard !disposed, let binding, runState == .running || runState == .stopping else { throw DirectSessionError.invalidResponse }
        let generation = lifecycle
        runState = .stopping
        let result = try await runtime.request("session.interrupt", parameters: {
            guard self.binding == binding, !self.disposed else { throw DirectSessionError.stopUnconfirmed }
            return self.rpcParams(binding)
        })
        guard result?.gatewayFields["status"]?.gatewayString == "interrupted" else { throw DirectSessionError.invalidResponse }
        for _ in 0..<40 {
            try checkLifecycle(generation)
            let status = try await runtime.request("session.status", parameters: {
                guard self.binding == binding, !self.disposed else { throw DirectSessionError.stopUnconfirmed }
                return self.rpcParams(binding)
            })
            let stopped = status?.gatewayFields["output"]?.gatewayString?
                .components(separatedBy: .newlines).contains("Agent Running: No") == true
            if stopped, terminalReceipt != nil { runState = .idle; return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DirectSessionError.stopUnconfirmed
    }

    func refresh(limit: Int = 120, offset: Int = 0) async throws {
        guard !disposed, let storedID, hasSubmittedPrompt else { return }
        let generation = lifecycle
        let epoch = bindingEpoch
        let turn = turnEpoch
        let page = try await loadTranscript(storedID, profile, limit, offset)
        try checkLifecycle(generation)
        guard epoch == bindingEpoch, turn == turnEpoch, storedID == self.storedID else { throw DirectSessionError.staleOperation }
        let canonical = page.sessionID
        guard !canonical.isEmpty else { throw DirectSessionError.invalidBinding }
        durableRowConfirmed = true
        if canonical != storedID {
            self.storedID = canonical
            // A REST continuation must never be paired with the ancestor's live ID.
            invalidateBinding()
            onCanonicalID?(canonical)
        }
        transcriptDirty = false
        onTranscript?(page, offset > 0)
    }

    /// Synchronous invalidation closes the await gap on account switches. RPC
    /// parameter closures and pending attachments fail before async cleanup runs.
    func invalidate() {
        guard !disposed else { return }
        disposed = true
        lifecycle &+= 1
        attachmentTask?.cancel()
        reconciliationTask?.cancel()
        idleRefreshTask?.cancel()
        if let observerID { runtime.removeObserver(observerID) }
    }

    func dispose() async throws {
        guard !didDispose else { return }
        didDispose = true
        invalidate()
        // Never close a persisted conversation or interrupt a background run.
        let abandonedBinding = binding
        binding = nil
        if !hasSubmittedPrompt, let abandonedBinding {
            // Surface cleanup failure; never reconnect and silently send a
            // previous connection's unpersisted runtime ID as a successful close.
            let connection = runtime.connectionGeneration
            guard runtime.state == .ready else { throw DirectSessionError.draftCleanupUnconfirmed }
            _ = try await runtime.request("session.close", parameters: {
                guard self.runtime.connectionGeneration == connection else { throw DirectSessionError.draftCleanupUnconfirmed }
                return self.rpcParams(abandonedBinding)
            })
        }
    }

    private func ensureBinding(create: [String: JSONValue]) async throws {
        if let attachmentTask { return try await attachmentTask.value }
        let generation = lifecycle
        let task = Task { [weak self] in
            guard let self else { throw DirectSessionError.stopped }
            try await self.runtime.connect()
            try self.checkLifecycle(generation)
            if self.binding != nil { return }
            try await self.runtime.withSessionEventsPaused {
                if self.hasSubmittedPrompt, self.storedID != nil {
                    // Recovery uses the raw transport under the server barrier;
                    // ordinary attachment uses the runtime's generation guard.
                    let result = try await self.runtime.request("session.resume", params: self.resumeParams())
                    try self.checkLifecycle(generation)
                    try await self.applyResume(result)
                } else {
                    var params = create.filter { ["cwd", "model", "provider", "reasoning_effort", "fast"].contains($0.key) }
                    params["profile"] = .string(self.profile)
                    params["close_on_disconnect"] = .bool(false)
                    let result = try await self.runtime.request("session.create", params: params)
                    try self.checkLifecycle(generation)
                    try self.adopt(GatewaySessionBinding.resolve(result, profile: self.profile))
                }
            }
        }
        attachmentTask = task
        defer { if lifecycle == generation { attachmentTask = nil } }
        try await task.value
    }

    private func resume(using transport: any HermesGatewayTransport) async throws {
        let generation = lifecycle
        let result = try await transport.request(method: "session.resume", params: .object(resumeParams()), timeout: nil)
        try checkLifecycle(generation)
        try await applyResume(result)
    }

    private func applyResume(_ result: JSONValue?) async throws {
        do {
            try adopt(GatewaySessionBinding.resolve(result, requestedID: storedID, profile: profile))
        } catch DirectSessionError.conflictingDurableIDs {
            invalidateBinding()
            try await refresh()
            // Canonical resolution has succeeded, but the conflicting runtime
            // is not trusted. A later explicit attachment must resume the tip.
            throw DirectSessionError.conflictingDurableIDs
        }
        try await refresh()
        guard binding != nil else { throw DirectSessionError.staleOperation }
        if result?.gatewayFields["running"] == .bool(true) { runState = .running }
        else if runState != .deliveryUnknown, !promptInFlight { runState = .idle }
        onResume?(result)
    }

    private func adopt(_ binding: GatewaySessionBinding) throws {
        guard !disposed else { throw DirectSessionError.stopped }
        self.binding = binding
        bindingEpoch &+= 1
        storedID = binding.storedID
        onCanonicalID?(binding.storedID)
        onBinding?(binding)
    }

    private func invalidateBinding() {
        bindingEpoch &+= 1
        binding = nil
    }

    private func resumeParams() -> [String: JSONValue] {
        ["session_id": .string(storedID ?? ""), "profile": .string(profile), "omit_messages": .bool(true), "defer_history": .bool(true)]
    }

    private func rpcParams(_ binding: GatewaySessionBinding) -> [String: JSONValue] {
        ["session_id": .string(binding.runtimeID), "profile": .string(profile)]
    }

    private func checkLifecycle(_ generation: Int) throws {
        guard !disposed, generation == lifecycle else { throw DirectSessionError.staleOperation }
        try Task.checkCancellation()
    }

    private func receive(_ event: HermesGatewayEvent) {
        guard !disposed else { return }
        if event.method == "local", event.type == "transport.closed" {
            if runState != .idle { runState = .deliveryUnknown }
            return
        }
        if event.type == "sessions.changed" {
            transcriptDirty = true
            scheduleIdleRefresh()
            return
        }
        guard let binding, event.sessionID == binding.runtimeID else { return }
        switch event.type {
        case "message.start":
            turnEpoch &+= 1
            terminalReceipt = nil
            runState = .running
            idleRefreshTask?.cancel()
            reconciliationTask?.cancel()
        case "error":
            // These exact pinned pre-agent cancellation events are terminal;
            // other `error` notifications are not assumed to end the turn.
            let message = event.payload?.gatewayFields["message"]?.gatewayString
            if message == "Turn cancelled before the agent was ready" || message == "Session no longer running before the agent was ready" {
                terminalReceipt = "\(event.connectionGeneration ?? -1):\(event.sequence ?? -1)"
                if runState != .stopping { runState = .idle }
            }
        case "message.complete":
            let receipt = "\(event.connectionGeneration ?? -1):\(event.sequence ?? -1)"
            guard terminalReceipt != receipt else { return }
            terminalReceipt = receipt
            if runState != .stopping { runState = .idle }
            onEvent?(event)
            reconciliationTask?.cancel()
            reconciliationTask = Task { [weak self] in
                do { try await self?.refresh() }
                catch { if !Task.isCancelled { self?.onError?(error) } }
            }
            return
        default: break
        }
        onEvent?(event)
    }

    private func scheduleIdleRefresh() {
        guard isVisible, !isEditing, runState == .idle else { return }
        idleRefreshTask?.cancel()
        idleRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self, self.isVisible, !self.isEditing, self.runState == .idle else { return }
                try await self.refresh()
            } catch { if !Task.isCancelled { self?.onError?(error) } }
        }
    }
}
