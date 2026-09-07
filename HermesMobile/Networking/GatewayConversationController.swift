import Foundation
import Observation

/// One conversation on the active server's shared socket. The view model owns
/// rendering/cache; this owner owns identity and RPC delivery, never a socket.
@MainActor
@Observable
final class GatewayConversationController {
    enum RunState: Equatable { case idle, submitting, running, stopping, deliveryUnknown }
    enum SteerOutcome: String { case accepted, queued, rejected }
    struct ReasoningConfiguration: Equatable, Sendable {
        let effort: String
        let deferred: Bool
        let supportsSessionChanges: Bool
    }

    private struct ReasoningCapability {
        let binding: GatewaySessionBinding
        let bindingEpoch: Int
        let connectionGeneration: Int
        let lifecycle: Int
        let extendedContract: Bool
        let configuration: ReasoningConfiguration
    }

    private static let reasoningEfforts: Set<String> = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
    ]
    private static let reasoningDisplays: Set<String> = ["show", "hide"]
    typealias TranscriptLoader = @MainActor (String, String, Int, Int) async throws -> DirectHermesTranscriptPage

    private(set) var binding: GatewaySessionBinding?
    private(set) var storedID: String?
    private(set) var runState: RunState = .idle
    /// A dispatched prompt whose outcome is not proven must remain a hard
    /// barrier even if a concurrent/queued terminal event temporarily makes
    /// `runState` idle. Canonical recovery or controller replacement owns the
    /// eventual resolution; this controller never clears it from a generic
    /// refresh or status response.
    private(set) var hasAmbiguousPromptDelivery = false
    private(set) var pendingReasoningEffort: String?
    /// One renderer-facing blocking prompt. It is transient and always scoped
    /// to the exact server/runtime/connection/request identity below.
    private(set) var pendingBlockingPrompt: GatewayBlockingPrompt?
    let profile: String
    var onBinding: ((GatewaySessionBinding) -> Void)?
    var onCanonicalID: ((String) -> Void)?
    var onEvent: ((HermesGatewayEvent) -> Void)?
    var onTranscript: ((DirectHermesTranscriptPage, Bool) -> Void)?
    var onResume: ((JSONValue?) -> Void)?
    var onReasoningConfiguration: ((ReasoningConfiguration) -> Void)?
    var onError: ((Error) -> Void)?
    var isVisible = false
    var isEditing = false {
        didSet { if !isEditing, transcriptDirty { scheduleIdleRefresh() } }
    }

    @ObservationIgnored private let runtime: HermesServerRuntime
    @ObservationIgnored private let loadTranscript: TranscriptLoader
    @ObservationIgnored private var observerID: UUID?
    @ObservationIgnored private var attachmentTask: Task<Void, Error>?
    @ObservationIgnored private var attachmentStageInFlight = false
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
    private var latestReadGeneration = 0
    @ObservationIgnored private var reasoningMutationCount = 0
    @ObservationIgnored private var reasoningMutationTail: Task<Void, Never>?
    @ObservationIgnored private var reasoningRevision = 0
    @ObservationIgnored private var ambiguousReasoningEffort: String?
    private enum BlockingClearReason: Equatable { case terminal, expiry }
    private var blockingClear: (identity: GatewayBlockingPromptIdentity, reason: BlockingClearReason)?
    private var blockingResponseInFlight = false

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

    /// Stages one direct attachment on this conversation's already-owned
    /// runtime. The source bytes are encoded off-main by
    /// `DirectGatewayAttachment.rpcParameters()`; this method only adds the
    /// runtime binding fields and validates that the same origin, binding,
    /// lifecycle, and socket generation survive the request.
    ///
    /// A failed request is never retried here. Validation failures proven to
    /// happen before the gateway can queue the attachment are distinct from
    /// failures whose server-side effect is unknown.
    func stageAttachment(
        _ pending: DirectPendingAttachment,
        create: [String: JSONValue] = [:]
    ) async throws -> DirectGatewayAttachmentStageResult {
        let kind = pending.source.kind
        switch pending.stageState {
        case .pending:
            break
        case .confirmed:
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .alreadyStaged
            )
        case .unknown(let scope):
            throw DirectGatewayAttachmentStageError.unknown(
                kind: kind,
                scope: scope,
                reason: .priorAttemptUnknown
            )
        }

        guard !disposed else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .staleBeforeDispatch
            )
        }
        guard !hasAmbiguousPromptDelivery else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .ambiguousPromptDelivery
            )
        }
        guard !attachmentStageInFlight,
              !promptInFlight,
              runState == .idle else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .controllerBusy
            )
        }

        attachmentStageInFlight = true
        defer { attachmentStageInFlight = false }

        let operationLifecycle = lifecycle
        do {
            // A local draft creates its one runtime session here. This shares
            // the controller's existing binding singleflight; it never opens
            // a second socket or a second reconnect loop.
            try await ensureBinding(create: create)
        } catch is CancellationError {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .cancelledBeforeDispatch
            )
        } catch {
            // The attachment request has not been dispatched yet. The shared
            // session-create/bind failure is therefore not an attachment stage
            // with an unknown queue side effect.
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .staleBeforeDispatch
            )
        }

        guard !disposed,
              lifecycle == operationLifecycle,
              let capturedBinding = binding,
              capturedBinding.profile == profile,
              runtime.state == .ready else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .staleBeforeDispatch
            )
        }

        // Attachments belong to the idle turn that was current after binding.
        // A prompt/event may advance this epoch while bytes are prepared; do
        // not dispatch into a newer turn or reuse an ambiguous queue result.
        let operationTurn = turnEpoch
        guard runState == .idle else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .controllerBusy
            )
        }

        let capturedGeneration = runtime.connectionGeneration
        let capturedOrigin = runtime.origin
        let scope = DirectPendingAttachmentStageScope(
            binding: capturedBinding,
            connectionGeneration: capturedGeneration,
            origin: capturedOrigin,
            turnEpoch: operationTurn
        )

        let attachmentFields: [String: JSONValue]
        do {
            attachmentFields = try await pending.source.rpcParameters()
        } catch is CancellationError {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .cancelledBeforeDispatch
            )
        } catch let error as DirectGatewayAttachmentError {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .sourcePreparation(error)
            )
        } catch {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .sourcePreparation(.malformed)
            )
        }

        guard !disposed,
              lifecycle == operationLifecycle,
              turnEpoch == operationTurn,
              runState == .idle,
              binding == capturedBinding,
              runtime.origin == capturedOrigin,
              runtime.connectionGeneration == capturedGeneration,
              runtime.state == .ready else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .staleBeforeDispatch
            )
        }

        let method: String
        switch kind {
        case .image:
            method = "image.attach_bytes"
        case .file:
            method = "file.attach"
        case .pdf:
            method = "pdf.attach"
        }

        var requestFields = attachmentFields
        requestFields["session_id"] = .string(capturedBinding.runtimeID)
        requestFields["profile"] = .string(profile)
        // Stock PDF rendering may invoke pdftoppm and is allowed the pinned
        // 120-second server-side window plus a small transport margin.
        let requestTimeout: Duration? = kind == .pdf ? .seconds(135) : nil
        var requestWasDispatched = false

        do {
            let result = try await runtime.request(method, parameters: {
                guard !self.disposed,
                      self.lifecycle == operationLifecycle,
                      self.turnEpoch == operationTurn,
                      self.runState == .idle,
                      self.binding == capturedBinding,
                      self.runtime.origin == capturedOrigin,
                      self.runtime.connectionGeneration == capturedGeneration,
                      self.runtime.state == .ready else {
                    throw DirectSessionError.staleOperation
                }
                requestWasDispatched = true
                return requestFields
            }, timeout: requestTimeout)

            guard !disposed,
                  lifecycle == operationLifecycle,
                  turnEpoch == operationTurn,
                  runState == .idle,
                  binding == capturedBinding,
                  runtime.origin == capturedOrigin,
                  runtime.connectionGeneration == capturedGeneration,
                  runtime.state == .ready else {
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .staleAfterDispatch
                )
            }

            let receipt: DirectGatewayAttachmentReceipt
            do {
                switch kind {
                case .image:
                    receipt = try DirectGatewayAttachmentReceipt.image(from: result)
                case .file:
                    receipt = try DirectGatewayAttachmentReceipt.file(from: result)
                case .pdf:
                    receipt = try DirectGatewayAttachmentReceipt.pdf(from: result)
                }
            } catch {
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .malformedResponse
                )
            }

            return DirectGatewayAttachmentStageResult(scope: scope, receipt: receipt)
        } catch let error as DirectGatewayAttachmentStageError {
            throw error
        } catch let error as HermesGatewayError {
            if case .server(let code, let message, _, let serverMethod, _, _) = error,
               requestWasDispatched,
               serverMethod == method,
               Self.isDefiniteAttachmentRejection(kind: kind, method: method, code: code) {
                throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                    kind: kind,
                    reason: .serverRejected(code: code, message: message)
                )
            }

            guard requestWasDispatched else {
                let reason: DirectGatewayAttachmentStageDefiniteReason = {
                    if case .cancelled = error { return .cancelledBeforeDispatch }
                    return .staleBeforeDispatch
                }()
                throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                    kind: kind,
                    reason: reason
                )
            }

            if case .cancelled = error {
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .cancelledAfterDispatch
                )
            }

            throw DirectGatewayAttachmentStageError.unknown(
                kind: kind,
                scope: scope,
                reason: Self.attachmentUnknownReason(for: error)
            )
        } catch is CancellationError {
            if requestWasDispatched {
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .cancelledAfterDispatch
                )
            }
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .cancelledBeforeDispatch
            )
        } catch is DirectSessionError {
            if requestWasDispatched {
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .staleAfterDispatch
                )
            }
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .staleBeforeDispatch
            )
        } catch {
            if requestWasDispatched {
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .transport
                )
            }
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .staleBeforeDispatch
            )
        }
    }

    /// Creation settings are per draft, not mutations of server configuration.
    /// A lost prompt acknowledgement is never automatically replayed.
    func submit(
        _ text: String,
        stagedAttachments: [DirectPendingAttachment] = [],
        create: [String: JSONValue] = [:]
    ) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DirectSessionError.invalidResponse }
        guard !hasAmbiguousPromptDelivery else { throw DirectSessionError.ambiguousPrompt }
        if pendingReasoningEffort != nil, let mutationTail = reasoningMutationTail {
            await mutationTail.value
        }
        guard runState == .idle,
              !promptInFlight,
              !attachmentStageInFlight,
              reasoningMutationCount == 0
        else { throw DirectSessionError.ambiguousPrompt }
        promptInFlight = true
        defer { promptInFlight = false }
        if ambiguousReasoningEffort != nil {
            // An unacknowledged stock write is never replayed. A read can make
            // the next attempt safe, but this submit must still surface that
            // the requested setting's outcome was previously unknown.
            try await reconcileAmbiguousReasoning()
            throw DirectSessionError.invalidResponse
        }
        if let pendingReasoningEffort {
            let applied = try await applyStockReasoning(pendingReasoningEffort)
            guard !applied.deferred else { throw DirectSessionError.invalidResponse }
        }

        // Confirmed attachment receipts belong to the idle turn in which they
        // were staged. Bind first, then validate that exact scope before this
        // submit advances the turn. Pending/unknown receipts are never sent.
        let preSubmitTurn = turnEpoch
        var stagedScope: DirectPendingAttachmentStageScope?
        var stagedReferenceTexts: [String] = []
        let validationLifecycle = lifecycle
        if !stagedAttachments.isEmpty {
            try await ensureBinding(create: create)
            guard !disposed,
                  lifecycle == validationLifecycle,
                  turnEpoch == preSubmitTurn,
                  runState == .idle,
                  runtime.state == .ready,
                  let currentBinding = binding else {
                throw DirectSessionError.staleOperation
            }
            let scope = DirectPendingAttachmentStageScope(
                binding: currentBinding,
                connectionGeneration: runtime.connectionGeneration,
                origin: runtime.origin,
                turnEpoch: preSubmitTurn
            )
            guard stagedAttachments.allSatisfy({ $0.isConfirmed(for: scope) }) else {
                throw DirectSessionError.invalidResponse
            }
            stagedScope = scope
            stagedReferenceTexts = stagedAttachments.compactMap { $0.referenceText(for: scope) }
        }

        turnEpoch &+= 1
        let submissionTurn = turnEpoch
        reconciliationTask?.cancel()
        idleRefreshTask?.cancel()
        runState = .submitting
        if stagedAttachments.isEmpty {
            do { try await ensureBinding(create: create) }
            catch { runState = .idle; throw error }
        }
        guard let capturedBinding = binding else { runState = .idle; throw DirectSessionError.invalidBinding }
        let generation = lifecycle
        let capturedOrigin = runtime.origin
        let capturedConnectionGeneration = runtime.connectionGeneration
        let previousHasSubmittedPrompt = hasSubmittedPrompt
        let previousTerminalReceipt = terminalReceipt
        let submittedText = ([text] + stagedReferenceTexts).joined(separator: "\n")
        terminalReceipt = nil
        hasSubmittedPrompt = true
        var submitRequestWasDispatched = false
        do {
            let result = try await runtime.request("prompt.submit", parameters: {
                guard !self.disposed, let binding = self.binding else { throw DirectSessionError.invalidBinding }
                if !stagedAttachments.isEmpty {
                    guard self.lifecycle == generation,
                          self.turnEpoch == submissionTurn,
                          self.runState == .submitting,
                          binding == capturedBinding,
                          self.runtime.origin == capturedOrigin,
                          self.runtime.connectionGeneration == capturedConnectionGeneration,
                          self.runtime.state == .ready,
                          let stagedScope,
                          stagedAttachments.allSatisfy({ $0.isConfirmed(for: stagedScope) }) else {
                        throw DirectSessionError.staleOperation
                    }
                }
                submitRequestWasDispatched = true
                return ["session_id": .string(binding.runtimeID), "profile": .string(self.profile), "text": .string(submittedText)]
            })
            try checkLifecycle(generation)
            if !stagedAttachments.isEmpty {
                guard binding == capturedBinding,
                      runtime.origin == capturedOrigin,
                      runtime.connectionGeneration == capturedConnectionGeneration else {
                    throw DirectSessionError.staleOperation
                }
            }
            guard result?.gatewayFields["status"]?.gatewayString == "streaming" else { throw DirectSessionError.invalidResponse }
            // A very short turn can complete before the RPC continuation runs.
            if runState == .submitting { runState = .running }
        } catch {
            guard !disposed, generation == lifecycle else { throw error }
            if !submitRequestWasDispatched {
                if !stagedAttachments.isEmpty {
                    let canReuseConfirmedStage = turnEpoch == submissionTurn &&
                        runState == .submitting &&
                        binding == capturedBinding &&
                        runtime.origin == capturedOrigin &&
                        runtime.connectionGeneration == capturedConnectionGeneration
                    if canReuseConfirmedStage {
                        turnEpoch = preSubmitTurn
                        runState = .idle
                        hasSubmittedPrompt = previousHasSubmittedPrompt
                        terminalReceipt = previousTerminalReceipt
                    } else if runState == .submitting {
                        runState = .idle
                    }
                } else if runState == .submitting {
                    runState = .idle
                }
                throw error
            }
            if Self.isDefinitePromptSubmitRejection(error) {
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
            } else {
                // A terminal event is not proof that this dispatched prompt
                // was accepted: another client or a queued turn may own it.
                // Keep the explicit barrier independent from transient
                // `runState`; this also covers an internal/unknown server
                // error or a response carrying the wrong RPC method.
                hasAmbiguousPromptDelivery = true
                if terminalReceipt == nil { runState = .deliveryUnknown }
            }
            throw error
        }
    }

    /// Reads the live session setting for an already-stored conversation. Drafts
    /// deliberately remain local and are never created just to read a setting.
    func reasoningConfiguration() async throws -> ReasoningConfiguration {
        guard !disposed, hasSubmittedPrompt, storedID != nil else { throw DirectSessionError.invalidBinding }
        while let mutationTail = reasoningMutationTail {
            await mutationTail.value
        }
        if let pendingReasoningEffort {
            let configuration = ReasoningConfiguration(
                effort: pendingReasoningEffort,
                deferred: true,
                supportsSessionChanges: true
            )
            onReasoningConfiguration?(configuration)
            return configuration
        }
        if ambiguousReasoningEffort != nil { try await reconcileAmbiguousReasoning() }
        let revision = reasoningRevision
        try await ensureBinding(create: [:])
        let configuration = try await readReasoningCapability().configuration
        guard revision == reasoningRevision else { throw DirectSessionError.staleOperation }
        onReasoningConfiguration?(configuration)
        return configuration
    }

    /// Changes the next-turn reasoning setting without changing run state. A
    /// fresh capability read is required before every write; its binding,
    /// socket generation, and lifecycle are pinned through the acknowledgement.
    func setReasoningEffort(_ effort: String) async throws -> ReasoningConfiguration {
        guard Self.reasoningEfforts.contains(effort), !disposed,
              hasSubmittedPrompt, storedID != nil,
              !promptInFlight, runState == .idle || runState == .running else {
            throw DirectSessionError.invalidResponse
        }
        reasoningRevision &+= 1
        reasoningMutationCount += 1
        let previous = reasoningMutationTail
        let operation: Task<ReasoningConfiguration, Error> = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { throw DirectSessionError.stopped }
            defer {
                self.reasoningMutationCount -= 1
                if self.reasoningMutationCount == 0 { self.reasoningMutationTail = nil }
            }
            guard !self.disposed, self.runState == .idle || self.runState == .running else {
                throw DirectSessionError.invalidResponse
            }
            if self.ambiguousReasoningEffort != nil {
                try await self.reconcileAmbiguousReasoning()
                throw DirectSessionError.invalidResponse
            }
            try await self.ensureBinding(create: [:])
            let selectedWhileRunning = self.runState == .running
            let capability = try await self.readReasoningCapability()
            guard !self.disposed, self.runState == .idle || self.runState == .running else {
                throw DirectSessionError.invalidResponse
            }
            if !capability.extendedContract {
                if selectedWhileRunning || self.runState == .running {
                    self.pendingReasoningEffort = effort
                    let configuration = ReasoningConfiguration(
                        effort: effort, deferred: true, supportsSessionChanges: true
                    )
                    self.onReasoningConfiguration?(configuration)
                    if self.runState == .idle { self.schedulePendingReasoningDrain() }
                    return configuration
                }
                return try await self.applyStockReasoning(effort, capability: capability)
            }
            let result = try await self.runtime.request("config.set", parameters: {
                try self.checkReasoningCapability(capability)
                guard self.runState == .idle || self.runState == .running else {
                    throw DirectSessionError.invalidResponse
                }
                return [
                    "key": .string("reasoning"),
                    "value": .string(effort),
                    "scope": .string("session"),
                    "session_id": .string(capability.binding.runtimeID),
                    "profile": .string(self.profile)
                ]
            })
            try self.checkReasoningCapability(capability)
            guard let fields = result?.gatewayFields,
                  fields["key"] == .string("reasoning"),
                  fields["value"] == .string(effort),
                  fields["scope"] == .string("session"),
                  fields["persisted"] == .bool(true),
                  let deferredValue = fields["deferred"],
                  case .bool(let deferred) = deferredValue else {
                throw DirectSessionError.invalidResponse
            }
            let configuration = ReasoningConfiguration(
                effort: effort,
                deferred: deferred,
                supportsSessionChanges: true
            )
            self.onReasoningConfiguration?(configuration)
            return configuration
        }
        reasoningMutationTail = Task { @MainActor in _ = try? await operation.value }
        return try await operation.value
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
            if stopped, terminalReceipt != nil {
                runState = .idle
                schedulePendingReasoningDrain()
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DirectSessionError.stopUnconfirmed
    }

    func refresh(limit: Int = 120, offset: Int = 0) async throws {
        guard !disposed, let storedID, hasSubmittedPrompt else { return }
        let generation = lifecycle
        let epoch = bindingEpoch
        let turn = turnEpoch
        // Backwards offsets belong to a particular tail. An older request
        // crossing a new tail read must not rewind its cursor or prepend stale
        // rows. Likewise, a slow tail response cannot replace a newer one.
        if offset == 0 { latestReadGeneration &+= 1 }
        let readGeneration = latestReadGeneration
        let page = try await loadTranscript(storedID, profile, limit, offset)
        try checkLifecycle(generation)
        guard epoch == bindingEpoch, turn == turnEpoch, storedID == self.storedID,
              readGeneration == latestReadGeneration else { throw DirectSessionError.staleOperation }
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
        reasoningRevision &+= 1
        pendingReasoningEffort = nil
        pendingBlockingPrompt = nil
        blockingClear = nil
        ambiguousReasoningEffort = nil
        reasoningMutationTail?.cancel()
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
        restoreBlockingPrompt(from: result)
        try await refresh()
        guard binding != nil else { throw DirectSessionError.staleOperation }
        if result?.gatewayFields["running"] == .bool(true) { runState = .running }
        else if runState != .deliveryUnknown, !promptInFlight {
            runState = .idle
            schedulePendingReasoningDrain()
        }
        onResume?(result)
    }

    /// Answers a stock clarify request only when the caller supplies the exact
    /// identity it captured from the displayed prompt. That identity is
    /// revalidated after any connect/rebind and again in the RPC parameter
    /// closure; an ambiguous or replaced response is never retried.
    func respondToBlockingPrompt(
        _ answer: String,
        expectedIdentity: GatewayBlockingPromptIdentity
    ) async throws -> GatewayBlockingResponse {
        guard !disposed else { throw DirectSessionError.stopped }
        guard !blockingResponseInFlight else { throw GatewayBlockingError.responseInFlight }
        blockingResponseInFlight = true
        defer { blockingResponseInFlight = false }
        guard let captured = pendingBlockingPrompt else {
            throw GatewayBlockingError.noPendingClarification
        }
        guard captured.identity == expectedIdentity,
              let capturedBinding = binding else {
            throw GatewayBlockingError.staleClarification
        }
        if captured.kind.isCancelOnly, !answer.isEmpty {
            throw GatewayBlockingError.invalidClarificationResponse
        }
        let capturedLifecycle = lifecycle
        try await ensureBinding(create: [:])
        guard pendingBlockingPrompt?.identity == expectedIdentity,
              let currentBinding = binding,
              currentBinding == capturedBinding,
              runtime.connectionGeneration == expectedIdentity.connectionGeneration,
              lifecycle == capturedLifecycle else {
            throw GatewayBlockingError.staleClarification
        }
        if pendingBlockingPrompt?.kind.isCancelOnly == true, !answer.isEmpty {
            throw GatewayBlockingError.invalidClarificationResponse
        }

        let result = try await runtime.request("clarify.respond", parameters: {
            guard let pending = self.pendingBlockingPrompt,
                  pending.identity == expectedIdentity,
                  let binding = self.binding,
                  binding == capturedBinding,
                  self.runtime.connectionGeneration == expectedIdentity.connectionGeneration,
                  self.lifecycle == capturedLifecycle else {
                throw GatewayBlockingError.staleClarification
            }
            if pending.kind.isCancelOnly, !answer.isEmpty {
                throw GatewayBlockingError.invalidClarificationResponse
            }
            return [
                "session_id": .string(expectedIdentity.runtimeID),
                "profile": .string(expectedIdentity.profile),
                "request_id": .string(expectedIdentity.requestID),
                "answer": .string(answer)
            ]
        })
        guard !disposed,
              let currentBinding = binding,
              currentBinding == capturedBinding,
              runtime.connectionGeneration == expectedIdentity.connectionGeneration,
              lifecycle == capturedLifecycle else {
            throw GatewayBlockingError.staleClarification
        }
        guard let status = result?.gatewayFields["status"]?.gatewayString else {
            throw GatewayBlockingError.invalidClarificationResponse
        }
        switch status {
        case "ok":
            if let stillPending = pendingBlockingPrompt {
                guard stillPending.identity == expectedIdentity else {
                    throw GatewayBlockingError.staleClarification
                }
                pendingBlockingPrompt = nil
            } else {
                guard blockingClear?.identity == expectedIdentity,
                      blockingClear?.reason == BlockingClearReason.terminal else {
                    throw GatewayBlockingError.staleClarification
                }
            }
            return .accepted
        case "expired":
            if let stillPending = pendingBlockingPrompt {
                guard stillPending.identity == expectedIdentity else {
                    throw GatewayBlockingError.staleClarification
                }
                pendingBlockingPrompt = nil
            } else {
                guard blockingClear?.identity == expectedIdentity,
                      blockingClear?.reason == BlockingClearReason.expiry else {
                    throw GatewayBlockingError.staleClarification
                }
            }
            return .expired
        default:
            throw GatewayBlockingError.invalidClarificationResponse
        }
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

    private func readReasoningCapability() async throws -> ReasoningCapability {
        try await runtime.connect()
        let capability = try reasoningSnapshot()
        let result = try await runtime.request("config.get", parameters: {
            try self.checkReasoningCapability(capability)
            return [
                "key": .string("reasoning"),
                "scope": .string("session"),
                "session_id": .string(capability.binding.runtimeID),
                "profile": .string(self.profile)
            ]
        })
        try checkReasoningCapability(capability)
        guard let fields = result?.gatewayFields,
              let effort = fields["value"]?.gatewayString,
              Self.reasoningEfforts.contains(effort),
              let display = fields["display"]?.gatewayString,
              Self.reasoningDisplays.contains(display) else {
            throw DirectSessionError.invalidResponse
        }
        let supportsSessionChanges: Bool
        let deferred: Bool
        if fields["session_reasoning_contract"] == .number(1) {
            guard let deferredValue = fields["deferred"], case .bool(let value) = deferredValue else {
                throw DirectSessionError.invalidResponse
            }
            supportsSessionChanges = true
            deferred = value
        } else {
            guard fields["session_reasoning_contract"] == nil,
                  fields["deferred"] == nil,
                  fields["persisted"] == nil else {
                throw DirectSessionError.invalidResponse
            }
            supportsSessionChanges = true
            deferred = false
        }
        return ReasoningCapability(
            binding: capability.binding,
            bindingEpoch: capability.bindingEpoch,
            connectionGeneration: capability.connectionGeneration,
            lifecycle: capability.lifecycle,
            extendedContract: fields["session_reasoning_contract"] == .number(1),
            configuration: ReasoningConfiguration(
                effort: effort,
                deferred: deferred,
                supportsSessionChanges: supportsSessionChanges
            )
        )
    }

    /// Applies stock reasoning only after the exact attached runtime reports
    /// idle. Once config.set is attempted, every non-confirmed outcome becomes
    /// read-reconciliation-only state and is never automatically replayed.
    private func applyStockReasoning(
        _ effort: String,
        capability suppliedCapability: ReasoningCapability? = nil
    ) async throws -> ReasoningConfiguration {
        let capability: ReasoningCapability
        if let suppliedCapability { capability = suppliedCapability }
        else { capability = try await readReasoningCapability() }
        guard !capability.extendedContract else { throw DirectSessionError.invalidResponse }
        let status = try await runtime.request("session.status", parameters: {
            try self.checkReasoningCapability(capability)
            return self.rpcParams(capability.binding)
        })
        try checkReasoningCapability(capability)
        guard let output = status?.gatewayFields["output"]?.gatewayString else {
            throw DirectSessionError.invalidResponse
        }
        let lines = Set(output.components(separatedBy: .newlines))
        if lines.contains("Agent Running: Yes") {
            pendingReasoningEffort = effort
            let configuration = ReasoningConfiguration(
                effort: effort, deferred: true, supportsSessionChanges: true
            )
            onReasoningConfiguration?(configuration)
            return configuration
        }
        guard lines.contains("Agent Running: No") else { throw DirectSessionError.invalidResponse }

        do {
            let result = try await runtime.request("config.set", parameters: {
                try self.checkReasoningCapability(capability)
                return [
                    "key": .string("reasoning"),
                    "value": .string(effort),
                    "scope": .string("session"),
                    "session_id": .string(capability.binding.runtimeID),
                    "profile": .string(self.profile)
                ]
            })
            try checkReasoningCapability(capability)
            guard let ack = result?.gatewayFields,
                  ack["key"] == .string("reasoning"),
                  ack["value"] == .string(effort),
                  ack["scope"] == nil || ack["scope"] == .string("session"),
                  ack["persisted"] == nil || ack["persisted"] == .bool(true),
                  ack["deferred"] == nil || ack["deferred"] == .bool(false) else {
                throw DirectSessionError.invalidResponse
            }
            let readback = try await readReasoningCapability()
            try checkReasoningCapability(capability)
            guard !readback.extendedContract,
                  readback.binding == capability.binding,
                  readback.configuration.effort == effort else {
                throw DirectSessionError.invalidResponse
            }
            if pendingReasoningEffort == effort { pendingReasoningEffort = nil }
            ambiguousReasoningEffort = nil
            let configuration = ReasoningConfiguration(
                effort: effort, deferred: false, supportsSessionChanges: true
            )
            onReasoningConfiguration?(configuration)
            return configuration
        } catch {
            // Even a cancellation or malformed acknowledgement can follow a
            // server-side mutation. Retain no replayable intent.
            pendingReasoningEffort = nil
            ambiguousReasoningEffort = effort
            throw error
        }
    }

    private func reconcileAmbiguousReasoning() async throws {
        guard ambiguousReasoningEffort != nil else { return }
        let configuration = try await readReasoningCapability().configuration
        ambiguousReasoningEffort = nil
        onReasoningConfiguration?(configuration)
    }

    private func blockingIdentity(requestID: String) throws -> GatewayBlockingPromptIdentity {
        guard let binding,
              !binding.storedID.isEmpty,
              !binding.runtimeID.isEmpty,
              !binding.profile.isEmpty,
              !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayBlockingError.malformedClarification
        }
        return GatewayBlockingPromptIdentity(
            origin: runtime.origin.absoluteString,
            profile: binding.profile,
            storedID: binding.storedID,
            runtimeID: binding.runtimeID,
            connectionGeneration: runtime.connectionGeneration,
            requestID: requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func restoreBlockingPrompt(from result: JSONValue?) {
        blockingClear = nil
        guard let fields = result?.gatewayFields else {
            pendingBlockingPrompt = nil
            return
        }
        guard let pending = fields["pending_clarify"] else {
            pendingBlockingPrompt = nil
            return
        }
        if pending == .null {
            pendingBlockingPrompt = nil
            return
        }
        do {
            guard case .object(let pendingFields) = pending,
                  let requestID = pendingFields["request_id"]?.gatewayString else {
                throw GatewayBlockingError.malformedClarification
            }
            let identity = try blockingIdentity(requestID: requestID)
            pendingBlockingPrompt = try GatewayBlockingPrompt.decode(
                payload: pending,
                identity: identity
            )
        } catch {
            pendingBlockingPrompt = nil
            onError?(error)
        }
    }

    private func handleBlockingRequest(_ event: HermesGatewayEvent) {
        guard let requestID = event.payload?.gatewayFields["request_id"]?.gatewayString else {
            onError?(GatewayBlockingError.malformedClarification)
            return
        }
        do {
            let identity = try blockingIdentity(requestID: requestID)
            let prompt = try GatewayBlockingPrompt.decode(payload: event.payload, identity: identity)
            if pendingBlockingPrompt != prompt {
                blockingClear = nil
                pendingBlockingPrompt = prompt
            }
        } catch {
            onError?(error)
        }
    }

    private func handleBlockingExpiry(_ event: HermesGatewayEvent) {
        guard let requestID = event.payload?.gatewayFields["request_id"]?.gatewayString else {
            onError?(GatewayBlockingError.malformedClarification)
            return
        }
        guard let pending = pendingBlockingPrompt,
              pending.identity.requestID == requestID,
              pending.identity.runtimeID == (event.sessionID ?? "") else {
            return
        }
        blockingClear = (pending.identity, .expiry)
        pendingBlockingPrompt = nil
    }

    private func clearBlockingPromptForTerminal(_ event: HermesGatewayEvent) {
        guard let pending = pendingBlockingPrompt,
              pending.identity.runtimeID == (event.sessionID ?? "") else {
            return
        }
        blockingClear = (pending.identity, .terminal)
        pendingBlockingPrompt = nil
    }

    private func schedulePendingReasoningDrain() {
        guard !disposed, pendingReasoningEffort != nil, ambiguousReasoningEffort == nil else { return }
        reasoningMutationCount += 1
        let previous = reasoningMutationTail
        let operation = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            defer {
                self.reasoningMutationCount -= 1
                if self.reasoningMutationCount == 0 { self.reasoningMutationTail = nil }
            }
            guard !self.disposed, self.runState == .idle,
                  let effort = self.pendingReasoningEffort else { return }
            do { _ = try await self.applyStockReasoning(effort) }
            catch {
                if !Task.isCancelled, !self.disposed { self.onError?(error) }
            }
        }
        reasoningMutationTail = Task { @MainActor in await operation.value }
    }

    private func reasoningSnapshot() throws -> ReasoningCapability {
        guard !disposed, hasSubmittedPrompt, let storedID, let binding,
              storedID == binding.storedID, binding.profile == profile else {
            throw DirectSessionError.invalidBinding
        }
        return ReasoningCapability(
            binding: binding,
            bindingEpoch: bindingEpoch,
            connectionGeneration: runtime.connectionGeneration,
            lifecycle: lifecycle,
            extendedContract: false,
            configuration: ReasoningConfiguration(
                effort: "",
                deferred: false,
                supportsSessionChanges: false
            )
        )
    }

    private func checkReasoningCapability(_ capability: ReasoningCapability) throws {
        guard !disposed, lifecycle == capability.lifecycle,
              bindingEpoch == capability.bindingEpoch,
              runtime.connectionGeneration == capability.connectionGeneration,
              binding == capability.binding else {
            throw DirectSessionError.staleOperation
        }
    }

    private static func isDefiniteAttachmentRejection(
        kind: DirectGatewayAttachmentKind,
        method: String,
        code: Int
    ) -> Bool {
        switch (kind, method) {
        case (.image, "image.attach_bytes"):
            return [4015, 4016, 4017, 4018].contains(code)
        case (.file, "file.attach"):
            // 5028 can follow file materialization; it is not a proof that
            // no server-side artifact was written, so it stays unknown.
            return code == 4015
        case (.pdf, "pdf.attach"):
            // The pinned stock 5028 branches (missing renderer, timeout,
            // render failure, no pages) happen before the page queue loop.
            // This is intentionally scoped to pdf.attach, never a global
            // interpretation of code 5028.
            return [4015, 4016, 4017, 4018, 4019, 5028].contains(code)
        default:
            return false
        }
    }

    /// Codes observed in the pinned `prompt.submit` implementation before it
    /// calls `_start_inflight_turn` (or while rejecting a stale runtime
    /// session before the method body). This is deliberately an allowlist: a
    /// generic JSON-RPC server/internal error may be returned after a future
    /// side effect, so treating every `.server` error as a harmless rejection
    /// would permit a duplicate prompt.  5008 is intentionally excluded;
    /// truncation persistence can have partially changed durable state before
    /// reporting failure.
    private static let definitePromptSubmitServerCodes: Set<Int> = [
        4001, // stale runtime session lookup
        4004, // malformed truncation parameters
        4009, // subagent still running
        4018, // stale/missing truncation target
        4028, // empty truncation target
        4029, // truncation consent required
        4090, // active session slot unavailable
        4091, // hosted room member busy
        4120, // invalid hosted-room proof
        4121, // hosted room isolation unsupported
        4122, // hosted room is gateway-managed
        5122, // hosted-room verification failure
    ]

    private static func isDefinitePromptSubmitRejection(_ error: Error) -> Bool {
        guard let gatewayError = error as? HermesGatewayError,
              case .server(let code, _, _, let serverMethod, _, _) = gatewayError else {
            return false
        }
        return serverMethod == "prompt.submit" && definitePromptSubmitServerCodes.contains(code)
    }

    private static func attachmentUnknownReason(
        for error: HermesGatewayError
    ) -> DirectGatewayAttachmentStageUnknownReason {
        if case .server(let code, let message, _, _, _, _) = error {
            return .server(code: code, message: message)
        }
        return .transport
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
        case "clarify.request":
            handleBlockingRequest(event)
        case "clarify.expire":
            handleBlockingExpiry(event)
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
                if runState != .stopping {
                    runState = .idle
                    schedulePendingReasoningDrain()
                }
            }
        case "message.complete":
            clearBlockingPromptForTerminal(event)
            let receipt = "\(event.connectionGeneration ?? -1):\(event.sequence ?? -1)"
            guard terminalReceipt != receipt else { return }
            terminalReceipt = receipt
            if runState != .stopping {
                runState = .idle
                schedulePendingReasoningDrain()
            }
            onEvent?(event)
            reconciliationTask?.cancel()
            reconciliationTask = Task { [weak self] in
                do { try await self?.refresh() }
                catch DirectSessionError.staleOperation { /* A newer read/turn owns reconciliation. */ }
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
            } catch DirectSessionError.staleOperation { /* A newer read/turn owns reconciliation. */ }
            catch { if !Task.isCancelled { self?.onError?(error) } }
        }
    }
}
