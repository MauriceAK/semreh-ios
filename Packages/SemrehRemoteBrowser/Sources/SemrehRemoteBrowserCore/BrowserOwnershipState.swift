import Foundation

/// Proof that the local client currently holds remote control authority.
///
/// A lease is bound to one request, connection epoch, surface generation and
/// client identity. Any of those changing voids the lease.
public struct ControlLease: Equatable, Sendable {
    public let leaseID: LeaseID
    public let requestID: UUID
    public let connection: ConnectionEpoch
    public let surface: SurfaceIdentity
    public let revision: UInt64
    public let clientIdentity: UUID

    public init(
        leaseID: LeaseID,
        requestID: UUID,
        connection: ConnectionEpoch,
        surface: SurfaceIdentity,
        revision: UInt64,
        clientIdentity: UUID
    ) {
        self.leaseID = leaseID
        self.requestID = requestID
        self.connection = connection
        self.surface = surface
        self.revision = revision
        self.clientIdentity = clientIdentity
    }
}

/// Named session states from the fixed design contract.
public enum BrowserSessionState: Equatable, Sendable {
    case unavailable(reason: String)
    case connecting
    case watching(controlSupported: Bool)
    case requestPending(requestID: UUID)
    case manual(lease: ControlLease)
    /// Resume was explicitly requested. Input is disabled immediately.
    /// `outcomeKnown == false` means the acknowledgement was lost: the true
    /// authority state is UNKNOWN until reconciled by a fresh observation —
    /// it is never automatically treated as paused or resumed.
    case resumePending(lease: ControlLease, outcomeKnown: Bool)
    case disconnected
    case ended
}

/// Owns the browser workspace session state machine.
///
/// Rules enforced here:
/// - A grant must match the pending request, connection, surface and client;
///   its revision must be current and no unacknowledged commands may be
///   outstanding. Anything else dispatches zero human commands.
/// - Resume disables input before dispatch and needs a fresh-observation
///   acknowledgement for its success state; it never replays an uncertain
///   request.
/// - Disconnect, backgrounding and close clear held state and never emit an
///   implicit Resume.
/// - New connection epochs never restore cached human authority.
public final class BrowserSessionController {
    /// Stable identity of this local client for lease binding.
    public let clientIdentity: UUID

    private let adapter: BrowserAdapter

    public private(set) var state: BrowserSessionState
    public private(set) var currentSurface: RemoteSurfaceDescriptor?
    public private(set) var capabilities: RemoteBrowserCapabilities

    /// Commands dispatched but not yet acknowledged, rejected or reported lost.
    private var inflightCommands: [CommandID: BrowserAdapterAction] = [:]
    private var pendingResumeCommand: CommandID?
    private var lastSeenRevision: UInt64 = 0

    /// Grants ignored because they did not match the pending request,
    /// connection, surface, revision or quiescence requirements.
    public private(set) var ignoredGrantCount = 0
    /// Human commands accepted (dispatched to the adapter) this session.
    public private(set) var acceptedCommandCount = 0

    public var onStateChange: ((BrowserSessionState) -> Void)?
    public var onCommandAcknowledged: ((CommandID) -> Void)?
    public var onCommandRejected: ((CommandID, String) -> Void)?
    public var onAcknowledgementLost: ((CommandID) -> Void)?

    public init(adapter: BrowserAdapter, clientIdentity: UUID = UUID()) {
        self.adapter = adapter
        self.clientIdentity = clientIdentity
        self.capabilities = adapter.capabilities
        self.state = .unavailable(reason: "Browser unavailable: no connection attempted.")
    }

    // MARK: - Derived

    /// Human input commands may only be dispatched in `.manual` with a current lease.
    public var canSendHumanCommands: Bool {
        if case .manual = state { return true }
        return false
    }

    public var inflightCommandCount: Int { inflightCommands.count }

    // MARK: - User intents

    public func connect() {
        switch state {
        case .unavailable, .disconnected, .ended:
            transition(to: .connecting)
            adapter.connect()
        case .connecting, .watching, .requestPending, .manual, .resumePending:
            break
        }
    }

    public func reconnect() {
        guard case .disconnected = state else { return }
        transition(to: .connecting)
        adapter.connect()
    }

    /// Request exclusive control. Only valid while watching a surface that
    /// supports control. Returns the request ID, or nil when not allowed.
    @discardableResult
    public func requestControl() -> UUID? {
        guard case .watching(let supported) = state, supported else { return nil }
        let requestID = UUID()
        transition(to: .requestPending(requestID: requestID))
        adapter.perform(.requestControl(requestID: requestID), commandID: UUID())
        return requestID
    }

    /// Dispatch one human input command. Returns nil (dispatching zero
    /// commands) unless the session is `.manual` with a current lease.
    @discardableResult
    public func sendHumanCommand(_ action: BrowserAdapterAction) -> CommandID? {
        guard canSendHumanCommands else { return nil }
        switch action {
        case .click, .scroll, .insertText, .specialKey:
            break
        case .stopTask:
            guard capabilities.stopTaskSupported else { return nil }
        case .requestControl, .resumeHermes:
            // These go through their dedicated, validated paths.
            return nil
        }
        let commandID = UUID()
        inflightCommands[commandID] = action
        acceptedCommandCount += 1
        adapter.perform(action, commandID: commandID)
        return commandID
    }

    /// Explicitly resume Hermes. Input is disabled BEFORE the resume command
    /// is dispatched. Success requires the adapter's fresh-observation
    /// acknowledgement; the request is never replayed automatically.
    public func resumeHermes() {
        guard case .manual(let lease) = state else { return }
        let commandID = UUID()
        pendingResumeCommand = commandID
        inflightCommands[commandID] = .resumeHermes
        acceptedCommandCount += 1
        transition(to: .resumePending(lease: lease, outcomeKnown: true))
        adapter.perform(.resumeHermes, commandID: commandID)
    }

    /// Dismissal/background: stop local input, clear held state, never emit
    /// an implicit Resume.
    public func handleBackground() {
        switch state {
        case .manual, .requestPending, .resumePending, .watching, .connecting:
            inflightCommands.removeAll()
            pendingResumeCommand = nil
            transition(to: .disconnected)
        case .unavailable, .disconnected, .ended:
            break
        }
    }

    /// Close the workspace: stop input, clear held state, never emit an
    /// implicit Resume. Terminal until an explicit reconnect.
    public func close() {
        inflightCommands.removeAll()
        pendingResumeCommand = nil
        adapter.disconnect()
        transition(to: .ended)
    }

    // MARK: - Adapter events

    public func handle(_ event: BrowserAdapterEvent) {
        switch event {
        case .connected(let descriptor, let caps):
            handleConnected(descriptor: descriptor, capabilities: caps)
        case .connectionFailed(let reason):
            inflightCommands.removeAll()
            pendingResumeCommand = nil
            transition(to: .unavailable(reason: reason))
        case .controlGranted(let grant):
            handleGrant(grant)
        case .controlRequestRejected(let requestID, _):
            if case .requestPending(let pending) = state, pending == requestID {
                transition(to: .watching(controlSupported: capabilities.controlSupported))
            }
        case .commandAcknowledged(let commandID):
            inflightCommands.removeValue(forKey: commandID)
            onCommandAcknowledged?(commandID)
            if commandID == pendingResumeCommand,
               case .resumePending = state
            {
                pendingResumeCommand = nil
                // Fresh-observation acknowledgement: the success state.
                transition(to: .watching(controlSupported: capabilities.controlSupported))
            }
        case .commandRejected(let commandID, let reason):
            inflightCommands.removeValue(forKey: commandID)
            onCommandRejected?(commandID, reason)
            if commandID == pendingResumeCommand,
               case .resumePending(let lease, _) = state
            {
                pendingResumeCommand = nil
                transition(to: .resumePending(lease: lease, outcomeKnown: false))
            }
        case .acknowledgementLost(let commandID):
            inflightCommands.removeValue(forKey: commandID)
            onAcknowledgementLost?(commandID)
            if commandID == pendingResumeCommand,
               case .resumePending(let lease, _) = state
            {
                // UNKNOWN until reconciled — not automatically paused.
                pendingResumeCommand = nil
                transition(to: .resumePending(lease: lease, outcomeKnown: false))
            }
        case .quiescent:
            break
        case .frameArrived:
            // Frames are consumed by the viewport pipeline, not the controller.
            break
        case .surfaceChanged(let identity):
            handleSurfaceChanged(identity)
        case .disconnected:
            handleDisconnected()
        case .sessionEnded:
            inflightCommands.removeAll()
            pendingResumeCommand = nil
            transition(to: .ended)
        }
    }

    // MARK: - Private

    private func transition(to newState: BrowserSessionState) {
        state = newState
        onStateChange?(newState)
    }

    private func handleGrant(_ grant: ControlGrant) {
        guard case .requestPending(let pendingID) = state,
              grant.requestID == pendingID
        else {
            // Delayed grant for a superseded request, or no pending request:
            // dispatch zero human commands.
            ignoredGrantCount += 1
            return
        }
        guard let surface = currentSurface,
              grant.connection == surface.connection,
              grant.surface == surface.surface
        else {
            ignoredGrantCount += 1
            return
        }
        guard grant.revision >= lastSeenRevision else {
            ignoredGrantCount += 1
            return
        }
        // Explicit adapter-reported quiescence: no unacknowledged commands
        // may be outstanding when authority is granted.
        guard inflightCommands.isEmpty else {
            ignoredGrantCount += 1
            return
        }
        lastSeenRevision = grant.revision
        let lease = ControlLease(
            leaseID: grant.leaseID,
            requestID: grant.requestID,
            connection: grant.connection,
            surface: grant.surface,
            revision: grant.revision,
            clientIdentity: clientIdentity
        )
        transition(to: .manual(lease: lease))
    }

    private func handleConnected(
        descriptor: RemoteSurfaceDescriptor,
        capabilities caps: RemoteBrowserCapabilities
    ) {
        // `.ended` is terminal until an explicit reconnect.
        if case .ended = state { return }
        if let current = currentSurface,
           descriptor.connection != current.connection
        {
            // New connection epoch: never restore cached human authority.
            inflightCommands.removeAll()
            pendingResumeCommand = nil
        }
        currentSurface = descriptor
        capabilities = caps
        // A fresh connection observation reconciles an unknown resume outcome.
        transition(to: .watching(controlSupported: caps.controlSupported))
    }

    private func handleSurfaceChanged(_ identity: SurfaceIdentity) {
        if let descriptor = currentSurface {
            currentSurface = RemoteSurfaceDescriptor(
                connection: descriptor.connection,
                surface: identity,
                sourceDimensions: descriptor.sourceDimensions,
                hostDisplayName: descriptor.hostDisplayName
            )
        }
        switch state {
        case .manual, .requestPending, .resumePending:
            // The lease was bound to the old surface: void it.
            inflightCommands.removeAll()
            pendingResumeCommand = nil
            transition(to: .watching(controlSupported: capabilities.controlSupported))
        case .watching, .connecting, .disconnected, .unavailable, .ended:
            break
        }
    }

    private func handleDisconnected() {
        switch state {
        case .ended, .unavailable:
            break
        default:
            inflightCommands.removeAll()
            pendingResumeCommand = nil
            transition(to: .disconnected)
        }
    }
}
