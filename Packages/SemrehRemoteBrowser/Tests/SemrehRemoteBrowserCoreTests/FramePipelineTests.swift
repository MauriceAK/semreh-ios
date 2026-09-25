import Foundation
import XCTest
@testable import SemrehRemoteBrowserCore

private struct FakeDecodedImage: DecodedImage {}

private final class FakeDecoder: FrameDecoder {
    var inspectionCount = 0
    var decodeCount = 0
    var failDecode = false
    var inspectedDimensions: PixelDimensions?

    func inspectDimensions(of payload: FramePayload) -> PixelDimensions? {
        inspectionCount += 1
        return inspectedDimensions ?? payload.dimensions
    }

    func decode(_ payload: FramePayload) -> (any DecodedImage)? {
        decodeCount += 1
        return failDecode ? nil : FakeDecodedImage()
    }
}

private func makePayload(
    sequence: UInt64,
    generation: UInt64 = 1,
    width: Int = 200,
    height: Int = 100,
    bytes: Int = 1024,
    actualBytes: Int? = nil
) -> FramePayload {
    FramePayload(
        sequence: sequence,
        generation: generation,
        dimensions: PixelDimensions(width: width, height: height),
        compressedByteCount: bytes,
        data: Data(repeating: 0, count: actualBytes ?? max(bytes, 0))
    )
}

final class FramePipelineTests: XCTestCase {

    /// Synchronous executor: decode runs inline, deterministically.
    private func makePipeline(_ decoder: FakeDecoder? = nil)
        -> (FramePipeline, FakeDecoder)
    {
        let decoder = decoder ?? FakeDecoder()
        let pipeline = FramePipeline(decoder: decoder, decodeExecutor: { $0() })
        pipeline.reset(generation: 1)
        return (pipeline, decoder)
    }

    func testValidFrameDecodedAndDelivered() {
        let (pipeline, decoder) = makePipeline()
        var delivered: [DecodedFrame] = []
        pipeline.onFrame = { delivered.append($0) }

        pipeline.submit(makePayload(sequence: 1))

        XCTAssertEqual(decoder.decodeCount, 1)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].sequence, 1)
        XCTAssertEqual(pipeline.acceptedCount, 1)
        XCTAssertEqual(pipeline.droppedCount, 0)
    }

    func testOversizedFrameDroppedBeforeDecode() {
        let (pipeline, decoder) = makePipeline()
        var delivered = 0
        pipeline.onFrame = { _ in delivered += 1 }

        pipeline.submit(makePayload(sequence: 1, bytes: 5 * 1024 * 1024))

        XCTAssertEqual(decoder.decodeCount, 0)
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(pipeline.droppedCount, 1)
    }

    func testActualCompressedSizeAndMetadataMustAgree() {
        let (pipeline, decoder) = makePipeline()

        pipeline.submit(makePayload(sequence: 1, bytes: 1, actualBytes: 1024))
        pipeline.submit(makePayload(sequence: 2, bytes: -1, actualBytes: 0))

        XCTAssertEqual(decoder.inspectionCount, 0)
        XCTAssertEqual(decoder.decodeCount, 0)
        XCTAssertEqual(pipeline.droppedCount, 2)
    }

    func testEncodedDimensionsMustMatchBeforeFullDecode() {
        let decoder = FakeDecoder()
        decoder.inspectedDimensions = PixelDimensions(width: 201, height: 100)
        let (pipeline, _) = makePipeline(decoder)

        pipeline.submit(makePayload(sequence: 1, width: 200, height: 100))

        XCTAssertEqual(decoder.inspectionCount, 1)
        XCTAssertEqual(decoder.decodeCount, 0)
    }

    func testInvalidDimensionsDroppedBeforeDecode() {
        let (pipeline, decoder) = makePipeline()
        pipeline.submit(makePayload(sequence: 1, width: 0))
        XCTAssertEqual(decoder.decodeCount, 0)
        XCTAssertEqual(pipeline.droppedCount, 1)
    }

    func testStaleSequenceDropped() {
        let (pipeline, _) = makePipeline()
        pipeline.submit(makePayload(sequence: 5))
        pipeline.submit(makePayload(sequence: 3))
        XCTAssertEqual(pipeline.acceptedCount, 1)
        XCTAssertEqual(pipeline.droppedCount, 1)
    }

    func testGenerationMismatchDropped() {
        let (pipeline, _) = makePipeline()
        pipeline.submit(makePayload(sequence: 1, generation: 2))
        XCTAssertEqual(pipeline.droppedCount, 1)
    }

    func testLatestFrameWinsWhileDecoding() {
        let decoder = FakeDecoder()
        var captured: [() -> Void] = []
        let pipeline = FramePipeline(decoder: decoder, decodeExecutor: { captured.append($0) })
        pipeline.reset(generation: 1)
        var delivered: [UInt64] = []
        pipeline.onFrame = { delivered.append($0.sequence) }

        pipeline.submit(makePayload(sequence: 1)) // starts decoding
        pipeline.submit(makePayload(sequence: 2)) // pending
        pipeline.submit(makePayload(sequence: 3)) // replaces pending; latest wins
        XCTAssertEqual(captured.count, 1)

        captured.removeFirst()() // finish frame 1 -> starts frame 3
        XCTAssertEqual(captured.count, 1)
        captured.removeFirst()() // finish frame 3

        // Frame 2 was superseded while pending: delivered are 1 and 3 only.
        XCTAssertEqual(delivered, [1, 3])
        XCTAssertEqual(decoder.decodeCount, 2)
    }

    func testResetDropsPendingAndInvalidatesInflight() {
        let decoder = FakeDecoder()
        var captured: [() -> Void] = []
        let pipeline = FramePipeline(decoder: decoder, decodeExecutor: { captured.append($0) })
        pipeline.reset(generation: 1)
        var delivered = 0
        pipeline.onFrame = { _ in delivered += 1 }

        pipeline.submit(makePayload(sequence: 1, generation: 1))
        pipeline.submit(makePayload(sequence: 2, generation: 1))
        pipeline.reset(generation: 2) // drops pending + invalidates in-flight decode

        XCTAssertEqual(captured.count, 1)
        captured.removeFirst()() // stale decode finishes: must not deliver
        XCTAssertEqual(delivered, 0)

        // New generation starts fresh: sequence numbering restarts.
        pipeline.submit(makePayload(sequence: 1, generation: 2))
        XCTAssertEqual(captured.count, 1)
        captured.removeFirst()()
        XCTAssertEqual(delivered, 1)
    }

    func testResetNeverStartsNewDecodeUntilOldDecodeExits() {
        let decoder = FakeDecoder()
        var captured: [() -> Void] = []
        let pipeline = FramePipeline(decoder: decoder, decodeExecutor: { captured.append($0) })
        pipeline.reset(generation: 1)

        pipeline.submit(makePayload(sequence: 1, generation: 1))
        pipeline.reset(generation: 2)
        pipeline.submit(makePayload(sequence: 1, generation: 2))

        XCTAssertEqual(captured.count, 1, "reset must not create a second decode slot")
        captured.removeFirst()()
        XCTAssertEqual(decoder.decodeCount, 0, "invalidated work must skip full decode")
        XCTAssertEqual(captured.count, 1, "new generation starts after old work exits")

        captured.removeFirst()()
        XCTAssertEqual(decoder.decodeCount, 1)
    }

    func testCancelRemovesCallbacksAndDropsWork() {
        let decoder = FakeDecoder()
        var captured: [() -> Void] = []
        let pipeline = FramePipeline(decoder: decoder, decodeExecutor: { captured.append($0) })
        pipeline.reset(generation: 1)
        var delivered = 0
        pipeline.onFrame = { _ in delivered += 1 }

        pipeline.submit(makePayload(sequence: 1))
        pipeline.cancel()

        XCTAssertEqual(captured.count, 1)
        captured.removeFirst()() // in-flight decode finishes after cancel
        XCTAssertEqual(delivered, 0, "teardown must remove callbacks")
        XCTAssertEqual(
            decoder.decodeCount,
            0,
            "work cancelled before execution must skip the full image decode"
        )
    }

    func testDecodeFailureDropsFrameButContinues() {
        let decoder = FakeDecoder()
        decoder.failDecode = true
        let (pipeline, _) = makePipeline(decoder)
        var delivered = 0
        pipeline.onFrame = { _ in delivered += 1 }

        pipeline.submit(makePayload(sequence: 1))
        XCTAssertEqual(delivered, 0)

        decoder.failDecode = false
        pipeline.submit(makePayload(sequence: 2))
        XCTAssertEqual(delivered, 1)
    }
}
