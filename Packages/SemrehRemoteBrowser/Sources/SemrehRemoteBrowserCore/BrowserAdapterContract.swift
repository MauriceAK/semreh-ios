import Foundation

/// Identifier for one dispatched adapter command. Used to correlate
/// acknowledgements, rejections and lost-acknowledgement reports.
public typealias CommandID = UUID
/// Identifier for one granted control lease.
public typealias LeaseID = UUID

/// Normalized remote content coordinates, 0...1 in the source dimensions.
public struct RemotePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Explicit remote special keys. Only committed keys are sent, in order;
/// there is no desktop keyboard emulation.
public enum SpecialKey: String, Equatable, Sendable, CaseIterable {
    case backspace
    case enter
    case tab
    case escape

    /// Human-readable label for UI controls.
    public var displayName: String {
        switch self {
        case .backspace: return "Backspace"
        case .enter: return "Enter"
        case .tab: return "Tab"
        case .escape: return "Escape"
        }
    }
}

/// Actions the local client can ask the adapter to perform.
///
/// These are internal Swift abstractions, not Hermes endpoints. The adapter —
/// never the view — decides what actually happens.
public enum BrowserAdapterAction: Equatable, Sendable {
    case requestControl(requestID: UUID)
    case resumeHermes
    case insertText(String)
    case click(RemotePoint)
    case scroll(dx: Double, dy: Double)
    case specialKey(SpecialKey)
    case stopTask
}

/// A control grant issued by the adapter.
///
/// The controller accepts a grant only when it matches the pending request,
/// connection, surface and client, its revision is current, and no
/// unacknowledged commands are outstanding (adapter-reported quiescence).
public struct ControlGrant: Equatable, Sendable {
    public let requestID: UUID
    public let connection: ConnectionEpoch
    public let surface: SurfaceIdentity
    public let leaseID: LeaseID
    public let revision: UInt64

    public init(
        requestID: UUID,
        connection: ConnectionEpoch,
        surface: SurfaceIdentity,
        leaseID: LeaseID = LeaseID(),
        revision: UInt64
    ) {
        self.requestID = requestID
        self.connection = connection
        self.surface = surface
        self.leaseID = leaseID
        self.revision = revision
    }
}

/// One compressed remote surface frame.
public struct FramePayload: Equatable, Sendable {
    /// Monotonic per-surface-generation sequence number.
    public let sequence: UInt64
    /// Surface generation at capture time; must match the current generation.
    public let generation: UInt64
    public let dimensions: PixelDimensions
    public let compressedByteCount: Int
    public let data: Data

    public init(
        sequence: UInt64,
        generation: UInt64,
        dimensions: PixelDimensions,
        compressedByteCount: Int,
        data: Data
    ) {
        self.sequence = sequence
        self.generation = generation
        self.dimensions = dimensions
        self.compressedByteCount = compressedByteCount
        self.data = data
    }
}

/// Events an adapter reports to the client.
public enum BrowserAdapterEvent: Equatable, Sendable {
    case connected(RemoteSurfaceDescriptor, RemoteBrowserCapabilities)
    case connectionFailed(reason: String)
    case controlGranted(ControlGrant)
    case controlRequestRejected(requestID: UUID, reason: String)
    case commandAcknowledged(CommandID)
    case commandRejected(CommandID, reason: String)
    /// The adapter explicitly reports it cannot confirm a command's outcome.
    case acknowledgementLost(CommandID)
    case frameArrived(FramePayload)
    case surfaceChanged(SurfaceIdentity)
    case disconnected
    case sessionEnded
    /// The adapter reports no commands are in flight.
    case quiescent
}

/// Abstraction over whatever supplies the remote surface.
///
/// The default implementation reports unavailable and never grants control.
/// Fixtures are injected only from BrowserLab or tests — never from
/// production code paths.
public protocol BrowserAdapter: AnyObject {
    var capabilities: RemoteBrowserCapabilities { get }
    var onEvent: ((BrowserAdapterEvent) -> Void)? { get set }
    func connect()
    func disconnect()
    func perform(_ action: BrowserAdapterAction, commandID: CommandID)
}

/// The honest default adapter: reports unavailable, rejects everything,
/// never grants control, never emits frames.
public final class UnavailableBrowserAdapter: BrowserAdapter {
    public let capabilities = RemoteBrowserCapabilities.unavailable
    public var onEvent: ((BrowserAdapterEvent) -> Void)?

    public init() {}

    public func connect() {
        onEvent?(.connectionFailed(reason: "Browser unavailable: no adapter configured."))
    }

    public func disconnect() {}

    public func perform(_ action: BrowserAdapterAction, commandID: CommandID) {
        switch action {
        case .requestControl(let requestID):
            onEvent?(.controlRequestRejected(
                requestID: requestID,
                reason: "Browser unavailable: no adapter configured."
            ))
        default:
            onEvent?(.commandRejected(
                commandID,
                reason: "Browser unavailable: no adapter configured."
            ))
        }
    }
}
