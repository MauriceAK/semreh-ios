import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatMeasuredTranscriptSurfaceTests: XCTestCase {
    private typealias Owner = ChatNativeTranscriptViewport.Controller

    func testMuseStreamingBodyWaitsThroughDragAndMomentumThenKeepsCurrentIntraRowAnchor() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", receipt: receipt))
        defer { unmountStreaming(fixture) }
        let owner = fixture.owner
        XCTAssertTrue(receipt.interactionReference === owner.markdownPresentationInteraction)
        owner.ownership = .reading
        fixture.collection.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        owner.anchor = owner.currentAnchor()
        let configurations = receipt.contents.count
        fixture.collection.directTouch = true
        owner.scrollViewWillBeginDragging(fixture.collection)
        XCTAssertEqual(receipt.interactionReference?.isInteracting, true,
            "Already-hosted Markdown observes the same live owner without a row replacement")

        owner.update(streamingViewport(scope: scope, content: "first growth", revision: 1, height: 3_300, receipt: receipt))
        fixture.collection.layoutIfNeeded()
        XCTAssertEqual(receipt.contents.count, configurations)
        XCTAssertEqual(owner.deferredStreamingRowIDs, ["row-0"])
        fixture.collection.setContentOffset(CGPoint(x: 0, y: 570), animated: false)
        owner.scrollViewDidScroll(fixture.collection)
        fixture.collection.directTouch = false
        fixture.collection.momentum = true
        owner.scrollViewDidEndDragging(fixture.collection, willDecelerate: true)
        owner.update(streamingViewport(scope: scope, content: "final exact content", revision: 2,
            height: 3_600, streaming: false, receipt: receipt))
        fixture.collection.layoutIfNeeded()
        XCTAssertEqual(receipt.contents.count, configurations, "Final formatting must also yield to the ongoing gesture")
        let current = try XCTUnwrap(owner.currentAnchor())

        fixture.collection.momentum = false
        owner.scrollViewDidEndDecelerating(fixture.collection)
        fixture.collection.layoutIfNeeded()
        XCTAssertEqual(receipt.contents.count, configurations + 1, "Coalesce all held bodies into the latest one")
        XCTAssertEqual(receipt.contents.last, "final exact content")
        XCTAssertTrue(owner.deferredStreamingRowIDs.isEmpty)
        XCTAssertEqual(owner.currentAnchor()?.id, current.id)
        XCTAssertEqual(try XCTUnwrap(owner.currentAnchor()).delta, current.delta, accuracy: 0.5)
        XCTAssertEqual(receipt.interactions, [true, false])
        XCTAssertEqual(receipt.interactionReference?.isInteracting, false)
    }

    func testMuseStreamingDeferralDoesNotHoldActivityScopeOrLegacyChanges() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", showsActivity: true, receipt: receipt))
        defer { unmountStreaming(fixture) }
        fixture.collection.directTouch = true
        fixture.owner.scrollViewWillBeginDragging(fixture.collection)
        fixture.owner.update(streamingViewport(scope: scope, content: "held", revision: 1, showsActivity: true, receipt: receipt))
        XCTAssertEqual(fixture.owner.deferredStreamingRowIDs, ["row-0"])

        fixture.owner.update(streamingViewport(scope: scope, content: "tool boundary", revision: 2,
            activity: "Tool state changed", showsActivity: true, receipt: receipt))
        XCTAssertEqual(receipt.contents.last, "tool boundary")
        XCTAssertTrue(fixture.owner.deferredStreamingRowIDs.isEmpty)
        fixture.owner.update(streamingViewport(scope: "replacement", content: "new scope", revision: 3, receipt: receipt))
        XCTAssertEqual(receipt.contents.last, "new scope")
        XCTAssertTrue(fixture.owner.deferredStreamingRowIDs.isEmpty)
        XCTAssertEqual(receipt.interactions, [true, false])
        fixture.owner.update(streamingViewport(scope: "replacement", content: "legacy live", revision: 4,
            muse: false, receipt: receipt))
        XCTAssertEqual(receipt.contents.last, "legacy live")
        XCTAssertTrue(fixture.owner.deferredStreamingRowIDs.isEmpty)
    }

    func testHiddenActivityDoesNotReconfigureMountedBodyButOptInAndTextDo() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "visible body", receipt: receipt))
        defer { unmountStreaming(fixture) }
        let configurations = receipt.contents.count
        let height = fixture.collection.contentSize.height
        let offset = fixture.collection.contentOffset
        fixture.owner.update(streamingViewport(scope: scope, content: "visible body", revision: 1,
            activity: "Hidden reasoning", receipt: receipt))
        fixture.collection.layoutIfNeeded()
        XCTAssertEqual(receipt.contents.count, configurations)
        XCTAssertEqual(fixture.collection.contentSize.height, height, accuracy: 0.5)
        XCTAssertEqual(fixture.collection.contentOffset.y, offset.y, accuracy: 0.5)
        fixture.owner.update(streamingViewport(scope: scope, content: "visible body", revision: 2,
            toolActivity: "Retained tool result", receipt: receipt))
        fixture.collection.layoutIfNeeded()
        XCTAssertEqual(receipt.contents.count, configurations)
        XCTAssertEqual(fixture.collection.contentSize.height, height, accuracy: 0.5)
        fixture.owner.update(streamingViewport(scope: scope, content: "new visible body", revision: 3,
            toolActivity: "Retained tool result", receipt: receipt))
        fixture.collection.layoutIfNeeded()
        XCTAssertGreaterThan(receipt.contents.count, configurations, "Hidden details must not suppress a real body change")
        XCTAssertEqual(receipt.contents.last, "new visible body")
        let withNewBody = receipt.contents.count
        fixture.owner.update(streamingViewport(scope: scope, content: "new visible body", revision: 4,
            activity: "Retained reasoning", toolActivity: "Retained tool result", showsActivity: true, receipt: receipt))
        fixture.collection.layoutIfNeeded()
        XCTAssertGreaterThan(receipt.contents.count, withNewBody)
        let visible = fixture.owner.input.revisionAt(0)
        XCTAssertEqual(visible.liveToolCalls.first?.preview, "Retained tool result")
        XCTAssertEqual(visible.toolCallGroups.first?.toolCalls.first?.preview, "Retained tool result")
        XCTAssertEqual(visible.message.message.toolCalls, [.string("Retained tool result")])
        let withDetails = receipt.contents.count
        fixture.owner.update(streamingViewport(scope: scope, content: "final visible body", revision: 5,
            activity: "Retained reasoning", showsActivity: true, receipt: receipt))
        fixture.collection.layoutIfNeeded()
        XCTAssertGreaterThan(receipt.contents.count, withDetails)
        XCTAssertEqual(receipt.contents.last, "final visible body")
    }

    func testMuseStationaryTouchWithoutDraggingCannotHoldTerminalBody() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", receipt: receipt))
        defer { unmountStreaming(fixture) }
        // UIKit can track a tap/long press without ever sending the drag-end
        // delegates. Such a touch must not acquire deferred-body ownership.
        fixture.collection.stationaryTouch = true
        fixture.owner.update(streamingViewport(scope: scope, content: "received during touch", revision: 1, receipt: receipt))
        fixture.owner.update(streamingViewport(scope: scope, content: "exact terminal body", revision: 2,
            streaming: false, receipt: receipt))
        XCTAssertEqual(receipt.contents.last, "exact terminal body")
        XCTAssertTrue(fixture.owner.deferredStreamingRowIDs.isEmpty)
        XCTAssertFalse(fixture.owner.streamingInteractionActive)
        XCTAssertEqual(receipt.interactionReference?.isInteracting, false)
        fixture.collection.stationaryTouch = false
        fixture.collection.layoutIfNeeded()
        XCTAssertEqual(receipt.contents.last, "exact terminal body", "No synthetic drag-end callback is needed")
        XCTAssertTrue(receipt.interactions.isEmpty)
    }

    func testMuseDragEndWaitsForUIKitTrackingCleanupWithoutAnotherInput() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", receipt: receipt))
        defer { unmountStreaming(fixture) }
        fixture.collection.directTouch = true
        fixture.owner.scrollViewWillBeginDragging(fixture.collection)
        fixture.owner.update(streamingViewport(scope: scope, content: "exact terminal body", revision: 1,
            streaming: false, receipt: receipt))
        fixture.collection.directTouch = false
        fixture.collection.stationaryTouch = true
        fixture.owner.scrollViewDidEndDragging(fixture.collection, willDecelerate: false)
        // Reproduce the observed UIKit callback order, including tracking that
        // outlives the callback and the first queued cleanup opportunity.
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(fixture.owner.streamingInteractionActive)
        XCTAssertEqual(receipt.contents.last, "initial")
        XCTAssertEqual(fixture.owner.deferredStreamingRowIDs, ["row-0"])
        fixture.collection.stationaryTouch = false
        try await waitForStreamingInteractionToEnd(fixture.owner)
        XCTAssertEqual(receipt.contents.last, "exact terminal body")
        XCTAssertTrue(fixture.owner.deferredStreamingRowIDs.isEmpty)
        XCTAssertEqual(receipt.interactions, [true, false])
        XCTAssertEqual(receipt.interactionReference?.isInteracting, false)
    }

    func testMuseQueuedDragEndCannotReleaseANewerGesture() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", receipt: receipt))
        defer { unmountStreaming(fixture) }
        fixture.collection.directTouch = true
        fixture.owner.scrollViewWillBeginDragging(fixture.collection)
        fixture.collection.directTouch = false
        fixture.collection.stationaryTouch = true
        fixture.owner.scrollViewDidEndDragging(fixture.collection, willDecelerate: false)

        fixture.collection.stationaryTouch = false
        fixture.collection.directTouch = true
        fixture.owner.scrollViewWillBeginDragging(fixture.collection)
        fixture.owner.update(streamingViewport(scope: scope, content: "second gesture terminal", revision: 1,
            streaming: false, receipt: receipt))
        // Even if UIKit's flags clear before the newer end callback, the old
        // queued callback must not release the newer interaction's ownership.
        fixture.collection.directTouch = false
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(fixture.owner.streamingInteractionActive)
        XCTAssertEqual(receipt.contents.last, "initial")
        XCTAssertEqual(receipt.interactions, [true])
        fixture.owner.scrollViewDidEndDragging(fixture.collection, willDecelerate: false)
        XCTAssertEqual(receipt.contents.last, "second gesture terminal")
        XCTAssertEqual(receipt.interactions, [true, false])
        XCTAssertEqual(receipt.interactionReference?.isInteracting, false)
    }

    func testMuseQueuedDragEndIsInvalidatedByScopeSuspendAndStop() async throws {
        for boundary in ["scope", "suspend", "stop"] {
            let scope = UUID().uuidString
            let receipt = StreamingReceipt()
            let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", receipt: receipt))
            defer { unmountStreaming(fixture) }
            fixture.collection.directTouch = true
            fixture.owner.scrollViewWillBeginDragging(fixture.collection)
            fixture.owner.update(streamingViewport(scope: scope, content: "held", revision: 1, receipt: receipt))
            fixture.collection.directTouch = false
            fixture.collection.stationaryTouch = true
            fixture.owner.scrollViewDidEndDragging(fixture.collection, willDecelerate: false)
            switch boundary {
            case "scope":
                fixture.owner.update(streamingViewport(scope: UUID().uuidString, content: "new scope", receipt: receipt))
            case "suspend": fixture.owner.suspendPresentation()
            default: fixture.owner.stop()
            }
            fixture.collection.stationaryTouch = false
            let configurations = receipt.contents.count
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertFalse(fixture.owner.streamingInteractionActive, boundary)
            XCTAssertTrue(fixture.owner.deferredStreamingRowIDs.isEmpty, boundary)
            XCTAssertEqual(receipt.contents.count, configurations, boundary)
            XCTAssertEqual(receipt.interactions, [true, false], boundary)
            XCTAssertEqual(receipt.interactionReference?.isInteracting, false, boundary)
        }
    }

    func testMuseCanonicalHoldRetainsDetachedReaderThroughTerminalAndResumeUntilLatest() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", receipt: receipt))
        defer { unmountStreaming(fixture) }
        let owner = fixture.owner
        fixture.collection.directTouch = true
        owner.scrollViewWillBeginDragging(fixture.collection)
        fixture.collection.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        owner.scrollViewDidScroll(fixture.collection)
        fixture.collection.directTouch = false
        owner.scrollViewDidEndDragging(fixture.collection, willDecelerate: false)
        XCTAssertFalse(owner.streamingInteractionActive, "The independent VM cadence gate must release")
        XCTAssertTrue(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        owner.update(streamingViewport(scope: scope, content: "exact terminal body", revision: 1,
            streaming: false, receipt: receipt))
        XCTAssertEqual(receipt.contents.last, "exact terminal body", "Holding formatting must not hold terminal source or actions")
        XCTAssertTrue(owner.deferredStreamingRowIDs.isEmpty)
        XCTAssertEqual(receipt.interactionReference?.blocksCanonicalPresentation, true)

        let reader = try XCTUnwrap(owner.currentAnchor())
        owner.ownership = .restoring(reader)
        owner.publish()
        XCTAssertTrue(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        owner.suspendPresentation()
        XCTAssertTrue(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        owner.resumePresentation()
        fixture.collection.layoutIfNeeded()
        XCTAssertTrue(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        // A follow hint is not yet proof that the stationary reader arrived.
        owner.ownership = .following
        owner.publish()
        XCTAssertFalse(owner.realizedTailArrival)
        XCTAssertTrue(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        owner.beginMotion()
        XCTAssertTrue(owner.explicitLatestOwnsViewport)
        XCTAssertFalse(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        XCTAssertEqual(receipt.interactionReference?.blocksCanonicalPresentation, false)
        XCTAssertEqual(receipt.interactions, [true, false])
    }

    func testMuseLatestDeadlineTailArrivalGetsOneStableConfirmationAfterBodyShrinks() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope,
            content: "provisional terminal body", streaming: false, receipt: receipt))
        defer { unmountStreaming(fixture) }
        let owner = fixture.owner
        let link = try prepareDeadlineTailAfterBodyShrinks(fixture, scope: scope, receipt: receipt)

        owner.advanceMotion(link)
        XCTAssertTrue(owner.realizedTailArrival)
        XCTAssertTrue(owner.motionLink === link, "The first realized tail sample still needs one fresh confirmation")
        XCTAssertEqual(owner.motionCompleted, 0)
        XCTAssertEqual(owner.motionCancelled, 0)
        XCTAssertTrue(owner.follows)
        owner.advanceMotion(link)
        XCTAssertNil(owner.motionLink)
        XCTAssertEqual(owner.motionCompleted, 1)
        XCTAssertEqual(owner.motionCancelled, 0)
        XCTAssertTrue(owner.follows)
        XCTAssertTrue(owner.realizedTailArrival)
    }

    func testMuseLatestDeadlineConfirmationStillExhaustsWhenTailGeometryChanges() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope,
            content: "provisional terminal body", streaming: false, receipt: receipt))
        defer { unmountStreaming(fixture) }
        let owner = fixture.owner
        let link = try prepareDeadlineTailAfterBodyShrinks(fixture, scope: scope, receipt: receipt)
        owner.advanceMotion(link)
        XCTAssertTrue(owner.motionLink === link)
        let firstTail = try XCTUnwrap(owner.motionTailSample)

        owner.update(streamingViewport(scope: scope, content: "another measured body change", revision: 2,
            height: 1_200, streaming: false, receipt: receipt))
        try realizeStreamingTail(fixture)
        let path = try XCTUnwrap(owner.dataSource.indexPath(for: .footer))
        XCTAssertNotEqual(try XCTUnwrap(fixture.collection.cellForItem(at: path)).frame, firstTail)
        owner.advanceMotion(link)
        XCTAssertNil(owner.motionLink, "A changed tail cannot acquire another deadline extension")
        XCTAssertEqual(owner.motionCompleted, 0)
        XCTAssertEqual(owner.motionCancelled, 1)
        XCTAssertFalse(owner.follows)
        owner.advanceMotion(link)
        XCTAssertEqual(owner.motionCancelled, 1)
        XCTAssertEqual(owner.motionCompleted, 0)
    }

    func testMuseLatestDeadlineConfirmationCannotReclaimANewerDrag() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope,
            content: "provisional terminal body", streaming: false, receipt: receipt))
        defer { unmountStreaming(fixture) }
        let owner = fixture.owner
        let link = try prepareDeadlineTailAfterBodyShrinks(fixture, scope: scope, receipt: receipt)
        owner.advanceMotion(link)
        XCTAssertTrue(owner.motionLink === link)

        fixture.collection.directTouch = true
        owner.scrollViewWillBeginDragging(fixture.collection)
        let readerOffset = fixture.collection.contentOffset
        owner.advanceMotion(link)
        XCTAssertNil(owner.motionLink)
        XCTAssertEqual(owner.motionCompleted, 0)
        XCTAssertEqual(owner.motionCancelled, 1)
        XCTAssertFalse(owner.follows)
        XCTAssertFalse(owner.explicitLatestOwnsViewport)
        XCTAssertEqual(fixture.collection.contentOffset, readerOffset)
    }

    func testMuseCanonicalHoldReleasesAtMeasuredTailAndResetsForScopeLegacyAndStop() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", receipt: receipt))
        defer { unmountStreaming(fixture) }
        let owner = fixture.owner
        func park() {
            owner.ownership = .reading
            fixture.collection.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
            owner.anchor = owner.currentAnchor()
            owner.publish()
            XCTAssertTrue(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        }
        park()
        fixture.collection.directTouch = true
        owner.scrollViewWillBeginDragging(fixture.collection)
        for _ in 0..<6 {
            fixture.collection.setContentOffset(CGPoint(x: 0, y: owner.bottomOffset), animated: false)
            owner.scrollViewDidScroll(fixture.collection)
            fixture.collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(owner.realizedTailArrival, "Release must use a fitted actual tail, not estimated distance")
        fixture.collection.directTouch = false
        owner.scrollViewDidEndDragging(fixture.collection, willDecelerate: false)
        XCTAssertFalse(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        owner.ownership = .restoring(Owner.Anchor(id: "row-0", delta: 400))
        owner.publish()
        XCTAssertTrue(owner.markdownPresentationInteraction.holdsCanonicalPresentation,
            "A requested reader restore must hold before its old realized tail moves")
        owner.ownership = .reading
        owner.publish()
        XCTAssertFalse(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        park()
        let replacement = UUID().uuidString
        owner.update(streamingViewport(scope: replacement, content: "new scope", receipt: receipt))
        XCTAssertFalse(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        park()
        owner.update(streamingViewport(scope: replacement, content: "legacy", revision: 1, muse: false, receipt: receipt))
        XCTAssertFalse(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
        owner.update(streamingViewport(scope: replacement, content: "Muse again", revision: 2, receipt: receipt))
        park()
        owner.stop()
        XCTAssertFalse(owner.markdownPresentationInteraction.holdsCanonicalPresentation)
    }

    func testSuspendingMuseStreamingDropsPendingOwnershipAndResumesLatestBody() async throws {
        let scope = UUID().uuidString
        let receipt = StreamingReceipt()
        let fixture = try await mountStreaming(viewport: streamingViewport(scope: scope, content: "initial", receipt: receipt))
        defer { unmountStreaming(fixture) }
        fixture.collection.directTouch = true
        fixture.owner.scrollViewWillBeginDragging(fixture.collection)
        fixture.owner.update(streamingViewport(scope: scope, content: "held", revision: 1, receipt: receipt))
        fixture.owner.suspendPresentation()
        XCTAssertTrue(fixture.owner.deferredStreamingRowIDs.isEmpty)
        XCTAssertEqual(receipt.interactions, [true, false])
        fixture.collection.directTouch = false
        fixture.owner.update(streamingViewport(scope: scope, content: "completed while hidden", revision: 2,
            streaming: false, receipt: receipt))
        fixture.owner.resumePresentation()
        fixture.collection.layoutIfNeeded()
        XCTAssertEqual(receipt.contents.last, "completed while hidden")
        XCTAssertFalse(fixture.owner.streamingInteractionActive)
        XCTAssertTrue(fixture.owner.deferredStreamingRowIDs.isEmpty)
    }

    func testMuseDockFadeUsesPhysicalEdgeWhileLegacyKeepsComposerFade() throws {
        let receipt = StreamingReceipt()
        let scope = UUID().uuidString
        let owner = Owner(input: streamingViewport(scope: scope, content: "body", bottom: 160, receipt: receipt))
        owner.loadViewIfNeeded()
        defer { owner.stop() }
        owner.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        owner.view.layoutIfNeeded()
        let muse = owner.visualEdgeGeometry
        XCTAssertEqual(muse.bottomStart, 584 / 600, accuracy: 0.001)
        XCTAssertEqual(muse.bottomEnd, 1, accuracy: 0.001)
        XCTAssertEqual(owner.input.bottomInset, 160)
        if #available(iOS 26.0, *) { XCTAssertTrue(owner.collection.bottomEdgeEffect.isHidden) }
        owner.update(streamingViewport(scope: scope, content: "body", muse: false, bottom: 160, receipt: receipt))
        owner.view.layoutIfNeeded()
        let legacy = owner.visualEdgeGeometry
        XCTAssertEqual(legacy.bottomStart, 456 / 600, accuracy: 0.001)
        XCTAssertEqual(legacy.bottomEnd, 472 / 600, accuracy: 0.001)
        XCTAssertEqual(owner.input.bottomInset, 160)
        if #available(iOS 26.0, *) { XCTAssertFalse(owner.collection.bottomEdgeEffect.isHidden) }
    }

    func testStreamingTailRefitsOnlyTheChangedSuffixOfTenThousandRows() throws {
        let fixture = layoutFixture(rowCount: 10_000)
        let before = try frame(8_000, in: fixture.layout)
        let lastBefore = try frame(10_001, in: fixture.layout)
        let sizeBefore = fixture.layout.collectionViewContentSize

        try fit(item: .row("row-9999"), at: 10_000, height: 241, layout: fixture.layout)

        XCTAssertEqual(try frame(8_000, in: fixture.layout), before)
        XCTAssertEqual(try frame(10_001, in: fixture.layout).minY, lastBefore.minY + 81, accuracy: 0.01)
        XCTAssertEqual(fixture.layout.collectionViewContentSize.height, sizeBefore.height + 81, accuracy: 0.01)
        XCTAssertEqual(fixture.layout.lastRebuiltFrameCount, 2,
            "Streaming the final row must not rebuild ten thousand earlier frames")
        withExtendedLifetime(fixture) {}
    }

    func testEarlierSelfSizingPreservesPrefixAndMovesTheFollowingRows() throws {
        let fixture = layoutFixture(rowCount: 40)
        let before = try frame(4, in: fixture.layout)
        let next = try frame(6, in: fixture.layout)
        try fit(item: .row("row-4"), at: 5, height: 73, layout: fixture.layout)

        XCTAssertEqual(try frame(4, in: fixture.layout), before)
        XCTAssertEqual(try frame(5, in: fixture.layout).height, 73, accuracy: 0.01)
        XCTAssertEqual(try frame(6, in: fixture.layout).minY, next.minY - 87, accuracy: 0.01)
        XCTAssertEqual(fixture.layout.lastRebuiltFrameCount, 37)
        withExtendedLifetime(fixture) {}
    }

    func testComposerClearanceChangesContentSizeWithoutRebuildingRows() throws {
        let fixture = layoutFixture(rowCount: 100)
        let before = try frame(60, in: fixture.layout)
        let height = fixture.layout.collectionViewContentSize.height
        var next = fixture.input
        // A new value models measured composer growth; no keyboard height enters it.
        next = viewport(ids: next.ids, scope: next.scope, bottom: 180)
        fixture.layout.configure(input: next, width: 390)

        XCTAssertEqual(fixture.layout.collectionViewContentSize.height, height + 180, accuracy: 0.01)
        XCTAssertEqual(try frame(60, in: fixture.layout), before)
        XCTAssertEqual(fixture.layout.lastRebuiltFrameCount, 0)
        withExtendedLifetime(fixture) {}
    }

    func testWidthChangeRebuildsEveryFrameAfterAnIncrementalFit() throws {
        let fixture = layoutFixture(rowCount: 40)
        try fit(item: .row("row-39"), at: 40, height: 240, layout: fixture.layout)
        _ = fixture.layout.collectionViewContentSize
        fixture.layout.configure(input: fixture.input, width: 430)

        XCTAssertEqual(try frame(0, in: fixture.layout).width, 406, accuracy: 0.01)
        XCTAssertEqual(try frame(41, in: fixture.layout).width, 406, accuracy: 0.01)
        XCTAssertEqual(fixture.layout.lastRebuiltFrameCount, 42)
        withExtendedLifetime(fixture) {}
    }

    func testLatestUsesItsOwnMeasuredClearanceAfterViewportResize() throws {
        let input = viewport(ids: ["row-0"], top: 72, bottom: 152, latest: 164)
        let controller = Owner(input: input)
        controller.loadViewIfNeeded()
        defer { controller.stop() }

        for height: CGFloat in [772, 437] {
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: height)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.collection.contentInset.top, 72)
            XCTAssertEqual(controller.latest.frame.maxY, height - 164, accuracy: 0.5)
            XCTAssertEqual(controller.input.bottomInset, 152,
                "Keyboard-sized viewport changes must not add another keyboard reservation")
        }
    }

    func testTypedRestoreKeepsReaderBelowTheMeasuredHeader() async throws {
        let scope = UUID()
        let request = ChatTranscriptRestoreRequest(scope: scope, generation: 1, target: .message(id: "row-20"))
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        let input = viewport(ids: (0..<40).map { "row-\($0)" }, scope: scope.uuidString,
            top: 82, bottom: 140, latest: 152, request: request,
            onRestore: { delivered, outcome in
                XCTAssertEqual(delivered, request)
                outcomes.append(outcome)
            })
        let controller = Owner(input: input)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        for _ in 0..<6 {
            controller.view.layoutIfNeeded()
            controller.collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("row-20")))
        let cell = try XCTUnwrap(controller.collection.cellForItem(at: path))
        XCTAssertEqual(cell.frame.minY - controller.collection.contentOffset.y, 82, accuracy: 1)
        XCTAssertEqual(controller.currentAnchor()?.id, "row-20")
        XCTAssertEqual(outcomes, [.success])
    }

    func testStationaryMountedRowReceivesDirectionAndDynamicTypeChanges() async throws {
        let receipt = EnvironmentReceipt()
        let scope = UUID().uuidString
        var environment = EnvironmentValues()
        environment.layoutDirection = .leftToRight
        environment.dynamicTypeSize = .large
        let makeRow: (Int) -> AnyView = { _ in AnyView(EnvironmentWitness(receipt: receipt).frame(height: 100)) }
        let input = viewport(ids: ["row-0"], scope: scope, environment: environment, makeRow: makeRow)
        let controller = Owner(input: input)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("row-0")))
        let mountedCell = try XCTUnwrap(controller.collection.cellForItem(at: path))
        let offset = controller.collection.contentOffset
        let identityBuilds = controller.identityBuilds
        XCTAssertEqual(receipt.latest, PresentedEnvironment(environment))

        let changes: [(inout EnvironmentValues) -> Void] = [
            { $0.layoutDirection = .rightToLeft },
            { $0.dynamicTypeSize = .accessibility2 }
        ]
        for change in changes {
            let priorUpdates = receipt.updates
            change(&environment)
            controller.update(viewport(ids: ["row-0"], scope: scope, environment: environment, makeRow: makeRow))
            controller.view.layoutIfNeeded()
            controller.collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(receipt.latest, PresentedEnvironment(environment))
            XCTAssertGreaterThan(receipt.updates, priorUpdates,
                "A stationary mounted row must receive the new environment without new text or a swipe")
            XCTAssertTrue(controller.collection.cellForItem(at: path) === mountedCell)
            XCTAssertEqual(controller.identityBuilds, identityBuilds)
            XCTAssertEqual(controller.collection.contentOffset.y, offset.y, accuracy: 0.5)
        }
    }

    func testSystemAccessibilityFlagsParticipateInHostedRowIdentity() {
        // These environment properties are system-owned/read-only. Exercise the
        // explicit identity values without pretending to mutate system settings.
        typealias Signature = ChatMeasuredTranscriptView.EnvironmentSignature
        let baseline = Signature(layoutDirection: .leftToRight, dynamicTypeSize: .large,
            reducesMotion: false, reducesTransparency: false, increasesContrast: false,
            differentiatesWithoutColor: false)
        let changes: [(inout Signature) -> Void] = [
            { $0.reducesMotion = true },
            { $0.reducesTransparency = true },
            { $0.increasesContrast = true },
            { $0.differentiatesWithoutColor = true }
        ]
        for change in changes {
            var changed = baseline
            change(&changed)
            XCTAssertNotEqual(changed.description, baseline.description)
        }
    }

    private struct PresentedEnvironment: Equatable {
        let isRightToLeft: Bool
        let dynamicTypeSize: DynamicTypeSize
        let reducesMotion: Bool
        let reducesTransparency: Bool
        let increasesContrast: Bool
        let differentiatesWithoutColor: Bool

        init(_ environment: EnvironmentValues) {
            isRightToLeft = environment.layoutDirection == .rightToLeft
            dynamicTypeSize = environment.dynamicTypeSize
            reducesMotion = environment.accessibilityReduceMotion
            reducesTransparency = environment.accessibilityReduceTransparency
            increasesContrast = environment.colorSchemeContrast == .increased
            differentiatesWithoutColor = environment.accessibilityDifferentiateWithoutColor
        }
    }

    private final class EnvironmentReceipt {
        var latest: PresentedEnvironment?
        var updates = 0
    }

    private struct EnvironmentWitness: UIViewRepresentable {
        let receipt: EnvironmentReceipt
        func makeUIView(context: Context) -> UILabel { UILabel() }
        func updateUIView(_ label: UILabel, context: Context) {
            receipt.latest = PresentedEnvironment(context.environment)
            receipt.updates += 1
            label.text = context.environment.layoutDirection == .rightToLeft ? "RTL" : "LTR"
        }
    }

    private final class StreamingCollection: ChatNativeTranscriptViewport.Collection {
        var directTouch = false
        var stationaryTouch = false
        var momentum = false
        override var isTracking: Bool { directTouch || stationaryTouch }
        override var isDragging: Bool { directTouch }
        override var isDecelerating: Bool { momentum }
    }

    private final class StreamingReceipt {
        var contents: [String] = []
        var interactions: [Bool] = []
        var interactionReference: MarkdownPresentationInteraction?
    }

    private struct StreamingInteractionWitness: UIViewRepresentable {
        let receipt: StreamingReceipt
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            return view
        }
        func updateUIView(_ view: UIView, context: Context) {
            receipt.interactionReference = context.environment.markdownPresentationInteraction
        }
    }

    private struct MountedStreaming {
        let owner: Owner
        let collection: StreamingCollection
        let window: UIWindow
        let previous: UIWindow?
    }

    private func mountStreaming(viewport: ChatNativeTranscriptViewport) async throws -> MountedStreaming {
        let collection = StreamingCollection(frame: .zero, collectionViewLayout: Owner.ColumnLayout())
        let owner = Owner(input: viewport, makeCollection: { layout in
            collection.setCollectionViewLayout(layout, animated: false)
            return collection
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = owner
        window.makeKeyAndVisible()
        for _ in 0..<6 {
            owner.view.layoutIfNeeded()
            collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue((collection.collectionViewLayout as? Owner.ColumnLayout)?.measured.contains(.row("row-0")) == true)
        return MountedStreaming(owner: owner, collection: collection, window: window, previous: previous)
    }

    // Inject a delayed display-link timestamp, not a real frame-rate claim. A
    // canonical body shrink is laid out while the paused motion still owns Latest.
    private func prepareDeadlineTailAfterBodyShrinks(_ fixture: MountedStreaming,
                                                   scope: String, receipt: StreamingReceipt) throws -> CADisplayLink {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Animated settlement requires Reduce Motion off")
        let owner = fixture.owner
        owner.ownership = .reading
        fixture.collection.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        owner.anchor = owner.currentAnchor()
        XCTAssertFalse(owner.realizedTailArrival)
        let provisionalHeight = fixture.collection.contentSize.height
        owner.beginMotion()
        let link = try XCTUnwrap(owner.motionLink)
        link.isPaused = true
        owner.update(streamingViewport(scope: scope, content: "canonical truncated body", revision: 1,
            height: 1_500, streaming: false, receipt: receipt))
        try realizeStreamingTail(fixture)
        XCTAssertLessThan(fixture.collection.contentSize.height, provisionalHeight)
        XCTAssertNil(owner.motionTailSample)
        owner.motionStarted = link.timestamp - 1
        return link
    }

    private func realizeStreamingTail(_ fixture: MountedStreaming) throws {
        for _ in 0..<6 {
            fixture.collection.setNeedsLayout()
            fixture.collection.layoutIfNeeded()
            fixture.collection.setContentOffset(CGPoint(x: 0, y: fixture.owner.bottomOffset), animated: false)
            fixture.collection.layoutIfNeeded()
            if fixture.owner.realizedTailArrival { break }
        }
        XCTAssertTrue(fixture.owner.realizedTailArrival, "Require a fitted live footer, not an estimated tail")
        let path = try XCTUnwrap(fixture.owner.dataSource.indexPath(for: .footer))
        _ = try XCTUnwrap(fixture.collection.cellForItem(at: path))
    }

    private func unmountStreaming(_ fixture: MountedStreaming) {
        fixture.owner.stop()
        fixture.window.isHidden = true
        fixture.window.rootViewController = nil
        fixture.previous?.makeKey()
    }

    private func waitForStreamingInteractionToEnd(_ owner: Owner) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while owner.streamingInteractionActive && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(owner.streamingInteractionActive, "The terminal body must flush after UIKit clears tracking without another model update or delegate callback")
    }

    private func streamingViewport(scope: String, content: String, revision: Int = 0,
                                   height: CGFloat = 3_000, streaming: Bool = true,
                                   activity: String = "", toolActivity: String = "", showsActivity: Bool = false, muse: Bool = true, bottom: CGFloat = 0,
                                   receipt: StreamingReceipt) -> ChatNativeTranscriptViewport {
        var environment = EnvironmentValues()
        environment.usesMuseChatSurface = muse
        var input = viewport(ids: ["row-0"], scope: scope, bottom: bottom, environment: environment,
            makeRow: { _ in
                receipt.contents.append(content)
                return AnyView(Text(content).background(StreamingInteractionWitness(receipt: receipt))
                    .frame(height: height, alignment: .top))
            }, revision: revision, isStreaming: streaming, rowRevision: { _ in
                let tools = toolActivity.isEmpty ? [] : [ToolCall(id: "fixture-tool", name: "fixture", preview: toolActivity, args: nil, startedAt: 0)]
                let message = ChatMessage(role: "assistant", content: content, timestamp: 0, messageId: "row-0",
                    toolCalls: toolActivity.isEmpty ? nil : [.string(toolActivity)], reasoning: activity.isEmpty ? nil : activity)
                return StableViewportRowRevision(
                    message: TranscriptMessage(loadedIndex: 0, renderID: "row-0", anchorID: "row-0", message: message),
                    outgoingInsertionEvent: nil, allowsOutgoingMotion: false,
                    reasoningGroups: activity.isEmpty ? [] : [ReasoningGroup(id: "fixture-reasoning", anchorMessageID: "row-0", text: activity)],
                    toolCallGroups: tools.isEmpty ? [] : [ToolCallGroup(id: "fixture-tools", anchorMessageID: "row-0", toolCalls: tools)],
                    liveReasoningText: activity, liveToolCalls: tools,
                    streamingAssistantMessageID: streaming ? "row-0" : nil, liveTokensPerSecond: nil,
                    localAttachmentPreviews: nil, compressionReferenceCard: nil, listeningMessageID: nil,
                    showsThinkingAndToolCards: showsActivity, isViewingCachedData: false, hasActiveStream: streaming,
                    isRegeneratingMessage: false, isEditingMessage: false, isForkingMessage: false,
                    transcriptMediaCacheNamespace: scope)
            })
        input.headerRevision = .spacer(height: 1)
        input.footerRevision = .spacer(height: 1)
        input.onStreamingInteractionChanged = { receipt.interactions.append($0) }
        return input
    }

    private final class Items: NSObject, UICollectionViewDataSource {
        let count: Int
        init(count: Int) { self.count = count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
        }
    }

    private struct LayoutFixture {
        let layout: Owner.ColumnLayout
        let collection: UICollectionView
        let source: Items
        let input: ChatNativeTranscriptViewport
    }

    private func layoutFixture(rowCount: Int) -> LayoutFixture {
        let input = viewport(ids: (0..<rowCount).map { "row-\($0)" })
        let layout = Owner.ColumnLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), collectionViewLayout: layout)
        let source = Items(count: rowCount + 2)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
        collection.dataSource = source
        collection.reloadData()
        layout.configure(input: input, width: 390)
        layout.commitSnapshot([.header] + input.ids.map(Owner.Item.row) + [.footer])
        layout.prepare()
        return LayoutFixture(layout: layout, collection: collection, source: source, input: input)
    }

    private func frame(_ index: Int, in layout: Owner.ColumnLayout) throws -> CGRect {
        try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
    }

    private func fit(item: Owner.Item, at index: Int, height: CGFloat, layout: Owner.ColumnLayout) throws {
        let attributes = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)))
        attributes.size.height = height
        layout.didFit(attributes, item: item, key: layout.key)
    }

    private func viewport(ids: [String], scope: String = UUID().uuidString,
                          top: CGFloat = 0, bottom: CGFloat = 0, latest: CGFloat? = nil,
                          environment: EnvironmentValues = EnvironmentValues(),
                          makeRow: ((Int) -> AnyView)? = nil,
                          revision: Int = 0, isStreaming: Bool = false,
                          rowRevision: ((Int) -> StableViewportRowRevision)? = nil,
                          request: ChatTranscriptRestoreRequest? = nil,
                          onRestore: @escaping (ChatTranscriptRestoreRequest, ChatTranscriptRestoreOutcome) -> Void = { _, _ in })
        -> ChatNativeTranscriptViewport {
        ChatNativeTranscriptViewport(ids: ids, revisionAt: rowRevision ?? { index in
            let message = ChatMessage(role: "assistant", content: "Measured row \(index)", timestamp: Double(index), messageId: ids[index])
            return StableViewportRowRevision(
                message: TranscriptMessage(loadedIndex: index, renderID: ids[index], anchorID: ids[index], message: message),
                outgoingInsertionEvent: nil, allowsOutgoingMotion: false,
                reasoningGroups: [], toolCallGroups: [], liveReasoningText: "", liveToolCalls: [],
                streamingAssistantMessageID: nil, liveTokensPerSecond: nil, localAttachmentPreviews: nil,
                compressionReferenceCard: nil, listeningMessageID: nil, showsThinkingAndToolCards: false,
                isViewingCachedData: false, hasActiveStream: false, isRegeneratingMessage: false,
                isEditingMessage: false, isForkingMessage: false, transcriptMediaCacheNamespace: scope)
        }, revision: revision, typeKey: "measured-surface-test|\(ChatMeasuredTranscriptView.environmentSignature(environment))", scope: scope, initialID: nil,
            restoreRequest: request, cancellationToken: 0, latestToken: 0,
            explicitLatest: false, following: false, isStreaming: isStreaming, horizontalPadding: 12, spacing: 10,
            bottomInset: bottom, topInset: top, latestBottomInset: latest, environment: environment,
            makeRow: makeRow ?? { index in AnyView(Text("Measured row \(index)").frame(height: 100)) },
            makeHeader: { AnyView(Color.clear.frame(height: 1)) },
            makeFooter: { AnyView(Color.clear.frame(height: 1)) },
            onLatest: {}, onState: { _, _, _, _ in }, onRestore: onRestore, onRefresh: { _ in })
    }
}
