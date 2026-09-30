import Foundation
import UIKit

enum ChatHapticFeedback: Equatable {
    case lightImpact
    case mediumImpact
    case selection
    case success
    case warning
}

/// A small, visible-progress gate for the stream's selection pulse. It has no
/// timer: network bursts cannot schedule pulses that fire after a view leaves.
struct StreamingHapticPulseGate {
    static let minimumInterval: TimeInterval = 0.65
    static let minimumVisibleUnits = 4

    private var firstProgressAt: TimeInterval?
    private var lastPulseAt: TimeInterval?
    private var visibleUnitsSincePulse = 0

    mutating func recordVisibleUnits(_ units: Int, at now: TimeInterval) -> Bool {
        guard units > 0 else { return false }
        if firstProgressAt == nil { firstProgressAt = now }
        visibleUnitsSincePulse += units
        guard visibleUnitsSincePulse >= Self.minimumVisibleUnits,
              now - (lastPulseAt ?? firstProgressAt ?? now) >= Self.minimumInterval
        else { return false }
        visibleUnitsSincePulse = 0
        lastPulseAt = now
        return true
    }

    mutating func reset() {
        firstProgressAt = nil
        lastPulseAt = nil
        visibleUnitsSincePulse = 0
    }
}

enum StreamingHapticEligibility {
    static func shouldEmit(
        isSceneActive: Bool,
        isChatPresented: Bool,
        isLatestTranscriptRowVisible: Bool,
        isTranscriptBottomVisible: Bool,
        shouldFollowLatestMessage: Bool
    ) -> Bool {
        isSceneActive && isChatPresented && isLatestTranscriptRowVisible
            && isTranscriptBottomVisible && shouldFollowLatestMessage
    }
}

@MainActor
enum ChatHaptics {
    typealias Performer = @MainActor (ChatHapticFeedback) -> Void

    static func messageSent(isEnabled: Bool, performer: Performer = perform) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    static func assistantResponseCompleted(isEnabled: Bool, performer: Performer = perform) {
        emit(.success, isEnabled: isEnabled, performer: performer)
    }

#if DEBUG
    // Actual enabled stream-feedback dispatches; not physical haptic evidence.
    private(set) static var performedStreamProgressCount = 0
#endif
    static func streamProgress(isEnabled: Bool, performer: Performer = perform) {
#if DEBUG
        if isEnabled { performedStreamProgressCount += 1 }
#endif
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func streamCancelled(isEnabled: Bool, performer: Performer = perform) {
        emit(.mediumImpact, isEnabled: isEnabled, performer: performer)
    }

    static func approvalSubmitted(_ choice: ApprovalChoice, isEnabled: Bool, performer: Performer = perform) {
        switch choice {
        case .once, .session, .always:
            emit(.lightImpact, isEnabled: isEnabled, performer: performer)
        case .deny:
            emit(.warning, isEnabled: isEnabled, performer: performer)
        }
    }

    static func approvalBypassEnabled(isEnabled: Bool, performer: Performer = perform) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    static func clarificationSubmitted(isEnabled: Bool, performer: Performer = perform) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func configurationSelected(isEnabled: Bool, performer: Performer = perform) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func destructiveConfirmationAccepted(isEnabled: Bool, performer: Performer = perform) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    private static func emit(_ feedback: ChatHapticFeedback, isEnabled: Bool, performer: Performer) {
        guard isEnabled else { return }
        performer(feedback)
    }

    private static func perform(_ feedback: ChatHapticFeedback) {
        switch feedback {
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
