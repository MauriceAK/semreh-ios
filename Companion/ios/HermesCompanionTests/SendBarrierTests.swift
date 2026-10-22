import UIKit
import XCTest
@testable import HermesCompanion

@MainActor
final class SendBarrierTests: XCTestCase {
    private var window: UIWindow!
    private var previousKeyWindow: UIWindow?
    private var controller: TranscriptController!
    private var table: UITableView!
    private var context: ConversationContext!
    private var revision = UUID()
    private let insets = UIEdgeInsets(top: 80, left: 0, bottom: 100, right: 0)

    override func setUp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        controller = TranscriptController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        context = .init(sessionID: "send-barrier", hostGeneration: UUID(), selectionGeneration: UUID())
        revision = UUID()
        render([], activity: .idle, sends: [])
    }

    override func tearDown() async throws {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
        controller = nil
        table = nil
        window = nil
    }

    private func render(_ messages: [ChatMessage], activity: TranscriptActivity, sends: [SendPresentationIntent]) {
        controller.render(messages: messages, hasMore: false, loading: false, latestRevision: revision,
            sessionID: context.sessionID, viewportInsets: insets, activity: activity,
            conversationContext: context, sends: sends)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
    }

    private func outgoing(_ text: String = "First line\nSecond line\nThird line\nFourth line", id: String = "pending", operation: String = "operation") -> ChatMessage {
        .init(id: id, role: "user", text: text, provisional: false, operationId: operation)
    }

    private func bubble() throws -> UIView {
        let footer = try XCTUnwrap(table.tableFooterView)
        return try XCTUnwrap(footer.subviews.first { $0.accessibilityIdentifier == "workingIndicator" })
    }

    func testNewWorkingWaitsForVisibleOutgoingWithoutFooterRelayout() async throws {
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        let completed = expectation(description: "Outgoing presentation completes")
        controller.onSendPresentation = { [weak self] _, outcome in
            XCTAssertEqual(outcome, .completed)
            XCTAssertTrue((try? self?.bubble().isHidden) == true)
            completed.fulfill()
        }
        render([outgoing()], activity: .working, sends: [intent])
        XCTAssertTrue(try bubble().isHidden)
        XCTAssertEqual(table.tableFooterView?.frame.height, 52)
        let row = table.rectForRow(at: .init(row: 0, section: 0))
        let offset = table.contentOffset
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertFalse(try bubble().isHidden)
        XCTAssertEqual(table.rectForRow(at: .init(row: 0, section: 0)), row)
        XCTAssertEqual(table.contentOffset, offset)
        XCTAssertEqual(table.tableFooterView?.frame.height, 52)
    }

    func testUserLineBreaksRemainLiteralEvenAfterSameTextWasFormattedForAssistant() async throws {
        let raw = "**First**\nSecond\nThird\nFourth"
        let cell = BubbleCell(style: .default, reuseIdentifier: "bubble")
        let text = try XCTUnwrap(cell.contentView.subviews.flatMap(\.subviews).compactMap { $0 as? UITextView }.first)
        cell.configure(.init(id: "assistant", role: "assistant", text: raw, provisional: false))
        for _ in 0..<100 where text.text == raw { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(text.text, raw)
        let user = outgoing(raw)
        let before = BubbleCell.height(user, width: 390, traits: controller.traitCollection)
        cell.configure(user)
        XCTAssertEqual(text.text, raw)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(text.text, raw)
        XCTAssertEqual(BubbleCell.height(user, width: 390, traits: controller.traitCollection), before)
        XCTAssertGreaterThan(before, 80)
    }

    func testLongOutgoingCompletesWhenItsTrailingPortionIsVisible() async throws {
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        let completed = expectation(description: "Long outgoing presentation completes")
        controller.onSendPresentation = { _, outcome in
            XCTAssertEqual(outcome, .completed)
            completed.fulfill()
        }
        render([outgoing((0..<100).map { "Line \($0)" }.joined(separator: "\n"))], activity: .working, sends: [intent])
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .completed)
        let row = table.rectForRow(at: .init(row: 0, section: 0))
        XCTAssertGreaterThan(row.height, table.bounds.height)
        XCTAssertLessThanOrEqual(row.maxY, table.contentOffset.y + table.bounds.height - insets.bottom)
        XCTAssertFalse(try bubble().isHidden)
    }

    func testDragHoldsNewWorkingUntilReaderReturnsToLatest() async throws {
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        var completions = 0
        let completed = expectation(description: "Outgoing presents after Latest")
        controller.onSendPresentation = { _, outcome in
            XCTAssertEqual(outcome, .completed)
            completions += 1
            completed.fulfill()
        }
        let rows = (0..<30).map { ChatMessage(id: "old-\($0)", role: "assistant", text: "Earlier reply", provisional: false) } + [outgoing()]
        render(rows, activity: .working, sends: [intent])
        controller.scrollViewWillBeginDragging(table)
        table.contentOffset.y -= 150
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(try bubble().isHidden)
        revision = UUID()
        render(rows, activity: .working, sends: [intent])
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertFalse(try bubble().isHidden)
    }

    func testRequestsAndStopRemainImmediateDuringOutgoingPresentation() throws {
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        for activity in [TranscriptActivity.waiting, .stopping] {
            render([outgoing()], activity: activity, sends: [intent])
            XCTAssertFalse(try bubble().isHidden)
            XCTAssertEqual(try bubble().accessibilityLabel, activity.label)
        }
    }

    func testSameSessionOnAnotherHostCancelsOldPresentation() throws {
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        var cancelled = false
        controller.onSendPresentation = { received, outcome in
            XCTAssertEqual(received, intent)
            XCTAssertEqual(outcome, .cancelled)
            cancelled = true
        }
        render([outgoing()], activity: .working, sends: [intent])
        context = .init(sessionID: context.sessionID, hostGeneration: UUID(), selectionGeneration: UUID())
        render([.init(id: "other", role: "assistant", text: "Other host", provisional: false)], activity: .working, sends: [])
        XCTAssertTrue(cancelled)
        XCTAssertFalse(try bubble().isHidden)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
    }

    func testCanonicalRowChangePreservesOnePresentationForOperation() async throws {
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        let completed = expectation(description: "Canonical outgoing presents once")
        var completions = 0
        controller.onSendPresentation = { received, outcome in
            XCTAssertEqual(received, intent)
            XCTAssertEqual(outcome, .completed)
            completions += 1
            completed.fulfill()
        }
        render([outgoing()], activity: .working, sends: [intent])
        render([outgoing(id: "canonical")], activity: .working, sends: [intent])
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .completed)
        render([outgoing(id: "canonical")], activity: .working, sends: [intent])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
    }

    func testCorrelatedReceiptWithFollowingAssistantKeepsPresentationActive() async throws {
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        let assistant = ChatMessage(id: "following-assistant", role: "assistant", text: "Public progress", provisional: false)
        let completed = expectation(description: "Correlated outgoing presents with the assistant tail retained")
        var historyChanges: [Bool] = []
        controller.onReadingHistory = { historyChanges.append($0) }
        controller.onSendPresentation = { received, outcome in
            XCTAssertEqual(received, intent)
            XCTAssertEqual(outcome, .completed)
            completed.fulfill()
        }
        render([outgoing(), assistant], activity: .working, sends: [intent])
        render([outgoing(id: "canonical"), assistant], activity: .working, sends: [intent])
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertFalse(historyChanges.contains(true), "Receipt correlation changes a row's canonical ID, not the reader's viewport intent.")
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
        XCTAssertFalse(try bubble().isHidden)
    }

    func testCachedReaderRestorationAcceptsStableOperationIdentity() throws {
        let rows = (0..<30).map { index in
            index == 10 ? outgoing("Anchored outgoing", id: "canonical", operation: "anchor-operation") :
                ChatMessage(id: "history-\(index)", role: "assistant", text: "Earlier public reply", provisional: true)
        }
        let restoration = ReaderRestoration(id: UUID(), position: .anchored(messageID: "outbound:anchor-operation", offsetFromUsableTop: 17))
        controller.render(messages: rows, hasMore: false, loading: false, latestRevision: revision,
            sessionID: context.sessionID, viewportInsets: insets, activity: .idle,
            conversationContext: context, readerRestoration: restoration)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let row = table.rectForRow(at: .init(row: 10, section: 0))
        XCTAssertEqual(row.minY - table.contentOffset.y - insets.top, 17, accuracy: 1)
    }

    func testReaderAnchorSurvivesCanonicalReplacementAndRecordsStableIdentity() throws {
        var rows = (0..<30).map { index in
            index == 10 ? outgoing("Anchored outgoing", operation: "anchor-operation") :
                ChatMessage(id: "history-\(index)", role: "assistant", text: "Earlier public reply", provisional: true)
        }
        render(rows, activity: .idle, sends: [])
        controller.scrollViewWillBeginDragging(table)
        let path = IndexPath(row: 10, section: 0)
        table.contentOffset.y = table.rectForRow(at: path).minY + 10
        table.layoutIfNeeded()
        var bookmark: ReaderPosition?
        controller.onReaderPosition = { position, receivedContext in
            XCTAssertEqual(receivedContext, self.context)
            bookmark = position
        }
        controller.scrollViewDidEndDragging(table, willDecelerate: false)
        XCTAssertEqual(bookmark, .anchored(messageID: "outbound:anchor-operation", offsetFromUsableTop: -10 - Double(insets.top)))
        let before = table.rectForRow(at: path).minY - table.contentOffset.y
        rows[10] = outgoing("Anchored outgoing", id: "canonical", operation: "anchor-operation")
        render(rows, activity: .idle, sends: [])
        XCTAssertEqual(table.rectForRow(at: path).minY - table.contentOffset.y, before, accuracy: 1)
    }


    func testIdleRejectionReleasesUnusedFooterReservation() throws {
        let emptyHeight = table.contentSize.height
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        render([outgoing()], activity: .idle, sends: [intent])
        XCTAssertEqual(table.tableFooterView?.frame.height, 52)
        render([], activity: .idle, sends: [])
        XCTAssertNil(table.tableFooterView)
        XCTAssertEqual(table.contentSize.height, emptyHeight, accuracy: 1)
    }

    func testCompletedIdleSendKeepsFooterUntilItsOutgoingTargetRetires() async throws {
        let intent = SendPresentationIntent(context: context, operationID: "operation")
        let completed = expectation(description: "Idle outgoing presentation completes before the receipt")
        controller.onSendPresentation = { _, outcome in
            XCTAssertEqual(outcome, .completed)
            completed.fulfill()
        }
        render([outgoing()], activity: .idle, sends: [intent])
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .completed)
        render([outgoing()], activity: .idle, sends: [])
        XCTAssertEqual(table.tableFooterView?.frame.height, 52, "Later working activity must reuse the completed send's reserved geometry.")
        render([], activity: .idle, sends: [])
        XCTAssertNil(table.tableFooterView, "A rejected or retired outgoing target must release its idle reservation.")
    }

    func testZeroDistanceLatestDefersReaderCallbacksUntilAfterRender() async throws {
        let rows = [outgoing()]
        render(rows, activity: .idle, sends: [])
        let completed = expectation(description: "Latest publishes reader ownership after reconciliation")
        var rendering = false
        var historyCallbacks = 0
        controller.onReadingHistory = { reading in
            XCTAssertFalse(rendering)
            XCTAssertFalse(reading)
            historyCallbacks += 1
        }
        controller.onReaderPosition = { position, receivedContext in
            XCTAssertFalse(rendering)
            XCTAssertEqual(position, .latest)
            XCTAssertEqual(receivedContext, self.context)
            completed.fulfill()
        }
        let offset = table.contentOffset
        revision = UUID()
        rendering = true
        render(rows, activity: .idle, sends: [])
        rendering = false
        XCTAssertFalse(controller.isJumpingToLatest)
        XCTAssertEqual(table.contentOffset, offset)
        XCTAssertEqual(historyCallbacks, 0)
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(historyCallbacks, 1)
    }

    func testDeferredLatestCannotPublishAfterContextReplacement() async throws {
        let rows = [outgoing()]
        render(rows, activity: .idle, sends: [])
        let stale = expectation(description: "The old context must not publish reader state")
        stale.isInverted = true
        controller.onReadingHistory = { _ in stale.fulfill() }
        controller.onReaderPosition = { _, _ in stale.fulfill() }
        revision = UUID()
        render(rows, activity: .idle, sends: [])
        context = .init(sessionID: context.sessionID, hostGeneration: UUID(), selectionGeneration: UUID())
        render(rows, activity: .idle, sends: [])
        let result = await XCTWaiter.fulfillment(of: [stale], timeout: 0.1)
        XCTAssertEqual(result, .completed)
    }

    func testDeferredLatestCannotOverrideANewerDrag() async throws {
        let rows = [outgoing()]
        render(rows, activity: .idle, sends: [])
        let stale = expectation(description: "The superseded viewport intent must not publish reader state")
        stale.isInverted = true
        controller.onReadingHistory = { _ in stale.fulfill() }
        controller.onReaderPosition = { _, _ in stale.fulfill() }
        revision = UUID()
        render(rows, activity: .idle, sends: [])
        controller.scrollViewWillBeginDragging(table)
        let result = await XCTWaiter.fulfillment(of: [stale], timeout: 0.1)
        XCTAssertEqual(result, .completed)
    }

}
