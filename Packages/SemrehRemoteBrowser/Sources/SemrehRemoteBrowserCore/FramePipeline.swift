import Foundation

/// Opaque decoded image. The UI layer provides the concrete type.
public protocol DecodedImage: Sendable {}

/// A decoded frame ready for display.
public struct DecodedFrame: Sendable {
    public let sequence: UInt64
    public let generation: UInt64
    public let dimensions: PixelDimensions
    public let image: any DecodedImage

    public init(
        sequence: UInt64,
        generation: UInt64,
        dimensions: PixelDimensions,
        image: any DecodedImage
    ) {
        self.sequence = sequence
        self.generation = generation
        self.dimensions = dimensions
        self.image = image
    }
}

/// Decodes frame payloads. Implementations must run off the main thread;
/// the pipeline inspects dimensions before allocating.
public protocol FrameDecoder: AnyObject {
    /// Reads encoded image properties without allocating the full decoded
    /// bitmap. Returning nil rejects malformed or unsupported image data.
    func inspectDimensions(of payload: FramePayload) -> PixelDimensions?
    func decode(_ payload: FramePayload) -> (any DecodedImage)?
}

/// Bounded latest-frame delivery for remote surface frames.
///
/// - Dimensions are inspected before any allocation; malformed, oversized,
///   stale or generation-mismatched frames are dropped.
/// - At most one compressed frame waits while one decode runs, plus the
///   displayed image. When several frames arrive during a decode, the latest
///   wins; older pending frames are dropped.
/// - Teardown removes callbacks so no decoded frame outlives the pipeline.
public final class FramePipeline {
    /// Initial safety ceilings. These are configurable client ceilings, not
    /// upstream promises.
    public enum Ceilings {
        /// 4 MiB compressed image data.
        public static let maxCompressedBytes = 4 * 1024 * 1024
        /// 4096 pixels maximum per dimension.
        public static let maxDimensionPixels = 4096
        /// 8,388,608 decoded pixels.
        public static let maxDecodedPixels = 8_388_608
    }

    private let decoder: FrameDecoder
    private let decodeExecutor: (@escaping () -> Void) -> Void
    private let lock = NSLock()

    private var decoding = false
    private var pending: FramePayload?
    private var currentGeneration: UInt64 = 0
    private var lastAcceptedSequence: UInt64 = 0
    /// Invalidates in-flight decodes after cancel/reset.
    private var decodeToken: UInt64 = 0

    public private(set) var acceptedCount = 0
    public private(set) var droppedCount = 0

    public var onFrame: ((DecodedFrame) -> Void)?

    public init(
        decoder: FrameDecoder,
        decodeExecutor: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    ) {
        self.decoder = decoder
        self.decodeExecutor = decodeExecutor
    }

    /// Point the pipeline at a new surface generation. Stale frames, pending
    /// work and in-flight decodes for the old generation are dropped.
    public func reset(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        decodeToken &+= 1
        currentGeneration = generation
        lastAcceptedSequence = 0
        pending = nil
        // If an old decode is running, keep the one physical decode slot
        // occupied. A new-generation frame becomes the sole pending frame and
        // starts only after the old work exits.
    }

    public func submit(_ payload: FramePayload) {
        lock.lock()
        let decision = assessFrame(
            payload,
            currentGeneration: currentGeneration,
            lastAcceptedSequence: lastAcceptedSequence
        )
        guard decision == .accept else {
            droppedCount += 1
            lock.unlock()
            return
        }
        acceptedCount += 1
        lastAcceptedSequence = payload.sequence
        if decoding {
            // Bounded: keep at most one pending frame; the latest wins.
            pending = payload
            lock.unlock()
            return
        }
        decoding = true
        let token = decodeToken
        lock.unlock()
        decode(payload, token: token)
    }

    /// Teardown: drop pending and in-flight work and remove callbacks.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        decodeToken &+= 1
        pending = nil
        onFrame = nil
    }

    // MARK: - Private

    /// Starts a decode for a payload already admitted by `submit`/`finishDecode`.
    /// Re-validates the token so a reset/cancel that raced the handoff drops
    /// the stale frame instead of delivering it.
    private func decode(_ payload: FramePayload, token: UInt64) {
        decodeExecutor { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = token == self.decodeToken
            self.lock.unlock()
            guard isCurrent else {
                self.finishDecode(payload: payload, image: nil, token: token)
                return
            }
            guard let encodedDimensions = self.decoder.inspectDimensions(of: payload),
                  encodedDimensions == payload.dimensions,
                  encodedDimensions.isValid,
                  encodedDimensions.pixelCount <= Ceilings.maxDecodedPixels
            else {
                self.finishDecode(payload: payload, image: nil, token: token)
                return
            }
            let image = self.decoder.decode(payload)
            self.finishDecode(payload: payload, image: image, token: token)
        }
    }

    private func finishDecode(
        payload: FramePayload,
        image: (any DecodedImage)?,
        token: UInt64
    ) {
        lock.lock()
        let tokenIsCurrent = token == decodeToken
        let callback = tokenIsCurrent ? onFrame : nil
        let next = pending
        pending = nil
        let nextToken = decodeToken
        if next == nil {
            decoding = false
        }
        // else: decoding stays true; `next` starts below with nextToken.
        lock.unlock()

        if tokenIsCurrent, let image {
            callback?(DecodedFrame(
                sequence: payload.sequence,
                generation: payload.generation,
                dimensions: payload.dimensions,
                image: image
            ))
        }
        // A decode failure drops that frame; the pending frame still runs.
        if let next {
            decode(next, token: nextToken)
        }
    }
}
