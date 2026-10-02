import SwiftUI

struct ChatActiveRunStatusView: View {
    let presentation: ChatActiveRunStatusPresentation

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            Text(presentation.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.88)

        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .chatTimelineAccessorySurface(
            fallbackMaterial: .regularMaterial,
            cornerRadius: 16
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

#Preview("Active Run Status") {
    VStack(spacing: 12) {
        ChatActiveRunStatusView(
            presentation: ChatActiveRunStatusPresentation(kind: .reconnecting)
        )
    }
    .padding()
    .background(Color(.systemBackground))
}
