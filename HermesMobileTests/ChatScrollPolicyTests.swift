import SwiftUI
import XCTest
@testable import HermesMobile

final class ChatScrollPolicyTests: XCTestCase {
    func testExistingTranscriptUsesBottomAsItsInitialLayoutAnchor() {
        XCTAssertEqual(ChatScrollPolicy.initialTranscriptAnchor, .bottom)
    }

    func testTranscriptSizeChangesStayBottomAnchoredOnlyWhileFollowingLatestIncludingComposerResize() {
        XCTAssertEqual(
            ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: true),
            .bottom
        )
        XCTAssertNil(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: false))
        XCTAssertEqual(
            ChatScrollPolicy.sizeChangeAnchor(
                shouldFollowLatestMessage: true,
                isComposerResizing: true
            ),
            .bottom
        )
        XCTAssertNil(
            ChatScrollPolicy.sizeChangeAnchor(
                shouldFollowLatestMessage: false,
                isComposerResizing: true
            )
        )
    }

    func testMeasuredLayoutFollowDetectsGrowthButNotOffsetOnlySamples() {
        var state = ChatTranscriptLayoutFollowState()

        XCTAssertEqual(state.recordContentHeight(400), .initial)
        XCTAssertEqual(state.recordContentHeight(400.25), .unchanged)
        XCTAssertEqual(state.recordContentHeight(400), .unchanged)
        XCTAssertEqual(state.recordContentHeight(350), .shrank)
        XCTAssertEqual(state.recordContentHeight(470), .grew)
        XCTAssertEqual(state.recordContentHeight(470), .unchanged)
    }

    func testMeasuredLayoutFollowAllowsLateCompletionGrowth() {
        XCTAssertTrue(
            ChatTranscriptLayoutFollowPolicy.shouldSchedule(
                change: .grew,
                hasRealizedLatestContent: true,
                shouldFollowLatestMessage: true,
                isUserInteracting: false,
                isDecelerating: false,
                hasPendingRestore: false,
                hasExplicitBottomRequest: false,
                isPaging: false
            ),
            "a measured rich-layout growth after streaming completion can use the existing latest-content proxy"
        )
    }

    func testMeasuredLayoutFollowCadenceCoalescesBeforeIssuingProxyCommands() {
        XCTAssertGreaterThan(ChatTranscriptLayoutFollowPolicy.coalescingDelay, 0)
        XCTAssertGreaterThanOrEqual(
            ChatTranscriptLayoutFollowPolicy.minimumCommandInterval,
            ChatTranscriptLayoutFollowPolicy.coalescingDelay
        )
    }

    func testMeasuredLayoutFollowRejectsReaderGestureRestoreExplicitAndPaging() {
        let blockedCases: [(String, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            ("reader", false, false, false, false, false, false),
            ("gesture", true, true, false, false, false, false),
            ("deceleration", true, false, true, false, false, false),
            ("restore", true, false, false, true, false, false),
            ("explicit jump", true, false, false, false, true, false),
            ("older paging", true, false, false, false, false, true)
        ]

        for (name, shouldFollow, isInteracting, isDecelerating, hasRestore, hasExplicit, isPaging) in blockedCases {
            XCTAssertFalse(
                ChatTranscriptLayoutFollowPolicy.shouldSchedule(
                    change: .grew,
                    hasRealizedLatestContent: true,
                    shouldFollowLatestMessage: shouldFollow,
                    isUserInteracting: isInteracting,
                    isDecelerating: isDecelerating,
                    hasPendingRestore: hasRestore,
                    hasExplicitBottomRequest: hasExplicit,
                    isPaging: isPaging
                ),
                "measured follow must not issue a proxy correction during \(name)"
            )
        }

        XCTAssertFalse(
            ChatTranscriptLayoutFollowPolicy.shouldSchedule(
                change: .grew,
                hasRealizedLatestContent: false,
                shouldFollowLatestMessage: true,
                isUserInteracting: false,
                isDecelerating: false,
                hasPendingRestore: false,
                hasExplicitBottomRequest: false,
                isPaging: false
            ),
            "a correction waits for a realized latest row/tail preference"
        )
    }

    func testMeasuredLayoutFollowStateResetInvalidatesScopePendingGrowth() {
        var state = ChatTranscriptLayoutFollowState()

        XCTAssertEqual(state.recordContentHeight(300), .initial)
        XCTAssertEqual(state.recordContentHeight(360), .grew)
        state.reset()
        XCTAssertNil(state.lastContentHeight)
        XCTAssertEqual(state.recordContentHeight(360), .initial)
    }

    func testVisibleTranscriptPolicyChoosesTopmostPartiallyVisibleRow() {
        let frames = [
            "row-above": CGRect(x: 0, y: -120, width: 300, height: 80),
            "row-visible": CGRect(x: 0, y: -20, width: 300, height: 100),
            "row-later": CGRect(x: 0, y: 90, width: 300, height: 100),
            "row-below": CGRect(x: 0, y: 420, width: 300, height: 100)
        ]

        XCTAssertEqual(
            ChatTranscriptVisibilityPolicy.firstVisibleMessageID(
                frames: frames,
                viewportHeight: 400
            ),
            "row-visible"
        )
    }

    func testVisibleTranscriptPolicyReturnsNilWhenNoRowIntersectsViewport() {
        let frames = [
            "row-above": CGRect(x: 0, y: -120, width: 300, height: 80),
            "row-below": CGRect(x: 0, y: 420, width: 300, height: 100)
        ]

        XCTAssertNil(
            ChatTranscriptVisibilityPolicy.firstVisibleMessageID(
                frames: frames,
                viewportHeight: 400
            )
        )
    }

    func testVisibleTranscriptPolicyRetainsAnchorAcrossTransientEmptyPreference() {
        XCTAssertEqual(
            ChatTranscriptVisibilityPolicy.retainedVisibleMessageID(
                currentID: "row-reading",
                incomingID: nil,
                hasMessages: true
            ),
            "row-reading"
        )
        XCTAssertEqual(
            ChatTranscriptVisibilityPolicy.retainedVisibleMessageID(
                currentID: "row-reading",
                incomingID: "row-new",
                hasMessages: true
            ),
            "row-new"
        )
        XCTAssertNil(
            ChatTranscriptVisibilityPolicy.retainedVisibleMessageID(
                currentID: "row-reading",
                incomingID: nil,
                hasMessages: false
            )
        )
    }

    func testActivationRecoveryLeavesAReaderWithRealizedRowsAlone() {
        XCTAssertFalse(
            ChatTranscriptViewportRecoveryPolicy.shouldRecoverAfterActivation(
                hasMessages: true,
                hadObservedRows: true,
                hasVisibleRows: true,
                shouldFollowLatest: false,
                isNearBottom: false,
                isTailVisible: false,
                isDirectlyInteracting: false,
                isDecelerating: false
            ),
            "a valid history viewport must not be re-scrolled on activation"
        )
    }

    func testVisiblePreferenceArmsRecoveryForTheNextActivation() {
        var state = ChatTranscriptActivationRecoveryState()

        XCTAssertFalse(state.armForActivation(), "a new transcript has no observed viewport yet")
        state.recordPreferenceSample(hasVisibleMessageRows: true)

        XCTAssertTrue(state.hasObservedRows)
        XCTAssertTrue(state.armForActivation(), "a later background/foreground return can now probe the retained viewport")

        state.disarm()
        XCTAssertFalse(state.isArmed)
        XCTAssertTrue(state.hasObservedRows, "disappearing only ends this activation check, not the observed-row history")
        XCTAssertTrue(state.armForActivation())
    }

    func testEmptyPreferenceAndNewTranscriptResetDoNotArmRecovery() {
        var state = ChatTranscriptActivationRecoveryState()

        state.recordPreferenceSample(hasVisibleMessageRows: false)
        XCTAssertFalse(state.hasObservedRows, "a bottom-anchor-only or empty preference is not a visible message row")
        XCTAssertFalse(state.armForActivation())

        state.recordPreferenceSample(hasVisibleMessageRows: true)
        XCTAssertTrue(state.armForActivation())
        state.reset()

        XCTAssertFalse(state.hasObservedRows)
        XCTAssertFalse(state.isArmed)
        XCTAssertFalse(state.armForActivation())
    }

    func testActivationProbeClassifiesVisibleUnchangedFramesAsStale() {
        XCTAssertEqual(
            ChatTranscriptActivationProbeDisposition.resolve(
                currentFramesGeneration: 12,
                activationBaselineFramesGeneration: 12,
                cachedFrameCount: 7,
                visibleCachedRowCount: 3
            ),
            .waitForFreshGeometry(visibleCachedRowCount: 3),
            "Even frames that look visible under the resumed viewport are not fresh evidence."
        )
    }

    func testActivationProbeUsesFreshGenerationInsteadOfCachedFrameCount() {
        XCTAssertEqual(
            ChatTranscriptActivationProbeDisposition.resolve(
                currentFramesGeneration: 13,
                activationBaselineFramesGeneration: 12,
                cachedFrameCount: 7,
                visibleCachedRowCount: 3
            ),
            .freshGeometryArrived
        )
    }

    func testActivationProbeEvaluatesOnlyAnEmptyUnchangedCacheAsFallback() {
        XCTAssertEqual(
            ChatTranscriptActivationProbeDisposition.resolve(
                currentFramesGeneration: 12,
                activationBaselineFramesGeneration: 12,
                cachedFrameCount: 0,
                visibleCachedRowCount: 0
            ),
            .evaluateEmptyCache
        )
    }

    func testActivationProbeTreatsNonemptyButOffscreenCacheAsEmptyFallback() {
        XCTAssertEqual(
            ChatTranscriptActivationProbeDisposition.resolve(
                currentFramesGeneration: 12,
                activationBaselineFramesGeneration: 12,
                cachedFrameCount: 8,
                visibleCachedRowCount: 0
            ),
            .evaluateEmptyCache,
            "stale offscreen frames must not leave a blank/out-of-range viewport waiting forever"
        )
    }

    func testActivationRecoveryRepairsBlankOrUnrealizedTailOnlyWithEvidence() {
        XCTAssertTrue(
            ChatTranscriptViewportRecoveryPolicy.shouldRecoverAfterActivation(
                hasMessages: true,
                hadObservedRows: true,
                hasVisibleRows: false,
                shouldFollowLatest: false,
                isNearBottom: false,
                isTailVisible: false,
                isDirectlyInteracting: false,
                isDecelerating: false
            )
        )
        XCTAssertTrue(
            ChatTranscriptViewportRecoveryPolicy.shouldRecoverAfterActivation(
                hasMessages: true,
                hadObservedRows: true,
                hasVisibleRows: true,
                shouldFollowLatest: true,
                isNearBottom: true,
                isTailVisible: false,
                isDirectlyInteracting: false,
                isDecelerating: false
            )
        )
        XCTAssertFalse(
            ChatTranscriptViewportRecoveryPolicy.shouldRecoverAfterActivation(
                hasMessages: true,
                hadObservedRows: false,
                hasVisibleRows: false,
                shouldFollowLatest: true,
                isNearBottom: true,
                isTailVisible: false,
                isDirectlyInteracting: false,
                isDecelerating: false
            )
        )
        XCTAssertFalse(
            ChatTranscriptViewportRecoveryPolicy.shouldRecoverAfterActivation(
                hasMessages: true,
                hadObservedRows: true,
                hasVisibleRows: false,
                shouldFollowLatest: false,
                isNearBottom: false,
                isTailVisible: false,
                isDirectlyInteracting: true,
                isDecelerating: false
            )
        )
    }

    func testOlderMessagePrefetchUsesMeasuredNearTopBoundary() {
        let loadedPageBoundary = ChatTranscriptVisibilityPolicy.VisibleRow(
            id: "row-oldest-loaded",
            frame: CGRect(x: 0, y: 200, width: 300, height: 80)
        )
        let nearTop = ChatTranscriptVisibilityPolicy.VisibleRow(
            id: "row-near-top",
            frame: CGRect(x: 0, y: ChatTranscriptPagingPolicy.nearTopPrefetchDistance, width: 300, height: 80)
        )
        let loadedPageOutsideBoundary = ChatTranscriptVisibilityPolicy.VisibleRow(
            id: "row-oldest-outside-boundary",
            frame: CGRect(x: 0, y: ChatTranscriptPagingPolicy.nearTopPrefetchDistance + 1, width: 300, height: 80)
        )

        XCTAssertTrue(
            ChatTranscriptPagingPolicy.shouldPrefetchOlderMessages(
                firstLoadedRow: loadedPageBoundary,
                firstVisibleRow: nearTop,
                viewportHeight: 400,
                hasOlderMessages: true,
                isLoadingOlderMessages: false,
                hasPendingRestore: false,
                shouldFollowLatest: false,
                lastRequestedVisibleRowID: nil
            )
        )
        XCTAssertFalse(
            ChatTranscriptPagingPolicy.shouldPrefetchOlderMessages(
                firstLoadedRow: loadedPageOutsideBoundary,
                firstVisibleRow: nearTop,
                viewportHeight: 400,
                hasOlderMessages: true,
                isLoadingOlderMessages: false,
                hasPendingRestore: false,
                shouldFollowLatest: false,
                lastRequestedVisibleRowID: nil
            )
        )
        XCTAssertFalse(
            ChatTranscriptPagingPolicy.shouldPrefetchOlderMessages(
                firstLoadedRow: .init(
                    id: loadedPageBoundary.id,
                    frame: CGRect(x: 0, y: -500, width: 300, height: 80)
                ),
                firstVisibleRow: nearTop,
                viewportHeight: 400,
                hasOlderMessages: true,
                isLoadingOlderMessages: false,
                hasPendingRestore: false,
                shouldFollowLatest: false,
                lastRequestedVisibleRowID: nil
            ),
            "a visible row near the top is not enough when the loaded page boundary is far away"
        )
        XCTAssertFalse(
            ChatTranscriptPagingPolicy.shouldPrefetchOlderMessages(
                firstLoadedRow: loadedPageBoundary,
                firstVisibleRow: nearTop,
                viewportHeight: 400,
                hasOlderMessages: true,
                isLoadingOlderMessages: false,
                hasPendingRestore: false,
                shouldFollowLatest: false,
                lastRequestedVisibleRowID: nearTop.id
            )
        )
        XCTAssertFalse(
            ChatTranscriptPagingPolicy.shouldPrefetchOlderMessages(
                firstLoadedRow: loadedPageBoundary,
                firstVisibleRow: nearTop,
                viewportHeight: 400,
                hasOlderMessages: true,
                isLoadingOlderMessages: false,
                hasPendingRestore: false,
                shouldFollowLatest: true,
                lastRequestedVisibleRowID: nil
            )
        )
    }

    func testOlderPageLoadSkipsCorrectionWhenAnchorStayedPut() {
        XCTAssertFalse(
            ChatTranscriptPagingPolicy.shouldRestorePrependedAnchor(
                beforeFrame: CGRect(x: 0, y: 96, width: 300, height: 80),
                afterFrame: CGRect(x: 0, y: 104, width: 300, height: 80)
            )
        )
        XCTAssertTrue(
            ChatTranscriptPagingPolicy.shouldRestorePrependedAnchor(
                beforeFrame: CGRect(x: 0, y: 96, width: 300, height: 80),
                afterFrame: CGRect(x: 0, y: 120, width: 300, height: 80)
            )
        )
        XCTAssertTrue(
            ChatTranscriptPagingPolicy.shouldRestorePrependedAnchor(
                beforeFrame: CGRect(x: 0, y: 96, width: 300, height: 80),
                afterFrame: nil
            )
        )
    }

    func testOlderPageEarlyPreferenceSurvivesOldViewPassUntilEligibleSnapshot() {
        var reconciliation = ChatTranscriptPagingReconciliationState()

        // The row preference arrives while the load await is still pending.
        reconciliation.recordPreferenceBeforeLoadCompletion()
        XCTAssertTrue(reconciliation.hasPendingEarlyPreference)
        XCTAssertTrue(
            reconciliation.shouldRequestFreshViewPassAfterLoad(didLoad: true),
            "a successful load must request one fresh view pass"
        )

        // The token's first pass can still contain the old 120-row snapshot.
        // It must not consume the request or emit a terminal reconciliation.
        XCTAssertFalse(
            reconciliation.consumeIfEligible(
                loadCompleted: true,
                transcriptChanged: false,
                firstLoadedIDChanged: false
            )
        )
        XCTAssertTrue(
            reconciliation.hasPendingEarlyPreference,
            "the request must survive the stale token pass"
        )

        // The later 166-row snapshot has the new first loaded ID and is the
        // sole eligible pass that may consume the request.
        XCTAssertTrue(
            reconciliation.consumeIfEligible(
                loadCompleted: true,
                transcriptChanged: true,
                firstLoadedIDChanged: true
            )
        )
        XCTAssertFalse(reconciliation.hasPendingEarlyPreference)
        XCTAssertFalse(
            reconciliation.consumeIfEligible(
                loadCompleted: true,
                transcriptChanged: true,
                firstLoadedIDChanged: true
            ),
            "an eligible prepend must reconcile at most once"
        )

        reconciliation.reset()
        reconciliation.recordPreferenceBeforeLoadCompletion()
        XCTAssertFalse(
            reconciliation.shouldRequestFreshViewPassAfterLoad(didLoad: false),
            "a no-progress load must not schedule a fresh reconcile"
        )
    }

    func testOlderPageMissingAnchorUsesOneProxyRealizationBeforeMeasuredCorrection() {
        var reconciliation = ChatTranscriptPagingReconciliationState()

        // The load's completion token can first revisit the old 120-row
        // snapshot. It must not issue a realization or consume the request.
        reconciliation.recordPreferenceBeforeLoadCompletion()
        XCTAssertEqual(
            reconciliation.actionForEligibleSnapshot(
                loadCompleted: true,
                transcriptChanged: false,
                firstLoadedIDChanged: false,
                hasAnchorFrame: false
            ),
            .waitForFreshSnapshot
        )
        XCTAssertTrue(reconciliation.hasPendingEarlyPreference)

        // The 166-row snapshot is eligible, but the lazy stack currently
        // exposes only the prepended boundary. Request the existing proxy once
        // so the durable anchor can be measured; do not guess an offset.
        XCTAssertEqual(
            reconciliation.actionForEligibleSnapshot(
                loadCompleted: true,
                transcriptChanged: true,
                firstLoadedIDChanged: true,
                hasAnchorFrame: false
            ),
            .requestAnchorRealization
        )
        XCTAssertTrue(reconciliation.hasRequestedAnchorRealization)

        // A repeated preference while the row is still unrealized cannot start
        // another scroll command. Once the proxy realizes the row, the normal
        // measured correction path is the sole terminal action.
        XCTAssertEqual(
            reconciliation.actionForEligibleSnapshot(
                loadCompleted: true,
                transcriptChanged: true,
                firstLoadedIDChanged: true,
                hasAnchorFrame: false
            ),
            .waitForFreshSnapshot
        )
        XCTAssertEqual(
            reconciliation.actionForEligibleSnapshot(
                loadCompleted: true,
                transcriptChanged: true,
                firstLoadedIDChanged: true,
                hasAnchorFrame: true
            ),
            .applyMeasuredCorrection
        )
        XCTAssertFalse(reconciliation.hasPendingEarlyPreference)
        XCTAssertFalse(reconciliation.hasRequestedAnchorRealization)

        // Gesture/restore/scope cancellation uses the transcript's existing
        // reset path. A later page may request one fresh realization, but the
        // cancelled page cannot reuse the old request.
        reconciliation.reset()
        XCTAssertEqual(
            reconciliation.actionForEligibleSnapshot(
                loadCompleted: true,
                transcriptChanged: true,
                firstLoadedIDChanged: true,
                hasAnchorFrame: false
            ),
            .requestAnchorRealization
        )
    }

    func testOlderPageUnchangedCallbacksCannotConfirmLayout() {
        var state = ChatTranscriptPagingReconciliationState()
        func sample(present: Bool = true, displaced: Bool = false)
            -> ChatTranscriptPagingReconciliationAction {
            state.actionForEligibleSnapshot(
                loadCompleted: true, transcriptChanged: true, firstLoadedIDChanged: true,
                hasAnchorFrame: present,
                anchorNeedsCorrection: displaced
            )
        }
        XCTAssertEqual(sample(), .waitForFreshSnapshot)
        XCTAssertEqual(sample(), .waitForFreshSnapshot, "a reused preference is not settlement")
        XCTAssertEqual(sample(present: false), .requestAnchorRealization)
        XCTAssertEqual(sample(present: false), .waitForFreshSnapshot, "realize at most once")
        XCTAssertEqual(sample(displaced: true), .applyMeasuredCorrection)

        state.reset()
        XCTAssertEqual(sample(), .waitForFreshSnapshot)
        XCTAssertEqual(sample(displaced: true), .applyMeasuredCorrection)

        state.reset()
        state.startSettlement(at: 100)
        XCTAssertEqual(sample(), .waitForFreshSnapshot) // callback generation 8
        XCTAssertEqual(sample(), .waitForFreshSnapshot) // newer callback 9, unchanged anchor
        XCTAssertEqual(sample(), .waitForFreshSnapshot) // unrelated map update, callback 10
        XCTAssertEqual(sample(displaced: true), .applyMeasuredCorrection,
                       "late displacement must still have its original pending owner")

        state.reset()
        state.startSettlement(at: 200)
        for _ in 0..<20 {
            XCTAssertEqual(sample(), .waitForFreshSnapshot,
                           "more unchanged callbacks cannot prove layout completion")
        }
        XCTAssertTrue(state.expireSettlement(at: 202), "stable no-op observations abandon without scrolling")
        XCTAssertEqual(sample(displaced: true), .waitForFreshSnapshot,
                       "expiry must not permit a delayed correction")
    }

    func testOlderPageProvisionalSettlementYieldsToCancellationAndExpiresWithoutSuccess() {
        var state = ChatTranscriptPagingReconciliationState()
        func sample(present: Bool = true)
            -> ChatTranscriptPagingReconciliationAction {
            state.actionForEligibleSnapshot(
                loadCompleted: true, transcriptChanged: true, firstLoadedIDChanged: true,
                hasAnchorFrame: present,
                anchorNeedsCorrection: false
            )
        }
        state.startSettlement(at: 100)
        XCTAssertEqual(sample(), .waitForFreshSnapshot)
        // Production metrics/user/restore/bottom/scene cancellation clears the
        // anchor and calls this same cancellation transition synchronously.
        state.cancel()
        XCTAssertEqual(sample(present: false), .waitForFreshSnapshot)
        XCTAssertTrue(state.isCancelled)
        XCTAssertFalse(state.hasRequestedAnchorRealization)

        state.reset()
        state.startSettlement(at: 200)
        XCTAssertEqual(sample(), .waitForFreshSnapshot)
        XCTAssertFalse(state.expireSettlement(at: 201.999))
        XCTAssertTrue(state.expireSettlement(at: 202))
        XCTAssertEqual(sample(present: false), .waitForFreshSnapshot)
        XCTAssertEqual(sample(), .waitForFreshSnapshot, "expiry cannot report alignment success")
        XCTAssertNil(state.settlementDeadline)

        state.reset()
        state.startSettlement(at: 300)
        XCTAssertEqual(sample(), .waitForFreshSnapshot)
        XCTAssertEqual(sample(present: false), .requestAnchorRealization)
        XCTAssertTrue(state.expireSettlement(at: 302), "an unrealized requested anchor is bounded too")
        XCTAssertEqual(sample(present: false), .waitForFreshSnapshot)
    }

    func testOlderPagingTransfersAfterConfirmedRestoreButNotDuringCompetingRestore() {
        // The production guard keeps an unconfirmed initial restore ahead of a
        // page, including the native-seed-only interval before a restore task
        // exists.
        XCTAssertTrue(
            ChatTranscriptRestorePagingOwnershipPolicy.shouldKeepRestoreOwner(
                hasSettlementTask: true,
                isInitialRestoreInProgress: true,
                hasConfirmedTargetGeometry: false,
                isInitialRestorePending: true
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePagingOwnershipPolicy.shouldKeepRestoreOwner(
                hasSettlementTask: false,
                isInitialRestoreInProgress: false,
                hasConfirmedTargetGeometry: false,
                isInitialRestorePending: true
            )
        )

        // The actual handoff is tied to the saved row's identity and an
        // attached first-visible sample. This models the production prefetch
        // anchor, which can be the first callback that still has that sample.
        let savedTargetConfirmed =
            ChatTranscriptRestorePagingOwnershipPolicy.hasConfirmedVisibleInitialTarget(
                initialRestoreTargetID: "saved-row",
                firstVisibleMessageID: "saved-row",
                isScrollViewAttached: true
            )
        XCTAssertTrue(savedTargetConfirmed)
        XCTAssertFalse(
            ChatTranscriptRestorePagingOwnershipPolicy.hasConfirmedVisibleInitialTarget(
                initialRestoreTargetID: "saved-row",
                firstVisibleMessageID: "saved-row",
                isScrollViewAttached: false
            ),
            "a pre-window preference cannot release initial restore ownership"
        )
        XCTAssertFalse(
            ChatTranscriptRestorePagingOwnershipPolicy.hasConfirmedVisibleInitialTarget(
                initialRestoreTargetID: "saved-row",
                firstVisibleMessageID: "different-row",
                isScrollViewAttached: true
            ),
            "an unrelated visible row cannot release the saved restore"
        )
        XCTAssertFalse(
            ChatTranscriptRestorePagingOwnershipPolicy.shouldKeepRestoreOwner(
                hasSettlementTask: true,
                isInitialRestoreInProgress: true,
                hasConfirmedTargetGeometry: savedTargetConfirmed,
                isInitialRestorePending: true
            ),
            "a confirmed saved row transfers ownership to paging"
        )

        // A first-visible saved-row sample is the explicit ownership handoff;
        // it must not be treated like an active competing restore task.
        XCTAssertFalse(
            ChatTranscriptRestorePagingOwnershipPolicy.shouldKeepRestoreOwner(
                hasSettlementTask: true,
                isInitialRestoreInProgress: true,
                hasConfirmedTargetGeometry: true,
                isInitialRestorePending: true
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePagingOwnershipPolicy.shouldKeepRestoreOwner(
                hasSettlementTask: true,
                isInitialRestoreInProgress: false,
                hasConfirmedTargetGeometry: true,
                isInitialRestorePending: false
            ),
            "activation recovery remains a competing restore owner"
        )

        var reconciliation = ChatTranscriptPagingReconciliationState()
        reconciliation.recordPreferenceBeforeLoadCompletion()
        XCTAssertEqual(
            reconciliation.actionForEligibleSnapshot(
                loadCompleted: true,
                transcriptChanged: false,
                firstLoadedIDChanged: false,
                hasAnchorFrame: false
            ),
            .waitForFreshSnapshot
        )
        XCTAssertEqual(
            reconciliation.actionForEligibleSnapshot(
                loadCompleted: true,
                transcriptChanged: true,
                firstLoadedIDChanged: true,
                hasAnchorFrame: false
            ),
            .requestAnchorRealization
        )
        XCTAssertEqual(
            reconciliation.actionForEligibleSnapshot(
                loadCompleted: true,
                transcriptChanged: true,
                firstLoadedIDChanged: true,
                hasAnchorFrame: false
            ),
            .waitForFreshSnapshot,
            "the restore-to-paging handoff still permits only one proxy request"
        )

        // The same existing cancellation contract wins over a later page
        // correction, and reset clears the one-shot request.
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.shouldCancelPendingRestore(
                isDirectlyInteracting: true,
                isDecelerating: false
            )
        )
        reconciliation.reset()
        XCTAssertFalse(reconciliation.hasRequestedAnchorRealization)
    }

    func testPrependedAnchorAlignmentPreservesPartiallyVisibleRowInsteadOfForcingTop() throws {
        let alignment = try XCTUnwrap(
            ChatTranscriptPagingPolicy.preservedAnchorAlignment(
                beforeFrame: CGRect(x: 0, y: -120, width: 300, height: 180),
                viewportHeight: 400
            )
        )

        XCTAssertEqual(alignment.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(alignment.y, -0.54545, accuracy: 0.001)
        XCTAssertNotEqual(alignment.y, UnitPoint.top.y)
    }

    func testTranscriptVisibilityAcceptsPartlyVisibleRow() {
        XCTAssertTrue(
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: CGRect(x: 0, y: -20, width: 300, height: 100),
                viewportHeight: 400,
                bottomInset: 40
            )
        )
    }

    func testTranscriptVisibilityRejectsZeroHeightRow() {
        XCTAssertFalse(
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: CGRect(x: 0, y: 100, width: 300, height: 0),
                viewportHeight: 400,
                bottomInset: 40
            )
        )
    }

    func testTranscriptVisibilityRejectsMissingFrame() {
        XCTAssertFalse(
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: nil,
                viewportHeight: 400,
                bottomInset: 40
            )
        )
    }

    func testTranscriptVisibilityRejectsRowBehindComposerInset() {
        XCTAssertFalse(
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: CGRect(x: 0, y: 360, width: 300, height: 20),
                viewportHeight: 400,
                bottomInset: 40
            )
        )
    }

    func testTranscriptVisibilityRejectsRowEntirelyAboveViewport() {
        XCTAssertFalse(
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: CGRect(x: 0, y: -100, width: 300, height: 100),
                viewportHeight: 400,
                bottomInset: 40
            )
        )
    }

    func testTranscriptVisibilityRejectsCollapsedViewport() {
        XCTAssertFalse(
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: CGRect(x: 0, y: 1, width: 300, height: 100),
                viewportHeight: 40,
                bottomInset: 40
            )
        )
    }

    func testTranscriptVisibilityRejectsNonpositiveViewport() {
        for viewportHeight in [CGFloat.zero, -1] {
            XCTAssertFalse(
                ChatTranscriptVisibilityPolicy.isVisible(
                    frame: CGRect(x: 0, y: 1, width: 300, height: 100),
                    viewportHeight: viewportHeight,
                    bottomInset: 0
                )
            )
        }
    }

    func testComposerResizeOnlyRejoinsLatestWhenReaderStillFollowsBottom() {
        XCTAssertTrue(
            ChatScrollPolicy.shouldFollowAfterComposerResize(
                wasFollowingLatest: true,
                isUserInteracting: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldFollowAfterComposerResize(
                wasFollowingLatest: false,
                isUserInteracting: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldFollowAfterComposerResize(
                wasFollowingLatest: true,
                isUserInteracting: true
            )
        )
    }

    func testInitialAsyncWorkWaitsForNavigationAppearanceCompletion() {
        XCTAssertFalse(ChatInitialAppearancePolicy.shouldBeginAsyncWork(hasCompletedAppearance: false))
        XCTAssertTrue(ChatInitialAppearancePolicy.shouldBeginAsyncWork(hasCompletedAppearance: true))
    }

    func testWarmLiveReopenSkipsBlockingTranscriptReload() {
        XCTAssertFalse(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(hasPreservedTranscript: true)
        )
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(hasPreservedTranscript: false)
        )
    }

    func testKnownStreamIDWithoutTranscriptStillReloadsHistory() {
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(hasPreservedTranscript: false)
        )
    }

    func testNewViewModelStillReconcilesAfterPaintingCachedRows() {
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: true,
                wasReusedFromOpenSessionStore: false
            )
        )
    }

    func testReusedWarmViewModelCanSkipColdOpenReload() {
        XCTAssertFalse(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: true,
                wasReusedFromOpenSessionStore: true
            )
        )
        XCTAssertTrue(
            ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
                hasPreservedTranscript: false,
                wasReusedFromOpenSessionStore: true
            )
        )
    }

    func testBottomThresholdLoosensWhileStreaming() {
        XCTAssertEqual(
            ChatScrollPolicy.bottomThreshold(isStreaming: false),
            ChatScrollPolicy.bottomDetectionThreshold
        )
        XCTAssertEqual(
            ChatScrollPolicy.bottomThreshold(isStreaming: true),
            ChatScrollPolicy.streamingBottomDetectionThreshold
        )
        XCTAssertGreaterThan(
            ChatScrollPolicy.bottomThreshold(isStreaming: true),
            ChatScrollPolicy.bottomThreshold(isStreaming: false)
        )
    }

    func testIsNearBottomUsesIdleThresholdWhenNotStreaming() {
        XCTAssertTrue(ChatScrollPolicy.isNearBottom(distanceFromBottom: 80, isStreaming: false))
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 81, isStreaming: false))
    }

    func testIsNearBottomUsesLooserThresholdWhileStreaming() {
        // 120pt is past the idle threshold but still "near bottom" while streaming.
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 120, isStreaming: false))
        XCTAssertTrue(ChatScrollPolicy.isNearBottom(distanceFromBottom: 120, isStreaming: true))
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 161, isStreaming: true))
    }

    func testShouldEnterReadingOlderRequiresHysteresisPastThreshold() {
        let threshold = ChatScrollPolicy.bottomThreshold(isStreaming: false)
        let hysteresis = ChatScrollPolicy.readingOlderHysteresis

        XCTAssertFalse(
            ChatScrollPolicy.shouldEnterReadingOlder(
                distanceFromBottom: threshold + hysteresis,
                isStreaming: false
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldEnterReadingOlder(
                distanceFromBottom: threshold + hysteresis + 1,
                isStreaming: false
            )
        )
    }

    func testAutoScrollPausedWhileUserInteracting() {
        XCTAssertTrue(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: true,
                cooldownUntil: nil
            )
        )
    }

    func testAutoScrollPausedDuringCooldownWindow() {
        let now = Date()
        let future = now.addingTimeInterval(0.1)

        XCTAssertTrue(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: future,
                now: now
            )
        )
    }

    func testAutoScrollResumesAfterCooldownExpires() {
        let now = Date()
        let past = now.addingTimeInterval(-0.1)

        XCTAssertFalse(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: past,
                now: now
            )
        )
    }

    func testAutoScrollNotPausedWithoutInteractionOrCooldown() {
        XCTAssertFalse(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: nil
            )
        )
    }

    func testCooldownDeadlineIsUserScrollCooldownInFuture() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let deadline = ChatScrollPolicy.cooldownDeadline(after: base)

        XCTAssertEqual(
            deadline.timeIntervalSince(base),
            ChatScrollPolicy.userScrollCooldown,
            accuracy: 0.0001
        )
    }

    func testStreamingTokensDoNotEmitProgrammaticFollowScroll() {
        XCTAssertFalse(
            ChatScrollPolicy.shouldProgrammaticallyFollowStreamTokens(
                shouldFollowLatestMessage: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldProgrammaticallyFollowStreamTokens(
                shouldFollowLatestMessage: false
            )
        )
    }

    func testReadingOlderKeepsTranscriptViewportStableDuringMarkdownResize() {
        XCTAssertNil(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: false))
        XCTAssertFalse(ChatScrollPolicy.shouldBumpScrollTriggerForStreamingFlush())
    }


    func testFollowRejoinShouldSnapWithoutAnimation() {
        XCTAssertTrue(
            ChatScrollPolicy.shouldSnapWhenRejoiningLatest(
                wasFollowingLatest: false,
                isNearBottom: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldSnapWhenRejoiningLatest(
                wasFollowingLatest: true,
                isNearBottom: true
            )
        )
    }

    func testExplicitBottomJumpAnimatesRegardlessOfDistanceUnlessReduceMotion() {
        XCTAssertTrue(ChatScrollPolicy.shouldAnimateExplicitBottomJump(reduceMotion: false))
        XCTAssertFalse(ChatScrollPolicy.shouldAnimateExplicitBottomJump(reduceMotion: true))
    }

    func testExplicitBottomJumpStaysVisibleUntilViewportActuallyArrives() {
        XCTAssertTrue(
            ChatScrollPolicy.shouldShowScrollToBottomButton(
                isNearBottom: false,
                hasExplicitBottomRequest: true,
                hasActiveStream: true,
                shouldFollowLatestMessage: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldShowScrollToBottomButton(
                isNearBottom: true,
                hasExplicitBottomRequest: true,
                hasActiveStream: true,
                shouldFollowLatestMessage: true
            )
        )
    }

    func testExplicitBottomJumpRetriesAcrossLazyLayoutSettlement() {
        XCTAssertGreaterThanOrEqual(ChatScrollPolicy.explicitBottomSettlementDelays.count, 4)
        XCTAssertEqual(ChatScrollPolicy.explicitBottomSettlementDelays.first, 0)
        XCTAssertTrue(
            zip(
                ChatScrollPolicy.explicitBottomSettlementDelays,
                ChatScrollPolicy.explicitBottomSettlementDelays.dropFirst()
            ).allSatisfy(<)
        )
    }

    func testExplicitBottomTargetKeepsSelectingLatestRowUntilTailIsVisible() {
        XCTAssertEqual(
            ChatScrollPolicy.explicitBottomTargetID(
                latestMessageID: "message-latest",
                latestMessageIsVisible: false,
                bottomAnchorID: "chat-bottom-anchor"
            ),
            "message-latest"
        )
        XCTAssertEqual(
            ChatScrollPolicy.explicitBottomTargetID(
                latestMessageID: "message-latest",
                latestMessageIsVisible: false,
                bottomAnchorID: "chat-bottom-anchor"
            ),
            "message-latest"
        )
    }

    func testExplicitBottomTargetUsesSentinelOnceTailIsVisible() {
        XCTAssertEqual(
            ChatScrollPolicy.explicitBottomTargetID(
                latestMessageID: "message-latest",
                latestMessageIsVisible: true,
                bottomAnchorID: "chat-bottom-anchor"
            ),
            "chat-bottom-anchor"
        )
    }

    func testExplicitBottomTargetFallsBackToSentinelWithoutLatestRow() {
        XCTAssertEqual(
            ChatScrollPolicy.explicitBottomTargetID(
                latestMessageID: nil,
                latestMessageIsVisible: false,
                bottomAnchorID: "chat-bottom-anchor"
            ),
            "chat-bottom-anchor"
        )
    }

    func testExplicitBottomRequestFinishesOnlyWhenMetricsAndTailAgree() {
        XCTAssertTrue(
            ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: true,
                isTailVisible: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: true,
                isTailVisible: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: false,
                isTailVisible: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: false,
                isTailVisible: false
            )
        )
    }

    func testExplicitBottomRequestCannotFinishBeforeItsFirstTargetIsIssued() {
        XCTAssertFalse(
            ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: true,
                isTailVisible: true,
                hasIssuedScroll: false
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: true,
                isTailVisible: true,
                hasIssuedScroll: true
            )
        )
    }

    func testDirectTouchWinsOverNearBottomGeometryWhenExplicitJumpIsSettling() {
        XCTAssertFalse(
            ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: true,
                isTailVisible: true,
                isDirectlyInteracting: true
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: true,
                isTailVisible: true,
                isDirectlyInteracting: false
            )
        )
    }

    func testInheritedExplicitDecelerationDoesNotInstallFollowCooldown() {
        XCTAssertFalse(
            ChatScrollPolicy.shouldRecordUserScrollCooldown(
                isUserInteracting: true,
                isDirectlyInteracting: false,
                isDecelerating: true,
                isExplicitBottomScrollContext: true
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldRecordUserScrollCooldown(
                isUserInteracting: true,
                isDirectlyInteracting: true,
                isDecelerating: true,
                isExplicitBottomScrollContext: true
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldRecordUserScrollCooldown(
                isUserInteracting: true,
                isDirectlyInteracting: false,
                isDecelerating: true,
                isExplicitBottomScrollContext: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.isEffectiveUserInteraction(
                isUserInteracting: true,
                isDirectlyInteracting: false,
                isDecelerating: true,
                isExplicitBottomScrollContext: true
            )
        )
    }

    func testOrdinaryDecelerationStillCountsAsUserInteraction() {
        XCTAssertTrue(
            ChatScrollPolicy.isEffectiveUserInteraction(
                isUserInteracting: true,
                isDirectlyInteracting: false,
                isDecelerating: true,
                isExplicitBottomScrollContext: false
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.isEffectiveUserInteraction(
                isUserInteracting: true,
                isDirectlyInteracting: true,
                isDecelerating: true,
                isExplicitBottomScrollContext: true
            )
        )
    }

    func testExplicitDecelerationContextCarriesUntilItEndsOrDirectTouchStarts() {
        XCTAssertTrue(
            ChatScrollPolicy.nextExplicitBottomDecelerationContext(
                wasExplicitBottomScrollActive: true,
                wasExplicitBottomDecelerationActive: false,
                isDirectlyInteracting: false,
                isDecelerating: true
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.nextExplicitBottomDecelerationContext(
                wasExplicitBottomScrollActive: false,
                wasExplicitBottomDecelerationActive: true,
                isDirectlyInteracting: false,
                isDecelerating: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.nextExplicitBottomDecelerationContext(
                wasExplicitBottomScrollActive: false,
                wasExplicitBottomDecelerationActive: true,
                isDirectlyInteracting: false,
                isDecelerating: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.nextExplicitBottomDecelerationContext(
                wasExplicitBottomScrollActive: false,
                wasExplicitBottomDecelerationActive: true,
                isDirectlyInteracting: true,
                isDecelerating: true
            )
        )
    }

    func testTrailingDecelerationDoesNotCancelExplicitBottomJump() {
        XCTAssertFalse(
            ChatScrollPolicy.shouldCancelExplicitBottomRequest(
                isDirectlyInteracting: false,
                isDecelerating: true
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldCancelExplicitBottomRequest(
                isDirectlyInteracting: true,
                isDecelerating: false
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldCancelExplicitBottomRequest(
                isDirectlyInteracting: true,
                isDecelerating: true
            ),
            "a new finger-driven gesture must still override an explicit jump"
        )
    }

    func testFirstEnterWithNoSavedPointRestoresLatest() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: true,
                lastVisibleMessageID: nil
            ),
            .latest
        )
    }

    func testLeaveWhileFollowingLatestRestoresLatestEvenIfAMessageIDExists() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: true,
                lastVisibleMessageID: "msg-mid"
            ),
            .latest
        )
    }

    func testLeaveWhileReadingOlderRestoresThatMessage() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: false,
                lastVisibleMessageID: "msg-where-i-left"
            ),
            .message(id: "msg-where-i-left")
        )
    }

    func testBlankSavedMessageFallsBackToLatest() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: false,
                lastVisibleMessageID: "   "
            ),
            .latest
        )
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: false,
                lastVisibleMessageID: nil
            ),
            .latest
        )
    }

    func testAppearMustProgrammaticallyRestoreWhenTheTranscriptHasRows() {
        XCTAssertTrue(ChatTranscriptRestorePolicy.shouldProgrammaticallyRestoreOnAppear(hasMessages: true))
        XCTAssertFalse(ChatTranscriptRestorePolicy.shouldProgrammaticallyRestoreOnAppear(hasMessages: false))
    }

    func testRestoreRetriesAcrossFarLazyLayoutSettlement() {
        XCTAssertGreaterThanOrEqual(ChatTranscriptRestorePolicy.settlementDelays.count, 5)
        XCTAssertEqual(ChatTranscriptRestorePolicy.settlementDelays.first, 0)
        XCTAssertTrue(
            zip(
                ChatTranscriptRestorePolicy.settlementDelays,
                ChatTranscriptRestorePolicy.settlementDelays.dropFirst()
            ).allSatisfy(<)
        )
    }

    func testRestoreStopsOnlyAfterTheRequestedViewportArrives() {
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.hasReachedTarget(
                .message(id: "transcript:20"),
                firstVisibleMessageID: "transcript:53",
                isNearBottom: false,
                isTailVisible: false
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.hasReachedTarget(
                .message(id: "transcript:20"),
                firstVisibleMessageID: "transcript:20",
                isNearBottom: false,
                isTailVisible: false
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.hasReachedTarget(
                .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true,
                isTailVisible: true
            )
        )
    }

    func testInitialNativePositionTargetsOnlyASavedReaderMessage() {
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.initialPositionMessageID(
                for: .message(id: "transcript:20")
            ),
            "transcript:20"
        )
        XCTAssertNil(
            ChatTranscriptRestorePolicy.initialPositionMessageID(for: .latest),
            "latest-follow keeps the existing bottom default anchor"
        )
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.initialTranscriptAnchor(
                for: .message(id: "transcript:20"),
                hasSavedMessage: true
            ),
            .top,
            "saved-reader entry must not first apply the provisional bottom anchor"
        )
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.initialTranscriptAnchor(
                for: .latest,
                hasSavedMessage: false
            ),
            ChatScrollPolicy.initialTranscriptAnchor
        )
        XCTAssertEqual(
            ChatTranscriptRestorePolicy.initialTranscriptAnchor(
                for: .message(id: "not-loaded"),
                hasSavedMessage: false
            ),
            ChatScrollPolicy.initialTranscriptAnchor
        )
    }

    func testInitialTargetGeometryRetiresOnlyAfterWindowAttachment() {
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.shouldConfirmInitialTargetGeometry(
                targetMessageID: "transcript:20",
                visibleMessageID: "transcript:20",
                isScrollViewAttached: false
            ),
            "a pre-window preference echo must not retire the native seed"
        )
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.shouldConfirmInitialTargetGeometry(
                targetMessageID: "transcript:20",
                visibleMessageID: "transcript:20",
                isScrollViewAttached: true
            )
        )
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.shouldConfirmInitialTargetGeometry(
                targetMessageID: "transcript:20",
                visibleMessageID: "transcript:23",
                isScrollViewAttached: true
            )
        )
    }

    func testSavedMessageGeometryBeforeRestoreTokenAvoidsProxyFallback() {
        var state = ChatTranscriptRestoreState()
        state.recordVisibleMessageSample("transcript:20")

        XCTAssertTrue(state.beginRestore(token: 1))
        XCTAssertTrue(
            state.shouldSettle(
                target: .message(id: "transcript:20"),
                firstVisibleMessageID: "transcript:20"
            ),
            "the native initial position may reach the reader row before ChatView issues its restore token"
        )
        XCTAssertFalse(state.hasIssuedRestoreAttempt)
    }

    func testBackgroundRecoveryDoesNotReuseCachedVisibleMessageSample() {
        var state = ChatTranscriptRestoreState()
        state.recordVisibleMessageSample("transcript:20")

        XCTAssertTrue(state.beginViewportRecovery(token: 1))
        XCTAssertFalse(
            state.shouldSettle(
                target: .message(id: "transcript:20"),
                firstVisibleMessageID: "transcript:20"
            ),
            "activation recovery still requires fresh geometry or an issued correction"
        )

        state.recordVisibleMessageSample("transcript:20")
        XCTAssertTrue(
            state.shouldSettle(
                target: .message(id: "transcript:20"),
                firstVisibleMessageID: "transcript:20"
            )
        )
    }

    func testOutgoingInsertionMotionIsSuppressedDuringRestore() {
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.shouldAllowOutgoingInsertionMotion(
                shouldFollowLatestMessage: true,
                isRestoreInProgress: true
            )
        )
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.shouldAllowOutgoingInsertionMotion(
                shouldFollowLatestMessage: false,
                isRestoreInProgress: false
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.shouldAllowOutgoingInsertionMotion(
                shouldFollowLatestMessage: true,
                isRestoreInProgress: false
            )
        )
    }

    func testLatestRestoreRejectsProvisionalZeroDistanceBeforeLazyTailExists() {
        var state = ChatTranscriptRestoreState()
        state.recordMetrics(
            isNearBottom: true,
            isDirectlyInteracting: false,
            isDecelerating: false
        )

        XCTAssertFalse(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            ),
            "zero-distance geometry cannot prove that the lazy transcript rendered its tail"
        )

        state.recordTailVisibility(true)
        XCTAssertTrue(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
        )
    }

    func testInitialRestoreRetainsTailPreferenceDeliveredBeforeToken() {
        var state = ChatTranscriptRestoreState()
        state.recordTailVisibility(true)

        XCTAssertTrue(state.beginRestore(token: 1))
        state.recordMetrics(
            isNearBottom: true,
            isDirectlyInteracting: false,
            isDecelerating: false
        )

        XCTAssertTrue(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            ),
            "an unchanged SwiftUI preference may not be delivered again after the token arrives"
        )
    }

    func testInitialRestoreDoesNotOverwriteARealUserDecision() {
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.shouldStartRestore(
                hasMessages: true,
                hasUserInteractedBeforeRestore: false
            )
        )
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.shouldStartRestore(
                hasMessages: true,
                hasUserInteractedBeforeRestore: true
            )
        )
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.shouldStartRestore(
                hasMessages: false,
                hasUserInteractedBeforeRestore: false
            )
        )
    }

    func testInitialGeometryCannotReplaceSavedRestoreIntent() {
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.shouldApplyScrollMetricsBeforeRestore(
                hasRequestedRestore: false,
                hasPendingMessageRestore: false,
                hasUserInteractedBeforeRestore: false,
                isDirectlyInteracting: false
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.shouldApplyScrollMetricsBeforeRestore(
                hasRequestedRestore: false,
                hasPendingMessageRestore: true,
                hasUserInteractedBeforeRestore: false,
                isDirectlyInteracting: true
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.shouldApplyScrollMetricsBeforeRestore(
                hasRequestedRestore: true,
                hasPendingMessageRestore: false,
                hasUserInteractedBeforeRestore: false,
                isDirectlyInteracting: false
            )
        )
        XCTAssertFalse(
            ChatTranscriptRestorePolicy.shouldApplyScrollMetricsBeforeRestore(
                hasRequestedRestore: true,
                hasPendingMessageRestore: true,
                hasUserInteractedBeforeRestore: false,
                isDirectlyInteracting: false
            )
        )
    }

    func testLatestRestoreCannotSettleFromDefaultNearBottomBeforeAnAttemptOrMetrics() {
        var state = ChatTranscriptRestoreState()

        XCTAssertFalse(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            ),
            "the view's initial near-bottom default is not a geometry sample"
        )

        state.recordRestoreAttempt()
        state.recordTailVisibility(true)

        XCTAssertTrue(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
        )
    }

    func testConfirmedGeometryCanSettleLatestWithoutIssuingAnAttempt() {
        var state = ChatTranscriptRestoreState()
        state.recordMetrics(
            isNearBottom: true,
            isDirectlyInteracting: false,
            isDecelerating: false
        )
        state.recordTailVisibility(true)

        XCTAssertTrue(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
        )
    }

    func testMessageRestoreRetriesUntilTheRequestedRowIsObserved() {
        var state = ChatTranscriptRestoreState()
        let visibleRows = ["transcript:53", "transcript:41", "transcript:20"]
        var attempts = 0

        for visibleRow in visibleRows {
            guard !state.shouldSettle(
                target: .message(id: "transcript:20"),
                firstVisibleMessageID: visibleRow,
                isNearBottom: false
            ) else { break }

            state.recordRestoreAttempt()
            attempts += 1
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(
            state.shouldSettle(
                target: .message(id: "transcript:20"),
                firstVisibleMessageID: "transcript:20",
                isNearBottom: false
            )
        )
    }

    func testDirectRestoreInteractionCancelsPendingSettlement() {
        var state = ChatTranscriptRestoreState()
        state.recordRestoreAttempt()
        state.recordMetrics(
            isNearBottom: false,
            isDirectlyInteracting: true,
            isDecelerating: false
        )

        XCTAssertTrue(state.isCancelled)
        XCTAssertFalse(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
        )
    }

    func testExplicitBottomActionCancelsPendingRestoreSettlement() {
        var state = ChatTranscriptRestoreState()
        state.recordRestoreAttempt()
        state.cancel()

        XCTAssertTrue(state.isCancelled)
        XCTAssertFalse(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
        )
    }

    func testPreRestoreDirectInteractionSurvivesApplyingSameRestoreRequest() {
        var state = ChatTranscriptRestoreState()
        state.recordMetrics(
            isNearBottom: false,
            isDirectlyInteracting: true,
            isDecelerating: false
        )

        XCTAssertFalse(
            state.beginRestore(token: 1),
            "applying the pending restore must not resurrect programmatic scrolling"
        )
        XCTAssertTrue(state.isCancelled)
        XCTAssertFalse(state.hasIssuedRestoreAttempt)
        XCTAssertFalse(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
        )

        XCTAssertFalse(state.beginRestore(token: 1))
        XCTAssertTrue(state.isCancelled)

        XCTAssertTrue(state.beginRestore(token: 2))
        state.recordRestoreAttempt()
        state.recordTailVisibility(true)
        XCTAssertTrue(
            state.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
        )
    }

    func testDecelerationAndAsynchronousGeometryDoNotCancelRestore() {
        var deceleratingState = ChatTranscriptRestoreState()
        deceleratingState.recordRestoreAttempt()
        deceleratingState.recordMetrics(
            isNearBottom: true,
            isDirectlyInteracting: false,
            isDecelerating: true
        )
        deceleratingState.recordTailVisibility(true)
        XCTAssertFalse(deceleratingState.isCancelled)
        XCTAssertTrue(
            deceleratingState.shouldSettle(
                target: .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
        )

        var asynchronousGeometryState = ChatTranscriptRestoreState()
        asynchronousGeometryState.recordRestoreAttempt()
        asynchronousGeometryState.recordMetrics(
            isNearBottom: false,
            isDirectlyInteracting: false,
            isDecelerating: false
        )
        XCTAssertFalse(asynchronousGeometryState.isCancelled)
    }


    func testStreamingFlushMustNotInvalidateTheTranscriptView() {
        XCTAssertFalse(ChatScrollPolicy.shouldBumpScrollTriggerForStreamingFlush())
    }

    func testLiveSessionReconcileKeepsInProgressChrome() {
        XCTAssertTrue(
            ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: "stream-live",
                localActiveStreamID: nil
            )
        )
        XCTAssertTrue(
            ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: nil,
                localActiveStreamID: "stream-live"
            )
        )
        XCTAssertFalse(
            ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: nil,
                localActiveStreamID: nil
            )
        )
        XCTAssertFalse(
            ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: "   ",
                localActiveStreamID: ""
            )
        )
    }

    func testStreamingBubbleHeightMustNotImplicitlyAnimateUnderTheFinger() {
        XCTAssertFalse(
            ChatScrollPolicy.shouldAnimateStreamingBubbleHeight(
                shouldFollowLatestMessage: false,
                isUserInteracting: false
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldAnimateStreamingBubbleHeight(
                shouldFollowLatestMessage: true,
                isUserInteracting: true
            )
        )
        XCTAssertFalse(
            ChatScrollPolicy.shouldAnimateStreamingBubbleHeight(
                shouldFollowLatestMessage: true,
                isUserInteracting: false
            )
        )
    }

    func testDebugPerformanceLabUsesTheRealChatSurfaceWithTenThousandRows() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: sourceURL.appendingPathComponent("HermesMobile/HermesMobileApp.swift"),
            encoding: .utf8
        )
        let viewModelSource = try String(
            contentsOf: sourceURL.appendingPathComponent("HermesMobile/Features/Chat/ChatViewModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("--chat-performance-lab"))
        XCTAssertTrue(appSource.contains("ChatPerformanceLabView"))
        XCTAssertTrue(viewModelSource.contains("seedPerformanceLab(messageCount: 10_000)"))
    }

}
