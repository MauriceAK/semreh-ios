import SwiftUI

struct ChatActiveRunStatusView: View {
    let presentation: ChatActiveRunStatusPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            progressIndicator

            Text(presentation.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.88)

            if let activeRunStartedAt = presentation.activeRunStartedAt {
                // Self-updating "working for X" readout (item 4). The count-up has
                // no natural end, so the bound stays far out; the system updates the
                // text on its own cadence without re-evaluating this view.
                Text(timerInterval: activeRunStartedAt...Date.distantFuture, countsDown: false)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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

    @ViewBuilder
    private var progressIndicator: some View {
        if reduceMotion {
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        }
    }
}

#Preview("Active Run Status") {
    VStack(spacing: 12) {
        ChatActiveRunStatusView(
            presentation: ChatActiveRunStatusPresentation(
                kind: .active,
                activeRunStartedAt: Date(timeIntervalSinceNow: -83)
            )
        )

        ChatActiveRunStatusView(
            presentation: ChatActiveRunStatusPresentation(kind: .reconnecting)
        )
    }
    .padding()
    .background(Color(.systemBackground))
}
