import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSessionMutationTests: APIClientTestCase {
    func testCompressionSummaryExtractsCompressedTokenEstimate() {
        let arrowSummary = SessionCompressionSummary(
            headline: "Compressed: 20 -> 10 messages",
            tokenLine: "Approx request size: ~30,100 \u{2192} ~10,347 tokens",
            note: nil,
            referenceMessage: nil
        )
        let asciiSummary = SessionCompressionSummary(
            headline: nil,
            tokenLine: "Rough transcript estimate: ~1200 -> ~320 tokens",
            note: nil,
            referenceMessage: nil
        )

        XCTAssertEqual(arrowSummary.compressedTokenEstimate, 10_347)
        XCTAssertEqual(asciiSummary.compressedTokenEstimate, 320)
    }

}
