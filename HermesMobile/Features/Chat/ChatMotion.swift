import SwiftUI

enum ChatMotion {
    static func press(duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: duration, extraBounce: 0)
    }

    static func quickState(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.10) : .easeInOut(duration: 0.16)
    }

    static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.10) : .smooth(duration: 0.18, extraBounce: 0)
    }

    static func composerChrome(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22, extraBounce: 0)
    }

    /// Coordinates the optimistic row insertion with its local entrance.
    /// The transcript's existing bottom anchor supplies the layout movement;
    /// this adds no independent scroll-offset writer.
    static func outgoingBubble(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.26, extraBounce: 0.03)
    }

    static let scrollToLatestDuration: TimeInterval = 0.20
    static func scrollToLatest(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: scrollToLatestDuration)
    }

    /// The window during which an issued explicit bottom-jump animation is
    /// still airborne. Direct jumps (Reduce Motion) have no window.
    static func explicitBottomAnimationWindow(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : scrollToLatestDuration
    }

    /// Bottom-follow scrolling and active-row height growth while a response
    /// streams in. Short enough to keep up with the ~48ms word-reveal cadence;
    /// each new flush retargets the previous animation so the streaming edge
    /// glides instead of stepping per flush.
    static func streamingFollow(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    static func typingIndicator(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    static func bottomOverlayTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    /// Message insertion: a short fade with a small rise as new transcript
    /// rows enter. Streaming text updates reuse row identity, so they never
    /// trigger this transition — only genuine inserts/removals do.
    static func messageInsert(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0)
    }

    static func messageInsertTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom))
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}
