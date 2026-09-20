import XCTest
@testable import HermesMobile

/// The Streaming Lab is `#if DEBUG`-only; the test target always builds
/// Debug, so the lab code is fully exercisable here.
final class StreamingLabReplayTests: XCTestCase {
    override func tearDown() {
        // Knob overrides are process-global; never leak a tuned value into
        // other suites (StreamingTextFadeTests reads the same defaults).
        StreamingTextFadeLab.shared.reset()
        super.tearDown()
    }

    // MARK: - Fixture shape

    func testFixtureContainsEveryShapeTheFadePipelineTreatsDifferently() {
        let fixture = StreamingLabReplay.fixture

        XCTAssertTrue(fixture.contains("\n\n"), "needs paragraph boundaries")
        XCTAssertTrue(fixture.contains("\n# "), "needs a heading")
        XCTAssertTrue(fixture.contains("\n- "), "needs flat bullets")
        XCTAssertTrue(fixture.contains("\n   - "), "needs nested list items")
        XCTAssertTrue(fixture.contains("\n1. "), "needs an ordered list")
        XCTAssertTrue(fixture.contains("```swift"), "needs a code fence")
        XCTAssertEqual(
            fixture.components(separatedBy: "```").count, 3,
            "the fence must be closed so text after it is fadeable"
        )
    }

    func testFixtureHasALongWrappingParagraph() {
        let longestLine = StreamingLabReplay.fixture
            .components(separatedBy: "\n")
            .map(\.count)
            .max() ?? 0
        XCTAssertGreaterThan(longestLine, 300, "needs a paragraph long enough to wrap several lines")
    }

    // MARK: - Realistic regression corpus

    func testRegressionCorpusDefinesNamedSmallMediumLargeMatrix() {
        XCTAssertEqual(StreamingLabReplay.fixtureMatrix.map(\.tier), [.small, .medium, .large])
        XCTAssertEqual(
            StreamingLabReplay.fixtureMatrix.map { [$0.conversationCount, $0.messagesPerConversation] },
            [[3, 8], [6, 24], [12, 50]]
        )
    }

    func testEveryRegressionTierIsMultiConversationAndReportsExactCounts() {
        let expectedUTF8Bytes: [StreamingLabReplay.FixtureTier: Int] = [
            .small: 10_635,
            .medium: 63_984,
            .large: 266_808
        ]

        for configuration in StreamingLabReplay.fixtureMatrix {
            let metadata = StreamingLabReplay.corpusMetadata(for: configuration.tier)
            let conversations = (0..<configuration.conversationCount).map {
                StreamingLabReplay.regressionConversation(at: $0, tier: configuration.tier)
            }

            XCTAssertGreaterThan(metadata.conversationCount, 1, "\(configuration.tier) collapsed to one conversation")
            XCTAssertEqual(metadata.conversationCount, configuration.conversationCount)
            XCTAssertEqual(metadata.messagesPerConversation, configuration.messagesPerConversation)
            XCTAssertEqual(metadata.totalMessageCount, configuration.conversationCount * configuration.messagesPerConversation)
            XCTAssertEqual(metadata.utf8ByteCount, conversations.reduce(0) { $0 + $1.utf8.count })
            XCTAssertEqual(metadata.utf8ByteCount, expectedUTF8Bytes[configuration.tier])
            XCTAssertEqual(metadata.contentKinds, Set(StreamingLabReplay.FixtureContentKind.allCases))
        }
    }

    func testEveryRegressionTierCoversMarkdownCodeToolsAndMedia() {
        for tier in StreamingLabReplay.FixtureTier.allCases {
            let conversation = StreamingLabReplay.regressionConversation(at: 0, tier: tier)

            XCTAssertTrue(conversation.contains("# How the fade should feel"), tier.rawValue)
            XCTAssertTrue(conversation.contains("```swift"), tier.rawValue)
            XCTAssertTrue(conversation.contains("**Tool activity fixture**"), tier.rawValue)
            XCTAssertTrue(conversation.contains("```json"), tier.rawValue)
            XCTAssertTrue(conversation.contains("MEDIA:/fixtures/performance/image-01.png"), tier.rawValue)
            XCTAssertTrue(conversation.contains("MEDIA:/fixtures/performance/clip-01.m4a"), tier.rawValue)
            XCTAssertTrue(conversation.contains("MEDIA:/fixtures/performance/document-01.pdf"), tier.rawValue)
        }
    }

    func testRegressionConversationSelectionIsDeterministicAndClamped() {
        for configuration in StreamingLabReplay.fixtureMatrix {
            let tier = configuration.tier
            XCTAssertEqual(
                StreamingLabReplay.regressionConversation(at: -1, tier: tier),
                StreamingLabReplay.regressionConversation(at: 0, tier: tier)
            )
            XCTAssertEqual(
                StreamingLabReplay.regressionConversation(at: 99, tier: tier),
                StreamingLabReplay.regressionConversation(at: configuration.conversationCount - 1, tier: tier)
            )
            XCTAssertNotEqual(
                StreamingLabReplay.regressionConversation(at: 0, tier: tier),
                StreamingLabReplay.regressionConversation(at: 1, tier: tier)
            )
        }
    }

    func testCorpusReportLabelsSyntheticEvidenceAndRequiresNativeAcceptance() {
        let report = StreamingLabReplay.corpusMetadata.report

        XCTAssertTrue(report.contains("synthetic_fixture=true"))
        XCTAssertTrue(report.contains("tier=large"))
        XCTAssertTrue(report.contains("conversations=12"))
        XCTAssertTrue(report.contains("total_messages=600"))
        XCTAssertTrue(report.contains("utf8_bytes=266808"))
        XCTAssertTrue(report.contains("native_device_acceptance=required_separately"))
    }

    // MARK: - Prefix paging

    func testPrefixAtTotalUnitCountReproducesTheFixtureExactly() {
        let fixture = StreamingLabReplay.fixture
        let total = StreamingLabReplay.fixtureUnitCount
        XCTAssertEqual(StreamingLabReplay.prefix(of: fixture, unitCount: total), fixture)
    }

    func testPrefixesGrowMonotonicallyAndStayPrefixesOfTheFixture() {
        let fixture = StreamingLabReplay.fixture
        let total = StreamingLabReplay.fixtureUnitCount
        var previous = ""

        for unitCount in 0...total {
            let current = StreamingLabReplay.prefix(of: fixture, unitCount: unitCount)
            XCTAssertTrue(current.hasPrefix(previous), "prefix shrank at unit \(unitCount)")
            XCTAssertTrue(fixture.hasPrefix(current), "not a prefix of the fixture at unit \(unitCount)")
            previous = current
        }

        XCTAssertEqual(previous, fixture)
    }

    func testPrefixAtZeroUnitsIsEmpty() {
        XCTAssertEqual(StreamingLabReplay.prefix(of: StreamingLabReplay.fixture, unitCount: 0), "")
    }

    // MARK: - Tick advance

    func testAdvanceAtProductionCadenceRevealsAboutOneUnitPerTick() {
        // 21 words/s at a 48ms tick deposits ~1.008 units per tick.
        var revealed = 0
        var carry = 0.0
        for _ in 0..<100 {
            (revealed, carry) = StreamingLabReplay.advance(
                revealed: revealed,
                carry: carry,
                wordsPerSecond: StreamingLabReplay.defaultWordsPerSecond
            )
        }
        // 100 ticks * 48ms * 21 words/s = 100.8 units of budget → 100 whole units.
        XCTAssertEqual(revealed, 100)
    }

    func testAdvanceAtHighSpeedRevealsSeveralUnitsPerTick() {
        let (revealed, _) = StreamingLabReplay.advance(
            revealed: 0,
            carry: 0,
            wordsPerSecond: StreamingLabReplay.maxWordsPerSecond
        )
        XCTAssertGreaterThanOrEqual(revealed, 3, "max speed must reproduce chunky multi-word ticks")
    }

    func testAdvanceBanksFractionalBudgetInsteadOfDroppingIt() {
        // A speed below one unit per tick must still make progress over time.
        var revealed = 0
        var carry = 0.0
        for _ in 0..<10 {
            (revealed, carry) = StreamingLabReplay.advance(
                revealed: revealed,
                carry: carry,
                wordsPerSecond: 2
            )
        }
        // 10 ticks * 48ms * 2 words/s = 0.96 units banked, none revealed yet…
        XCTAssertEqual(revealed, 0)
        XCTAssertEqual(carry, 0.96, accuracy: 0.0001)

        // …and the 11th tick crosses the unit boundary.
        (revealed, carry) = StreamingLabReplay.advance(revealed: revealed, carry: carry, wordsPerSecond: 2)
        XCTAssertEqual(revealed, 1)
    }

    func testAdvanceClampsNegativeInputs() {
        let (revealed, carry) = StreamingLabReplay.advance(
            revealed: 5,
            carry: -1,
            wordsPerSecond: -10
        )
        XCTAssertEqual(revealed, 5)
        XCTAssertEqual(carry, 0)
    }

    // MARK: - Knob overrides

    func testLabOverridesFlowThroughStreamingTextFadeDefaults() {
        StreamingTextFadeLab.shared.fadeDuration = 0.2
        StreamingTextFadeLab.shared.glyphStagger = 0.03
        StreamingTextFadeLab.shared.maxStampLead = 1.2

        XCTAssertEqual(StreamingTextFadeDefaults.fadeDuration, 0.2)
        XCTAssertEqual(StreamingTextFadeDefaults.glyphStagger, 0.03)
        XCTAssertEqual(StreamingTextFadeDefaults.maxStampLead, 1.2)
        // Derived values follow the knobs, exactly as in production.
        XCTAssertEqual(StreamingTextFadeDefaults.framePauseDelay, 1.2 + 0.2 + 0.1, accuracy: 0.0001)
        XCTAssertEqual(StreamingTextFadeDefaults.blockAbsorbDelay, 1.2 + 0.2 + 0.25, accuracy: 0.0001)
    }

    func testLabResetRestoresTheShippedBaseline() {
        StreamingTextFadeLab.shared.fadeDuration = 0.99
        StreamingTextFadeLab.shared.glyphStagger = 0.05
        StreamingTextFadeLab.shared.maxStampLead = 0.01

        StreamingTextFadeLab.shared.reset()

        XCTAssertEqual(StreamingTextFadeDefaults.fadeDuration, StreamingTextFadeDefaults.Baseline.fadeDuration)
        XCTAssertEqual(StreamingTextFadeDefaults.glyphStagger, StreamingTextFadeDefaults.Baseline.glyphStagger)
        XCTAssertEqual(StreamingTextFadeDefaults.maxStampLead, StreamingTextFadeDefaults.Baseline.maxStampLead)
    }
}
