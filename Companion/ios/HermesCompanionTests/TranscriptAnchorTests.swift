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
}
