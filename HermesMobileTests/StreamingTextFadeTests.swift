import MarkdownUI
import SwiftUI
import XCTest
@testable import HermesMobile

final class StreamingTextFadeTests: XCTestCase {
    private let fade = StreamingTextFadeDefaults.fadeDuration
    private let floorOpacity = StreamingTextFadeDefaults.floorOpacity

    func testBatchOpacityMatchesScalarAcrossBaselineAppendRepeatAndRollover() {
        for duration in [0.0, -1.0, 0.16, 0.5] {
            for floor in [0.0, 0.25, 1.0] {
                let scalar = StreamingTextFadeStampStore<Int>()
                let batch = StreamingTextFadeStampStore<Int>()
                func compare(_ keys: [Int?], _ clock: TimeInterval) {
                    scalar.register(keys.compactMap { $0 }, clock: clock)
                    let expected = keys.map {
                        scalar.opacity(for: $0, clock: clock, fadeDuration: duration, floorOpacity: floor)
                    }
                    XCTAssertEqual(batch.registerAndOpacities(keys, clock: clock,
                        fadeDuration: duration, floorOpacity: floor), expected)
                }
                compare([nil, 0, 0, 1], 0)
                // Batch reads must not finish the baseline themselves.
                compare([0, 2, nil], 0.01)
                scalar.finishBaseline()
                batch.finishBaseline()
                compare([0, 2, 3, 3, nil, 4], 1)
                compare([0, 2, 3, 3, nil, 4], 1.08)
                compare([0, 2, 3, 4, 5], 1.09)
                compare([3, 4, 5], 3)
                scalar.rolloverReset()
                batch.rolloverReset()
                compare([nil, 0, 0, 1], 3.01)
                compare([], 3.02)
                compare([0, 1], 4)
            }
        }
    }

    func testBatchOpacityMatchesScalarSharedChainOrderingAndCompression() {
        let scalarChain = StreamingTextFadeStampChain()
        let batchChain = StreamingTextFadeStampChain()
        let scalar = (0..<2).map { _ in StreamingTextFadeStampStore<Int>(chain: scalarChain) }
        let batch = (0..<2).map { _ in StreamingTextFadeStampStore<Int>(chain: batchChain) }
        for store in scalar + batch { store.finishBaseline() }
        for tick in 0..<8 {
            let block = tick % 2
            let keys: [Int?] = (0..<(100 + tick * 10)).map { Optional($0) } + [nil, 99]
            let clock = 10 + Double(tick) * 0.01
            scalar[block].register(keys.compactMap { $0 }, clock: clock)
            XCTAssertEqual(batch[block].registerAndOpacities(keys, clock: clock),
                           keys.map { scalar[block].opacity(for: $0, clock: clock) })
        }
        for block in 0..<2 {
            let keys: [Int?] = (0..<180).map { Optional($0) }
            scalar[block].register(keys.compactMap { $0 }, clock: 12)
            XCTAssertEqual(batch[block].registerAndOpacities(keys, clock: 12),
                           keys.map { scalar[block].opacity(for: $0, clock: 12) })
        }
    }

    func testLongKeyBatchScalarExactOutputsAndWorkAttachment() throws {
        let scalar = StreamingTextFadeStampStore<Int>()
        let batch = StreamingTextFadeStampStore<Int>()
        scalar.finishBaseline()
        batch.finishBaseline()
        let keys: [Int?] = (0..<8_000).map { $0 % 31 == 0 ? nil : $0 }
        var scalarCalls = 0
        var scalarLocks = 0
        var batchCalls = 0
        var batchLocks = 0
        for clock in [10.0, 10.08, 10.16, 11.0] {
            scalar.register(keys.compactMap { $0 }, clock: clock, glyphStagger: 0, maxStampLead: 0)
            scalarLocks += 1
            let expected = keys.map { key -> Double in
                scalarCalls += 1
                if key != nil { scalarLocks += 1 }
                return scalar.opacity(for: key, clock: clock, fadeDuration: 0.16)
            }
            let actual = batch.registerAndOpacities(keys, clock: clock,
                glyphStagger: 0, maxStampLead: 0, fadeDuration: 0.16)
            batchCalls += 1
            batchLocks += 1
            XCTAssertEqual(actual, expected)
            scalar.finishBaseline()
            batch.finishBaseline()
            scalarLocks += 1
            batchLocks += 1
        }
        XCTAssertEqual(scalarCalls, 32_000)
        XCTAssertEqual(batchCalls, 4)
        XCTAssertEqual(batchLocks, 8)
        XCTAssertEqual(scalarLocks, 8 + 4 * keys.compactMap { $0 }.count)
        let attachment = XCTAttachment(string:
            "Helper-only exact array parity; no FPS measurement. " +
            "scalarOpacityCalls=\(scalarCalls), batchOpacityCalls=\(batchCalls), " +
            "scalarStoreLocks=\(scalarLocks), batchStoreLocks=\(batchLocks). " +
            "Counts follow invoked APIs; exclude diagnostics and shared-chain locks.")
        attachment.name = "R54 bounded opacity API work comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

#if DEBUG
    @MainActor
    func testMountedProductionFadeStoreLazyLifetimeMatchesEagerPixels() async throws {
        let lazy = try await mountedFadeStoreFrames(eager: false)
        let eager = try await mountedFadeStoreFrames(eager: true)
        XCTAssertEqual(lazy.count, eager.count)
        for (index, pair) in zip(lazy, eager).enumerated() {
            assertFramePixelsEqual(pair.0, pair.1, "Mounted frame \(index)")
        }
    }

    private func assertFramePixelsEqual(_ lhs: [UInt8], _ rhs: [UInt8], _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, label, file: file, line: line)
        let differences = zip(lhs, rhs).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        XCTAssertEqual(differences, 0, label, file: file, line: line)
    }

    @MainActor
    private func mountedFadeStoreFrames(eager: Bool) async throws -> [[UInt8]] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .white
        let model = FadeStoreMountModel()
        let probe = StreamingFadeWorkProbe()
        let host = UIHostingController(rootView: FadeStoreMountRoot(model: model, eager: eager, probe: probe))
        host.view.backgroundColor = .white
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        var frames: [[UInt8]] = []
        var ink: [Int] = []
        var retained: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>?
        var expectedCreations = 1
        for step in 0..<8 {
            let previousBodies = step == 0 ? 0 : model.bodyCount
            switch step {
            case 1: model.clock = 1
            case 2: model.text += " appended"; model.clock = 2
            case 3: model.clock = 2.08
            case 4: model.clock = 2.2
            case 5:
                model.ordinal += 1
                model.armOnAppear = true
                model.text = "New block"
                model.clock = 3
                expectedCreations += 1
            case 6: model.clock = 3.2
            case 7:
                model.identity += 1
                model.text = "Replacement baseline"
                model.armOnAppear = false
                model.clock = 4
                expectedCreations += 1
            default: break
            }
            // Yield for real SwiftUI transactions, then force a visible frame.
            try await Task.sleep(for: .milliseconds(30))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(
                bounds: CGRect(x: 0, y: 0, width: 320, height: 240), format: format
            ).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            XCTAssertGreaterThan(model.bodyCount, previousBodies, "Step \(step) must update the production body")
            let store = try XCTUnwrap(model.store)
            if step == 0 || step == 5 || step == 7 {
                if let retained { XCTAssertFalse(retained === store) }
                retained = store
            } else {
                XCTAssertTrue(retained === store, "Clock/appends must retain the original store")
            }
            let creations = try XCTUnwrap(probe.snapshot()["fadeStoreCreations"])
            if eager {
                XCTAssertGreaterThanOrEqual(creations, step + 1)
            } else {
                XCTAssertEqual(creations, expectedCreations)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            frames.append(try rgbaPixels(cgImage))
            ink.append(darknessSum(in: cgImage))
        }
        XCTAssertGreaterThan(ink[0], 0, "Baseline must draw visible text")
        assertFramePixelsEqual(frames[0], frames[1], "Clock updates preserve baseline pixels")
        XCTAssertLessThan(ink[2], ink[3], "Appended text must fade, not remount as baseline")
        XCTAssertLessThan(ink[3], ink[4])
        XCTAssertLessThan(ink[5], ink[6], "New ordinal must honor armOnAppear")
        XCTAssertGreaterThan(ink[7], 0, "Replacement identity gets a fresh baseline")
        let attachment = XCTAttachment(string: "eager=\(eager), bodies=\(model.bodyCount), counters=\(probe.snapshot())")
        attachment.name = "R56 mounted production store construction"
        attachment.lifetime = .keepAlways
        add(attachment)
        return frames
    }

    @MainActor
    func testTrailingRendererScalarBatchExactPixelsForStyledUnicode() throws {
        let markdown = "**office affine** café e\u{301} 👩🏽‍💻 — العربية שלום *italic* `code`"
        let scalar = StreamingTextFadeStampStore<Text.Layout.CharacterIndex>()
        let batch = StreamingTextFadeStampStore<Text.Layout.CharacterIndex>()
        func compare(_ clock: TimeInterval) throws -> Int {
            let left = try trailingRendererImage(markdown, store: scalar, clock: clock, scalar: true)
            let right = try trailingRendererImage(markdown, store: batch, clock: clock, scalar: false)
            XCTAssertEqual(left.width, right.width)
            XCTAssertEqual(left.height, right.height)
            XCTAssertEqual(try rgbaPixels(left), try rgbaPixels(right))
            return darknessSum(in: left)
        }
        let baselineInk = try compare(0)
        XCTAssertGreaterThan(baselineInk, 0)
        scalar.rolloverReset()
        batch.rolloverReset()
        let freshInk = try compare(10)
        let partialInk = try compare(10.08)
        let settledInk = try compare(10.2)
        XCTAssertLessThan(freshInk, partialInk)
        XCTAssertLessThan(partialInk, settledInk)
        XCTAssertEqual(settledInk, baselineInk)
    }

    @MainActor
    private func trailingRendererImage(
        _ markdown: String, store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>,
        clock: TimeInterval, scalar: Bool
    ) throws -> CGImage {
        var fadeRenderer = StreamingTrailingContentOpacityRenderer(clock: clock, store: store)
        fadeRenderer.usesScalarOpacity = scalar
        let view = Markdown(markdown)
            .textRenderer(fadeRenderer)
            .frame(width: 320, alignment: .leading)
            .background(SwiftUI.Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
#endif

    // MARK: - StreamingTextFadeCurve

    func testCurveStartsAtFloorOpacity() {
        XCTAssertEqual(StreamingTextFadeCurve.opacity(age: 0), floorOpacity)
    }

    func testCurveReachesFullOpacityAtFadeDuration() {
        XCTAssertEqual(StreamingTextFadeCurve.opacity(age: fade), 1)
        XCTAssertEqual(StreamingTextFadeCurve.opacity(age: fade * 10), 1)
        XCTAssertEqual(StreamingTextFadeCurve.opacity(age: .infinity), 1)
    }

    func testCurveIsMonotonicallyIncreasingWithAge() {
        let ages = stride(from: 0.0, through: fade, by: fade / 20).map { $0 }
        let opacities = ages.map { StreamingTextFadeCurve.opacity(age: $0) }
        for (earlier, later) in zip(opacities, opacities.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }
    }

    func testCurveClampsNegativeAgeToFloor() {
        XCTAssertEqual(StreamingTextFadeCurve.opacity(age: -0.5), floorOpacity)
    }

    func testCurveZeroDurationIsAlwaysOpaque() {
        XCTAssertEqual(StreamingTextFadeCurve.opacity(age: 0, fadeDuration: 0), 1)
    }

    func testCurveProducesTrailingGradientAtWordCadence() {
        // Words stamped one #212 tick (48ms) apart: the newest must be the
        // faintest and each older word strictly more opaque until solid.
        let cadence = 0.048
        let newest = StreamingTextFadeCurve.opacity(age: 0)
        let previous = StreamingTextFadeCurve.opacity(age: cadence)
        let older = StreamingTextFadeCurve.opacity(age: cadence * 2)
        let oldest = StreamingTextFadeCurve.opacity(age: fade)

        XCTAssertLessThan(newest, previous)
        XCTAssertLessThan(previous, older)
        XCTAssertLessThan(older, oldest)
        XCTAssertEqual(oldest, 1)
    }

    // MARK: - StreamingTextFadeStampStore

    private let stagger = StreamingTextFadeDefaults.glyphStagger
    private let maxLead = StreamingTextFadeDefaults.maxStampLead

    func testStoreBaselineCharactersNeverFade() {
        let store = StreamingTextFadeStampStore<Int>()
        store.register([0, 1], clock: 0)
        XCTAssertEqual(store.opacity(for: 0, clock: 0), 1)
        XCTAssertEqual(store.opacity(for: 1, clock: 0), 1)
        store.finishBaseline()

        // Baseline characters stay opaque on every later frame too.
        XCTAssertEqual(store.opacity(for: 0, clock: 5), 1)
    }

    func testStoreNewCharacterAfterBaselineFadesIn() {
        let store = StreamingTextFadeStampStore<Int>()
        store.register([0], clock: 0)
        store.finishBaseline()

        store.register([1], clock: 1)
        XCTAssertEqual(store.opacity(for: 1, clock: 1), floorOpacity)
        let mid = store.opacity(for: 1, clock: 1 + fade / 2)
        XCTAssertGreaterThan(mid, floorOpacity)
        XCTAssertLessThan(mid, 1)
        XCTAssertEqual(store.opacity(for: 1, clock: 1 + fade), 1)
    }

    func testStoreRepeatRegisterKeepsOriginalStamp() {
        let store = StreamingTextFadeStampStore<Int>()
        store.rolloverReset()

        store.register([7], clock: 2)
        // Re-registering on later frames must not re-stamp (which would
        // reset the fade every frame).
        store.register([7], clock: 2 + fade / 2)
        store.register([7], clock: 2 + fade)
        XCTAssertEqual(store.opacity(for: 7, clock: 2 + fade), 1)
    }

    func testStoreBatchCascadesInReadingOrder() {
        // Glyphs arriving in one draw frame (a multi-word drain batch) must
        // reveal in sequence, newest-last — not as one chunk.
        let store = StreamingTextFadeStampStore<Int>()
        store.rolloverReset()

        store.register([1, 2, 3], clock: 10)
        let probe = 10 + stagger * 2
        let first = store.opacity(for: 1, clock: probe)
        let second = store.opacity(for: 2, clock: probe)
        let third = store.opacity(for: 3, clock: probe)
        XCTAssertGreaterThan(first, second)
        XCTAssertGreaterThan(second, third)
    }

    func testStoreQueueContinuesAcrossBatches() {
        // A glyph arriving one frame after a queued batch must reveal after
        // the queue tail, not jump in at arrival time.
        let store = StreamingTextFadeStampStore<Int>()
        store.rolloverReset()

        store.register([1, 2], clock: 10)
        store.register([3], clock: 10.001)
        let probe = 10 + stagger * 2 + 0.001
        XCTAssertGreaterThan(
            store.opacity(for: 2, clock: probe),
            store.opacity(for: 3, clock: probe)
        )
    }

    func testStoreLeadCompressionBoundsTheQueue() {
        // A huge batch must compress its pace so the last glyph's reveal
        // stays within maxStampLead of the clock.
        let store = StreamingTextFadeStampStore<Int>()
        store.rolloverReset()

        store.register(Array(0..<2_000), clock: 10)
        XCTAssertEqual(store.opacity(for: 1_999, clock: 10 + maxLead + fade), 1)
        // And it still cascades: the first glyph leads the last.
        let probe = 10 + maxLead / 2
        XCTAssertGreaterThan(
            store.opacity(for: 0, clock: probe),
            store.opacity(for: 1_999, clock: probe)
        )
    }

    func testStoreSaturatedQueueStaysBounded() {
        // Repeated batches at a saturated queue must not push reveals
        // arbitrarily far into the future.
        let store = StreamingTextFadeStampStore<Int>()
        store.rolloverReset()

        var nextKey = 0
        for tick in 0..<50 {
            let clock = 10 + Double(tick) * 0.048
            store.register(Array(nextKey..<(nextKey + 40)), clock: clock)
            nextKey += 40
        }
        let lastClock = 10 + 49 * 0.048
        XCTAssertEqual(store.opacity(for: nextKey - 1, clock: lastClock + maxLead + fade), 1)
    }

    func testStoreUnregisteredKeyIsOpaque() {
        let store = StreamingTextFadeStampStore<Int>()
        store.finishBaseline()
        XCTAssertEqual(store.opacity(for: 42, clock: 1), 1)
    }

    func testStoreNilKeyIsOpaque() {
        let store = StreamingTextFadeStampStore<Int>()
        store.finishBaseline()
        XCTAssertEqual(store.opacity(for: nil, clock: 1), 1)
    }

    func testStoreRolloverResetKeepsFadingArmed() {
        let store = StreamingTextFadeStampStore<Int>()
        store.register([0], clock: 0)
        store.finishBaseline()
        XCTAssertEqual(store.opacity(for: 0, clock: 5), 1)

        store.rolloverReset()

        // The same character offset belongs to a brand-new block now and
        // must fade in rather than inherit the old block's stamp.
        store.register([0], clock: 5)
        XCTAssertEqual(store.opacity(for: 0, clock: 5), floorOpacity)
        XCTAssertEqual(store.opacity(for: 0, clock: 5 + fade), 1)
    }

    func testStoreRolloverResetBeforeBaselineArmsFading() {
        let store = StreamingTextFadeStampStore<Int>()
        store.rolloverReset()

        // First content arriving into a previously empty tail fades in.
        store.register([0], clock: 1)
        XCTAssertEqual(store.opacity(for: 0, clock: 1), floorOpacity)
    }

    // MARK: - StreamedTextAnimationSettings

    func testAnimationSettingRoutesEverythingToHeadWhenDisabled() {
        // Int.max puts all blocks in the solid head — no fade renderer, no
        // frame clock (same mechanism as Reduce Motion).
        XCTAssertEqual(
            StreamedTextAnimationSettings.effectiveFirstFadeOrdinal(3, reduceMotion: false, isEnabled: false),
            Int.max
        )
        XCTAssertEqual(
            StreamedTextAnimationSettings.effectiveFirstFadeOrdinal(3, reduceMotion: true, isEnabled: true),
            Int.max
        )
        XCTAssertEqual(
            StreamedTextAnimationSettings.effectiveFirstFadeOrdinal(3, reduceMotion: false, isEnabled: true),
            3
        )
    }

    // MARK: - StreamingTextFadeStampChain

    func testChainedBlocksRevealInReadingOrder() {
        // The #234 lab inversion: a fast stream backlogs line 2's queue up to
        // maxStampLead, then line 3 starts a fresh store. Sharing one chain,
        // line 3 must queue behind line 2's tail instead of jumping to "now".
        let chain = StreamingTextFadeStampChain()
        let lineTwo = StreamingTextFadeStampStore<Int>(chain: chain)
        let lineThree = StreamingTextFadeStampStore<Int>(chain: chain)
        lineTwo.rolloverReset()
        lineThree.rolloverReset()

        lineTwo.register(Array(0..<2_000), clock: 10)
        lineThree.register([0, 1], clock: 10.001)

        // At every instant of the cascade, line 3's first glyph is never
        // more revealed than line 2's last glyph.
        for probe in stride(from: 10.0, through: 10 + maxLead + fade, by: 0.02) {
            XCTAssertLessThanOrEqual(
                lineThree.opacity(for: 0, clock: probe),
                lineTwo.opacity(for: 1_999, clock: probe),
                "line 3 overtook line 2's tail at clock \(probe)"
            )
        }
    }

    func testChainedBlockWithIdleChainStartsAtClock() {
        // When the previous block's cascade already drained, the next block
        // reveals immediately — chaining adds no artificial delay.
        let chain = StreamingTextFadeStampChain()
        let first = StreamingTextFadeStampStore<Int>(chain: chain)
        first.rolloverReset()
        first.register([0], clock: 10)

        let second = StreamingTextFadeStampStore<Int>(chain: chain)
        second.rolloverReset()
        second.register([0], clock: 20)
        XCTAssertEqual(second.opacity(for: 0, clock: 20), floorOpacity)
        XCTAssertEqual(second.opacity(for: 0, clock: 20 + fade), 1)
    }

    func testChainResetForgetsBacklog() {
        // Wholesale content replacement resets the cursor so the restarted
        // window does not inherit a stale future backlog.
        let chain = StreamingTextFadeStampChain()
        let before = StreamingTextFadeStampStore<Int>(chain: chain)
        before.rolloverReset()
        before.register(Array(0..<2_000), clock: 10)

        chain.reset()

        let after = StreamingTextFadeStampStore<Int>(chain: chain)
        after.rolloverReset()
        after.register([0], clock: 10.001)
        XCTAssertEqual(after.opacity(for: 0, clock: 10.001), floorOpacity)
        XCTAssertEqual(after.opacity(for: 0, clock: 10.001 + fade), 1)
    }

    // MARK: - StreamingTextFadeTailSplitter

    private func assertRoundTrip(_ text: String, from firstFadeOrdinal: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: firstFadeOrdinal)
        let joined = split.head + split.blocks.map(\.text).joined()
        XCTAssertEqual(joined, text, "head + block texts must reproduce the input", file: file, line: line)
    }

    func testSplitterEmptyText() {
        let split = StreamingTextFadeTailSplitter.split("", firstFadeOrdinal: 0)
        XCTAssertEqual(split.head, "")
        XCTAssertTrue(split.blocks.isEmpty)
        XCTAssertEqual(split.boundaryCount, 0)
    }

    func testSplitterSingleParagraphIsOneBlock() {
        let split = StreamingTextFadeTailSplitter.split("Hello **world**, streaming", firstFadeOrdinal: 0)
        XCTAssertEqual(split.head, "")
        XCTAssertEqual(split.blocks, [
            StreamingTextFadeTailSplitter.Block(ordinal: 0, text: "Hello **world**, streaming", fadeEnabled: true)
        ])
    }

    func testSplitterBlankLineSeparatesBlocks() {
        let text = "First paragraph.\n\nSecond paragraph still stre"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.boundaryCount, 1)
        XCTAssertEqual(split.blocks.map(\.text), ["First paragraph.\n\n", "Second paragraph still stre"])
        assertRoundTrip(text)
    }

    func testSplitterFirstFadeOrdinalMovesEarlierBlocksToHead() {
        let text = "First paragraph.\n\nSecond paragraph still stre"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 1)
        XCTAssertEqual(split.head, "First paragraph.\n\n")
        XCTAssertEqual(split.blocks.map(\.ordinal), [1])
        assertRoundTrip(text, from: 1)
    }

    func testSplitterFirstFadeOrdinalBeyondCountYieldsAllHead() {
        let text = "First paragraph.\n\nSecond"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: Int.max)
        XCTAssertEqual(split.head, text)
        XCTAssertTrue(split.blocks.isEmpty)
    }

    func testSplitterOrdinalsAreStableAcrossAppends() {
        let before = StreamingTextFadeTailSplitter.split("a\n\nb gro", firstFadeOrdinal: 0)
        let after = StreamingTextFadeTailSplitter.split("a\n\nb grows\n\nc starts", firstFadeOrdinal: 0)
        XCTAssertEqual(before.blocks[0].text, after.blocks[0].text)
        XCTAssertEqual(before.blocks[0].ordinal, after.blocks[0].ordinal)
        XCTAssertEqual(after.blocks.map(\.ordinal), [0, 1, 2])
    }

    func testSplitterTrailingBlankLineYieldsNoCurrentBlock() {
        let text = "First paragraph.\n\n"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 1)
        XCTAssertEqual(split.head, text)
        XCTAssertTrue(split.blocks.isEmpty)
    }

    func testSplitterSoftWrappedParagraphStaysOneBlock() {
        let text = "line one\nline two of the same paragraph"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.text), [text])
    }

    func testSplitterUnclosedFenceBlockIsNotFadeable() {
        let text = "Intro.\n\n```swift\nlet x = 1\n"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.fadeEnabled), [true, false])
        XCTAssertEqual(split.blocks[1].text, "```swift\nlet x = 1\n")
    }

    func testSplitterClosedFenceCreatesBoundaryAfterIt() {
        let text = "```swift\nlet x = 1\n```\nAfter the code"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.text), ["```swift\nlet x = 1\n```\n", "After the code"])
        XCTAssertEqual(split.blocks.map(\.fadeEnabled), [false, true])
        assertRoundTrip(text)
    }

    func testSplitterBlankLineInsideFenceIsNotABoundary() {
        let text = "```\nfirst\n\nsecond\n"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.boundaryCount, 0)
        XCTAssertEqual(split.blocks.map(\.fadeEnabled), [false])
    }

    func testSplitterTildeFenceIsRecognized() {
        let split = StreamingTextFadeTailSplitter.split("~~~\ncode\n", firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.fadeEnabled), [false])
    }

    func testSplitterHeadingLineIsABoundary() {
        let text = "## Section\nBody text streaming"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.text), ["## Section\n", "Body text streaming"])
    }

    func testSplitterStreamingHeadingWithoutNewlineIsCurrentBlock() {
        let text = "Intro.\n\n## Partial headi"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 1)
        XCTAssertEqual(split.head, "Intro.\n\n")
        XCTAssertEqual(split.blocks.map(\.text), ["## Partial headi"])
    }

    func testSplitterThematicBreakIsABoundary() {
        let text = "Before.\n---\nAfter words"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.text), ["Before.\n---\n", "After words"])
    }

    func testSplitterCompletedTopLevelItemsAreBoundaries() {
        // MarkdownUI renders one Text per list item, so each completed item
        // becomes its own fade block and only the in-progress item grows.
        let text = "Intro:\n\n- first item\n- second item\n- third streaming ite"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.text), [
            "Intro:\n\n",
            "- first item\n",
            "- second item\n",
            "- third streaming ite"
        ])
        assertRoundTrip(text)
    }

    func testSplitterCompletedOrderedItemsAreBoundaries() {
        let text = "1. alpha\n2. beta\n3. gamma still str"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 2)
        XCTAssertEqual(split.head, "1. alpha\n2. beta\n")
        XCTAssertEqual(split.blocks.map(\.text), ["3. gamma still str"])
        assertRoundTrip(text, from: 2)
    }

    func testSplitterNestedItemLinesAreNotBoundaries() {
        // Splitting a nested item into its own Markdown view would render it
        // un-nested and jump the layout when absorbed; it stays in its
        // parent's block instead.
        let text = "- parent item\n  - nested child\n  - second child gro"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.boundaryCount, 0)
        XCTAssertEqual(split.blocks.map(\.text), [text])
    }

    func testSplitterThematicBreakLineIsNotMistakenForBullet() {
        let text = "***\nAfter break words"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.text), ["***\n", "After break words"])
    }

    func testSplitterBlockquoteBlockIsNotFadeable() {
        let text = "Intro.\n\n> quoted words streaming"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.fadeEnabled), [true, false])
    }

    func testSplitterTableBlockIsNotFadeable() {
        let text = "Intro.\n\n| a | b |\n|---|---|\n| 1 | 2"
        let split = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0)
        XCTAssertEqual(split.blocks.map(\.fadeEnabled), [true, false])
    }

    func testSplitterRoundTripsAcrossShapesAndOrdinals() {
        let samples = [
            "",
            "word",
            "a\n\nb\n\nc",
            "Intro.\n\n```swift\ncode\n```\ntail",
            "## H\n\n- item one\n- item two",
            "1. a\n2. b\n3. c",
            "para\n\n",
            "  \n\t\n",
            "emoji 👩‍👩‍👧‍👦 tail café"
        ]
        for sample in samples {
            for ordinal in 0...4 {
                assertRoundTrip(sample, from: ordinal)
            }
        }
    }

    // MARK: - Mounted-identity split cache

#if DEBUG
    @MainActor
    func testSplitCacheReusesIdenticalLookupsAndEvictsPreviousKey() {
        let cache = StreamingTextFadeSplitCache()
        let text = "First **paragraph**.\n\nSecond 👩🏽‍💻"
        // First body and onAppear anchor share the all-solid split. Boundary
        // count does not depend on the ordinal used to produce that split.
        let initial = cache.split(text, firstFadeOrdinal: Int.max)
        XCTAssertEqual(cache.split(text, firstFadeOrdinal: Int.max), initial)
        XCTAssertEqual(cache.splitCount, 1)
        XCTAssertEqual(initial.boundaryCount,
                       StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: 0).boundaryCount)

        let anchored = cache.split(text, firstFadeOrdinal: initial.boundaryCount)
        for _ in 0..<10 {
            // Parent/theme/fade-active changes leave the split inputs intact.
            XCTAssertEqual(cache.split(text, firstFadeOrdinal: initial.boundaryCount), anchored)
        }
        XCTAssertEqual(cache.splitCount, 2)

        let appended = text + " appended"
        let advance = cache.split(appended, firstFadeOrdinal: initial.boundaryCount)
        XCTAssertEqual(cache.split(appended, firstFadeOrdinal: initial.boundaryCount), advance)
        XCTAssertEqual(cache.splitCount, 3, "advance and body share unchanged fade ordinal")
        _ = cache.split(text, firstFadeOrdinal: initial.boundaryCount)
        XCTAssertEqual(cache.splitCount, 4, "only the latest key is retained")

        let newIdentity = StreamingTextFadeSplitCache()
        XCTAssertEqual(newIdentity.split(text, firstFadeOrdinal: initial.boundaryCount), anchored)
        XCTAssertEqual(newIdentity.splitCount, 1, "new identity owns independent derived state")
        XCTAssertEqual(cache.splitCount, 4)
    }

    @MainActor
    func testSplitCacheParityAcrossStreamingShapesAndMotionSettings() {
        let cache = StreamingTextFadeSplitCache()
        let revisions = [
            "", "paragraph **bold** [link](https://example.com) العربية 👩🏽‍💻",
            "paragraph\n\nnext", "paragraph\n\nnext\n\n",
            "```swift\nlet café = 1\n", "```swift\nlet café = 1\n```\ntail",
            "~~~\ncode\n~~~\n", "- parent\n", "- parent\n  - nested child",
            "1. first\n2. second\n3. growing", "## Heading\n---\nnext",
            "> quote\n\n| a | b |\n|---|---|\n| 1 | 2 |",
            "replacement", "r", "", "new response\n\nend"
        ]
        for text in revisions {
            for rawOrdinal in [-1, 0, 1, 3, Int.max] {
                for (reduceMotion, enabled) in [(false, true), (true, true), (false, false), (false, true)] {
                    let ordinal = StreamedTextAnimationSettings.effectiveFirstFadeOrdinal(
                        rawOrdinal, reduceMotion: reduceMotion, isEnabled: enabled
                    )
                    let expected = StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: ordinal)
                    let actual = cache.split(text, firstFadeOrdinal: ordinal)
                    XCTAssertEqual(actual, expected)
                    XCTAssertEqual(Array((actual.head + actual.blocks.map(\.text).joined()).utf8), Array(text.utf8))
                    let count = cache.splitCount
                    XCTAssertEqual(cache.split(text, firstFadeOrdinal: ordinal), expected)
                    XCTAssertEqual(cache.splitCount, count)
                    if reduceMotion || !enabled {
                        XCTAssertTrue(actual.blocks.isEmpty)
                        XCTAssertEqual(Array(actual.head.utf8), Array(text.utf8))
                    }
                }
            }
        }
    }

    @MainActor
    func testSplitCacheOrdinalChangesAvoidBoundaryScansForLongActiveTails() {
        let paragraph = String(repeating: "Long `inline code` café 👩🏽‍💻 العربية $x^2$ ", count: 1_000)
        let samples = [paragraph, "Intro\n\n```swift\n" + paragraph + "\n\n" + paragraph]
        for text in samples {
            let cache = StreamingTextFadeSplitCache()
            let ordinals = [Int.max, 0, 1, 0, -1, Int.max, 0]
            for ordinal in ordinals {
                let actual = cache.split(text, firstFadeOrdinal: ordinal)
                XCTAssertEqual(actual, StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: ordinal))
                XCTAssertEqual(Array((actual.head + actual.blocks.map(\.text).joined()).utf8), Array(text.utf8))
            }
            XCTAssertEqual(cache.splitCount, ordinals.count, "assembly still runs for each ordinal change")
            XCTAssertEqual(cache.boundaryScanCount, 1, "long unchanged tail is scanned only once")
            XCTAssertEqual(cache.boundaryScanReuseCount, ordinals.count - 1)
            _ = cache.split(text, firstFadeOrdinal: ordinals.last!)
            XCTAssertEqual(cache.splitCount, ordinals.count, "identical lookups also avoid assembly")
            XCTAssertEqual(cache.boundaryScanReuseCount, ordinals.count - 1)
        }
    }

    @MainActor
    func testSplitCacheEveryScalarAppendAndOrdinalMatchesReference() {
        // Scalar boundaries include combining marks, ZWJ joins, and CR/LF
        // arriving separately, as well as every partial list/fence line.
        let samples = [
            "- parent\n  - child\n\tcontinuation\n- sibling\nend",
            "1. first\n2. second\n  nested\n3) last\n",
            "Intro\n\n```swift\nlet s = `value`\n\n```\ntail",
            "~~~\ncode\n~~~\n## heading\n---\n***\n",
            "cafe\u{301} 👩🏽‍💻 🇺🇳 العربية\r\n\r\nnext",
            "> quote\n\n| a | b |\n|---|---|\n| 1 | 2 |\n",
            "\n \n\t\nplain **bold** and $x^2$"
        ]
        for sample in samples {
            let cache = StreamingTextFadeSplitCache()
            var text = ""
            var revisions = [text]
            for scalar in sample.unicodeScalars {
                text.unicodeScalars.append(scalar)
                revisions.append(text)
            }
            for revision in revisions {
                let boundaryCount = StreamingTextFadeTailSplitter.split(revision, firstFadeOrdinal: 0).boundaryCount
                // Walk forward and backward through every possible split,
                // including empty trailing blocks and all-solid mode.
                let ordinals = [Int.min] + Array(0...(boundaryCount + 1))
                    + Array((0...(boundaryCount + 1)).reversed()) + [Int.max]
                for ordinal in ordinals {
                    let actual = cache.split(revision, firstFadeOrdinal: ordinal)
                    XCTAssertEqual(actual, StreamingTextFadeTailSplitter.split(revision, firstFadeOrdinal: ordinal))
                    XCTAssertEqual(Array((actual.head + actual.blocks.map(\.text).joined()).utf8), Array(revision.utf8))
                }
            }
            XCTAssertEqual(cache.boundaryScanCount, revisions.count, "one scan per distinct source revision")
            XCTAssertEqual(cache.splitCount, cache.boundaryScanCount + cache.boundaryScanReuseCount)
        }
    }

    @MainActor
    func testSplitCacheReplacementInvalidatesBoundariesEvenAtSameLength() {
        let cache = StreamingTextFadeSplitCache()
        let revisions = ["a\n\nb", "abcd", "- p\n", "- p\n  child", "```\nx\n", "x", "", "a\n\nb"]
        for (index, text) in revisions.enumerated() {
            for ordinal in [0, 1, Int.max, 0] {
                XCTAssertEqual(cache.split(text, firstFadeOrdinal: ordinal),
                               StreamingTextFadeTailSplitter.split(text, firstFadeOrdinal: ordinal))
            }
            XCTAssertEqual(cache.boundaryScanCount, index + 1)
            XCTAssertEqual(cache.boundaryScanReuseCount, (index + 1) * 3)
        }
    }

    @MainActor
    func testSplitCacheDistinguishesCanonicalUnicodeAndEffectiveOrdinal() {
        let cache = StreamingTextFadeSplitCache()
        let composed = "caf\u{e9}\n\ntail"
        let decomposed = "cafe\u{301}\n\ntail"
        XCTAssertEqual(composed, decomposed, "Swift equality alone is insufficient for this cache")
        _ = cache.split(composed, firstFadeOrdinal: 0)
        let replaced = cache.split(decomposed, firstFadeOrdinal: 0)
        XCTAssertEqual(cache.splitCount, 2)
        XCTAssertEqual(cache.boundaryScanCount, 2, "canonical equivalence must invalidate stored indices")
        XCTAssertEqual(Array(replaced.blocks.map(\.text).joined().utf8), Array(decomposed.utf8))
        let solid = cache.split(decomposed, firstFadeOrdinal: Int.max)
        XCTAssertEqual(cache.splitCount, 3)
        XCTAssertTrue(solid.blocks.isEmpty)
        XCTAssertEqual(Array(solid.head.utf8), Array(decomposed.utf8))
        _ = cache.split(decomposed, firstFadeOrdinal: 0)
        XCTAssertEqual(cache.splitCount, 4, "re-enabling motion must not reuse the all-solid result")
        XCTAssertEqual(cache.boundaryScanCount, 2)
        XCTAssertEqual(cache.boundaryScanReuseCount, 2)
    }
#endif

    // MARK: - StreamingTextFadeWindow

    func testWindowKeepsFreshBlocks() {
        let start = StreamingTextFadeWindow.advanceStart(
            current: 3,
            boundaryCount: 5,
            lastTouchedAt: [3: 100, 4: 100.5, 5: 101],
            now: 101,
            absorbDelay: 1.3
        )
        XCTAssertEqual(start, 3)
    }

    func testWindowAbsorbsBlocksUntouchedPastTheDelay() {
        let start = StreamingTextFadeWindow.advanceStart(
            current: 3,
            boundaryCount: 6,
            lastTouchedAt: [3: 100, 4: 100.1, 5: 105.9, 6: 106],
            now: 106,
            absorbDelay: 1.3
        )
        // Blocks 3 and 4 finished their cascade long ago; 5 is still fresh.
        XCTAssertEqual(start, 5)
    }

    func testWindowNeverAbsorbsTheCurrentBlock() {
        let start = StreamingTextFadeWindow.advanceStart(
            current: 2,
            boundaryCount: 2,
            lastTouchedAt: [:],
            now: 1_000,
            absorbDelay: 1.3
        )
        XCTAssertEqual(start, 2)
    }

    func testWindowCapForcesAbsorptionOfOldestBlocks() {
        let touched = Dictionary(uniqueKeysWithValues: (0...30).map { ($0, 100.0) })
        let start = StreamingTextFadeWindow.advanceStart(
            current: 0,
            boundaryCount: 30,
            lastTouchedAt: touched,
            now: 100.1,
            absorbDelay: 1.3
        )
        XCTAssertEqual(start, 30 - StreamingTextFadeWindow.maxBlocks + 1)
    }

    // MARK: - Renderer attach + opacity through the real MarkdownUI pipeline

    @MainActor
    func testFadeRendererAttachesThroughMarkdownUIAndAppliesStampOpacity() throws {
        let markdown = "Streaming fade attach probe with several plain words"
        let clock: TimeInterval = 1_000

        // Armed store: every character stamps at first sight → age 0 →
        // opacity 0 → no visible ink. If .textRenderer does not attach
        // through MarkdownUI's subtree, the text renders solid and this
        // test fails loudly.
        let armedStore = StreamingTextFadeStampStore<Text.Layout.CharacterIndex>()
        armedStore.rolloverReset()
        let fadedInk = try renderedDarkness(markdown: markdown, store: armedStore, clock: clock)

        // Untouched store: the first draw is the baseline → opacity 1.
        let baselineStore = StreamingTextFadeStampStore<Text.Layout.CharacterIndex>()
        let solidInk = try renderedDarkness(markdown: markdown, store: baselineStore, clock: clock)

        XCTAssertGreaterThan(solidInk, 0, "baseline render must produce visible text")
        XCTAssertLessThan(
            fadedInk, solidInk / 20,
            "age-zero stamps must render (near-)invisible — if not, the fade renderer is not attached through MarkdownUI"
        )
    }

    @MainActor
    func testFadeRendererCascadesInkOverTime() throws {
        let markdown = "Streaming fade cascade probe with several plain words"
        let clock: TimeInterval = 1_000

        let store = StreamingTextFadeStampStore<Text.Layout.CharacterIndex>()
        store.rolloverReset()
        // First render queues every glyph's reveal stamp from `clock`.
        let startInk = try renderedDarkness(markdown: markdown, store: store, clock: clock)
        let earlyInk = try renderedDarkness(markdown: markdown, store: store, clock: clock + 0.12)
        let lateInk = try renderedDarkness(markdown: markdown, store: store, clock: clock + 0.28)
        let doneInk = try renderedDarkness(
            markdown: markdown,
            store: store,
            clock: clock + maxLead + fade + 0.05
        )

        let solidStore = StreamingTextFadeStampStore<Text.Layout.CharacterIndex>()
        let solidInk = try renderedDarkness(markdown: markdown, store: solidStore, clock: clock)

        // Ink must bleed in progressively (the moving-gradient cascade), not
        // jump from invisible to solid in one step.
        XCTAssertLessThan(startInk, solidInk / 20)
        XCTAssertGreaterThan(earlyInk, Int(Double(solidInk) * 0.03), "cascade should have visibly started")
        XCTAssertLessThan(earlyInk, Int(Double(solidInk) * 0.7), "cascade should not be done this early")
        XCTAssertGreaterThan(lateInk, earlyInk, "ink must keep increasing through the cascade")
        XCTAssertGreaterThan(doneInk, Int(Double(solidInk) * 0.95), "cascade must finish fully solid")
    }

    @MainActor
    private func renderedDarkness(
        markdown: String,
        store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>,
        clock: TimeInterval
    ) throws -> Int {
        let view = Markdown(markdown)
            .textRenderer(StreamingTextFadeRenderer(clock: clock, store: store))
            .frame(width: 320, alignment: .leading)
            .background(SwiftUI.Color.white)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        return darknessSum(in: image)
    }

    /// Sum of per-pixel darkness vs. white; antialiasing-tolerant measure of
    /// how much ink the text laid down.
    private func darknessSum(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
            sum += max(0, 765 - rgb)
        }
        return sum
    }
}

#if DEBUG
@MainActor
private final class FadeStoreMountModel: ObservableObject {
    @Published var text = "Baseline text"
    @Published var clock: TimeInterval = 0
    @Published var ordinal = 0
    @Published var identity = 0
    @Published var armOnAppear = false
    let chain = StreamingTextFadeStampChain()
    var bodyCount = 0
    var store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>?
}

private struct FadeStoreMountRoot: View {
    @ObservedObject var model: FadeStoreMountModel
    let eager: Bool
    let probe: StreamingFadeWorkProbe

    var body: some View {
        StreamingFadeBlockView(
            text: model.text, colorScheme: .light, fadeEnabled: true,
            armOnAppear: model.armOnAppear, clock: model.clock, chain: model.chain,
            eagerConstruction: eager, probe: probe,
            observeStore: { store in
                model.bodyCount += 1
                model.store = store
            }
        )
        .id(model.ordinal)
        .id(model.identity)
        .frame(width: 320, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
#endif
