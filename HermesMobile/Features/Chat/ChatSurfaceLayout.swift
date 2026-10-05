import SwiftUI

/// The transcript underlaps bottom container chrome while SwiftUI still owns
/// keyboard avoidance. Only measured chrome and underlap add content clearance.
/// The native transcript owns scrolling and preserves its reader anchor when these
/// measurements change; this shell does not observe offsets or schedule follow work.
struct ChatSurfaceLayout<Transcript: View, Header: View, Bottom: View>: View {
    let onHeaderHeightChange: (CGFloat) -> Void
    let onBottomHeightChange: (CGFloat) -> Void
    var onBottomUnderlapChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder let transcript: () -> Transcript
    @ViewBuilder let header: () -> Header
    @ViewBuilder let bottom: () -> Bottom

    var body: some View {
        GeometryReader { shell in
            ZStack {
                transcript()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .anchorPreference(key: ChatSurfaceTranscriptBoundsKey.self, value: .bounds) { $0 }
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            // Keep overlay chrome within the independent safe-area proposal;
            // the transcript may draw below it without enlarging the shell.
            .frame(width: shell.size.width, height: shell.size.height)
            .overlayPreferenceValue(ChatSurfaceTranscriptBoundsKey.self) { bounds in
                GeometryReader { geometry in
                    // Resolve both edges in this layout pass. Container insets can
                    // include keyboard avoidance, so they are not tab-bar heights.
                    let underlap = bounds.map {
                        max(0, geometry[$0].maxY - shell.size.height)
                    } ?? 0
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .onChange(of: underlap, initial: true) { _, value in
                            onBottomUnderlapChange(value)
                        }
                }
            }
            .overlay(alignment: .top) {
                header()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("muse-chat-header")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        onHeaderHeightChange($0)
                    }
            }
            .overlay(alignment: .bottom) {
                bottom()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("muse-chat-dock")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        onBottomHeightChange($0)
                    }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ChatSurfaceTranscriptBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
