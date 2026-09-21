import SwiftUI
import SemrehRemoteBrowserCore

/// Presentation state for the remote browser workspace.
///
/// Bridges `BrowserSessionController` (ownership/input policy),
/// `FramePipeline` (bounded frame delivery) and `TextDraft` (committed-text
/// entry) to SwiftUI. The default adapter reports unavailable; fixtures are
/// injected by BrowserLab or tests only.
@MainActor
public final class RemoteBrowserViewModel: ObservableObject {
    public let controller: BrowserSessionController
    private let adapter: BrowserAdapter
    private let pipeline: FramePipeline

    @Published public private(set) var state: BrowserSessionState
    @Published public private(set) var capabilities: RemoteBrowserCapabilities
    @Published public private(set) var hostDisplayName: String?
    @Published public private(set) var sourceDimensions: PixelDimensions?
    @Published public private(set) var surfaceGeneration: UInt64 = 0
    @Published public private(set) var displayedImage: DisplayableImage?
    @Published public private(set) var notice: String?

    @Published public var draft = TextDraft()
    @Published public var inputMode: ViewportInputMode = .direct

    /// Committed-text commands awaiting acknowledgement, correlated to the
    /// exact local draft revision that dispatched them. An old same-epoch ACK
    /// can never confirm a newer draft, even when its text is identical.
    private var pendingTextCommits: [CommandID: UInt64] = [:]
    private var draftRevision: UInt64 = 0

    public init(adapter: BrowserAdapter = UnavailableBrowserAdapter(), decoder: FrameDecoder) {
        let controller = BrowserSessionController(adapter: adapter)
        self.controller = controller
        self.adapter = adapter
        self.pipeline = FramePipeline(decoder: decoder)
        self.state = controller.state
        self.capabilities = controller.capabilities

        adapter.onEvent = { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.controller.handle(event)
                self.handleAdapterEvent(event)
            }
        }
        controller.onStateChange = { [weak self] newState in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state = newState
                self.capabilities = self.controller.capabilities
            }
        }
        controller.onCommandAcknowledged = { [weak self] commandID in
            DispatchQueue.main.async { [weak self] in self?.handleTextAck(commandID) }
        }
        controller.onCommandRejected = { [weak self] commandID, reason in
            DispatchQueue.main.async { [weak self] in self?.handleTextReject(commandID, reason: reason) }
        }
        controller.onAcknowledgementLost = { [weak self] commandID in
            DispatchQueue.main.async { [weak self] in self?.handleTextAckLost(commandID) }
        }
        pipeline.onFrame = { [weak self] frame in
            DispatchQueue.main.async { [weak self] in self?.ingest(frame) }
        }
    }

    deinit {
        pipeline.cancel()
    }

    // MARK: - Intents

    public func connect() { controller.connect() }
    public func reconnect() { controller.reconnect() }
    public func close() {
        invalidatePendingTextDelivery()
        controller.close()
    }
    public func handleBackground() {
        invalidatePendingTextDelivery()
        controller.handleBackground()
    }
    public func resumeHermes() { controller.resumeHermes() }

    public func requestControl() {
        notice = nil
        if controller.requestControl() == nil {
            notice = "Control is not available on this surface."
        }
    }

    /// Human input from viewport gestures (click/scroll). Zero commands are
    /// dispatched unless the session holds a current manual lease.
    public func sendInput(_ action: BrowserAdapterAction) {
        _ = controller.sendHumanCommand(action)
    }

    public func sendSpecialKey(_ key: SpecialKey) {
        _ = controller.sendHumanCommand(.specialKey(key))
    }

    public func stopTask() {
        _ = controller.sendHumanCommand(.stopTask)
    }

    // MARK: - Text draft

    public var draftText: String {
        get { draft.text }
        set {
            var updated = draft
            updated.edit(newValue)
            guard updated != draft else { return }
            draftRevision &+= 1
            draft = updated
        }
    }

    public var deliveryStatusText: String? {
        switch draft.delivery {
        case .idle: return nil
        case .sending: return "Sending…"
        case .unconfirmed: return "Delivery unconfirmed — kept locally, never resent automatically"
        case .confirmed: return "Delivered"
        case .rejected(let reason): return "Rejected: \(reason)"
        }
    }

    /// Commit the draft: only committed text is sent, exactly once.
    public func commitDraft() {
        guard controller.canSendHumanCommands else {
            notice = "Take control before inserting text."
            return
        }
        var updated = draft
        guard let text = updated.beginCommit() else { return }
        draft = updated
        if let commandID = controller.sendHumanCommand(.insertText(text)) {
            pendingTextCommits[commandID] = draftRevision
        } else {
            // Lost the lease between the check and the send: restore the
            // draft to idle with the text preserved.
            var restored = draft
            restored.edit(restored.text)
            draft = restored
            notice = "Control was lost before the text was sent."
        }
    }

    // MARK: - Presentation

    public var title: String {
        switch state {
        case .unavailable: return "Browser unavailable"
        case .connecting: return "Connecting…"
        case .watching: return "Watching Hermes"
        case .requestPending: return "Taking control…"
        case .manual: return "You're in control"
        case .resumePending(_, let known):
            return known ? "Resuming Hermes…" : "Resume status unknown"
        case .disconnected: return "Connection lost"
        case .ended: return "Browser session ended"
        }
    }

    public var subtitle: String {
        switch state {
        case .unavailable(let reason): return reason
        case .connecting: return "Establishing the remote surface…"
        case .watching(let supported):
            return supported ? "Remote input disabled" : "Read-only"
        case .requestPending: return "Waiting for the authoritative grant…"
        case .manual: return "Remote input enabled"
        case .resumePending(_, let known):
            return known
                ? "Input disabled while Hermes resumes"
                : "Acknowledgement lost — reconcile before continuing"
        case .disconnected: return "Control status not confirmed"
        case .ended: return hostDisplayName ?? ""
        }
    }

    public var accessibilityStatus: String {
        if let host = hostDisplayName, !host.isEmpty {
            return "\(title). \(host). \(subtitle)"
        }
        return "\(title). \(subtitle)"
    }

    public enum PrimaryAction {
        case takeControl
        case resume
        case reconnect
        case none
    }

    public var primaryAction: PrimaryAction {
        switch state {
        case .watching(let supported): return supported ? .takeControl : .none
        case .manual: return .resume
        case .disconnected: return .reconnect
        default: return .none
        }
    }

    public var showsProgress: Bool {
        switch state {
        case .connecting, .requestPending: return true
        default: return false
        }
    }

    public enum FooterMode {
        case hidden
        case watch
        case manual
    }

    public var footerMode: FooterMode {
        switch state {
        case .manual: return .manual
        case .watching, .requestPending, .connecting, .resumePending: return .watch
        case .unavailable, .disconnected, .ended: return .hidden
        }
    }

    /// The viewport's input mode: local viewing controls only unless manual.
    public var viewportMode: ViewportInputMode {
        controller.canSendHumanCommands ? inputMode : .watch
    }

    /// In manual mode show Keyboard, mode selector and Fit; in watch mode
    /// show only local viewing controls (Fit).
    public var showStopTask: Bool {
        capabilities.stopTaskSupported && controller.canSendHumanCommands
    }

    /// A stale frame must be shielded while disconnected.
    public var shieldStaleFrame: Bool {
        if case .disconnected = state { return true }
        return false
    }

    public var viewportInteractive: Bool {
        switch state {
        case .disconnected, .ended: return false
        default: return true
        }
    }

    // MARK: - Private

    private func handleAdapterEvent(_ event: BrowserAdapterEvent) {
        switch event {
        case .connected(let descriptor, _):
            invalidatePendingTextDelivery()
            pipeline.reset(generation: descriptor.surface.generation)
            hostDisplayName = descriptor.hostDisplayName
            sourceDimensions = descriptor.sourceDimensions
            surfaceGeneration = descriptor.surface.generation
            displayedImage = nil
            notice = nil
        case .surfaceChanged(let identity):
            invalidatePendingTextDelivery()
            pipeline.reset(generation: identity.generation)
            surfaceGeneration = identity.generation
            displayedImage = nil
        case .controlRequestRejected(_, let reason):
            notice = "Control request rejected: \(reason)"
        case .connectionFailed(let reason):
            invalidatePendingTextDelivery()
            notice = reason
        case .disconnected, .sessionEnded:
            invalidatePendingTextDelivery()
        case .frameArrived(let payload):
            pipeline.submit(payload)
        default:
            break
        }
    }

    private func ingest(_ frame: DecodedFrame) {
        guard frame.generation == surfaceGeneration else { return }
        #if canImport(UIKit)
        if let uiImage = (frame.image as? UIKitDecodedImage)?.image {
            displayedImage = uiImage
        }
        #endif
    }

    private func handleTextAck(_ commandID: CommandID) {
        guard pendingTextCommits.removeValue(forKey: commandID) == draftRevision else { return }
        draft.markConfirmed()
        draft.clearAfterConfirmation()
    }

    private func handleTextReject(_ commandID: CommandID, reason: String) {
        guard pendingTextCommits.removeValue(forKey: commandID) == draftRevision else { return }
        draft.markRejected(reason: reason)
    }

    private func handleTextAckLost(_ commandID: CommandID) {
        // Keep the command tracked so a late acknowledgement can still
        // confirm it; the draft stays preserved and marked unconfirmed.
        guard pendingTextCommits[commandID] == draftRevision else { return }
        draft.markUnconfirmed()
    }

    private func invalidatePendingTextDelivery() {
        guard !pendingTextCommits.isEmpty else { return }
        pendingTextCommits.removeAll()
        draft.invalidatePendingDelivery()
    }
}
