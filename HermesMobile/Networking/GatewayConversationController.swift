import Foundation
import Observation

enum DirectPromptDeliveryUncertaintyError: Error, Equatable, Sendable {
    case persistenceUnavailable
}

enum DirectSessionBranchError: Error, Equatable, Sendable {
    /// The gateway may have created the child, but the client did not receive
    /// a trustworthy result.  Branching is never retried automatically.
    case outcomeUnknown
    case invalidResponse
}

enum DirectSessionCompressionError: Error, Equatable, Sendable {
    case outcomeUnknown
    case invalidResponse
}

enum DirectBtwError: Error, Equatable, Sendable {
    case alreadyActive
    case outcomeUnknown
    case invalidResponse
}

enum DirectBackgroundError: Error, Equatable, Sendable {
    case outcomeUnknown
    case invalidResponse
}

enum DirectGoalError: LocalizedError, Equatable, Sendable {
    case runningProfileUnavailable
    case runningProfileMismatch(selected: String, current: String)
    case unsupportedResult
    case invalidResponse
    case outcomeUnknown

    var errorDescription: String? {
        switch self {
        case .runningProfileUnavailable:
            "Hermes did not report the profile used by this running gateway. Goal state was not changed."
        case .runningProfileMismatch:
            "Goals are available only when this chat uses the running gateway profile. Goal state was not changed."
        case .unsupportedResult:
            "Hermes resolved /goal to an unsupported command result. Goal state was not changed by the app."
        case .invalidResponse:
            "Hermes returned an invalid goal response."
        case .outcomeUnknown:
            "Goal outcome unknown. Check /goal status before trying again."
        }
    }
}

enum DirectSkillDispatchError: LocalizedError, Equatable, Sendable {
    case runningProfileUnavailable
    case runningProfileMismatch(selected: String, current: String)
    case alreadyDispatching
    case reservedCommand
    case unsupportedResult
    case invalidResponse
    case outcomeUnknown

    var errorDescription: String? {
        switch self {
        case .runningProfileUnavailable:
            "Hermes did not report the profile used by this running gateway. The skill was not invoked."
        case .runningProfileMismatch:
            "Skills can be invoked only when this chat uses the running gateway profile."
        case .alreadyDispatching:
            "Wait for the current skill invocation to finish."
        case .reservedCommand:
            "That slash name belongs to a built-in Hermes command, not a skill."
        case .unsupportedResult:
            "Hermes resolved that skill name to an unsupported alias."
        case .invalidResponse:
            "Hermes returned an invalid skill response."
        case .outcomeUnknown:
            "Skill invocation outcome unknown. It was not retried."
        }
    }
}

/// One conversation on the active server's shared socket. The view model owns
/// rendering/cache; this owner owns identity and RPC delivery, never a socket.
@MainActor
@Observable
final class GatewayConversationController {
    struct DestructivePromptTarget: Equatable {
        let userRowID: Int
        let userOrdinal: Int?
        let permitsEmptyTranscript: Bool
    }
    enum RunState: Equatable { case idle, submitting, running, stopping, deliveryUnknown }
    enum SteerOutcome: String { case accepted, queued, rejected }
    enum CompressionOutcome: Equatable { case compressed, unchanged, aborted, lockSkipped }
    enum BtwOutcome: Equatable, Sendable {
        case completed(attemptID: UUID, taskID: String, question: String, text: String)
        case unknown(attemptID: UUID)
    }
    enum BackgroundOutcome: Equatable, Sendable {
        case completed(attemptID: UUID, taskID: String, prompt: String, text: String)
        case unknown(attemptID: UUID)
    }
    enum GoalDispatchResult: Equatable, Sendable {
        case output(String)
        /// The dispatcher has only prepared this prompt. The caller must send
        /// it once through this same controller's normal prompt path.
        case send(notice: String?, message: String, display: String?)
    }
    enum SkillDispatchResult: Equatable, Sendable {
        case invocation(name: String, message: String, display: String)
        case bundle(message: String, notice: String?, display: String)
        case output(String)
    }
    static func goalControlIsAllowedWhileRunning(_ arg: String) -> Bool {
        ["status", "pause", "clear"].contains(
            arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
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
    enum OlderPageError: Error { case canonicalChanged }

    private(set) var binding: GatewaySessionBinding?
    private(set) var storedID: String?
    private(set) var runState: RunState = .idle
    /// Stock running resume has no event watermark. Presentation must retain
    /// canonical saved rows and ignore unproven response text until terminal refresh.
    private(set) var suppressesColdResumedContent = false
    /// A dispatched prompt whose outcome is not proven must remain a hard
    /// barrier even if a concurrent/queued terminal event temporarily makes
    /// `runState` idle. Canonical recovery or controller replacement owns the
    /// eventual resolution; this controller never clears it from a generic
    /// refresh or status response.
    private(set) var hasAmbiguousPromptDelivery = false
    var promptDeliveryUncertaintyToken: UUID? { promptUncertaintyMarker?.token }
    private(set) var promptDeliveryUncertaintyHasConfirmedAcceptance = false
    /// A persisted marker means Hermes may still own an attachment queued for
    /// this durable chat. It is intentionally a cached value, never a file
    /// read from a SwiftUI body.
    private(set) var attachmentRecoveryNeedsReset = false
    private(set) var attachmentRecoveryIsBusy = false
    private(set) var unresolvedAttachmentMarkerToken: UUID?
    var hasUnresolvedAttachmentMarker: Bool { attachmentRecoveryNeedsReset }
    private(set) var pendingReasoningEffort: String?
    /// One renderer-facing blocking prompt. It is transient and always scoped
    /// to the exact server/runtime/connection/request identity below.
    private(set) var pendingBlockingPrompt: GatewayBlockingPrompt?
    /// Native direct-gateway prompts. Approval requests are retained in arrival
    /// order because Hermes may have more than one live request; sensitive
    /// requests use the same identity-keyed queue and expose only the first.
    private(set) var pendingApprovalPrompt: GatewayApprovalPrompt?
    private(set) var pendingSecretPrompt: GatewaySecretPrompt?
    private(set) var pendingSudoPrompt: GatewaySudoPrompt?
    private(set) var blockingInteractionResponseInFlight = false
    let profile: String
    var onBinding: ((GatewaySessionBinding) -> Void)?
    var onCanonicalID: ((String) -> Void)?
    var onEvent: ((HermesGatewayEvent) -> Void)?
    var onTranscript: ((DirectHermesTranscriptPage, Bool) -> Void)?
    var onResume: ((JSONValue?) -> Void)?
    /// A reconnect verified canonical history and explicit idle for the unchanged run.
    var onRecoveredIdle: ((String) -> Void)?
    private var recoveredIdleCandidate: (lifecycle: Int, turn: Int, binding: GatewaySessionBinding, generation: Int, terminal: String?)?
    var onReasoningConfiguration: ((ReasoningConfiguration) -> Void)?
    var onBtwOutcome: ((BtwOutcome) -> Void)?
    var onBackgroundOutcome: ((BackgroundOutcome) -> Void)?
    var onError: ((Error) -> Void)?
    var isVisible = false
    var isEditing = false {
        didSet { if !isEditing, transcriptDirty { scheduleIdleRefresh() } }
    }

    @ObservationIgnored private let runtime: HermesServerRuntime
    @ObservationIgnored private let loadTranscript: TranscriptLoader
    @ObservationIgnored private let recoveryMarkerStore: any DirectGatewayAttachmentRecoveryMarkerStoreProtocol
    @ObservationIgnored private let promptUncertaintyStore: any DirectPromptDeliveryUncertaintyStoreProtocol
    @ObservationIgnored private var observerID: UUID?
    @ObservationIgnored private var attachmentTask: Task<Void, Error>?
    @ObservationIgnored private var attachmentStageInFlight = false
    @ObservationIgnored private var attachmentRemovalInFlight = false
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var idleRefreshTask: Task<Void, Never>?
    private var lifecycle = 0
    private var disposed = false
    private var didDispose = false
    private var hasSubmittedPrompt: Bool
    private var transcriptDirty = false
    private var terminalReceipt: String?
    private var promptInFlight = false
    /// A draft session.create may have reached Hermes without returning its
    /// binding. Goal preparation never repeats that create in this controller.
    private var goalPreparationOutcomeUnknown = false
    private var skillDispatchInFlight = false
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
    private enum InteractionClearReason: Equatable { case terminal, expiry }
    private enum SensitiveInteractionKind: String { case secret, sudo }
    private var approvalPromptQueue: [GatewayApprovalPrompt] = []
    private var secretPromptQueue: [GatewaySecretPrompt] = []
    private var sudoPromptQueue: [GatewaySudoPrompt] = []
    private var approvalClear: [(GatewayBlockingPromptIdentity, InteractionClearReason)] = []
    private var secretClear: [(GatewayBlockingPromptIdentity, InteractionClearReason)] = []
    private var sudoClear: [(GatewayBlockingPromptIdentity, InteractionClearReason)] = []
    private var blockingInteractionInFlightIdentity: GatewayBlockingPromptIdentity?
    private var recoveryMarker: DirectGatewayAttachmentRecoveryMarker?
    private var recoveryMarkerLoadFailed = false
    private var recoveryStageUnknown = false
    private var locallyConfirmedRecoveryStageCount = 0
    private var recoveryDetachPaths: [String] = []
    @ObservationIgnored private var recoveryCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryCleanupOwnerToken: UUID?
    @ObservationIgnored private var recoveryCleanupOwnerID: UUID?
    private var latestEventSequence = -1
    private struct RecoveryPromptObservation: Sendable {
        let token: UUID
        let binding: GatewaySessionBinding
        let origin: URL
        let connectionGeneration: Int
        let lifecycle: Int
        let minimumEventSequence: Int
        var accepted = false
        var terminalSequence: Int?
    }
    private var recoveryPromptObservation: RecoveryPromptObservation?
    private var promptUncertaintyMarker: DirectPromptDeliveryUncertaintyMarker?
    private var promptUncertaintyLoadFailed = false
    private var promptLineageResolutionFailed = false
    private var lastClearedPromptUncertaintyMarker: DirectPromptDeliveryUncertaintyMarker?
    private var promptUncertaintyAbandonInFlight = false
    /// Shared exclusion lease for branch and manual compression. Existing
    /// mutation entrypoints already honor this lease; reads remain available.
    private var branchInFlight = false
    private(set) var branchOutcomeUnknown = false
    /// Controller-lifetime quarantine only; history reads do not prove a lost
    /// compression request has finished, and never authorize automatic retry.
    private(set) var compressionOutcomeUnknown = false
    private struct ActiveBtw {
        let attemptID: UUID
        let question: String
        let binding: GatewaySessionBinding
        let bindingEpoch: Int
        let lifecycle: Int
        var connectionGeneration: Int?
        var taskID: String?
    }
    private var activeBtw: ActiveBtw?
    private struct ActiveBackground {
        let attemptID: UUID
        let prompt: String
        let binding: GatewaySessionBinding
        let bindingEpoch: Int
        let lifecycle: Int
        var connectionGeneration: Int?
        var taskID: String?
    }
    private var activeBackgroundByAttempt: [UUID: ActiveBackground] = [:]

    /// Identity-only accessors used when ownership moves to a child
    /// ChatViewModel. The shared runtime is never recreated or resumed.
    var runtimeOrigin: URL { runtime.origin }
    var sharedRuntime: HermesServerRuntime { runtime }
    var isDisposed: Bool { disposed }

    init(
        runtime: HermesServerRuntime,
        storedID: String?,
        profile: String = "default",
        recoveryMarkerStore: any DirectGatewayAttachmentRecoveryMarkerStoreProtocol = DirectGatewayAttachmentRecoveryMarkerStore(),
        promptUncertaintyStore: any DirectPromptDeliveryUncertaintyStoreProtocol = DirectPromptDeliveryUncertaintyStore(),
        loadTranscript: @escaping TranscriptLoader
    ) {
        self.runtime = runtime
        self.storedID = storedID
        let normalizedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profile = normalizedProfile.isEmpty ? "default" : normalizedProfile
        self.recoveryMarkerStore = recoveryMarkerStore
        self.promptUncertaintyStore = promptUncertaintyStore
        self.loadTranscript = loadTranscript
        hasSubmittedPrompt = storedID != nil
        durableRowConfirmed = storedID != nil
        refreshPromptUncertaintyMarker()
        refreshRecoveryMarker()
        observerID = runtime.observe(event: { [weak self] event in
            self?.receive(event)
        }, recover: { [weak self] transport in
            guard let self, !self.disposed else { return }
            self.recoveredIdleCandidate = nil
            // Fresh, unsent runtime sessions have no durable row to resume.
            self.invalidateBinding()
            if self.hasSubmittedPrompt, self.storedID != nil {
                try await self.resume(using: transport)
            }
        }, ready: { [weak self] in
            self?.publishRecoveredIdleAfterEventDrain()
        })
    }

    convenience init(
        runtime: HermesServerRuntime,
        client: APIClient,
        storedID: String?,
        profile: String = "default",
        recoveryMarkerStore: any DirectGatewayAttachmentRecoveryMarkerStoreProtocol = DirectGatewayAttachmentRecoveryMarkerStore(),
        promptUncertaintyStore: any DirectPromptDeliveryUncertaintyStoreProtocol = DirectPromptDeliveryUncertaintyStore()
    ) {
        self.init(runtime: runtime, storedID: storedID, profile: profile, recoveryMarkerStore: recoveryMarkerStore, promptUncertaintyStore: promptUncertaintyStore) { id, profile, limit, offset in
            try await client.directSessionMessages(sessionID: id, profile: profile, limit: limit, offset: offset)
        }
    }

    deinit { attachmentTask?.cancel(); reconciliationTask?.cancel(); idleRefreshTask?.cancel(); recoveryCleanupTask?.cancel() }

    private func currentRecoveryIdentity() throws -> DirectGatewayAttachmentRecoveryIdentity {
        guard let storedID, let binding else { throw DirectSessionError.invalidBinding }
        return try DirectGatewayAttachmentRecoveryIdentity(
            origin: runtime.origin,
            profile: profile,
            storedID: storedID,
            runtimeID: binding.runtimeID
        )
    }

    private func refreshRecoveryMarker() {
        guard let storedID, let binding,
              let identity = try? DirectGatewayAttachmentRecoveryIdentity(
                origin: runtime.origin,
                profile: profile,
                storedID: storedID,
                runtimeID: binding.runtimeID
              ) else {
            return
        }
        do {
            let loaded = try recoveryMarkerStore.load(for: identity)
            if let existing = recoveryMarker,
               existing.identity != identity {
                // A canonical-ID change can be a stock compression
                // continuation. Keep the marker keyed by its original
                // durable identity; the current runtime binding is still
                // required for any reset and the marker remains blocking.
                _ = existing
            } else {
                recoveryMarker = loaded
                recoveryMarkerLoadFailed = false
                recoveryStageUnknown = loaded != nil
            }
        } catch {
            recoveryMarkerLoadFailed = true
        }
        attachmentRecoveryNeedsReset = recoveryMarker != nil || recoveryMarkerLoadFailed
        unresolvedAttachmentMarkerToken = recoveryMarker?.token
    }

    private func promptUncertaintyIdentity(for storedID: String) throws -> DirectPromptDeliveryUncertaintyIdentity {
        try DirectPromptDeliveryUncertaintyIdentity(
            origin: runtime.origin,
            profile: profile,
            storedID: storedID
        )
    }

    private func refreshPromptUncertaintyMarker() {
        guard let storedID,
              let identity = try? promptUncertaintyIdentity(for: storedID) else {
            return
        }
        do {
            promptUncertaintyMarker = try promptUncertaintyStore.load(for: identity)
            promptUncertaintyLoadFailed = false
            hasAmbiguousPromptDelivery = promptUncertaintyMarker != nil || promptLineageResolutionFailed
            promptDeliveryUncertaintyHasConfirmedAcceptance = false
        } catch {
            promptUncertaintyMarker = nil
            promptUncertaintyLoadFailed = true
            // A metadata read failure cannot prove that no barrier exists.
            hasAmbiguousPromptDelivery = true
        }
    }

    private func persistPromptUncertaintyBeforeDispatch() throws -> DirectPromptDeliveryUncertaintyMarker {
        guard !compressionOutcomeUnknown else { throw DirectSessionCompressionError.outcomeUnknown }
        guard !promptLineageResolutionFailed else { throw DirectSessionError.ambiguousPrompt }
        guard let storedID else { throw DirectSessionError.invalidBinding }
        let identity: DirectPromptDeliveryUncertaintyIdentity
        do { identity = try promptUncertaintyIdentity(for: storedID) }
        catch { throw DirectSessionError.ambiguousPrompt }

        do {
            // Re-read immediately before writing so another live controller in
            // this process cannot be silently overwritten with a new token.
            if let existing = try promptUncertaintyStore.load(for: identity) {
                promptUncertaintyMarker = existing
                promptUncertaintyLoadFailed = false
                hasAmbiguousPromptDelivery = true
                promptDeliveryUncertaintyHasConfirmedAcceptance = false
                throw DirectSessionError.ambiguousPrompt
            }
            let marker = DirectPromptDeliveryUncertaintyMarker(identity: identity)
            try promptUncertaintyStore.write(marker)
            promptUncertaintyMarker = marker
            promptUncertaintyLoadFailed = false
            promptDeliveryUncertaintyHasConfirmedAcceptance = false
            // The on-disk marker is a crash quarantine. Until this request
            // actually returns, promptInFlight/runState already block another
            // send and the marker must not render as an unknown outcome.
            return marker
        } catch let error as DirectSessionError {
            throw error
        } catch {
            promptUncertaintyLoadFailed = true
            // This is proven nondispatch: preserve the draft rather than make
            // the VM treat a local metadata failure as an accepted/unknown
            // server write. Future sends remain fail-closed until reload.
            throw DirectPromptDeliveryUncertaintyError.persistenceUnavailable
        }
    }

    @discardableResult
    private func clearPromptUncertainty(
        _ marker: DirectPromptDeliveryUncertaintyMarker,
        retainBarrierOnFailure: Bool
    ) -> Bool {
        do {
            guard !promptLineageResolutionFailed else {
                promptDeliveryUncertaintyHasConfirmedAcceptance = !retainBarrierOnFailure
                return false
            }
            guard let current = promptUncertaintyMarker,
                  current.token == marker.token else {
                hasAmbiguousPromptDelivery = true
                promptDeliveryUncertaintyHasConfirmedAcceptance = false
                return false
            }
            // Canonical adoption can migrate the marker while prompt.submit is
            // awaiting its ACK. Remove a still-present ancestor alias first,
            // then the exact current identity; never unlock merely because an
            // old same-token marker was removed.
            if current.identity != marker.identity,
               let alias = try promptUncertaintyStore.load(for: marker.identity) {
                guard alias.token == marker.token else {
                    hasAmbiguousPromptDelivery = true
                    promptDeliveryUncertaintyHasConfirmedAcceptance = false
                    return false
                }
                try promptUncertaintyStore.remove(alias)
            }
            if let persistedCurrent = try promptUncertaintyStore.load(for: current.identity) {
                guard persistedCurrent == current else {
                    hasAmbiguousPromptDelivery = true
                    promptDeliveryUncertaintyHasConfirmedAcceptance = false
                    return false
                }
                try promptUncertaintyStore.remove(current)
            }
            guard promptUncertaintyMarker == current else {
                hasAmbiguousPromptDelivery = true
                return false
            }
            promptUncertaintyMarker = nil
            lastClearedPromptUncertaintyMarker = current
            promptUncertaintyLoadFailed = false
            hasAmbiguousPromptDelivery = false
            promptDeliveryUncertaintyHasConfirmedAcceptance = false
            return true
        } catch {
            // A successful server acknowledgement must not be presented as a
            // retryable failure merely because local cleanup could not finish.
            // Keep the durable barrier and let the next controller reload it.
            // The durable residue must continue blocking stage/submit even
            // when the server ACK already proved acceptance. The companion
            // flag lets the VM explain cleanup residue without saying that
            // delivery itself was unconfirmed.
            hasAmbiguousPromptDelivery = true
            promptDeliveryUncertaintyHasConfirmedAcceptance = !retainBarrierOnFailure
            return false
        }
    }

    private func migratePromptUncertaintyMarkerIfNeeded(to storedID: String) throws {
        guard let marker = promptUncertaintyMarker,
              marker.identity.storedID != storedID else { return }
        let identity: DirectPromptDeliveryUncertaintyIdentity
        do { identity = try promptUncertaintyIdentity(for: storedID) }
        catch { throw DirectSessionError.ambiguousPrompt }
        let migrated = DirectPromptDeliveryUncertaintyMarker(
            token: marker.token,
            identity: identity,
            status: marker.status,
            createdAt: marker.createdAt
        )
        do {
            if let existing = try promptUncertaintyStore.load(for: identity) {
                guard existing.token == marker.token,
                      existing.status == marker.status,
                      existing.createdAt == marker.createdAt else {
                    throw DirectSessionError.ambiguousPrompt
                }
                promptUncertaintyMarker = existing
            } else {
                try promptUncertaintyStore.write(migrated)
                promptUncertaintyMarker = migrated
            }
            // The ancestor remains on disk if removal fails; retaining both
            // aliases is safer than losing the warning during compression.
            try? promptUncertaintyStore.remove(marker)
            hasAmbiguousPromptDelivery = true
            promptDeliveryUncertaintyHasConfirmedAcceptance = false
        } catch let error as DirectSessionError {
            hasAmbiguousPromptDelivery = true
            throw error
        } catch {
            hasAmbiguousPromptDelivery = true
            throw DirectSessionError.ambiguousPrompt
        }
    }

    /// The opened tip may have no exact marker while an ancestor does. Resolve
    /// every valid marker in this origin/profile through the authoritative REST
    /// messages contract before choosing a token or removing any aliases.
    private func resolvePromptUncertaintyLineage(
        requestedID: String,
        canonicalID: String,
        validate: () throws -> Void
    ) async throws {
        let hadLineageFailure = promptLineageResolutionFailed
        let ownedMarker = promptInFlight ? promptUncertaintyMarker : nil
        do {
            let identity = try promptUncertaintyIdentity(for: canonicalID)
            // Retain exact-ID corruption handling even though legacy discovery
            // cannot attribute unreadable records to an origin/profile.
            var exact = try promptUncertaintyStore.load(for: identity)
            let candidates = try promptUncertaintyStore.candidates(for: identity, limit: 64)
            var matching: [DirectPromptDeliveryUncertaintyMarker] = []
            var readAncestor = false
            for candidate in candidates {
                let resolvedID: String
                if candidate.identity.storedID == requestedID || candidate.identity.storedID == canonicalID {
                    resolvedID = canonicalID
                } else {
                    readAncestor = true
                    let page = try await loadTranscript(candidate.identity.storedID, profile, 1, 0)
                    try validate()
                    guard !page.sessionID.isEmpty else { throw DirectSessionError.invalidBinding }
                    resolvedID = page.sessionID
                }
                if resolvedID == canonicalID { matching.append(candidate) }
            }
            if readAncestor {
                let confirmed = try await loadTranscript(canonicalID, profile, 1, 0)
                try validate()
                guard confirmed.sessionID == canonicalID else { throw DirectSessionError.staleOperation }
            }
            try validate()
            // No awaits below: another controller cannot replace a token in the
            // middle of the local write/remove transaction on the main actor.
            let currentCandidates = try promptUncertaintyStore.candidates(for: identity, limit: 64)
            let currentExact = try promptUncertaintyStore.load(for: identity)
            if currentCandidates != candidates || currentExact != exact {
                // An ACK can finish this controller's own submit during an
                // ancestor read. Accept only proven local cleanup of that same
                // marker; every other candidate must remain byte-for-byte equal.
                guard let ownedMarker, let cleared = lastClearedPromptUncertaintyMarker,
                      ownedMarker.token == cleared.token,
                      ownedMarker.status == cleared.status,
                      ownedMarker.createdAt == cleared.createdAt,
                      promptUncertaintyMarker == nil else { throw DirectSessionError.ambiguousPrompt }
                let removed = candidates.filter { candidate in
                    matching.contains(candidate) && candidate.token == ownedMarker.token &&
                        candidate.status == ownedMarker.status && candidate.createdAt == ownedMarker.createdAt &&
                        !currentCandidates.contains(candidate)
                }
                guard !removed.isEmpty,
                      currentCandidates == candidates.filter({ !removed.contains($0) }),
                      currentExact == (exact.map { removed.contains($0) } == true ? nil : exact) else {
                    throw DirectSessionError.ambiguousPrompt
                }
                matching.removeAll { removed.contains($0) }
                exact = currentExact
            }
            if let exact, !matching.contains(exact) { matching.append(exact) }
            if let first = matching.first {
                guard matching.allSatisfy({ $0.token == first.token && $0.status == first.status && $0.createdAt == first.createdAt }) else {
                    throw DirectSessionError.ambiguousPrompt
                }
                let tip = exact ?? DirectPromptDeliveryUncertaintyMarker(
                    token: first.token, identity: identity, status: first.status, createdAt: first.createdAt
                )
                if exact == nil { try promptUncertaintyStore.write(tip) }
                promptUncertaintyMarker = tip
                if !promptInFlight || first.identity != identity { hasAmbiguousPromptDelivery = true }
                for alias in matching where alias.identity != identity {
                    try promptUncertaintyStore.remove(alias)
                }
            }
            promptLineageResolutionFailed = false
            if hadLineageFailure, matching.isEmpty, exact == nil,
               promptUncertaintyMarker == nil, !promptUncertaintyLoadFailed {
                hasAmbiguousPromptDelivery = false
                promptDeliveryUncertaintyHasConfirmedAcceptance = false
            }
        } catch {
            // A superseded read must not poison the replacement conversation.
            try validate()
            promptLineageResolutionFailed = true
            hasAmbiguousPromptDelivery = true
            promptDeliveryUncertaintyHasConfirmedAcceptance = false
            throw error
        }
    }

    /// Clears only the local uncertainty marker after a fresh canonical read
    /// and idle status proof. It never closes, resends, or mutates history.
    func abandonPromptDeliveryUncertainty(expectedToken: UUID) async throws {
        guard !disposed,
              !promptLineageResolutionFailed,
              let marker = promptUncertaintyMarker,
              marker.token == expectedToken,
              let binding,
              !promptUncertaintyAbandonInFlight,
              !promptInFlight,
              !attachmentStageInFlight,
              !attachmentRemovalInFlight,
              !blockingInteractionResponseInFlight,
              pendingBlockingPrompt == nil,
              pendingApprovalPrompt == nil,
              pendingSecretPrompt == nil,
              pendingSudoPrompt == nil,
              runState == .idle || runState == .deliveryUnknown else {
            throw DirectSessionError.staleOperation
        }
        promptUncertaintyAbandonInFlight = true
        defer { promptUncertaintyAbandonInFlight = false }
        let capturedLifecycle = lifecycle
        let capturedBinding = binding
        let capturedGeneration = runtime.connectionGeneration
        let capturedOrigin = runtime.origin
        guard let storedID,
              let identity = try? promptUncertaintyIdentity(for: storedID),
              marker.identity == identity else {
            throw DirectSessionError.staleOperation
        }

        let isCurrentAbandonScope: () -> Bool = {
            guard !self.disposed,
                  self.lifecycle == capturedLifecycle,
                  self.binding == capturedBinding,
                  self.runtime.origin == capturedOrigin,
                  self.runtime.connectionGeneration == capturedGeneration,
                  self.promptUncertaintyAbandonInFlight,
                  self.promptUncertaintyMarker?.token == expectedToken,
                  self.promptUncertaintyMarker?.identity == identity,
                  !self.promptInFlight,
                  !self.attachmentStageInFlight,
                  !self.attachmentRemovalInFlight,
                  !self.blockingResponseInFlight,
                  !self.blockingInteractionResponseInFlight,
                  self.pendingBlockingPrompt == nil,
                  self.pendingApprovalPrompt == nil,
                  self.pendingSecretPrompt == nil,
                  self.pendingSudoPrompt == nil,
                  self.runState == .idle || self.runState == .deliveryUnknown else {
                return false
            }
            do {
                guard let persisted = try self.promptUncertaintyStore.load(for: identity),
                      persisted.token == expectedToken else { return false }
            } catch {
                return false
            }
            return true
        }

        try await refresh()
        guard isCurrentAbandonScope() else {
            throw DirectSessionError.staleOperation
        }
        let status = try await runtime.request("session.status", parameters: {
            guard !self.disposed,
                  self.lifecycle == capturedLifecycle,
                  self.binding == capturedBinding,
                  self.runtime.origin == capturedOrigin,
                  self.runtime.connectionGeneration == capturedGeneration,
                  self.runState == .idle || self.runState == .deliveryUnknown,
                  !self.promptInFlight else {
                throw DirectSessionError.staleOperation
            }
            return self.rpcParams(capturedBinding)
        })
        guard isCurrentAbandonScope() else {
            throw DirectSessionError.staleOperation
        }
        guard status?.gatewayFields["output"]?.gatewayString?
            .components(separatedBy: .newlines)
            .contains("Agent Running: No") == true else {
            throw DirectSessionError.ambiguousPrompt
        }
        do {
            try promptUncertaintyStore.remove(marker)
        } catch {
            throw DirectPromptDeliveryUncertaintyError.persistenceUnavailable
        }
        // No await occurs between the scope check and the token-checked local
        // removal, so the in-memory token is still the one just removed.
        guard promptUncertaintyMarker?.token == expectedToken else {
            throw DirectSessionError.staleOperation
        }
        promptUncertaintyMarker = nil
        promptUncertaintyLoadFailed = false
        hasAmbiguousPromptDelivery = false
        promptDeliveryUncertaintyHasConfirmedAcceptance = false
        runState = .idle
    }

    private func markRecoveryMarker(_ marker: DirectGatewayAttachmentRecoveryMarker) {
        recoveryMarker = marker
        recoveryMarkerLoadFailed = false
        recoveryStageUnknown = false
        attachmentRecoveryNeedsReset = false
        unresolvedAttachmentMarkerToken = marker.token
    }

    private func markRecoveryStageUnknownIfNeeded(_ kind: DirectGatewayAttachmentKind) {
        guard kind != .file else { return }
        recoveryStageUnknown = true
        attachmentRecoveryNeedsReset = true
    }

    private func clearRecoveryMarker(_ marker: DirectGatewayAttachmentRecoveryMarker) throws {
        try recoveryMarkerStore.remove(marker)
        guard recoveryMarker?.token == marker.token else {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.tokenMismatch
        }
        recoveryMarker = nil
        recoveryMarkerLoadFailed = false
        attachmentRecoveryNeedsReset = false
        unresolvedAttachmentMarkerToken = nil
        locallyConfirmedRecoveryStageCount = 0
        recoveryDetachPaths.removeAll()
        recoveryStageUnknown = false
    }

    private func persistRecoveryMarkerIfNeeded() throws -> (marker: DirectGatewayAttachmentRecoveryMarker, created: Bool) {
        if let recoveryMarker { return (recoveryMarker, false) }
        guard !recoveryMarkerLoadFailed else {
            throw DirectSessionError.attachmentRecoveryUnavailable
        }
        let marker = DirectGatewayAttachmentRecoveryMarker(identity: try currentRecoveryIdentity())
        do { try recoveryMarkerStore.write(marker) }
        catch {
            recoveryMarkerLoadFailed = true
            attachmentRecoveryNeedsReset = true
            throw DirectSessionError.attachmentRecoveryUnavailable
        }
        markRecoveryMarker(marker)
        return (marker, true)
    }

    private func discardRecoveryStateAfterReset(_ marker: DirectGatewayAttachmentRecoveryMarker?) {
        if let marker { try? recoveryMarkerStore.remove(marker) }
        recoveryMarker = nil
        recoveryMarkerLoadFailed = false
        recoveryStageUnknown = false
        attachmentRecoveryNeedsReset = false
        unresolvedAttachmentMarkerToken = nil
        locallyConfirmedRecoveryStageCount = 0
        recoveryDetachPaths.removeAll()
        recoveryPromptObservation = nil
    }

    private func draftRuntimeWasProvenClosed(
        binding: GatewaySessionBinding,
        lifecycle expectedLifecycle: Int,
        origin expectedOrigin: URL,
        generation expectedGeneration: Int
    ) async throws -> Bool {
        do {
            let result = try await runtime.request("session.status", parameters: {
                guard !self.disposed,
                      self.lifecycle == expectedLifecycle,
                      self.binding == binding,
                      self.runtime.origin == expectedOrigin,
                      self.runtime.connectionGeneration == expectedGeneration,
                      self.runtime.state == .ready,
                      self.runState == .idle else {
                    throw DirectSessionError.staleOperation
                }
                return self.rpcParams(binding)
            })
            _ = result
            return false
        } catch let error as HermesGatewayError {
            guard !disposed,
                  lifecycle == expectedLifecycle,
                  self.binding == binding,
                  runtime.origin == expectedOrigin,
                  runtime.connectionGeneration == expectedGeneration,
                  runtime.state == .ready,
                  runState == .idle else {
                throw DirectSessionError.staleOperation
            }
            guard case .server(let code, _, _, let method, _, _) = error,
                  method == "session.status" else { return false }
            return code == 4001
        }
    }

    private func rebindAfterAttachmentReset(
        oldBinding: GatewaySessionBinding,
        lifecycle expectedLifecycle: Int,
        origin expectedOrigin: URL,
        marker: DirectGatewayAttachmentRecoveryMarker?
    ) async throws {
        guard !disposed, lifecycle == expectedLifecycle,
              runtime.origin == expectedOrigin else {
            throw DirectSessionError.staleOperation
        }
        invalidateBinding()
        do { try await ensureBinding(create: [:]) }
        catch { throw DirectSessionError.attachmentRecoveryUnavailable }
        guard !disposed,
              lifecycle == expectedLifecycle,
              runtime.origin == expectedOrigin,
              runtime.state == .ready,
              let rebound = binding,
              rebound.profile == profile,
              rebound.runtimeID != oldBinding.runtimeID else {
            throw DirectSessionError.attachmentRecoveryUnavailable
        }
        // A different runtime can already carry its own unresolved marker.
        // Runtime-ID change alone is not authority to clear that quarantine.
        // Inspect only the rebound runtime key before discarding old-runtime
        // state; a marker or read failure keeps recovery blocked on B.
        let reboundIdentity = try currentRecoveryIdentity()
        do {
            guard try recoveryMarkerStore.load(for: reboundIdentity) == nil else {
                throw DirectSessionError.unresolvedAttachment
            }
        } catch let error as DirectSessionError {
            throw error
        } catch {
            throw DirectSessionError.attachmentRecoveryUnavailable
        }
        // A distinct stock runtime has a fresh in-memory attachment queue.
        // Only now may the VM discard its old staged receipts. A corrupt or
        // otherwise undeletable old marker is harmless because it is keyed to
        // the closed runtime ID and is deliberately left on disk.
        discardRecoveryStateAfterReset(marker)
        turnEpoch &+= 1
    }

    /// Opening a local draft does not create a backend session.
    func open() async throws {
        guard !disposed else { throw DirectSessionError.stopped }
        guard !branchInFlight else { throw DirectSessionError.ambiguousPrompt }
        guard storedID != nil, hasSubmittedPrompt else { return }
        try await ensureBinding(create: [:])
    }

    /// Gives `/goal` a canonical runtime binding without submitting a prompt.
    /// This remains separate from `open()`, whose draft behavior is unchanged.
    func prepareGoalSession(create: [String: JSONValue]) async throws -> GatewaySessionBinding {
        guard !goalPreparationOutcomeUnknown else { throw DirectGoalError.outcomeUnknown }
        guard !disposed, !branchInFlight, runState == .idle, !promptInFlight,
              !attachmentStageInFlight, !attachmentRemovalInFlight,
              !hasAmbiguousPromptDelivery else {
            throw DirectSessionError.invalidBinding
        }
        let wasDraftCreate = storedID == nil && !hasSubmittedPrompt
        let capturedLifecycle = lifecycle
        let capturedTurn = turnEpoch
        let capturedOrigin = runtime.origin
        do {
            try await ensureBinding(create: create)
        } catch {
            if wasDraftCreate, binding == nil {
                let definiteCreateRefusal: Bool
                if case HermesGatewayError.server(_, _, _, let method, _, _) = error {
                    definiteCreateRefusal = method == "session.create"
                } else {
                    definiteCreateRefusal = false
                }
                if !definiteCreateRefusal { goalPreparationOutcomeUnknown = true }
            }
            throw goalPreparationOutcomeUnknown ? DirectGoalError.outcomeUnknown : error
        }
        guard !disposed, lifecycle == capturedLifecycle, turnEpoch == capturedTurn,
              runtime.origin == capturedOrigin, runtime.state == .ready,
              runState == .idle, !promptInFlight, !attachmentStageInFlight,
              !attachmentRemovalInFlight, let binding, binding.profile == profile,
              storedID == binding.storedID else {
            if wasDraftCreate { goalPreparationOutcomeUnknown = true }
            throw wasDraftCreate ? DirectGoalError.outcomeUnknown : DirectSessionError.staleOperation
        }
        return binding
    }

    /// Creates a full-session child on the already-owned gateway socket.
    /// `session.branch` returns a live child runtime; the child controller is
    /// therefore adopted directly and must not resume or create another one.
    /// The parent remains bound and is never mutated by this operation.
    func branch(name rawName: String = "") async throws -> GatewayConversationController {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !disposed,
              !compressionOutcomeUnknown,
              !branchOutcomeUnknown,
              !branchInFlight,
              hasSubmittedPrompt,
              let capturedBinding = binding,
              let storedID,
              storedID == capturedBinding.storedID,
              capturedBinding.profile == profile,
              runState == .idle,
              !promptInFlight,
              !hasAmbiguousPromptDelivery,
              !promptUncertaintyLoadFailed,
              !attachmentRecoveryIsBusy,
              !attachmentStageInFlight,
              !attachmentRemovalInFlight,
              recoveryMarker == nil,
              !recoveryMarkerLoadFailed,
              !recoveryStageUnknown,
              pendingBlockingPrompt == nil,
              pendingApprovalPrompt == nil,
              pendingSecretPrompt == nil,
              pendingSudoPrompt == nil,
              !blockingResponseInFlight,
              !blockingInteractionResponseInFlight,
              reasoningMutationCount == 0,
              pendingReasoningEffort == nil,
              ambiguousReasoningEffort == nil,
              runtime.state == .ready else {
            throw DirectSessionError.ambiguousPrompt
        }

        let capturedLifecycle = lifecycle
        let capturedBindingEpoch = bindingEpoch
        let capturedConnectionGeneration = runtime.connectionGeneration
        let capturedOrigin = runtime.origin
        branchInFlight = true
        var requestWasDispatched = false
        var childController: GatewayConversationController?
        var knownChildBinding: GatewaySessionBinding?
        var handoffCompleted = false
        defer { branchInFlight = false }

        do {
            try await runtime.withSessionEventsPaused {
                guard self.isCurrentBranchScope(
                    binding: capturedBinding,
                    lifecycle: capturedLifecycle,
                    bindingEpoch: capturedBindingEpoch,
                    connectionGeneration: capturedConnectionGeneration,
                    origin: capturedOrigin
                ) else {
                    throw DirectSessionError.staleOperation
                }

                let result = try await runtime.request("session.branch", parameters: {
                    guard self.isCurrentBranchScope(
                        binding: capturedBinding,
                        lifecycle: capturedLifecycle,
                        bindingEpoch: capturedBindingEpoch,
                        connectionGeneration: capturedConnectionGeneration,
                        origin: capturedOrigin
                    ) else {
                        throw DirectSessionError.staleOperation
                    }
                    requestWasDispatched = true
                    var parameters: [String: JSONValue] = [
                        "session_id": .string(capturedBinding.runtimeID),
                        "profile": .string(profile)
                    ]
                    if !name.isEmpty { parameters["name"] = .string(name) }
                    return parameters
                })

                // Parse the child identity before any post-ACK scope guard so a
                // later parent rebind can still attempt cleanup of a child that
                // is known to belong to this branch request.
                let childBinding = try branchBinding(
                    from: result,
                    parent: capturedBinding
                )
                knownChildBinding = childBinding
                guard self.isCurrentBranchScope(
                    binding: capturedBinding,
                    lifecycle: capturedLifecycle,
                    bindingEpoch: capturedBindingEpoch,
                    connectionGeneration: capturedConnectionGeneration,
                    origin: capturedOrigin
                ) else {
                    throw DirectSessionError.staleOperation
                }

                let child = try makeBranchedController(childBinding)
                childController = child
                // Verify the returned child through the existing canonical
                // transcript loader before exposing it to the caller.
                try await child.refresh()
                guard child.binding == childBinding,
                      child.storedID == childBinding.storedID,
                      self.isCurrentBranchScope(
                          binding: capturedBinding,
                          lifecycle: capturedLifecycle,
                          bindingEpoch: capturedBindingEpoch,
                          connectionGeneration: capturedConnectionGeneration,
                          origin: capturedOrigin
                      ) else {
                    throw DirectSessionBranchError.invalidResponse
                }
            }

            // `withSessionEventsPaused` drains buffered events in its defer
            // before returning here. Revalidate both sides after that drain so
            // an event-driven rebind cannot turn the already-validated child
            // into a stale handoff.
            guard let childController,
                  let knownChildBinding,
                  childController.binding == knownChildBinding,
                  childController.storedID == knownChildBinding.storedID,
                  isCurrentBranchScope(
                      binding: capturedBinding,
                      lifecycle: capturedLifecycle,
                      bindingEpoch: capturedBindingEpoch,
                      connectionGeneration: capturedConnectionGeneration,
                      origin: capturedOrigin
                  ) else {
                throw DirectSessionBranchError.invalidResponse
            }
            handoffCompleted = true
            return childController
        } catch let error as HermesGatewayError {
            if !requestWasDispatched || Self.isDefinitiveBranchRefusal(error) {
                throw error
            }
            if let knownChildBinding {
                childController?.invalidate()
                _ = await closeKnownBranchChild(
                    knownChildBinding,
                    parentBinding: capturedBinding,
                    lifecycle: capturedLifecycle,
                    connectionGeneration: capturedConnectionGeneration
                )
            }
            branchOutcomeUnknown = true
            throw DirectSessionBranchError.outcomeUnknown
        } catch let error as DirectSessionBranchError {
            if requestWasDispatched, !handoffCompleted,
               let knownChildBinding {
                childController?.invalidate()
                _ = await closeKnownBranchChild(
                    knownChildBinding,
                    parentBinding: capturedBinding,
                    lifecycle: capturedLifecycle,
                    connectionGeneration: capturedConnectionGeneration
                )
            }
            if case .outcomeUnknown = error {
                branchOutcomeUnknown = true
            } else if requestWasDispatched {
                branchOutcomeUnknown = true
            }
            if requestWasDispatched, !handoffCompleted {
                throw DirectSessionBranchError.outcomeUnknown
            }
            throw error
        } catch {
            if !requestWasDispatched {
                throw error
            }
            if !handoffCompleted, let knownChildBinding {
                childController?.invalidate()
                _ = await closeKnownBranchChild(
                    knownChildBinding,
                    parentBinding: capturedBinding,
                    lifecycle: capturedLifecycle,
                    connectionGeneration: capturedConnectionGeneration
                )
            }
            branchOutcomeUnknown = true
            throw DirectSessionBranchError.outcomeUnknown
        }
    }

    func compress(focusTopic: String = "") async throws -> CompressionOutcome {
        guard hasSubmittedPrompt, !branchInFlight, !compressionOutcomeUnknown,
              let capturedBinding = binding else { throw DirectSessionError.ambiguousPrompt }
        let capturedLifecycle = lifecycle
        let capturedEpoch = bindingEpoch
        let capturedGeneration = runtime.connectionGeneration
        let capturedOrigin = runtime.origin
        func checkScope() throws {
            guard isCurrentBranchScope(binding: capturedBinding, lifecycle: capturedLifecycle,
                                       bindingEpoch: capturedEpoch, connectionGeneration: capturedGeneration,
                                       origin: capturedOrigin), pendingReasoningEffort == nil,
                  ambiguousReasoningEffort == nil else { throw DirectSessionError.staleOperation }
        }
        try checkScope()
        branchInFlight = true
        defer { branchInFlight = false }
        var dispatched = false
        var outcome: CompressionOutcome?
        do {
            try await runtime.withSessionEventsPaused {
                let result = try await runtime.request("session.compress", parameters: {
                    try checkScope()
                    dispatched = true
                    var params = self.rpcParams(capturedBinding)
                    let focus = focusTopic.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !focus.isEmpty { params["focus_topic"] = .string(focus) }
                    return params
                })
                try checkScope()
                guard case .object(let fields) = result else { throw DirectSessionCompressionError.invalidResponse }
                if fields["compressed"] == .bool(false), fields["lock_held"] == .bool(true) {
                    outcome = .lockSkipped
                    return
                }
                guard let status = fields["status"]?.gatewayString,
                      status == "compressed" || status == "aborted",
                      let info = fields["info"]?.gatewayFields,
                      info["profile_name"]?.gatewayString == self.profile,
                      let durableID = info["stored_session_id"]?.gatewayString,
                      !durableID.isEmpty,
                      let summary = fields["summary"]?.gatewayFields,
                      case .bool(let noop) = summary["noop"],
                      case .bool(let aborted) = summary["aborted"],
                      aborted == (status == "aborted") else {
                    throw DirectSessionCompressionError.invalidResponse
                }
                // REST resolves the ancestor first. Only its matching durable
                // identity authorizes reusing the runtime that stock reanchors.
                try await self.refresh()
                guard !self.disposed, self.lifecycle == capturedLifecycle,
                      self.runtime.origin == capturedOrigin,
                      self.runtime.connectionGeneration == capturedGeneration,
                      self.runtime.state == .ready, self.storedID == durableID else {
                    throw DirectSessionCompressionError.invalidResponse
                }
                try self.adopt(GatewaySessionBinding(storedID: durableID, runtimeID: capturedBinding.runtimeID, profile: self.profile))
                outcome = aborted ? .aborted : (noop ? .unchanged : .compressed)
            }
            guard let outcome, !disposed, lifecycle == capturedLifecycle,
                  runtime.connectionGeneration == capturedGeneration,
                  runtime.state == .ready, binding?.runtimeID == capturedBinding.runtimeID,
                  binding?.storedID == storedID else { throw DirectSessionCompressionError.invalidResponse }
            return outcome
        } catch {
            if !dispatched { throw error }
            if case HermesGatewayError.server(let code, _, _, let method, _, _) = error,
               method == "session.compress", code == 4001 {
                throw error
            }
            compressionOutcomeUnknown = true
            invalidateBinding()
            throw DirectSessionCompressionError.outcomeUnknown
        }
    }

    private func isCurrentBranchScope(
        binding: GatewaySessionBinding,
        lifecycle expectedLifecycle: Int,
        bindingEpoch expectedBindingEpoch: Int,
        connectionGeneration expectedConnectionGeneration: Int,
        origin expectedOrigin: URL
    ) -> Bool {
        !disposed
            && !branchOutcomeUnknown
            && self.binding == binding
            && storedID == binding.storedID
            && binding.profile == profile
            && lifecycle == expectedLifecycle
            && bindingEpoch == expectedBindingEpoch
            && runtime.origin == expectedOrigin
            && runtime.connectionGeneration == expectedConnectionGeneration
            && runtime.state == .ready
            && runState == .idle
            && !promptInFlight
            && !hasAmbiguousPromptDelivery
            && !promptUncertaintyLoadFailed
            && !attachmentRecoveryIsBusy
            && !attachmentStageInFlight
            && !attachmentRemovalInFlight
            && recoveryMarker == nil
            && !recoveryMarkerLoadFailed
            && !recoveryStageUnknown
            && pendingBlockingPrompt == nil
            && pendingApprovalPrompt == nil
            && pendingSecretPrompt == nil
            && pendingSudoPrompt == nil
            && !blockingResponseInFlight
            && !blockingInteractionResponseInFlight
            && reasoningMutationCount == 0
    }

    private func branchBinding(
        from result: JSONValue?,
        parent: GatewaySessionBinding
    ) throws -> GatewaySessionBinding {
        guard case .object(let fields) = result,
              fields["parent"]?.gatewayString == parent.storedID,
              let messageCount = fields["message_count"],
              case .number(let count) = messageCount,
              count.isFinite,
              count > 0,
              count.rounded() == count,
              let infoProfile = fields["info"]?.gatewayFields["profile_name"]?.gatewayString,
              infoProfile == profile else {
            throw DirectSessionBranchError.invalidResponse
        }
        let child = try GatewaySessionBinding.resolve(result, profile: profile)
        guard child.storedID != parent.storedID,
              child.runtimeID != parent.runtimeID,
              child.profile == profile else {
            throw DirectSessionBranchError.invalidResponse
        }
        return child
    }

    private func makeBranchedController(
        _ childBinding: GatewaySessionBinding
    ) throws -> GatewayConversationController {
        let child = GatewayConversationController(
            runtime: runtime,
            storedID: childBinding.storedID,
            profile: profile,
            recoveryMarkerStore: recoveryMarkerStore,
            promptUncertaintyStore: promptUncertaintyStore,
            loadTranscript: loadTranscript
        )
        try child.adopt(childBinding)
        return child
    }

    private func closeKnownBranchChild(
        _ childBinding: GatewaySessionBinding,
        parentBinding: GatewaySessionBinding,
        lifecycle expectedLifecycle: Int,
        connectionGeneration expectedConnectionGeneration: Int
    ) async -> Bool {
        guard !disposed,
              lifecycle == expectedLifecycle,
              binding == parentBinding,
              storedID == parentBinding.storedID,
              parentBinding.profile == profile,
              runtime.connectionGeneration == expectedConnectionGeneration,
              runtime.state == .ready else {
            return false
        }
        do {
            let result = try await runtime.request("session.close", parameters: {
                guard !self.disposed,
                      self.lifecycle == expectedLifecycle,
                      self.binding == parentBinding,
                      self.storedID == parentBinding.storedID,
                      parentBinding.profile == self.profile,
                      self.runtime.connectionGeneration == expectedConnectionGeneration,
                      self.runtime.state == .ready else {
                    throw DirectSessionError.staleOperation
                }
                return [
                    "session_id": .string(childBinding.runtimeID),
                    "profile": .string(childBinding.profile)
                ]
            })
            return result?.gatewayFields["closed"] == .bool(true)
        } catch {
            return false
        }
    }

    private static func isDefinitiveBranchRefusal(_ error: HermesGatewayError) -> Bool {
        guard case .server(let code, _, _, let method, _, _) = error,
              method == "session.branch" else { return false }
        // 4001 is a missing runtime and 4008 is the handler's empty-history
        // refusal; neither can have created a child.  5008 is deliberately
        // excluded because the handler may fail after child persistence.
        return code == 4001 || code == 4008
    }

    /// Explicitly abandons only the live runtime carrying an unresolved
    /// attachment marker. The caller owns user confirmation and warning text.
    /// Durable transcript rows are retained by stock `session.close`; the
    /// next `open()` resumes that stored conversation with a fresh runtime.
    func resetPendingAttachments(expectedToken: UUID? = nil) async throws {
        guard !disposed else { throw DirectSessionError.stopped }
        guard !compressionOutcomeUnknown else { throw DirectSessionCompressionError.outcomeUnknown }
        guard !branchInFlight else { throw DirectSessionError.ambiguousPrompt }
        guard recoveryMarker != nil || recoveryMarkerLoadFailed else {
            throw DirectSessionError.unresolvedAttachment
        }
        if let expectedToken {
            guard recoveryMarker?.token == expectedToken else {
                throw DirectSessionError.staleOperation
            }
        }
        let marker = recoveryMarker
        guard !attachmentRecoveryIsBusy,
              !attachmentStageInFlight,
              !attachmentRemovalInFlight,
              !promptInFlight,
              !hasAmbiguousPromptDelivery,
              runState == .idle,
              let capturedBinding = binding else {
            throw DirectSessionError.ambiguousPrompt
        }
        let identity = try currentRecoveryIdentity()
        if let marker {
            guard marker.identity.origin == identity.origin,
                  marker.identity.profile == identity.profile,
                  marker.identity.runtimeID == identity.runtimeID else {
                throw DirectSessionError.staleOperation
            }
        }
        guard runtime.state == .ready else {
            throw DirectSessionError.staleOperation
        }
        let wasDurable = hasSubmittedPrompt && storedID != nil
        let capturedLifecycle = lifecycle
        let capturedGeneration = runtime.connectionGeneration
        let capturedOrigin = runtime.origin
        attachmentRecoveryIsBusy = true
        defer { attachmentRecoveryIsBusy = false }

        var closeWasDispatched = false
        let closeResult: JSONValue?
        do {
            closeResult = try await runtime.request("session.close", parameters: {
                guard !self.disposed,
                      self.lifecycle == capturedLifecycle,
                      self.binding == capturedBinding,
                      self.runtime.origin == capturedOrigin,
                      self.runtime.connectionGeneration == capturedGeneration,
                      self.runtime.state == .ready,
                      self.runState == .idle,
                      marker == nil
                        ? self.recoveryMarkerLoadFailed
                        : self.recoveryMarker?.token == marker?.token else {
                    throw DirectSessionError.staleOperation
                }
                closeWasDispatched = true
                // Once the close is actually dispatched, the previous
                // in-memory stage is no longer safe to treat as reusable.
                // Keep the quarantine visible until a fresh-runtime proof
                // completes, including a failed/same-runtime rebind.
                self.attachmentRecoveryNeedsReset = true
                return self.rpcParams(capturedBinding)
            })
        } catch {
            guard closeWasDispatched else { throw error }
            if wasDurable {
                try await rebindAfterAttachmentReset(
                    oldBinding: capturedBinding,
                    lifecycle: capturedLifecycle,
                    origin: capturedOrigin,
                    marker: marker
                )
                return
            }
            if try await draftRuntimeWasProvenClosed(
                binding: capturedBinding,
                lifecycle: capturedLifecycle,
                origin: capturedOrigin,
                generation: capturedGeneration
            ) {
                discardRecoveryStateAfterReset(marker)
                invalidateBinding()
                turnEpoch &+= 1
                return
            }
            throw DirectSessionError.attachmentRecoveryUnavailable
        }

        guard !disposed,
              lifecycle == capturedLifecycle,
              binding == capturedBinding,
              runtime.origin == capturedOrigin,
              runtime.connectionGeneration == capturedGeneration else {
            throw DirectSessionError.staleOperation
        }
        guard closeResult?.gatewayFields["closed"] == .bool(true) else {
            if wasDurable {
                try await rebindAfterAttachmentReset(
                    oldBinding: capturedBinding,
                    lifecycle: capturedLifecycle,
                    origin: capturedOrigin,
                    marker: marker
                )
                return
            }
            if try await draftRuntimeWasProvenClosed(
                binding: capturedBinding,
                lifecycle: capturedLifecycle,
                origin: capturedOrigin,
                generation: capturedGeneration
            ) {
                discardRecoveryStateAfterReset(marker)
                invalidateBinding()
                turnEpoch &+= 1
                return
            }
            throw DirectSessionError.attachmentRecoveryUnavailable
        }
        if wasDurable {
            try await rebindAfterAttachmentReset(
                oldBinding: capturedBinding,
                lifecycle: capturedLifecycle,
                origin: capturedOrigin,
                marker: marker
            )
        } else {
            discardRecoveryStateAfterReset(marker)
            invalidateBinding()
            recoveryPromptObservation = nil
            turnEpoch &+= 1
        }
    }

    /// Removes one locally confirmed image/PDF stage from the exact idle turn
    /// that produced its receipt. Generic files have no pinned detach route;
    /// unknown or stale receipts remain quarantined and are never guessed.
    func removeStagedAttachment(_ pending: DirectPendingAttachment) async throws {
        guard !disposed else { throw DirectSessionError.stopped }
        guard !compressionOutcomeUnknown else { throw DirectSessionCompressionError.outcomeUnknown }
        guard !branchInFlight else { throw DirectSessionError.ambiguousPrompt }
        guard pending.source.kind != .file else { throw DirectSessionError.invalidResponse }
        guard !hasAmbiguousPromptDelivery,
              !recoveryMarkerLoadFailed,
              !recoveryStageUnknown,
              !attachmentRecoveryIsBusy,
              !attachmentStageInFlight,
              !attachmentRemovalInFlight,
              !promptInFlight,
              recoveryCleanupTask == nil,
              recoveryPromptObservation == nil,
              runState == .idle,
              let marker = recoveryMarker,
              let capturedBinding = binding else {
            throw DirectSessionError.unresolvedAttachment
        }

        let capturedLifecycle = lifecycle
        let capturedGeneration = runtime.connectionGeneration
        let capturedOrigin = runtime.origin
        let scope = DirectPendingAttachmentStageScope(
            binding: capturedBinding,
            connectionGeneration: capturedGeneration,
            origin: capturedOrigin,
            turnEpoch: turnEpoch
        )
        let paths = pending.serverDetachPaths(for: scope)
        guard pending.isConfirmed(for: scope), !paths.isEmpty else {
            throw DirectSessionError.staleOperation
        }

        var remainingPaths = recoveryDetachPaths
        for path in paths {
            guard let index = remainingPaths.firstIndex(of: path) else {
                throw DirectSessionError.staleOperation
            }
            remainingPaths.remove(at: index)
        }
        guard locallyConfirmedRecoveryStageCount > 0 else {
            throw DirectSessionError.staleOperation
        }

        attachmentRemovalInFlight = true
        attachmentRecoveryIsBusy = true
        defer {
            attachmentRemovalInFlight = false
            attachmentRecoveryIsBusy = false
        }

        let isCurrentRemovalScope: () -> Bool = {
            !self.disposed
                && self.lifecycle == capturedLifecycle
                && self.binding == capturedBinding
                && self.runtime.origin == capturedOrigin
                && self.runtime.connectionGeneration == capturedGeneration
                && self.recoveryMarker?.token == marker.token
        }

        let status = try await runtime.request("session.status", parameters: {
            guard isCurrentRemovalScope(),
                  self.runtime.state == .ready,
                  self.runState == .idle else {
                throw DirectSessionError.staleOperation
            }
            return self.rpcParams(capturedBinding)
        })
        guard isCurrentRemovalScope(),
              status?.gatewayFields["output"]?.gatewayString?
                .components(separatedBy: .newlines)
                .contains("Agent Running: No") == true else {
            throw DirectSessionError.ambiguousPrompt
        }

        var acknowledgedPaths = 0
        do {
            for path in paths {
                var requestWasDispatched = false
                do {
                    let result = try await runtime.request("image.detach", parameters: {
                        guard !self.disposed,
                              self.lifecycle == capturedLifecycle,
                              self.binding == capturedBinding,
                              self.runtime.origin == capturedOrigin,
                              self.runtime.connectionGeneration == capturedGeneration,
                              self.runtime.state == .ready,
                              self.runState == .idle,
                              self.recoveryMarker?.token == marker.token else {
                            throw DirectSessionError.staleOperation
                        }
                        requestWasDispatched = true
                        return [
                            "session_id": .string(capturedBinding.runtimeID),
                            "profile": .string(capturedBinding.profile),
                            "path": .string(path)
                        ]
                    })
                    guard result?.gatewayFields["detached"] == .bool(true) else {
                        throw DirectSessionError.invalidResponse
                    }
                    acknowledgedPaths += 1
                } catch {
                    // A dispatched detach, or a partial PDF detach, no longer
                    // has a safely replayable local receipt. Keep the marker
                    // and chip visible; explicit reset remains the escape hatch.
                    if (requestWasDispatched || acknowledgedPaths > 0), isCurrentRemovalScope() {
                        recoveryStageUnknown = true
                        attachmentRecoveryNeedsReset = true
                    }
                    throw error
                }
            }

            guard !disposed,
                  lifecycle == capturedLifecycle,
                  binding == capturedBinding,
                  runtime.origin == capturedOrigin,
                  runtime.connectionGeneration == capturedGeneration,
                  runtime.state == .ready,
                  runState == .idle,
                  recoveryMarker?.token == marker.token else {
                throw DirectSessionError.staleOperation
            }

            recoveryDetachPaths = remainingPaths
            locallyConfirmedRecoveryStageCount -= 1
            if locallyConfirmedRecoveryStageCount == 0, recoveryDetachPaths.isEmpty {
                do {
                    try clearRecoveryMarker(marker)
                } catch {
                    recoveryStageUnknown = true
                    attachmentRecoveryNeedsReset = true
                    throw DirectSessionError.attachmentRecoveryUnavailable
                }
            }
        } catch {
            if acknowledgedPaths > 0, isCurrentRemovalScope() {
                recoveryStageUnknown = true
                attachmentRecoveryNeedsReset = true
            }
            throw error
        }
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
        guard !branchInFlight, !compressionOutcomeUnknown else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: pending.source.kind,
                reason: .controllerBusy
            )
        }
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
        guard !recoveryMarkerLoadFailed else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .recoveryMarkerUnavailable
            )
        }
        // Report the actual in-flight operation before the marker barrier.
        // The first stage may have persisted its marker while its RPC is
        // suspended; a concurrent tap is a local busy rejection, not a
        // recovery-quarantine result.
        guard !attachmentStageInFlight,
              !attachmentRemovalInFlight,
              !promptInFlight,
              runState == .idle else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .controllerBusy
            )
        }
        guard !recoveryMarkerLoadFailed,
              !recoveryStageUnknown,
              !attachmentRecoveryIsBusy,
              recoveryMarker == nil || locallyConfirmedRecoveryStageCount > 0 else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .unresolvedAttachment
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
        guard !recoveryStageUnknown,
              !attachmentRecoveryIsBusy,
              recoveryMarker == nil || locallyConfirmedRecoveryStageCount > 0 else {
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .unresolvedAttachment
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
        var markerCreatedForThisStage = false
        if kind != .file {
            do {
                let markerResult = try persistRecoveryMarkerIfNeeded()
                markerCreatedForThisStage = markerResult.created
            } catch let error as DirectSessionError {
                throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                    kind: kind,
                    reason: error == .attachmentRecoveryUnavailable
                        ? .recoveryMarkerUnavailable
                        : .staleBeforeDispatch
                )
            }
        }

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

            if kind != .file {
                locallyConfirmedRecoveryStageCount += 1
                recoveryDetachPaths.append(contentsOf: receipt.detachPaths)
            }
            return DirectGatewayAttachmentStageResult(scope: scope, receipt: receipt)
        } catch let error as DirectGatewayAttachmentStageError {
            if case .unknown = error {
                markRecoveryStageUnknownIfNeeded(kind)
            }
            if markerCreatedForThisStage,
               locallyConfirmedRecoveryStageCount == 0,
               case .definiteBeforeStage = error {
                if let marker = recoveryMarker {
                    try? clearRecoveryMarker(marker)
                }
            }
            throw error
        } catch let error as HermesGatewayError {
            if case .server(let code, let message, _, let serverMethod, _, _) = error,
               requestWasDispatched,
               serverMethod == method,
               Self.isDefiniteAttachmentRejection(kind: kind, method: method, code: code) {
                if markerCreatedForThisStage,
                   locallyConfirmedRecoveryStageCount == 0,
                   let marker = recoveryMarker {
                    try? clearRecoveryMarker(marker)
                }
                throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                    kind: kind,
                    reason: .serverRejected(code: code, message: message)
                )
            }

            guard requestWasDispatched else {
                if markerCreatedForThisStage,
                   locallyConfirmedRecoveryStageCount == 0,
                   let marker = recoveryMarker {
                    try? clearRecoveryMarker(marker)
                }
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
                markRecoveryStageUnknownIfNeeded(kind)
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .cancelledAfterDispatch
                )
            }

            markRecoveryStageUnknownIfNeeded(kind)
            throw DirectGatewayAttachmentStageError.unknown(
                kind: kind,
                scope: scope,
                reason: Self.attachmentUnknownReason(for: error)
            )
        } catch is CancellationError {
            if requestWasDispatched {
                markRecoveryStageUnknownIfNeeded(kind)
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .cancelledAfterDispatch
                )
            }
            if markerCreatedForThisStage,
               locallyConfirmedRecoveryStageCount == 0,
               let marker = recoveryMarker {
                try? clearRecoveryMarker(marker)
            }
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .cancelledBeforeDispatch
            )
        } catch is DirectSessionError {
            if requestWasDispatched {
                markRecoveryStageUnknownIfNeeded(kind)
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .staleAfterDispatch
                )
            }
            if markerCreatedForThisStage,
               locallyConfirmedRecoveryStageCount == 0,
               let marker = recoveryMarker {
                try? clearRecoveryMarker(marker)
            }
            throw DirectGatewayAttachmentStageError.definiteBeforeStage(
                kind: kind,
                reason: .staleBeforeDispatch
            )
        } catch {
            if requestWasDispatched {
                markRecoveryStageUnknownIfNeeded(kind)
                throw DirectGatewayAttachmentStageError.unknown(
                    kind: kind,
                    scope: scope,
                    reason: .transport
                )
            }
            if markerCreatedForThisStage,
               locallyConfirmedRecoveryStageCount == 0,
               let marker = recoveryMarker {
                try? clearRecoveryMarker(marker)
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
        create: [String: JSONValue] = [:],
        destructiveTarget: DestructivePromptTarget? = nil
    ) async throws {
        guard !compressionOutcomeUnknown else { throw DirectSessionCompressionError.outcomeUnknown }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DirectSessionError.invalidResponse }
        if let destructiveTarget {
            guard destructiveTarget.userRowID > 0,
                  Double(exactly: destructiveTarget.userRowID) != nil,
                  destructiveTarget.userOrdinal.map({ $0 >= 0 }) ?? true else {
                throw DirectSessionError.staleOperation
            }
        }
        let destructiveEntryBinding = destructiveTarget == nil ? nil : binding
        let destructiveEntryLifecycle = lifecycle
        let destructiveEntryOrigin = runtime.origin
        let destructiveEntryConnectionGeneration = runtime.connectionGeneration
        if destructiveTarget != nil {
            guard let destructiveEntryBinding,
                  destructiveEntryBinding.profile == profile,
                  runtime.state == .ready else {
                throw DirectSessionError.invalidBinding
            }
        }
        guard !branchInFlight else { throw DirectSessionError.ambiguousPrompt }
        guard !promptUncertaintyLoadFailed else { throw DirectSessionError.staleOperation }
        guard !hasAmbiguousPromptDelivery else { throw DirectSessionError.ambiguousPrompt }
        guard !recoveryMarkerLoadFailed else { throw DirectSessionError.attachmentRecoveryUnavailable }
        guard !attachmentRecoveryIsBusy, !attachmentStageInFlight, !attachmentRemovalInFlight else { throw DirectSessionError.ambiguousPrompt }
        guard !recoveryStageUnknown else { throw DirectSessionError.unresolvedAttachment }
        if destructiveTarget != nil {
            // Edit/regenerate never consume the ordinary composer's staged files.
            guard stagedAttachments.isEmpty, recoveryMarker == nil else {
                throw DirectSessionError.unresolvedAttachment
            }
        }
        if recoveryMarker != nil {
            guard !stagedAttachments.isEmpty,
                  locallyConfirmedRecoveryStageCount > 0 else {
                throw DirectSessionError.unresolvedAttachment
            }
        }
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

        if destructiveTarget != nil {
            // Stock checks the active-turn lease again while replacing rows, but
            // this status proof keeps an already-running turn out of the normal
            // path. A cross-client race after this read remains a stock limitation.
            guard lifecycle == destructiveEntryLifecycle,
                  binding == destructiveEntryBinding,
                  runtime.origin == destructiveEntryOrigin,
                  runtime.connectionGeneration == destructiveEntryConnectionGeneration else {
                throw DirectSessionError.staleOperation
            }
            try await ensureBinding(create: create)
            guard lifecycle == destructiveEntryLifecycle,
                  let statusBinding = binding,
                  statusBinding == destructiveEntryBinding,
                  statusBinding.profile == profile,
                  runtime.origin == destructiveEntryOrigin,
                  runtime.connectionGeneration == destructiveEntryConnectionGeneration else {
                throw DirectSessionError.staleOperation
            }
            let status = try await runtime.request("session.status", parameters: {
                guard !self.disposed,
                      self.lifecycle == destructiveEntryLifecycle,
                      self.binding == statusBinding,
                      self.runtime.origin == destructiveEntryOrigin,
                      self.runtime.connectionGeneration == destructiveEntryConnectionGeneration,
                      self.runtime.state == .ready, self.runState == .idle,
                      self.promptInFlight else { throw DirectSessionError.staleOperation }
                return self.rpcParams(statusBinding)
            })
            guard status?.gatewayFields["output"]?.gatewayString?
                .components(separatedBy: .newlines)
                .contains("Agent Running: No") == true,
                  lifecycle == destructiveEntryLifecycle,
                  binding == destructiveEntryBinding,
                  runtime.origin == destructiveEntryOrigin,
                  runtime.connectionGeneration == destructiveEntryConnectionGeneration else {
                throw DirectSessionError.ambiguousPrompt
            }
        }

        // Confirmed attachment receipts belong to the idle turn in which they
        // were staged. Bind first, then validate that exact scope before this
        // submit advances the turn. Pending/unknown receipts are never sent.
        let preSubmitTurn = turnEpoch
        var stagedScope: DirectPendingAttachmentStageScope?
        var stagedReferenceTexts: [String] = []
        var recoveryTokenForSubmit: UUID?
        var recoveryMinimumEventSequence = -1
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
            guard !recoveryMarkerLoadFailed,
                  !recoveryStageUnknown,
                  recoveryMarker == nil || locallyConfirmedRecoveryStageCount > 0 else {
                throw DirectSessionError.unresolvedAttachment
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
            if let recoveryMarker,
               locallyConfirmedRecoveryStageCount > 0 {
                recoveryTokenForSubmit = recoveryMarker.token
                recoveryMinimumEventSequence = latestEventSequence
            }
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
        if stagedAttachments.isEmpty, (recoveryMarker != nil || recoveryMarkerLoadFailed) {
            runState = .idle
            throw DirectSessionError.unresolvedAttachment
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
        if let recoveryTokenForSubmit {
            recoveryPromptObservation = RecoveryPromptObservation(
                token: recoveryTokenForSubmit,
                binding: capturedBinding,
                origin: capturedOrigin,
                connectionGeneration: capturedConnectionGeneration,
                lifecycle: generation,
                minimumEventSequence: recoveryMinimumEventSequence
            )
        }
        var promptMarkerForSubmit: DirectPromptDeliveryUncertaintyMarker?
        do {
            // The marker is written before the transport can dispatch. This
            // intentionally quarantines the small pre-write crash window; a
            // proven nondispatch below removes it without retrying.
            promptMarkerForSubmit = try persistPromptUncertaintyBeforeDispatch()
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
                if destructiveTarget != nil {
                    guard self.lifecycle == generation,
                          self.lifecycle == destructiveEntryLifecycle,
                          self.turnEpoch == submissionTurn,
                          self.runState == .submitting,
                          binding == capturedBinding,
                          binding == destructiveEntryBinding,
                          self.runtime.origin == capturedOrigin,
                          self.runtime.origin == destructiveEntryOrigin,
                          self.runtime.connectionGeneration == capturedConnectionGeneration,
                          self.runtime.connectionGeneration == destructiveEntryConnectionGeneration,
                          self.runtime.state == .ready else {
                        throw DirectSessionError.staleOperation
                    }
                }
                submitRequestWasDispatched = true
                var parameters: [String: JSONValue] = [
                    "session_id": .string(binding.runtimeID),
                    "profile": .string(self.profile),
                    "text": .string(submittedText)
                ]
                if let destructiveTarget {
                    parameters["confirm_truncate"] = .bool(true)
                    parameters["truncate_before_row_id"] = .number(Double(destructiveTarget.userRowID))
                    if let ordinal = destructiveTarget.userOrdinal {
                        parameters["truncate_before_user_ordinal"] = .number(Double(ordinal))
                    }
                    if destructiveTarget.permitsEmptyTranscript {
                        parameters["confirm_empty_truncate"] = .bool(true)
                    }
                }
                return parameters
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
            // This exact ACK proves the new turn belongs to this controller.
            // Events buffered before it remain conservatively suppressed; all
            // subsequent locally owned streaming may render normally.
            suppressesColdResumedContent = false
            // A very short turn can complete before the RPC continuation runs.
            if runState == .submitting { runState = .running }
            if let promptMarkerForSubmit {
                // The server has definitively accepted this turn. A local
                // cleanup failure must not turn a known acceptance into an
                // unknown-send error; the persisted marker remains a reopen
                // quarantine and is surfaced as confirmed acceptance.
                _ = clearPromptUncertainty(promptMarkerForSubmit, retainBarrierOnFailure: false)
            }
            if recoveryTokenForSubmit != nil,
               recoveryPromptObservation?.token == recoveryTokenForSubmit {
                recoveryPromptObservation?.accepted = true
                scheduleRecoveryCleanupIfReady()
            }
        } catch {
            guard !disposed, generation == lifecycle else { throw error }
            var promptCleanupError: DirectPromptDeliveryUncertaintyError?
            if !submitRequestWasDispatched {
                recoveryPromptObservation = nil
                if let promptMarkerForSubmit {
                    if !clearPromptUncertainty(promptMarkerForSubmit, retainBarrierOnFailure: true) {
                        promptCleanupError = .persistenceUnavailable
                    }
                }
            }
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
                throw promptCleanupError ?? error
            }
            if Self.isDefinitePromptSubmitRejection(error) {
                runState = .idle
                if let promptMarkerForSubmit {
                    if !clearPromptUncertainty(promptMarkerForSubmit, retainBarrierOnFailure: true) {
                        promptCleanupError = .persistenceUnavailable
                    }
                }
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
            throw promptCleanupError ?? error
        }
    }

    /// Reads the live session setting for an already-stored conversation. Drafts
    /// deliberately remain local and are never created just to read a setting.
    func reasoningConfiguration() async throws -> ReasoningConfiguration {
        guard !disposed, !branchInFlight, hasSubmittedPrompt, storedID != nil else { throw DirectSessionError.invalidBinding }
        while let mutationTail = reasoningMutationTail {
            await mutationTail.value
        }
        guard !branchInFlight else { throw DirectSessionError.staleOperation }
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
              !branchInFlight,
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
            guard !self.disposed, !self.branchInFlight,
                  self.runState == .idle || self.runState == .running else {
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
        guard !compressionOutcomeUnknown else { throw DirectSessionCompressionError.outcomeUnknown }
        guard !disposed, !branchInFlight, binding != nil, runState == .running,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DirectSessionError.invalidResponse }
        let result = try await runtime.request("session.steer", parameters: {
            guard !self.disposed, !self.branchInFlight,
                  let binding = self.binding, self.runState == .running else { throw DirectSessionError.staleOperation }
            return ["session_id": .string(binding.runtimeID), "profile": .string(self.profile), "text": .string(text)]
        })
        guard let status = result?.gatewayFields["status"]?.gatewayString,
              let outcome = SteerOutcome(rawValue: status) else { throw DirectSessionError.invalidResponse }
        // Rejected steer never becomes interrupt + prompt.submit.
        return outcome
    }

    /// Dispatches only stock `/goal` through the bound runtime. Goal storage is
    /// process-profile scoped upstream, so a selected chat may use it only when
    /// `/api/profiles/active.current` matches this controller's profile.
    func dispatchGoal(_ arg: String, profileContext: DirectHermesActiveProfile) async throws -> GoalDispatchResult {
        let current = profileContext.current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !current.isEmpty else { throw DirectGoalError.runningProfileUnavailable }
        guard current == profile else {
            throw DirectGoalError.runningProfileMismatch(selected: profile, current: current)
        }
        let capturedRunState = runState
        let permitsRunning = Self.goalControlIsAllowedWhileRunning(arg)
        guard !disposed, !branchInFlight,
              capturedRunState == .idle || (capturedRunState == .running && permitsRunning), !promptInFlight,
              !hasAmbiguousPromptDelivery, let capturedBinding = binding else {
            throw DirectSessionError.invalidBinding
        }
        let capturedLifecycle = lifecycle
        let capturedBindingEpoch = bindingEpoch
        let capturedTurn = turnEpoch
        let capturedOrigin = runtime.origin
        let capturedConnection = runtime.connectionGeneration

        func requireCurrentScope() throws {
            guard !disposed, !branchInFlight, runState == capturedRunState, !promptInFlight,
                  !hasAmbiguousPromptDelivery, lifecycle == capturedLifecycle,
                  bindingEpoch == capturedBindingEpoch, turnEpoch == capturedTurn,
                  binding == capturedBinding, runtime.origin == capturedOrigin,
                  runtime.connectionGeneration == capturedConnection,
                  runtime.state == .ready, profile == current else {
                throw DirectSessionError.staleOperation
            }
        }

        let resolved = try await runtime.request("command.resolve", parameters: {
            try requireCurrentScope()
            return ["name": .string("goal")]
        })
        try requireCurrentScope()
        guard resolved?.gatewayFields["canonical"]?.gatewayString == "goal" else {
            throw DirectGoalError.invalidResponse
        }

        var dispatched = false
        let response: JSONValue?
        do {
            response = try await runtime.request("command.dispatch", parameters: {
                try requireCurrentScope()
                dispatched = true
                return [
                    "session_id": .string(capturedBinding.runtimeID),
                    "name": .string("goal"),
                    "arg": .string(arg)
                ]
            })
            do { try requireCurrentScope() }
            catch { throw DirectGoalError.outcomeUnknown }
        } catch {
            guard dispatched else { throw error }
            if case HermesGatewayError.server(_, _, _, let method, _, _) = error,
               method == "command.dispatch" {
                throw error
            }
            throw DirectGoalError.outcomeUnknown
        }

        guard let fields = response?.gatewayFields,
              let type = fields["type"]?.gatewayString else {
            throw DirectGoalError.outcomeUnknown
        }
        switch type {
        case "exec", "plugin":
            guard let output = fields["output"]?.gatewayString else {
                throw DirectGoalError.outcomeUnknown
            }
            return .output(output)
        case "send":
            guard capturedRunState == .idle else { throw DirectGoalError.unsupportedResult }
            guard let message = fields["message"]?.gatewayString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else {
                throw DirectGoalError.outcomeUnknown
            }
            return .send(
                notice: fields["notice"]?.gatewayString,
                message: message,
                display: fields["display"]?.gatewayString
            )
        case "alias", "skill":
            throw DirectGoalError.unsupportedResult
        default:
            throw DirectGoalError.outcomeUnknown
        }
    }

    /// Resolves one generated skill shortcut using the stock gateway. Expanded
    /// skill content stays opaque/model-facing; callers render only `display`.
    func dispatchSkill(
        name rawName: String,
        arg: String,
        profileContext: DirectHermesActiveProfile
    ) async throws -> SkillDispatchResult {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { throw DirectSkillDispatchError.invalidResponse }
        let current = profileContext.current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !current.isEmpty else { throw DirectSkillDispatchError.runningProfileUnavailable }
        guard current == profile else {
            throw DirectSkillDispatchError.runningProfileMismatch(selected: profile, current: current)
        }
        guard !skillDispatchInFlight else { throw DirectSkillDispatchError.alreadyDispatching }
        guard !disposed, !branchInFlight, runState == .idle, !promptInFlight,
              !hasAmbiguousPromptDelivery, let capturedBinding = binding else {
            throw DirectSessionError.invalidBinding
        }
        skillDispatchInFlight = true
        defer { skillDispatchInFlight = false }
        let capturedLifecycle = lifecycle
        let capturedBindingEpoch = bindingEpoch
        let capturedTurn = turnEpoch
        let capturedOrigin = runtime.origin
        let capturedConnection = runtime.connectionGeneration

        func requireCurrentScope() throws {
            guard !disposed, !branchInFlight, runState == .idle, !promptInFlight,
                  !hasAmbiguousPromptDelivery, lifecycle == capturedLifecycle, bindingEpoch == capturedBindingEpoch,
                  turnEpoch == capturedTurn, binding == capturedBinding,
                  runtime.origin == capturedOrigin,
                  runtime.connectionGeneration == capturedConnection,
                  runtime.state == .ready, profile == current, skillDispatchInFlight else {
                throw DirectSessionError.staleOperation
            }
        }

        do {
            let resolved = try await runtime.request("command.resolve", parameters: {
                try requireCurrentScope()
                return ["name": .string(name)]
            })
            try requireCurrentScope()
            if resolved?.gatewayFields["canonical"]?.gatewayString != nil {
                throw DirectSkillDispatchError.reservedCommand
            }
            throw DirectSkillDispatchError.invalidResponse
        } catch let error as HermesGatewayError {
            guard case .server(let code, _, _, let method, _, _) = error,
                  code == 4011, method == "command.resolve" else { throw error }
            try requireCurrentScope()
        }

        var dispatched = false
        let response: JSONValue?
        do {
            response = try await runtime.request("command.dispatch", parameters: {
                try requireCurrentScope()
                dispatched = true
                return [
                    "session_id": .string(capturedBinding.runtimeID),
                    "name": .string(name),
                    "arg": .string(arg)
                ]
            })
            do { try requireCurrentScope() }
            catch { throw DirectSkillDispatchError.outcomeUnknown }
        } catch {
            guard dispatched else { throw error }
            if case HermesGatewayError.server(_, _, _, let method, _, _) = error,
               method == "command.dispatch" {
                throw error
            }
            throw DirectSkillDispatchError.outcomeUnknown
        }

        guard let fields = response?.gatewayFields,
              let type = fields["type"]?.gatewayString else {
            throw DirectSkillDispatchError.outcomeUnknown
        }
        switch type {
        case "skill":
            guard let skillName = nonEmptyGatewayString(fields["name"]),
                  let message = nonEmptyGatewayString(fields["message"]),
                  let display = nonEmptyGatewayString(fields["display"]) else {
                throw DirectSkillDispatchError.outcomeUnknown
            }
            return .invocation(name: skillName, message: message, display: display)
        case "send":
            guard let message = nonEmptyGatewayString(fields["message"]),
                  let display = nonEmptyGatewayString(fields["display"]) else {
                throw DirectSkillDispatchError.outcomeUnknown
            }
            return .bundle(message: message, notice: rawGatewayString(fields["notice"]), display: display)
        case "exec", "plugin":
            guard let output = rawGatewayString(fields["output"]) else {
                throw DirectSkillDispatchError.outcomeUnknown
            }
            return .output(output)
        case "alias":
            throw DirectSkillDispatchError.unsupportedResult
        default:
            throw DirectSkillDispatchError.outcomeUnknown
        }
    }

    private func nonEmptyGatewayString(_ value: JSONValue?) -> String? {
        guard let result = rawGatewayString(value),
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }

    private func rawGatewayString(_ value: JSONValue?) -> String? {
        guard case .string(let result) = value else { return nil }
        return result
    }

    /// Starts one stock side-question task without changing canonical history.
    /// The caller supplies its local attempt identity before awaiting so a
    /// completion buffered during the RPC can be rendered during event drain.
    func startBtw(_ text: String, attemptID: UUID) async throws -> String {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw DirectBtwError.invalidResponse }
        guard activeBtw == nil else { throw DirectBtwError.alreadyActive }
        guard !disposed, !branchInFlight, let binding else { throw DirectBtwError.invalidResponse }
        let capturedLifecycle = lifecycle
        let capturedEpoch = bindingEpoch
        activeBtw = ActiveBtw(
            attemptID: attemptID, question: question, binding: binding,
            bindingEpoch: capturedEpoch, lifecycle: capturedLifecycle,
            connectionGeneration: nil, taskID: nil
        )
        var dispatched = false
        var acknowledgedTaskID: String?
        do {
            try await runtime.withSessionEventsPaused {
                guard var active = self.activeBtw,
                      active.attemptID == attemptID,
                      self.isCurrentBtwScope(active) else {
                    throw DirectSessionError.staleOperation
                }
                active.connectionGeneration = self.runtime.connectionGeneration
                self.activeBtw = active
                let result = try await self.runtime.request("prompt.btw", parameters: {
                    guard let current = self.activeBtw,
                          current.attemptID == attemptID,
                          self.isCurrentBtwScope(current) else {
                        throw DirectSessionError.staleOperation
                    }
                    dispatched = true
                    return self.rpcParams(binding).merging(["text": .string(question)]) { _, new in new }
                })
                guard let taskID = result?.gatewayFields["task_id"]?.gatewayString,
                      !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      var current = self.activeBtw,
                      current.attemptID == attemptID,
                      self.isCurrentBtwScope(current) else {
                    throw DirectBtwError.invalidResponse
                }
                current.taskID = taskID
                self.activeBtw = current
                acknowledgedTaskID = taskID
            }
            guard let acknowledgedTaskID else { throw DirectBtwError.invalidResponse }
            return acknowledgedTaskID
        } catch {
            if activeBtw?.attemptID == attemptID { activeBtw = nil }
            if !dispatched || Self.isDefinitiveBtwRefusal(error) { throw error }
            throw DirectBtwError.outcomeUnknown
        }
    }

    private func isCurrentBtwScope(_ active: ActiveBtw) -> Bool {
        !disposed && lifecycle == active.lifecycle && bindingEpoch == active.bindingEpoch &&
            binding == active.binding && active.binding.profile == profile &&
            (active.connectionGeneration == nil || active.connectionGeneration == runtime.connectionGeneration)
    }

    private static func isDefinitiveBtwRefusal(_ error: Error) -> Bool {
        guard let gatewayError = error as? HermesGatewayError,
              case .server(_, _, _, let method, _, _) = gatewayError else { return false }
        return method == "prompt.btw"
    }

    /// Starts one independently correlated stock background task. Multiple
    /// attempts may coexist; an uncertain or completed attempt never drops a sibling.
    func startBackground(_ text: String, attemptID: UUID) async throws -> String {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, activeBackgroundByAttempt[attemptID] == nil,
              !disposed, !branchInFlight, let binding else {
            throw DirectBackgroundError.invalidResponse
        }
        let active = ActiveBackground(
            attemptID: attemptID, prompt: prompt, binding: binding,
            bindingEpoch: bindingEpoch, lifecycle: lifecycle,
            connectionGeneration: nil, taskID: nil
        )
        activeBackgroundByAttempt[attemptID] = active
        var dispatched = false
        var acknowledgedTaskID: String?
        do {
            try await runtime.withSessionEventsPaused {
                guard var current = self.activeBackgroundByAttempt[attemptID],
                      self.isCurrentBackgroundScope(current) else {
                    throw DirectSessionError.staleOperation
                }
                current.connectionGeneration = self.runtime.connectionGeneration
                self.activeBackgroundByAttempt[attemptID] = current
                let result = try await self.runtime.request("prompt.background", parameters: {
                    guard let current = self.activeBackgroundByAttempt[attemptID],
                          self.isCurrentBackgroundScope(current) else {
                        throw DirectSessionError.staleOperation
                    }
                    dispatched = true
                    return self.rpcParams(binding).merging(["text": .string(prompt)]) { _, new in new }
                })
                guard let taskID = result?.gatewayFields["task_id"]?.gatewayString,
                      !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DirectBackgroundError.invalidResponse
                }
                let collisions = self.activeBackgroundByAttempt.values.filter {
                    $0.attemptID != attemptID && $0.taskID == taskID
                }
                if !collisions.isEmpty {
                    for collision in collisions {
                        self.activeBackgroundByAttempt.removeValue(forKey: collision.attemptID)
                        self.onBackgroundOutcome?(.unknown(attemptID: collision.attemptID))
                    }
                    throw DirectBackgroundError.invalidResponse
                }
                guard var acknowledged = self.activeBackgroundByAttempt[attemptID],
                      self.isCurrentBackgroundScope(acknowledged) else {
                    throw DirectBackgroundError.invalidResponse
                }
                acknowledged.taskID = taskID
                self.activeBackgroundByAttempt[attemptID] = acknowledged
                acknowledgedTaskID = taskID
            }
            guard let acknowledgedTaskID else { throw DirectBackgroundError.invalidResponse }
            return acknowledgedTaskID
        } catch {
            activeBackgroundByAttempt.removeValue(forKey: attemptID)
            if !dispatched || Self.isDefinitiveBackgroundRefusal(error) { throw error }
            throw DirectBackgroundError.outcomeUnknown
        }
    }

    private func isCurrentBackgroundScope(_ active: ActiveBackground) -> Bool {
        !disposed && lifecycle == active.lifecycle && bindingEpoch == active.bindingEpoch &&
            binding == active.binding && active.binding.profile == profile &&
            (active.connectionGeneration == nil || active.connectionGeneration == runtime.connectionGeneration)
    }

    private static func isDefinitiveBackgroundRefusal(_ error: Error) -> Bool {
        guard let gatewayError = error as? HermesGatewayError,
              case .server(_, _, _, let method, _, _) = gatewayError else { return false }
        return method == "prompt.background"
    }

    /// The interrupt acknowledgement is not evidence the server has stopped.
    /// Confirm both a matching terminal event and the pinned status contract.
    func interrupt() async throws {
        // An unconfirmed interrupt must remain retryable, without reopening
        // ordinary send/steer or treating a lost acknowledgement as success.
        if runState == .stopping, binding == nil {
            guard !disposed, !branchInFlight, hasSubmittedPrompt,
                  let retryStoredID = storedID else { throw DirectSessionError.invalidResponse }
            let retryLifecycle = lifecycle
            let retryTurn = turnEpoch
            let retryOrigin = runtime.origin
            runState = .deliveryUnknown
            do {
                try await ensureBinding(create: [:])
            } catch {
                if !disposed, lifecycle == retryLifecycle, turnEpoch == retryTurn,
                   storedID == retryStoredID, runtime.origin == retryOrigin,
                   runState == .deliveryUnknown { runState = .stopping }
                throw error
            }
            guard !disposed, lifecycle == retryLifecycle, turnEpoch == retryTurn,
                  storedID == retryStoredID, runtime.origin == retryOrigin,
                  let rebound = binding, rebound.storedID == retryStoredID,
                  rebound.profile == profile,
                  runState == .deliveryUnknown || runState == .running else {
                throw DirectSessionError.staleOperation
            }
            if runState == .deliveryUnknown { runState = .stopping }
        }
        guard !disposed, !branchInFlight,
              let binding, runState == .running || runState == .stopping else { throw DirectSessionError.invalidResponse }
        let generation = lifecycle
        let interruptedTurn = turnEpoch
        let interruptedConnection = runtime.connectionGeneration
        let interruptedStoredID = binding.storedID
        runState = .stopping
        let result = try await runtime.request("session.interrupt", parameters: {
            guard self.binding == binding, !self.disposed, !self.branchInFlight else { throw DirectSessionError.stopUnconfirmed }
            return self.rpcParams(binding)
        })
        guard result?.gatewayFields["status"]?.gatewayString == "interrupted" else { throw DirectSessionError.invalidResponse }
        for _ in 0..<40 {
            try checkLifecycle(generation)
            let status = try await runtime.request("session.status", parameters: {
                guard self.binding == binding, !self.disposed, !self.branchInFlight else { throw DirectSessionError.stopUnconfirmed }
                return self.rpcParams(binding)
            })
            let stopped = status?.gatewayFields["output"]?.gatewayString?
                .components(separatedBy: .newlines).contains("Agent Running: No") == true
            if stopped {
                if terminalReceipt == nil {
                    // A reconnect can lose the terminal event even though stock
                    // status authoritatively reports the turn idle. Reconcile the
                    // durable transcript, then prove the same scoped turn is still
                    // idle before releasing local streaming state.
                    do {
                        try await refresh()
                    } catch {
                        if !disposed, lifecycle == generation, turnEpoch == interruptedTurn,
                           runtime.connectionGeneration == interruptedConnection,
                           terminalReceipt != nil, runState == .idle {
                            schedulePendingReasoningDrain()
                            return
                        }
                        throw error
                    }
                    if !disposed, lifecycle == generation, turnEpoch == interruptedTurn,
                       runtime.connectionGeneration == interruptedConnection,
                       terminalReceipt != nil, runState == .idle {
                        schedulePendingReasoningDrain()
                        return
                    }
                    var confirmationBinding = binding
                    if self.binding == nil, storedID != interruptedStoredID {
                        // A canonical continuation rotated while the ancestor was
                        // being reconciled. Rebind without submitting, but do not
                        // trust the ancestor's idle status for the new tip.
                        guard !disposed, lifecycle == generation, turnEpoch == interruptedTurn,
                              runtime.connectionGeneration == interruptedConnection,
                              runState == .stopping else { throw DirectSessionError.staleOperation }
                        runState = .deliveryUnknown
                        do {
                            try await ensureBinding(create: [:])
                        } catch {
                            if !disposed, lifecycle == generation, turnEpoch == interruptedTurn,
                               runState == .deliveryUnknown { runState = .stopping }
                            throw error
                        }
                        guard !disposed, lifecycle == generation, turnEpoch == interruptedTurn,
                              runtime.connectionGeneration == interruptedConnection,
                              let rebound = self.binding, rebound.storedID == storedID,
                              rebound.profile == profile, runState == .deliveryUnknown else {
                            throw DirectSessionError.staleOperation
                        }
                        confirmationBinding = rebound
                        runState = .stopping
                    }
                    guard !disposed, lifecycle == generation, turnEpoch == interruptedTurn,
                          self.binding == confirmationBinding,
                          storedID == confirmationBinding.storedID,
                          runtime.connectionGeneration == interruptedConnection,
                          runState == .stopping else { throw DirectSessionError.staleOperation }
                    let confirmed = try await runtime.request("session.status", parameters: {
                        guard !self.disposed, self.lifecycle == generation,
                              self.turnEpoch == interruptedTurn, self.binding == confirmationBinding,
                              self.storedID == confirmationBinding.storedID,
                              self.runtime.connectionGeneration == interruptedConnection,
                              self.runState == .stopping else { throw DirectSessionError.staleOperation }
                        return self.rpcParams(confirmationBinding)
                    })
                    if !disposed, lifecycle == generation, turnEpoch == interruptedTurn,
                       runtime.connectionGeneration == interruptedConnection,
                       terminalReceipt != nil, runState == .idle {
                        schedulePendingReasoningDrain()
                        return
                    }
                    guard !disposed, lifecycle == generation, turnEpoch == interruptedTurn,
                          self.binding == confirmationBinding,
                          storedID == confirmationBinding.storedID,
                          runtime.connectionGeneration == interruptedConnection,
                          runState == .stopping,
                          confirmed?.gatewayFields["output"]?.gatewayString?
                            .components(separatedBy: .newlines).contains("Agent Running: No") == true else {
                        throw DirectSessionError.stopUnconfirmed
                    }
                    clearBlockingPromptForConfirmedIdle(runtimeID: binding.runtimeID)
                    clearDirectBlockingForConfirmedIdle(runtimeID: binding.runtimeID)
                    if confirmationBinding.runtimeID != binding.runtimeID {
                        clearBlockingPromptForConfirmedIdle(runtimeID: confirmationBinding.runtimeID)
                        clearDirectBlockingForConfirmedIdle(runtimeID: confirmationBinding.runtimeID)
                    }
                }
                runState = .idle
                schedulePendingReasoningDrain()
                if terminalReceipt == nil, let recoveredID = storedID { onRecoveredIdle?(recoveredID) }
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DirectSessionError.stopUnconfirmed
    }

    func refresh(limit: Int = 120, offset: Int = 0, olderAnchorID: String? = nil) async throws {
        guard !disposed, let storedID, hasSubmittedPrompt else { return }
        let generation = lifecycle
        let epoch = bindingEpoch
        let turn = turnEpoch
        let pagingBinding = binding
        let pagingConnection = runtime.connectionGeneration
        let pagingTerminal = terminalReceipt
        // Backwards offsets belong to a particular tail. An older request
        // crossing a new tail read must not rewind its cursor or prepend stale
        // rows. Likewise, a slow tail response cannot replace a newer one.
        if offset == 0 { latestReadGeneration &+= 1 }
        let readGeneration = latestReadGeneration
        var requestOffset = olderAnchorID == nil ? offset : max(0, offset - 1)
        var page = try await loadTranscript(storedID, profile, limit, requestOffset)
        if let olderAnchorID {
            // A running writer can move the backwards cursor by whole pages.
            // Seek the exact loaded boundary; unknown/newer rows never prepend.
            var scans = 1
            while !page.messages.contains(where: { $0.messageId == olderAnchorID }) {
                try checkLifecycle(generation)
                guard epoch == bindingEpoch, turn == turnEpoch, storedID == self.storedID,
                      binding == pagingBinding, runtime.connectionGeneration == pagingConnection,
                      terminalReceipt == pagingTerminal, readGeneration == latestReadGeneration,
                      page.sessionID == storedID, scans < 8,
                      (page.pagination?.returned ?? page.messages.count) >= limit else {
                    throw DirectSessionError.staleOperation
                }
                requestOffset += max(1, (page.pagination?.returned ?? page.messages.count) - 1)
                page = try await loadTranscript(storedID, profile, limit, requestOffset)
                scans += 1
            }
            let anchor = page.messages.firstIndex { $0.messageId == olderAnchorID }!
            page = DirectHermesTranscriptPage(sessionID: page.sessionID,
                messages: Array(page.messages[..<anchor]),
                pagination: DirectHermesTranscriptPagination(limit: page.pagination?.limit ?? limit,
                    offset: page.pagination?.offset ?? requestOffset, order: page.pagination?.order ?? "latest",
                    returned: page.pagination?.returned ?? page.messages.count))
        }
        try checkLifecycle(generation)
        guard epoch == bindingEpoch, turn == turnEpoch, storedID == self.storedID,
              readGeneration == latestReadGeneration,
              offset == 0 || (binding == pagingBinding && runtime.connectionGeneration == pagingConnection
                && terminalReceipt == pagingTerminal) else { throw DirectSessionError.staleOperation }
        let canonical = page.sessionID
        guard !canonical.isEmpty else { throw DirectSessionError.invalidBinding }
        // An older page cannot replace the live tail or rebind it to a new tip.
        // A fresh canonical tail read owns continuation adoption instead.
        if offset > 0, canonical != storedID {
            guard runState == .idle, !promptInFlight, !hasAmbiguousPromptDelivery else {
                throw OlderPageError.canonicalChanged
            }
            // Only an idle, still-owned scope may recover through the ordinary
            // canonical tail read. Never apply this older page to the old tail.
            try await refresh(limit: limit)
            try checkLifecycle(generation)
            guard turn == turnEpoch, runState == .idle, !promptInFlight else {
                throw DirectSessionError.staleOperation
            }
            try await open()
            return
        }
        try await resolvePromptUncertaintyLineage(requestedID: storedID, canonicalID: canonical) {
            try self.checkLifecycle(generation)
            guard epoch == self.bindingEpoch, turn == self.turnEpoch, storedID == self.storedID,
                  readGeneration == self.latestReadGeneration,
                  offset == 0 || (self.binding == pagingBinding && self.runtime.connectionGeneration == pagingConnection
                    && self.terminalReceipt == pagingTerminal) else { throw DirectSessionError.staleOperation }
        }
        durableRowConfirmed = true
        if canonical != storedID {
            try migratePromptUncertaintyMarkerIfNeeded(to: canonical)
            self.storedID = canonical
            // A REST continuation must never be paired with the ancestor's live ID.
            invalidateBinding()
            onCanonicalID?(canonical)
        }
        if offset == 0 { transcriptDirty = false }
        onTranscript?(page, offset > 0)
    }

    /// Synchronous invalidation closes the await gap on account switches. RPC
    /// parameter closures and pending attachments fail before async cleanup runs.
    func invalidate() {
        guard !disposed else { return }
        if let attempt = activeBtw?.attemptID {
            activeBtw = nil
            onBtwOutcome?(.unknown(attemptID: attempt))
        }
        abandonBackgroundAttemptsAsUnknown()
        disposed = true
        suppressesColdResumedContent = false
        lifecycle &+= 1
        reasoningRevision &+= 1
        pendingReasoningEffort = nil
        pendingBlockingPrompt = nil
        blockingClear = nil
        approvalPromptQueue.removeAll()
        pendingApprovalPrompt = nil
        secretPromptQueue.removeAll()
        pendingSecretPrompt = nil
        sudoPromptQueue.removeAll()
        pendingSudoPrompt = nil
        approvalClear.removeAll()
        secretClear.removeAll()
        sudoClear.removeAll()
        ambiguousReasoningEffort = nil
        reasoningMutationTail?.cancel()
        attachmentTask?.cancel()
        reconciliationTask?.cancel()
        idleRefreshTask?.cancel()
        if let observerID { runtime.removeObserver(observerID) }
    }

    func dispose() async throws {
        guard !didDispose else { return }
        guard !branchInFlight else { throw DirectSessionError.ambiguousPrompt }
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
        guard !branchInFlight else { throw DirectSessionError.ambiguousPrompt }
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
                    let recoveringTurn = self.turnEpoch
                    let recoveringID = self.storedID
                    let result = try await self.runtime.request("session.resume", params: self.resumeParams())
                    try self.checkLifecycle(generation)
                    try await self.applyResume(result)
                    try self.stageRecoveredIdle(result, generation: generation, turn: recoveringTurn, storedID: recoveringID)
                } else {
                    var params = create.filter { ["cwd", "model", "provider", "reasoning_effort", "fast"].contains($0.key) }
                    params["profile"] = .string(self.profile)
                    params["close_on_disconnect"] = .bool(false)
                    let result = try await self.runtime.request("session.create", params: params)
                    try self.checkLifecycle(generation)
                    try self.adopt(GatewaySessionBinding.resolve(result, profile: self.profile))
                }
            }
            self.publishRecoveredIdleAfterEventDrain()
        }
        attachmentTask = task
        defer { if lifecycle == generation { attachmentTask = nil } }
        try await task.value
    }

    private func resume(using transport: any HermesGatewayTransport) async throws {
        let generation = lifecycle
        let recoveringTurn = turnEpoch
        let recoveringID = storedID
        let result = try await transport.request(method: "session.resume", params: .object(resumeParams()), timeout: nil)
        try checkLifecycle(generation)
        try await applyResume(result)
        try stageRecoveredIdle(result, generation: generation, turn: recoveringTurn, storedID: recoveringID)
    }

    private func stageRecoveredIdle(_ result: JSONValue?, generation: Int, turn recoveringTurn: Int, storedID recoveringID: String?) throws {
        try checkLifecycle(generation)
        guard recoveringTurn == turnEpoch,
              let recoveringID, recoveringID == storedID,
              binding?.storedID == recoveringID,
              result?.gatewayFields["running"] == .bool(false),
              runState == .idle, !promptInFlight, !hasAmbiguousPromptDelivery else { return }
        guard let binding else { return }
        recoveredIdleCandidate = (generation, recoveringTurn, binding, runtime.connectionGeneration, terminalReceipt)
    }

    private func publishRecoveredIdleAfterEventDrain() {
        guard let candidate = recoveredIdleCandidate else { return }
        recoveredIdleCandidate = nil
        guard !disposed, lifecycle == candidate.lifecycle, turnEpoch == candidate.turn,
              binding == candidate.binding, storedID == candidate.binding.storedID,
              runtime.connectionGeneration == candidate.generation, runtime.state == .ready,
              terminalReceipt == candidate.terminal,
              runState == .idle, !promptInFlight, !hasAmbiguousPromptDelivery else { return }
        onRecoveredIdle?(candidate.binding.storedID)
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
        if result?.gatewayFields["running"] == .bool(true) {
            runState = .running
            suppressesColdResumedContent = true
        }
        else if runState != .deliveryUnknown, !promptInFlight {
            runState = .idle
            suppressesColdResumedContent = false
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
        guard !branchInFlight else { throw GatewayBlockingError.responseInFlight }
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

    // MARK: - Direct blocking interactions

    /// Responds to the exact approval card that the caller rendered. Approval
    /// cards are queued by full identity, so a response can finish after a
    /// later card arrives without accidentally acknowledging that later card.
    func respondToApproval(
        _ choice: GatewayApprovalChoice,
        expectedIdentity: GatewayBlockingPromptIdentity
    ) async throws -> GatewayBlockingResponse {
        guard !disposed else { throw DirectSessionError.stopped }
        guard !branchInFlight else { throw GatewayBlockingError.responseInFlight }
        guard !blockingInteractionResponseInFlight else { throw GatewayBlockingError.responseInFlight }
        blockingInteractionResponseInFlight = true
        blockingInteractionInFlightIdentity = expectedIdentity
        defer {
            blockingInteractionResponseInFlight = false
            blockingInteractionInFlightIdentity = nil
        }
        guard let captured = approvalPromptQueue.first(where: { $0.identity == expectedIdentity }),
              captured.choices.contains(choice),
              let capturedBinding = binding else {
            throw GatewayBlockingContractError.staleInteraction
        }
        let capturedLifecycle = lifecycle
        try await ensureBinding(create: [:])
        guard isCurrentInteraction(expectedIdentity, binding: capturedBinding, lifecycle: capturedLifecycle),
              approvalPromptQueue.contains(where: { $0.identity == expectedIdentity }) else {
            throw GatewayBlockingContractError.staleInteraction
        }
        let result = try await runtime.request("approval.respond", parameters: {
            guard self.isCurrentInteraction(expectedIdentity, binding: capturedBinding, lifecycle: capturedLifecycle),
                  self.approvalPromptQueue.contains(where: { $0.identity == expectedIdentity }) else {
                throw GatewayBlockingContractError.staleInteraction
            }
            return [
                "session_id": .string(expectedIdentity.runtimeID),
                "profile": .string(expectedIdentity.profile),
                "request_id": .string(expectedIdentity.requestID),
                "choice": .string(choice.rawValue)
            ]
        })
        guard isCurrentInteraction(expectedIdentity, binding: capturedBinding, lifecycle: capturedLifecycle),
              approvalPromptQueue.contains(where: { $0.identity == expectedIdentity }) ||
              approvalClear.contains(where: { $0.0 == expectedIdentity }) else {
            throw GatewayBlockingContractError.staleInteraction
        }
        if approvalClear.contains(where: { $0.0 == expectedIdentity && $0.1 == .expiry }) {
            return .expired
        }
        guard let resolved = positiveIntegral(result?.gatewayFields["resolved"]) else {
            throw GatewayBlockingContractError.approvalNotResolved
        }
        _ = resolved
        clearApproval(expectedIdentity, reason: .terminal)
        // The first approval response does not prove the queue is empty. Stock
        // approval.pending is authoritative for the next card and may omit
        // choices, which the shared model decoder derives safely.
        await refreshApprovalQueue(expectedIdentity: expectedIdentity, binding: capturedBinding, lifecycle: capturedLifecycle)
        return .accepted
    }

    func cancelSecret(expectedIdentity: GatewayBlockingPromptIdentity) async throws -> GatewayBlockingResponse {
        try await cancelSensitive(.secret, expectedIdentity: expectedIdentity)
    }

    func cancelSudo(expectedIdentity: GatewayBlockingPromptIdentity) async throws -> GatewayBlockingResponse {
        try await cancelSensitive(.sudo, expectedIdentity: expectedIdentity)
    }

    private func cancelSensitive(
        _ kind: SensitiveInteractionKind,
        expectedIdentity: GatewayBlockingPromptIdentity
    ) async throws -> GatewayBlockingResponse {
        guard !disposed else { throw DirectSessionError.stopped }
        guard !branchInFlight else { throw GatewayBlockingError.responseInFlight }
        guard !blockingInteractionResponseInFlight else { throw GatewayBlockingError.responseInFlight }
        blockingInteractionResponseInFlight = true
        blockingInteractionInFlightIdentity = expectedIdentity
        defer {
            blockingInteractionResponseInFlight = false
            blockingInteractionInFlightIdentity = nil
        }
        guard containsSensitive(kind, identity: expectedIdentity), let capturedBinding = binding else {
            throw GatewayBlockingContractError.staleInteraction
        }
        let capturedLifecycle = lifecycle
        try await ensureBinding(create: [:])
        guard isCurrentInteraction(expectedIdentity, binding: capturedBinding, lifecycle: capturedLifecycle),
              containsSensitive(kind, identity: expectedIdentity) else {
            throw GatewayBlockingContractError.staleInteraction
        }
        let method = "\(kind.rawValue).respond"
        let result: JSONValue?
        do {
            result = try await runtime.request(method, parameters: {
                guard self.isCurrentInteraction(expectedIdentity, binding: capturedBinding, lifecycle: capturedLifecycle),
                      self.containsSensitive(kind, identity: expectedIdentity) else {
                    throw GatewayBlockingContractError.staleInteraction
                }
                return [
                    "session_id": .string(expectedIdentity.runtimeID),
                    "profile": .string(expectedIdentity.profile),
                    "request_id": .string(expectedIdentity.requestID),
                    kind == .secret ? "value" : "password": .string("")
                ]
            })
        } catch {
            throw error
        }
        guard isCurrentInteraction(expectedIdentity, binding: capturedBinding, lifecycle: capturedLifecycle),
              containsSensitive(kind, identity: expectedIdentity) || sensitiveClearContains(kind, identity: expectedIdentity) else {
            throw GatewayBlockingContractError.staleInteraction
        }
        if sensitiveClearContains(kind, identity: expectedIdentity, reason: .expiry) {
            return .expired
        }
        guard result?.gatewayFields["status"]?.gatewayString == "ok" else {
            if result?.gatewayFields["status"]?.gatewayString == "expired" {
                clearSensitive(kind, expectedIdentity: expectedIdentity, reason: .expiry)
                return .expired
            }
            throw GatewayBlockingContractError.invalidResponse
        }
        clearSensitive(kind, expectedIdentity: expectedIdentity, reason: .terminal)
        return .accepted
    }

    private func isCurrentInteraction(
        _ identity: GatewayBlockingPromptIdentity,
        binding: GatewaySessionBinding,
        lifecycle: Int
    ) -> Bool {
        !disposed && self.binding == binding && self.lifecycle == lifecycle &&
        runtime.state == .ready &&
        runtime.connectionGeneration == identity.connectionGeneration &&
        runtime.origin.absoluteString == identity.origin &&
        binding.runtimeID == identity.runtimeID && binding.storedID == identity.storedID &&
        binding.profile == identity.profile
    }

    private func positiveIntegral(_ value: JSONValue?) -> Int? {
        guard case .number(let number) = value, number.isFinite, number >= 1,
              number.rounded(.towardZero) == number,
              let value = Int(exactly: number), value > 0 else { return nil }
        return value
    }

    private func containsSensitive(_ kind: SensitiveInteractionKind, identity: GatewayBlockingPromptIdentity) -> Bool {
        switch kind {
        case .secret: return secretPromptQueue.contains { $0.identity == identity }
        case .sudo: return sudoPromptQueue.contains { $0.identity == identity }
        }
    }

    private func sensitiveClearContains(_ kind: SensitiveInteractionKind, identity: GatewayBlockingPromptIdentity) -> Bool {
        sensitiveClearContains(kind, identity: identity, reason: nil)
    }

    private func sensitiveClearContains(
        _ kind: SensitiveInteractionKind,
        identity: GatewayBlockingPromptIdentity,
        reason: InteractionClearReason?
    ) -> Bool {
        switch kind {
        case .secret:
            return secretClear.contains { $0.0 == identity && (reason == nil || $0.1 == reason) }
        case .sudo:
            return sudoClear.contains { $0.0 == identity && (reason == nil || $0.1 == reason) }
        }
    }

    private func clearApproval(_ identity: GatewayBlockingPromptIdentity, reason: InteractionClearReason) {
        approvalPromptQueue.removeAll { $0.identity == identity }
        pendingApprovalPrompt = approvalPromptQueue.first
        approvalClear.removeAll()
        approvalClear.append((identity, reason))
    }

    private func clearSensitive(_ kind: SensitiveInteractionKind, expectedIdentity: GatewayBlockingPromptIdentity, reason: InteractionClearReason) {
        switch kind {
        case .secret:
            secretPromptQueue.removeAll { $0.identity == expectedIdentity }
            pendingSecretPrompt = secretPromptQueue.first
            secretClear.removeAll()
            secretClear.append((expectedIdentity, reason))
        case .sudo:
            sudoPromptQueue.removeAll { $0.identity == expectedIdentity }
            pendingSudoPrompt = sudoPromptQueue.first
            sudoClear.removeAll()
            sudoClear.append((expectedIdentity, reason))
        }
    }

    private func refreshApprovalQueue(expectedIdentity: GatewayBlockingPromptIdentity, binding: GatewaySessionBinding, lifecycle: Int) async {
        guard isCurrentInteraction(expectedIdentity, binding: binding, lifecycle: lifecycle) else { return }
        do {
            let result = try await runtime.request("approval.pending", parameters: {
                guard self.isCurrentInteraction(expectedIdentity, binding: binding, lifecycle: lifecycle) else {
                    throw GatewayBlockingContractError.staleInteraction
                }
                return ["session_id": .string(binding.runtimeID), "profile": .string(binding.profile)]
            })
            guard isCurrentInteraction(expectedIdentity, binding: binding, lifecycle: lifecycle) else { return }
            guard let rawApprovals = result?.gatewayFields["approvals"],
                  case .array(let values) = rawApprovals else {
                throw GatewayBlockingContractError.malformedApproval
            }
            var prompts: [GatewayApprovalPrompt] = []
            for value in values {
                guard let requestID = value.gatewayFields["request_id"]?.gatewayString else {
                    throw GatewayBlockingContractError.malformedApproval
                }
                let identity = try blockingIdentity(requestID: requestID)
                let prompt = try GatewayApprovalPrompt.decode(payload: value, identity: identity)
                if !prompts.contains(where: { $0.identity == prompt.identity }) { prompts.append(prompt) }
            }
            let newlyArrived = approvalPromptQueue.filter { existing in
                !prompts.contains(where: { $0.identity == existing.identity })
            }
            approvalPromptQueue = prompts + newlyArrived
            pendingApprovalPrompt = approvalPromptQueue.first
            approvalClear.removeAll { $0.0 == expectedIdentity }
        } catch GatewayBlockingContractError.staleInteraction {
            // A newer binding owns the interaction; never mutate its queue.
        } catch {
            guard isCurrentInteraction(expectedIdentity, binding: binding, lifecycle: lifecycle) else { return }
            onError?(error)
        }
    }

    private func adopt(_ binding: GatewaySessionBinding) throws {
        guard !disposed else { throw DirectSessionError.stopped }
        try migratePromptUncertaintyMarkerIfNeeded(to: binding.storedID)
        self.binding = binding
        bindingEpoch &+= 1
        let previousRecoveryIdentity = recoveryMarker?.identity
        storedID = binding.storedID
        onCanonicalID?(binding.storedID)
        onBinding?(binding)
        if previousRecoveryIdentity == nil {
            refreshRecoveryMarker()
        } else if previousRecoveryIdentity?.runtimeID != binding.runtimeID {
            // A cleanup awaiting the old runtime must not quarantine the newly
            // adopted runtime. Explicit reset owns its marker independently and
            // is allowed to retain it until fresh-runtime proof completes.
            if recoveryCleanupTask != nil {
                recoveryCleanupTask?.cancel()
                recoveryCleanupTask = nil
                recoveryCleanupOwnerToken = nil
                recoveryCleanupOwnerID = nil
                if !attachmentStageInFlight && !attachmentRemovalInFlight {
                    attachmentRecoveryIsBusy = false
                }
            }
            // A fresh stock runtime has an empty in-memory attachment queue;
            // a marker keyed to the old runtime is not authority for it.
            if !attachmentRecoveryIsBusy {
                recoveryMarker = nil
                recoveryMarkerLoadFailed = false
                recoveryStageUnknown = false
                attachmentRecoveryNeedsReset = false
                unresolvedAttachmentMarkerToken = nil
                locallyConfirmedRecoveryStageCount = 0
                recoveryDetachPaths.removeAll()
                recoveryPromptObservation = nil
            }
            refreshRecoveryMarker()
        } else if previousRecoveryIdentity?.storedID != binding.storedID {
            attachmentRecoveryNeedsReset = true
        }
        // A fresh draft has no marker until its first durable ID is known, but
        // another controller may have written one in the meantime. Reload the
        // tip identity before any submit can proceed.
        refreshPromptUncertaintyMarker()
    }

    private func invalidateBinding() {
        if let attempt = activeBtw?.attemptID {
            activeBtw = nil
            onBtwOutcome?(.unknown(attemptID: attempt))
        }
        abandonBackgroundAttemptsAsUnknown()
        bindingEpoch &+= 1
        binding = nil
        suppressesColdResumedContent = false
    }

    private func abandonBackgroundAttemptsAsUnknown() {
        let attempts = Array(activeBackgroundByAttempt.keys)
        activeBackgroundByAttempt.removeAll()
        for attempt in attempts {
            onBackgroundOutcome?(.unknown(attemptID: attempt))
        }
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
        restoreDirectBlockingPrompts(from: result)
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

    private func restoreDirectBlockingPrompts(from result: JSONValue?) {
        approvalPromptQueue.removeAll()
        pendingApprovalPrompt = nil
        pendingSecretPrompt = nil
        pendingSudoPrompt = nil
        secretPromptQueue.removeAll()
        sudoPromptQueue.removeAll()
        approvalClear.removeAll()
        secretClear.removeAll()
        sudoClear.removeAll()
        guard let fields = result?.gatewayFields else { return }
        if let pending = fields["pending_approval"], pending != .null {
            do {
                guard let requestID = pending.gatewayFields["request_id"]?.gatewayString else {
                    throw GatewayBlockingContractError.malformedApproval
                }
                let identity = try blockingIdentity(requestID: requestID)
                let prompt = try GatewayApprovalPrompt.decode(payload: pending, identity: identity)
                approvalPromptQueue = [prompt]
                pendingApprovalPrompt = prompt
            } catch {
                onError?(error)
            }
        }
        // Stock resume intentionally does not restore secret/sudo requests;
        // never fabricate a sensitive prompt from stale client state.
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
        guard let runtimeID = event.sessionID else { return }
        clearBlockingPromptForConfirmedIdle(runtimeID: runtimeID)
    }

    private func clearBlockingPromptForConfirmedIdle(runtimeID: String) {
        guard let pending = pendingBlockingPrompt,
              pending.identity.runtimeID == runtimeID else {
            return
        }
        blockingClear = (pending.identity, .terminal)
        pendingBlockingPrompt = nil
    }

    private func handleApprovalRequest(_ event: HermesGatewayEvent) {
        guard let requestID = event.payload?.gatewayFields["request_id"]?.gatewayString else {
            onError?(GatewayBlockingContractError.malformedApproval)
            return
        }
        do {
            let identity = try blockingIdentity(requestID: requestID)
            let prompt = try GatewayApprovalPrompt.decode(payload: event.payload, identity: identity)
            if let index = approvalPromptQueue.firstIndex(where: { $0.identity == identity }) {
                approvalPromptQueue[index] = prompt
            } else {
                approvalPromptQueue.append(prompt)
            }
            pendingApprovalPrompt = approvalPromptQueue.first
            approvalClear.removeAll { $0.0 == identity }
        } catch { onError?(error) }
    }

    private func handleSecretRequest(_ event: HermesGatewayEvent) {
        guard let requestID = event.payload?.gatewayFields["request_id"]?.gatewayString else {
            onError?(GatewayBlockingContractError.malformedSecret)
            return
        }
        do {
            let identity = try blockingIdentity(requestID: requestID)
            let prompt = try GatewaySecretPrompt.decode(payload: event.payload, identity: identity)
            if let index = secretPromptQueue.firstIndex(where: { $0.identity == identity }) {
                secretPromptQueue[index] = prompt
            } else {
                secretPromptQueue.append(prompt)
            }
            pendingSecretPrompt = secretPromptQueue.first
            secretClear.removeAll { $0.0 == identity }
        } catch { onError?(error) }
    }

    private func handleSudoRequest(_ event: HermesGatewayEvent) {
        guard let requestID = event.payload?.gatewayFields["request_id"]?.gatewayString else {
            onError?(GatewayBlockingContractError.malformedSudo)
            return
        }
        do {
            let identity = try blockingIdentity(requestID: requestID)
            let prompt = try GatewaySudoPrompt.decode(payload: event.payload, identity: identity)
            if let index = sudoPromptQueue.firstIndex(where: { $0.identity == identity }) {
                sudoPromptQueue[index] = prompt
            } else {
                sudoPromptQueue.append(prompt)
            }
            pendingSudoPrompt = sudoPromptQueue.first
            sudoClear.removeAll { $0.0 == identity }
        } catch { onError?(error) }
    }

    private func handleSensitiveExpiry(_ kind: SensitiveInteractionKind, event: HermesGatewayEvent) {
        guard let requestID = event.payload?.gatewayFields["request_id"]?.gatewayString else {
            onError?(kind == .secret ? GatewayBlockingContractError.malformedSecret : GatewayBlockingContractError.malformedSudo)
            return
        }
        let identity: GatewayBlockingPromptIdentity?
        switch kind {
        case .secret: identity = secretPromptQueue.first(where: { $0.identity.requestID == requestID })?.identity
        case .sudo: identity = sudoPromptQueue.first(where: { $0.identity.requestID == requestID })?.identity
        }
        guard let identity, identity.runtimeID == (event.sessionID ?? "") else { return }
        clearSensitive(kind, expectedIdentity: identity, reason: .expiry)
    }

    private func clearDirectBlockingForTerminal(_ event: HermesGatewayEvent) {
        guard let runtimeID = event.sessionID else { return }
        clearDirectBlockingForConfirmedIdle(runtimeID: runtimeID)
    }

    private func clearDirectBlockingForConfirmedIdle(runtimeID: String) {
        let inFlight = blockingInteractionInFlightIdentity
        let inFlightCategory = inFlight.flatMap { self.inFlightKind($0) }
        approvalPromptQueue.removeAll { $0.identity.runtimeID == runtimeID }
        pendingApprovalPrompt = approvalPromptQueue.first
        secretPromptQueue.removeAll { $0.identity.runtimeID == runtimeID }
        pendingSecretPrompt = secretPromptQueue.first
        sudoPromptQueue.removeAll { $0.identity.runtimeID == runtimeID }
        pendingSudoPrompt = sudoPromptQueue.first
        // Only the request whose RPC has already crossed the transport boundary
        // gets a tombstone. Other queued prompts are terminally gone and must
        // not reappear after the turn completes.
        if let inFlight, inFlight.runtimeID == runtimeID {
            switch inFlightCategory {
            case .approval:
                approvalClear = [(inFlight, .terminal)]
            case .secret:
                secretClear = [(inFlight, .terminal)]
            case .sudo:
                sudoClear = [(inFlight, .terminal)]
            case nil:
                break
            }
        }
    }

    private enum InFlightInteractionKind { case approval, secret, sudo }

    private func inFlightKind(_ identity: GatewayBlockingPromptIdentity) -> InFlightInteractionKind? {
        if approvalClear.contains(where: { $0.0 == identity }) ||
            approvalPromptQueue.contains(where: { $0.identity == identity }) { return .approval }
        if secretClear.contains(where: { $0.0 == identity }) ||
            secretPromptQueue.contains(where: { $0.identity == identity }) { return .secret }
        if sudoClear.contains(where: { $0.0 == identity }) ||
            sudoPromptQueue.contains(where: { $0.identity == identity }) { return .sudo }
        // During terminal handling the queue has just been removed, so infer
        // the method from the request's currently tracked prompt kind only.
        return nil
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

    private func noteRecoveryTerminal(_ event: HermesGatewayEvent) {
        guard let sequence = event.sequence,
              let observation = recoveryPromptObservation,
              observation.lifecycle == lifecycle,
              observation.accepted || observation.terminalSequence == nil,
              sequence > observation.minimumEventSequence,
              runtime.state == .ready else { return }
        var updated = observation
        updated.terminalSequence = max(observation.terminalSequence ?? sequence, sequence)
        recoveryPromptObservation = updated
        scheduleRecoveryCleanupIfReady()
    }

    private func scheduleRecoveryCleanupIfReady() {
        guard recoveryCleanupTask == nil,
              let observation = recoveryPromptObservation,
              observation.accepted,
              observation.terminalSequence != nil,
              recoveryMarker?.token == observation.token,
              !disposed,
              runState == .idle else { return }
        let ownerID = UUID()
        recoveryCleanupOwnerToken = observation.token
        recoveryCleanupOwnerID = ownerID
        recoveryCleanupTask = Task { [weak self] in
            guard let self else { return }
            await self.performRecoveryCleanup(observation: observation, ownerID: ownerID)
        }
    }

    private func performRecoveryCleanup(observation: RecoveryPromptObservation, ownerID: UUID) async {
        let ownerToken = observation.token
        var ownsBusy = false
        defer {
            if recoveryCleanupOwnerID == ownerID {
                recoveryCleanupTask = nil
                recoveryCleanupOwnerToken = nil
                recoveryCleanupOwnerID = nil
                if ownsBusy {
                    attachmentRecoveryIsBusy = false
                }
            }
        }
        guard !disposed,
              recoveryCleanupOwnerID == ownerID,
              recoveryCleanupOwnerToken == ownerToken,
              !attachmentRecoveryIsBusy,
              let marker = recoveryMarker,
              marker.token == observation.token,
              lifecycle == observation.lifecycle,
              binding == observation.binding,
              runtime.origin == observation.origin,
              runtime.state == .ready,
              runState == .idle else { return }
        attachmentRecoveryIsBusy = true
        ownsBusy = true
        do {
            let status = try await runtime.request("session.status", parameters: {
                guard !self.disposed,
                      self.lifecycle == observation.lifecycle,
                      self.binding == observation.binding,
                      self.runtime.origin == observation.origin,
                      self.runtime.connectionGeneration == observation.connectionGeneration,
                      self.runtime.state == .ready,
                      self.runState == .idle,
                      self.recoveryMarker?.token == marker.token else {
                    throw DirectSessionError.staleOperation
                }
                return self.rpcParams(observation.binding)
            })
            guard let output = status?.gatewayFields["output"]?.gatewayString,
                  output.components(separatedBy: .newlines).contains("Agent Running: No") else {
                throw DirectSessionError.invalidResponse
            }
            var seen = Set<String>()
            for path in recoveryDetachPaths where seen.insert(path).inserted {
                let result = try await runtime.request("image.detach", parameters: {
                    guard !self.disposed,
                          self.lifecycle == observation.lifecycle,
                          self.binding == observation.binding,
                          self.runtime.origin == observation.origin,
                          self.runtime.connectionGeneration == observation.connectionGeneration,
                          self.runtime.state == .ready,
                          self.runState == .idle,
                          self.recoveryMarker?.token == marker.token else {
                        throw DirectSessionError.staleOperation
                    }
                    return [
                        "session_id": .string(observation.binding.runtimeID),
                        "profile": .string(observation.binding.profile),
                        "path": .string(path)
                    ]
                })
                guard case .bool = result?.gatewayFields["detached"] else {
                    throw DirectSessionError.invalidResponse
                }
            }
            guard !disposed,
                  lifecycle == observation.lifecycle,
                  binding == observation.binding,
                  runtime.origin == observation.origin,
                  runtime.connectionGeneration == observation.connectionGeneration,
                  runtime.state == .ready,
                  runState == .idle,
                  recoveryMarker?.token == marker.token else {
                throw DirectSessionError.staleOperation
            }
            try clearRecoveryMarker(marker)
            recoveryPromptObservation = nil
        } catch {
            guard !disposed,
                  recoveryCleanupOwnerID == ownerID,
                  recoveryCleanupOwnerToken == ownerToken,
                  lifecycle == observation.lifecycle,
                  binding == observation.binding,
                  runtime.origin == observation.origin,
                  runtime.connectionGeneration == observation.connectionGeneration,
                  recoveryMarker?.token == marker.token else { return }
            recoveryStageUnknown = true
            attachmentRecoveryNeedsReset = true
            if !Task.isCancelled { onError?(error) }
            // Every failure intentionally leaves the marker in place.
        }
    }

    private func receive(_ event: HermesGatewayEvent) {
        guard !disposed else { return }
        if event.method == "local", event.type == "transport.closed" {
            if let attempt = activeBtw?.attemptID {
                activeBtw = nil
                onBtwOutcome?(.unknown(attemptID: attempt))
            }
            abandonBackgroundAttemptsAsUnknown()
            if runState != .idle { runState = .deliveryUnknown }
            approvalPromptQueue.removeAll()
            pendingApprovalPrompt = nil
            secretPromptQueue.removeAll()
            pendingSecretPrompt = nil
            sudoPromptQueue.removeAll()
            pendingSudoPrompt = nil
            return
        }
        if event.type == "sessions.changed" {
            transcriptDirty = true
            scheduleIdleRefresh()
            return
        }
        guard let binding, event.sessionID == binding.runtimeID else { return }
        if let sequence = event.sequence {
            latestEventSequence = max(latestEventSequence, sequence)
        }
        var clearColdResumeSuppressionAfterDelivery = false
        switch event.type {
        case "background.complete":
            if let taskID = event.payload?.gatewayFields["task_id"]?.gatewayString,
               let active = activeBackgroundByAttempt.values.first(where: { $0.taskID == taskID }),
               isCurrentBackgroundScope(active),
               let text = event.payload?.gatewayFields["text"]?.gatewayString {
                activeBackgroundByAttempt.removeValue(forKey: active.attemptID)
                onBackgroundOutcome?(.completed(
                    attemptID: active.attemptID,
                    taskID: taskID,
                    prompt: active.prompt,
                    text: text
                ))
            }
        case "btw.complete":
            if let active = activeBtw,
               isCurrentBtwScope(active),
               let expectedTaskID = active.taskID,
               event.payload?.gatewayFields["task_id"]?.gatewayString == expectedTaskID,
               event.payload?.gatewayFields["question"]?.gatewayString == active.question,
               let text = event.payload?.gatewayFields["text"]?.gatewayString {
                activeBtw = nil
                onBtwOutcome?(.completed(
                    attemptID: active.attemptID,
                    taskID: expectedTaskID,
                    question: active.question,
                    text: text
                ))
            }
        case "clarify.request":
            handleBlockingRequest(event)
        case "clarify.expire":
            handleBlockingExpiry(event)
        case "approval.request":
            handleApprovalRequest(event)
        case "secret.request":
            handleSecretRequest(event)
        case "sudo.request":
            handleSudoRequest(event)
        case "secret.expire":
            handleSensitiveExpiry(.secret, event: event)
        case "sudo.expire":
            handleSensitiveExpiry(.sudo, event: event)
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
                clearDirectBlockingForTerminal(event)
                noteRecoveryTerminal(event)
                terminalReceipt = "\(event.connectionGeneration ?? -1):\(event.sequence ?? -1)"
                if runState != .stopping {
                    runState = .idle
                    schedulePendingReasoningDrain()
                }
                scheduleRecoveryCleanupIfReady()
                clearColdResumeSuppressionAfterDelivery = true
            }
        case "message.complete":
            clearBlockingPromptForTerminal(event)
            clearDirectBlockingForTerminal(event)
            noteRecoveryTerminal(event)
            let receipt = "\(event.connectionGeneration ?? -1):\(event.sequence ?? -1)"
            guard terminalReceipt != receipt else { return }
            terminalReceipt = receipt
            if runState != .stopping {
                runState = .idle
                schedulePendingReasoningDrain()
            }
            scheduleRecoveryCleanupIfReady()
            onEvent?(event)
            suppressesColdResumedContent = false
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
        if clearColdResumeSuppressionAfterDelivery {
            suppressesColdResumedContent = false
        }
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
