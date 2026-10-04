import SwiftUI

/// The transcript has one viewport, already resized by SwiftUI for the keyboard.
/// Only the chrome actually drawn over that viewport contributes content clearance.
/// The native transcript owns scrolling and preserves its reader anchor when these
/// measurements change; this shell does not observe offsets or schedule follow work.
struct ChatSurfaceLayout<Transcript: View, Header: View, Bottom: View>: View {
    let onHeaderHeightChange: (CGFloat) -> Void
    let onBottomHeightChange: (CGFloat) -> Void
    @ViewBuilder let transcript: () -> Transcript
    @ViewBuilder let header: () -> Header
    @ViewBuilder let bottom: () -> Bottom

    var body: some View {
        ZStack {
            transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
