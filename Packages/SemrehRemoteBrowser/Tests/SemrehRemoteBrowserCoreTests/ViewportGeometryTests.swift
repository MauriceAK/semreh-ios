import XCTest
@testable import SemrehRemoteBrowserCore

final class ViewportGeometryTests: XCTestCase {

    private let source = PixelDimensions(width: 200, height: 100)

    func testAspectFitCentersContent() {
        // 200x100 source in a 100x100 viewport: fit scale 0.5, content 100x50,
        // centered with 25pt letterbox top and bottom.
        let t = ViewportTransform(
            source: source,
            viewportWidth: 100,
            viewportHeight: 100,
            generation: 1
        )
        XCTAssertEqual(t.fitScale, 0.5, accuracy: 1e-9)
        let rect = t.contentRect
        XCTAssertEqual(rect.x, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.y, 25, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 100, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 50, accuracy: 1e-9)
    }

    func testBlackBarTapsAreRejectedNotClamped() {
        let t = ViewportTransform(
            source: source,
            viewportWidth: 100,
            viewportHeight: 100,
            generation: 1
        )
        // Inside the top letterbox bar.
        XCTAssertNil(t.remotePoint(localX: 50, localY: 5))
        // Inside the bottom letterbox bar.
        XCTAssertNil(t.remotePoint(localX: 50, localY: 95))
        // Inside the content.
        XCTAssertNotNil(t.remotePoint(localX: 50, localY: 50))
    }

    func testCornerCenterMappingRoundTrip() {
        let t = ViewportTransform(
            source: source,
            viewportWidth: 100,
            viewportHeight: 100,
            generation: 1
        )
        let corners = [
            RemotePoint(x: 0, y: 0),
            RemotePoint(x: 1, y: 0),
            RemotePoint(x: 0, y: 1),
            RemotePoint(x: 1, y: 1),
            RemotePoint(x: 0.5, y: 0.5),
        ]
        for remote in corners {
            let local = t.localPoint(for: remote)
            let back = t.remotePoint(localX: local.x, localY: local.y)
            XCTAssertNotNil(back)
            XCTAssertEqual(back!.x, remote.x, accuracy: 1e-9)
            XCTAssertEqual(back!.y, remote.y, accuracy: 1e-9)
        }
        // Top-left of content sits at the letterbox edge, not at (0,0).
        let topLeft = t.localPoint(for: RemotePoint(x: 0, y: 0))
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 25, accuracy: 1e-9)
    }

    func testZoomIsClampedTo1To4() {
        let zoomedOut = ViewportTransform(
            source: source, viewportWidth: 100, viewportHeight: 100,
            zoom: 0.25, generation: 1
        )
        XCTAssertEqual(zoomedOut.zoom, 1)
        let zoomedIn = ViewportTransform(
            source: source, viewportWidth: 100, viewportHeight: 100,
            zoom: 10, generation: 1
        )
        XCTAssertEqual(zoomedIn.zoom, 4)
    }

    func testZoomScalesAroundCenter() {
        let t = ViewportTransform(
            source: source, viewportWidth: 100, viewportHeight: 100,
            zoom: 2, generation: 1
        )
        // 200x100 @ fit 0.5 @ zoom 2 -> 200x100 content, centered: (-50, 0).
        let rect = t.contentRect
        XCTAssertEqual(rect.width, 200, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 100, accuracy: 1e-9)
        XCTAssertEqual(rect.x, -50, accuracy: 1e-9)
        XCTAssertEqual(rect.y, 0, accuracy: 1e-9)
        // Center still maps to center.
        let center = t.remotePoint(localX: 50, localY: 50)
        XCTAssertEqual(center?.x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(center?.y ?? -1, 0.5, accuracy: 1e-9)
    }

    func testInvalidSourceYieldsNoMapping() {
        let t = ViewportTransform(
            source: PixelDimensions(width: 0, height: 100),
            viewportWidth: 100,
            viewportHeight: 100,
            generation: 1
        )
        XCTAssertEqual(t.fitScale, 0)
        XCTAssertNil(t.remotePoint(localX: 50, localY: 50))
    }

    // MARK: - Frame admission

    private func payload(
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

    func testValidFrameAccepted() {
        XCTAssertEqual(
            assessFrame(payload(sequence: 1), currentGeneration: 1, lastAcceptedSequence: 0),
            .accept
        )
    }

    func testInvalidDimensionsRejected() {
        XCTAssertEqual(
            assessFrame(payload(sequence: 1, width: 0), currentGeneration: 1, lastAcceptedSequence: 0),
            .dropInvalidDimensions
        )
        XCTAssertEqual(
            assessFrame(payload(sequence: 1, width: 5000), currentGeneration: 1, lastAcceptedSequence: 0),
            .dropInvalidDimensions
        )
    }

    func testOversizedFrameRejected() {
        XCTAssertEqual(
            assessFrame(
                payload(sequence: 1, bytes: 5 * 1024 * 1024),
                currentGeneration: 1,
                lastAcceptedSequence: 0
            ),
            .dropOversized
        )
        // 5000x5000 exceeds the decoded-pixel ceiling even though each
        // dimension alone would pass; use 3000x3000 = 9,000,000 > 8,388,608.
        XCTAssertEqual(
            assessFrame(
                payload(sequence: 1, width: 3000, height: 3000, bytes: 1024),
                currentGeneration: 1,
                lastAcceptedSequence: 0
            ),
            .dropOversized
        )
    }

    func testLyingOrNegativeByteMetadataRejected() {
        XCTAssertEqual(
            assessFrame(
                payload(sequence: 1, bytes: 1, actualBytes: 1024),
                currentGeneration: 1,
                lastAcceptedSequence: 0
            ),
            .dropInvalidByteCount
        )
        XCTAssertEqual(
            assessFrame(
                payload(sequence: 1, bytes: -1, actualBytes: 0),
                currentGeneration: 1,
                lastAcceptedSequence: 0
            ),
            .dropInvalidByteCount
        )
    }

    func testStaleSequenceRejected() {
        XCTAssertEqual(
            assessFrame(payload(sequence: 3), currentGeneration: 1, lastAcceptedSequence: 5),
            .dropStale
        )
    }

    func testGenerationMismatchRejected() {
        XCTAssertEqual(
            assessFrame(payload(sequence: 6, generation: 2), currentGeneration: 1, lastAcceptedSequence: 5),
            .dropGenerationMismatch
        )
    }
}
