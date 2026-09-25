import Foundation

/// What the attached browser surface allows the local client to do.
///
/// These are adapter-reported capabilities, not client claims. The default
/// adapter reports no control.
public struct RemoteBrowserCapabilities: Equatable, Sendable {
    /// Whether the adapter can grant exclusive remote control.
    public let controlSupported: Bool
    /// Whether the adapter supplies an explicit stop-task capability.
    /// A Stop Task button appears only when this is true; stopping a video
    /// stream is not stopping Hermes.
    public let stopTaskSupported: Bool

    public init(controlSupported: Bool, stopTaskSupported: Bool) {
        self.controlSupported = controlSupported
        self.stopTaskSupported = stopTaskSupported
    }

    /// The honest default: unavailable, read-only, no capabilities.
    public static let unavailable = RemoteBrowserCapabilities(
        controlSupported: false,
        stopTaskSupported: false
    )
}
