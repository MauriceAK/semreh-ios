import CoreGraphics
import Foundation
import SwiftUI

/// Pure decision rules for the chat transcript's auto-scroll behavior.
///
/// The transcript keeps app-owned follow-bottom intent separate from
/// user-owned manual scrolling, and a short cooldown after any user
/// interaction prevents streaming layout growth from yanking the viewport
/// while a manual scroll is still settling.
enum ChatScrollPolicy {
    /// Existing transcripts should enter at their latest content as part of the
    /// scroll view's first layout, before the destination becomes visible.
    static let initialTranscriptAnchor = UnitPoint.bottom

    /// Rich Markdown can finish measuring after the scroll view's initial
    /// layout. Keep those size changes bottom-pinned only while the app still
    /// owns follow-latest intent; return nil as soon as the reader scrolls away.
    /// A composer/keyboard resize is also a size change. A latest-following
    /// transcript must stay pinned while that viewport changes, otherwise the
    /// newly inserted/streaming tail can briefly render behind the composer.
    /// Reader mode remains unanchored during the same resize so its viewport is
    /// not repositioned by the composer.
    static func sizeChangeAnchor(
        shouldFollowLatestMessage: Bool,
        isComposerResizing: Bool = false
    ) -> UnitPoint? {
        _ = isComposerResizing
        return shouldFollowLatestMessage ? .bottom : nil
    }

    /// A composer resize is a viewport change, not new transcript content. Preserve
    /// a reader's position during the resize; only re-pin a user who was already
    /// following the latest content and is not actively dragging the transcript.
    static func shouldFollowAfterComposerResize(
        wasFollowingLatest: Bool,
        isUserInteracting: Bool
    ) -> Bool {
        wasFollowingLatest && !isUserInteracting
    }

    /// Distance (pt) from the bottom within which we treat the transcript as
    /// pinned to the latest content while idle.
    static let bottomDetectionThreshold: CGFloat = 80

    /// Looser bottom threshold while a response is streaming, so small layout
    /// jitter from incoming tokens does not flip follow state off.
    static let streamingBottomDetectionThreshold: CGFloat = 160

    /// Extra distance past the bottom threshold required before the composer
    /// chrome collapses into its compact "reading older" presentation.
    static let readingOlderHysteresis: CGFloat = 64

    /// How long automatic follow-scroll stays paused after the user last
    /// interacted with the scroll view.
    static let userScrollCooldown: TimeInterval = 0.25

    static func bottomThreshold(isStreaming: Bool) -> CGFloat {
        isStreaming ? streamingBottomDetectionThreshold : bottomDetectionThreshold
    }

    static func isNearBottom(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom <= bottomThreshold(isStreaming: isStreaming)
    }

    /// True once the user has scrolled far enough above the bottom that the
    /// composer chrome should collapse. The hysteresis keeps the chrome stable
    /// when hovering right around the bottom threshold.
    static func shouldEnterReadingOlder(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom > bottomThreshold(isStreaming: isStreaming) + readingOlderHysteresis
    }

    static func cooldownDeadline(after date: Date = Date()) -> Date {
        date.addingTimeInterval(userScrollCooldown)
    }

    /// Automatic follow-scroll is paused while the user is actively touching the
    /// scroll view and for a brief cooldown window afterward. Explicit user
    /// actions (tapping scroll-to-bottom, sending a message) bypass this.
    static func isAutoScrollPaused(
        isUserInteracting: Bool,
        cooldownUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        if isUserInteracting {
            return true
        }

        guard let cooldownUntil else {
            return false
        }

        return now < cooldownUntil
    }

    /// Streaming follow uses the default size-change anchor plus bounded measured
    /// content-growth corrections. Extra `scrollTo` on every token is what lags
    /// when the user flicks back down.
    static func shouldProgrammaticallyFollowStreamTokens(shouldFollowLatestMessage: Bool) -> Bool {
        _ = shouldFollowLatestMessage
        return false
    }

    /// Token/reasoning flushes must not bump `streamingScrollTrigger`. That Int is
    /// passed into `ChatTranscriptView`, so incrementing it re-evaluates every row
    /// while the user is reading older messages — the iMessage-level hitch.
    static func shouldBumpScrollTriggerForStreamingFlush() -> Bool {
        false
    }

    /// Keep the active row's height changes unanimated. MarkdownUI already
    /// performs expensive measurement; animating every token makes UIKit's
    /// scroll view chase a moving target under the user's finger.
    static func shouldAnimateStreamingBubbleHeight(
        shouldFollowLatestMessage: Bool,
        isUserInteracting: Bool
    ) -> Bool {
        _ = shouldFollowLatestMessage
        _ = isUserInteracting
        return false
    }

    static func shouldSnapWhenRejoiningLatest(
        wasFollowingLatest: Bool,
        isNearBottom: Bool
    ) -> Bool {
        isNearBottom && !wasFollowingLatest
    }

    /// An explicit tap owns its motion independently of how far away the tail
    /// is. Automatic following keeps its separate near-bottom animation band.
    static func shouldAnimateExplicitBottomJump(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// A lazy transcript can need more than one layout pass before its bottom
    /// sentinel has an exact position. Explicit jumps therefore settle in a
    /// short, bounded sequence instead of trusting one open-loop `scrollTo`.
    static let explicitBottomSettlementDelays: [UInt64] = [
        0,
        16_000_000,
        48_000_000,
        96_000_000,
        180_000_000,
        320_000_000
    ]

    /// Realize the concrete latest row before refining toward the trailing
    /// sentinel. A lazy transcript can otherwise estimate an off-list target
    /// after a large append and land short of the actual bottom.
    static func explicitBottomTargetID(
        latestMessageID: String?,
        latestMessageIsVisible: Bool,
        bottomAnchorID: String
    ) -> String {
        guard !latestMessageIsVisible, let latestMessageID else {
            return bottomAnchorID
        }
        return latestMessageID
    }

    /// Explicit bottom settlement is complete only after a target was issued
    /// and both the scroll metrics and concrete tail-row geometry agree.
    static func shouldFinishExplicitBottomRequest(
        isNearBottom: Bool,
        isTailVisible: Bool,
        isDirectlyInteracting: Bool = false,
        hasIssuedScroll: Bool = true
    ) -> Bool {
        hasIssuedScroll && !isDirectlyInteracting && isNearBottom && isTailVisible
    }

    /// Keep the affordance visible until UIKit reports that the viewport
    /// physically arrived. Follow intent alone is not proof of scroll position.
    static func shouldShowScrollToBottomButton(
        isNearBottom: Bool,
        hasExplicitBottomRequest: Bool,
        hasActiveStream: Bool,
        shouldFollowLatestMessage: Bool
    ) -> Bool {
        guard !isNearBottom else { return false }
        return hasExplicitBottomRequest || !hasActiveStream || !shouldFollowLatestMessage
    }

    /// A trailing deceleration callback belongs to the gesture that preceded a
    /// tap and must not cancel the tap. Only a new finger-driven interaction
    /// supersedes an explicit jump.
    static func shouldCancelExplicitBottomRequest(
        isDirectlyInteracting: Bool,
        isDecelerating: Bool
    ) -> Bool {
        _ = isDecelerating
        return isDirectlyInteracting
    }

    /// Deceleration inherited from the button's preceding gesture is not a new
    /// user scroll. Do not let it install a cooldown after explicit settlement;
    /// a genuinely new direct touch still records the normal cooldown.
    static func shouldRecordUserScrollCooldown(
        isUserInteracting: Bool,
        isDirectlyInteracting: Bool,
        isDecelerating: Bool,
        isExplicitBottomScrollContext: Bool
    ) -> Bool {
        isEffectiveUserInteraction(
            isUserInteracting: isUserInteracting,
            isDirectlyInteracting: isDirectlyInteracting,
            isDecelerating: isDecelerating,
            isExplicitBottomScrollContext: isExplicitBottomScrollContext
        )
    }

    /// Mirrors cooldown ownership for the follow-state branches. Inherited
    /// deceleration from an explicit bottom request is not a fresh user scroll,
    /// so it must not make the transcript stop following through a separate
    /// `isUserInteracting` path.
    static func isEffectiveUserInteraction(
        isUserInteracting: Bool,
        isDirectlyInteracting: Bool,
        isDecelerating: Bool,
        isExplicitBottomScrollContext: Bool
    ) -> Bool {
        guard isUserInteracting else { return false }
        let isInheritedExplicitDeceleration = isExplicitBottomScrollContext
            && isDecelerating
            && !isDirectlyInteracting
        return !isInheritedExplicitDeceleration
    }

    /// Carries explicit-scroll ownership across observer callbacks until
    /// deceleration ends. A new direct touch always drops that ownership.
    static func nextExplicitBottomDecelerationContext(
        wasExplicitBottomScrollActive: Bool,
        wasExplicitBottomDecelerationActive: Bool,
        isDirectlyInteracting: Bool,
        isDecelerating: Bool
    ) -> Bool {
        !isDirectlyInteracting
            && isDecelerating
            && (wasExplicitBottomScrollActive || wasExplicitBottomDecelerationActive)
    }
}

enum ChatTranscriptLayoutFollowChange: Equatable {
    case invalid
    case initial
    case unchanged
    case grew
    case shrank
}

/// Tracks only measured content height. Offset-only scroll samples therefore
/// cannot schedule a follow correction, and the reference can be updated
/// without invalidating the SwiftUI transcript body.
struct ChatTranscriptLayoutFollowState: Equatable {
    static let heightTolerance: CGFloat = 0.5

    private(set) var lastContentHeight: CGFloat?

    mutating func recordContentHeight(_ height: CGFloat) -> ChatTranscriptLayoutFollowChange {
        guard height.isFinite else { return .invalid }

        guard let lastContentHeight else {
            self.lastContentHeight = height
            return .initial
        }

        self.lastContentHeight = height
        if height > lastContentHeight + Self.heightTolerance {
            return .grew
        }
        if height < lastContentHeight - Self.heightTolerance {
            return .shrank
        }
        return .unchanged
    }

    mutating func reset() {
        lastContentHeight = nil
    }
}

enum ChatTranscriptLayoutFollowPolicy {
    /// The first correction is delayed just enough to coalesce the preference
    /// and content-size callbacks from one layout transaction.
    static let coalescingDelay: TimeInterval = 0.016

    /// A streaming row may grow many times per second. Keep proxy corrections
    /// bounded to this cadence while retaining the latest pending growth.
    static let minimumCommandInterval: TimeInterval = 0.1

    static func shouldSchedule(
        change: ChatTranscriptLayoutFollowChange,
        hasRealizedLatestContent: Bool,
        shouldFollowLatestMessage: Bool,
        isUserInteracting: Bool,
        isDecelerating: Bool,
        hasPendingRestore: Bool,
        hasExplicitBottomRequest: Bool,
        isPaging: Bool
    ) -> Bool {
        change == .grew
            && hasRealizedLatestContent
            && shouldFollowLatestMessage
            && !isUserInteracting
            && !isDecelerating
            && !hasPendingRestore
            && !hasExplicitBottomRequest
            && !isPaging
    }
}

/// Chooses the durable transcript row to use when reopening after the user has
/// read away from the latest message. Frames come only from currently realized
/// LazyVStack rows, so this stays bounded to the visible window rather than
/// walking the entire transcript.
enum ChatTranscriptVisibilityPolicy {
    struct VisibleRow: Equatable {
        let id: String
        let frame: CGRect
    }

    static func isVisible(
        frame: CGRect?,
        viewportHeight: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        guard let frame, viewportHeight > 0 else { return false }

        let visibleHeight = max(0, viewportHeight - bottomInset)
        guard visibleHeight > 0 else { return false }

        return frame.height > 0 && frame.maxY > 0 && frame.minY < visibleHeight
    }

    static func firstVisibleMessageID(
        frames: [String: CGRect],
        viewportHeight: CGFloat
    ) -> String? {
        firstVisibleMessage(
            frames: frames,
            viewportHeight: viewportHeight
        )?.id
    }

    static func firstVisibleMessage(
        frames: [String: CGRect],
        viewportHeight: CGFloat
    ) -> VisibleRow? {
        guard viewportHeight > 0 else { return nil }

        return frames
            .filter { _, frame in
                frame.height > 0 && frame.maxY > 0 && frame.minY < viewportHeight
            }
            .min { lhs, rhs in
                if lhs.value.minY == rhs.value.minY {
                    return lhs.key < rhs.key
                }
                return lhs.value.minY < rhs.value.minY
            }
            .map { VisibleRow(id: $0.key, frame: $0.value) }
    }

    /// A preference pass can transiently contain no realized rows while a lazy
    /// stack is being rebuilt. Do not erase the last usable restore anchor from
    /// that sample; a truly empty transcript is the only case that clears it.
    static func retainedVisibleMessageID(
        currentID: String?,
        incomingID: String?,
        hasMessages: Bool
    ) -> String? {
        guard hasMessages else { return nil }
        return incomingID ?? currentID
    }
}

/// Bounded recovery decisions for the lazy transcript. These rules intentionally
/// require a prior realized viewport and current geometry evidence, so a normal
/// return to a chat does not re-scroll a reader who is legitimately reading old
/// messages.
enum ChatTranscriptViewportRecoveryPolicy {
    static func shouldRecoverAfterActivation(
        hasMessages: Bool,
        hadObservedRows: Bool,
        hasVisibleRows: Bool,
        shouldFollowLatest: Bool,
        isNearBottom: Bool,
        isTailVisible: Bool,
        isDirectlyInteracting: Bool,
        isDecelerating: Bool
    ) -> Bool {
        guard hasMessages,
              hadObservedRows,
              !isDirectlyInteracting,
              !isDecelerating
        else { return false }

        // No realized row means the existing lazy offset is not usable. When
        // following latest, a near-bottom sample without the concrete tail is
        // the other known stale-estimate case. A reader with visible rows is
        // otherwise left exactly where they are.
        return !hasVisibleRows || (shouldFollowLatest && isNearBottom && !isTailVisible)
    }
}

/// Paging keeps older-page loads ahead of the top edge without tying the
/// trigger to a particular page size. Only visible row geometry is inspected,
/// so the decision remains bounded by the lazy viewport.
enum ChatTranscriptPagingPolicy {
    static let nearTopPrefetchDistance: CGFloat = 240
    static let anchorPreservationTolerance: CGFloat = 12

    static func shouldPrefetchOlderMessages(
        firstLoadedRow: ChatTranscriptVisibilityPolicy.VisibleRow?,
        firstVisibleRow: ChatTranscriptVisibilityPolicy.VisibleRow?,
        viewportHeight: CGFloat,
        hasOlderMessages: Bool,
        isLoadingOlderMessages: Bool,
        hasPendingRestore: Bool,
        shouldFollowLatest: Bool,
        lastRequestedVisibleRowID: String?
    ) -> Bool {
        guard hasOlderMessages,
              !isLoadingOlderMessages,
              !hasPendingRestore,
              !shouldFollowLatest,
              viewportHeight > 0,
              let firstLoadedRow,
              let firstVisibleRow,
              firstLoadedRow.frame.height > 0,
              firstLoadedRow.frame.maxY >= -nearTopPrefetchDistance,
              firstLoadedRow.frame.minY <= nearTopPrefetchDistance,
              firstVisibleRow.frame.height > 0,
              firstVisibleRow.frame.maxY > 0,
              firstVisibleRow.id != lastRequestedVisibleRowID
        else { return false }

        return true
    }

    /// A prepend should not issue a corrective jump when SwiftUI kept the
    /// anchor's screen position. If the row was displaced or temporarily fell
    /// out of the realized window, one non-animated correction is warranted.
    static func shouldRestorePrependedAnchor(
        beforeFrame: CGRect?,
        afterFrame: CGRect?
    ) -> Bool {
        guard let afterFrame else { return true }
        guard let beforeFrame else { return false }
        return abs(afterFrame.minY - beforeFrame.minY) > anchorPreservationTolerance
    }

    /// Converts the measured pre-page row position into the custom scroll
    /// alignment that keeps its top edge at the same viewport coordinate. This
    /// is more faithful than always using `.top`, especially for a partially
    /// visible or unusually tall message bubble.
    static func preservedAnchorAlignment(
        beforeFrame: CGRect?,
        viewportHeight: CGFloat
    ) -> UnitPoint? {
        guard let beforeFrame,
              viewportHeight > 0,
              beforeFrame.height >= 0
        else { return nil }

        let availableAlignmentDistance = viewportHeight - beforeFrame.height
        guard abs(availableAlignmentDistance) > .ulpOfOne else { return nil }

        let y = beforeFrame.minY / availableAlignmentDistance
        guard y.isFinite else { return nil }
        return UnitPoint(x: 0.5, y: y)
    }
}

struct ChatTranscriptViewportAnchor: Equatable {
    let messageID: String
    let frame: CGRect?
    let viewportHeight: CGFloat?
}

/// Keeps transcript reconciliation and other state-heavy startup work out of
/// the system navigation transition. Cache preparation remains synchronous so
/// an available transcript can participate in the destination's first layout.
enum ChatInitialAppearancePolicy {
    static func shouldBeginAsyncWork(hasCompletedAppearance: Bool) -> Bool {
        hasCompletedAppearance
    }

    static func shouldReloadTranscriptOnAppear(hasPreservedTranscript: Bool) -> Bool {
        !hasPreservedTranscript
    }

    /// A newly created view model may paint cached rows before its first
    /// authoritative network load. Those rows are not proof that the model is
    /// warm; only a model reused from `OpenChatSessionStore` can skip the cold
    /// open reconciliation.
    static func shouldReloadTranscriptOnAppear(
        hasPreservedTranscript: Bool,
        wasReusedFromOpenSessionStore: Bool
    ) -> Bool {
        if wasReusedFromOpenSessionStore {
            return !hasPreservedTranscript
        }

        return true
    }
}

enum ChatTranscriptRestoreTarget: Equatable {
    case latest
    case message(id: String)
}

/// Leave/reopen must land at latest or the last-read message.
/// `defaultScrollAnchor(.bottom)` plus LazyVStack often paints mid-list first.
enum ChatTranscriptRestorePolicy {
    /// LazyVStack estimates can miss a far-away row by dozens of cells on the
    /// first pass. Reissue the same restore against progressively realized
    /// geometry, then stop as soon as the intended viewport is reported.
    static let settlementDelays: [UInt64] = [
        0,
        24_000_000,
        64_000_000,
        128_000_000,
        240_000_000,
        420_000_000
    ]

    static func target(
        wasFollowingLatest: Bool,
        lastVisibleMessageID: String?
    ) -> ChatTranscriptRestoreTarget {
        if wasFollowingLatest {
            return .latest
        }

        let trimmed = lastVisibleMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return .latest
        }
        return .message(id: trimmed)
    }

    /// A saved reader row can be supplied to SwiftUI's initial scroll-position
    /// layout. Latest-follow already uses the bottom default anchor and should
    /// not install a second initial target.
    static func initialPositionMessageID(
        for target: ChatTranscriptRestoreTarget
    ) -> String? {
        guard case let .message(id) = target else { return nil }
        return id
    }

    static func initialTranscriptAnchor(
        for target: ChatTranscriptRestoreTarget,
        hasSavedMessage: Bool
    ) -> UnitPoint {
        guard initialPositionMessageID(for: target) != nil, hasSavedMessage else {
            return ChatScrollPolicy.initialTranscriptAnchor
        }
        return .top
    }

    /// Preference geometry can be published before the transcript's UIKit host
    /// enters a window. Only an attached sample is strong enough to retire the
    /// native seed; otherwise the first in-window layout could fall back to the
    /// provisional default anchor.
    static func shouldConfirmInitialTargetGeometry(
        targetMessageID: String?,
        visibleMessageID: String?,
        isScrollViewAttached: Bool
    ) -> Bool {
        guard isScrollViewAttached,
              let targetMessageID,
              let visibleMessageID
        else { return false }

        return targetMessageID == visibleMessageID
    }

    static func shouldAllowOutgoingInsertionMotion(
        shouldFollowLatestMessage: Bool,
        isRestoreInProgress: Bool
    ) -> Bool {
        shouldFollowLatestMessage && !isRestoreInProgress
    }

    static func shouldProgrammaticallyRestoreOnAppear(hasMessages: Bool) -> Bool {
        hasMessages
    }

    /// A view can disappear before its asynchronous appearance task copies the
    /// durable restore point into local state. Do not replace that point with a
    /// default latest-position decision when a user has not interacted yet.
    static func shouldStartRestore(
        hasMessages: Bool,
        hasUserInteractedBeforeRestore: Bool
    ) -> Bool {
        hasMessages && !hasUserInteractedBeforeRestore
    }

    /// Initial geometry is not a user decision. Before restore initialization,
    /// only a real finger interaction may change follow intent.
    static func shouldApplyScrollMetricsBeforeRestore(
        hasRequestedRestore: Bool,
        hasPendingMessageRestore: Bool,
        hasUserInteractedBeforeRestore: Bool,
        isDirectlyInteracting: Bool
    ) -> Bool {
        hasUserInteractedBeforeRestore
            || isDirectlyInteracting
            || (hasRequestedRestore && !hasPendingMessageRestore)
    }

    static func hasReachedTarget(
        _ target: ChatTranscriptRestoreTarget,
        firstVisibleMessageID: String?,
        isNearBottom: Bool,
        isTailVisible: Bool
    ) -> Bool {
        switch target {
        case .latest:
            // UIKit can report a zero distance while the lazy stack still has
            // no realized tail. Treating that provisional geometry as success
            // leaves the scroll view at an empty estimated offset until a touch
            // forces another layout pass.
            return isNearBottom && isTailVisible
        case .message(let id):
            return firstVisibleMessageID == id
        }
    }

    /// A restore is superseded only by a new finger-driven interaction. UIKit's
    /// deceleration and asynchronous content/layout metrics still belong to the
    /// restore that is settling.
    static func shouldCancelPendingRestore(
        isDirectlyInteracting: Bool,
        isDecelerating: Bool
    ) -> Bool {
        _ = isDecelerating
        return isDirectlyInteracting
    }
}

/// Small, testable state machine for a transcript restore settlement pass.
/// `ChatTranscriptView` starts with no geometry sample; its initial near-bottom
/// input is only a default and cannot prove that a latest restore converged.
struct ChatTranscriptRestoreState: Equatable {
    /// The restore token currently owned by this settlement state. Nil is the
    /// pre-request window in which a direct interaction can cancel the first
    /// restore before ChatView has requested it.
    private(set) var restoreToken: Int? = nil
    private(set) var hasIssuedRestoreAttempt = false
    private(set) var hasConfirmedMetricsSample = false
    private(set) var isCancelled = false
    private(set) var isNearBottom = false
    private(set) var isTailVisible = false
    private(set) var hasObservedVisibleMessageSample = false
    private(set) var observedVisibleMessageID: String?

    /// Claims a restore token without allowing a pre-request cancellation to be
    /// replaced by a fresh state. A different token represents a new lifecycle
    /// request and starts a clean settlement pass.
    mutating func beginRestore(token: Int) -> Bool {
        guard restoreToken != token else { return !isCancelled }

        let preservePreRequestCancellation = restoreToken == nil && isCancelled
        restoreToken = token
        hasIssuedRestoreAttempt = false
        hasConfirmedMetricsSample = false
        isNearBottom = false
        // Keep the latest preference-backed visibility samples. SwiftUI may
        // deliver the target row or bottom-anchor preference before the initial
        // restore token arrives and will not necessarily redeliver them.
        isCancelled = preservePreRequestCancellation
        return !isCancelled
    }

    /// Starts a geometry-proven recovery after a scene/tab activation. Unlike
    /// the initial restore, this is allowed to supersede a previously cancelled
    /// request because the caller has already ruled out an active finger drag.
    mutating func beginViewportRecovery(token: Int) -> Bool {
        restoreToken = token
        hasIssuedRestoreAttempt = false
        hasConfirmedMetricsSample = false
        isNearBottom = false
        hasObservedVisibleMessageSample = false
        observedVisibleMessageID = nil
        isCancelled = false
        return true
    }

    mutating func recordRestoreAttempt() {
        hasIssuedRestoreAttempt = true
    }

    mutating func cancel() {
        isCancelled = true
    }

    mutating func recordMetrics(
        isNearBottom: Bool,
        isDirectlyInteracting: Bool,
        isDecelerating: Bool
    ) {
        guard !isCancelled else { return }

        if ChatTranscriptRestorePolicy.shouldCancelPendingRestore(
            isDirectlyInteracting: isDirectlyInteracting,
            isDecelerating: isDecelerating
        ) {
            isCancelled = true
            return
        }

        hasConfirmedMetricsSample = true
        self.isNearBottom = isNearBottom
    }

    mutating func recordTailVisibility(_ visible: Bool) {
        guard !isCancelled else { return }
        isTailVisible = visible
    }

    mutating func recordVisibleMessageSample(_ messageID: String?) {
        guard !isCancelled else { return }
        hasObservedVisibleMessageSample = true
        observedVisibleMessageID = messageID
    }

    func shouldSettle(
        target: ChatTranscriptRestoreTarget,
        firstVisibleMessageID: String?,
        isNearBottom: Bool? = nil
    ) -> Bool {
        guard !isCancelled else { return false }

        // On a fresh transcript mount, the seeded native position can already
        // make the saved row the first visible row before the restore token's
        // settling task gets its first turn. That fresh row-frame sample is
        // sufficient evidence to skip the delayed proxy fallback.
        if case let .message(id) = target,
           hasObservedVisibleMessageSample,
           observedVisibleMessageID == id {
            return true
        }

        guard hasIssuedRestoreAttempt || hasConfirmedMetricsSample else { return false }

        return ChatTranscriptRestorePolicy.hasReachedTarget(
            target,
            firstVisibleMessageID: firstVisibleMessageID,
            isNearBottom: isNearBottom ?? self.isNearBottom,
            isTailVisible: isTailVisible
        )
    }
}

enum ChatLiveReconcilePolicy {
    /// A live SSE owner already has in-progress tools/reasoning in RAM.
    /// A later `/api/session` page must not wipe that chrome — that is the
    /// "everything dumps in after a wait" hitch.
    static func shouldPreserveLiveRunChrome(
        loadedActiveStreamID: String?,
        localActiveStreamID: String?
    ) -> Bool {
        func present(_ value: String?) -> Bool {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !trimmed.isEmpty
        }
        return present(loadedActiveStreamID) || present(localActiveStreamID)
    }
}
