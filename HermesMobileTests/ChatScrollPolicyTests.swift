import XCTest
@testable import HermesMobile

final class ChatScrollPolicyTests: XCTestCase {
    func testExistingTranscriptUsesBottomAsItsInitialLayoutAnchor() {
        XCTAssertEqual(ChatScrollPolicy.initialTranscriptAnchor, .bottom)
    }

    func testTranscriptSizeChangesStayBottomAnchoredOnlyWhileFollowingLatest() {
        XCTAssertEqual(
            ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: true),
            .bottom
        )
        XCTAssertNil(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: false))
        XCTAssertNil(
            ChatScrollPolicy.sizeChangeAnchor(
                shouldFollowLatestMessage: true,
                isComposerResizing: true
            )
        )
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

    func testLeavingAChatKeepsTheLiveStreamAttached() {
        XCTAssertTrue(ChatNavigationLifecyclePolicy.shouldKeepLiveStreamOnDisappear)
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
                isNearBottom: false
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.hasReachedTarget(
                .message(id: "transcript:20"),
                firstVisibleMessageID: "transcript:20",
                isNearBottom: false
            )
        )
        XCTAssertTrue(
            ChatTranscriptRestorePolicy.hasReachedTarget(
                .latest,
                firstVisibleMessageID: nil,
                isNearBottom: true
            )
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
