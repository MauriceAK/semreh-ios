import UIKit
import XCTest
@testable import HermesCompanion

@MainActor
final class TranscriptAnchorTests: XCTestCase {
    private struct Harness {
        let controller: TranscriptController
        let table: UITableView
        let messages: [ChatMessage]
        let revision: UUID
    }
    private func readingHarness() throws -> Harness {
        let controller = TranscriptController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        controller.view.layoutIfNeeded()
        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let messages = (0..<60).map { ChatMessage(id: "anchor-\($0)", role: "assistant", text: "Message \($0). A stable line for reading geometry.", provisional: true) }
        let revision = UUID()
        controller.update(messages: Array(messages[20...]), hasMore: true, loading: false, latestRevision: revision)
        controller.view.layoutIfNeeded()
        // The real prepend path switches the controller into reading-history mode.
        controller.update(messages: messages, hasMore: true, loading: false, latestRevision: revision)
        table.setContentOffset(CGPoint(x: 0, y: table.rectForRow(at: IndexPath(row: 30, section: 0)).minY - 100), animated: false)
        table.layoutIfNeeded()
        return Harness(controller: controller, table: table, messages: messages, revision: revision)
    }
    private func queueFormatting(_ harness: Harness) throws {
        let path = try XCTUnwrap(harness.table.indexPathsForVisibleRows?.first)
        let cell = try XCTUnwrap(harness.table.cellForRow(at: path) as? BubbleCell)
        try XCTUnwrap(cell.onFormattingWillChange)()
    }
    private func settleSizing() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }
    func testShortMessageBubbleIsNotAVerticalPill() throws {
        let controller = TranscriptController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        controller.view.layoutIfNeeded()
        controller.update(messages: [.init(id: "short-hi", role: "user", text: "hi", provisional: false)], hasMore: false, loading: false, latestRevision: UUID())
        controller.view.layoutIfNeeded()
        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)) as? BubbleCell)
        let text = try XCTUnwrap(cell.contentView.subviews.flatMap(\.subviews).compactMap { $0 as? UITextView }.first)
        let bubble = try XCTUnwrap(text.superview)
        XCTAssertEqual(text.text, "hi")
        XCTAssertGreaterThanOrEqual(bubble.bounds.width, bubble.bounds.height, "A short outgoing message must remain a horizontal rounded bubble.")
        XCTAssertLessThanOrEqual(bubble.layer.cornerRadius, min(bubble.bounds.width, bubble.bounds.height) / 2)
        XCTAssertEqual(bubble.layer.cornerCurve, .continuous)
    }
    func testExplicitLatestMovesOverTimeAndCompletesAtMeasuredBottom() async throws {
        let harness = try readingHarness()
        let start = harness.table.contentOffset.y
        let bottom = harness.table.contentSize.height - harness.table.bounds.height + harness.table.adjustedContentInset.bottom
        XCTAssertGreaterThan(bottom - start, 100)
        harness.controller.update(messages: harness.messages, hasMore: true, loading: false, latestRevision: UUID())
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertEqual(harness.table.contentOffset.y, start, accuracy: 1, "Explicit Latest must begin from the reader's position.")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertGreaterThan(harness.table.contentOffset.y, start)
            XCTAssertLessThan(harness.table.contentOffset.y, bottom)
        }
        try await Task.sleep(for: .milliseconds(350))
        let measuredBottom = harness.table.contentSize.height - harness.table.bounds.height + harness.table.adjustedContentInset.bottom
        XCTAssertEqual(harness.table.contentOffset.y, measuredBottom, accuracy: 1)
    }
    private func settleLatest(_ harness: Harness) async throws {
        for _ in 0..<100 where harness.controller.isJumpingToLatest { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(harness.controller.isJumpingToLatest)
    }
    func testPassiveLayoutAndChromeDoNotFinishExplicitLatestEarly() async throws {
        let harness = try readingHarness()
        let start = harness.table.contentOffset.y
        harness.controller.update(messages: harness.messages, hasMore: true, loading: false, latestRevision: UUID())
        harness.controller.updateChrome(viewportInsets: .init(top: 80, left: 0, bottom: 160, right: 0), activity: .working)
        harness.controller.view.setNeedsLayout()
        harness.controller.view.layoutIfNeeded()
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertTrue(harness.controller.isJumpingToLatest)
            XCTAssertEqual(harness.table.contentOffset.y, start, accuracy: 1)
        }
        try await settleLatest(harness)
        XCTAssertEqual(harness.table.contentOffset.y + harness.table.bounds.height - 160, harness.table.contentSize.height, accuracy: 1)
    }
    func testUserDragCancelsLatestAnimationAndDeferredPinning() async throws {
        let harness = try readingHarness()
        let revision = UUID()
        harness.controller.update(messages: harness.messages, hasMore: true, loading: false, latestRevision: revision)
        try await Task.sleep(for: .milliseconds(80))
        var dragNotifications = 0
        harness.controller.onUserScrollBegan = { dragNotifications += 1 }
        harness.controller.scrollViewWillBeginDragging(harness.table)
        harness.table.contentOffset.y -= 100
        let dragged = harness.table.contentOffset.y
        harness.controller.update(messages: harness.messages, hasMore: true, loading: false, latestRevision: revision)
        harness.controller.view.setNeedsLayout()
        harness.controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(dragNotifications, 1)
        XCTAssertFalse(harness.controller.isJumpingToLatest)
        XCTAssertEqual(harness.table.contentOffset.y, dragged, accuracy: 1)
        harness.controller.scrollViewDidEndDragging(harness.table, willDecelerate: false)
    }
    func testSessionChangeCancelsLatestAnimationBeforeReplacingRows() async throws {
        let harness = try readingHarness()
        harness.controller.update(messages: harness.messages, hasMore: true, loading: false, latestRevision: UUID())
        try await Task.sleep(for: .milliseconds(50))
        let next = [ChatMessage(id: "next-session", role: "assistant", text: "Another conversation", provisional: false)]
        harness.controller.update(messages: next, hasMore: false, loading: false, latestRevision: UUID(), sessionID: "next")
        harness.controller.view.layoutIfNeeded()
        XCTAssertFalse(harness.controller.isJumpingToLatest)
        let offset = harness.table.contentOffset.y
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(harness.table.numberOfRows(inSection: 0), 1)
        XCTAssertEqual(harness.table.contentOffset.y, offset, accuracy: 1)
    }
    func testLatestUsesActualSystemReduceMotion() async throws {
        let harness = try readingHarness()
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        if let expected = ProcessInfo.processInfo.environment["COMPANION_TEST_EXPECT_REDUCED_MOTION"] {
            let requested = try XCTUnwrap(["1": true, "true": true, "0": false, "false": false][expected.lowercased()])
            XCTAssertEqual(reducedMotion, requested)
        }
        harness.controller.update(messages: harness.messages, hasMore: true, loading: false, latestRevision: UUID())
        XCTAssertEqual(harness.controller.isJumpingToLatest, !reducedMotion)
        if reducedMotion {
            XCTAssertEqual(harness.table.contentOffset.y + harness.table.bounds.height - harness.table.adjustedContentInset.bottom, harness.table.contentSize.height, accuracy: 1)
        }
        let attachment = XCTAttachment(string: "System Reduce Motion: \(reducedMotion). Explicit jump active after request: \(harness.controller.isJumpingToLatest).")
        attachment.name = "latest-system-reduce-motion"
        attachment.lifetime = .keepAlways
        add(attachment)
        try await settleLatest(harness)
    }
    func testFormattingRestoresAnchorCapturedBeforeDeferredGeometryChange() async throws {
        let harness = try readingHarness()
        let before = harness.table.contentOffset.y
        try queueFormatting(harness)
        // Reproduce UIKit reconciling geometry before the coalesced batch runs.
        harness.table.contentOffset.y += 24
        try await settleSizing()
        XCTAssertEqual(harness.table.contentOffset.y, before, accuracy: 1)
    }
    func testUserDragInvalidatesPendingFormattingAnchor() async throws {
        let harness = try readingHarness()
        try queueFormatting(harness)
        harness.controller.scrollViewWillBeginDragging(harness.table)
        harness.table.contentOffset.y += 80
        let dragged = harness.table.contentOffset.y
        try await settleSizing()
        XCTAssertEqual(harness.table.contentOffset.y, dragged, accuracy: 1)
        harness.controller.scrollViewDidEndDragging(harness.table, willDecelerate: false)
    }
    func testLatestKeepsFormattedTailVisibleAfterPendingReadingBatch() async throws {
        let harness = try readingHarness()
        var messages = harness.messages
        // Narrow proportional glyphs become much wider monospace code. This
        // exercises real raw-to-Markdown height growth, not an unchanged row.
        let raw = "```swift\n" + String(repeating: "i", count: 1000) + "\n```\n" + UUID().uuidString
        messages[59] = .init(id: "anchor-59", role: "assistant", text: raw, provisional: false)
        harness.controller.update(messages: messages, hasMore: true, loading: false, latestRevision: harness.revision)
        let last = IndexPath(row: 59, section: 0)
        // Move the viewport to the final row while retaining reading-history intent.
        harness.table.setContentOffset(CGPoint(x: 0, y: harness.table.contentSize.height - harness.table.bounds.height + harness.table.adjustedContentInset.bottom), animated: false)
        harness.table.layoutIfNeeded()
        let cell = try XCTUnwrap(harness.table.cellForRow(at: last) as? BubbleCell)
        let text = try XCTUnwrap(cell.contentView.subviews.flatMap(\.subviews).compactMap { $0 as? UITextView }.first)
        let beforeFormatting = try XCTUnwrap(cell.onFormattingWillChange)
        var plainHeight: CGFloat?
        let finalMessages = messages
        cell.onFormattingWillChange = { [weak controller = harness.controller, weak table = harness.table] in
            beforeFormatting() // Captures the old reading anchor for the deferred batch.
            guard let controller, let table else { return }
            plainHeight = table.rectForRow(at: last).height
            // Latest arrives after the batch captures its intent, but before the
            // actual formatting mutation and deferred height reconciliation.
            controller.update(messages: finalMessages, hasMore: true, loading: false, latestRevision: UUID())
        }
        for _ in 0..<100 {
            if plainHeight != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = try XCTUnwrap(plainHeight, "The actual Markdown formatting callback must run.")
        try await settleSizing()
        try await settleLatest(harness)
        XCTAssertFalse(text.text.contains("```"))
        let finalRow = harness.table.rectForRow(at: last)
        XCTAssertGreaterThan(finalRow.height, before + 20, "The regression must cause a real row-height increase.")
        XCTAssertLessThanOrEqual(finalRow.maxY, harness.table.contentOffset.y + harness.table.bounds.height - harness.table.adjustedContentInset.bottom + 1)
        let textBottom = text.convert(text.bounds, to: harness.controller.view).maxY
        let viewportBottom = harness.table.convert(harness.table.bounds, to: harness.controller.view).maxY
        XCTAssertLessThanOrEqual(textBottom, viewportBottom, "Latest must expose the formatted canonical tail.")
    }
    func testFormattingNotificationPrecedesActualTextMutation() async throws {
        let cell = BubbleCell(style: .default, reuseIdentifier: "bubble")
        let text = try XCTUnwrap(cell.contentView.subviews.flatMap(\.subviews).compactMap { $0 as? UITextView }.first)
        let raw = "**Formatted " + UUID().uuidString + "**"
        var before: String?
        cell.onFormattingWillChange = { before = text.text }
        cell.configure(.init(id: UUID().uuidString, role: "assistant", text: raw, provisional: false))
        for _ in 0..<100 {
            if before != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(before, raw)
        XCTAssertEqual(text.text, String(raw.dropFirst(2).dropLast(2)))
    }
    func testOverlayInsetsPreserveReaderAndLatestExposesTailAboveDock() async throws {
        let harness = try readingHarness()
        let before = harness.table.contentOffset.y
        let bounds = harness.table.bounds.size
        harness.controller.updateChrome(viewportInsets: .init(top: 132, left: 0, bottom: 180, right: 0), activity: .working)
        XCTAssertEqual(harness.table.bounds.size, bounds, "Floating controls must not shrink the transcript surface.")
        XCTAssertEqual(harness.table.contentOffset.y, before, accuracy: 1)
        XCTAssertEqual(harness.table.contentInset.bottom, 180)
        XCTAssertNotNil(harness.table.tableFooterView)
        harness.controller.update(messages: harness.messages, hasMore: true, loading: false, latestRevision: UUID())
        try await settleLatest(harness)
        let readableBottom = harness.table.contentOffset.y + harness.table.bounds.height - harness.table.contentInset.bottom
        XCTAssertEqual(readableBottom, harness.table.contentSize.height, accuracy: 1)
        let footer = try XCTUnwrap(harness.table.tableFooterView)
        let activity = try XCTUnwrap(footer.subviews.first(where: { $0.accessibilityIdentifier == "workingIndicator" }))
        XCTAssertEqual(activity.accessibilityLabel, "Hermes is working")
        XCTAssertLessThan(activity.frame.midX, footer.bounds.midX)
        XCTAssertFalse(footer.isAccessibilityElement)
        XCTAssertTrue(activity.isAccessibilityElement)
        XCTAssertLessThanOrEqual(footer.frame.maxY, readableBottom + 1)
        harness.controller.updateChrome(viewportInsets: .init(top: 132, left: 0, bottom: 80, right: 0), activity: .idle)
        XCTAssertNil(harness.table.tableFooterView)
        XCTAssertEqual(harness.table.contentOffset.y + harness.table.bounds.height - 80, harness.table.contentSize.height, accuracy: 1)
    }

    func testWorkingBubbleAnimationsRespectSystemReduceMotion() throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = TranscriptController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.updateChrome(viewportInsets: .init(top: 80, left: 0, bottom: 80, right: 0), activity: .working)
        controller.update(messages: [.init(id: "motion-check", role: "user", text: "Check the working indicator.", provisional: false)], hasMore: false, loading: false, latestRevision: UUID())
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let footer = try XCTUnwrap(table.tableFooterView)
        let bubble = try XCTUnwrap(footer.subviews.first(where: { $0.accessibilityIdentifier == "workingIndicator" }))
        let dots = bubble.subviews
        let animationKeys = dots.map { $0.layer.animationKeys() ?? [] }
        let animationProperties = dots.map { dot in
            (dot.layer.animationKeys() ?? []).compactMap { (dot.layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath }
        }
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        let reducedTransparency = UIAccessibility.isReduceTransparencyEnabled
        let expectedFlag = ProcessInfo.processInfo.environment["COMPANION_TEST_EXPECT_REDUCED_MOTION"]
        let expectedTransparency = ProcessInfo.processInfo.environment["COMPANION_TEST_EXPECT_REDUCED_TRANSPARENCY"]
        let animatedDots = animationKeys.filter { !$0.isEmpty }.count
        let attachedToWindow = dots.allSatisfy { $0.window === window }
        let evidence: [String: Any] = [
            "systemReduceMotion": reducedMotion,
            "requestedReduceMotion": expectedFlag ?? "unspecified",
            "systemReduceTransparency": reducedTransparency,
            "requestedReduceTransparency": expectedTransparency ?? "unspecified",
            "dotCount": dots.count,
            "animatedDotCount": animatedDots,
            "animationCounts": animationKeys.map(\.count),
            "animationProperties": animationProperties,
            "attachedToWindow": attachedToWindow
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "working-bubble-system-motion.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        for (name, requested, actual) in [("Reduce Motion", expectedFlag, reducedMotion), ("Reduce Transparency", expectedTransparency, reducedTransparency)] {
            if let requested {
                let expected = try XCTUnwrap(["1": true, "true": true, "0": false, "false": false][requested.lowercased()], "Expected \(name) must be 1, 0, true, or false.")
                XCTAssertEqual(actual, expected, "The simulator's actual \(name) preference must match the requested verification mode.")
            }
        }
        XCTAssertEqual(dots.count, 3)
        XCTAssertTrue(attachedToWindow)
        XCTAssertEqual(animatedDots, reducedMotion ? 0 : 3)
        for properties in animationProperties {
            XCTAssertEqual(Set(properties), reducedMotion ? Set<String>() : Set(["opacity", "transform.translation.y"]))
        }
    }

}
