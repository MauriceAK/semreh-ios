import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// Measures intermediate native layout, not screenshot cadence or presented FPS.
/// A sealed prefix plus a short new block must never briefly contain two copies
/// of the old active block while nested renderer state catches up with source.
@MainActor
final class StreamingMarkdownLayoutTests: XCTestCase {
    func testSealingMultilineHeadingDoesNotTemporarilyDuplicateItsHeight() async throws {
        let heading = "# A long heading keeps the reader in place while the answer continues across several lines"
        try await assertSealingPreservesLayout(prefix: heading + "\n", appended: "Next")
    }

    func testSealingWrappedParagraphDoesNotTemporarilyDuplicateItsHeight() async throws {
        let paragraph = "The reader keeps these already received words in place. This deliberately wrapped paragraph is taller than the short paragraph that follows it. Unicode stays intact: café 👩🏽‍💻 العربية."
        try await assertSealingPreservesLayout(prefix: paragraph + "\n\n", appended: "Next")
    }

    func testSealingParagraphAfterOuterChunkCapKeepsCompletedBlocksInPlace() async throws {
        // The raw-source owner packs later paragraphs into a larger tail.
        // Exercise a semantic boundary inside that tail with the same host.
        let earlier = String(repeating: "Earlier paragraph.\n\n", count: 70)
        let paragraph = "These received words stay in place while a later paragraph grows across several lines and then finishes."
        try await assertSealingPreservesLayout(prefix: earlier + paragraph + "\n\n", appended: "Next")
    }

    func testFadeEligibilityExcludesMultipleTextAndCodeLayouts() {
        for source in ["A plain paragraph", "**Bold** and `inline`", "# A heading", "  # A heading\n"] {
            XCTAssertTrue(StreamingMarkdownRenderBudget.isSingleTextFadeCandidate(source), source)
        }
        for source in ["    code", "\tcode\n", "\n    code\n", "  \n\tcode", "```swift\ncode", "~~~",
                       "- Item", "1. Item", "-\tItem", "*\tItem", "+\tItem", "1.\tItem", "1)\tItem",
                       "-", "+", "*", "1.", "1)", "> Quote", "| Cell |", "First\nSecond", "![image](url)",
                       "$x$", #"\(x\)"#, "<span>text</span>"] {
            XCTAssertFalse(StreamingMarkdownRenderBudget.isSingleTextFadeCandidate(source), source)
        }
    }

#if DEBUG
    func testReenablingAnimationKeepsReceivedTextSolidAndOnlyFutureAppendsFade() async throws {
        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled,
            "This animated fixture requires system Reduce Motion off; do not silently skip its fade assertions")
        let defaults = UserDefaults.standard
        let key = StreamedTextAnimationSettings.isEnabledKey
        let saved = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let fixture = try StreamingGeometryFixture(content: "Received baseline")
        defer { fixture.tearDown() }
        await fixture.observeLayoutTurns()
        XCTAssertGreaterThan(ink(try fixture.pixels()), 0, "The mounted baseline must contain visible text")
        fixture.model.content += " active words"
        await fixture.observeLayoutTurns()
        let freshInk = ink(try fixture.pixels())
        fixture.model.clock += 0.2
        await fixture.observeLayoutTurns()
        XCTAssertGreaterThan(ink(try fixture.pixels()), freshInk, "The real animated child must fade future text")
        defaults.set(false, forKey: key)
        await fixture.observeLayoutTurns()
        let beforeAppend = try fixture.pixels()
        fixture.model.content += " and words received without animation"
        await fixture.observeLayoutTurns()
        let solid = try fixture.pixels()
        XCTAssertNotEqual(solid, beforeAppend, "The capture must include newly received words")
        fixture.model.clock += 0.2
        await fixture.observeLayoutTurns()
        XCTAssertEqual(try fixture.pixels(), solid, "Words received with animation off must already be solid")
        defaults.set(true, forKey: key)
        await fixture.observeLayoutTurns()
        XCTAssertEqual(try fixture.pixels(), solid,
            "With the fade clock frozen, remounting must keep all received words solid and in the same positions")
        fixture.model.content += " future words"
        await fixture.observeLayoutTurns()
        let nextFreshInk = ink(try fixture.pixels())
        fixture.model.clock += 0.2
        await fixture.observeLayoutTurns()
        XCTAssertGreaterThan(ink(try fixture.pixels()), nextFreshInk,
            "The remounted store must still fade later appended text")
    }

    private func ink(_ pixels: Data) -> Int {
        var total = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
            let alpha = Int(pixels[index + 3])
            total += (765 - rgb) * alpha / 255
        }
        return total
    }
#endif

    func testLongLiteralTailReachesFreshLayoutWithoutStaleProjection() async throws {
        // Cross the documented rich/literal budget and then seal literal leaves.
        // Rich -> literal may change style; test current-source parity, not a
        // promise of identical formatting during that existing fallback.
        let source = String(repeating: "A long paragraph keeps growing. ", count: 150) + " café 👩🏽‍💻"
        let fixture = try StreamingGeometryFixture(content: String(source.prefix(3_800)))
        defer { fixture.tearDown() }
        await fixture.observeLayoutTurns()
        for count in [4_100, 4_600, source.count] {
            let next = String(source.prefix(count))
            fixture.model.content = next
            await fixture.observeLayoutTurns()
            XCTAssertEqual(fixture.height(), fixture.freshHeight(next), accuracy: 1)
        }
    }

    private func assertSealingPreservesLayout(prefix: String, appended: String,
                                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try StreamingGeometryFixture(content: prefix)
        defer { fixture.tearDown() }
        await fixture.observeLayoutTurns()
        let before = fixture.height()
        let next = prefix + appended
        let reference = fixture.freshHeight(next)
        XCTAssertGreaterThan(before, 0, file: file, line: line)
        XCTAssertGreaterThan(reference, before, "The short appended block must add visible content.", file: file, line: line)

        fixture.probe.reset()
        fixture.model.content = next
        await fixture.observeLayoutTurns()
        let after = fixture.height()
        let heights = fixture.probe.heights
        let receipt = XCTAttachment(string: "sourceBytes=\(prefix.utf8.count)->\(next.utf8.count) width=320 before=\(before) fresh=\(reference) after=\(after) layoutHeights=\(heights)")
        receipt.name = "Streaming semantic-boundary native geometry"
        receipt.lifetime = .keepAlways
        add(receipt)

        XCTAssertFalse(heights.isEmpty, "The mounted renderer must have produced observed layout.", file: file, line: line)
        XCTAssertEqual(after, reference, accuracy: 1,
                       "The same mounted identity must reach the fresh renderer's complete layout.", file: file, line: line)
        XCTAssertLessThanOrEqual(try XCTUnwrap(heights.max(), file: file, line: line), max(before, reference) + 1,
                                "Sealing must not briefly duplicate the old active heading or paragraph above the new tail.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(heights.min(), file: file, line: line), min(before, reference) - 1,
                                   "An append must not briefly remove the already visible prefix.", file: file, line: line)
    }
}

@MainActor
private final class StreamingGeometryModel: ObservableObject {
    @Published var content: String
    @Published var clock: TimeInterval = 100
    init(content: String) { self.content = content }
}

/// Layout callbacks need not publish SwiftUI state. A lock also avoids assuming
/// executor isolation in the Layout protocol while keeping this observer inert.
private final class StreamingGeometryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CGFloat] = []
    var heights: [CGFloat] { lock.lock(); defer { lock.unlock() }; return samples }
    func reset() { lock.lock(); defer { lock.unlock() }; samples = [] }
    func record(_ height: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        if samples.last != height { samples.append(height) }
    }
}

private struct StreamingGeometryLayout: Layout {
    let probe: StreamingGeometryProbe
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: 320, height: nil)) ?? .zero
        probe.record(size.height)
        return size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: 320, height: nil))
    }
}

private struct StreamingGeometryRoot: View {
    @ObservedObject var model: StreamingGeometryModel
    let probe: StreamingGeometryProbe
    var body: some View {
        StreamingGeometryLayout(probe: probe) {
            StreamingMarkdownRenderer(content: model.content)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
#if DEBUG
        .environment(\.streamingMarkdownAnimationClock, model.clock)
#endif
    }
}

@MainActor
private final class StreamingGeometryFixture {
    let model: StreamingGeometryModel
    let probe: StreamingGeometryProbe
    private let host: UIHostingController<StreamingGeometryRoot>
    private let window: UIWindow
    private let previousKeyWindow: UIWindow?

    init(content: String) throws {
        let model = StreamingGeometryModel(content: content)
        let probe = StreamingGeometryProbe()
        self.model = model
        self.probe = probe
        host = UIHostingController(rootView: StreamingGeometryRoot(model: model, probe: probe))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    func height() -> CGFloat {
        _ = host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        // Compare the renderer itself, not UIHostingController's safe-area
        // additions (a mounted window differs from a fresh offscreen host).
        return probe.heights.last ?? 0
    }

    func freshHeight(_ content: String) -> CGFloat {
        let probe = StreamingGeometryProbe()
        let reference = UIHostingController(rootView: StreamingGeometryRoot(
            model: StreamingGeometryModel(content: content), probe: probe))
        _ = reference.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        return probe.heights.last ?? 0
    }

    func observeLayoutTurns() async {
        // Retain every synchronous fit between real main-run-loop turns, rather
        // than observing only the settled end state after all onChange work.
        for _ in 0..<12 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            _ = height()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    func pixels() throws -> Data {
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format)
        var drawn = false
        let image = renderer.image { _ in
            drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "The production hosting view must commit a captured frame")
        let cg = try XCTUnwrap(image.cgImage)
        var data = Data(count: cg.width * cg.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return data
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}
