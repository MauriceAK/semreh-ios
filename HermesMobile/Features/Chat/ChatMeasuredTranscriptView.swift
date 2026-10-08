import SwiftUI

/// The measured surface has one scrolling owner: the native viewport. This
/// adapter deliberately has no ScrollViewReader, proxy fallback, delayed scroll
/// task, or second restoration state. The supplied viewport carries the same
/// rich rows and typed restore contract as the existing conversation.
struct ChatMeasuredTranscriptView: View {
    let viewport: ChatNativeTranscriptViewport
    let dismissesKeyboardOnTap: Bool
    let onDismissKeyboard: () -> Void

    /// Hosted cells receive an environment snapshot. These values can change
    /// while their message revision stays fixed, so they must also invalidate
    /// the configuration of a stationary, already-mounted row.
    struct EnvironmentSignature: Equatable, CustomStringConvertible {
        var layoutDirection: LayoutDirection
        var dynamicTypeSize: DynamicTypeSize
        var reducesMotion: Bool
        var reducesTransparency: Bool
        var increasesContrast: Bool
        var differentiatesWithoutColor: Bool

        var description: String {
            "direction:\(layoutDirection)|type:\(dynamicTypeSize)|motion:\(reducesMotion)"
                + "|transparency:\(reducesTransparency)|contrast:\(increasesContrast)"
                + "|differentiate:\(differentiatesWithoutColor)"
        }
    }

    static func environmentSignature(_ environment: EnvironmentValues) -> EnvironmentSignature {
        EnvironmentSignature(layoutDirection: environment.layoutDirection,
            dynamicTypeSize: environment.dynamicTypeSize,
            reducesMotion: environment.accessibilityReduceMotion,
            reducesTransparency: environment.accessibilityReduceTransparency,
            increasesContrast: environment.colorSchemeContrast == .increased,
            differentiatesWithoutColor: environment.accessibilityDifferentiateWithoutColor)
    }

    var body: some View {
        viewport
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard dismissesKeyboardOnTap else { return }
                    onDismissKeyboard()
                }
            )
    }
}
