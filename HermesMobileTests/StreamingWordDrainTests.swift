import XCTest
@testable import HermesMobile

final class StreamingWordDrainTests: XCTestCase {
    func testPresentationCadenceScalesWithGrowingRowAndInteraction() {
        XCTAssertEqual(StreamingWordDrain.presentationCadence(receivedByteCount: 0, prioritizingInteraction: false), 32_000_000)
        XCTAssertEqual(StreamingWordDrain.presentationCadence(receivedByteCount: 8_192, prioritizingInteraction: false), 64_000_000)
        XCTAssertEqual(StreamingWordDrain.presentationCadence(receivedByteCount: 32_768, prioritizingInteraction: false), 100_000_000)
        XCTAssertEqual(StreamingWordDrain.presentationCadence(receivedByteCount: 1_000, prioritizingInteraction: true), 100_000_000)
        XCTAssertEqual(StreamingWordDrain.presentationCadence(receivedByteCount: 1_000_000, prioritizingInteraction: true), 150_000_000)
        for bytes in [0, 8_192, 32_768, Int.max] {
            for interacting in [false, true] {
                XCTAssertLessThanOrEqual(
                    StreamingWordDrain.presentationCadence(receivedByteCount: bytes, prioritizingInteraction: interacting),
                    StreamingWordDrain.maximumBufferAgeNanoseconds
                )
            }
        }
    }

    func testBufferKeepsExactCountAndContentAcrossSmallDrainsAndAppends() {
        var buffer = StreamingWordDrain.Buffer()
        let chunks = ["  alpha ", "beta  ", "gamma\n", "delta ", "epsilon"]
        var received = ""
        var revealed = ""
        for chunk in chunks {
            buffer.append(chunk)
            received += chunk
            XCTAssertEqual(buffer.unitCount, StreamingWordDrain.unitCount(in: buffer.text))
            if buffer.unitCount > 1 {
                revealed += buffer.drain(maxUnits: 1)
                XCTAssertEqual(buffer.unitCount, StreamingWordDrain.unitCount(in: buffer.text))
            }
        }
        revealed += buffer.drainAll()
        XCTAssertEqual(revealed, received)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.unitCount, 0)
    }

    func testBufferPreservesUnicodeAcrossChunkBoundaryAndReplay() {
        var buffer = StreamingWordDrain.Buffer()
        let chunks = ["cafe", "\u{301} ", "👩‍", "👩‍👧‍👦 ", "🇫", "🇷 end"]
        for chunk in chunks {
            buffer.append(chunk)
            XCTAssertEqual(buffer.unitCount, StreamingWordDrain.unitCount(in: buffer.text))
        }
        let first = buffer.drain(maxUnits: 1)
        XCTAssertEqual(first, "cafe\u{301} ")
        XCTAssertEqual(first + buffer.drainAll(), chunks.joined())

        buffer.append("new reply ")
        XCTAssertEqual(buffer.unitCount, 2)
        buffer.clear() // stop/session replacement must discard the old tail
        buffer.append("fresh reply")
        XCTAssertEqual(buffer.drainAll(), "fresh reply")
    }

    func testBufferHandlesLargeBacklogWithoutRecountingOnEachDrain() {
        var buffer = StreamingWordDrain.Buffer()
        let input = String(repeating: "word ", count: 4_000)
        buffer.append(input)
        XCTAssertEqual(buffer.unitCount, 4_000)
        var output = ""
        for remaining in stride(from: 4_000, through: 1, by: -1) {
            XCTAssertEqual(buffer.unitCount, remaining)
            output += buffer.drain(maxUnits: 1)
        }
        XCTAssertEqual(output, input)
        XCTAssertTrue(buffer.isEmpty)
    }

    // MARK: - unitCount

    func testUnitCountEmptyTextIsZero() {
        XCTAssertEqual(StreamingWordDrain.unitCount(in: ""), 0)
    }

    func testUnitCountTextWithoutWhitespaceIsOneUnit() {
        XCTAssertEqual(StreamingWordDrain.unitCount(in: "chunk-0chunk-1chunk-2"), 1)
    }

    func testUnitCountWhitespaceOnlyTextIsOneUnit() {
        XCTAssertEqual(StreamingWordDrain.unitCount(in: "  \n\t "), 1)
    }

    func testUnitCountCountsWordsWithTrailingWhitespace() {
        XCTAssertEqual(StreamingWordDrain.unitCount(in: "alpha beta gamma"), 3)
        XCTAssertEqual(StreamingWordDrain.unitCount(in: "alpha beta gamma "), 3)
    }

    func testUnitCountLeadingWhitespaceAttachesToFirstUnit() {
        XCTAssertEqual(StreamingWordDrain.unitCount(in: "  alpha beta"), 2)
    }

    func testUnitCountTreatsConsecutiveWhitespaceAsOneSeparator() {
        XCTAssertEqual(StreamingWordDrain.unitCount(in: "alpha  \n\n beta\t\tgamma"), 3)
    }

    func testUnitCountHandlesGraphemeClusters() {
        XCTAssertEqual(StreamingWordDrain.unitCount(in: "👩‍👩‍👧‍👦 🇫🇷 café"), 3)
    }

    // MARK: - splitAtUnitBoundary

    func testSplitAtUnitBoundaryRoundTripsForEveryCount() {
        let text = "  alpha beta\n\ngamma  delta epsilon"
        let unitCount = StreamingWordDrain.unitCount(in: text)
        for count in 0...(unitCount + 2) {
            let (head, tail) = StreamingWordDrain.splitAtUnitBoundary(text, unitCount: count)
            XCTAssertEqual(head + tail, text, "head + tail must reproduce input for count \(count)")
        }
    }

    func testSplitAtUnitBoundaryZeroCountReturnsEverythingInTail() {
        let (head, tail) = StreamingWordDrain.splitAtUnitBoundary("alpha beta", unitCount: 0)
        XCTAssertEqual(head, "")
        XCTAssertEqual(tail, "alpha beta")
    }

    func testSplitAtUnitBoundaryTakesWordsWithTrailingWhitespace() {
        let (head, tail) = StreamingWordDrain.splitAtUnitBoundary("alpha  beta gamma", unitCount: 1)
        XCTAssertEqual(head, "alpha  ")
        XCTAssertEqual(tail, "beta gamma")
    }

    func testSplitAtUnitBoundaryCountBeyondBacklogReturnsEverythingInHead() {
        let (head, tail) = StreamingWordDrain.splitAtUnitBoundary("alpha beta", unitCount: 5)
        XCTAssertEqual(head, "alpha beta")
        XCTAssertEqual(tail, "")
    }

    func testSplitAtUnitBoundaryNeverSplitsGraphemeClusters() {
        let (head, tail) = StreamingWordDrain.splitAtUnitBoundary("👩‍👩‍👧‍👦 x", unitCount: 1)
        XCTAssertEqual(head, "👩‍👩‍👧‍👦 ")
        XCTAssertEqual(tail, "x")
    }

    func testSplitAtUnitBoundaryKeepsCombiningMarksWithBaseCharacter() {
        // "e" + U+0301 combine into one grapheme; the boundary after "café" must
        // include the combining mark in head.
        let text = "cafe\u{301} au lait"
        let (head, tail) = StreamingWordDrain.splitAtUnitBoundary(text, unitCount: 1)
        XCTAssertEqual(head, "cafe\u{301} ")
        XCTAssertEqual(tail, "au lait")
    }

    func testSplitAtUnitBoundaryLeadingWhitespaceStaysWithFirstUnit() {
        let (head, tail) = StreamingWordDrain.splitAtUnitBoundary("  alpha beta", unitCount: 1)
        XCTAssertEqual(head, "  alpha ")
        XCTAssertEqual(tail, "beta")
    }

    // MARK: - drainQuota

    func testDrainQuotaSmallBacklogDrainsOneWordPerTick() {
        // 10 words × 48ms = 480ms, under the 1s lag bound → steady cadence.
        XCTAssertEqual(
            StreamingWordDrain.drainQuota(
                backlogUnitCount: 10,
                cadenceNanoseconds: 48_000_000,
                maxLagNanoseconds: 1_000_000_000
            ),
            1
        )
    }

    func testDrainQuotaScalesWithBacklogToStayWithinLagBound() {
        // 1000 words × 48ms = 48s of backlog; quota must scale to drain in ~1s.
        let quota = StreamingWordDrain.drainQuota(
            backlogUnitCount: 1000,
            cadenceNanoseconds: 48_000_000,
            maxLagNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(quota, 48)
    }

    func testDrainQuotaNeverExceedsBacklog() {
        let quota = StreamingWordDrain.drainQuota(
            backlogUnitCount: 5,
            cadenceNanoseconds: 1_000_000_000,
            maxLagNanoseconds: 1_000_000
        )
        XCTAssertEqual(quota, 5)
    }

    func testDrainQuotaSingleUnitBacklogIsOne() {
        XCTAssertEqual(
            StreamingWordDrain.drainQuota(
                backlogUnitCount: 1,
                cadenceNanoseconds: 48_000_000,
                maxLagNanoseconds: 1_000_000_000
            ),
            1
        )
    }

    func testDrainQuotaZeroCadenceDrainsEverything() {
        XCTAssertEqual(
            StreamingWordDrain.drainQuota(
                backlogUnitCount: 7,
                cadenceNanoseconds: 0,
                maxLagNanoseconds: 1_000_000_000
            ),
            7
        )
    }

    func testDrainQuotaZeroLagBoundDrainsEverything() {
        XCTAssertEqual(
            StreamingWordDrain.drainQuota(
                backlogUnitCount: 7,
                cadenceNanoseconds: 48_000_000,
                maxLagNanoseconds: 0
            ),
            7
        )
    }
}
