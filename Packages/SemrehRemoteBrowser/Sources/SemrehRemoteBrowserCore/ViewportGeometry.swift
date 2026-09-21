import Foundation

/// Local viewport rectangle in points.
public struct ViewportRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Maps remote content coordinates to local rendered coordinates.
///
/// Letterboxing reflects the aspect ratio: the source is aspect-fit into the
/// viewport and centered; there are no artificial top/bottom spacers.
/// Orientation and keyboard changes update the local transform only — never
/// the remote site's viewport.
public struct ViewportTransform: Equatable, Sendable {
    public let source: PixelDimensions
    public let viewportWidth: Double
    public let viewportHeight: Double
    /// Local zoom, clamped to 1...4.
    public let zoom: Double
    /// Local pan offset in points.
    public let panX: Double
    public let panY: Double
    /// Surface generation this transform was computed for.
    public let generation: UInt64

    public init(
        source: PixelDimensions,
        viewportWidth: Double,
        viewportHeight: Double,
        zoom: Double = 1,
        panX: Double = 0,
        panY: Double = 0,
        generation: UInt64
    ) {
        self.source = source
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.zoom = min(4, max(1, zoom))
        self.panX = panX
        self.panY = panY
        self.generation = generation
    }

    /// Aspect-fit scale of the source into the viewport, before local zoom.
    public var fitScale: Double {
        guard source.isValid, viewportWidth > 0, viewportHeight > 0 else { return 0 }
        return min(
            viewportWidth / Double(source.width),
            viewportHeight / Double(source.height)
        )
    }

    public var effectiveScale: Double { fitScale * zoom }

    /// Rendered content rect in viewport point coordinates.
    public var contentRect: ViewportRect {
        let width = Double(source.width) * effectiveScale
        let height = Double(source.height) * effectiveScale
        return ViewportRect(
            x: (viewportWidth - width) / 2 + panX,
            y: (viewportHeight - height) / 2 + panY,
            width: width,
            height: height
        )
    }

    /// Map a local viewport point to normalized remote coordinates.
    ///
    /// Returns nil for touches outside the rendered content: black-bar taps
    /// are rejected, never clamped onto real buttons.
    public func remotePoint(localX x: Double, localY y: Double) -> RemotePoint? {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let contentX = x - rect.x
        let contentY = y - rect.y
        guard contentX >= 0, contentY >= 0,
              contentX <= rect.width, contentY <= rect.height
        else { return nil }
        return RemotePoint(x: contentX / rect.width, y: contentY / rect.height)
    }

    /// Map normalized remote coordinates to a local viewport point.
    public func localPoint(for remote: RemotePoint) -> (x: Double, y: Double) {
        let rect = contentRect
        return (
            x: rect.x + remote.x * rect.width,
            y: rect.y + remote.y * rect.height
        )
    }
}

/// Input mode of the viewport. Watch gestures never emit remote input.
public enum ViewportInputMode: Equatable, Sendable {
    case watch
    case direct
    case trackpad
}

/// Frame admission decision.
public enum FrameDecision: Equatable, Sendable {
    case accept
    case dropInvalidDimensions
    case dropInvalidByteCount
    case dropOversized
    case dropStale
    case dropGenerationMismatch
}

/// Decide whether a frame payload may enter the decode pipeline.
///
/// Rejects invalid/nonfinite dimensions, oversized payloads, stale sequences
/// and generation mismatches before any allocation.
public func assessFrame(
    _ payload: FramePayload,
    currentGeneration: UInt64,
    lastAcceptedSequence: UInt64
) -> FrameDecision {
    guard payload.dimensions.isValid else { return .dropInvalidDimensions }
    guard payload.compressedByteCount >= 0,
          payload.compressedByteCount == payload.data.count
    else {
        return .dropInvalidByteCount
    }
    guard payload.data.count <= FramePipeline.Ceilings.maxCompressedBytes else {
        return .dropOversized
    }
    guard payload.dimensions.pixelCount <= FramePipeline.Ceilings.maxDecodedPixels else {
        return .dropOversized
    }
    guard payload.generation == currentGeneration else { return .dropGenerationMismatch }
    guard payload.sequence > lastAcceptedSequence else { return .dropStale }
    return .accept
}
