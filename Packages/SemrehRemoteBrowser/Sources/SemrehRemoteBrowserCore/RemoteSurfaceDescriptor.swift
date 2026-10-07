import Foundation

/// Pixel dimensions of a remote surface or a local viewport area.
///
/// Platform-independent: no CoreGraphics dependency so core logic and tests
/// run on any host.
public struct PixelDimensions: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Client-side validity: positive and within the per-dimension safety ceiling.
    public var isValid: Bool {
        width > 0 && height > 0 && width <= 4096 && height <= 4096
    }

    public var pixelCount: Int { width * height }
}

/// Identifies one connection epoch.
///
/// A new epoch never restores cached human authority: any control lease bound
/// to the previous epoch is void.
public struct ConnectionEpoch: Equatable, Hashable, Sendable {
    public let id: UUID
    public let generation: UInt64

    public init(id: UUID = UUID(), generation: UInt64) {
        self.id = id
        self.generation = generation
    }
}

/// Identifies one remote surface revision series.
///
/// The generation changes when the remote surface resets; frames and leases
/// bound to an older generation are stale.
public struct SurfaceIdentity: Equatable, Hashable, Sendable {
    public let id: UUID
    public let generation: UInt64

    public init(id: UUID = UUID(), generation: UInt64) {
        self.id = id
        self.generation = generation
    }
}

/// Describes the remote surface the workspace is currently bound to.
public struct RemoteSurfaceDescriptor: Equatable, Hashable, Sendable {
    public let connection: ConnectionEpoch
    public let surface: SurfaceIdentity
    public let sourceDimensions: PixelDimensions

    /// Hostname only — never credential-bearing paths or query strings.
    public let hostDisplayName: String

    public init(
        connection: ConnectionEpoch,
        surface: SurfaceIdentity,
        sourceDimensions: PixelDimensions,
        hostDisplayName: String
    ) {
        self.connection = connection
        self.surface = surface
        self.sourceDimensions = sourceDimensions
        self.hostDisplayName = hostDisplayName
    }
}
